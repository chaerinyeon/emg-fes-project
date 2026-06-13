#!/bin/bash
# iPhone 앱 샌드박스의 CSV 로그(Documents/data/)를 프로젝트 폴더로 복사한다.
# 사용법: ./scripts/pull_csv.sh   (iPhone USB 연결 + 잠금 해제 상태에서)
# 결과: <프로젝트 루트>/data_from_iphone/<환자ID>/*.csv
set -e

DEVICE_ID="00008101-0002042034DB001E"   # iPhone (2)
BUNDLE_ID="com.emgfes.flutterApp"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$PROJECT_ROOT/data_from_iphone"

mkdir -p "$DEST"

xcrun devicectl device copy from \
  --device "$DEVICE_ID" \
  --source "Documents/data" \
  --destination "$DEST" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID"

echo ""
echo "✅ 복사 완료 → $DEST/"
find "$DEST" -name "*.csv" | sort | tail -5
