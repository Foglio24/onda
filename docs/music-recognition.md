# Song recognition

On iPhone, iPad and Mac, use the recognition button in Home or Search, then tap to listen.
Seaglass asks for microphone access the first time. Its animated panel listens to a short
sample and then shows a result, no match, or a clear error. You can stop it at any time.

The result contains the song and artist, artwork and the album and other metadata when the
catalog supplies them. You can play it, add it to favorites, download it or put it in an
existing playlist. Playback and downloads resolve the identified title and artist in YouTube
Music; the available recording can differ from the catalog result.

Recognition needs no subscription, API key or Apple Developer account. It uses Apple's local
`SHSignatureGenerator` to compute an audio fingerprint and sends only that fingerprint to the
community Shazam endpoint. The temporary audio recording is deleted and is never uploaded.
This uses local ShazamKit signature generation, not the entitlement-protected ShazamKit
catalog service. Nothing is added to your system Shazam library.

The endpoint is not an officially supported API. Network errors, service changes or rate
limits can prevent recognition; Seaglass stops the request and never rotates identities or
automatically retries a refusal. Google Song Search currently provides no documented public
API for embedding its recognition results in this app.

Microphone access is limited to the recognition panel. Closing it, stopping, leaving the app,
an audio interruption or quitting stops capture. Music is paused while listening and remains
paused afterward, so playback does not unexpectedly restart. You can change microphone access
in the system privacy settings.

Implementation references: [Apple signature generation](https://developer.apple.com/documentation/shazamkit/generating-a-signature-from-an-audio-buffer)
and [ShazamIO's community request format](https://github.com/shazamio/ShazamIO/tree/3578d409e647843d94492bfdccb39dcdc7983222).
