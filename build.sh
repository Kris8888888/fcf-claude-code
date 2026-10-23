#!/bin/bash
# 构建「FCF启动claude code.app」通用版（Apple 芯片 + Intel），ad-hoc 签名，产出 dmg 和 zip 安装包
set -euo pipefail
cd "$(dirname "$0")"
APP_NAME="FCF启动claude code"; EXE="Duihuatai"; OUT="build"; APP="$OUT/$APP_NAME.app"; MIN="14.0"
rm -rf "$OUT"; mkdir -p "$OUT/arm64" "$OUT/x86_64" "$APP/Contents/MacOS" "$APP/Contents/Resources"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
COMMON=(-O -swift-version 5 -sdk "$SDK" -parse-as-library -module-name Duihuatai Sources/*.swift -framework AppKit -framework SwiftUI)
echo "编译 arm64…";  swiftc "${COMMON[@]}" -target arm64-apple-macos$MIN  -o "$OUT/arm64/$EXE"
echo "编译 x86_64…"; swiftc "${COMMON[@]}" -target x86_64-apple-macos$MIN -o "$OUT/x86_64/$EXE"
lipo -create "$OUT/arm64/$EXE" "$OUT/x86_64/$EXE" -output "$APP/Contents/MacOS/$EXE"
echo "生成图标…"; swiftc -O -sdk "$SDK" tools/MakeIcon.swift -o "$OUT/MakeIcon" -framework AppKit; "$OUT/MakeIcon" "$OUT/AppIcon.iconset"; iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"; echo -n "APPL????" > "$APP/Contents/PkgInfo"
# 用固定的自签名证书签名：系统按「编号 + 证书」认 App，更新后文件夹访问授权不会丢。
# 证书在本机钥匙串里（备份：~/Library/Application Support/com.likang.duihuatai-signing/），找不到才退回临时签名
SIGN_ID="FCF Claude Code Signing"
if security find-identity -p codesigning | grep -q "$SIGN_ID"; then
  echo "签名（${SIGN_ID}）…"; codesign --force --deep --sign "$SIGN_ID" --identifier com.likang.duihuatai "$APP"
else
  echo "⚠️ 没找到签名证书，用临时签名（每次打包后系统都会重新询问文件夹权限）"
  codesign --force --deep --sign - --identifier com.likang.duihuatai "$APP"
fi
codesign -dr - "$APP" 2>&1 | tail -1
echo "打包…"
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
PKG="FCF-Claude-Code-$VER"
(cd "$OUT" && ditto -c -k --keepParent "$APP_NAME.app" "$PKG.zip")
rm -rf "$OUT/dmgroot"; mkdir -p "$OUT/dmgroot"; cp -R "$APP" "$OUT/dmgroot/"; ln -s /Applications "$OUT/dmgroot/拖到这里安装"
hdiutil create -volname "$APP_NAME" -srcfolder "$OUT/dmgroot" -ov -format UDZO "$OUT/$PKG.dmg" >/dev/null
rm -rf "$OUT/dmgroot"
echo "完成：$APP"
echo "安装包：$OUT/$PKG.dmg  $OUT/$PKG.zip"
