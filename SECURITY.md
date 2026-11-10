# Security

## Supported versions

Security fixes go into the latest release of each app: the newest `vX.Y.Z` release for iPhone and
iPad, and the newest `android-vX.Y.Z` release for Android.

## Reporting a vulnerability

Please report it privately, through
[GitHub's private vulnerability reporting](https://github.com/Foglio24/onda/security/advisories/new).
Don't open a public issue. Include the version, the device and steps to reproduce it.

In scope:

- the two apps;
- this repository's workflows;
- the published IPA and APKs;
- the AltStore source.

Out of scope:

- YouTube Music, Last.fm, LRCLIB and GitHub themselves;
- sideloading tools;
- problems that need a jailbroken or rooted device.

## How Seaglass handles data

- **An optional account, no tracking.** Seaglass contains no analytics or tracking. Without an
  account, the library, playlists, downloads, listening history and settings stay on the device.
  On iPhone, iPad and Mac the user can sign in to a Seaglass account (the service in
  `server/account`, on Cloudflare): liked songs, playlists (name and songs), the listening
  history and some listening preferences are then kept on it and synced between devices.
  Downloads, playlist covers and Mixes stay on each device. The account is managed on its web
  page (name, password, the Premium subscription on Patreon, deleting it, downloading its data);
  deleting it deletes everything synced at once.
- **Network.** The apps talk only to:
  - YouTube Music (`music.youtube.com`, and `www.youtube.com` and Google's media hosts for
    streams);
  - LRCLIB (`lrclib.net`) for lyrics;
  - Last.fm (`ws.audioscrobbler.com`, `www.last.fm`), only when the user connects it with their
    own API key;
  - Spotify's and Apple Music's public pages (`open.spotify.com`, `music.apple.com` and their
    short links), when the user imports a playlist from a link;
  - the GitHub API, to check for updates;
  - the Seaglass account service (`account.<domain>`, set at build time), only when the user
    signs in.
  - Shazam (`amp.shazam.com`), only when the user starts song recognition on iPhone, iPad or
    Mac. Only a locally generated audio fingerprint is sent, not the recorded audio. Artwork
    and optional catalog links in the response are accepted only over HTTPS.
  - the user's own OpenSubsonic server (Navidrome and others), only when they set it up in
    Settings › Audio › Lossless, and only over HTTPS: searches for the songs that play, and
    their original files. Seaglass ships no lossless service, server or credentials, and never
    uses third-party relays of paid streaming services.
- **Last.fm credentials.** On iOS the Last.fm API secret and session key are kept in the
  Keychain; on a Mac, in the Mac's login keychain (the app is signed ad hoc, without the
  entitlements the iOS keychain needs there).
