#!/bin/bash
# The direct swiftc/lipo build flow was informed by MouseToucher.
# Copyright (c) 2025 Roger Hughes, used under the MIT License.
# See THIRD_PARTY_NOTICES.md. Magic Mouse Toolkit changes: GPL-3.0-only.

set -euo pipefail
cd "$(dirname "$0")"

export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"

APP="${APP_NAME:-Magic Mouse Toolkit.app}"
APP_INFO_PLIST="${APP_INFO_PLIST:-Info.plist}"
BIN="MagicMouseToolkit"
BUILD_DIR="${BUILD_DIR:-build}"
SIGN_ID="${SIGN_ID:--}"

SWIFT_FILES=(Sources/*.swift)
FLAGS=(-import-objc-header Sources/MultitouchBridge.h
       -F /System/Library/PrivateFrameworks -framework MultitouchSupport
       -framework AppKit -framework SwiftUI -framework QuartzCore -framework IOKit -O)

mkdir -p "$BUILD_DIR"
# フェーズ2のLiquid Glass(glassEffect)はmacOS 26+のAPIのためターゲットを引き上げ
swiftc "${SWIFT_FILES[@]}" "${FLAGS[@]}" -target arm64-apple-macos26.0  -o "$BUILD_DIR/$BIN-arm64"
swiftc "${SWIFT_FILES[@]}" "${FLAGS[@]}" -target x86_64-apple-macos26.0 -o "$BUILD_DIR/$BIN-x86_64"
lipo -create "$BUILD_DIR/$BIN-arm64" "$BUILD_DIR/$BIN-x86_64" -output "$BUILD_DIR/$BIN"

rm -rf "$BUILD_DIR/$APP"
mkdir -p "$BUILD_DIR/$APP/Contents/MacOS" "$BUILD_DIR/$APP/Contents/Resources"
cp "$APP_INFO_PLIST" "$BUILD_DIR/$APP/Contents/Info.plist"
cp "$BUILD_DIR/$BIN" "$BUILD_DIR/$APP/Contents/MacOS/"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$BUILD_DIR/$APP/Contents/Resources/"

# iCloud Drive 配下では com.apple.FinderInfo / fileprovider 拡張属性が
# 署名の直前に再付与されることがあり codesign が失敗するため、リトライ付きで署名する
SIGN_FLAGS=(--force --sign "$SIGN_ID")
if [ "$SIGN_ID" != "-" ]; then
  MATCHES=$(security find-identity -v -p codesigning)
  if ! grep -Fq -- "$SIGN_ID" <<< "$MATCHES"; then
    echo "Signing identity not available: $SIGN_ID" >&2
    exit 1
  fi
  CERT_SHA=$(awk -v identity="$SIGN_ID" 'index($0, identity) { print $2; exit }' <<< "$MATCHES")
  BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_INFO_PLIST")
  SIGN_FLAGS+=(--timestamp=none --requirements "=designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$CERT_SHA\"")
fi

for attempt in 1 2 3; do
  xattr -cr "$BUILD_DIR/$APP"
  if codesign "${SIGN_FLAGS[@]}" "$BUILD_DIR/$APP"; then
    break
  fi
  if [ "$attempt" = 3 ]; then
    echo "Code signing failed after three attempts" >&2
    exit 1
  fi
  sleep 1
done
codesign --verify --deep --strict "$BUILD_DIR/$APP"
echo "Built: $BUILD_DIR/$APP"
