#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$PROJECT_ROOT/src"
VENDOR_DIR="$PROJECT_ROOT/vendor"
ASSETS_DIR="$PROJECT_ROOT/assets"
BUILD_DIR="$PROJECT_ROOT/build"
FRAMEWORKS_DIR="$BUILD_DIR/Frameworks"
EXE_PATH="$BUILD_DIR/debug_build"
ASYNC_COLLECTION_DIR="$SOURCE_DIR/async"
GFX_COLLECTION_DIR="$SOURCE_DIR/gfx"
WORLD_COLLECTION_DIR="$SOURCE_DIR/world"

find_sdl3_framework() {
	if [[ -n "${SDL3_FRAMEWORK:-}" ]]; then
		if [[ -d "$SDL3_FRAMEWORK" ]]; then
			printf '%s\n' "$SDL3_FRAMEWORK"
			return
		fi
		printf 'SDL3_FRAMEWORK is set but does not point at a directory: %s\n' "$SDL3_FRAMEWORK" >&2
		exit 1
	fi

	local candidates=(
		"$HOME/Library/Frameworks/SDL3.framework"
		"$HOME/Library/Frameworks/SDL3.xcframework/macos-arm64_x86_64/SDL3.framework"
		"/Library/Frameworks/SDL3.framework"
		"/Library/Frameworks/SDL3.xcframework/macos-arm64_x86_64/SDL3.framework"
	)

	local candidate
	for candidate in "${candidates[@]}"; do
		if [[ -d "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return
		fi
	done

	printf 'SDL3.framework was not found. Set SDL3_FRAMEWORK to the macOS SDL3.framework path.\n' >&2
	exit 1
}

stage_assets() {
	if [[ -d "$ASSETS_DIR" ]]; then
		rm -rf "$BUILD_DIR/assets"
		cp -R "$ASSETS_DIR" "$BUILD_DIR/assets"
	fi

	if [[ -d "$VENDOR_DIR/fonts" ]]; then
		mkdir -p "$BUILD_DIR/vendor"
		rm -rf "$BUILD_DIR/vendor/fonts"
		cp -R "$VENDOR_DIR/fonts" "$BUILD_DIR/vendor/fonts"
	fi
}

stage_sdl3() {
	local source_framework="$1"
	mkdir -p "$FRAMEWORKS_DIR"
	rm -rf "$FRAMEWORKS_DIR/SDL3.framework"
	cp -R "$source_framework" "$FRAMEWORKS_DIR/SDL3.framework"
	xattr -dr com.apple.quarantine "$FRAMEWORKS_DIR/SDL3.framework" 2>/dev/null || true
	xattr -dr com.apple.provenance "$FRAMEWORKS_DIR/SDL3.framework" 2>/dev/null || true
	rm -f "$BUILD_DIR/libSDL3.dylib"
	ln -s "Frameworks/SDL3.framework/SDL3" "$BUILD_DIR/libSDL3.dylib"
}

mkdir -p "$BUILD_DIR"
stage_assets
stage_sdl3 "$(find_sdl3_framework)"

ODIN_EXTRA_FLAGS_ARRAY=()
if [[ -n "${ODIN_EXTRA_FLAGS:-}" ]]; then
	read -r -a ODIN_EXTRA_FLAGS_ARRAY <<< "$ODIN_EXTRA_FLAGS"
fi

if [[ ${#ODIN_EXTRA_FLAGS_ARRAY[@]} -gt 0 ]]; then
	odin build "$SOURCE_DIR" \
		"-collection:app=$SOURCE_DIR" \
		"-collection:async=$ASYNC_COLLECTION_DIR" \
		"-collection:gfx=$GFX_COLLECTION_DIR" \
		"-collection:world=$WORLD_COLLECTION_DIR" \
		"-out:$EXE_PATH" \
		-debug \
		"${ODIN_EXTRA_FLAGS_ARRAY[@]}" \
		"-extra-linker-flags:-L$BUILD_DIR -F$FRAMEWORKS_DIR -framework SDL3 -rpath @executable_path/Frameworks"
else
	odin build "$SOURCE_DIR" \
		"-collection:app=$SOURCE_DIR" \
		"-collection:async=$ASYNC_COLLECTION_DIR" \
		"-collection:gfx=$GFX_COLLECTION_DIR" \
		"-collection:world=$WORLD_COLLECTION_DIR" \
		"-out:$EXE_PATH" \
		-debug \
		"-extra-linker-flags:-L$BUILD_DIR -F$FRAMEWORKS_DIR -framework SDL3 -rpath @executable_path/Frameworks"
fi

pushd "$BUILD_DIR" >/dev/null
trap 'popd >/dev/null' EXIT
"$EXE_PATH" "$@"
