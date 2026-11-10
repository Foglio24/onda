// The account service end to end, on a local copy of the Worker and its database (Miniflare,
// through Wrangler): signing up (confirming the address) and in from the page and from the app,
// syncing, the profile, Patreon's webhook, changing and resetting the password, signing out and
// deleting the account. Emails go to a stand-in for Resend's API on this machine.
// Run with `npm test` from server/account. Nothing here reaches Cloudflare, Patreon or Resend.

import { execFileSync } from "node:child_process";
import { createHash, createHmac, randomBytes, randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { unstable_startWorker } from "wrangler";

const root = fileURLToPath(new URL("..", import.meta.url));
const origin = "https://account.seaglass.test";
const webhookSecret = "test-webhook-secret";
const state = mkdtempSync(join(tmpdir(), "seaglass-account-"));
const wrangler = join(root, "node_modules", ".bin", "wrangler");

execFileSync(wrangler, ["d1", "migrations", "apply", "DB", "--local", "--persist-to", state], {
  cwd: root, stdio: ["ignore", "ignore", "inherit"], env: { ...process.env, CI: "1" },
});
function sql(command) {
  return JSON.parse(execFileSync(wrangler, ["d1", "execute", "DB", "--local", "--persist-to", state, "--json", "--command", command], {
    cwd: root, stdio: ["ignore", "pipe", "inherit"], env: { ...process.env, CI: "1" },
  }).toString())[0].results;
}

// Resend's API, as far as the Worker can tell: every email it sends lands in `emails`.
const emails = [];
const resend = createServer((request, response) => {
  let body = "";
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    if (request.headers.authorization === "Bearer test-resend") emails.push(JSON.parse(body));
    response.writeHead(request.headers.authorization === "Bearer test-resend" ? 200 : 401, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ id: randomUUID() }));
  });
});
await new Promise((resolve) => resend.listen(0, "127.0.0.1", resolve));
process.env.NO_PROXY = [process.env.NO_PROXY, "127.0.0.1", "localhost"].filter(Boolean).join(",");
const lastEmail = () => emails.at(-1);

const worker = await unstable_startWorker({
  config: join(root, "wrangler.jsonc"),
  bindings: {
    PATREON_CLIENT_ID: { type: "plain_text", value: "test-client" },
    PATREON_CLIENT_SECRET: { type: "plain_text", value: "test-secret" },
    PATREON_WEBHOOK_SECRET: { type: "plain_text", value: webhookSecret },
    PATREON_CAMPAIGN_ID: { type: "plain_text", value: "4242" },
    PATREON_URL: { type: "plain_text", value: "https://www.patreon.com/seaglass" },
    RESEND_API_KEY: { type: "plain_text", value: "test-resend" },
    RESEND_ENDPOINT: { type: "plain_text", value: `http://127.0.0.1:${resend.address().port}/emails` },
    AUTH_EMAIL_FROM: { type: "plain_text", value: "Seaglass <no-reply@seaglass.test>" },
    AUTH_EMAIL_READY: { type: "plain_text", value: "true" },
  },
  dev: { persist: state, server: { port: 0, secure: true }, inspector: false, logLevel: "error" },
});

let failures = 0;
let passed = 0;
function check(condition, label, detail) {
  if (condition) { passed += 1; return; }
  failures += 1;
  console.error(`✗ ${label}` + (detail === undefined ? "" : `: ${typeof detail === "string" ? detail : JSON.stringify(detail)}`));
}

