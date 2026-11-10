import { HttpError, json, readJson, respond, unix } from "./http.mjs";

const attemptLifetime = 600;
const codeLifetime = 120;
const sessionLifetime = 30 * 86_400;
const tokenLifetime = 30 * 60;
const codeLifetimeReset = 15 * 60;
const codeAttempts = 5;
const secretPattern = /^[A-Za-z0-9_-]{43}$/;
const verifierPattern = /^[A-Za-z0-9._~-]{43,128}$/;
const attemptCookieName = "__Host-seaglass-login";
const sessionCookieName = "__Host-seaglass-session";
const appCallback = "com.onda.player.auth:/callback";
const encoder = new TextEncoder();

function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function secret() { return base64url(crypto.getRandomValues(new Uint8Array(32))); }
async function hash(value) {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value))));
}

function attemptCookie(state, proof, maxAge) {
  return `${attemptCookieName}=${state}.${proof}; Path=/; Max-Age=${maxAge}; HttpOnly; Secure; SameSite=Lax`;
}
function sessionCookie(value, maxAge) {
  return `${sessionCookieName}=${value}; Path=/; Max-Age=${maxAge}; HttpOnly; Secure; SameSite=Lax`;
}
function redirect(location, cookies = []) {
  const headers = new Headers({ Location: location });
  for (const value of Array.isArray(cookies) ? cookies : [cookies]) headers.append("Set-Cookie", value);
  return respond(null, 303, headers);
}
export function clearSessionCookie() { return sessionCookie("", 0); }

/**
 * Whether emails can be sent: through Resend (its free plan, RESEND_API_KEY) or Cloudflare's
 * Email Service (the EMAIL binding, on Workers Paid), from AUTH_EMAIL_FROM. See README.
 */
export function emailReady(env) {
  return Boolean((env.RESEND_API_KEY || env.EMAIL) && env.AUTH_EMAIL_FROM && env.AUTH_EMAIL_READY === "true");
}

function origin(env) {
  try {
    const value = new URL(env.PUBLIC_ORIGIN);
    if (value.protocol !== "https:" || value.href !== value.origin + "/") throw new Error();
    return value.origin;
  } catch { throw new HttpError(503, "auth_unconfigured"); }
}
function requireOrigin(request, env) {
  if (request.headers.get("Origin") !== origin(env)) throw new HttpError(403, "wrong_origin");
}
function browserAttempt(request) {
  const value = (request.headers.get("Cookie") ?? "").split(";").map((part) => part.trim())
    .find((part) => part.startsWith(attemptCookieName + "="))?.slice(attemptCookieName.length + 1) ?? "";
  const [state, proof, extra] = value.split(".");
  return extra === undefined && secretPattern.test(state ?? "") && secretPattern.test(proof ?? "") ? { state, proof } : null;
}
async function limited(request, env) {
  const ip = request.headers.get("CF-Connecting-IP");
  if (env.AUTH_RATE_LIMITER && ip && !(await env.AUTH_RATE_LIMITER.limit({ key: ip })).success) {
    throw new HttpError(429, "login_rate_limited");
  }
}

export async function startLogin(request, url, env) {
  origin(env);
  const appChallenge = url.searchParams.get("challenge") ?? "";
  const appState = url.searchParams.get("state") ?? "";
  const client = url.searchParams.get("client") === "web" ? "web" : "native";
  if ((client === "native" && (!secretPattern.test(appChallenge) || !secretPattern.test(appState))) ||
      (client === "web" && (appChallenge || appState))) throw new HttpError(400, "invalid_login_request");
  await limited(request, env);
  const state = secret();
  const proof = secret();
  await env.DB.prepare(`INSERT INTO login_attempts
    (state_hash, nonce, provider_verifier, app_challenge, app_state, client, expires_at)
    VALUES (?, '', '', ?, ?, ?, ?)`)
    .bind(await hash(state + proof), appChallenge, appState, client, unix() + attemptLifetime).run();
  // The page tells the app's sign-in from the browser's: the app's one ends back in the app.
  return redirect(`/account?login=${client === "native" ? "app" : "web"}`, attemptCookie(state, proof, attemptLifetime));
}

