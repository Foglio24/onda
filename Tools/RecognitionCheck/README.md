`run.sh` is offline. It checks request/response handling, operation cancellation and Apple's local
signature generation. It does not request microphone access or contact a recognition service.

`reference.sig` is the public fingerprint from ShazamIO's `test_recognize_file.yaml`, commit
`3578d409e647843d94492bfdccb39dcdc7983222`, licensed MIT, copyright 2021 dotX12:
https://github.com/shazamio/ShazamIO/blob/3578d409e647843d94492bfdccb39dcdc7983222/tests/cassettes/test_recognize/test_recognize_file.yaml

`live.sh` is an explicitly manual probe. It generates a real native fingerprint from the public
audio example at https://audd.tech/example.mp3, then sends exactly one request to the community
Shazam endpoint. No AudD API, account, key or app impersonation is involved. This is not a supported
Apple API; errors and rate limits stop the probe without retrying.

The live fixture is a 5.304 s excerpt of **Everybody Wants To Rule The World**, by **Tears for Fears**,
with SHA-256 `86544a7dfb3b8486ae648fbcf2a63a843d423d5f602e25b24fbf121f5b86f2b6`.
The script checks that digest before sending its fingerprint; an extended-version catalog match
is accepted if the title and artist still identify this recording.
