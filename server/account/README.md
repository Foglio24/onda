# Seaglass account service

A Cloudflare Worker with a D1 database. It gives Seaglass accounts, as Spotify does:

- **The account page** (`/account`): sign up, log in, reset the password, edit the first name,
  last name and display name, change the password, get Premium (Patreon), download the data,
  sign out everywhere and delete the account. Everything about the account is managed here.
- **The app** (iPhone, iPad and Mac) signs in through the page, then only shows the account
  (name, email, plan, last sync) and signs out. It syncs the library (liked songs, playlists,
  history) and some preferences.
- **Seaglass Premium** is a Patreon membership of Seaglass's campaign, linked on the page: an
  active paid membership (at least `PREMIUM_MIN_CENTS` a month, any paid tier by default) is
  Premium. In the app it unlocks AutoMix and playlist Mixes, importing playlists from links, song
  recognition, lyrics translation, AI karaoke and Tempo. The app locks them only when the service says Premium can be
  bought (`premiumEnabled` in `/v1/status`: Patreon set up, with `PATREON_URL`).

## Layout

| Path | What it is |
| --- | --- |
| `src/index.mjs` | Routes, the page's security headers, the daily cleanup |
| `src/auth.mjs` | Accounts, passwords (PBKDF2), sessions, the app's sign-in (a code exchanged with a verifier, as PKCE) |
| `src/sync.mjs` | Synced records, with revisions: a stale write gets `409` and the current record |
| `src/patreon.mjs` | Patreon's OAuth link and its signed webhook |
| `public/` | The account page (Italian and English) |
| `migrations/` | The D1 schema |
| `scripts/cloudflare.mjs` | Finds the domain and the database for the deploy workflow and the app's build |
| `test/run.mjs` | The whole service end to end on a local copy (Miniflare) |

## Running it locally

```sh
cd server/account
npm ci
npm test                 # the end-to-end checks
npm run migrate:local    # then: npx wrangler dev --local-protocol https
```

## Deploying

`.github/workflows/account.yml` tests every change and deploys from `main`. It finds the
domain on the Cloudflare account and serves the service at **`account.<domain>`** (a Worker
custom domain: Cloudflare creates the DNS record and the certificate), creates the
`seaglass-account` D1 database the first time and applies its migrations. Without a domain it
uses `seaglass-account.<subdomain>.workers.dev`. Today it is `https://account.mystudioappweb.com`,
which `project.yml` gives the app; the app's build (`build.yml`) asks Cloudflare for the same
address and puts it in the app.

### 1. Cloudflare API token (required)

Cloudflare dashboard › My Profile › API Tokens › Create Token › Custom token, with:

- Account › **Workers Scripts** › Edit
- Account › **D1** › Edit
- Account › **Account Settings** › Read
- Zone › **Workers Routes** › Edit, Zone › **DNS** › Edit, Zone › **Zone** › Read (on the domain)

Add it to the GitHub repository as the secret **`CLOUDFLARE_API_TOKEN`**. If the token opens
more than one account, also add the variable `CLOUDFLARE_ACCOUNT_ID`. With more than one domain,
the first one alphabetically is used: set the variable `SEAGLASS_ACCOUNT_DOMAIN` (for example
`account.example.com`) to choose.

### 2. Patreon, for Premium (optional: without it Premium "is coming soon" and the app keeps every feature unlocked)

1. On <https://www.patreon.com/portal/registration/register-clients>, create a client with the
   redirect URI `https://account.<domain>/v1/patreon/callback`.
2. On <https://www.patreon.com/portal/registration/register-webhooks>, add a webhook to
   `https://account.<domain>/v1/patreon/webhook` with the `members:create`, `members:update`,
   `members:delete`, `members:pledge:create`, `members:pledge:update` and
   `members:pledge:delete` triggers.
3. In GitHub add the secrets `PATREON_CLIENT_ID`, `PATREON_CLIENT_SECRET` and
   `PATREON_WEBHOOK_SECRET` (the webhook's secret), and the variables `PATREON_URL` (the
   campaign's page, `https://www.patreon.com/<name>`), `PATREON_CAMPAIGN_ID` and, optionally,
   `PREMIUM_MIN_CENTS` (the least a tier pays a month to be Premium, in cents).
4. Run the "Account service" workflow again.

### 3. Email (optional: password reset and email confirmation)

Without it, accounts work at once, and a forgotten password goes through support (the page
says to write to `SUPPORT_EMAIL`). With it, "Forgot your password?" emails a six-digit code
(valid 15 minutes, five tries, one email a minute), and new accounts confirm their address
with a link.

The free way is [Resend](https://resend.com) (free plan: 100 emails a day, 3,000 a month):

1. Create a Resend account, add the domain (Domains › Add Domain) and let Resend add its DNS
   records to Cloudflare (or copy them into Cloudflare's DNS), then wait for "Verified".
2. Create an API key with "Sending access" and add it to GitHub as the secret `RESEND_API_KEY`.
3. Set the variable `SEAGLASS_EMAIL_FROM`, for example `Seaglass <no-reply@<domain>>`.
4. Run the "Account service" workflow again.

Without `RESEND_API_KEY`, `SEAGLASS_EMAIL_FROM` uses Cloudflare's Email Service instead, which
sends to any address only on the Workers Paid plan.

### 4. Support

`SUPPORT_EMAIL` in `wrangler.jsonc` is the address the page and the app give for help.

## Security

Passwords are hashed with PBKDF2-SHA256 (310,000 iterations) and a salt per account. Sessions,
sign-in codes, Patreon states and email links are stored as SHA-256 hashes only. The page's
session cookie is `__Host-`, `HttpOnly`, `Secure` and `SameSite=Lax`, and every write made with
it must come from the page's own origin. The app's sign-in ends with a one-time code that only
the verifier the app kept can exchange. Patreon's tokens are used once and never stored; its
webhook is accepted only with a valid signature. Sign-in requests are rate-limited per IP.
