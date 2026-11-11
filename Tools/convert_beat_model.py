"""Converts the Beat This! beat tracker (CPJKU, MIT licence: code and weights) to Core ML for AutoMix.

Usage: python Tools/convert_beat_model.py <checkpoint.ckpt> <out.mlpackage> <fixture.bin>

The model reads a log-mel spectrogram (frames x 128, 50 frames per second, see `BeatThisModel`) and
gives each frame a beat and a downbeat logit. It is converted with a fixed input of `CHUNK` frames:
the app runs a song in overlapping chunks of that size, as upstream's inference does.

The fixture holds a test signal, its log-mel spectrogram and the logits upstream's own inference
gives for it (split, predict, aggregate), so that CI can check the app's front end and its chunked
Core ML inference against them (Tools/BeatThisCheck).
"""
import struct
import sys

import numpy as np
import torch

from beat_this.inference import load_model, split_predict_aggregate
from beat_this.preprocessing import LogMelSpect

CHUNK = 1500
BORDER = 6
MELS = 128
RATE = 22050


class Wrapper(torch.nn.Module):
    """The model with its outputs as a tuple (Core ML needs named tensors, not a dict)."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, spect):
        out = self.model(spect)
        return out["beat"], out["downbeat"]


def test_signal(seconds=48.0):
    """A song made to a click at 128 BPM with a chord change every bar and a quieter 8-bar intro,
    then a second part at 100 BPM: the fixture covers more than one chunk and a tempo change."""
    rng = np.random.default_rng(7)
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    x = np.zeros(n)
    def part(start, end, bpm, root):
        beat = 60 / bpm
        k = 0
        while start + k * beat < end:
            at = start + k * beat
            i = int(at * RATE)
            length = min(int(0.25 * RATE), n - i)
            tt = np.arange(length) / RATE
            accent = 1.4 if k % 4 == 0 else 1.0
            level = 0.35 if k < 32 and start == 0 else 1.0
            x[i:i + length] += 0.8 * np.sin(2 * np.pi * (55 + 90 * np.exp(-tt * 40)) * tt) * np.exp(-tt * 18) * accent * level
            hat = int((at + beat / 2) * RATE)
            hl = min(int(0.05 * RATE), n - hat)
            if hl > 0:
                x[hat:hat + hl] += 0.15 * level * rng.uniform(-1, 1, hl) * np.exp(-np.arange(hl) / RATE * 60)
            if k % 4 == 0:
                cl = min(int(4 * beat * RATE), n - i)
                ct = np.arange(cl) / RATE
                chord = [root, root + 4, root + 7] if (k // 4) % 2 == 0 else [root + 5, root + 9, root + 12]
                for p in chord:
                    f = 440 * 2 ** ((p - 69) / 12)
                    x[i:i + cl] += 0.06 * level * np.sin(2 * np.pi * f * ct)
            k += 1
    part(0.0, 28.0, 128, 57)
    part(28.0, seconds, 100, 60)
    return (x / np.abs(x).max() * 0.8).astype(np.float32)


def outer_einsum():
    """The rotary embeddings' outer products ('..., f -> ... f') as a broadcast multiplication:
    the same numbers, in an operation Core ML converts (its einsum doesn't take that form)."""
    import rotary_embedding_torch.rotary_embedding_torch as rotary

    plain = torch.einsum

    def einsum(equation, *operands):
        if equation.replace(" ", "") == "...,f->...f" and len(operands) == 2:
            return operands[0][..., None] * operands[1]
        return plain(equation, *operands)

    rotary.einsum = einsum


def main(checkpoint, out_path, fixture_path):
    torch.manual_seed(0)
    outer_einsum()
    model = load_model(checkpoint, device="cpu").eval()
    wrapper = Wrapper(model).eval()
    example = torch.zeros(1, CHUNK, MELS)
    with torch.no_grad():
        # The rotary embeddings cache their tables on the first call: the traced graphs of two calls
        # differ in that alone, so the trace isn't checked against a second one.
        traced = torch.jit.trace(wrapper, example, check_trace=False)

    import coremltools as ct

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="spect", shape=(1, CHUNK, MELS), dtype=np.float32)],
        outputs=[ct.TensorType(name="beat", dtype=np.float32), ct.TensorType(name="downbeat", dtype=np.float32)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT32,
    )
    mlmodel.short_description = "Beat This! small0 (CPJKU, MIT): beat and downbeat logits per log-mel frame (50 fps)"
    mlmodel.save(out_path)

    # The fixture: the signal, upstream's spectrogram of it, and upstream's logits.
    audio = test_signal()
    spect = LogMelSpect()(torch.from_numpy(audio.astype(np.float64)).float())
    with torch.no_grad():
        predicted = split_predict_aggregate(spect, CHUNK, BORDER, "keep_first", model)
    beat, downbeat = predicted["beat"], predicted["downbeat"]
    spect = spect.numpy().astype(np.float32)
    beat = beat.numpy().astype(np.float32)
    downbeat = downbeat.numpy().astype(np.float32)
    with open(fixture_path, "wb") as f:
        f.write(struct.pack("<4i", len(audio), spect.shape[0], spect.shape[1], len(beat)))
        f.write(audio.tobytes())
        f.write(spect.tobytes())
        f.write(beat.tobytes())
        f.write(downbeat.tobytes())
    print(f"converted {checkpoint} to {out_path}; fixture: {len(audio)} samples, {spect.shape[0]} frames,"
          f" {int((beat > 0).sum())} beat frames over 0")


if __name__ == "__main__":
    main(*sys.argv[1:4])
