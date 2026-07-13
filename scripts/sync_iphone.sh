#!/bin/bash
# iPhone (2) 앱 샌드박스의 CSV 로그(Documents/data/)를 데스크탑으로 자동 동기화한다.
# launchd(com.emgfes.iphone-sync)가 5분마다 실행 — iPhone이 USB 연결 + 잠금 해제
# 상태일 때만 실제 복사가 일어나고, 아니면 조용히 건너뛴다.
# 로그: ~/Library/Logs/emgfes-iphone-sync.log

DEVICE_ID="00008101-0002042034DB001E"   # iPhone (2)
BUNDLE_ID="com.emgfes.flutterApp"
DEST="$HOME/Desktop/data"
LOG="$HOME/Library/Logs/emgfes-iphone-sync.log"

mkdir -p "$DEST"
ts() { date "+%Y-%m-%d %H:%M:%S"; }

# 새 파일을 임시 폴더로 받은 뒤 rsync 로 병합 — 기존 파일과의 충돌을 피한다.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if out=$(xcrun devicectl device copy from \
    --device "$DEVICE_ID" \
    --source "Documents/data" \
    --destination "$TMP" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" 2>&1); then
  n=$(rsync -a --itemize-changes "$TMP"/ "$DEST"/ | grep -c '^>f')
  echo "$(ts) OK: 새 파일 ${n}개 → $DEST" >> "$LOG"
else
  reason=$(echo "$out" | grep -oE 'kAMD[A-Za-z]+|error 10[0-9][0-9]' | head -1)
  echo "$(ts) skip: ${reason:-unknown} (기기 미연결 또는 잠금)" >> "$LOG"
fi
