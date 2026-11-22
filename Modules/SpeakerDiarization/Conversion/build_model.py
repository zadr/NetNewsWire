"""Downloads one revision of nvidia/Nemotron-3-Diarization, converts it, compiles it and runs the parity gate.

usage: python -I build_model.py API_JSON DOWNLOADS_DIR OUT_DIR SCRIPTS_HASH

API_JSON is the Hugging Face API response for the model (`/api/models/nvidia/Nemotron-3-Diarization?blobs=true`):
its `sha` is the revision to convert and its `siblings` give the hashes every downloaded file is checked against.

OUT_DIR gets:
- NemotronDiarization/: what goes into the app bundle (compiled model, mel filters, silence embeddings, and
  NemotronDiarization.json recording the revision, hashes, tool versions and parity results).
- fixtures/: the reference clip and reference outputs for the Swift tests.

Exit status: 0 on success, 3 when the download failed (the caller may fall back to an earlier conversion),
1 for anything else, including a failed parity gate.
"""

import datetime
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

REPOSITORY = "nvidia/Nemotron-3-Diarization"
FILES = ["config.json", "processor_config.json", "model.safetensors"]
PAYLOAD_NAME = "NemotronDiarization"
EXIT_DOWNLOAD_FAILED = 3

# Values the Swift port hard-codes (Sources/SpeakerDiarization). If NVIDIA changes them, the port needs updating.
EXPECTED_CONFIG = {
    "config.json": {
        "chunk_length": 340,
        "chunk_right_context": 40,
        "fifo_length": 40,
        "speaker_cache_update_period": 300,
        "audio_config.hidden_size": 512,
        "audio_config.num_mel_bins": 128,
        "audio_config.subsampling_factor": 8,
        "head_config.num_speakers": 8,
        "streaming_config.speaker_cache_length": 264,
        "streaming_config.speaker_cache_silence_frames_per_speaker": 1,
        "streaming_config.prediction_score_threshold": 0.25,
        "streaming_config.latest_frames_score_boost": 0.05,
        "streaming_config.strong_boost_rate": 0.75,
        "streaming_config.weak_boost_rate": 1.5,
        "streaming_config.min_positive_scores_rate": 0.5,
    },
    "processor_config.json": {
        "feature_extractor.feature_extractor_type": "NemotronAsrStreamingFeatureExtractor",
        "feature_extractor.feature_size": 128,
        "feature_extractor.hop_length": 160,
        "feature_extractor.n_fft": 512,
        "feature_extractor.win_length": 400,
        "feature_extractor.preemphasis": 0.97,
        "feature_extractor.sampling_rate": 16000,
    },
}


class DownloadError(Exception):
    pass


def log(message):
    print(f"SpeakerDiarization model: {message}", flush=True)


def git_blob_sha1(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def verify(path, sibling):
    """True when the file matches the hash the API reports: LFS sha256 for large files, git blob sha1 otherwise."""
    if not os.path.exists(path):
        return False
    if "lfs" in sibling:
        return os.path.getsize(path) == sibling["lfs"]["size"] and file_sha256(path) == sibling["lfs"]["sha256"]
    with open(path, "rb") as f:
        return git_blob_sha1(f.read()) == sibling["blobId"]


def download(revision, siblings, model_dir):
    os.makedirs(model_dir, exist_ok=True)
    for name in FILES:
        sibling = siblings.get(name)
        if sibling is None:
            raise SystemExit(f"{REPOSITORY}@{revision} has no {name}")
        path = os.path.join(model_dir, name)
        if verify(path, sibling):
            continue
        url = f"https://huggingface.co/{REPOSITORY}/resolve/{revision}/{name}"
        log(f"downloading {name} from {url}")
        part = path + ".part"
        try:
            with urllib.request.urlopen(url, timeout=60) as response, open(part, "wb") as f:
                shutil.copyfileobj(response, f, 1 << 20)
        except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
            raise DownloadError(f"downloading {name} failed: {error}") from error
        if not verify(part, sibling):
            os.remove(part)
            expected = sibling["lfs"]["sha256"] if "lfs" in sibling else sibling["blobId"]
            raise SystemExit(f"{name} doesn't match the hash Hugging Face reports ({expected})")
        os.replace(part, path)
    log(f"verified {', '.join(FILES)} for revision {revision}")


def check_config(model_dir):
    problems = []
    for file_name, expected in EXPECTED_CONFIG.items():
        with open(os.path.join(model_dir, file_name)) as f:
            config = json.load(f)
        for key, value in expected.items():
            actual = config
            for part in key.split("."):
                actual = actual.get(part) if isinstance(actual, dict) else None
            if actual != value:
                problems.append(f"{file_name} {key} is {actual!r}, the Swift port assumes {value!r}")
    if problems:
        raise SystemExit("upstream configuration changed:\n  " + "\n  ".join(problems))


def compile_model(package_path, payload_dir):
    # Compile for macOS, and check that iOS accepts the model too.
    subprocess.run(["xcrun", "coremlcompiler", "compile", package_path, payload_dir, "--platform", "macOS",
                    "--deployment-target", "15.0"], check=True, stdout=subprocess.DEVNULL)
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["xcrun", "coremlcompiler", "compile", package_path, tmp, "--platform", "iOS",
                        "--deployment-target", "18.0"], check=True, stdout=subprocess.DEVNULL)


