#!/bin/bash
# Builds DockMin as a .app bundle (required for a stable TCC permission
# identity) and signs it ad-hoc.
#
# Compiles directly with swiftc rather than `swift build`: this machine's
# Command Line Tools ship a skewed PackageDescription (.swiftinterface built
# by Swift 6.3.3 next to a Swift 5.10 dylib), which breaks SwiftPM manifest
# linking. On a machine with a consistent toolchain or full Xcode, `swift
# build` also works — this path is the portable, dependency-free one.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/DockMin.app"
BIN_NAME="DockMin"
SRC="Sources/DockMin"
SDK="$(xcrun --show-sdk-path)"

# Signing identity. Ad-hoc ("-") by default, which means the code hash changes
# whenever the code does — and TCC keys the Accessibility / Input Monitoring
# grants to that hash, so every rebuild costs you two new permission prompts.
# To keep the grants across rebuilds, make a self-signed code-signing certificate
# (Keychain Access → Certificate Assistant → Create a Certificate, type: Code
# Signing) and build with:
#     SIGN_IDENTITY="DockMin Local" ./Scripts/make-app.sh
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "==> compiling with swiftc ($SRC/*.swift)"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

xcrun swiftc -O \
  -sdk "$SDK" \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  -framework CoreGraphics \
  -framework ApplicationServices \
  -framework QuartzCore \
  -framework ServiceManagement \
  "${SRC}"/*.swift \
  -o "${APP}/Contents/MacOS/${BIN_NAME}"

cp "${SRC}/Info.plist" "${APP}/Contents/Info.plist"

echo "==> code signing (identity: ${SIGN_IDENTITY})"
codesign --force --sign "$SIGN_IDENTITY" "$APP"

# Re-signing changes the binary's code hash. Whether the existing Input
# Monitoring grant still applies is not something a build script can detect
# (reading that record needs root), so don't touch TCC here — resetting it only
# deletes a grant that may still be valid and forces a manual re-tick.
# After a rebuild, check the app's own reading instead and re-authorize in
# System Settings only if it stays false:
#     ./Scripts/make-app.sh --status   (or the menu bar icon: red = missing)

echo "==> done: $(pwd)/${APP}"

case "${1:-}" in
  --run)
    # `open` would just activate an already-running copy — i.e. the *previous*
    # binary — so the new build would silently never get tested.
    pkill -f "${APP}/Contents/MacOS/${BIN_NAME}" 2>/dev/null || true
    sleep 1
    echo "==> launching"
    open "$APP"
    ;;
  --install)
    # The canonical place to run it from: a stable path keeps the TCC records and
    # the login item pointing at one copy instead of at a build directory.
    DEST="/Applications/${BIN_NAME}.app"
    echo "==> installing ${DEST}"
    pkill -f "${BIN_NAME}.app/Contents/MacOS/${BIN_NAME}" 2>/dev/null || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    codesign --force --sign "$SIGN_IDENTITY" "$DEST"
    sleep 1
    open "$DEST"
    cat <<EOF

==> installed and running from ${DEST}
    菜单栏图标现在是默认色就是就绪了；若显示红色，去
      系统设置 → 隐私与安全 → 辅助功能 / 输入监控
    把 DockMin 勾上（列表里没有就用「+」添加 ${DEST}）。
    想让开机自启指向这个路径：菜单栏图标 →「登录时启动」关一下再开一次
    （之前那次注册指向的是 build/ 里那份）。
    build/ 里那份可以继续开发用，但别和这份同时跑——两个实例会抢同一次点击。
EOF
    ;;
  --status|--dump-dock|--hit)
    # Diagnostics run against the freshly built bundle's signing identity.
    "${APP}/Contents/MacOS/${BIN_NAME}" "$@"
    ;;
esac
