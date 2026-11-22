#!/bin/sh
#
# Puts our Core ML conversion of nvidia/Nemotron-3-Diarization in the app bundle, converting the latest upstream
# revision first when it isn't cached yet. Runs as a Run Script build phase of the Mac and iOS apps; also runs by hand
# (without Xcode's environment it just fills the cache, for the Swift package tests). See README.md.
#
# Environment: NNW_MODEL_BUILD_CACHE overrides the cache folder (default ~/Library/Caches/NetNewsWire-ModelBuild).

set -eu

REPOSITORY="nvidia/Nemotron-3-Diarization"
PAYLOAD_NAME="NemotronDiarization"
UV_VERSION="0.13.9"
KEEP_CONVERSIONS=3

CONVERSION_DIR=$(cd "$(dirname "$0")" && pwd)
CACHE_DIR="${NNW_MODEL_BUILD_CACHE:-$HOME/Library/Caches/NetNewsWire-ModelBuild}"

log() { echo "SpeakerDiarization model: $*"; }
warn() { echo "warning: SpeakerDiarization model: $*"; }
fail() { echo "error: SpeakerDiarization model: $*"; exit 1; }

if [ "${ENABLE_USER_SCRIPT_SANDBOXING:-NO}" = "YES" ]; then
	fail "this build phase needs ENABLE_USER_SCRIPT_SANDBOXING = NO (it uses the network and a cache outside the build folder)"
fi

mkdir -p "$CACHE_DIR/conversions" "$CACHE_DIR/downloads"

# One build at a time per cache (the Mac and iOS apps may build in parallel).
if [ -z "${NNW_MODEL_BUILD_LOCKED:-}" ]; then
	NNW_MODEL_BUILD_LOCKED=1 exec /usr/bin/lockf "$CACHE_DIR/.lock" /bin/sh "$0" "$@"
fi

started=$(date +%s)

scripts_hash=$(cd "$CONVERSION_DIR" && cat .python-version pyproject.toml uv.lock *.py | /usr/bin/shasum -a 256 | cut -c1-16)

latest_cached_conversion() {
	marker=$(ls -t "$CACHE_DIR"/conversions/*/.complete 2>/dev/null | head -n 1)
	if [ -n "$marker" ]; then
		dirname "$marker"
	fi
}

fall_back() {
	conversion=$(latest_cached_conversion)
	[ -n "$conversion" ] || fail "$1, and there is no earlier conversion to fall back on"
	warn "$1; using the cached conversion $(basename "$conversion")"
}

ensure_uv() {
	uv="$CACHE_DIR/uv/$UV_VERSION/uv"
	if [ ! -x "$uv" ]; then
		log "installing uv $UV_VERSION into $CACHE_DIR/uv/$UV_VERSION"
		/usr/bin/curl -LsSf "https://astral.sh/uv/$UV_VERSION/install.sh" \
			| env UV_UNMANAGED_INSTALL="$CACHE_DIR/uv/$UV_VERSION" INSTALLER_NO_MODIFY_PATH=1 /bin/sh \
			|| fail "couldn't install uv $UV_VERSION (https://docs.astral.sh/uv/getting-started/installation/)"
	fi
}

# Xcode's environment (SDKROOT, CC, deployment targets and so on) has no business in the Python build.
run_clean() {
	env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" LANG=en_US.UTF-8 \
		DEVELOPER_DIR="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}" \
		UV_PROJECT_ENVIRONMENT="$CACHE_DIR/venv" UV_PYTHON_INSTALL_DIR="$CACHE_DIR/python" \
		UV_CACHE_DIR="$CACHE_DIR/uv-cache" UV_PYTHON_PREFERENCE=only-managed UV_NO_CONFIG=1 TQDM_DISABLE=1 \
		"$@"
}

convert() {
	revision=$1
	api_json=$2
	staging="$CACHE_DIR/conversions/.staging-$revision-$scripts_hash"
	ensure_uv
	log "setting up the Python environment (uv.lock)"
	run_clean "$uv" sync --frozen --quiet --project "$CONVERSION_DIR" || fail "uv sync failed"
	rm -rf "$staging"
	mkdir -p "$staging"
	status=0
	run_clean "$CACHE_DIR/venv/bin/python" -I "$CONVERSION_DIR/build_model.py" "$api_json" "$CACHE_DIR/downloads" \
		"$staging" "$scripts_hash" || status=$?
	if [ "$status" -eq 3 ]; then
		rm -rf "$staging"
		fall_back "couldn't download $REPOSITORY@$revision"
		return
	fi
	[ "$status" -eq 0 ] || fail "converting $REPOSITORY@$revision failed (output kept in $staging)"
	conversion="$CACHE_DIR/conversions/$revision-$scripts_hash"
	rm -rf "$conversion"
	mv "$staging" "$conversion"
	touch "$conversion/.complete"

	# Keep the downloads of this revision only, and the newest few conversions.
	find "$CACHE_DIR/downloads" -mindepth 1 -maxdepth 1 ! -name "$revision" -exec rm -rf {} +
	ls -t "$CACHE_DIR"/conversions/*/.complete | tail -n +$((KEEP_CONVERSIONS + 1)) | while read -r marker; do
		rm -rf "$(dirname "$marker")"
	done
}

api_json="$CACHE_DIR/api.json"
if /usr/bin/curl -fsS --max-time 20 -o "$api_json.part" "https://huggingface.co/api/models/$REPOSITORY?blobs=true" \
	&& revision=$(/usr/bin/plutil -extract sha raw -o - "$api_json.part" 2>/dev/null); then
	mv "$api_json.part" "$api_json"
	conversion="$CACHE_DIR/conversions/$revision-$scripts_hash"
	if [ -f "$conversion/.complete" ]; then
		log "$REPOSITORY@$revision is up to date (conversion scripts $scripts_hash)"
	else
		log "converting $REPOSITORY@$revision (conversion scripts $scripts_hash)"
		convert "$revision" "$api_json"
	fi
else
	rm -f "$api_json.part"
	fall_back "couldn't reach Hugging Face to look up the latest $REPOSITORY revision"
fi

ln -sfn "$conversion" "$CACHE_DIR/current"
payload="$conversion/$PAYLOAD_NAME"
log "revision $(/usr/bin/plutil -extract revision raw -o - "$payload/$PAYLOAD_NAME.json"), from $payload"

if [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
	destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/$PAYLOAD_NAME"
	mkdir -p "$destination"
	/usr/bin/rsync -a --delete "$payload/" "$destination/"
	log "copied to $destination"
fi

log "done in $(($(date +%s) - started)) s"
