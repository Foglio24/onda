import {
  authenticate, changePassword, clearSessionCookie, emailReady, exchangeLogin, loginAccount, registerAccount,
  requestPasswordReset, requestVerification, resetPassword, startLogin, verifyEmail,
} from "./auth.mjs";
import { HttpError, json, readJson, respond, unix } from "./http.mjs";
import { disconnectPatreon, finishPatreon, patreonConfigured, patreonWebhook, startPatreon, supporter } from "./patreon.mjs";
import { pullLibrary, pullSync, writeSync } from "./sync.mjs";

// Seaglass's account service: sign-in for the app and the account page, the library and
// preferences the app syncs, and the Patreon membership. Everything about the account is
// managed on the page (as on Spotify): the app only signs in, shows it and signs out.

const recordPath = /^\/v1\/sync\/(profile|playlist|history|favorites|preferences|library)\/([a-z0-9-]+)$/;
const authenticated = new Set([
  "GET /v1/account", "DELETE /v1/account", "POST /v1/account/password", "DELETE /v1/session", "DELETE /v1/sessions",
  "GET /v1/sync", "GET /v1/sync/library", "GET /v1/premium", "POST /v1/patreon/connect", "POST /v1/patreon/disconnect",
]);
const deletionPhrase = "ELIMINA IL MIO ACCOUNT";

// The page is the only HTML served: it loads nothing from elsewhere and can't be framed.
const pageHeaders = {
  "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; " +
    "connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
  "Strict-Transport-Security": "max-age=31536000",
  "X-Frame-Options": "DENY",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
};

async function asset(env, request, path) {
  const response = await env.ASSETS.fetch(new URL(path, request.url));
  if (response.status === 404) return json({ error: "not_found" }, 404);
  const headers = new Headers(response.headers);
  for (const [name, value] of Object.entries(pageHeaders)) headers.set(name, value);
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("Referrer-Policy", "no-referrer");
  // The page changes with each deploy and holds no data: revalidated, never kept stale.
  headers.set("Cache-Control", "no-cache");
  return new Response(response.body, { status: response.status, headers });
}

async function accountOverview(env, session) {
  const [{ results }, profile, library, membership] = await Promise.all([
    env.DB.prepare(`SELECT kind, COUNT(*) AS count FROM sync_records
      WHERE account_id = ? AND payload IS NOT NULL GROUP BY kind`).bind(session.accountId).all(),
    env.DB.prepare("SELECT revision, payload FROM sync_records WHERE account_id = ? AND kind = 'profile' AND record_id = 'profile'")
      .bind(session.accountId).first(),
    env.DB.prepare("SELECT payload, updated_at FROM sync_records WHERE account_id = ? AND kind = 'library' AND record_id = 'library'")
      .bind(session.accountId).first(),
    supporter(env, session.accountId),
  ]);
  const records = Object.fromEntries(results.map((row) => [row.kind, row.count]));
  if (library?.payload) {
    const snapshot = JSON.parse(library.payload);
    records.playlist = Math.max(records.playlist ?? 0, snapshot.playlists?.length ?? 0);
    records.favorites = Math.max(records.favorites ?? 0, snapshot.liked?.length ?? 0);
    records.history = Math.max(records.history ?? 0, snapshot.history?.length ?? 0);
  }
  return json({
    id: session.accountId,
    email: session.email,
    emailVerified: session.emailVerified,
    createdAt: session.createdAt,
    records,
    syncedAt: library?.updated_at ?? null,
    profile: profile?.payload ? JSON.parse(profile.payload) : null,
    profileRevision: profile?.revision ?? 0,
    membership,
  });
}

