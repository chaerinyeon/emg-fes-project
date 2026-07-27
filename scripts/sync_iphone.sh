#!/bin/bash
# iPhone (2) 앱 샌드박스의 CSV 로그(Documents/data/)를 로컬로 자동 동기화한다.
# launchd(com.emgfes.iphone-sync)가 5분마다 실행 — iPhone이 USB 연결 + 잠금 해제
# 상태일 때만 실제 복사가 일어나고, 아니면 조용히 건너뛴다.
# 로그: ~/Library/Logs/emgfes-iphone-sync.log

DEVICE_ID="00008101-0002042034DB001E"   # iPhone (2)
BUNDLE_ID="com.emgfes.flutterApp"
# ~/Desktop 은 macOS TCC 보호 폴더라 launchd 컨텍스트의 rsync 가 권한 거부된다
# (전체 디스크 접근을 /bin/bash 에 주지 않는 한). 홈 직하 폴더는 보호 대상이 아니다.
DEST="$HOME/emgfes-data"
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
  # rsync 출력을 변수로 받는다 — 파이프로 넘기면 $? 가 grep 것이 되어 rsync 실패가
  # 그대로 묻힌다(실제로 TCC 권한 거부가 185회 "OK: 0개" 로 위장된 적 있음).
  rsync_out=$(rsync -a --itemize-changes "$TMP"/ "$DEST"/ 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    reason=$(printf '%s\n' "$rsync_out" | grep -m1 -iE 'error|denied|permitted')
    echo "$(ts) FAIL: rsync rc=$rc — ${reason:-알 수 없는 오류} (대상: $DEST)" >> "$LOG"
    exit 1
  fi
  n=$(printf '%s\n' "$rsync_out" | grep -c '^>f')
  echo "$(ts) OK: 새 파일 ${n}개 → $DEST" >> "$LOG"

  # ── GitHub `data` 브랜치 자동 업로드 ─────────────────────────────────
  # 새 CSV 가 들어왔을 때만 커밋하고, 미푸시 커밋이 있으면(이전 오프라인 실패 포함) 푸시한다.
  # data 브랜치는 setup_data_repo.sh 가 미리 만든다 — .git 이 없으면 이 블록은 조용히 건너뛴다.
  # git/gh 는 /opt/homebrew/bin 에 있어 launchd 기본 PATH 에 없으므로 여기서 PATH 를 맞춘다.
  if [ -d "$DEST/.git" ]; then
    export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

    # GitHub 하드리밋(100MB/파일) 초과분은 스테이징에서 빼고 크게 경고 — 푸시를 깨뜨리지 않는다.
    if [ "$n" -gt 0 ]; then
      git -C "$DEST" add -A
      while IFS= read -r big; do
        [ -n "$big" ] || continue
        git -C "$DEST" reset -q -- "$big" 2>/dev/null || true
        echo "$(ts) WARN: 100MB 초과로 업로드 제외 — $big" >> "$LOG"
      done < <(cd "$DEST" && git diff --cached --name-only -z | tr '\0' '\n' | while IFS= read -r p; do [ -f "$p" ] && [ "$(stat -f%z "$p" 2>/dev/null || echo 0)" -ge 104857600 ] && echo "$p"; done)

      if ! git -C "$DEST" diff --cached --quiet; then
        if git -C "$DEST" commit -qm "data: sync $(ts) (${n}개 신규)"; then
          echo "$(ts) GIT: 커밋 (${n}개 신규)" >> "$LOG"
        else
          echo "$(ts) FAIL: git commit rc=$? — data 브랜치" >> "$LOG"
        fi
      fi
    fi

    # 로컬이 origin/data 보다 앞서 있으면 푸시 (이전 실패분도 여기서 재시도됨).
    ahead=$(git -C "$DEST" rev-list --count @{u}..HEAD 2>/dev/null || echo 0)
    if [ "${ahead:-0}" -gt 0 ]; then
      if git -C "$DEST" push -q origin data 2>>"$LOG"; then
        echo "$(ts) GIT: push OK → origin/data (${ahead} 커밋)" >> "$LOG"
      else
        echo "$(ts) FAIL: git push rc=$? — data 브랜치 (다음 동기화때 재시도)" >> "$LOG"
      fi
    fi
  fi
  # ─────────────────────────────────────────────────────────────────────
else
  reason=$(echo "$out" | grep -oE 'kAMD[A-Za-z]+|error 10[0-9][0-9]' | head -1)
  echo "$(ts) skip: ${reason:-unknown} (기기 미연결 또는 잠금)" >> "$LOG"
fi
