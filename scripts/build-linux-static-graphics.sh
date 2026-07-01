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

is_musl_rid() {
  [[ "$RID" == linux-musl-* ]]
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
  local python_bin_dir
  python_bin_dir="$(dirname "$(command -v python3)")"
  if [[ ! -d "$depot_dir/.git" ]]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$depot_dir"
  else
    git -C "$depot_dir" pull --ff-only
  fi
  if is_musl_rid; then
    initialize_depot_tools_system_python "$depot_dir"
    patch_depot_tools_python_deps "$depot_dir"
  fi
  export PATH="$python_bin_dir:$depot_dir:$PATH"
}

initialize_depot_tools_system_python() {
  local depot_dir="$1"
  local python_bin_dir
  python_bin_dir="$(dirname "$(command -v python3)")"

  if [[ -d "$depot_dir" ]]; then
    python3 - "$depot_dir" "$python_bin_dir" <<'PY'
import os
import pathlib
import sys

depot_dir = pathlib.Path(sys.argv[1]).resolve()
python_bin_dir = pathlib.Path(sys.argv[2]).resolve()
marker = depot_dir / "python3_bin_reldir.txt"
marker.write_text(os.path.relpath(python_bin_dir, depot_dir) + "\n")
PY
  fi
}

patch_depot_tools_python_deps() {
  local depot_dir="$1"
  local gsutil_dir="$depot_dir/external_bin/gsutil/gsutil_4.68/gsutil"
  local gsutil_third_party="$gsutil_dir/third_party"

  if [[ -d "$gsutil_dir" && ! -f "$gsutil_dir/six.py" ]]; then
    python3 - "$gsutil_dir/six.py" <<'PY'
import pathlib
import shutil
import six
import sys

src = pathlib.Path(six.__file__)
dest = pathlib.Path(sys.argv[1])
shutil.copyfile(src, dest)
PY
  fi

  if [[ -d "$gsutil_third_party" && ! -f "$gsutil_third_party/six.py" ]]; then
    python3 - "$gsutil_third_party/six.py" <<'PY'
import pathlib
import shutil
import six
import sys

src = pathlib.Path(six.__file__)
dest = pathlib.Path(sys.argv[1])
shutil.copyfile(src, dest)
PY
  fi
}

prepend_python_module_path() {
  local module="$1"
  local module_dir
  module_dir="$(python3 - "$module" <<'PY'
import importlib
import pathlib
import sys

module = importlib.import_module(sys.argv[1])
print(pathlib.Path(module.__file__).parent)
PY
)"
  export PYTHONPATH="$module_dir:${PYTHONPATH:-}"
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
  if is_musl_rid; then
    initialize_depot_tools_system_python "$src/third_party/depot_tools"
    patch_depot_tools_python_deps "$src/third_party/depot_tools"
    prepend_python_module_path six
    prepare_angle_gcs_artifacts "$src"
  fi
  prepare_musl_clang_runtime
  prepare_musl_libstdcxx_headers
  gclient sync -f -D -R

  local out_dir="$src/out/linux-static-$TARGET_CPU"
  local angle_is_clang="false"
  if is_musl_rid; then
    angle_is_clang="true"
  fi
  mkdir -p "$out_dir"
  cat >"$out_dir/args.gn" <<EOF_ARGS
target_os = "linux"
target_cpu = "$TARGET_CPU"
is_debug = false
is_component_build = false
is_clang = $angle_is_clang
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
  append_angle_musl_gn_args "$out_dir/args.gn"

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

prepare_angle_gcs_artifacts() {
  local src="$1"
  download_angle_gcs_artifact \
    angle-glslang-validator \
    "$src/tools/glslang/glslang_validator.sha1" \
    "$src/tools/glslang/glslang_validator"
  download_angle_gcs_artifact \
    angle-flex-bison \
    "$src/tools/flex-bison/linux/bison.sha1" \
    "$src/tools/flex-bison/linux/bison"
  download_angle_gcs_artifact \
    angle-flex-bison \
    "$src/tools/flex-bison/linux/flex.sha1" \
    "$src/tools/flex-bison/linux/flex"
}

download_angle_gcs_artifact() {
  local bucket="$1"
  local sha_file="$2"
  local output="$3"

  if [[ -f "$sha_file" && ! -f "$output" ]]; then
    local sha
    sha="$(tr -d '[:space:]' <"$sha_file")"
    curl -fsSL "https://storage.googleapis.com/$bucket/$sha" -o "$output"
    chmod +x "$output"
  fi
}

append_angle_musl_gn_args() {
  local args_file="$1"

  if is_musl_rid; then
    cat >>"$args_file" <<'EOF_ARGS'
clang_base_path = "/usr"
clang_use_chrome_plugins = false
EOF_ARGS
  fi
}

prepare_musl_clang_runtime() {
  if ! is_musl_rid; then
    return 0
  fi

  local arch
  local gnu_triple
  case "$TARGET_CPU" in
    x64)
      arch="x86_64"
      gnu_triple="x86_64-unknown-linux-gnu"
      ;;
    arm64)
      arch="aarch64"
      gnu_triple="aarch64-unknown-linux-gnu"
      ;;
    *)
      echo "Unsupported musl ANGLE target_cpu for clang runtime: $TARGET_CPU" >&2
      return 1
      ;;
  esac

  local src
  src="$(find /usr/lib/llvm* /usr/lib/clang -path "*/${arch}-alpine-linux-musl/libclang_rt.builtins-${arch}.a" -print -quit 2>/dev/null || true)"
  if [[ -z "$src" ]]; then
    echo "Could not find Alpine compiler-rt builtins for $arch" >&2
    return 1
  fi

  local clang_version
  clang_version="$(clang -print-resource-dir | awk -F/ '{print $NF}')"
  local dest_dir="/usr/lib/clang/$clang_version/lib/$gnu_triple"
  mkdir -p "$dest_dir"
  ln -sf "$src" "$dest_dir/libclang_rt.builtins.a"
}

prepare_musl_libstdcxx_headers() {
  if ! is_musl_rid; then
    return 0
  fi

  local arch
  local musl_triple
  case "$TARGET_CPU" in
    x64)
      arch="x86_64"
      musl_triple="x86_64-linux-musl"
      ;;
    arm64)
      arch="aarch64"
      musl_triple="aarch64-linux-musl"
      ;;
    *)
      echo "Unsupported musl ANGLE target_cpu for libstdc++ headers: $TARGET_CPU" >&2
      return 1
      ;;
  esac

  local cxx_root
  cxx_root="$(find /usr/include/c++ -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null || true)"
  if [[ -z "$cxx_root" ]]; then
    echo "Could not find libstdc++ include root" >&2
    return 1
  fi

  local src_dir="$cxx_root/${arch}-alpine-linux-musl"
  local dest_dir="$cxx_root/$musl_triple"
  if [[ ! -d "$src_dir" ]]; then
    echo "Could not find Alpine libstdc++ target headers: $src_dir" >&2
    return 1
  fi

  ln -sfn "$src_dir" "$dest_dir"
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
