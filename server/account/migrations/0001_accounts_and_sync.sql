-- Accounts, their sessions and logins, and what they sync. The same tables as the staging
-- database Codex set up (its 0001, 0003 and 0004 migrations), without Stripe's billing.

CREATE TABLE accounts (
  id TEXT PRIMARY KEY NOT NULL,
  -- Always 'seaglass' and the normalized email: kept from an earlier sign-in design.
  oidc_issuer TEXT NOT NULL,
  oidc_subject TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  sync_seq INTEGER NOT NULL DEFAULT 0,
  email TEXT,
  email_normalized TEXT,
  password_salt TEXT,
  password_hash TEXT,
  email_verified_at INTEGER,
  UNIQUE (oidc_issuer, oidc_subject)
);
CREATE UNIQUE INDEX accounts_email_normalized ON accounts(email_normalized) WHERE email_normalized IS NOT NULL;

CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL
);
CREATE INDEX sessions_account ON sessions(account_id);
CREATE INDEX sessions_expiry ON sessions(expires_at);

CREATE TABLE login_attempts (
  state_hash TEXT PRIMARY KEY NOT NULL,
  nonce TEXT NOT NULL,
  provider_verifier TEXT NOT NULL,
  app_challenge TEXT NOT NULL,
  app_state TEXT NOT NULL,
  client TEXT NOT NULL DEFAULT 'native' CHECK (client IN ('native', 'web')),
  expires_at INTEGER NOT NULL
);
CREATE INDEX login_attempts_expiry ON login_attempts(expires_at);

CREATE TABLE login_codes (
  code_hash TEXT PRIMARY KEY NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  app_challenge TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX login_codes_account ON login_codes(account_id);
CREATE INDEX login_codes_expiry ON login_codes(expires_at);

CREATE TABLE email_tokens (
  token_hash TEXT PRIMARY KEY NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  purpose TEXT NOT NULL CHECK (purpose IN ('verify', 'reset')),
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX email_tokens_expiry ON email_tokens(expires_at);

CREATE TABLE sync_records (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('profile', 'playlist', 'history', 'favorites', 'preferences', 'library')),
  record_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK (revision > 0),
  seq INTEGER NOT NULL,
  operation_id TEXT NOT NULL,
  payload TEXT CHECK (payload IS NULL OR json_valid(payload)),
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, kind, record_id)
);
CREATE INDEX sync_records_cursor ON sync_records(account_id, seq);
