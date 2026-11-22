"""Parity gate: the compiled Core ML model, run through the same chunk loop as the Swift port, against the official
PyTorch pipeline on the reference clip.

usage: python -I parity.py MODEL_DIR PAYLOAD_DIR CLIP_WAV FIXTURES_DIR

Exits non-zero when a check fails. Writes fixtures for the Swift tests to FIXTURES_DIR (see `write_fixtures`).

Thresholds, from the prototype's measurements of the same pal8 model (frame-level DER, no collar, overlap scored,
threshold 0.5, against the official model with lowest-index top-k tie-breaking):
- 97.6 s, 6 speakers: DER 0.060% (GPU) / 0.111% (Neural Engine), Pearson r 0.99991 / 0.99987.
- two 5-minute podcast cuts: DER 0.19-0.54%, Pearson r >= 0.99968.
- the fp32 PyTorch port itself, through the same loop: up to 0.094%, from near-ties in the speaker cache.
So DER <= 1% (about twice the worst observed) and r >= 0.999 pass every healthy conversion, while a broken one
(wrong front-end, misplaced mask, wrong cache logic, bad quantization) shows up as several percent or more.
The NumPy front-end matched the official processor to 4.7e-4; 1e-2 leaves room for float32 FFT differences.
"""

import json
import os
import sys
import time
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np

from convert import MEL_FILTERS_FILE, MODEL_NAME, SILENCE_EMBEDS_FILE
from nemotron_coreml import diarize_offline, frame_der, log_mel, patch_stable_topk, segments_from_probs

MAX_DER = 0.01
MIN_PEARSON = 0.999
MAX_FEATURE_DIFF = 1e-2
# The clip has three voices and about 1.5 s where two of them overlap.
MIN_REFERENCE_SPEAKERS = 3
MIN_REFERENCE_OVERLAP_FRAMES = 50
COMPUTE_UNITS = ["ALL", "CPU_AND_GPU"]


def read_wav(path):
    with wave.open(path, "rb") as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2, path
        return np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float32) / np.float32(32768.0)


def reference(model_dir, audio):
    """Official processor + model, offline, ties in the speaker cache broken by lowest index."""
    import torch
    from transformers import AutoModelForAudioFrameClassification, AutoProcessor

    patch_stable_topk()
    processor = AutoProcessor.from_pretrained(model_dir)
    model = AutoModelForAudioFrameClassification.from_pretrained(model_dir, attn_implementation="eager").eval()
    inputs = processor(audio, sampling_rate=16000)
    with torch.inference_mode():
        logits = model(**inputs).logits
    return (inputs.input_features[0].numpy(), inputs.attention_mask[0].numpy().astype(np.float32),
            torch.sigmoid(logits)[0].numpy())


def coreml_step(model_path, units):
    import coremltools as ct

    model = ct.models.CompiledMLModel(model_path, compute_units=getattr(ct.ComputeUnit, units))

    def step(prefix, chunk, mask, window_mask):
        out = model.predict({"prefix_embeds": prefix, "chunk_features": chunk, "mask": mask, "window_mask": window_mask})
        return out["chunk_embeds"], out["frame_probs"], out["chunk_logits"]

    return step


def compare(probs, ref_probs, mask):
    valid = mask > 0
    p, r = probs[valid].astype(np.float64), ref_probs[valid].astype(np.float64)
    der, parts = frame_der(r > 0.5, p > 0.5)
    return {
        "der": float(der),
        "pearson": float(np.corrcoef(p.ravel(), r.ravel())[0, 1]),
        "maxAbsDiff": float(np.abs(p - r).max()),
        "flips": int(((p > 0.5) != (r > 0.5)).sum()),
        "frames": int(valid.sum()),
        **parts,
    }


