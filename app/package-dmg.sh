#!/bin/bash
# 打 dmg 安装包：从 git 已提交的版本（git archive HEAD）的干净副本编译通用版，ad-hoc 签名，
# 装进 dmg（里面有 TokenBar.app 和「应用程序」快捷方式，拖进去就装好了）。
# 工作区里没提交的改动不会进安装包。
# 用法：bash app/package-dmg.sh        → dist/TokenBar-<版本号>.dmg，最后输出它的 SHA-256（贴到 GitHub Release）
# 构建号 CFBundleVersion 用提交数（git rev-list --count HEAD），只改干净副本里的 Info.plist，仓库里的不动。
# 有 Developer ID 证书时：TOKENBAR_SIGN_IDENTITY="Developer ID Application: …" bash app/package-dmg.sh
#   （公证 notarytool 要 Apple ID 凭据，需要自己在终端里跑，脚本不做）
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO/app/Info.plist")"
BUILD="$(git -C "$REPO" rev-list --count HEAD)"
NAME="TokenBar-$VERSION"
DIST="$REPO/dist"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tokenbar-dmg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "版本 ${VERSION}（构建号 ${BUILD}），从 $(git -C "$REPO" rev-parse --short HEAD) 打包"
if [ -n "$(git -C "$REPO" status --porcelain -- app)" ]; then
  echo "提醒：app/ 下有没提交的改动，不会进安装包" >&2
fi

mkdir -p "$WORK/src"
git -C "$REPO" archive HEAD | tar -x -C "$WORK/src"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$WORK/src/app/Info.plist"
bash "$WORK/src/app/build.sh" --no-install --universal
APP="$WORK/src/app/build/TokenBar.app"

SIGN_ID="${TOKENBAR_SIGN_IDENTITY:--}"
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --deep --strict "$APP"

STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$DIST"
rm -f "$DIST/$NAME.dmg"
hdiutil create -volname "Token Bar $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$NAME.dmg" >/dev/null
hdiutil verify "$DIST/$NAME.dmg" >/dev/null

echo "已打包：$DIST/$NAME.dmg（$(du -h "$DIST/$NAME.dmg" | cut -f1)，$(lipo -archs "$APP/Contents/MacOS/TokenBar")，构建号 $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")）"
echo "SHA-256（贴到 Release 说明里）："
(cd "$DIST" && shasum -a 256 "$NAME.dmg")