async function passwordHash(password, salt) {
  const key = await crypto.subtle.importKey("raw", encoder.encode(password), "PBKDF2", false, ["deriveBits"]);
  const saltBytes = Uint8Array.from(atob(salt.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat((4 - salt.length % 4) % 4)), (c) => c.charCodeAt(0));
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: saltBytes, iterations: 310_000 }, key, 256);
  return base64url(new Uint8Array(bits));
}
function emailAddress(value) {
  if (typeof value !== "string" || value.length > 254) throw new HttpError(400, "invalid_email");
  const email = value.trim().normalize("NFC");
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || /[\r\n]/.test(email)) throw new HttpError(400, "invalid_email");
  return { email, normalized: email.toLowerCase() };
}
function validPassword(value) {
  return typeof value === "string" && value.length >= 12 && value.length <= 128 && !/[\u0000-\u001f\u007f]/.test(value);
}
function escapeHtml(value) {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
}
async function sendEmail(env, message) {
  if (!emailReady(env)) throw new HttpError(503, "email_unconfigured");
  if (env.RESEND_API_KEY) {
    // RESEND_ENDPOINT only for the local test, which receives the emails itself.
    const response = await fetch(env.RESEND_ENDPOINT || "https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: env.AUTH_EMAIL_FROM, to: [message.to], subject: message.subject, text: message.text, html: message.html }),
    });
    if (!response.ok) throw new HttpError(502, "email_failed");
    return;
  }
  await env.EMAIL.send({ from: env.AUTH_EMAIL_FROM, ...message });
}

const emailTexts = {
  it: {
    verifySubject: "Conferma il tuo indirizzo email · Seaglass",
    verify: "Conferma il tuo indirizzo email per attivare l'account Seaglass.",
    verifyButton: "Conferma l'indirizzo",
    verifyExpiry: "Il link scade tra 30 minuti.",
    resetSubject: "Il tuo codice per reimpostare la password · Seaglass",
    reset: "Ecco il codice per scegliere una nuova password del tuo account Seaglass:",
    resetExpiry: "Inseriscilo sulla pagina dell'account. Il codice scade tra 15 minuti.",
    ignore: "Se non l'hai chiesto tu, ignora questa email: il tuo account resta com'è.",
  },
  en: {
    verifySubject: "Confirm your email address · Seaglass",
    verify: "Confirm your email address to activate your Seaglass account.",
    verifyButton: "Confirm the address",
    verifyExpiry: "The link expires in 30 minutes.",
    resetSubject: "Your code to reset your password · Seaglass",
    reset: "Here is the code to choose a new password for your Seaglass account:",
    resetExpiry: "Enter it on the account page. The code expires in 15 minutes.",
    ignore: "If you didn't ask for this, ignore this email: your account stays as it is.",
  },
};
function texts(language) { return emailTexts[language === "it" ? "it" : "en"]; }

async function sendVerification(env, email, token, language) {
  const t = texts(language);
  const url = new URL("/v1/auth/verify", origin(env));
  url.searchParams.set("token", token);
  const link = escapeHtml(url.href);
  await sendEmail(env, {
    to: email,
    subject: t.verifySubject,
    text: `${t.verify}\n\n${url.href}\n\n${t.verifyExpiry} ${t.ignore}`,
    html: `<p>${t.verify}</p><p><a href="${link}">${t.verifyButton}</a></p><p>${t.verifyExpiry} ${t.ignore}</p>`,
  });
}

async function issueVerification(env, accountId, email, language) {
  const token = secret();
  const now = unix();
  await env.DB.batch([
    env.DB.prepare("DELETE FROM email_tokens WHERE account_id = ? AND purpose = 'verify'").bind(accountId),
    env.DB.prepare("INSERT INTO email_tokens (token_hash, account_id, purpose, expires_at, created_at) VALUES (?, ?, 'verify', ?, ?)")
      .bind(await hash(token), accountId, now + tokenLifetime, now),
  ]);
  try { await sendVerification(env, email, token, language); }
  catch (error) {
    await env.DB.prepare("DELETE FROM email_tokens WHERE token_hash = ?").bind(await hash(token)).run();
    throw error;
  }
}

