#!/usr/bin/env bash
set -euo pipefail

RID="${RID:-osx-arm64}"
OUTPUT_DIR="${OUTPUT_DIR:-$PWD/External/NativeStatic/$RID/native}"

case "$RID" in
  osx-arm64) ARCH="arm64" ;;
  osx-x64) ARCH="x86_64" ;;
  *) echo "Unsupported RID: $RID" >&2; exit 2 ;;
esac

mkdir -p "$OUTPUT_DIR"

src="$OUTPUT_DIR/macos_font_preinit.m"
cat > "$src" <<'OBJC'
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

__attribute__((constructor(101)))
static void StaticLinkAvaloniaPreinitializeAppKitFonts(void)
{
    @autoreleasepool
    {
        [NSApplication sharedApplication];
        [NSFont systemFontOfSize:13.0];
        ((id (*)(id, SEL, CGFloat, CGFloat))objc_msgSend)([NSFont class], sel_registerName("systemFontOfSize:width:"), 13.0, 0.0);
    }
}
OBJC

clang -arch "$ARCH" \
  -mmacosx-version-min=12.0 \
  -fobjc-arc \
  -c "$src" \
  -o "$OUTPUT_DIR/macos_font_preinit.o"

rm -f "$src"
echo "Wrote $OUTPUT_DIR/macos_font_preinit.o"
