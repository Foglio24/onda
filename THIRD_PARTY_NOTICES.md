# Third-party notices

Onda's own code is covered by [LICENSE](LICENSE). It uses, includes or talks to the following
work by others, which keeps its own licence or terms.

## Included in the app

### YouTubeKit
- **What:** Swift package that turns a YouTube video ID into audio stream URLs.
- **Source:** https://github.com/alexeichhorn/YouTubeKit
- **Licence:** MIT. Copyright (c) 2022 Alexander Eichhorn.

### UVR-MDX-NET Voc_FT (AI karaoke model)
- **What:** the vocal separation model used by the karaoke mode, bundled in the IPA as a Core ML
  model. It is converted in CI from ONNX to Core ML; the weights are not changed.
- **Authors:** trained by the [Ultimate Vocal Remover](https://github.com/Anjok07/ultimatevocalremovergui)
  project (MIT), on the MDX-Net architecture by [KUIELab](https://github.com/kuielab/mdx-net) (MIT).
- **Downloaded from:** the ONNX version published by
  [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx/releases/tag/source-separation-models)
  (Apache-2.0), converted from [TRvlvr/model_repo](https://github.com/TRvlvr/model_repo/releases/tag/all_public_uvr_models).
- **Licence:** the model repository doesn't state a licence of its own. All rights in the model
  remain with its authors; it is included with credit, as the projects above redistribute it.

## Used at build time only (not included in the app)
- [coremltools](https://github.com/apple/coremltools) (BSD-3-Clause), [PyTorch](https://github.com/pytorch/pytorch)
  (BSD-3-Clause), [onnx2torch](https://github.com/ENOT-AutoDL/onnx2torch) (Apache-2.0),
  [ONNX](https://github.com/onnx/onnx) and [ONNX Runtime](https://github.com/microsoft/onnxruntime)
  (MIT/Apache-2.0), [NumPy](https://github.com/numpy/numpy) (BSD-3-Clause), to convert and check the karaoke model.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (MIT), to generate the Xcode project.

## Services Onda connects to
Onda is not affiliated with, endorsed by or sponsored by any of these services. Their names and
logos are trademarks of their owners, and the music, artwork, lyrics and data they provide belong
to their respective rights holders.

- **YouTube Music / YouTube** (Google LLC): catalogue, search, radios and audio streams.
- **LRCLIB** (https://lrclib.net): synced lyrics.
- **Last.fm**: scrobbling and listening data, through each user's own API key.
- **Spotify** and **Apple Music**: public playlist pages, read only to import song titles.
- **Apple Translation**: on-device lyrics translation.
- **GitHub**: release information and downloads for the update check.
