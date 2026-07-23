#!/bin/bash
# ~/emgfes-data 를 공개 저장소 emg-fes-project 의 orphan 브랜치 `data` 로 초기화한다.
# 최초 1회만 수동 실행. PII 스캔을 통과해야만 원격에 푸시한다.
#
# 설계: sync_iphone.sh 가 5분마다 이 폴더에 새 CSV 를 받으면 자동으로 commit+push 하는데,
# 그 대상 브랜치(data)를 여기서 미리 만들어 둔다. 코드가 있는 main 과는 root 히스토리가
# 분리된 orphan 브랜치라 서로 절대 섞이지 않는다. 코드 체크아웃(~/Developer/emg-fes-project)
# 과는 별개의 클론 — 원격만 공유한다.
set -euo pipefail

# launchd 가 아니라 사람이 실행하지만, sync 와 동일 환경을 쓰도록 PATH 를 맞춘다.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

DATA_DIR="$HOME/emgfes-data"
REMOTE="https://github.com/chaerinyeon/emg-fes-project.git"
BRANCH="data"
GH="/opt/homebrew/bin/gh"

cd "$DATA_DIR"

# ── 1) PII / 비식별화 스캔 ──────────────────────────────────────────────
# 공개 저장소로 나가므로 원본 CSV·마스터에 식별정보(이메일/전화/이름형 헤더)가
# 없는지 먼저 확인한다. 하나라도 걸리면 푸시하지 않고 중단 → 사람이 확인한다.
echo "▶ PII 스캔 중 (subject_*/ CSV + master_*.csv) ..."
# macOS 기본 /bin/bash 3.2 에는 mapfile 이 없으므로 while-read 로 순회한다.
HITS=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  hit=$(grep -InE \
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|01[0-9][-. ][0-9]{3,4}[-. ][0-9]{4}|\b(name|이름|성명|환자|patient)\b' \
    "$f" 2>/dev/null | head -3) || true
  [ -n "$hit" ] && HITS+="$(printf '%s\n' "$hit" | sed "s|^|  $f: |")"$'\n'
done < <(find . -type f \( -path './subject_*/*.csv' -o -name 'master_*.csv' \))
if [ -n "$HITS" ]; then
  echo "✗ PII 의심 항목 발견 — 푸시를 중단합니다. 아래를 확인하세요:"
  printf '%s' "$HITS"
  exit 1
fi
echo "✓ PII 스캔 통과 (이메일/전화/이름형 식별정보 없음)"

# ── 2) git 저장소 초기화 (orphan data 브랜치) ──────────────────────────
if [ -d .git ]; then
  echo "▶ 이미 git 저장소 — 재사용"
else
  git init -q -b "$BRANCH"   # 첫 브랜치를 바로 data 로 → main 과 무관한 root 히스토리
fi

# 원본 CSV(subject_*/) 와 master_*.csv 만 추적. 나머지는 재생성 가능/불필요.
cat > .gitignore <<'EOF'
# emgfes-data: 원본 raw CSV 와 master 만 추적한다.
results/
results_*/
__pycache__/
*.pyc
*.png
*.zip
*.py
.DS_Store
EOF

# 원격 (코드 저장소와 동일 remote)
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE"
else
  git remote add origin "$REMOTE"
fi

# 비대화식(launchd) push 를 위한 자격증명 헬퍼 — repo-local 로만 설정해 전역 git config 는 건드리지 않는다.
git config --local "credential.https://github.com.helper" "!$GH auth git-credential"

# 커밋 신원 — launchd 컨텍스트에서 "누구세요" 오류를 막기 위해 repo-local 로 고정.
git config --local user.name  "$(git config user.name  2>/dev/null || echo yeonchaerin)"
git config --local user.email "$(git config user.email 2>/dev/null || echo yeoncofls718@gmail.com)"

# ── 3) 최초 커밋 + 푸시 ────────────────────────────────────────────────
git add -A
if git diff --cached --quiet; then
  echo "✗ 커밋할 데이터가 없습니다 (subject_*/ CSV 나 master_*.csv 를 찾지 못함)."
  exit 1
fi
n_subj=$(ls -d subject_* 2>/dev/null | wc -l | tr -d ' ')
n_csv=$(git diff --cached --name-only | grep -c '\.csv$' || true)
git commit -qm "data: 최초 스냅샷 (${n_subj} subject, ${n_csv} CSV)"
git push -u origin "$BRANCH"
echo "✓ 완료 — origin/$BRANCH 로 ${n_csv}개 CSV 푸시됨"
echo "  확인: https://github.com/chaerinyeon/emg-fes-project/tree/$BRANCH"
