#!/bin/sh
# Sparkle 은 유니버설(x86_64 + arm64) 바이너리로만 나온다 → 앱에 넣은 뒤 x86_64 를 빼서 애플 실리콘 전용으로 맞춘다
# (iSQL 은 arm64 전용, 사용자 2026-11-15 · 2026-11-19). Xcode 빌드 단계 "Thin Sparkle" 이 부른다.
# 빼면 서명이 깨지므로 안쪽부터 다시 서명한다 (식별자·엔타이틀먼트·플래그는 그대로). 내보내기(developer-id)가 다시 서명해도 그대로 arm64.
set -e
FW="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
[ -d "$FW" ] || { echo "warning: Sparkle.framework 가 아직 없어 줄이지 못함 ($FW)"; exit 0; }
V="$FW/Versions/B"
BINS="$V/XPCServices/Downloader.xpc/Contents/MacOS/Downloader
$V/XPCServices/Installer.xpc/Contents/MacOS/Installer
$V/Updater.app/Contents/MacOS/Updater
$V/Autoupdate
$V/Sparkle"
changed=0
echo "$BINS" | while read -r b; do
	[ -f "$b" ] || continue
	if lipo -archs "$b" | grep -q x86_64; then lipo -remove x86_64 "$b" -output "$b"; fi
done
ID="${EXPANDED_CODE_SIGN_IDENTITY:--}"
sign() { codesign --force --sign "$ID" --options runtime --preserve-metadata=identifier,entitlements,flags --timestamp=none "$1"; }
sign "$V/XPCServices/Downloader.xpc"
sign "$V/XPCServices/Installer.xpc"
sign "$V/Updater.app"
sign "$V/Autoupdate"
sign "$FW"
echo "Sparkle → $(lipo -archs "$V/Sparkle")"