def dir_size(path):
    return sum(os.path.getsize(os.path.join(d, f)) for d, _, files in os.walk(path) for f in files)


def main():
    api_json, downloads_dir, out_dir, scripts_hash = sys.argv[1:5]
    with open(api_json) as f:
        api = json.load(f)
    revision = api["sha"]
    siblings = {s["rfilename"]: s for s in api["siblings"]}
    model_dir = os.path.join(downloads_dir, revision)

    try:
        download(revision, siblings, model_dir)
    except DownloadError as error:
        print(f"SpeakerDiarization model: {error}", file=sys.stderr)
        sys.exit(EXIT_DOWNLOAD_FAILED)
    check_config(model_dir)

    import coremltools
    import torch
    import transformers

    from convert import MEL_FILTERS_FILE, MODEL_NAME, SILENCE_EMBEDS_FILE, convert
    import make_clip
    import parity

    work_dir = os.path.join(out_dir, "work")
    payload_dir = os.path.join(out_dir, PAYLOAD_NAME)
    os.makedirs(payload_dir, exist_ok=True)

    log("converting to Core ML (8-bit palettized)")
    package_path = convert(model_dir, work_dir, f"Revision {revision}.")
    log("compiling")
    compile_model(package_path, payload_dir)
    for name in (MEL_FILTERS_FILE, SILENCE_EMBEDS_FILE):
        shutil.copy(os.path.join(work_dir, name), payload_dir)

    log("parity gate: Core ML vs PyTorch on the reference clip")
    clip_path = os.path.join(work_dir, "reference_clip.wav")
    make_clip.make_reference_clip(clip_path)
    report, failures = parity.run(model_dir, payload_dir, clip_path, os.path.join(out_dir, "fixtures"))

    info = {
        "repository": REPOSITORY,
        "revision": revision,
        "lastModified": api.get("lastModified"),
        "modelSHA256": siblings["model.safetensors"]["lfs"]["sha256"],
        "conversionScriptsHash": scripts_hash,
        "convertedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "compiledModelBytes": dir_size(os.path.join(payload_dir, f"{MODEL_NAME}.mlmodelc")),
        "tools": {
            "python": platform.python_version(),
            "torch": torch.__version__,
            "transformers": transformers.__version__,
            "coremltools": coremltools.__version__,
            "macOS": platform.mac_ver()[0],
        },
        "parity": report,
    }
    with open(os.path.join(payload_dir, f"{PAYLOAD_NAME}.json"), "w") as f:
        json.dump(info, f, indent=2)
    shutil.rmtree(work_dir)

    if failures:
        for failure in failures:
            print(f"SpeakerDiarization model: parity gate failed: {failure}", file=sys.stderr)
        sys.exit(1)
    log(f"parity gate passed ({info['compiledModelBytes'] / 1e6:.1f} MB compiled)")


if __name__ == "__main__":
    main()