/** Six digits, each as likely as the others. */
function resetCode() {
  const values = new Uint32Array(1);
  do { crypto.getRandomValues(values); } while (values[0] >= 4_294_000_000);
  return String(values[0] % 1_000_000).padStart(6, "0");
}
async function codeHash(accountId, code) { return hash(`reset:${accountId}:${code}`); }

export async function registerAccount(request, env) {
  requireOrigin(request, env);
  await limited(request, env);
  const body = await readJson(request);
  const { email, normalized } = emailAddress(body.email);
  if (!validPassword(body.password)) throw new HttpError(400, "weak_password");
  const salt = secret();
  const derived = await passwordHash(body.password, salt);
  const id = crypto.randomUUID();
  const now = unix();
  // Until emails can be sent, an address can't be confirmed: the account is usable at once.
  const sendsEmail = emailReady(env);
  const created = await env.DB.prepare(`INSERT INTO accounts
    (id, oidc_issuer, oidc_subject, created_at, email, email_normalized, password_salt, password_hash, email_verified_at)
    VALUES (?, 'seaglass', ?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING RETURNING id`)
    .bind(id, normalized, now, email, normalized, salt, derived, sendsEmail ? null : now).first();
  if (created && sendsEmail) await issueVerification(env, id, email, body.language);
  return json({ accepted: true, verify: sendsEmail });
}

export async function verifyEmail(request, url, env) {
  const token = url.searchParams.get("token") ?? "";
  if (!secretPattern.test(token)) return redirect("/account?verify=invalid");
  const now = unix();
  const row = await env.DB.prepare(`DELETE FROM email_tokens WHERE token_hash = ? AND purpose = 'verify' AND expires_at > ?
    RETURNING account_id`).bind(await hash(token), now).first();
  if (!row) return redirect("/account?verify=invalid");
  await env.DB.prepare("UPDATE accounts SET email_verified_at = ? WHERE id = ?").bind(now, row.account_id).run();
  return redirect("/account?verify=success");
}

async function createAuthenticatedResponse(request, env, attempt, accountId) {
  if (attempt.client === "web") {
    const token = secret();
    const now = unix();
    await env.DB.prepare("INSERT INTO sessions (token_hash, account_id, expires_at) VALUES (?, ?, ?)")
      .bind(await hash(token), accountId, now + sessionLifetime).run();
    return json({ redirect: "/account" }, 200, { "Set-Cookie": sessionCookie(token, sessionLifetime) });
  }
  const code = secret();
  const appCode = await env.DB.prepare(`INSERT INTO login_codes (code_hash, account_id, app_challenge, expires_at)
    SELECT ?, ?, ?, ? RETURNING code_hash`).bind(await hash(code), accountId, attempt.app_challenge, unix() + codeLifetime).first();
  if (!appCode) throw new HttpError(500, "login_failed");
  const callback = new URL(appCallback);
  callback.searchParams.set("state", attempt.app_state);
  callback.searchParams.set("code", code);
  return json({ redirect: callback.href });
}

export async function loginAccount(request, env) {
  requireOrigin(request, env);
  await limited(request, env);
  const body = await readJson(request);
  const { normalized } = emailAddress(body.email);
  if (typeof body.password !== "string" || body.password.length > 128) throw new HttpError(401, "invalid_credentials");
  const attempt = browserAttempt(request);
  if (!attempt) throw new HttpError(400, "login_expired");
  const row = await env.DB.prepare(`SELECT id, password_salt, password_hash, email_verified_at FROM accounts
    WHERE email_normalized = ?`).bind(normalized).first();
  if (!row || !row.password_salt || !row.password_hash ||
      await passwordHash(body.password, row.password_salt) !== row.password_hash) throw new HttpError(401, "invalid_credentials");
  if (!row.email_verified_at) throw new HttpError(403, "email_not_verified");
  const loginAttempt = await env.DB.prepare("DELETE FROM login_attempts WHERE state_hash = ? AND expires_at > ? RETURNING *")
    .bind(await hash(attempt.state + attempt.proof), unix()).first();
  if (!loginAttempt) throw new HttpError(400, "login_expired");
  return createAuthenticatedResponse(request, env, loginAttempt, row.id);
}

/**
 * "Password dimenticata?": a six-digit code by email, valid 15 minutes and for five tries. The
 * answer is the same whether the address has an account or not.
 */
