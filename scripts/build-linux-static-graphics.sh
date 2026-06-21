#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/External/NativeStatic/.work}"
TARGET_CPU="${TARGET_CPU:-x64}"
RID="${RID:-linux-$TARGET_CPU}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/External/NativeStatic/$RID}"
SKIASHARP_VERSION="${SKIASHARP_VERSION:-3.119.2}"
ANGLE_BRANCH="${ANGLE_BRANCH:-7151}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
ANGLE_PATCH_DIR="${ANGLE_PATCH_DIR:-$ROOT_DIR/External/NativeStatic/patches}"
LLVM_AR="${LLVM_AR:-llvm-ar-19}"
SKIA_DEPS_RETRIES="${SKIA_DEPS_RETRIES:-3}"

usage() {
  cat <<'USAGE'
Usage: scripts/build-linux-static-graphics.sh [skia|angle|all]

Environment:
  WORK_DIR            Source/build cache directory. Default: External/NativeStatic/.work
  OUTPUT_DIR          Final static library directory. Default: External/NativeStatic/linux-$TARGET_CPU
  SKIASHARP_VERSION   SkiaSharp release branch version. Default: 3.119.2
  ANGLE_BRANCH        ANGLE chromium branch. Default: 7151
  TARGET_CPU          GN target_cpu. Default: x64. Supported: x64, arm64
  RID                 Output RID. Default: linux-$TARGET_CPU
  BUILD_JOBS          Ninja parallelism. Default: nproc
  ANGLE_PATCH_DIR     ANGLE patch directory. Default: External/NativeStatic/patches
  LLVM_AR             llvm-ar command used to expand thin archives. Default: llvm-ar-19
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

ensure_tools() {
  require_cmd git
  require_cmd python3
  require_cmd clang
  require_cmd clang++
  require_cmd ar
  require_cmd "$LLVM_AR"
  require_cmd ninja
  require_cmd pkg-config
}

ensure_depot_tools() {
  local depot_dir="$WORK_DIR/depot_tools"
  if [[ ! -d "$depot_dir/.git" ]]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$depot_dir"
  else
    git -C "$depot_dir" pull --ff-only
  fi
  export PATH="$depot_dir:$PATH"
}

sync_skiasharp() {
  local src="$WORK_DIR/SkiaSharp-$SKIASHARP_VERSION"
  if [[ ! -d "$src/.git" ]]; then
    git clone --depth 1 --branch "release/$SKIASHARP_VERSION" https://github.com/mono/SkiaSharp.git "$src"
  else
    git -C "$src" fetch --depth 1 origin "release/$SKIASHARP_VERSION"
    git -C "$src" checkout -q FETCH_HEAD
  fi
  git -C "$src" submodule update --init --depth 1 externals/skia >&2
  echo "$src"
}

prepare_skia_git_sync_deps() {
  local sync_deps="$1/tools/git-sync-deps"
  python3 - "$sync_deps" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = "  multithread(git_checkout_to_directory, list_of_arg_lists)"
new = "  for args in list_of_arg_lists:\n    git_checkout_to_directory(*args)"
if old in text:
    path.write_text(text.replace(old, new))
PY
}

sync_skia_deps() {
  local skia_dir="$1/externals/skia"
  if [[ ! -x "$skia_dir/bin/gn" ]]; then
    prepare_skia_git_sync_deps "$skia_dir"

    local attempt
    for attempt in $(seq 1 "$SKIA_DEPS_RETRIES"); do
      if python3 "$skia_dir/tools/git-sync-deps"; then
        return 0
      fi
      if [[ "$attempt" == "$SKIA_DEPS_RETRIES" ]]; then
        return 1
      fi
      echo "git-sync-deps failed; retrying ($attempt/$SKIA_DEPS_RETRIES)..." >&2
      sleep 10
    done
  fi
}

build_skia() {
  ensure_tools
  ensure_depot_tools
  local src
  src="$(sync_skiasharp)"
  sync_skia_deps "$src"

  local skia_dir="$src/externals/skia"
  local out_dir="$skia_dir/out/linux-static-$TARGET_CPU"
  mkdir -p "$out_dir" "$OUTPUT_DIR"

  cat >"$out_dir/args.gn" <<EOF_ARGS
target_os = "linux"
target_cpu = "$TARGET_CPU"
is_official_build = true
is_static_skiasharp = true
skia_enable_tools = false
skia_enable_ganesh = true
skia_enable_pdf = false
skia_enable_skottie = false
skia_use_dng_sdk = false
skia_use_fontconfig = true
skia_use_freetype = true
skia_use_harfbuzz = false
skia_use_icu = false
skia_use_piex = false
skia_use_sfntly = false
skia_use_system_expat = false
skia_use_system_freetype2 = false
skia_use_system_libjpeg_turbo = false
skia_use_system_libpng = false
skia_use_system_libwebp = false
skia_use_system_zlib = false
skia_use_vulkan = false
skia_use_xps = false
cc = "clang"
cxx = "clang++"
ar = "ar"
extra_cflags = [
  "-DSKIA_C_DLL",
  "-DHAVE_SYSCALL_GETRANDOM",
  "-DXML_DEV_URANDOM",
]
extra_cflags_cc = [ "-frtti" ]
extra_ldflags = [ "-static-libstdc++", "-static-libgcc" ]
EOF_ARGS

  (cd "$skia_dir" && "$skia_dir/bin/gn" gen "$out_dir")
  ninja -C "$out_dir" -j "$BUILD_JOBS" skia SkiaSharp HarfBuzzSharp

  copy_first_existing "$OUTPUT_DIR/libskia.a" \
    "$out_dir/libskia.a" \
    "$out_dir/obj/libskia.a"
  copy_first_existing "$OUTPUT_DIR/libSkiaSharp.a" \
    "$out_dir/libSkiaSharp.a" \
    "$out_dir/obj/libSkiaSharp.a"
  copy_first_existing "$OUTPUT_DIR/libHarfBuzzSharp.a" \
    "$out_dir/libHarfBuzzSharp.a" \
    "$out_dir/obj/libHarfBuzzSharp.a"
}

sync_angle() {
  local src="$WORK_DIR/ANGLE-$ANGLE_BRANCH"
  if [[ ! -d "$src/.git" ]]; then
    git clone --depth 1 --branch "chromium/$ANGLE_BRANCH" https://github.com/google/angle.git "$src"
  else
    git -C "$src" fetch --depth 1 origin "chromium/$ANGLE_BRANCH"
    git -C "$src" checkout -q FETCH_HEAD
  fi
  echo "$src"
}

build_angle() {
  ensure_tools
  ensure_depot_tools
  local src
  src="$(sync_angle)"
  mkdir -p "$OUTPUT_DIR"

  cd "$src"
  apply_angle_patches "$src"
  python3 scripts/bootstrap.py
  gclient sync -f -D -R

  local out_dir="$src/out/linux-static-$TARGET_CPU"
  mkdir -p "$out_dir"
  cat >"$out_dir/args.gn" <<EOF_ARGS
target_os = "linux"
target_cpu = "$TARGET_CPU"
is_debug = false
is_component_build = false
is_clang = false
treat_warnings_as_errors = false
use_custom_libcxx = false
use_sysroot = false
use_lld = false
use_thin_lto = false
symbol_level = 0
angle_build_tests = false
build_angle_deqp_tests = false
angle_enable_swiftshader = false
angle_enable_vulkan = false
angle_enable_wgpu = false
EOF_ARGS

  gn gen "$out_dir"
  ninja -C "$out_dir" -j "$BUILD_JOBS" libANGLE_static libGLESv2_static

  copy_full_archive_from_thin "$out_dir" "$OUTPUT_DIR/libANGLE_static.a" \
    "$out_dir/obj/libANGLE_static.a" \
    "$out_dir/obj/libANGLE_static/libANGLE_static.a" \
    "$out_dir/libANGLE_static.a"
  copy_full_archive_from_thin "$out_dir" "$OUTPUT_DIR/libGLESv2_static.a" \
    "$out_dir/obj/libGLESv2_static.a" \
    "$out_dir/obj/libGLESv2_static/libGLESv2_static.a" \
    "$out_dir/libGLESv2_static.a"
}

apply_angle_patches() {
  local src="$1"
  local build_patch="$ANGLE_PATCH_DIR/angle-chromium-$ANGLE_BRANCH.patch"
  local deps_patch="$ANGLE_PATCH_DIR/angle-chromium-$ANGLE_BRANCH-deps.patch"

  if ! git -C "$src" grep -q 'angle_static_library("libANGLE_static")' -- BUILD.gn; then
    python3 - "$src/BUILD.gn" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
targets = '''angle_static_library("libANGLE_static") {
  complete_static_lib = true
  public_deps = [ ":libANGLE" ]
}

angle_static_library("libANGLE_with_capture_static") {
  complete_static_lib = true
  public_deps = [ ":libANGLE_with_capture" ]
}

angle_static_library("libGLESv2_static") {
'''
text = re.sub(r'^angle_static_library\("libGLESv2_static"\) \{', targets, text, count=1, flags=re.M)
text = re.sub(r'^angle_static_library\("libGLESv2_static"\) \{\n  sources = libglesv2_sources', 'angle_static_library("libGLESv2_static") {\n  complete_static_lib = true\n  sources = libglesv2_sources', text, count=1, flags=re.M)
path.write_text(text)
PY
  fi

  if [[ -f "$build_patch" ]] && git -C "$src" grep -q "'third_party/catapult'" -- DEPS; then
    git -C "$src" apply "$build_patch"
  elif [[ -f "$deps_patch" ]] && ! git -C "$src" apply --check "$deps_patch" >/dev/null 2>&1; then
    :
  elif [[ -f "$deps_patch" ]]; then
    git -C "$src" apply "$deps_patch"
  fi
}

copy_first_existing() {
  local dest="$1"
  shift
  for src in "$@"; do
    if [[ -f "$src" ]]; then
      cp "$src" "$dest"
      echo "Wrote $dest"
      return 0
    fi
  done
  echo "None of the expected files exist for $dest:" >&2
  printf '  %s\n' "$@" >&2
  return 1
}

copy_full_archive_from_thin() {
  local base_dir="$1"
  local dest="$2"
  shift 2

  local src
  for src in "$@"; do
    if [[ -f "$src" ]]; then
      if [[ "$(head -c 7 "$src")" == "!<thin>" ]]; then
        local tmp="$dest.tmp"
        local rel_src="${src#$base_dir/}"
        (
          cd "$base_dir"
          mapfile -t members < <("$LLVM_AR" t "$rel_src")
          "$LLVM_AR" rcs "$tmp" "${members[@]}"
        )
        mv "$tmp" "$dest"
      else
        cp "$src" "$dest"
      fi
      echo "Wrote $dest"
      return 0
    fi
  done

  echo "None of the expected files exist for $dest:" >&2
  printf '  %s\n' "$@" >&2
  return 1
}

main() {
  mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
  case "${1:-all}" in
    skia) build_skia ;;
    angle) build_angle ;;
    all)
      build_skia
      build_angle
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
