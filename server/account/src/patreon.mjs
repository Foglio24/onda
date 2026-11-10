import { createHmac, timingSafeEqual } from "node:crypto";
import { HttpError, json, readText, respond, unix } from "./http.mjs";

// Seaglass Premium is a Patreon membership of Seaglass's campaign: the account page links an
// account to it (OAuth, the "identity" scope, which shows memberships of this client's own
// campaign), and Patreon's webhooks keep its status current. An active paid membership (at least
// PREMIUM_MIN_CENTS a month, any paid tier by default) is Premium, which unlocks features in the
// app. Patreon's tokens are used once, to read the membership, and never kept.

const authorizeURL = "https://www.patreon.com/oauth2/authorize";
const tokenURL = "https://www.patreon.com/api/oauth2/token";
const identityURL = "https://www.patreon.com/api/oauth2/v2/identity";
const stateLifetime = 600;
const encoder = new TextEncoder();

function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}
async function hash(value) {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value))));
}

export function patreonConfigured(env) {
  return Boolean(env.PATREON_CLIENT_ID && env.PATREON_CLIENT_SECRET);
}

function callbackURL(env) {
  return new URL("/v1/patreon/callback", env.PUBLIC_ORIGIN).href;
}

function redirect(location) {
  return respond(null, 303, { Location: location });
}

/** The page asks to link Patreon: where to send the browser. */
export async function startPatreon(env, accountId) {
  if (!patreonConfigured(env)) throw new HttpError(503, "patreon_unconfigured");
  const state = base64url(crypto.getRandomValues(new Uint8Array(32)));
  await env.DB.prepare("INSERT INTO patreon_states (state_hash, account_id, expires_at) VALUES (?, ?, ?)")
    .bind(await hash(state), accountId, unix() + stateLifetime).run();
  const url = new URL(authorizeURL);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", env.PATREON_CLIENT_ID.trim());
  url.searchParams.set("redirect_uri", callbackURL(env));
  url.searchParams.set("scope", "identity");
  url.searchParams.set("state", state);
  return json({ redirect: url.href });
}

/**
 * Patreon sends the browser back here: the membership is read and the account linked. Only in
 * the browser that started it, signed in to the same account: a link sent to someone else
 * can't tie their Patreon to another account.
 */
export async function finishPatreon(url, env, accountId) {
  const state = url.searchParams.get("state") ?? "";
  const code = url.searchParams.get("code") ?? "";
  if (!/^[A-Za-z0-9_-]{43}$/.test(state)) return redirect("/account?patreon=failed");
  const pending = await env.DB.prepare("DELETE FROM patreon_states WHERE state_hash = ? AND expires_at > ? RETURNING account_id")
    .bind(await hash(state), unix()).first();
  if (!pending || pending.account_id !== accountId || !code || code.length > 512 || !patreonConfigured(env)) {
    return redirect("/account?patreon=failed");
  }
  try {
    const member = await readMembership(env, code);
    const now = unix();
    await env.DB.batch([
      // A Patreon account links to one Seaglass account: linking it here unlinks it elsewhere.
      env.DB.prepare("DELETE FROM patreon_links WHERE patreon_user_id = ? AND account_id <> ?").bind(member.userId, pending.account_id),
      env.DB.prepare(`INSERT INTO patreon_links (account_id, patreon_user_id, patron_status, entitled_cents, linked_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(account_id) DO UPDATE SET patreon_user_id = excluded.patreon_user_id,
          patron_status = excluded.patron_status, entitled_cents = excluded.entitled_cents, updated_at = excluded.updated_at`)
        .bind(pending.account_id, member.userId, member.status, member.cents, now, now),
    ]);
    return redirect("/account?patreon=linked");
  } catch {
    return redirect("/account?patreon=failed");
  }
}

