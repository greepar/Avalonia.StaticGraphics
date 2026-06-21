# StaticLink.Avalonia

Static native libraries for Avalonia NativeAOT publishing.

This package links Avalonia's graphics/native dependencies from static archives so NativeAOT publish output does not need the usual SkiaSharp, HarfBuzzSharp, ANGLE, or AvaloniaNative runtime files next to the executable.

Repository: <https://github.com/greepar/StaticLink.Avalonia>

## Supported RIDs

- `win-x64`
- `win-arm64`
- `linux-x64`
- `linux-arm64`
- `osx-x64`
- `osx-arm64`

## Install

```bash
dotnet add package StaticLink.Avalonia
```

For fully static macOS output, also reference the AvaloniaNative package that matches your Avalonia version:

```bash
dotnet add package StaticLink.Avalonia.Native --version 11.3.14.1
```

## Publish

```bash
dotnet publish -c Release -r win-x64 \
  -p:PublishAot=true \
  -p:SelfContained=true \
  -p:PublishSingleFile=true \
  -p:StripSymbols=true
```

Use the RID you need, for example `linux-x64`, `linux-arm64`, `osx-arm64`, or `osx-x64`.

For Linux, `lld` is recommended:

```bash
dotnet publish -c Release -r linux-x64 \
  -p:PublishAot=true \
  -p:SelfContained=true \
  -p:PublishSingleFile=true \
  -p:StripSymbols=true \
  -p:LinkerFlavor=lld
```

For macOS, avoid the Metal renderer for fully static output. Use OpenGL or Software:

```csharp
.With(new AvaloniaNativePlatformOptions
{
    RenderingMode = [AvaloniaNativeRenderingMode.OpenGl, AvaloniaNativeRenderingMode.Software]
})
```

## Notes

- The package is intended for Avalonia `11.3.x` NativeAOT apps.
- `StaticLink.Avalonia.Native` is version-specific because `libAvaloniaNative.a` must match Avalonia's native ABI.
- The CI builds and smoke-publishes all six supported RIDs.
- macOS smoke tests run the published app on GitHub Actions and require it to stay alive for 15 seconds.
- Other native dependencies used by your app, such as SQLite or audio libraries, are outside this package's scope.
