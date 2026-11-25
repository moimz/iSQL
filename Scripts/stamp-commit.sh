#!/bin/sh
# 앱 화면에 "버전 2.9 (빌드 210 · abc1234)" 로 보이도록 커밋 해시를 Info.plist 의 ISQLCommit 에 넣는다.
# 커밋하지 않은 변경이 있으면 해시 뒤에 "+" 를 붙인다. (빌드 번호는 설치 스크립트가 CURRENT_PROJECT_VERSION 으로 넘긴다)
# Info.plist 처리가 끝난 뒤에 돌도록 그 파일을 입력으로 둔다 (아니면 처리하면서 덮어쓴다)
cd "$SRCROOT" || exit 0
hash=$(git rev-parse --short HEAD 2>/dev/null) || exit 0
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then hash="$hash+"; fi
plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
/usr/libexec/PlistBuddy -c "Delete :ISQLCommit" "$plist" >/dev/null 2>&1
/usr/libexec/PlistBuddy -c "Add :ISQLCommit string $hash" "$plist"