- **Account sign-in.** The app signs in through the account page in a private sign-in sheet
  (`ASWebAuthenticationSession`, never sharing the browser's cookies). The page returns a
  one-time code to the app's callback, which only the verifier the app generated can exchange
  (as PKCE). The resulting session token is kept like Last.fm's credentials, in the Keychain.
  The service stores passwords as PBKDF2-SHA256 hashes with a salt per account, and sessions,
  codes and email links only as SHA-256 hashes. Patreon's tokens are used once and not kept.
  The address-confirmation links and password-reset codes are emailed through Resend (or
  Cloudflare's Email Service); a reset code lasts 15 minutes and five tries.
- **Lyrics translation.** It runs on the device: Apple's Translation framework on iOS, ML Kit on
  Android.
- **Song recognition.** The microphone is requested only after a tap on the recognition control.
  A short recording stays in the app's private temporary folder and is deleted after generating
  its fingerprint, on cancellation and on errors. Capturing stops on dismissal, backgrounding,
  interruption or app termination. There is no continuous or background listening, account,
  shared API credential or paid provider. The community Shazam endpoint is unofficial; refusals
  and rate limits stop the request, without client rotation or automatic retries.

## Security review guidelines

Treat a change that breaks any of these as **P0** (secrets, updates) or **P1** (everything else).

### Secrets

- Never commit private keys, keystores (`.jks`, `.p12`, `.keystore`), API keys, tokens or
  passwords. Signing keys don't go in `android-builds` or any other branch either.
- The only key material in the repository is the public certificate
  `android/signing/seaglass-cert.pem`. The Android signing key lives in the
  `ANDROID_SIGNING_KEY` secret.
- Credentials the user enters (Last.fm, their OpenSubsonic server's password) and the account's
  session token go in the Keychain on iOS (the login keychain on a Mac); the OpenSubsonic
  password itself never travels (each request carries a salted token),
  never in `UserDefaults`, files in Documents, logs or diagnostics. The same applies on Android when Last.fm arrives:
  encrypted storage, never plain preferences or logs.

### Updates

- The iOS updater reads only `api.github.com/repos/Foglio24/onda`, and the IPA it downloads is
  that release's own asset. The Android updater reads only that repository's `android-v*`
  releases and hands the APK's link to the browser.
- The Mac updater (`AppUpdater.updateMac`, with the AppKit plug-in in `Mac/Bridge`) installs
  updates itself. It downloads only the latest release's own `Seaglass-mac.zip`, from
  `https://github.com/Foglio24/onda/releases/download/`. The file's size and SHA-256 must match
  what the GitHub API gives for that asset. Once unzipped, the app must have Seaglass's bundle
  identifier and the release's version, and pass `codesign --verify --deep --strict`. Only then
  does it replace the app, and it is never run before that. Don't drop or loosen any of these
  checks.
- Never point any updater at another host, mirror or repository, and never install or run
  downloaded code any other way.
- APKs are signed with the key whose certificate is `android/signing/seaglass-cert.pem`. The
  Android workflow checks that certificate and the version before publishing. Don't weaken or
  skip that check, and don't publish an APK signed with another key: it couldn't update the
  installed app.

### Network

- HTTPS only:
  - no App Transport Security exceptions on iOS;
  - no cleartext traffic and no `networkSecurityConfig` that allows it on Android;
  - no custom trust managers, hostname verifiers or certificate pinning bypasses.
- Logs and the diagnostics the user can share must not contain credentials, Last.fm session
  keys, YouTube `visitorData` or full stream URLs (they carry the device's IP address).

### Untrusted input

Everything that comes from the network or from the user's files is untrusted:

- InnerTube responses;
- lyrics;
- imported playlist files and links;
- links shared to the app (`music.youtube.com` on Android);
- GitHub release data.

Parse it defensively: no crashes on unexpected values, sizes bounded before reading, no
unbounded recursion.

When an ID or a title from such input is used in a file name or path (downloads, cached
analyses, exported files), it must be validated, so `..` or `/` can never leave the app's
folder. For example, a YouTube video ID matches `[A-Za-z0-9_-]{11}`.

### Android components

- Exported components stay as they are:
  - the launcher activity with its `music.youtube.com` link filter;
  - the Media3 `PlaybackService`.
- New components are `exported="false"` unless another app must reach them.
- `PendingIntent`s are immutable unless they must be mutable.
- Intent extras (including the CI `scene` extras) may only navigate and start playback. They
  must never delete data, change credentials, or read or write files outside the app.

### Account service (`server/account`)

- Passwords are hashed with PBKDF2-SHA256 and a salt per account. Session tokens, sign-in codes,
  Patreon states and email links are stored only as SHA-256 hashes; none of them is logged.
- The page's session cookie stays `__Host-`, `HttpOnly`, `Secure` and `SameSite=Lax`, and every
  write made with it checks that the request comes from the page's own origin.
- The app's sign-in ends with a one-time code bound to the app's verifier. The callback is
  `com.onda.player.auth:/callback` and nothing else.
- The page keeps its Content-Security-Policy (only its own scripts and styles, no framing) and
  builds every user-supplied text with `textContent`, never `innerHTML`.
- "Manage account" opens the page signed in through a link the app's session asks for: it works
  once, within a minute, and only an app session (a Bearer token) can make one.
- A password-reset code is six digits: it expires in 15 minutes, stops after five wrong tries,
  and an account gets at most one a minute. Asking for one answers the same whether the address
  has an account or not.
- Patreon's webhook is accepted only with a valid `X-Patreon-Signature`. Linking Patreon only
  finishes in the browser, signed in to the account, that started it.
- Deleting the account deletes everything synced with it at once. Sync never deletes anything
  on a device except what the user deleted on another device (see `LibraryMerge`).
- Cloudflare and Patreon credentials are GitHub secrets, given to the deploy steps that use them.

### iOS files

- `UIFileSharingEnabled` shows the app's Documents folder in the Files app. Don't put
  credentials or private state there.

### YouTube

- Seaglass uses YouTube Music as a client does. Don't add code to get around YouTube's
  protections: bot checks, attestation or proof-of-origin tokens, rate limits, or rotating
  clients or identities after a refusal.
- Don't add DRM circumvention.

### Workflows and dependencies

- Workflows keep the smallest `permissions` they need. Secrets are passed only to the steps that
  use them and are never printed.
- No `pull_request_target` workflow checks out or runs a pull request's code.
- Third-party actions come from known publishers, with a version.
- Files downloaded during a build (models, tools) come from their official source over HTTPS.
- New dependencies are pinned to a version and listed in `THIRD_PARTY_NOTICES.md` with their
  license.
