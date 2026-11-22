"""Converts the official Nemotron 3 Diarization weights to the offline Core ML chunk-step model.

usage: python -I convert.py MODEL_DIR OUT_DIR

Writes NemotronDiarizer.mlpackage (fp16 compute, 8-bit k-means palettized weights) and the constants the Swift side
needs: mel_filters_128x257.f32 (Slaney mel filter bank, row-major) and silence_embeds_512.f32, little-endian float32.

Offline shapes: prefix 304 = speaker cache 264 + FIFO 40, chunk 380 = chunk 340 + look-ahead 40 (config.json).
"""

import argparse
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch
from transformers import AutoModelForAudioFrameClassification, AutoProcessor

from nemotron_coreml import DiarizationStep

MODEL_NAME = "NemotronDiarizer"
PREFIX_SLOTS = 304
CHUNK_SLOTS = 380
MEL_FILTERS_FILE = "mel_filters_128x257.f32"
SILENCE_EMBEDS_FILE = "silence_embeds_512.f32"


def convert(model_dir, out_dir, description=""):
    """Returns the path of the saved .mlpackage."""
    os.makedirs(out_dir, exist_ok=True)
    model = AutoModelForAudioFrameClassification.from_pretrained(model_dir, attn_implementation="eager").eval()
    processor = AutoProcessor.from_pretrained(model_dir)
    P, K = PREFIX_SLOTS, CHUNK_SLOTS
    step = DiarizationStep(model, P, K).eval()

    # fixed seed: the traced graph doesn't depend on the example values, but keep the build deterministic anyway
    generator = torch.Generator().manual_seed(0)
    example = (
        torch.randn(1, P, 512, generator=generator),
        torch.randn(1, K * 8, 128, generator=generator),
        torch.ones(1, P + K),
        torch.ones(1, P + K),
    )
    with torch.inference_mode():
        traced = torch.jit.trace(step, example)

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="prefix_embeds", shape=(1, P, 512), dtype=np.float32),
            ct.TensorType(name="chunk_features", shape=(1, K * 8, 128), dtype=np.float32),
            ct.TensorType(name="mask", shape=(1, P + K), dtype=np.float32),
            ct.TensorType(name="window_mask", shape=(1, P + K), dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="chunk_embeds", dtype=np.float32),
            ct.TensorType(name="frame_probs", dtype=np.float32),
            ct.TensorType(name="chunk_logits", dtype=np.float32),
        ],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )
    mlmodel = cto.palettize_weights(
        mlmodel, cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(mode="kmeans", nbits=8))
    )
    mlmodel.author = "Converted from nvidia/Nemotron-3-Diarization"
    mlmodel.license = "OpenMDW-1.1"
    mlmodel.short_description = (
        f"Nemotron 3 Diarization chunk step: [speaker cache + FIFO ({P} slots, right-aligned) | chunk + look-ahead "
        f"({K} encoder frames = {K * 8} mel frames)] -> per-10ms speaker logits for 8 speakers. {description}"
    ).strip()
    mlmodel.user_defined_metadata.update({"prefix_slots": str(P), "chunk_slots": str(K)})

    path = os.path.join(out_dir, f"{MODEL_NAME}.mlpackage")
    if os.path.exists(path):
        shutil.rmtree(path)
    mlmodel.save(path)

    processor.feature_extractor.mel_filters.numpy().astype("<f4").tofile(os.path.join(out_dir, MEL_FILTERS_FILE))
    model.silence_embeds.detach().numpy().astype("<f4").tofile(os.path.join(out_dir, SILENCE_EMBEDS_FILE))
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model_dir")
    parser.add_argument("out_dir")
    args = parser.parse_args()
    print(convert(args.model_dir, args.out_dir))


if __name__ == "__main__":
    main()