/** A request to the Worker. `cookies` is a jar (Map) that Set-Cookie updates. */
async function call(method, path, { body, cookies, bearer, origin: from = origin, headers = {}, raw } = {}) {
  const init = { method, redirect: "manual", headers: { ...headers } };
  if (body !== undefined) {
    init.body = raw ? body : JSON.stringify(body);
    if (!raw) init.headers["Content-Type"] = "application/json";
  }
  if (from && method !== "GET") init.headers.Origin = from;
  if (cookies?.size) init.headers.Cookie = [...cookies].map(([name, value]) => `${name}=${value}`).join("; ");
  if (bearer) init.headers.Authorization = `Bearer ${bearer}`;
  const response = await worker.fetch(origin + path, init);
  for (const line of response.headers.getSetCookie?.() ?? []) {
    const [pair] = line.split(";");
    const index = pair.indexOf("=");
    const name = pair.slice(0, index);
    const value = pair.slice(index + 1);
    if (cookies) value && !/Max-Age=0/.test(line) ? cookies.set(name, value) : cookies.delete(name);
  }
  const text = await response.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  return { status: response.status, headers: response.headers, data };
}

const base64url = (bytes) => Buffer.from(bytes).toString("base64url");

try {
  // The service and the page.
  let response = await call("GET", "/health");
  check(response.status === 200 && response.data.status === "ok", "health");
  response = await call("GET", "/v1/status");
  check(response.data.accountLoginEnabled === true && response.data.emailEnabled === true && response.data.patreonEnabled === true &&
    response.data.premiumEnabled === true && response.data.supportEmail?.includes("@"), "status", response.data);
  response = await call("GET", "/account");
  check(response.status === 200 && String(response.data).includes("account.js"), "page served", response.status);
  check((response.headers.get("Content-Security-Policy") ?? "").includes("frame-ancestors 'none'"), "page CSP");
  response = await call("GET", "/account.js");
  check(response.status === 200 && response.headers.get("Content-Security-Policy"), "script served");
  response = await call("GET", "/wrangler.jsonc");
  check(response.status === 404, "only the page's files are served", response.status);

  // Signing up on the page, confirming the address from the email, then signing in.
  const email = `test-${randomUUID().slice(0, 8)}@example.com`;
  const password = "correct-horse";
  const browser = new Map();
  response = await call("GET", "/v1/auth/start?client=web", { cookies: browser });
  check(response.status === 303 && response.headers.get("Location") === "/account?login=web", "web login start", [response.headers.get("Location"), [...response.headers]]);
  response = await call("POST", "/v1/auth/register", { body: { email, password, language: "it" }, cookies: browser });
  check(response.status === 200 && response.data.verify === true, "register", response.data);
  check(lastEmail()?.to?.[0] === email && lastEmail().subject.startsWith("Conferma"), "confirmation email", lastEmail());
  const stored = sql(`SELECT password_hash FROM accounts WHERE email_normalized = '${email}'`)[0]?.password_hash ?? "";
  // Cloudflare's Web Crypto refuses more than 100,000 PBKDF2 iterations (a local copy doesn't).
  check(/^pbkdf2-sha256\$100000\$[A-Za-z0-9_-]{43}$/.test(stored), "password stored with its iterations", stored.slice(0, 22));
  response = await call("POST", "/v1/auth/login", { body: { email, password }, cookies: browser });
  check(response.status === 403 && response.data.error === "email_not_verified", "unconfirmed address refused", response.data);
  const verifyLink = new URL(lastEmail()?.text?.match(/https:\/\/\S+/)?.[0] ?? "invalid:");
  check(verifyLink.pathname === "/v1/auth/verify", "confirmation link", verifyLink.href);
  response = await call("GET", verifyLink.pathname + verifyLink.search);
  check(response.status === 303 && response.headers.get("Location") === "/account?verify=success", "address confirmed", response.status);
  for (const weak of ["sh0rt!", "longenough1", "only letters and spaces"]) {
    response = await call("POST", "/v1/auth/register", { body: { email: `weak-${randomUUID().slice(0, 8)}@example.com`, password: weak }, cookies: browser });
    check(response.status === 400 && response.data.error === "weak_password", `weak password refused (${weak})`, response.data);
  }
  response = await call("POST", "/v1/auth/login", { body: { email, password: "wrong password!!" }, cookies: browser });
  check(response.status === 401, "wrong password refused", response.status);
  response = await call("POST", "/v1/auth/login", { body: { email, password }, cookies: browser, origin: "https://evil.test" });
  check(response.status === 403, "login from another origin refused", response.status);
  response = await call("POST", "/v1/auth/login", { body: { email: email.toUpperCase(), password }, cookies: browser });
  check(response.status === 200 && response.data.redirect === "/account", "web login", response.data);
  check(browser.has("__Host-seaglass-session"), "session cookie set");

  response = await call("GET", "/v1/account", { cookies: browser });
  check(response.status === 200 && response.data.email === email && response.data.emailVerified === true, "account", response.data);
  check(response.data.membership?.available === true && response.data.membership.linked === false &&
    response.data.membership.joinURL === "https://www.patreon.com/seaglass", "membership", response.data.membership);
  const accountId = response.data.id;

  // The profile, edited on the page.
  response = await call("PUT", "/v1/sync/profile/profile", {
    cookies: browser, body: { revision: 0, operationId: randomUUID(), data: { firstName: " Ada ", lastName: "Lovelace" } },
  });
  check(response.status === 200 && response.data.revision === 1 && response.data.data.firstName === "Ada", "profile saved", response.data);
  response = await call("PUT", "/v1/sync/profile/profile", {
    cookies: browser, origin: null, body: { revision: 1, operationId: randomUUID(), data: { firstName: "Eve" } },
  });
  check(response.status === 403, "cookie write without Origin refused", response.status);
  response = await call("PUT", "/v1/sync/profile/profile", {
    cookies: browser, body: { revision: 0, operationId: randomUUID(), data: { firstName: "Eve" } },
  });
  check(response.status === 409 && response.data.current?.data?.firstName === "Ada", "stale profile refused", response.data);

  // The app's sign-in: the page, then the code exchanged with the verifier.
  const verifier = base64url(randomBytes(32));
  const challenge = base64url(createHash("sha256").update(verifier).digest());
  const appState = base64url(randomBytes(32));
  const appBrowser = new Map();
  response = await call("GET", `/v1/auth/start?challenge=${challenge}&state=${appState}`, { cookies: appBrowser });
  check(response.status === 303 && response.headers.get("Location") === "/account?login=app", "app login start", response.status);
  response = await call("POST", "/v1/auth/login", { body: { email, password }, cookies: appBrowser });
  const callback = new URL(response.data?.redirect ?? "invalid:");
  check(callback.protocol === "com.onda.player.auth:" && callback.searchParams.get("state") === appState, "app callback", response.data);
  response = await call("POST", "/v1/auth/exchange", { body: { code: callback.searchParams.get("code"), verifier: base64url(randomBytes(32)) } });
  check(response.status === 401, "exchange with the wrong verifier refused", response.status);
  response = await call("GET", `/v1/auth/start?challenge=${challenge}&state=${appState}`, { cookies: appBrowser });
  response = await call("POST", "/v1/auth/login", { body: { email, password }, cookies: appBrowser });
  const code = new URL(response.data.redirect).searchParams.get("code");
  response = await call("POST", "/v1/auth/exchange", { body: { code, verifier } });
  check(response.status === 200 && response.data.accountId === accountId && typeof response.data.token === "string", "exchange", response.data);
  const token = response.data.token;
  response = await call("POST", "/v1/auth/exchange", { body: { code, verifier } });
  check(response.status === 401, "a code works once", response.status);

  // The app's library.
  const track = { id: "yt:dQw4w9WgXcQ", videoId: "dQw4w9WgXcQ", title: "Song", artist: "Artist", primaryArtist: "Artist", duration: 213 };
  const library = { liked: [track], playlists: [{ id: randomUUID(), title: "Mix", tracks: [track] }], history: [track] };
  response = await call("PUT", "/v1/sync/library/library", { bearer: token, origin: null, body: { revision: 0, operationId: randomUUID(), data: library } });
  check(response.status === 200 && response.data.revision === 1, "library pushed", response.data);
  response = await call("PUT", "/v1/sync/library/library", { bearer: token, origin: null, body: { revision: 0, operationId: randomUUID(), data: library } });
  check(response.status === 409 && response.data.current?.revision === 1, "stale library refused", response.data);
  response = await call("PUT", "/v1/sync/preferences/" + randomUUID(), {
    bearer: token, origin: null, body: { revision: 0, operationId: randomUUID(), data: { values: { "player.crossfade": 6, "eq.preset": "rock" } } },
  });
  check(response.status === 200, "preferences pushed", response.data);
  const withPreferences = { ...library, preferences: { "playback.crossfade": 6, "audio.spatial": true, "theme.accent": "blue" } };
  response = await call("PUT", "/v1/sync/library/library", { bearer: token, origin: null, body: { revision: 1, operationId: randomUUID(), data: withPreferences } });
  check(response.status === 200 && response.data.revision === 2 && response.data.data.preferences?.["audio.spatial"] === true,
    "library with preferences pushed", response.data);
  response = await call("PUT", "/v1/sync/library/library", {
    bearer: token, origin: null, body: { revision: 2, operationId: randomUUID(), data: { ...library, preferences: { "bad key!": 1 } } },
  });
  check(response.status === 400, "invalid preferences refused", response.status);
  response = await call("GET", "/v1/sync/library", { bearer: token });
  check(response.data.record?.data?.playlists?.[0]?.title === "Mix" && response.data.record.revision === 2, "library pulled", response.data);

  // A session in use is renewed past half its life.
  sql(`UPDATE sessions SET expires_at = strftime('%s', 'now') + 3600 WHERE account_id = '${accountId}'`);
  response = await call("GET", "/v1/account", { bearer: token });
  const tokenHash = createHash("sha256").update(token).digest("base64url");
  const renewed = sql(`SELECT expires_at - strftime('%s', 'now') AS left FROM sessions WHERE token_hash = '${tokenHash}'`)[0];
  check(response.status === 200 && renewed.left > 29 * 86_400 - 60, "session renewed", renewed);
  response = await call("GET", "/v1/account", { bearer: token });
  check(response.data.records?.playlist === 1 && response.data.records?.favorites === 1 && response.data.syncedAt > 0 &&
    response.data.profile?.lastName === "Lovelace", "account counts", response.data);

  // The app opens the page signed in: a link that works once.
  response = await call("POST", "/v1/auth/web-link", { bearer: token, origin: null, body: { view: "premium" } });
  const webLink = new URL(response.data?.url ?? "invalid:");
  check(response.status === 200 && webLink.pathname === "/v1/auth/web" && webLink.searchParams.get("view") === "premium",
    "web link made", response.data);
  const linkedBrowser = new Map();
  response = await call("GET", webLink.pathname + webLink.search, { cookies: linkedBrowser });
  check(response.status === 303 && response.headers.get("Location") === "/account?view=premium" &&
    linkedBrowser.has("__Host-seaglass-session"), "web link signs the browser in", response.status);
  response = await call("GET", "/v1/account", { cookies: linkedBrowser });
  check(response.status === 200 && response.data.id === accountId, "the browser is in the account", response.data);
  const replay = new Map();
  response = await call("GET", webLink.pathname + webLink.search, { cookies: replay });
  check(response.status === 303 && !replay.has("__Host-seaglass-session"), "a web link works once", response.status);
  response = await call("POST", "/v1/auth/web-link", { cookies: browser, body: {} });
  check(response.status === 403, "only the app makes web links", response.status);

  // Patreon: the page's link starts at Patreon, and comes back only to the browser that started it.
  response = await call("POST", "/v1/patreon/connect", { cookies: browser, body: {} });
  const authorize = new URL(response.data?.redirect ?? "invalid:");
  check(authorize.origin === "https://www.patreon.com" && authorize.searchParams.get("redirect_uri") === origin + "/v1/patreon/callback",
    "patreon authorize", response.data);
  response = await call("GET", `/v1/patreon/callback?state=${authorize.searchParams.get("state")}&code=abc`);
  check(response.status === 303 && response.headers.get("Location") === "/account?patreon=failed", "callback without the session refused");

  sql(`INSERT INTO patreon_links (account_id, patreon_user_id, patron_status, entitled_cents, linked_at, updated_at)
    VALUES ('${accountId}', '987654', NULL, 0, 1, 1)`);
  const event = JSON.stringify({
    data: {
      type: "member", id: "m-1",
      attributes: { patron_status: "active_patron", currently_entitled_amount_cents: 500 },
      relationships: { user: { data: { id: "987654", type: "user" } }, campaign: { data: { id: "4242", type: "campaign" } } },
    },
  });
  const signature = createHmac("md5", webhookSecret).update(event).digest("hex");
  response = await call("POST", "/v1/patreon/webhook", {
    raw: true, body: event, origin: null, headers: { "X-Patreon-Event": "members:pledge:create", "X-Patreon-Signature": "0".repeat(32) },
  });
  check(response.status === 401, "unsigned webhook refused", response.status);
  response = await call("POST", "/v1/patreon/webhook", {
    raw: true, body: event, origin: null, headers: { "X-Patreon-Event": "members:pledge:create", "X-Patreon-Signature": signature },
  });
  check(response.status === 200 && response.data.accepted, "webhook accepted", response.data);
  response = await call("GET", "/v1/premium", { bearer: token });
  check(response.data.premium === true && response.data.entitledCents === 500, "premium", response.data);
  response = await call("POST", "/v1/patreon/webhook", {
    raw: true, body: event, origin: null, headers: { "X-Patreon-Event": "members:delete", "X-Patreon-Signature": signature },
  });
  response = await call("GET", "/v1/premium", { bearer: token });
  check(response.data.premium === false && response.data.status === "former_patron", "membership ended", response.data);
  response = await call("POST", "/v1/patreon/disconnect", { cookies: browser, body: {} });
  check(response.status === 204, "patreon unlinked", response.status);
  sql(`UPDATE accounts SET premium_lifetime = 1 WHERE id = '${accountId}'`);
  response = await call("GET", "/v1/premium", { bearer: token });
  check(response.data.premium === true && response.data.lifetime === true && response.data.linked === false,
    "premium for life without Patreon", response.data);
  sql(`UPDATE accounts SET premium_lifetime = 0 WHERE id = '${accountId}'`);

  // A new password ends the other sessions (the app's), not this one.
  response = await call("POST", "/v1/account/password", { cookies: browser, body: { current: "wrong password!!", password: "another pass!" } });
  check(response.status === 401, "password change needs the current one", response.status);
  response = await call("POST", "/v1/account/password", { cookies: browser, body: { current: password, password: "another pass!" } });
  check(response.status === 200, "password changed", response.data);
  response = await call("GET", "/v1/account", { bearer: token });
  check(response.status === 401, "the app was signed out", response.status);
  response = await call("GET", "/v1/account", { cookies: browser });
  check(response.status === 200, "the page stayed signed in", response.status);

  // A forgotten password: a six-digit code by email, five tries, every session ends. From
  // another address: sign-in requests are limited to 20 a minute for each.
  const fromElsewhere = { "CF-Connecting-IP": "203.0.113.7" };
  const sent = emails.length;
  response = await call("POST", "/v1/auth/reset/request", { body: { email, language: "en" }, headers: fromElsewhere });
  const resetCode = lastEmail()?.text?.match(/\b\d{6}\b/)?.[0];
  check(response.status === 200 && emails.length === sent + 1 && resetCode && lastEmail().subject.includes("code"), "reset code sent", lastEmail());
  response = await call("POST", "/v1/auth/reset/request", { body: { email: "nobody@example.com" }, headers: fromElsewhere });
  check(response.status === 200 && emails.length === sent + 1, "no email for an unknown address, same answer", response.data);
  response = await call("POST", "/v1/auth/reset/request", { body: { email }, headers: fromElsewhere });
  check(response.status === 200 && emails.length === sent + 1, "one code a minute", emails.length);
  const wrongCode = resetCode === "000000" ? "111111" : "000000";
  response = await call("POST", "/v1/auth/reset", { body: { email, code: wrongCode, password: "reset pass#1" }, headers: fromElsewhere });
  check(response.status === 400 && response.data.error === "invalid_reset", "wrong code refused", response.data);
  response = await call("POST", "/v1/auth/reset", { body: { email, code: resetCode, password: "reset pass#1" }, headers: fromElsewhere });
  check(response.status === 200, "password reset", response.data);
  response = await call("GET", "/v1/account", { cookies: browser });
  check(response.status === 401, "a reset signs out everywhere", response.status);
  response = await call("POST", "/v1/auth/reset", { body: { email, code: resetCode, password: "reset pass#1" }, headers: fromElsewhere });
  check(response.status === 400, "a code works once", response.status);
  sql(`UPDATE email_tokens SET created_at = created_at - 120`);
  response = await call("POST", "/v1/auth/reset/request", { body: { email }, headers: fromElsewhere });
  const secondCode = lastEmail()?.text?.match(/\b\d{6}\b/)?.[0];
  const otherCode = secondCode === "000000" ? "111111" : "000000";
  for (let attempt = 1; attempt <= 4; attempt += 1) {
    response = await call("POST", "/v1/auth/reset", { body: { email, code: otherCode, password: "yet another?" }, headers: fromElsewhere });
  }
  check(response.status === 400 && response.data.error === "invalid_reset", "four wrong codes", response.data);
  response = await call("POST", "/v1/auth/reset", { body: { email, code: otherCode, password: "yet another?" }, headers: fromElsewhere });
  check(response.status === 400 && response.data.error === "too_many_attempts", "the fifth ends the code", response.data);
  response = await call("POST", "/v1/auth/reset", { body: { email, code: secondCode, password: "yet another?" }, headers: fromElsewhere });
  check(response.status === 400, "an ended code doesn't work", response.data);

  // Signing in with the reset password, signing out everywhere, deleting the account (with
  // everything that went with it).
  response = await call("GET", "/v1/auth/start?client=web", { cookies: browser });
  response = await call("POST", "/v1/auth/login", { body: { email, password: "reset pass#1" }, cookies: browser });
  check(response.status === 200, "login with the reset password", response.data);
  response = await call("DELETE", "/v1/sessions", { cookies: browser });
  check(response.status === 204 && !browser.has("__Host-seaglass-session"), "signed out everywhere", response.status);
  response = await call("GET", "/v1/auth/start?client=web", { cookies: browser });
  response = await call("POST", "/v1/auth/login", { body: { email, password: "reset pass#1" }, cookies: browser });
  check(response.status === 200, "login again", response.data);
  response = await call("DELETE", "/v1/account", { cookies: browser, body: { confirm: "yes" } });
  check(response.status === 400, "deletion needs the confirmation", response.status);
  response = await call("DELETE", "/v1/account", { cookies: browser, body: { confirm: "ELIMINA IL MIO ACCOUNT" } });
  check(response.status === 204, "account deleted", response.status);
  const left = sql(`SELECT (SELECT COUNT(*) FROM sync_records WHERE account_id = '${accountId}') AS records,
    (SELECT COUNT(*) FROM sessions WHERE account_id = '${accountId}') AS sessions,
    (SELECT COUNT(*) FROM patreon_links WHERE account_id = '${accountId}') AS links`)[0];
  check(left.records === 0 && left.sessions === 0 && left.links === 0, "nothing left behind", left);
} catch (error) {
  failures += 1;
  console.error("✗ crashed:", error);
} finally {
  await worker.dispose();
  resend.close();
  rmSync(state, { recursive: true, force: true });
}

console.log(failures ? `${failures} failed, ${passed} passed` : `All ${passed} checks passed`);
process.exit(failures ? 1 : 0);
