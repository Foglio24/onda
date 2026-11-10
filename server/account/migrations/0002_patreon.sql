-- Patreon instead of a subscription of our own: an account links its Patreon membership to
-- Seaglass's campaign, and Patreon's webhooks keep its status current. No Patreon token is kept.

CREATE TABLE patreon_links (
  account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  patreon_user_id TEXT NOT NULL UNIQUE,
  -- 'active_patron', 'declined_patron', 'former_patron', or NULL (a follower, or not a member).
  patron_status TEXT,
  entitled_cents INTEGER NOT NULL DEFAULT 0,
  linked_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- One Patreon sign-in started from the account page, for ten minutes.
CREATE TABLE patreon_states (
  state_hash TEXT PRIMARY KEY NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL
);
CREATE INDEX patreon_states_expiry ON patreon_states(expires_at);
