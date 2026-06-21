using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace StaticLink.Avalonia.Native;

internal static class MacOSFontWarmup
{
    [ModuleInitializer]
    internal static void Initialize()
    {
        if (!OperatingSystem.IsMacOS())
        {
            return;
        }

        try
        {
            var nsApplication = objc_getClass("NSApplication");
            var sharedApplication = sel_registerName("sharedApplication");
            _ = objc_msgSend(nsApplication, sharedApplication);

            var nsFont = objc_getClass("NSFont");
            var systemFontOfSize = sel_registerName("systemFontOfSize:");
            var systemFontOfSizeWidth = sel_registerName("systemFontOfSize:width:");

            _ = objc_msgSend(nsFont, systemFontOfSize, 13.0);
            _ = objc_msgSend(nsFont, systemFontOfSizeWidth, 13.0, 0.0);
        }
        catch
        {
            // Defensive AppKit font-cache warmup must never fail application startup.
        }
    }

    [DllImport("/usr/lib/libobjc.A.dylib", EntryPoint = "objc_getClass")]
    private static extern IntPtr objc_getClass([MarshalAs(UnmanagedType.LPUTF8Str)] string name);

    [DllImport("/usr/lib/libobjc.A.dylib", EntryPoint = "sel_registerName")]
    private static extern IntPtr sel_registerName([MarshalAs(UnmanagedType.LPUTF8Str)] string name);

    [DllImport("/usr/lib/libobjc.A.dylib", EntryPoint = "objc_msgSend")]
    private static extern IntPtr objc_msgSend(IntPtr receiver, IntPtr selector);

    [DllImport("/usr/lib/libobjc.A.dylib", EntryPoint = "objc_msgSend")]
    private static extern IntPtr objc_msgSend(IntPtr receiver, IntPtr selector, double value);

    [DllImport("/usr/lib/libobjc.A.dylib", EntryPoint = "objc_msgSend")]
    private static extern IntPtr objc_msgSend(IntPtr receiver, IntPtr selector, double value, double width);
}
