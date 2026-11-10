-- Premium that no Patreon membership grants: the creator's own account, set by hand in the
-- database (UPDATE accounts SET premium_lifetime = 1 WHERE id = ...).
ALTER TABLE accounts ADD COLUMN premium_lifetime INTEGER NOT NULL DEFAULT 0;