export async function requestPasswordReset(request, env) {
  requireOrigin(request, env);
  await limited(request, env);
  const body = await readJson(request);
  const { normalized } = emailAddress(body.email);
  if (!emailReady(env)) throw new HttpError(503, "email_unconfigured");
  const row = await env.DB.prepare("SELECT id, email, email_verified_at FROM accounts WHERE email_normalized = ?")
    .bind(normalized).first();
  if (!row?.email_verified_at) return json({ accepted: true });
  const now = unix();
  // At most one email a minute for an account, whoever asks.
  const recent = await env.DB.prepare(`SELECT 1 FROM email_tokens WHERE account_id = ? AND purpose = 'reset' AND created_at > ?`)
    .bind(row.id, now - 60).first();
  if (recent) return json({ accepted: true });
  const code = resetCode();
  const tokenHash = await codeHash(row.id, code);
  await env.DB.batch([
    env.DB.prepare("DELETE FROM email_tokens WHERE account_id = ? AND purpose = 'reset'").bind(row.id),
    env.DB.prepare(`INSERT INTO email_tokens (token_hash, account_id, purpose, expires_at, created_at, attempts)
      VALUES (?, ?, 'reset', ?, ?, 0)`).bind(tokenHash, row.id, now + codeLifetimeReset, now),
  ]);
  const t = texts(body.language);
  try {
    await sendEmail(env, {
      to: row.email,
      subject: t.resetSubject,
      text: `${t.reset}\n\n${code}\n\n${t.resetExpiry} ${t.ignore}`,
      html: `<p>${t.reset}</p><p style="font-size:28px;font-weight:700;letter-spacing:6px">${code}</p><p>${t.resetExpiry} ${t.ignore}</p>`,
    });
  } catch (error) {
    await env.DB.prepare("DELETE FROM email_tokens WHERE token_hash = ?").bind(tokenHash).run();
    throw error;
  }
  return json({ accepted: true });
}

/** The code from the email and a new password: every session ends, the address is confirmed. */
export async function resetPassword(request, env) {
  requireOrigin(request, env);
  await limited(request, env);
  const body = await readJson(request);
  const { normalized } = emailAddress(body.email);
  if (typeof body.code !== "string" || !/^\d{6}$/.test(body.code)) throw new HttpError(400, "invalid_reset");
  if (!validPassword(body.password)) throw new HttpError(400, "weak_password");
  const now = unix();
  const pending = await env.DB.prepare(`SELECT email_tokens.token_hash, email_tokens.attempts, accounts.id AS account_id
    FROM accounts JOIN email_tokens ON email_tokens.account_id = accounts.id AND email_tokens.purpose = 'reset'
    WHERE accounts.email_normalized = ? AND email_tokens.expires_at > ?`).bind(normalized, now).first();
  if (!pending || pending.attempts >= codeAttempts) throw new HttpError(400, "invalid_reset");
  if (await codeHash(pending.account_id, body.code) !== pending.token_hash) {
    const tries = pending.attempts + 1;
    if (tries >= codeAttempts) {
      await env.DB.prepare("DELETE FROM email_tokens WHERE token_hash = ?").bind(pending.token_hash).run();
      throw new HttpError(400, "too_many_attempts");
    }
    await env.DB.prepare("UPDATE email_tokens SET attempts = ? WHERE token_hash = ?").bind(tries, pending.token_hash).run();
    throw new HttpError(400, "invalid_reset");
  }
  const salt = secret();
  const derived = await passwordHash(body.password, salt);
  await env.DB.batch([
    env.DB.prepare(`UPDATE accounts SET password_salt = ?, password_hash = ?, email_verified_at = COALESCE(email_verified_at, ?)
      WHERE id = ?`).bind(salt, derived, now, pending.account_id),
    env.DB.prepare("DELETE FROM sessions WHERE account_id = ?").bind(pending.account_id),
    env.DB.prepare("DELETE FROM email_tokens WHERE account_id = ?").bind(pending.account_id),
  ]);
  return json({ accepted: true });
}