async function route(request, env) {
  const url = new URL(request.url);
  const path = request.method + " " + url.pathname;
  if (path === "GET /health") return json({ status: "ok" });
  if (path === "GET /v1/status") {
    return json({ accountLoginEnabled: true, emailEnabled: emailReady(env), patreonEnabled: patreonConfigured(env) });
  }
  if (!url.pathname.startsWith("/v1/")) {
    if (!env.ASSETS || !["GET", "HEAD"].includes(request.method)) throw new HttpError(404, "not_found");
    if (url.pathname === "/" || url.pathname === "/account") return asset(env, request, "/account.html");
    if (/^\/[a-z0-9-]+\.(css|js|svg|png)$/.test(url.pathname)) return asset(env, request, url.pathname);
    throw new HttpError(404, "not_found");
  }
  switch (path) {
    case "GET /v1/auth/start": return startLogin(request, url, env);
    case "GET /v1/auth/verify": return verifyEmail(request, url, env);
    case "POST /v1/auth/register": return registerAccount(request, env);
    case "POST /v1/auth/login": return loginAccount(request, env);
    case "POST /v1/auth/reset/request": return requestPasswordReset(request, env);
    case "POST /v1/auth/reset": return resetPassword(request, env);
    case "POST /v1/auth/verify/resend": return requestVerification(request, env);
    case "POST /v1/auth/exchange": return exchangeLogin(request, env);
    case "GET /v1/patreon/callback": {
      const session = await authenticate(request, env.DB).catch(() => null);
      return finishPatreon(url, env, session?.accountId ?? null);
    }
    case "POST /v1/patreon/webhook": return patreonWebhook(request, env);
  }
  const syncMatch = request.method === "PUT" ? recordPath.exec(url.pathname) : null;
  if (!syncMatch && !authenticated.has(path)) throw new HttpError(404, "not_found");
  const session = await authenticate(request, env.DB);
  if (syncMatch) return writeSync(request, env.DB, session.accountId, syncMatch[1], syncMatch[2]);
  switch (path) {
    case "GET /v1/sync/library": return pullLibrary(env.DB, session.accountId);
    case "GET /v1/sync": return pullSync(url, env.DB, session.accountId);
    case "GET /v1/account": return accountOverview(env, session);
    case "GET /v1/premium": return json(await supporter(env, session.accountId));
    case "POST /v1/account/password": return changePassword(request, env, session);
    case "POST /v1/patreon/connect": return startPatreon(env, session.accountId);
    case "POST /v1/patreon/disconnect": return disconnectPatreon(env, session.accountId);
    case "DELETE /v1/account": {
      const body = await readJson(request);
      if (body.confirm !== deletionPhrase) throw new HttpError(400, "confirmation_required");
      // Everything else goes with the account (ON DELETE CASCADE): sessions, synced data, Patreon link.
      const deleted = await env.DB.prepare("DELETE FROM accounts WHERE id = ? RETURNING id").bind(session.accountId).first();
      if (!deleted) throw new HttpError(404, "account_not_found");
      const response = respond(null, 204);
      response.headers.append("Set-Cookie", clearSessionCookie());
      return response;
    }
    case "DELETE /v1/sessions": {
      // Sign out everywhere: the app on every device and every browser, this one included.
      await env.DB.prepare("DELETE FROM sessions WHERE account_id = ?").bind(session.accountId).run();
      const response = respond(null, 204);
      if (!request.headers.has("Authorization")) response.headers.append("Set-Cookie", clearSessionCookie());
      return response;
    }
  }
  // DELETE /v1/session: this device only.
  await env.DB.prepare("DELETE FROM sessions WHERE token_hash = ?").bind(session.tokenHash).run();
  const response = respond(null, 204);
  if (!request.headers.has("Authorization")) response.headers.append("Set-Cookie", clearSessionCookie());
  return response;
}

export default {
  async fetch(request, env) {
    try {
      return await route(request, env);
    } catch (error) {
      if (error instanceof HttpError) return json({ error: error.code }, error.status);
      console.error(error);
      return json({ error: "internal_error" }, 500);
    }
  },

  async scheduled(_event, env) {
    const now = unix();
    await env.DB.batch([
      env.DB.prepare("DELETE FROM login_attempts WHERE expires_at <= ?").bind(now),
      env.DB.prepare("DELETE FROM login_codes WHERE expires_at <= ?").bind(now),
      env.DB.prepare("DELETE FROM sessions WHERE expires_at <= ?").bind(now),
      env.DB.prepare("DELETE FROM email_tokens WHERE expires_at <= ?").bind(now),
      env.DB.prepare("DELETE FROM patreon_states WHERE expires_at <= ?").bind(now),
    ]);
  },
};
