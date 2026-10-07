#!/usr/bin/env bash
# bin/team-gate 회귀 테스트 — 임시 프로젝트 폴더에서 게이트 설정·실행·루프 기록을 검사한다. 사용: tests/team-gate.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/bin/team-gate"
WORK="$(mktemp -d /tmp/tg.XXXX)"
trap 'rm -rf "$WORK"' EXIT
unset VIBE_GATES

PASS=0; FAIL=0
check() {  # check <설명> <기대 exit> <실제 exit> [출력에 있어야 할 문자열] [출력에 없어야 할 문자열]
    local desc="$1" want="$2" got="$3" must="${4:-}" mustnot="${5:-}" ok=1
    [ "$want" = "$got" ] || ok=0
    [ -z "$must" ] || grep -qF -- "$must" "$WORK/out" || ok=0
    [ -z "$mustnot" ] || ! grep -qF -- "$mustnot" "$WORK/out" || ok=0
    if [ $ok -eq 1 ]; then PASS=$((PASS + 1)); echo "  ✅ $desc"
    else FAIL=$((FAIL + 1)); echo "  ❌ $desc (exit $got, 기대 $want)"; sed 's/^/       │ /' "$WORK/out"; fi
}

P="$WORK/proj"; mkdir -p "$P/.vibe"
cat > "$P/.vibe/gates.conf" <<'CONF'
# 이름 | 담당 파트 | 명령
unit  | 테스트설계 | test -f ok.txt
lint  | 품질       | echo lint-ok
perf  | 성능       | [ "$(cat perf.txt 2>/dev/null)" = fast ]
CONF

echo "▶ 설정·사용법"
(cd "$WORK" && "$GATE" > "$WORK/out" 2>&1); check "설정 없음 → exit 2" 2 $? "게이트 설정 없음"
(cd "$P" && "$GATE" --list > "$WORK/out" 2>&1); check "--list 는 실행 없이 목록" 0 $? "perf" "판정"
(cd "$P" && "$GATE" --only nope > "$WORK/out" 2>&1); check "--only 알 수 없는 게이트 → exit 2" 2 $? "알 수 없는 게이트"
printf 'bad line\n' > "$WORK/bad.conf"
("$GATE" --config "$WORK/bad.conf" > "$WORK/out" 2>&1); check "형식 오류 → exit 2" 2 $? "형식 오류"
printf 'a | x | true\na | y | true\n' > "$WORK/dup.conf"
("$GATE" --config "$WORK/dup.conf" > "$WORK/out" 2>&1); check "중복 이름 → exit 2" 2 $? "중복 이름"

echo "▶ 실행·판정"
(cd "$P" && "$GATE" --label T-1 > "$WORK/out" 2>&1); check "실패 게이트가 있으면 exit 1" 1 $? "판정: FAIL"
grep -qF "unit" "$P/.vibe/runs/latest.md" && grep -qF "**FAIL**" "$P/.vibe/runs/latest.md"; check "latest.md 요약 기록" 0 $?
touch "$P/ok.txt"
(cd "$P" && "$GATE" --only unit,lint > "$WORK/out" 2>&1); check "--only 로 일부만 실행·통과" 0 $? "판정: PASS" "perf"
(cd "$P/.vibe" && "$GATE" --only unit > "$WORK/out" 2>&1); check "하위 폴더에서도 명령은 프로젝트 루트에서 실행" 0 $? "판정: PASS"

echo "▶ 루프 기록 (§6.4)"
(cd "$P" && "$GATE" --label T-1 > "$WORK/out" 2>&1); check "2회차 기록" 1 $? "T-1 2회차"
(cd "$P" && "$GATE" --label T-1 > "$WORK/out" 2>&1); check "같은 게이트 연속 3회 실패 경고" 1 $? "'perf' 연속 실패 3회"
(cd "$P" && "$GATE" --label T-1 > "$WORK/out" 2>&1)
(cd "$P" && "$GATE" --label T-1 > "$WORK/out" 2>&1); check "5회차 미통과 에스컬레이션" 1 $? "5회차까지 미통과"
echo fast > "$P/perf.txt"
(cd "$P" && "$GATE" --label T-1 > "$WORK/out" 2>&1); check "전부 통과 → exit 0, 경고 없음" 0 $? "판정: PASS" "연속 실패"
[ "$(wc -l < "$P/.vibe/runs/history/T-1.tsv" | tr -d ' ')" = 6 ]; check "이력 6회차" 0 $?

echo
echo "결과: 통과 $PASS · 실패 $FAIL"
[ $FAIL -eq 0 ]
