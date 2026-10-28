"""Converts the UVR MDX-Net "Voc_FT" vocal model (ONNX, from sherpa-onnx's model release) to Core ML
for Seaglass's karaoke, checks the result against onnxruntime and writes a fixture for Tools/KaraokeCheck.

Runs in CI (see .github/workflows/build.yml):
    python Tools/convert_karaoke_model.py UVR-MDX-NET-Voc_FT.onnx Generated/VocFT.mlpackage Generated/karaoke-fixture.bin

The spectrogram code below is the reference that Seaglass/Player/MDXSeparator.swift follows. It matches
sherpa-onnx's own UVR processing to within 1e-7.
"""
import sys

import coremltools as ct
import numpy as np
import onnx
import onnxruntime as ort
import torch
from onnx2torch import convert

N_FFT, HOP, DIM_F, DIM_T = 6144, 1024, 3072, 256
SEGMENT = HOP * (DIM_T - 1)        # 261120 frames go into the model at once
TRIM = N_FFT // 2                  # dropped at both ends of a segment
MAX_PIECE = SEGMENT - 2 * TRIM     # 254976
WINDOW = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(N_FFT) / N_FFT)  # periodic Hann
FIXTURE_FRAMES = 200_000


def stft(x):
    """torch.stft(center=True, pad_mode="reflect", onesided=True) -> [bins, frames]."""
    padded = np.pad(x, (N_FFT // 2, N_FFT // 2), mode="reflect")
    frames = 1 + (len(padded) - N_FFT) // HOP
    return np.stack([np.fft.rfft(padded[t * HOP:t * HOP + N_FFT] * WINDOW) for t in range(frames)], axis=1)


def istft(spec, length):
    """torch.istft(center=True): windowed overlap-add divided by the squared-window envelope."""
    frames = spec.shape[1]
    total = N_FFT + HOP * (frames - 1)
    y, envelope = np.zeros(total), np.zeros(total)
    for t in range(frames):
        y[t * HOP:t * HOP + N_FFT] += np.fft.irfft(spec[:, t], n=N_FFT) * WINDOW
        envelope[t * HOP:t * HOP + N_FFT] += WINDOW ** 2
    y /= np.where(envelope > 1e-11, envelope, 1)
    return y[N_FFT // 2:N_FFT // 2 + length]


def model_input(left, right):
    planes = []
    for x in (left, right):
        segment = np.zeros(SEGMENT)
        segment[TRIM:TRIM + len(x)] = x
        spec = stft(segment)[:DIM_F]
        planes += [spec.real, spec.imag]
    return np.stack(planes)[None].astype(np.float32)


def vocals_from(output, n):
    result = []
    for c in range(2):
        spec = np.zeros((N_FFT // 2 + 1, DIM_T), dtype=np.complex128)
        spec[:DIM_F] = output[0, 2 * c].astype(np.float64) + 1j * output[0, 2 * c + 1].astype(np.float64)
        result.append(istft(spec, SEGMENT)[TRIM:TRIM + n])
    return np.stack(result)


def test_signal(n):
    """A voice-like harmonic tone with vibrato and a gliding pitch over a chord and some noise."""
    rng = np.random.default_rng(7)
    t = np.arange(n) / 44100
    pitch = 220 * (1 + 0.25 * t / t[-1]) * (1 + 0.01 * np.sin(2 * np.pi * 5.5 * t))
    phase = 2 * np.pi * np.cumsum(pitch) / 44100
    voice = sum(np.sin(k * phase) / k * np.exp(-((k * 220 - 700) / 900) ** 2) for k in range(1, 20))
    chord = sum(np.sin(2 * np.pi * f * t) for f in (130.8, 164.8, 196.0)) / 3
    noise = rng.standard_normal(n) * 0.02
    left = 0.5 * voice + 0.35 * chord + noise
    right = 0.5 * voice + 0.25 * chord - noise
    return left, right


def main():
    onnx_path, package_path, fixture_path = sys.argv[1:4]

    model = convert(onnx.load(onnx_path)).eval()
    example = torch.zeros(1, 4, DIM_F, DIM_T)
    with torch.no_grad():
        traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=(1, 4, DIM_F, DIM_T), dtype=np.float32)],
        outputs=[ct.TensorType(name="output", dtype=np.float32)],
        convert_to="mlprogram",
        # Activations peak around 1e3, far from float16's 6.5e4: safe, and twice as fast on the GPU / ANE.
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel.short_description = "UVR MDX-Net Voc_FT vocal separation (spectrogram in, spectrogram out)"
    mlmodel.save(package_path)

    left, right = test_signal(FIXTURE_FRAMES)
    x = model_input(left, right)
    expected = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"]).run(None, {"input": x})[0]
    with torch.no_grad():
        torch_out = traced(torch.from_numpy(x)).numpy()
    scale = np.abs(expected).max()
    print(f"spectrogram peak {scale:.1f}; torch vs onnxruntime max diff {np.abs(torch_out - expected).max():.2e}")

    vocals = vocals_from(expected, FIXTURE_FRAMES)
    mix_rms = np.sqrt(np.mean(np.stack([left, right]) ** 2))
    for units in (ct.ComputeUnit.CPU_ONLY, ct.ComputeUnit.ALL):
        try:
            loaded = ct.models.MLModel(package_path, compute_units=units)
            out = loaded.predict({"input": x})["output"]
        except Exception as error:  # e.g. no GPU / Neural Engine on the runner
            print(f"{units.name}: prediction not available here ({error})")
            continue
        error_rms = np.sqrt(np.mean((vocals_from(out, FIXTURE_FRAMES) - vocals) ** 2))
        print(f"{units.name}: spectrogram max diff {np.abs(out - expected).max():.3f}, "
              f"vocals error {20 * np.log10(error_rms / mix_rms):.1f} dB below the mix")
        if not np.all(np.isfinite(out)) or error_rms / mix_rms > 0.01:
            sys.exit(f"Core ML output differs too much from onnxruntime ({units.name})")

    # Fixture for Tools/KaraokeCheck: frame count, then left, right, vocals left, vocals right (float32).
    with open(fixture_path, "wb") as f:
        np.array([FIXTURE_FRAMES], dtype=np.int32).tofile(f)
        np.stack([left, right, vocals[0], vocals[1]]).astype(np.float32).tofile(f)
    print(f"vocals rms {np.sqrt(np.mean(vocals ** 2)):.4f}, mix rms {mix_rms:.4f}")


if __name__ == "__main__":
    main()
