param(
    [ValidateSet("skia", "angle", "angle-preflight", "all")]
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
if ($env:DEPOT_TOOLS_WIN_TOOLCHAIN -eq "0") {
    if (-not $env:GYP_MSVS_VERSION) {
        $env:GYP_MSVS_VERSION = "17.0"
    }
    if (-not $env:GYP_MSVS_OVERRIDE_PATH) {
        if ($env:VSINSTALLDIR) {
            $env:GYP_MSVS_OVERRIDE_PATH = $env:VSINSTALLDIR.TrimEnd("\", "/")
        } else {
            $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
            if (Test-Path $vswhere) {
                $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
                if ($vsPath) {
                    $env:GYP_MSVS_OVERRIDE_PATH = $vsPath.TrimEnd("\", "/")
                }
            }
        }
    }
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

function Split-ParameterList($Parameters) {
    if ([string]::IsNullOrWhiteSpace($Parameters)) {
        return @()
    }

    $items = [System.Collections.Generic.List[string]]::new()
    $start = 0
    $depth = 0
    for ($i = 0; $i -lt $Parameters.Length; $i++) {
        $ch = $Parameters[$i]
        if ($ch -eq '[' -or $ch -eq '(' -or $ch -eq '<') {
            $depth++
        } elseif ($ch -eq ']' -or $ch -eq ')' -or $ch -eq '>') {
            if ($depth -gt 0) { $depth-- }
        } elseif ($ch -eq ',' -and $depth -eq 0) {
            $items.Add($Parameters.Substring($start, $i - $start).Trim())
            $start = $i + 1
        }
    }
    $items.Add($Parameters.Substring($start).Trim())
    return $items | Where-Object { $_ }
}

function Get-X86NativeParameterSize($Parameter) {
    $parameter = [regex]::Replace($Parameter, '/\*.*?\*/', '').Trim()
    $parameter = [regex]::Replace($parameter, '\[[^\]]+\]\s*', '').Trim()
    $parameter = [regex]::Replace($parameter, '\b(ref|out|in)\b\s*', '').Trim()
    if (-not $parameter) { return 0 }

    $parts = $parameter -split '\s+'
    if ($parts.Length -gt 1) {
        $type = ($parts[0..($parts.Length - 2)] -join ' ')
    } else {
        $type = $parts[0]
    }
    $type = $type.Trim()

    if ($script:X86GeneratedStructSizes -and $script:X86GeneratedStructSizes.ContainsKey($type)) {
        return $script:X86GeneratedStructSizes[$type]
    }

    if ($type.Contains('*') -or $type.EndsWith('[]') -or $type -eq 'String' -or $type -eq 'string' -or $type.EndsWith('Delegate')) {
        return 4
    }

    switch -Regex ($type) {
        '^(Int64|UInt64|long|ulong|Double|double)$' { return 8 }
        default { return 4 }
    }
}

function Align-X86Size($Size, $Alignment) {
    if ($Alignment -le 1) { return $Size }
    return [int]([Math]::Ceiling($Size / [double]$Alignment) * $Alignment)
}

function Get-X86ManagedTypeLayout($Type, $KnownSizes) {
    if ($Type.Contains('*') -or $Type.Contains('delegate*') -or $Type.EndsWith('[]') -or $Type.EndsWith('Delegate')) {
        return @{ Size = 4; Alignment = 4 }
    }

    switch -Regex ($Type) {
        '^(Byte|SByte|bool)$' { return @{ Size = 1; Alignment = 1 } }
        '^(Int16|UInt16|short|ushort|Char)$' { return @{ Size = 2; Alignment = 2 } }
        '^(Int64|UInt64|long|ulong|Double|double)$' { return @{ Size = 8; Alignment = 4 } }
        default {
            if ($KnownSizes.ContainsKey($Type)) {
                return @{ Size = $KnownSizes[$Type]; Alignment = 4 }
            }
            return @{ Size = 4; Alignment = 4 }
        }
    }
}

function Get-X86GeneratedStructSizes($BindingFiles) {
    $structFields = @{}

    foreach ($bindingFile in $BindingFiles) {
        $lines = Get-Content -Path $bindingFile
        $current = $null
        $depth = 0
        $includeStack = @($true)
        foreach ($line in $lines) {
            if ($line -match '^\s*#if\s+USE_LIBRARY_IMPORT\b') {
                $includeStack += $includeStack[-1]
                continue
            }
            if ($line -match '^\s*#else\b') {
                if ($includeStack.Count -gt 1) {
                    $parentActive = $includeStack[-2]
                    $includeStack[-1] = $parentActive -and (-not $includeStack[-1])
                }
                continue
            }
            if ($line -match '^\s*#endif\b') {
                if ($includeStack.Count -gt 1) {
                    $includeStack = @($includeStack[0..($includeStack.Count - 2)])
                }
                continue
            }
            if (-not $includeStack[-1]) {
                continue
            }

            if (-not $current -and $line -match '\bstruct\s+([A-Za-z0-9_]+)\b') {
                $current = $Matches[1]
                $structFields[$current] = [System.Collections.Generic.List[string]]::new()
                $depth = ([regex]::Matches($line, '\{')).Count - ([regex]::Matches($line, '\}')).Count
                continue
            }

            if ($current) {
                if ($depth -eq 1 -and $line -match '^\s*public\s+(.+?)\s+[A-Za-z0-9_]+;\s*$') {
                    $fieldType = ([regex]::Replace($Matches[1].Trim(), '#if.*$', '')).Trim()
                    $structFields[$current].Add($fieldType)
                }

                $depth += ([regex]::Matches($line, '\{')).Count
                $depth -= ([regex]::Matches($line, '\}')).Count
                if ($depth -le 0) {
                    $current = $null
                }
            }
        }
    }

    $sizes = @{}
    $pending = @($structFields.Keys)
    while ($pending.Count -gt 0) {
        $next = @()
        $progress = $false
        foreach ($name in $pending) {
            $offset = 0
            $maxAlign = 1
            $resolved = $true
            foreach ($fieldType in $structFields[$name]) {
                if ($structFields.ContainsKey($fieldType) -and -not $sizes.ContainsKey($fieldType)) {
                    $resolved = $false
                    break
                }
                $layout = Get-X86ManagedTypeLayout $fieldType $sizes
                $maxAlign = [Math]::Max($maxAlign, [Math]::Min($layout.Alignment, 4))
                $offset = Align-X86Size $offset ([Math]::Min($layout.Alignment, 4))
                $offset += $layout.Size
            }
            if ($resolved) {
                $sizes[$name] = Align-X86Size $offset $maxAlign
                $progress = $true
            } else {
                $next += $name
            }
        }
        if (-not $progress) { break }
        $pending = $next
    }

    return $sizes
}

function Get-X86PInvokeThunks($BindingFiles, $DefinedSymbols) {
    $thunks = @{}
    $signaturePattern = 'internal static (?:extern|partial)\s+.+?\s+((?:sk|gr|hb)_[A-Za-z0-9_]+)\s*\((.*?)\);'
    $script:X86GeneratedStructSizes = Get-X86GeneratedStructSizes $BindingFiles

    foreach ($bindingFile in $BindingFiles) {
        if (-not (Test-Path $bindingFile)) {
            throw "Missing binding file for win-x86 thunk generation: $bindingFile"
        }

        $content = Get-Content -Raw -Path $bindingFile
        foreach ($match in [regex]::Matches($content, $signaturePattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
            $symbol = "_$($match.Groups[1].Value)"
            if (-not $DefinedSymbols.ContainsKey($symbol)) {
                continue
            }

            $bytes = 0
            foreach ($parameter in Split-ParameterList $match.Groups[2].Value) {
                $bytes += Get-X86NativeParameterSize $parameter
            }

            $decorated = "${symbol}@${bytes}"
            $thunks[$decorated] = [pscustomobject]@{
                Symbol = $symbol
                Bytes = $bytes
                Decorated = $decorated
            }
        }
    }

    return $thunks.Values | Sort-Object Symbol, Bytes
}

function New-WinX86SkiaStdcallThunks([string[]]$InputLibraries, [string[]]$BindingFiles, $Destination) {
    if ($TargetCpu -ne "x86") {
        return
    }

    $llvmNm = Get-Command llvm-nm.exe -ErrorAction SilentlyContinue
    if (-not $llvmNm) {
        $llvmNm = Get-Command llvm-nm -ErrorAction SilentlyContinue
    }
    if (-not $llvmNm) {
        throw "Missing required command: llvm-nm"
    }
    Require-Command ml.exe
    Require-Command lib.exe

    $thunkDir = Join-Path $WorkDir "win-x86-skia-stdcall-thunks"
    New-Item -ItemType Directory -Path $thunkDir -Force | Out-Null
    $asmPath = Join-Path $thunkDir "skia_x86_stdcall_thunks.asm"
    $objPath = Join-Path $thunkDir "skia_x86_stdcall_thunks.obj"

    $definedSymbols = @{}
    foreach ($library in $InputLibraries) {
        & $llvmNm.Source --defined-only $library |
            ForEach-Object {
                if ($_ -match '\sT\s(_(?:sk|gr|hb)_[A-Za-z0-9_]+)$') {
                    $definedSymbols[$Matches[1]] = $true
                }
            }
    }

    if (-not $definedSymbols.Count) {
        throw "No SkiaSharp/HarfBuzzSharp C API symbols found in $($InputLibraries -join ', ')"
    }

    $thunks = @(Get-X86PInvokeThunks $BindingFiles $definedSymbols)
    if (-not $thunks) {
        throw "No win-x86 stdcall thunks generated from $($BindingFiles -join ', ')"
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("OPTION CASEMAP:NONE")
    $lines.Add(".386")
    $lines.Add(".model flat")
    foreach ($symbol in ($thunks | Select-Object -ExpandProperty Symbol -Unique)) {
        $lines.Add("EXTERN ${symbol}:PROC")
    }
    $lines.Add("_TEXT SEGMENT")
    foreach ($thunk in $thunks) {
        $lines.Add("PUBLIC $($thunk.Decorated)")
        $lines.Add("$($thunk.Decorated) PROC")
        for ($offset = 0; $offset -lt $thunk.Bytes; $offset += 4) {
            $lines.Add("    push DWORD PTR [esp+$($thunk.Bytes)]")
        }
        $lines.Add("    call $($thunk.Symbol)")
        if ($thunk.Bytes -gt 0) {
            $lines.Add("    add esp, $($thunk.Bytes)")
        }
        $lines.Add("    ret $($thunk.Bytes)")
        $lines.Add("$($thunk.Decorated) ENDP")
    }
    $lines.Add("_TEXT ENDS")
    $lines.Add("END")
    Set-Content -Path $asmPath -Value $lines -Encoding ASCII

    & ml.exe /nologo /c /coff /safeseh /Fo$objPath $asmPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to assemble win-x86 Skia stdcall thunks."
    }

    & lib.exe /nologo /out:$Destination $objPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to archive win-x86 Skia stdcall thunks."
    }
    Write-Host "Wrote $Destination"
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
skia_use_xps = true
extra_cflags = [
  "-DSKIA_C_DLL",
  "-DWINVER=0x0601",
  "-D_WIN32_WINNT=0x0601",
  "-DNTDDI_VERSION=0x06010000",
]
extra_cflags_cc = [ "/GR" ]
"@ | Set-Content -Path (Join-Path $outDir "args.gn") -Encoding ASCII

    Push-Location $skiaDir
    try {
        & (Join-Path $skiaDir "bin\gn.exe") gen $outDir
        ninja -C $outDir -j $BuildJobs skia SkiaSharp HarfBuzzSharp
    } finally {
        Pop-Location
    }

    $skiaLib = Join-Path $OutputDir "skia.lib"
    $skiaSharpLib = Join-Path $OutputDir "SkiaSharp.lib"
    $harfbuzzLib = Join-Path $OutputDir "libHarfBuzzSharp.lib"
    Copy-FirstExisting $skiaLib @((Join-Path $outDir "skia.lib"), (Join-Path $outDir "obj\skia.lib"))
    Copy-FirstExisting $skiaSharpLib @((Join-Path $outDir "SkiaSharp.lib"), (Join-Path $outDir "obj\SkiaSharp.lib"))
    Copy-FirstExisting $harfbuzzLib @(
        (Join-Path $outDir "libHarfBuzzSharp.lib"),
        (Join-Path $outDir "HarfBuzzSharp.lib"),
        (Join-Path $outDir "obj\libHarfBuzzSharp.lib"),
        (Join-Path $outDir "obj\HarfBuzzSharp.lib"),
        (Join-Path $outDir "obj\HarfBuzzSharp\libHarfBuzzSharp.lib"),
        (Join-Path $outDir "obj\HarfBuzzSharp\HarfBuzzSharp.lib")
    )
    New-WinX86SkiaStdcallThunks `
        -InputLibraries @($skiaLib, $skiaSharpLib, $harfbuzzLib) `
        -BindingFiles @((Join-Path $src "binding\SkiaSharp\SkiaApi.generated.cs"), (Join-Path $src "binding\HarfBuzzSharp\HarfBuzzApi.generated.cs")) `
        -Destination (Join-Path $OutputDir "skia_x86_stdcall_thunks.lib")
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
    $buildFile = Join-Path $Src "BUILD.gn"
    $buildText = Get-Content -Path $buildFile -Raw
    if (-not $buildText.Contains('angle_static_library("libANGLE_static")')) {
        $libAngleTargets = @'
angle_static_library("libANGLE_static") {
  complete_static_lib = true
  public_deps = [ ":libANGLE" ]
}

angle_static_library("libANGLE_with_capture_static") {
  complete_static_lib = true
  public_deps = [ ":libANGLE_with_capture" ]
}

angle_static_library("libGLESv2_static") {
'@
        $buildText = [regex]::Replace($buildText, '(?m)^angle_static_library\("libGLESv2_static"\) \{', $libAngleTargets)
        $buildText = [regex]::Replace($buildText, '(?m)^angle_static_library\("libGLESv2_static"\) \{\r?\n  sources = libglesv2_sources', "angle_static_library(`"libGLESv2_static`") {`n  complete_static_lib = true`n  sources = libglesv2_sources")
        Set-Content -Path $buildFile -Value $buildText -NoNewline -Encoding UTF8
    }

    $patch = Join-Path $AnglePatchDir "angle-chromium-$AngleBranch.patch"
    $depsFile = Join-Path $Src "DEPS"
    if ((Test-Path $patch) -and (Select-String -Path $depsFile -Pattern "'third_party/catapult'" -Quiet)) {
        $null = git -C $Src apply $patch
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to apply ANGLE patch: $patch"
        }
    }
}

function Assert-AngleVisualStudioVersion {
    if ($env:VisualStudioVersion -and -not ($env:VisualStudioVersion -in @("17.0", "16.0", "15.0"))) {
        throw "ANGLE $AngleBranch requires Visual Studio 2022/2019/2017, but VisualStudioVersion is $env:VisualStudioVersion. Use windows-2022 or a VS 2022 developer prompt."
    }
    if ($env:GYP_MSVS_OVERRIDE_PATH -and ($env:GYP_MSVS_OVERRIDE_PATH -match '\\Microsoft Visual Studio\\18\\')) {
        throw "ANGLE $AngleBranch requires Visual Studio 2022/2019/2017, but GYP_MSVS_OVERRIDE_PATH points to $env:GYP_MSVS_OVERRIDE_PATH. Use windows-2022 or a VS 2022 developer prompt."
    }
}

function Test-AnglePatch {
    Require-Command git
    Assert-AngleVisualStudioVersion

    $src = Sync-Angle
    Apply-AnglePatches $src
    if (-not (Select-String -Path (Join-Path $src "BUILD.gn") -Pattern 'angle_static_library\("libANGLE_static"\)' -Quiet)) {
        throw "ANGLE BUILD.gn preflight failed."
    }
    Write-Host "ANGLE preflight passed."
}

function Build-Angle {
    Ensure-Tools
    Assert-AngleVisualStudioVersion
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
use_custom_libcxx = false
use_thin_lto = false
symbol_level = 0
angle_build_tests = false
build_angle_deqp_tests = false
angle_enable_swiftshader = false
angle_enable_vulkan = false
angle_enable_wgpu = false
extra_cflags = [
  "-DWINVER=0x0601",
  "-D_WIN32_WINNT=0x0601",
  "-DNTDDI_VERSION=0x06010000",
]
"@ | Set-Content -Path (Join-Path $outDir "args.gn") -Encoding ASCII
        gn gen $outDir
        ninja -C $outDir -j $BuildJobs libANGLE_static libGLESv2_static
        Copy-FirstExisting (Join-Path $OutputDir "libANGLE_static.lib") @((Join-Path $outDir "libANGLE_static.lib"), (Join-Path $outDir "obj\libANGLE_static.lib"), (Join-Path $outDir "obj\libANGLE_static\libANGLE_static.lib"))
        Copy-FirstExisting (Join-Path $OutputDir "libGLESv2_static.lib") @((Join-Path $outDir "libGLESv2_static.lib"), (Join-Path $outDir "obj\libGLESv2_static.lib"), (Join-Path $outDir "obj\libGLESv2_static\libGLESv2_static.lib"))
        foreach ($libcxxName in @("libc++.lib", "libc++abi.lib")) {
            $libcxxPath = Join-Path $src "third_party\llvm-build\Release+Asserts\lib\$libcxxName"
            if (Test-Path $libcxxPath) {
                Copy-Item $libcxxPath (Join-Path $OutputDir $libcxxName) -Force
                Write-Host "Wrote $(Join-Path $OutputDir $libcxxName)"
            }
        }
    } finally {
        Pop-Location
    }
}

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
switch ($Target) {
    "skia" { Build-Skia }
    "angle-preflight" { Test-AnglePatch }
    "angle" { Build-Angle }
    "all" { Build-Skia; Build-Angle }
}