export async function requestVerification(request, env) {
  requireOrigin(request, env);
  await limited(request, env);
  const body = await readJson(request);
  const { normalized } = emailAddress(body.email);
  const row = await env.DB.prepare("SELECT id, email, email_verified_at FROM accounts WHERE email_normalized = ?")
    .bind(normalized).first();
  if (row && !row.email_verified_at) await issueVerification(env, row.id, row.email, body.language);
  return json({ accepted: true });
}

export async function exchangeLogin(request, env) {
  const { code, verifier } = await readJson(request);
  if (typeof code !== "string" || !secretPattern.test(code) || typeof verifier !== "string" || !verifierPattern.test(verifier)) {
    throw new HttpError(400, "invalid_exchange");
  }
  const token = secret();
  const now = unix();
  const challenge = await hash(verifier);
  const [created] = await env.DB.batch([
    env.DB.prepare(`INSERT INTO sessions (token_hash, account_id, expires_at)
      SELECT ?, account_id, ? FROM login_codes WHERE code_hash = ? AND app_challenge = ? AND expires_at > ?
      RETURNING account_id`).bind(await hash(token), now + sessionLifetime, await hash(code), challenge, now),
    env.DB.prepare("DELETE FROM login_codes WHERE code_hash = ? AND app_challenge = ?").bind(await hash(code), challenge),
  ]);
  const accountId = created.results[0]?.account_id;
  if (!accountId) throw new HttpError(401, "invalid_login_code");
  return json({ accountId, token, expiresAt: now + sessionLifetime });
}

export async function authenticate(request, db) {
  const authorization = request.headers.get("Authorization") ?? "";
  const bearer = authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
  const browserToken = (request.headers.get("Cookie") ?? "").split(";").map((part) => part.trim())
    .find((part) => part.startsWith(sessionCookieName + "="))?.slice(sessionCookieName.length + 1) ?? "";
  const token = bearer || browserToken;
  if (!secretPattern.test(token)) throw new HttpError(401, "authentication_required");
  if (!bearer && !["GET", "HEAD", "OPTIONS"].includes(request.method)) {
    const originHeader = request.headers.get("Origin");
    if (!originHeader || originHeader !== new URL(request.url).origin) throw new HttpError(403, "wrong_origin");
  }
  const tokenHash = await hash(token);
  const now = unix();
  const session = await db.prepare(`SELECT accounts.id, accounts.created_at, accounts.email, accounts.email_verified_at,
    sessions.expires_at FROM sessions JOIN accounts ON accounts.id = sessions.account_id
    WHERE token_hash = ? AND expires_at > ?`).bind(tokenHash, now).first();
  if (!session) throw new HttpError(401, "authentication_required");
  // A session in use stays signed in (as Spotify's): past half its life it is renewed, so only
  // a device unused for 30 days has to sign in again. The page's cookie keeps its own expiry.
  if (session.expires_at - now < sessionLifetime / 2) {
    await db.prepare("UPDATE sessions SET expires_at = ? WHERE token_hash = ?").bind(now + sessionLifetime, tokenHash).run();
  }
  return { accountId: session.id, createdAt: session.created_at, email: session.email, emailVerified: Boolean(session.email_verified_at), tokenHash };
}

/** The account page changes the password with the current one: every other session ends. */
export async function changePassword(request, env, session) {
  await limited(request, env);
  const { current, password } = await readJson(request);
  if (!validPassword(password)) throw new HttpError(400, "weak_password");
  const row = await env.DB.prepare("SELECT password_salt, password_hash FROM accounts WHERE id = ?").bind(session.accountId).first();
  if (typeof current !== "string" || current.length > 128 || !row?.password_salt ||
      await passwordHash(current, row.password_salt) !== row.password_hash) throw new HttpError(401, "invalid_credentials");
  const salt = secret();
  const derived = await passwordHash(password, salt);
  await env.DB.batch([
    env.DB.prepare("UPDATE accounts SET password_salt = ?, password_hash = ? WHERE id = ?").bind(salt, derived, session.accountId),
    env.DB.prepare("DELETE FROM sessions WHERE account_id = ? AND token_hash <> ?").bind(session.accountId, session.tokenHash),
    env.DB.prepare("DELETE FROM email_tokens WHERE account_id = ? AND purpose = 'reset'").bind(session.accountId),
  ]);
  return json({ accepted: true });
}
