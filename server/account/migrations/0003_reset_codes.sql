-- Password resets by a six-digit code sent by email: wrong codes are counted, and after five the
-- code stops working (a new one has to be asked for).
ALTER TABLE email_tokens ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;
