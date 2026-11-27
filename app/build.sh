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

# build/ 里的是开发副本：从系统应用登记里去掉，免得通知中心挑中它（显示旧名字、点通知拉起开发版）。
# 用 --devtools 跑 --render 时系统会再登记一次，渲染模式结束时自己再去掉
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$BUNDLE" >/dev/null 2>&1 || true

# --no-install：只编译到 build/，不替换正在运行的 ~/Applications/TokenBar.app（先自检再装）
if [ "$NO_INSTALL" = 1 ]; then echo "已编译（未安装）: ${BUNDLE}（$(lipo -archs "$BUNDLE/Contents/MacOS/TokenBar")）"; exit 0; fi

mkdir -p "$HOME/Applications"
rm -rf "$OUT"
cp -R "$BUNDLE" "$OUT"
# 签名：默认 ad-hoc（-），每次重新编译签名都会变，钥匙串会把新版本当成新程序，重装后问一次授权。
# 想重装后一次都不问：在「钥匙串访问 → 证书助理 → 创建证书」建一个「代码签名」类型的自签名证书，
# 再用 TOKENBAR_SIGN_IDENTITY="证书名" bash app/build.sh 安装；同一证书签出的各版本被钥匙串当成同一个程序。
# 默认找名为「TokenBar Dev」的证书；没有这张证书时自动退回 ad-hoc（会提示一句）。
# TOKENBAR_SIGN_IDENTITY="" 强制 ad-hoc；不设时用默认证书名
SIGN_ID="${TOKENBAR_SIGN_IDENTITY-TokenBar Dev}"
if [ -n "$SIGN_ID" ]; then
  # 用证书签名时 codesign 要用私钥，系统可能问一次是否允许
  if sign_err=$(codesign --force --deep --sign "$SIGN_ID" "$OUT" 2>&1); then
    codesign -dv "$OUT" 2>&1 | grep '^Authority=' | head -1 | sed 's/^/  签名证书：/' || true
  else
    echo "用证书「${SIGN_ID}」签名失败（$(printf '%s' "$sign_err" | tail -1)），改用 ad-hoc 签名（重装后钥匙串会再问一次）" >&2
    codesign --force --deep --sign - "$OUT"
  fi
else
  codesign --force --deep --sign - "$OUT" >/dev/null 2>&1 || codesign --force --sign - "$OUT"
fi

"$LSREGISTER" -f "$OUT" >/dev/null 2>&1 || true    # 签名变了，重新登记正式版

echo "已编译: $OUT"
ls -l "$OUT/Contents/MacOS/TokenBar" | awk '{print "  二进制:", $5, "bytes"}'
codesign -dv "$OUT" 2>&1 | sed -n '1,3p' | sed 's/^/  /'

# 只换文件不会让正在运行的旧进程变成新版：退出旧的、打开新的（TOKENBAR_NO_RESTART=1 可跳过）
restart_by_quit_open() {
  if pgrep -f "$OUT/Contents/MacOS/TokenBar" >/dev/null; then
    osascript -e 'tell application id "com.lemon.deepseek-tokenbar" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6; do pgrep -f "$OUT/Contents/MacOS/TokenBar" >/dev/null || break; sleep 0.5; done
    pkill -f "$OUT/Contents/MacOS/TokenBar" 2>/dev/null || true
    sleep 0.5
    pkill -9 -f "$OUT/Contents/MacOS/TokenBar" 2>/dev/null || true
  fi
  if open "$OUT"; then echo "  已重新打开新版"; else echo "  没能自动打开新版，请手动打开 $OUT" >&2; fi
}
if [ "${TOKENBAR_NO_RESTART:-0}" != 1 ]; then
  # 有守护（launchd 常驻任务）且指向这份 App 时只让 launchd 重启它：先 quit 再 open 会出现两个进程——
  # 被强制结束的守护实例被 launchd 拉起，open 又开一个，两个各读一次钥匙串，重装就要输两次密码（11/5 实测）
  GUARD="gui/$(id -u)/com.lemon.deepseek-tokenbar.alive"
  if launchctl print "$GUARD" 2>/dev/null | grep -qF "program = $OUT/Contents/MacOS/TokenBar"; then
    # 记下旧进程号：kickstart 在新进程拉起前就返回，旧实例收尾时还在，不能把它当成新版
    old=" $(pgrep -f "$OUT/Contents/MacOS/TokenBar" | tr '\n' ' ') "
    launchctl kickstart -k "$GUARD" >/dev/null 2>&1 || true
    # launchd 的 ThrottleInterval 是 10 秒：上次启动不久时会等一会儿才拉起，最多等 15 秒
    started=0; i=0
    while [ "$i" -lt 30 ] && [ "$started" = 0 ]; do
      sleep 0.5; i=$((i + 1))
      for p in $(pgrep -f "$OUT/Contents/MacOS/TokenBar"); do
        case "$old" in *" $p "*) ;; *) started=1 ;; esac
      done
    done
    if [ "$started" = 1 ]; then echo "  已重启守护进程（新版）"
    elif launchctl print "$GUARD" 2>/dev/null | grep -qE "state = (running|spawn scheduled)"; then
      # 守护还在拉起中：再 open 一个就又是两个进程、两次钥匙串密码
      echo "  守护进程正在启动，稍等几秒；没出现的话手动打开 $OUT" >&2
    else
      echo "  守护进程没起来，改用退出后重新打开" >&2; restart_by_quit_open
    fi
  else
    restart_by_quit_open
  fi
fi
