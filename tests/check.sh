#!/usr/bin/env bash
# 플러그인 구조가 서로 맞는지 점검한다.
#
#   bash tests/check.sh
#
# 커맨드는 references/INDEX.md의 표를 읽어 참조 문서를 에이전트에 나눠 준다.
# 표와 실제 파일이 어긋나거나, 에이전트마다 복사해 둔 공통 규칙 블록이
# 서로 달라지면 리뷰 결과의 형식과 근거가 흔들린다. 그 어긋남을 여기서 잡는다.
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail=0
err() { echo "FAIL: $*"; fail=1; }

EXPECTED_AGENTS="transaction-concurrency query-performance migration-safety api-compatibility responsibility-boundary change-resilience"
INDEX=references/INDEX.md
START='<!-- 공통 규칙 시작 -->'
END='<!-- 공통 규칙 끝 -->'

# 표 1("## 참조 문서" 절)의 행에서 첫 칸(문서)과 셋째 칸(에이전트)을 뽑는다.
index_rows() {
  awk -F'|' '
    /^## / { in_table = ($0 == "## 참조 문서") ; next }
    in_table && /^\|/ {
      doc = $2; agents = $4
      gsub(/^[ \t`]+|[ \t`]+$/, "", doc)
      gsub(/^[ \t]+|[ \t]+$/, "", agents)
      if (doc ~ /\.md$/) print doc "\t" agents
    }
  ' "$INDEX"
}

# 1. INDEX.md 표 1과 references/ 파일이 서로 맞는지
if [ ! -f "$INDEX" ]; then
  err "$INDEX 없음"
else
  listed=$(index_rows | cut -f1 | sort)
  [ -z "$listed" ] && err "$INDEX 표 1에 문서 행이 없음"
  for doc in $listed; do
    [ -f "references/$doc" ] || err "INDEX.md에 있지만 파일이 없음: references/$doc"
  done
  for f in references/*.md; do
    name=$(basename "$f")
    [ "$name" = "INDEX.md" ] && continue
    printf '%s\n' "$listed" | grep -qxF "$name" || err "INDEX.md 표 1에 없는 문서: $f"
  done

  # 2. 표 1의 에이전트 이름마다 파일이 있는지
  index_rows | cut -f2 | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u | while IFS= read -r a; do
    [ -z "$a" ] && continue
    [ -f "agents/$a.md" ] || echo "FAIL: INDEX.md가 가리키는 에이전트 파일이 없음: agents/$a.md"
  done | grep . && fail=1
fi

# 5. 에이전트가 정확히 6개인지
actual=$(ls agents/*.md 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.md$//' | sort | tr '\n' ' ')
expected=$(printf '%s\n' $EXPECTED_AGENTS | sort | tr '\n' ' ')
[ "$actual" = "$expected" ] || err "에이전트 목록이 다름. 기대: $expected / 실제: ${actual:-없음}"

# 3, 4. frontmatter name과 공통 규칙 블록
ref_block=""
ref_file=""
for f in agents/*.md; do
  [ -f "$f" ] || continue
  base=$(basename "$f" .md)
  name=$(awk 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit} /^name:/ {sub(/^name:[ \t]*/, ""); print; exit}' "$f")
  [ "$name" = "$base" ] || err "$f: frontmatter name($name)이 파일 이름과 다름"

  grep -qxF "$START" "$f" && grep -qxF "$END" "$f" || { err "$f: 공통 규칙 블록 표시가 없음"; continue; }
  block=$(awk -v s="$START" -v e="$END" '$0==s {on=1; next} $0==e {on=0} on' "$f")
  if [ -z "$ref_file" ]; then
    ref_block="$block"; ref_file="$f"
  elif [ "$block" != "$ref_block" ]; then
    err "$f: 공통 규칙 블록이 $ref_file과 다름"
  fi
done

if [ "$fail" -eq 0 ]; then
  echo OK
  exit 0
fi
exit 1
