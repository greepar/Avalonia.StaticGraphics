param(
    [ValidateSet("skia", "angle", "all")]
    [string]$Target = "all"
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $PSScriptRoot
$WorkDir = if ($env:WORK_DIR) { $env:WORK_DIR } else { Join-Path $RootDir "External\NativeStatic\.work" }
$SkiaSharpVersion = if ($env:SKIASHARP_VERSION) { $env:SKIASHARP_VERSION } else { "3.119.2" }
$AngleBranch = if ($env:ANGLE_BRANCH) { $env:ANGLE_BRANCH } else { "7151" }
$TargetCpu = if ($env:TARGET_CPU) { $env:TARGET_CPU } else { "x64" }
$Rid = if ($env:RID) { $env:RID } else { "win-$TargetCpu" }
$OutputDir = if ($env:OUTPUT_DIR) { $env:OUTPUT_DIR } else { Join-Path $RootDir "External\NativeStatic\$Rid" }
$BuildJobs = if ($env:BUILD_JOBS) { $env:BUILD_JOBS } else { [Environment]::ProcessorCount }
$AnglePatchDir = if ($env:ANGLE_PATCH_DIR) { $env:ANGLE_PATCH_DIR } else { Join-Path $RootDir "External\NativeStatic\patches" }
$SkiaDepsRetries = if ($env:SKIA_DEPS_RETRIES) { [int]$env:SKIA_DEPS_RETRIES } else { 3 }

if (-not $env:DEPOT_TOOLS_WIN_TOOLCHAIN) {
    $env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"
}

function Require-Command($Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name"
    }
}

function Ensure-Tools {
    Require-Command git
    Require-Command python
    Require-Command ninja
    git config --global core.longpaths true
}

function Ensure-DepotTools {
    $depotDir = Join-Path $WorkDir "depot_tools"
    if (-not (Test-Path (Join-Path $depotDir ".git"))) {
        $null = git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git $depotDir
    } else {
        $null = git -C $depotDir pull --ff-only
    }
    $env:PATH = "$depotDir;$env:PATH"
}

function Copy-FirstExisting($Destination, [string[]]$Candidates) {
    foreach ($candidate in $Candidates) {
        if (Test-Path $candidate) {
            Copy-Item $candidate $Destination -Force
            Write-Host "Wrote $Destination"
            return
        }
    }
    throw "None of the expected files exist for ${Destination}: $($Candidates -join ', ')"
}

function Sync-SkiaSharp {
    $src = Join-Path $WorkDir "SkiaSharp-$SkiaSharpVersion"
    if (-not (Test-Path (Join-Path $src ".git"))) {
        $null = git -c core.longpaths=true clone --depth 1 --branch "release/$SkiaSharpVersion" https://github.com/mono/SkiaSharp.git $src
    } else {
        $null = git -C $src fetch --depth 1 origin "release/$SkiaSharpVersion"
        $null = git -C $src checkout -q FETCH_HEAD
    }
    $null = git -C $src submodule update --init --depth 1 externals/skia
    return $src
}

function Prepare-SkiaGitSyncDeps($SkiaDir) {
    $syncDeps = Join-Path $SkiaDir "tools\git-sync-deps"
    $text = Get-Content -Path $syncDeps -Raw
    $old = "  multithread(git_checkout_to_directory, list_of_arg_lists)"
    $new = "  for args in list_of_arg_lists:`n    git_checkout_to_directory(*args)"
    if ($text.Contains($old)) {
        Set-Content -Path $syncDeps -Value $text.Replace($old, $new) -NoNewline -Encoding UTF8
    }
}

function Invoke-SkiaGitSyncDeps($SkiaDir) {
    Prepare-SkiaGitSyncDeps $SkiaDir

    for ($attempt = 1; $attempt -le $SkiaDepsRetries; $attempt++) {
        python (Join-Path $SkiaDir "tools\git-sync-deps")
        if ($LASTEXITCODE -eq 0) {
            return
        }
        if ($attempt -eq $SkiaDepsRetries) {
            throw "git-sync-deps failed after $SkiaDepsRetries attempts"
        }
        Write-Warning "git-sync-deps failed; retrying ($attempt/$SkiaDepsRetries)..."
        Start-Sleep -Seconds 10
    }
}

