#!/usr/bin/env bash
# 플러그인 구조가 서로 맞는지 점검한다.
#
#   bash tests/check.sh
#
# 커맨드는 references/INDEX.md의 표를 읽어 참조 문서를 에이전트에 나눠 준다.
# 표와 실제 파일이 어긋나거나, 에이전트마다 복사해 둔 공통 규칙 블록이
# 서로 달라지면 리뷰 결과의 형식과 근거가 흔들린다. 그 어긋남을 여기서 잡는다.
set -uo pipefail
# macOS awk는 UTF-8 로캘에서 한글 문자열을 서로 같다고 비교한다. 바이트 비교로 고정한다.
export LC_ALL=C

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

# 3. 에이전트가 정확히 6개인지
actual=$(ls agents/*.md 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.md$//' | sort | tr '\n' ' ')
expected=$(printf '%s\n' $EXPECTED_AGENTS | sort | tr '\n' ' ')
[ "$actual" = "$expected" ] || err "에이전트 목록이 다름. 기대: $expected / 실제: ${actual:-없음}"

# 4. 커맨드의 두 표(1단계 인자 표의 둘째 칸, 5단계 선택 표의 첫 칸)가 에이전트를 빠짐없이,
#    실제 파일 이름 그대로 가리키는지. 커맨드는 이 이름으로 subagent_type을 만든다.
CMD=commands/review.md
cmd_names() {
  # $1: 표 머리 줄, $2: 에이전트 이름이 든 칸 번호(| 로 나눈 필드 번호)
  awk -F'|' -v head="$1" -v col="$2" '
    $0 == head { on = 1; next }
    on && /^\|/ { v = $col; gsub(/[ \t`]/, "", v); if (v ~ /^[a-z]+(-[a-z]+)+$/) print v; next }
    on && !/^\|/ { on = 0 }
  ' "$CMD"
}
for spec in "| 인자 | 에이전트 |:3" "| 에이전트 | 조건 |:2"; do
  head="${spec%:*}"; col="${spec##*:}"
  names=$(cmd_names "$head" "$col" | sort -u | tr '\n' ' ')
  [ "$names" = "$expected" ] || err "$CMD 표($head)의 에이전트가 다름. 기대: $expected / 실제: ${names:-없음}"
done

# 5, 6. frontmatter name과 공통 규칙 블록
ref_block=""
ref_file=""
mismatched=""
block_count=0
for f in agents/*.md; do
  [ -f "$f" ] || continue
  base=$(basename "$f" .md)
  name=$(awk 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit} /^name:/ {sub(/^name:[ \t]*/, ""); print; exit}' "$f")
  [ "$name" = "$base" ] || err "${f}: frontmatter name(${name})이 파일 이름과 다름"

  starts=$(grep -cxF "$START" "$f"); ends=$(grep -cxF "$END" "$f")
  if [ "$starts" != 1 ] || [ "$ends" != 1 ]; then err "${f}: 공통 규칙 블록 표시가 한 번씩 있어야 함(시작 ${starts}, 끝 ${ends})"; continue; fi
  start_line=$(grep -nxF "$START" "$f" | cut -d: -f1); end_line=$(grep -nxF "$END" "$f" | cut -d: -f1)
  [ "$start_line" -lt "$end_line" ] || { err "${f}: 공통 규칙 블록의 끝 표시가 시작 표시보다 앞에 있음"; continue; }
  # $(...)는 끝 줄바꿈을 지우므로 표시 문자를 붙여 빈 줄 차이까지 비교한다.
  block=$(awk -v s="$START" -v e="$END" '$0==s {on=1; next} $0==e {on=0} on' "$f"; printf x)
  block_count=$((block_count + 1))
  if [ -z "$ref_file" ]; then
    ref_block="$block"; ref_file="$f"
  elif [ "$block" != "$ref_block" ]; then
    mismatched="$mismatched $f"
  fi
done

# 첫 파일만 다르면 나머지가 모두 어긋나 보이므로, 그때는 첫 파일을 짚는다.
mismatch_count=$(printf '%s\n' $mismatched | grep -c .)
if [ "$mismatch_count" -gt 0 ]; then
  if [ "$block_count" -gt 2 ] && [ "$mismatch_count" -eq $((block_count - 1)) ]; then
    err "${ref_file}: 공통 규칙 블록이 다른 에이전트 파일들과 다름"
  else
    for f in $mismatched; do err "${f}: 공통 규칙 블록이 ${ref_file}의 블록과 다름"; done
  fi
fi

if [ "$fail" -eq 0 ]; then
  echo OK
  exit 0
fi
exit 1
