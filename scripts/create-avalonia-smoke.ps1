param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectDir,

    [Parameter(Mandatory = $true)]
    [string]$NuGetSource,

    [Parameter(Mandatory = $true)]
    [string]$StaticLinkVersion,

    [string]$AvaloniaVersion = "11.3.14",

    [string]$StaticLinkNativeVersion = ""
)

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null

$nativeReference = ""
if ($StaticLinkNativeVersion) {
    $nativeReference = "`n    <PackageReference Include=`"StaticLink.Avalonia.Native`" Version=`"$StaticLinkNativeVersion`" />"
}

@"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="local-staticlink" value="$NuGetSource" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
"@ | Set-Content -Path (Join-Path $ProjectDir "NuGet.config") -Encoding UTF8

@"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>WinExe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <AvaloniaUseCompiledBindingsByDefault>true</AvaloniaUseCompiledBindingsByDefault>
    <PublishAot>true</PublishAot>
    <SelfContained>true</SelfContained>
    <PublishSingleFile>true</PublishSingleFile>
    <PublishTrimmed>true</PublishTrimmed>
    <PublishReadyToRun>false</PublishReadyToRun>
    <InvariantGlobalization>true</InvariantGlobalization>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Avalonia" Version="$AvaloniaVersion" />
    <PackageReference Include="Avalonia.Desktop" Version="$AvaloniaVersion" />
    <PackageReference Include="Avalonia.Themes.Fluent" Version="$AvaloniaVersion" />
    <PackageReference Include="StaticLink.Avalonia" Version="$StaticLinkVersion" />$nativeReference
  </ItemGroup>
</Project>
"@ | Set-Content -Path (Join-Path $ProjectDir "AvaloniaStaticLinkSmoke.csproj") -Encoding UTF8

@"
using Avalonia;

namespace AvaloniaStaticLinkSmoke;

internal static class Program
{
    [STAThread]
    public static void Main(string[] args) => BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);

    public static AppBuilder BuildAvaloniaApp()
    {
        var builder = AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .LogToTrace();

        if (OperatingSystem.IsMacOS())
        {
            builder = builder.With(new AvaloniaNativePlatformOptions
            {
                RenderingMode = [AvaloniaNativeRenderingMode.Software]
            });
        }

        return builder;
    }
}
"@ | Set-Content -Path (Join-Path $ProjectDir "Program.cs") -Encoding UTF8

@"
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;

namespace AvaloniaStaticLinkSmoke;

public sealed partial class App : Application
{
    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.MainWindow = new MainWindow();
        }

        base.OnFrameworkInitializationCompleted();
    }
}
"@ | Set-Content -Path (Join-Path $ProjectDir "App.axaml.cs") -Encoding UTF8

@"
<Application xmlns="https://github.com/avaloniaui"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
             x:Class="AvaloniaStaticLinkSmoke.App">
  <Application.Styles>
    <FluentTheme />
  </Application.Styles>
</Application>
"@ | Set-Content -Path (Join-Path $ProjectDir "App.axaml") -Encoding UTF8

@"
using Avalonia.Controls;

namespace AvaloniaStaticLinkSmoke;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
    }
}
"@ | Set-Content -Path (Join-Path $ProjectDir "MainWindow.axaml.cs") -Encoding UTF8

@"
<Window xmlns="https://github.com/avaloniaui"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Class="AvaloniaStaticLinkSmoke.MainWindow"
        Width="420"
        Height="220"
        Title="Avalonia StaticLink Smoke">
  <Border Padding="24">
    <StackPanel Spacing="8" HorizontalAlignment="Center" VerticalAlignment="Center">
      <TextBlock Text="Avalonia $AvaloniaVersion" FontSize="24" FontWeight="SemiBold" HorizontalAlignment="Center" />
      <TextBlock Text="StaticLink NativeAOT smoke publish" HorizontalAlignment="Center" />
    </StackPanel>
  </Border>
</Window>
"@ | Set-Content -Path (Join-Path $ProjectDir "MainWindow.axaml") -Encoding UTF8