async function readMembership(env, code) {
  const token = await fetch(tokenURL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", "User-Agent": "Seaglass-Account" },
    body: new URLSearchParams({
      code, grant_type: "authorization_code", client_id: env.PATREON_CLIENT_ID.trim(),
      client_secret: env.PATREON_CLIENT_SECRET.trim(), redirect_uri: callbackURL(env),
    }),
  });
  if (!token.ok) throw new Error("token");
  const { access_token: accessToken } = await token.json();
  if (typeof accessToken !== "string" || !accessToken) throw new Error("token");
  const url = new URL(identityURL);
  url.searchParams.set("include", "memberships");
  url.searchParams.set("fields[member]", "patron_status,currently_entitled_amount_cents");
  url.searchParams.set("fields[user]", "full_name");
  const identity = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}`, "User-Agent": "Seaglass-Account" } });
  if (!identity.ok) throw new Error("identity");
  const body = await identity.json();
  const userId = body?.data?.id;
  if (typeof userId !== "string" || !/^\d{1,20}$/.test(userId)) throw new Error("identity");
  const members = (Array.isArray(body.included) ? body.included : []).filter((item) => item?.type === "member" &&
    (!env.PATREON_CAMPAIGN_ID || item.relationships?.campaign?.data?.id == null ||
      item.relationships.campaign.data.id === env.PATREON_CAMPAIGN_ID));
  return { userId, ...memberStatus(members[0]?.attributes) };
}

function memberStatus(attributes) {
  const status = ["active_patron", "declined_patron", "former_patron"].includes(attributes?.patron_status)
    ? attributes.patron_status : null;
  const cents = Number.isSafeInteger(attributes?.currently_entitled_amount_cents)
    ? Math.max(0, Math.min(attributes.currently_entitled_amount_cents, 10_000_000)) : 0;
  return { status, cents };
}

export async function disconnectPatreon(env, accountId) {
  await env.DB.prepare("DELETE FROM patreon_links WHERE account_id = ?").bind(accountId).run();
  return respond(null, 204);
}

/**
 * Patreon's webhook for the campaign's members (members:create, members:update, members:delete and
 * their pledge variants). Signed with the webhook's secret: the hex HMAC-MD5 of the body as sent.
 */
export async function patreonWebhook(request, env) {
  if (!env.PATREON_WEBHOOK_SECRET) throw new HttpError(503, "patreon_unconfigured");
  const body = await readText(request, 262_144);
  const signature = request.headers.get("X-Patreon-Signature") ?? "";
  const expected = createHmac("md5", env.PATREON_WEBHOOK_SECRET.trim()).update(body).digest("hex");
  if (!/^[0-9a-f]{32}$/.test(signature) ||
      !timingSafeEqual(Buffer.from(signature, "utf8"), Buffer.from(expected, "utf8"))) {
    throw new HttpError(401, "invalid_signature");
  }
  let payload;
  try { payload = JSON.parse(body); } catch { throw new HttpError(400, "invalid_json"); }
  const member = payload?.data;
  const userId = member?.relationships?.user?.data?.id;
  const campaignId = member?.relationships?.campaign?.data?.id;
  if (member?.type !== "member" || typeof userId !== "string" || !/^\d{1,20}$/.test(userId)) return json({ ignored: true });
  if (env.PATREON_CAMPAIGN_ID && campaignId != null && campaignId !== env.PATREON_CAMPAIGN_ID) return json({ ignored: true });
  const event = request.headers.get("X-Patreon-Event") ?? "";
  const { status, cents } = event.endsWith(":delete") ? { status: "former_patron", cents: 0 } : memberStatus(member.attributes);
  await env.DB.prepare("UPDATE patreon_links SET patron_status = ?, entitled_cents = ?, updated_at = ? WHERE patreon_user_id = ?")
    .bind(status, cents, unix(), userId).run();
  return json({ accepted: true });
}

/** What the app and the page show: the account's Patreon membership and whether it is Premium. */
export async function membership(env, accountId) {
  const row = await env.DB.prepare(`SELECT accounts.premium_lifetime, patreon_links.account_id AS linked_account,
      patreon_links.patron_status, patreon_links.entitled_cents, patreon_links.linked_at, patreon_links.updated_at
    FROM accounts LEFT JOIN patreon_links ON patreon_links.account_id = accounts.id WHERE accounts.id = ?`)
    .bind(accountId).first();
  const link = row?.linked_account ? row : null;
  const lifetime = row?.premium_lifetime === 1;
  return {
    provider: "patreon",
    available: patreonConfigured(env),
    joinURL: joinURL(env),
    linked: Boolean(link),
    // Premium for life (the creator's account) needs no membership.
    lifetime,
    premium: lifetime || isPremium(env, link),
    status: link?.patron_status ?? null,
    entitledCents: link?.entitled_cents ?? 0,
    linkedAt: link?.linked_at ?? null,
    updatedAt: link?.updated_at ?? null,
  };
}

function isPremium(env, link) {
  const minimum = Number.parseInt(env.PREMIUM_MIN_CENTS ?? "", 10);
  return link?.patron_status === "active_patron" &&
    link.entitled_cents >= (Number.isSafeInteger(minimum) && minimum > 0 ? minimum : 1);
}

/** Seaglass's page on Patreon, only when it is one (it's shown as a link). */
function joinURL(env) {
  try {
    const url = new URL(env.PATREON_URL);
    return url.protocol === "https:" && (url.hostname === "patreon.com" || url.hostname.endsWith(".patreon.com")) ? url.href : null;
  } catch { return null; }
}