def write_fixtures(out_dir, clip_path, feats, mask, ref_probs, coreml_probs):
    """Raw little-endian float32, row-major, for the Swift tests."""
    os.makedirs(out_dir, exist_ok=True)
    with open(clip_path, "rb") as src, open(os.path.join(out_dir, "reference_clip.wav"), "wb") as dst:
        dst.write(src.read())
    feats.astype("<f4").tofile(os.path.join(out_dir, "log_mel.f32"))
    mask.astype("<f4").tofile(os.path.join(out_dir, "mel_mask.f32"))
    ref_probs.astype("<f4").tofile(os.path.join(out_dir, "reference_probs.f32"))
    coreml_probs.astype("<f4").tofile(os.path.join(out_dir, "coreml_probs.f32"))
    with open(os.path.join(out_dir, "fixtures.json"), "w") as f:
        json.dump({"numFrames": len(feats), "numMels": feats.shape[1], "numSpeakers": ref_probs.shape[1],
                   "maxDER": MAX_DER, "minPearson": MIN_PEARSON, "maxFeatureDiff": MAX_FEATURE_DIFF}, f, indent=2)


def run(model_dir, payload_dir, clip_path, fixtures_dir):
    """Returns (report, failures)."""
    audio = read_wav(clip_path)
    mel_filters = np.fromfile(os.path.join(payload_dir, MEL_FILTERS_FILE), "<f4").reshape(128, 257)
    silence = np.fromfile(os.path.join(payload_dir, SILENCE_EMBEDS_FILE), "<f4")
    failures = []

    ref_feats, ref_mask, ref_probs = reference(model_dir, audio)
    feats, mask = log_mel(audio, mel_filters)
    feature_diff = float(np.abs(feats - ref_feats).max()) if feats.shape == ref_feats.shape else float("inf")
    report = {"clipSeconds": round(len(audio) / 16000, 2), "frontEndMaxAbsDiff": feature_diff}
    if feature_diff > MAX_FEATURE_DIFF or not np.array_equal(mask, ref_mask):
        failures.append(f"log-mel front-end differs from the official processor (max |diff| {feature_diff:.3g}, "
                        f"masks equal: {np.array_equal(mask, ref_mask)}); the Swift front-end would be wrong too")

    ref_speakers = sorted({s[2] for s in segments_from_probs(ref_probs, mask)})
    overlap_frames = int(((ref_probs > 0.5).sum(axis=1)[mask > 0] > 1).sum())
    report["referenceSpeakers"] = len(ref_speakers)
    report["referenceOverlapFrames"] = overlap_frames
    if len(ref_speakers) < MIN_REFERENCE_SPEAKERS or overlap_frames < MIN_REFERENCE_OVERLAP_FRAMES:
        failures.append(f"the reference found {len(ref_speakers)} speaker(s) and {overlap_frames} overlapping frames "
                        f"in the clip; the gate needs {MIN_REFERENCE_SPEAKERS} and {MIN_REFERENCE_OVERLAP_FRAMES}")

    model_path = os.path.join(payload_dir, f"{MODEL_NAME}.mlmodelc")
    results = {}
    coreml_probs = None
    for units in COMPUTE_UNITS:
        t0 = time.perf_counter()
        logits = diarize_offline(coreml_step(model_path, units), feats, mask, silence)
        probs = (1.0 / (1.0 + np.exp(-logits.astype(np.float64)))).astype(np.float32)
        result = compare(probs, ref_probs, mask)
        result["seconds"] = round(time.perf_counter() - t0, 2)
        results[units] = result
        print(f"  {units}: DER {100 * result['der']:.3f}%, Pearson r {result['pearson']:.6f}, "
              f"max |dp| {result['maxAbsDiff']:.3f}, flips {result['flips']}/{result['frames'] * probs.shape[1]} "
              f"({result['seconds']} s with load)")
        if result["der"] > MAX_DER or not result["pearson"] >= MIN_PEARSON:
            failures.append(f"Core ML ({units}) vs PyTorch: DER {100 * result['der']:.3f}% (max {100 * MAX_DER}%), "
                            f"Pearson r {result['pearson']:.6f} (min {MIN_PEARSON})")
        if coreml_probs is None:
            coreml_probs = probs
    report["coreml"] = results
    report["thresholds"] = {"maxDER": MAX_DER, "minPearson": MIN_PEARSON, "maxFeatureDiff": MAX_FEATURE_DIFF}

    write_fixtures(fixtures_dir, clip_path, feats, mask, ref_probs, coreml_probs)
    return report, failures


def main():
    model_dir, payload_dir, clip_path, fixtures_dir = sys.argv[1:5]
    report, failures = run(model_dir, payload_dir, clip_path, fixtures_dir)
    print(json.dumps(report, indent=2))
    for failure in failures:
        print(f"parity: {failure}", file=sys.stderr)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
