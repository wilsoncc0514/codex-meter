#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${CODEX_METER_VERSION:-0.4.0}"
BUILD_NUMBER="${CODEX_METER_BUILD_NUMBER:-14}"
SIGN_IDENTITY="${CODEX_METER_SIGN_IDENTITY:--}"
BUILD_EXTRA_ARGS=()
if [ "${CODEX_METER_DISABLE_SWIFTPM_SANDBOX:-0}" = "1" ]; then
  BUILD_EXTRA_ARGS+=(--disable-sandbox)
fi

swift_build() {
  if [ "${#BUILD_EXTRA_ARGS[@]}" -gt 0 ]; then
    swift build "$@" "${BUILD_EXTRA_ARGS[@]}"
  else
    swift build "$@"
  fi
}

if [ "${CODEX_METER_UNIVERSAL:-0}" = "1" ]; then
  ARM_SCRATCH="$ROOT_DIR/.build-arm64"
  X86_SCRATCH="$ROOT_DIR/.build-x86_64"
  UNIVERSAL_DIR="$ROOT_DIR/.build-universal"
  swift_build -c release --triple arm64-apple-macosx14.0 --scratch-path "$ARM_SCRATCH"
  swift_build -c release --triple x86_64-apple-macosx14.0 --scratch-path "$X86_SCRATCH"
  ARM_BIN_DIR="$(swift_build -c release --triple arm64-apple-macosx14.0 --scratch-path "$ARM_SCRATCH" --show-bin-path)"
  X86_BIN_DIR="$(swift_build -c release --triple x86_64-apple-macosx14.0 --scratch-path "$X86_SCRATCH" --show-bin-path)"
  mkdir -p "$UNIVERSAL_DIR"
  lipo -create "$ARM_BIN_DIR/CodexMeter" "$X86_BIN_DIR/CodexMeter" -output "$UNIVERSAL_DIR/CodexMeter"
  BIN_DIR="$UNIVERSAL_DIR"
else
  swift_build -c release
  BIN_DIR="$(swift_build -c release --show-bin-path)"
fi

APP_NAME="Codex 额度"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/CodexMeter" "$APP_DIR/Contents/MacOS/CodexMeter"
chmod +x "$APP_DIR/Contents/MacOS/CodexMeter"

/usr/libexec/PlistBuddy -c "Clear dict" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string app.codex-meter.prototype" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string CodexMeter" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMultipleInstancesProhibited bool true" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSApplicationCategoryType string public.app-category.utilities" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSUserNotificationUsageDescription string Codex 额度使用通知来提醒额度不足和额度恢复事件。" "$APP_DIR/Contents/Info.plist"

ICON_SOURCE="$ROOT_DIR/Resources/AppIcon-1024.png"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"
if [ ! -f "$ICON_SOURCE" ]; then
  echo "Missing app icon source: $ICON_SOURCE" >&2
  exit 1
fi
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"
