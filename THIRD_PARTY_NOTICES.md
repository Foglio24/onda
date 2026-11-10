# Third-party notices

Seaglass's own code is covered by [LICENSE](LICENSE). It uses, includes or talks to the following
work by others, which keeps its own licence or terms.

## Included in the app

### YouTubeKit
- **What:** Swift package that turns a YouTube video ID into audio stream URLs.
- **Source:** https://github.com/alexeichhorn/YouTubeKit
- **Licence:** MIT. Copyright (c) 2022 Alexander Eichhorn.

### UVR-MDX-NET Voc_FT (AI karaoke model)
- **What:** the vocal separation model used by the karaoke mode, and by AutoMix to find where songs
  are sung near where they meet, bundled in the IPA as a Core ML model. It is converted in CI from
  ONNX to Core ML; the weights are not changed. The Android app downloads the ONNX version itself
  from sherpa-onnx the first time karaoke is used (its checksum checked), unchanged.
- **Authors:** trained by the [Ultimate Vocal Remover](https://github.com/Anjok07/ultimatevocalremovergui)
  project (MIT), on the MDX-Net architecture by [KUIELab](https://github.com/kuielab/mdx-net) (MIT).
- **Downloaded from:** the ONNX version published by
  [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx/releases/tag/source-separation-models)
  (Apache-2.0), converted from [TRvlvr/model_repo](https://github.com/TRvlvr/model_repo/releases/tag/all_public_uvr_models).
- **Licence:** the model repository doesn't state a licence of its own. All rights in the model
  remain with its authors; it is included with credit, as the projects above redistribute it.

## Included in the Android app
All under the Apache License 2.0:
- [Jetpack Compose, AndroidX and Media3](https://developer.android.com/jetpack) (Google): the interface, the player and its notification.
- [Haze](https://github.com/chrisbanes/haze) (Chris Banes): the liquid glass and blur.
- [Coil](https://github.com/coil-kt/coil): artwork loading.
- [OkHttp](https://github.com/square/okhttp) (Square): networking.
- [Kotlin coroutines](https://github.com/Kotlin/kotlinx.coroutines) (JetBrains).

Also in the Android app, under the MIT License: [ONNX Runtime](https://github.com/microsoft/onnxruntime)
(Microsoft), which runs the karaoke's model on the phone. Its usage reporting is left out of the app.

Also in the Android app, under Google's [ML Kit terms](https://developers.google.com/ml-kit/terms):
[ML Kit](https://developers.google.com/ml-kit) on-device translation and language identification, for
the lyrics translation; each language's model is downloaded from Google the first time it's needed.

## Used at build time only (not included in the app)
- [coremltools](https://github.com/apple/coremltools) (BSD-3-Clause), [PyTorch](https://github.com/pytorch/pytorch)
  (BSD-3-Clause), [onnx2torch](https://github.com/ENOT-AutoDL/onnx2torch) (Apache-2.0),
  [ONNX](https://github.com/onnx/onnx) and [ONNX Runtime](https://github.com/microsoft/onnxruntime)
  (MIT/Apache-2.0), [NumPy](https://github.com/numpy/numpy) (BSD-3-Clause), to convert and check the karaoke model.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (MIT), to generate the Xcode project.
- [Wrangler](https://github.com/cloudflare/workers-sdk) 4.151.3 (MIT OR Apache-2.0), with its
  Miniflare and workerd, to test and deploy the account service (`server/account`).
- [JamendoLyrics](https://github.com/f90/jamendolyrics) (code MIT; each song under its own Creative
  Commons licence), downloaded by the "AutoMix on real songs" workflow to check AutoMix's voice
  detection against the timed lyrics and to render test transitions. Only the songs whose licence
  allows derivative works are mixed; the excerpts stay in that workflow's artifacts, with credits.
- [ShazamIO](https://github.com/shazamio/ShazamIO/tree/3578d409e647843d94492bfdccb39dcdc7983222)
  (MIT, copyright 2021 dotX12): one public fingerprint fixture for the offline native signature
  compatibility check. Its [license](Tools/RecognitionCheck/LICENSE.ShazamIO.txt) is retained.

## Services Seaglass connects to
Seaglass is not affiliated with, endorsed by or sponsored by any of these services. Their names and
logos are trademarks of their owners, and the music, artwork, lyrics and data they provide belong
to their respective rights holders.

- **YouTube Music / YouTube** (Google LLC): catalogue, search, radios and audio streams.
- **LRCLIB** (https://lrclib.net): synced lyrics.
- **Last.fm**: scrobbling and listening data, through each user's own API key.
- **Spotify** and **Apple Music**: public playlist pages, read only to import song titles.
- **Apple Translation**: on-device lyrics translation.
- **Shazam** (Apple): optional song recognition through an unofficial community endpoint.
  Only a locally generated audio fingerprint is sent. The request format was checked against
  [ShazamIO](https://github.com/shazamio/ShazamIO/tree/3578d409e647843d94492bfdccb39dcdc7983222)
  (MIT); the app uses Apple's local ShazamKit signature generator and does not bundle ShazamIO.
- **GitHub**: release information and downloads for the update check.
- **Cloudflare**: hosts Seaglass's own account service (Workers and D1), when the user signs in.
- **Patreon**: the Seaglass Premium subscription, linked on the account page.
