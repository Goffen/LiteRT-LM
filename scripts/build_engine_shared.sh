#!/usr/bin/env bash
# Build libengine_shared.dylib for macOS, iOS device, and iOS simulator,
# then copy each into the corresponding prebuilt/ directory.
#
# Run from the LiteRT-LM repo root:
#   ./scripts/build_engine_shared.sh
#
# Prerequisites: bazel, Xcode with iOS SDK
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREBUILT="$REPO_ROOT/prebuilt"
TARGET="//c:libengine_shared.dylib"

cd "$REPO_ROOT"

build_and_copy() {
    local config="$1"
    local dest_dir="$2"

    echo "── Building $TARGET --config=$config"
    bazel build --config="$config" "$TARGET"

    mkdir -p "$dest_dir"
    cp -f bazel-bin/c/libengine_shared.dylib "$dest_dir/libengine_shared.dylib"

    # Fix install name for iOS targets so dyld finds it via @rpath.
    # macOS host builds get patched in build.rs instead.
    if [[ "$config" == ios* ]]; then
        chmod u+w "$dest_dir/libengine_shared.dylib"
        install_name_tool -id "@rpath/libengine_shared.dylib" "$dest_dir/libengine_shared.dylib"
    fi

    local platform
    platform=$(otool -l "$dest_dir/libengine_shared.dylib" \
        | awk '/cmd LC_BUILD_VERSION/{found=1} found && /platform/{print $2; exit}')
    local size
    size=$(du -h "$dest_dir/libengine_shared.dylib" | cut -f1)

    echo "   → $dest_dir/libengine_shared.dylib  ($size, platform=$platform)"
    echo ""
}

build_and_copy "macos_arm64"    "$PREBUILT/macos_arm64"
build_and_copy "ios_arm64"      "$PREBUILT/ios_arm64"
build_and_copy "ios_sim_arm64"  "$PREBUILT/ios_sim_arm64"

# Restore bazel-bin symlink to macOS (most common dev target)
echo "── Restoring bazel-bin to macos_arm64"
bazel build --config=macos_arm64 "$TARGET" >/dev/null 2>&1

echo "Done. Prebuilt libraries:"
for f in "$PREBUILT"/{macos_arm64,ios_arm64,ios_sim_arm64}/libengine_shared.dylib; do
    ls -lh "$f"
done
