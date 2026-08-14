#!/usr/bin/env bash
# 노트북 ↔ 아이폰 관찰 화면을 **USB 로** 잇는다.
#
# 왜 USB 인가: 앱의 관찰 서버는 InternetAddress.anyIPv4 에 붙어 있어 Wi-Fi
# 뿐 아니라 USB 터널로도 같은 포트가 열린다. Wi-Fi 주소는 망을 옮길 때마다
# 바뀌고 병원 망은 기기 간 통신을 막는 경우가 많은데, USB 는 주소가
# localhost 로 고정된다.
#
# 접속 코드(k)는 앱이 저장해 두므로 재설치 전까지 안 바뀐다.
# 설정 탭 → 노트북에서 보기 → 「USB 로 보기 (고정)」 에서 확인한다.
set -euo pipefail

PORT="${1:-8080}"

command -v iproxy >/dev/null 2>&1 || {
  echo "iproxy 가 없습니다.  brew install libimobiledevice" >&2
  exit 1
}

UDID="$(idevice_id -l 2>/dev/null | head -1 || true)"
[ -n "$UDID" ] || {
  echo "연결된 아이폰이 없습니다. 케이블과 잠금 해제를 확인하세요." >&2
  exit 1
}

NAME="$(ideviceinfo -u "$UDID" -k DeviceName 2>/dev/null || echo iPhone)"
echo "기기: $NAME"

# 이미 떠 있으면 그걸 쓴다 — 두 개가 같은 포트를 잡으면 뒤엣것이 조용히 죽는다.
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "포트 $PORT 은 이미 열려 있습니다 (터널이 이미 떠 있는 듯)."
else
  iproxy "$PORT" "$PORT" >/dev/null 2>&1 &
  sleep 1
fi

# curl 은 실패해도 -w 로 000 을 찍는다. 여기에 `|| echo 000` 을 덧붙이면
# "000000" 이 되어 어떤 분기에도 안 걸린다 — 진단 스크립트가 스스로
# 오진하는 셈이라, 실패는 그냥 000 하나로 두고 읽는다.
#
# 터널이 막 뜬 직후에는 첫 요청이 샐 수 있어 몇 번 다시 묻는다.
# `|| true` 가 없으면 set -e 가 curl 의 종료코드(연결 실패 56)에 걸려
# **아무 메시지도 없이** 스크립트가 끝난다. 진단 도구가 진단을 못 내놓고
# 죽는 것이라, 없느니만 못하다.
CODE=000
for _ in 1 2 3 4 5; do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
    "http://localhost:$PORT/" 2>/dev/null || true)"
  [ -n "$CODE" ] || CODE=000
  [ "$CODE" != "000" ] && break
  sleep 1
done

case "$CODE" in
  403) echo "연결됨 — 서버가 응답합니다 (접속 코드가 필요한 정상 응답)." ;;
  200) echo "연결됨." ;;
  000)
    echo "응답 없음. 순서대로 확인하세요:" >&2
    echo "  1) 아이폰에서 RE-FIT 앱이 **켜져 있는지** (백그라운드면 서버도 잠든다)" >&2
    echo "  2) 설정 탭 → 노트북에서 보기 → '관찰 화면 열기' 가 켜져 있는지" >&2
    echo "  3) 아이폰 화면 잠금이 풀려 있는지" >&2
    exit 1
    ;;
  *) echo "예상 밖 응답: HTTP $CODE" >&2 ;;
esac

echo
echo "  실시간:  http://localhost:$PORT/?k=<설정 탭의 4자리>"
echo "  기록:    http://localhost:$PORT/records?k=<같은 코드>"
