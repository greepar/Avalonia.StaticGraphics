# Greepar.Avalonia.StaticGraphics

Static graphics libraries for Avalonia NativeAOT single-file publishing.

This package provides static archives for SkiaSharp, HarfBuzzSharp, and ANGLE, then wires them into MSBuild through `buildTransitive` targets. It is intended for Avalonia applications that want NativeAOT single-file publish outputs without shipping Avalonia graphics native libraries next to the executable.

Repository: <https://github.com/greepar/Avalonia.StaticGraphics>

## Supported RIDs

- `win-x64`
- `win-arm64`
- `linux-x64`
- `linux-arm64`
- `osx-x64`
- `osx-arm64`

## Included Libraries

Windows:

- `skia.lib`
- `SkiaSharp.lib`
- `libHarfBuzzSharp.lib`
- `libANGLE_static.lib`
- `libGLESv2_static.lib`

Linux and macOS:

- `libskia.a`
- `libSkiaSharp.a`
- `libHarfBuzzSharp.a`
- `libANGLE_static.a`
- `libGLESv2_static.a`

## Install

```bash
dotnet add package Greepar.Avalonia.StaticGraphics
```

## Publish

Windows x64 or arm64:

```bash
dotnet publish -c Release -r win-x64 \
  -p:PublishAot=true \
  -p:SelfContained=true \
  -p:PublishSingleFile=true \
  -p:StripSymbols=true
```

Linux x64 or arm64:

```bash
dotnet publish -c Release -r linux-x64 \
  -p:PublishAot=true \
  -p:SelfContained=true \
  -p:PublishSingleFile=true \
  -p:StripSymbols=true \
  -p:LinkerFlavor=lld
```

macOS x64 or arm64:

```bash
dotnet publish -c Release -r osx-arm64 \
  -p:PublishAot=true \
  -p:SelfContained=true \
  -p:PublishSingleFile=true \
  -p:StripSymbols=true
```

The package automatically contributes the static archives as `NativeLibrary` items when `PublishAot=true` and the `RuntimeIdentifier` is supported.

## Verify Output

After publishing, the publish directory should not contain Avalonia graphics runtime files such as:

- `libSkiaSharp.so`
- `libHarfBuzzSharp.so`
- `libSkiaSharp.dylib`
- `libHarfBuzzSharp.dylib`
- `libSkiaSharp.dll`
- `libHarfBuzzSharp.dll`
- `av_libglesv2.dll`

The package stores static archives under `static/<rid>/native/` inside the NuGet package, so `.a` and `.lib` files are used for linking and are not normal runtime assets.

## Build From Source

This repository does not depend on 2ndLAB static packages. The GitHub Actions workflow builds the native libraries from upstream source repositories:

- SkiaSharp: <https://github.com/mono/SkiaSharp>
- ANGLE: <https://github.com/google/angle>

Build scripts:

- `scripts/build-linux-static-graphics.sh`
- `scripts/build-windows-static-graphics.ps1`
- `scripts/build-macos-static-graphics.sh`

Build locally after the static archives exist:

```bash
dotnet pack NuGet/StaticGraphics/Greepar.Avalonia.StaticGraphics.csproj -c Release -o artifacts/nuget
```

The package will be written to:

```text
artifacts/nuget/Greepar.Avalonia.StaticGraphics.*.nupkg
```

## GitHub Actions

The workflow `.github/workflows/nuget-static-graphics.yml` builds all native archives and packs a single NuGet package for all supported RIDs.

It will:

- build Linux x64 static archives on `ubuntu-latest`
- build Linux arm64 static archives on `ubuntu-24.04-arm`
- build Windows x64 and arm64 static archives on `windows-latest`
- build macOS x64 and arm64 static archives on `macos-latest`
- download all native artifacts into `External/NativeStatic/<rid>/`
- run `dotnet pack`
- upload the generated `.nupkg` as a workflow artifact

To publish automatically to nuget.org, add a repository secret named `NUGET_API_KEY`, then either:

- run the workflow manually with `publish_to_nuget=true`
- push a tag matching `static-graphics-v*`

Example tag:

```bash
git tag static-graphics-v3.119.2-7151.4
git push origin static-graphics-v3.119.2-7151.4
```

## Known Runtime Dependencies

Single-file does not always mean dependency-free. Depending on platform and publish settings, the final executable may still depend on operating system libraries and frameworks.

Linux examples:

- `libc.so.6`
- `libm.so.6`
- `libstdc++.so.6`
- `libgcc_s.so.1`
- `libfontconfig.so.1`
- `libfreetype.so.6`

Linux systems also need usable fonts for text rendering and font fallback.

## Scope

This package only covers Avalonia graphics-related native libraries. If your application uses other native dependencies, such as SQLite, audio backends, OpenSSL, or custom native libraries, those dependencies may require separate handling.

## License

The NuGet package metadata uses the MIT license. The bundled third-party native libraries are built from their upstream projects and remain subject to their respective upstream licenses.