function Build-Skia {
    Ensure-Tools
    Ensure-DepotTools
    $src = Sync-SkiaSharp
    $skiaDir = Join-Path $src "externals\skia"
    if (-not (Test-Path (Join-Path $skiaDir "bin\gn.exe"))) {
        Invoke-SkiaGitSyncDeps $skiaDir
    }

    $outDir = Join-Path $skiaDir "out\win-static-$TargetCpu"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    @"
target_os = "win"
target_cpu = "$TargetCpu"
is_official_build = true
is_static_skiasharp = true
is_clang = true
skia_enable_tools = false
skia_enable_ganesh = true
skia_enable_pdf = false
skia_enable_skottie = false
skia_use_dng_sdk = false
skia_use_fontconfig = false
skia_use_freetype = false
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
extra_cflags = [ "-DSKIA_C_DLL" ]
extra_cflags_cc = [ "/GR" ]
"@ | Set-Content -Path (Join-Path $outDir "args.gn") -Encoding ASCII

    Push-Location $skiaDir
    try {
        & (Join-Path $skiaDir "bin\gn.exe") gen $outDir
        ninja -C $outDir -j $BuildJobs skia SkiaSharp HarfBuzzSharp
    } finally {
        Pop-Location
    }

    Copy-FirstExisting (Join-Path $OutputDir "skia.lib") @((Join-Path $outDir "skia.lib"), (Join-Path $outDir "obj\skia.lib"))
    Copy-FirstExisting (Join-Path $OutputDir "SkiaSharp.lib") @((Join-Path $outDir "SkiaSharp.lib"), (Join-Path $outDir "obj\SkiaSharp.lib"))
    Copy-FirstExisting (Join-Path $OutputDir "libHarfBuzzSharp.lib") @(
        (Join-Path $outDir "libHarfBuzzSharp.lib"),
        (Join-Path $outDir "HarfBuzzSharp.lib"),
        (Join-Path $outDir "obj\libHarfBuzzSharp.lib"),
        (Join-Path $outDir "obj\HarfBuzzSharp.lib"),
        (Join-Path $outDir "obj\HarfBuzzSharp\libHarfBuzzSharp.lib"),
        (Join-Path $outDir "obj\HarfBuzzSharp\HarfBuzzSharp.lib")
    )
}

function Sync-Angle {
    $src = Join-Path $WorkDir "ANGLE-$AngleBranch"
    if (-not (Test-Path (Join-Path $src ".git"))) {
        $null = git -c core.longpaths=true clone --depth 1 --branch "chromium/$AngleBranch" https://github.com/google/angle.git $src
    } else {
        $null = git -C $src fetch --depth 1 origin "chromium/$AngleBranch"
        $null = git -C $src checkout -q FETCH_HEAD
    }
    return $src
}

function Apply-AnglePatches($Src) {
    $patch = Join-Path $AnglePatchDir "angle-chromium-$AngleBranch.patch"
    if ((Test-Path $patch) -and -not (Select-String -Path (Join-Path $Src "BUILD.gn") -Pattern 'angle_static_library\("libANGLE_static"\)' -Quiet)) {
        $null = git -C $Src apply $patch
    }
}

function Build-Angle {
    Ensure-Tools
    Ensure-DepotTools
    $src = Sync-Angle
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    Apply-AnglePatches $src
    Push-Location $src
    try {
        python scripts/bootstrap.py
        gclient sync -f -D -R
        $outDir = Join-Path $src "out\win-static-$TargetCpu"
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        @"
target_os = "win"
target_cpu = "$TargetCpu"
is_debug = false
is_component_build = false
is_clang = true
use_lld = false
use_thin_lto = false
symbol_level = 0
angle_build_tests = false
build_angle_deqp_tests = false
angle_enable_swiftshader = false
angle_enable_vulkan = false
angle_enable_wgpu = false
"@ | Set-Content -Path (Join-Path $outDir "args.gn") -Encoding ASCII
        gn gen $outDir
        ninja -C $outDir -j $BuildJobs libANGLE_static libGLESv2_static
        Copy-FirstExisting (Join-Path $OutputDir "libANGLE_static.lib") @((Join-Path $outDir "libANGLE_static.lib"), (Join-Path $outDir "obj\libANGLE_static.lib"), (Join-Path $outDir "obj\libANGLE_static\libANGLE_static.lib"))
        Copy-FirstExisting (Join-Path $OutputDir "libGLESv2_static.lib") @((Join-Path $outDir "libGLESv2_static.lib"), (Join-Path $outDir "obj\libGLESv2_static.lib"), (Join-Path $outDir "obj\libGLESv2_static\libGLESv2_static.lib"))
    } finally {
        Pop-Location
    }
}

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
switch ($Target) {
    "skia" { Build-Skia }
    "angle" { Build-Angle }
    "all" { Build-Skia; Build-Angle }
}
