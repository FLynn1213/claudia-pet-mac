#!/bin/sh
# 编译 mac 版外壳并打成 .app 包（系统通知需要）：需要 Xcode 命令行工具（xcode-select --install），不需要完整 Xcode
set -eu
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -swift-version 5 -o build/claudia-pet.bin ClaudiaPet.swift -framework Cocoa -framework WebKit -framework UserNotifications

APP=build/claudia-pet.app
VER=$(cat ../VERSION 2>/dev/null || echo 0)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv build/claudia-pet.bin "$APP/Contents/MacOS/claudia-pet"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.claudia-pet</string>
<key>CFBundleName</key><string>claudia-pet</string>
<key>CFBundleDisplayName</key><string>claudia-pet</string>
<key>CFBundleExecutable</key><string>claudia-pet</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$VER</string>
<key>CFBundleShortVersionString</key><string>$VER</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# 应用图标：用仓库里原来的 icon/AppIcon.png 生成 .icns；失败也不影响运行
ICON=../icon/AppIcon.png
if [ -f "$ICON" ] && command -v iconutil >/dev/null 2>&1; then
  SET=build/AppIcon.iconset
  rm -rf "$SET"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON" --out "$SET/icon_${s}x${s}.png" >/dev/null 2>&1 || true
    sips -z $((s*2)) $((s*2)) "$ICON" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || true
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1 || echo "（图标没生成，不影响使用）"
  rm -rf "$SET"
fi


# 签名：用固定的证书签，重新编译后辅助功能（聊天模式动画要用）的授权才不会失效。
# 顺序：环境变量 CLAUDIA_SIGN_ID（证书名或指纹）→ 钥匙串里第一个「Apple Development」证书（按指纹，不写死账号）
# → 都没有就用 ad-hoc 签名（不需要开发者账号，系统通知中心认这个，但每次编译签名都变，辅助功能要重新授权）
SIGN_ID="${CLAUDIA_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $2; exit }')}"
if [ -n "$SIGN_ID" ]; then
  codesign --force --deep -s "$SIGN_ID" "$APP" >/dev/null 2>&1 && echo "用证书 $SIGN_ID 签名" \
    || { echo "（用证书 $SIGN_ID 签名失败，改用 ad-hoc，辅助功能每次编译后要重新授权）"; codesign --force --deep -s - "$APP" >/dev/null 2>&1; }
else
  codesign --force --deep -s - "$APP" >/dev/null 2>&1 || echo "（codesign 失败，通知可能不可用，会退回用 osascript）"
fi

# build/claudia-pet 留作入口（接入配置里写的就是这个路径），指向包里的可执行文件
rm -f build/claudia-pet
ln -s claudia-pet.app/Contents/MacOS/claudia-pet build/claudia-pet
echo "编译完成：$(pwd)/$APP"
