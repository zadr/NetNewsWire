# Speaker diarization model: build-time conversion

The `SpeakerDiarization` package runs our own Core ML conversion of NVIDIA’s
[Nemotron 3 Diarization](https://huggingface.co/nvidia/Nemotron-3-Diarization) (OpenMDW-1.1). The model is not
committed: every build of the Mac and iOS apps runs `build-model.sh` (Run Script phase “Speaker Diarization Model”),
which converts it from NVIDIA’s official `model.safetensors` when needed and copies it into the app. Only NVIDIA’s
repository is used; no third-party conversion.

## What a build does

1. Looks up the **latest** revision: `https://huggingface.co/api/models/nvidia/Nemotron-3-Diarization?blobs=true`
   (its `sha`). There is no pinned commit, so builds pick up upstream updates.
2. If `conversions/<revision>-<scripts hash>/` exists in the cache, uses it (about 0.1 s). The scripts hash covers
   the `*.py` files, `pyproject.toml`, `uv.lock` and `.python-version`, so changing any of them reconverts.
3. Otherwise (about a minute on an M4 Pro, plus the 400 MB download):
   - installs uv 0.13.9 into the cache with its official versioned installer (which checks the binary’s sha256), and
     the locked Python environment with `uv sync --frozen` (Python 3.12 managed by uv, so the system Python doesn’t
     matter);
   - downloads `config.json`, `processor_config.json` and `model.safetensors` for that revision and checks each one
     against the hash the API reports (LFS sha256 for the weights, git blob sha1 for the JSON files);
   - checks that the configuration still has the values the Swift port hard-codes (chunk sizes, cache parameters,
     front-end settings), and fails with the differences otherwise;
   - converts the offline chunk-step model (fp16 compute, 8-bit k-means palettized weights, about 100 MB), compiles it
     with `xcrun coremlcompiler` (checking that both macOS 15 and iOS 18 accept it) and writes the mel filter bank
     and silence embedding the Swift side needs;
   - runs the parity gate (below). A failed gate fails the build.
4. Copies `NemotronDiarization/` into the app’s resources: `NemotronDiarizer.mlmodelc`, `mel_filters_128x257.f32`,
   `silence_embeds_512.f32` and `NemotronDiarization.json`, which records the revision, the weights’ sha256, tool
   versions and the parity results. `SpeakerDiarizer.modelInfo` reads it.

If Hugging Face can’t be reached (or the download fails), the build uses the most recent cached conversion and shows
a warning. With nothing cached, it fails.

## Parity gate

`make_clip.py` makes a reference clip with no downloaded audio: about 50 s of three macOS voices (Daniel, Samantha,
Fred, or the next available ones) taking turns, with 1.6 s where two of them talk at once. On it, `parity.py` compares
NVIDIA’s Transformers pipeline (PyTorch, fp32, speaker-cache ties broken by lowest index like the port) with the
compiled Core ML model run through the same chunk loop and speaker cache as the Swift code, with compute units `ALL`
and `CPU_AND_GPU`. It fails when:

- frame-level DER (no collar, overlap scored) is over **1%**, or the Pearson correlation of the probabilities is under
  **0.999**. The prototype measured 0.06–0.11% on a 6-speaker clip and up to 0.54% on podcast excerpts for this same
  model, with r ≥ 0.99968; the fp32 PyTorch port alone reaches 0.09% from near-ties in the cache. A broken conversion
  is off by several percent;
- the NumPy front-end differs from NVIDIA’s processor by more than 1e-2 (measured 2e-4). This catches front-end
  changes that the model is robust enough to hide from the DER check: shifting the mel filters by one FFT bin only
  moves DER to 0.67%;
- the reference doesn’t find 3 speakers and some overlap in the clip (the clip would test nothing).

It writes fixtures for the Swift tests next to the conversion (`fixtures/`): the clip, NumPy log-mel, PyTorch and
Python Core ML probabilities, and the thresholds.

## Cache

`~/Library/Caches/NetNewsWire-ModelBuild` (override with `NNW_MODEL_BUILD_CACHE`): `uv/`, `python/`, `uv-cache/`,
`venv/`, `downloads/<revision>/` (only the current revision is kept), `conversions/` (the newest three), and
`current`, a link to the conversion the last build used. Builds share the cache through a lock, so the Mac and iOS
apps can build at the same time. Deleting the folder is always safe.

The script needs `ENABLE_USER_SCRIPT_SANDBOXING = NO` (the default for these targets) because it uses the network
and the cache; it stops with an error otherwise.

## By hand

```sh
Modules/SpeakerDiarization/Conversion/build-model.sh    # fill the cache without building the app
cd Modules/SpeakerDiarization && swift test             # parity tests use the cache's `current` conversion
```

Timing (the benchmark test is skipped unless given audio):

```sh
V=~/Library/Caches/NetNewsWire-ModelBuild/venv/bin/python
$V -I Modules/SpeakerDiarization/Conversion/make_clip.py /tmp/clip.wav --minutes 6
cd Modules/SpeakerDiarization && SPEAKER_DIARIZATION_BENCHMARK_AUDIO=/tmp/clip.wav swift test -c release --filter benchmark
```

To change Python dependencies, edit `pyproject.toml` and run `uv lock` here, with the uv from the cache.

## Files

| File | What |
| --- | --- |
| `build-model.sh` | Xcode entry point: revision lookup, cache, fallback, uv bootstrap, copy into the app |
| `build_model.py` | download and verification, configuration check, conversion, compilation, gate, model info |
| `convert.py` | PyTorch → Core ML conversion and palettization |
| `nemotron_coreml.py` | fixed-shape network wrapper, NumPy front-end, NumPy port of the chunk loop and speaker cache |
| `parity.py` | parity gate and Swift test fixtures |
| `make_clip.py` | reference and benchmark clips from macOS voices |
