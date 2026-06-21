#!/usr/bin/env bash
set -euo pipefail

RID="${RID:-osx-arm64}"
AVALONIA_VERSION="${AVALONIA_VERSION:-11.3.14}"
WORK_DIR="${WORK_DIR:-$PWD/External/NativeStatic/.work}"
OUTPUT_DIR="${OUTPUT_DIR:-$PWD/External/NativeStatic/$RID/native}"
BUILD_JOBS="${BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

case "$RID" in
  osx-arm64) ARCH="arm64" ;;
  osx-x64) ARCH="x86_64" ;;
  *) echo "Unsupported RID: $RID" >&2; exit 2 ;;
esac

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

src="$WORK_DIR/Avalonia-$AVALONIA_VERSION"
if [[ ! -d "$src/.git" ]]; then
  rm -rf "$src"
  git clone --depth 1 --branch "$AVALONIA_VERSION" https://github.com/AvaloniaUI/Avalonia.git "$src"
fi

if git -C "$src" config -f .gitmodules --get-regexp path | grep -q 'external/Numerge' && [[ ! -d "$src/external/Numerge/.git" ]]; then
  git -C "$src" submodule update --init --depth 1 external/Numerge
fi

if [[ ! -f "$src/native/Avalonia.Native/inc/avalonia-native.h" ]]; then
  bash "$src/native/Avalonia.Native/generate-headers.sh"
fi

project="$src/native/Avalonia.Native/src/OSX/Avalonia.Native.OSX.xcodeproj"
include_dir="$src/native/Avalonia.Native/inc"
build_dir="$WORK_DIR/avalonia-native-$RID"
rm -rf "$build_dir"
mkdir -p "$build_dir"

xcodebuild \
  -project "$project" \
  -target Avalonia.Native.OSX \
  -configuration Release \
  -sdk macosx \
  -arch "$ARCH" \
  CONFIGURATION_BUILD_DIR="$build_dir" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  MACH_O_TYPE=staticlib \
  EXECUTABLE_PREFIX=lib \
  EXECUTABLE_EXTENSION=a \
  PRODUCT_NAME=AvaloniaNative \
  HEADER_SEARCH_PATHS="$include_dir" \
  CLANG_ENABLE_MODULES=YES \
  GCC_GENERATE_DEBUGGING_SYMBOLS=NO \
  -jobs "$BUILD_JOBS"

candidate="$(find "$build_dir" -maxdepth 2 -type f -name 'libAvaloniaNative.a' -print -quit)"
if [[ -z "$candidate" ]]; then
  echo "Failed to find libAvaloniaNative.a in $build_dir" >&2
  find "$build_dir" -maxdepth 3 -type f -print >&2
  exit 1
fi

cp "$candidate" "$OUTPUT_DIR/libAvaloniaNative.a"
echo "Wrote $OUTPUT_DIR/libAvaloniaNative.a"
