#!/bin/bash
# 编译并安装菜单栏 App（纯命令行，不需要 Xcode 工程）
set -euo pipefail

# 用法：bash app/build.sh [--no-install] [--universal] [--devtools]
#   --no-install：只编译到 app/build/，不替换 ~/Applications/TokenBar.app
#   --universal：同时编 arm64 和 x86_64 合成通用版（打 dmg 用；平时只编本机架构，快一倍）
#   --devtools：带上开发工具入口（--render / --render-check 离屏渲染、--icon 生成图标）；装给用户和打 dmg 不加
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$HOME/Applications/TokenBar.app"
BUNDLE="$APP_DIR/build/TokenBar.app"
NO_INSTALL=0; UNIVERSAL=0; DEVTOOLS=()
for a in "$@"; do
  case "$a" in
    --no-install) NO_INSTALL=1 ;;
    --universal) UNIVERSAL=1 ;;
    --devtools) DEVTOOLS=(-D DEVTOOLS) ;;
    *) echo "不认识的参数：$a" >&2; exit 2 ;;
  esac
done

cd "$APP_DIR"
source ./sdk.sh
rm -rf build
mkdir -p "$BUNDLE/Contents/MacOS"

if [ "$UNIVERSAL" = 1 ]; then ARCHS="arm64 x86_64"; else ARCHS="$(uname -m)"; fi
SLICES=()
for arch in $ARCHS; do
  /usr/bin/swiftc \
    -O -swift-version 5 -strict-concurrency=complete -parse-as-library ${DEVTOOLS[@]+"${DEVTOOLS[@]}"} \
    -sdk "$SDK" \
    -target "$arch-apple-macosx14.0" \
    -framework SwiftUI -framework AppKit -framework WebKit -framework Security -framework Network -lsqlite3 \
    -module-cache-path "${SWIFT_MODULECACHE_PATH:-$APP_DIR/build/module-cache}" \
    -o "build/TokenBar-$arch" Sources/Core/*.swift Sources/App/*.swift
  SLICES+=("build/TokenBar-$arch")
done
lipo -create "${SLICES[@]}" -output "$BUNDLE/Contents/MacOS/TokenBar"
rm -f "${SLICES[@]}"

cp Info.plist "$BUNDLE/Contents/Info.plist"

# App 图标：先 bash app/build.sh --no-install --devtools，再在 app/ 下跑 ./build/TokenBar.app/Contents/MacOS/TokenBar --icon 生成 AppIcon.icns（油量表 logo）
mkdir -p "$BUNDLE/Contents/Resources"
if [ -f AppIcon.icns ]; then cp AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"; fi

# --no-install：只编译到 build/，不替换正在运行的 ~/Applications/TokenBar.app（先自检再装）
if [ "$NO_INSTALL" = 1 ]; then echo "已编译（未安装）: ${BUNDLE}（$(lipo -archs "$BUNDLE/Contents/MacOS/TokenBar")）"; exit 0; fi

mkdir -p "$HOME/Applications"
rm -rf "$OUT"
cp -R "$BUNDLE" "$OUT"
# 签名：默认 ad-hoc（-），每次重新编译签名都会变，钥匙串会把新版本当成新程序，重装后问一次授权。
# 想重装后一次都不问：在「钥匙串访问 → 证书助理 → 创建证书」建一个「代码签名」类型的自签名证书，
# 再用 TOKENBAR_SIGN_IDENTITY="证书名" bash app/build.sh 安装；同一证书签出的各版本被钥匙串当成同一个程序。
SIGN_ID="${TOKENBAR_SIGN_IDENTITY:-}"
if [ -n "$SIGN_ID" ]; then
  # 用证书签名时 codesign 要用私钥，系统可能问一次是否允许
  if codesign --force --deep --sign "$SIGN_ID" "$OUT"; then
    codesign -dv "$OUT" 2>&1 | grep '^Authority=' | head -1 | sed 's/^/  签名证书：/' || true
  else
    echo "用证书「${SIGN_ID}」签名失败，改用 ad-hoc 签名（重装后钥匙串会再问一次）" >&2
    codesign --force --deep --sign - "$OUT"
  fi
else
  codesign --force --deep --sign - "$OUT" >/dev/null 2>&1 || codesign --force --sign - "$OUT"
fi

echo "已编译: $OUT"
ls -l "$OUT/Contents/MacOS/TokenBar" | awk '{print "  二进制:", $5, "bytes"}'
codesign -dv "$OUT" 2>&1 | sed -n '1,3p' | sed 's/^/  /'
