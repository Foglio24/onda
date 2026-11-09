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

- **No server, no account, no tracking.** Seaglass has no server or account of its own and
  contains no analytics or tracking. The library, playlists, downloads, listening history and
  settings stay on the device.
- **Network.** The apps talk only to:
  - YouTube Music (`music.youtube.com`, and `www.youtube.com` and Google's media hosts for
    streams);
  - LRCLIB (`lrclib.net`) for lyrics;
  - Last.fm (`ws.audioscrobbler.com`, `www.last.fm`), only when the user connects it with their
    own API key;
  - Spotify's and Apple Music's public pages (`open.spotify.com`, `music.apple.com` and their
    short links), when the user imports a playlist from a link;
  - the GitHub API, to check for updates.
  - Shazam (`amp.shazam.com`), only when the user starts song recognition on iPhone, iPad or
    Mac. Only a locally generated audio fingerprint is sent, not the recorded audio. Artwork
    and optional catalog links in the response are accepted only over HTTPS.
- **Last.fm credentials.** On iOS the Last.fm API secret and session key are kept in the
  Keychain; on a Mac, in the Mac's login keychain (the app is signed ad hoc, without the
  entitlements the iOS keychain needs there).
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
- Credentials the user enters (Last.fm) go in the Keychain on iOS (the login keychain on a Mac),
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
