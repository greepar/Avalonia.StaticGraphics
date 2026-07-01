# StaticLink.Avalonia

Static native libraries for Avalonia single-file NativeAOT publishing.

## Install

```bash
dotnet add package StaticLink.Avalonia
```

Or add it manually:

```xml
<PackageReference Include="StaticLink.Avalonia" Version="2.88.9-7151.10" />
```

For macOS, also reference `StaticLink.Avalonia.Native`. This package is macOS-only and must match your Avalonia version because it contains `libAvaloniaNative.a`.

```xml
<PackageReference Include="StaticLink.Avalonia.Native" Version="11.3.14.1" />
```

## Publish

```bash
dotnet publish -c Release -r win-x64 \
  -p:PublishAot=true \
  -p:SelfContained=true \
  -p:PublishSingleFile=true \
  -p:StripSymbols=true
```

Use the RID you need, such as `win-x86`, `linux-x64`, `linux-arm64`, `osx-arm64`, or `osx-x64`.

For macOS, avoid the Metal renderer for fully static output. Use OpenGL or Software.
