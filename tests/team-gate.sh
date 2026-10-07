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
security | 보안    | true
CONF

echo "▶ 설정·사용법"
(cd "$WORK" && "$GATE" > "$WORK/out" 2>&1); check "설정 없음 → exit 2" 2 $? "게이트 설정 없음"
(cd "$P" && "$GATE" --list > "$WORK/out" 2>&1); check "--list 는 실행 없이 목록" 0 $? "perf" "판정"
(cd "$P" && "$GATE" --only nope > "$WORK/out" 2>&1); check "--only 알 수 없는 게이트 → exit 2" 2 $? "알 수 없는 게이트"
for option in --config --only --label; do
    (cd "$P" && "$GATE" "$option" > "$WORK/out" 2>&1); check "$option 값 누락 → exit 2" 2 $? "옵션 값이 필요"
done
for names in ',' 'unit,' ',unit' 'unit,,lint' ' ' 'unit,unit'; do
    (cd "$P" && "$GATE" --only "$names" > "$WORK/out" 2>&1); check "빈/중복 선택 거부: '$names'" 2 $?
done
printf 'bad line\n' > "$WORK/bad.conf"
("$GATE" --config "$WORK/bad.conf" > "$WORK/out" 2>&1); check "형식 오류 → exit 2" 2 $? "형식 오류"
printf 'a | x | true\na | y | true\n' > "$WORK/dup.conf"
("$GATE" --config "$WORK/dup.conf" > "$WORK/out" 2>&1); check "중복 이름 → exit 2" 2 $? "중복 이름"

echo "▶ 실행·판정"
(cd "$P" && "$GATE" --label T-1 > "$WORK/out" 2>&1); check "실패 게이트가 있으면 exit 1" 1 $? "판정: FAIL"
grep -qF "unit" "$P/.vibe/runs/latest.md" && grep -qF "**FAIL**" "$P/.vibe/runs/latest.md"; check "latest.md 요약 기록" 0 $?
touch "$P/ok.txt"
(cd "$P" && "$GATE" --only 'unit, lint' > "$WORK/out" 2>&1); check "일부 통과는 PARTIAL_PASS" 0 $? "판정: PARTIAL_PASS" "판정: FULL_PASS"
grep -qF '**FAIL**' "$P/.vibe/runs/latest-full.md" && grep -qF '**PARTIAL_PASS**' "$P/.vibe/runs/latest.md"; check "부분 실행은 마지막 전체 결과를 덮어쓰지 않음" 0 $?
grep -qF '미실행 게이트: perf,security' "$P/.vibe/runs/latest.md"; check "미실행 게이트 명시" 0 $?
(cd "$P/.vibe" && "$GATE" --only unit > "$WORK/out" 2>&1); check "하위 폴더에서도 명령은 프로젝트 루트에서 실행" 0 $? "판정: PARTIAL_PASS"
(cd "$P" && "$GATE" --only perf > "$WORK/out" 2>&1); check "일부 실패는 PARTIAL_FAIL" 1 $? "판정: PARTIAL_FAIL"

echo "▶ 루프 기록 (§6.4)"
(cd "$P" && "$GATE" --label T-1 > "$WORK/out" 2>&1); check "2회차 기록" 1 $? "T-1 2회차"
(cd "$P" && "$GATE" --label T-1 --only unit > "$WORK/out" 2>&1); check "부분 실행을 전체 회차로 세지 않음" 0 $? "전체 검증 2회 완료"
(cd "$P" && "$GATE" --label T-1 > "$WORK/out" 2>&1); check "같은 게이트 연속 3회 실패 경고" 1 $? "'perf' 연속 실패 3회"
(cd "$P" && "$GATE" --label T-1 > "$WORK/out" 2>&1)
(cd "$P" && "$GATE" --label T-1 > "$WORK/out" 2>&1); check "5회차 미통과 에스컬레이션" 1 $? "5회차까지 미통과"
echo fast > "$P/perf.txt"
(cd "$P" && "$GATE" --label T-1 > "$WORK/out" 2>&1); check "전부 통과 → FULL_PASS, 경고 없음" 0 $? "판정: FULL_PASS" "연속 실패"
[ "$(wc -l < "$P/.vibe/runs/history/T-1.tsv" | tr -d ' ')" = 7 ]; check "이력 전체 6회 + 부분 1회" 0 $?
(cd "$P" && "$GATE" --only security,perf,lint,unit > "$WORK/out" 2>&1); check "모든 게이트 선택은 FULL_PASS" 0 $? "판정: FULL_PASS"

echo "▶ 필수 검사·파이프라인 실패 전파"
for part in 테스트설계 품질 성능 보안; do
    awk -F'|' -v p="$part" '{ x=$2; gsub(/[[:space:]]/, "", x); if(x != p) print }' "$P/.vibe/gates.conf" > "$WORK/missing.conf"
    ("$GATE" --config "$WORK/missing.conf" > "$WORK/out" 2>&1); check "필수 파트 '$part' 누락 거부" 2 $? "필수 게이트 담당 파트 누락: $part"
done
sed 's/security | 보안    | true/security | 보안    | false | cat/' "$P/.vibe/gates.conf" > "$P/.vibe/pipe.conf"
(cd "$P" && "$GATE" --config "$P/.vibe/pipe.conf" > "$WORK/out" 2>&1); check "파이프라인 앞 명령 실패를 FAIL로 전파" 1 $? "security" "판정: FULL_PASS"
sed 's/security | 보안    | true/security | 보안    | printf ok | cat/' "$P/.vibe/gates.conf" > "$P/.vibe/pipe.conf"
(cd "$P" && "$GATE" --config "$P/.vibe/pipe.conf" > "$WORK/out" 2>&1); check "성공한 파이프라인은 FULL_PASS" 0 $? "판정: FULL_PASS"

echo "▶ 작업 범위 / 릴리스 범위 (§6.3)"
S="$WORK/scope"; mkdir -p "$S/.vibe"
cat > "$S/.vibe/gates.conf" <<'CONF'
unit        | 테스트설계                | true
accept-task | 테스트설계 scope=task     | [ "$VIBE_SCOPE" = task ] && [ "$VIBE_LABEL" = T-9 ]
accept-all  | 테스트설계 scope=release  | [ "$VIBE_SCOPE" = release ]
lint        | 품질                      | true
perf        | 성능                      | true
security    | 보안                      | true
CONF
(cd "$S" && "$GATE" --scope task --label T-9 > "$WORK/out" 2>&1); check "작업 범위: scope=all·task 만 실행, FULL_PASS" 0 $? "판정: FULL_PASS (범위 task" "accept-all"
grep -qx 'scope=task' "$S/.vibe/runs/latest-full-task.md" 2>/dev/null || grep -qF '범위: task' "$S/.vibe/runs/latest-full-task.md"; check "작업 범위 결과는 latest-full-task.md 에 기록" 0 $?
[ ! -e "$S/.vibe/runs/latest-full.md" ]; check "작업 범위 결과는 릴리스용 latest-full.md 를 만들지 않음" 0 $?
r="$(ls -d "$S"/.vibe/runs/2*/ | tail -1)"; grep -qx 'out_of_scope=accept-all' "$r/result.txt"; check "result.txt 에 범위 밖 게이트 기록" 0 $?
(cd "$S" && "$GATE" > "$WORK/out" 2>&1); check "릴리스 범위(기본): accept-task 제외·accept-all 실행" 0 $? "accept-all" "accept-task"
(cd "$S" && "$GATE" --scope task --only accept-all > "$WORK/out" 2>&1); check "범위 밖 게이트를 --only 로 고르면 거부" 2 $? "범위 'task' 밖"
(cd "$S" && "$GATE" --scope nope > "$WORK/out" 2>&1); check "잘못된 --scope 거부" 2 $?
sed 's/^security    | 보안  /security    | 보안 scope=release/' "$S/.vibe/gates.conf" > "$S/.vibe/sec-rel.conf"
("$GATE" --config "$S/.vibe/sec-rel.conf" --scope task > "$WORK/out" 2>&1); check "작업 범위에 보안 게이트가 없으면 거부" 2 $? "범위 'task' 의 필수 게이트 담당 파트 누락: 보안"
printf 'a | 테스트설계 timeout=abc | true\n' > "$WORK/attr.conf"; ("$GATE" --config "$WORK/attr.conf" > "$WORK/out" 2>&1); check "잘못된 timeout 거부" 2 $? "timeout 은 양의 정수"
printf 'a | 테스트설계 color=red | true\n' > "$WORK/attr.conf"; ("$GATE" --config "$WORK/attr.conf" > "$WORK/out" 2>&1); check "알 수 없는 속성 거부" 2 $? "알 수 없는 속성"

echo "▶ 제한시간·중단 (TIMEOUT / INCOMPLETE)"
T="$WORK/to"; mkdir -p "$T/.vibe"
cat > "$T/.vibe/gates.conf" <<'CONF'
unit     | 테스트설계 timeout=1 | sleep 41 & sleep 41
lint     | 품질                 | true
perf     | 성능                 | true
security | 보안                 | true
CONF
t0=$(date +%s); (cd "$T" && "$GATE" --label T-T > "$WORK/out" 2>&1); rc=$?; dt=$(( $(date +%s) - t0 ))
check "멈춘 게이트는 TIMEOUT 실패" 1 $rc "TIMEOUT 1s"
[ $dt -lt 10 ]; check "제한시간 뒤 바로 다음 게이트로 진행 (${dt}s)" 0 $?
r="$(ls -d "$T"/.vibe/runs/2*/ | tail -1)"; grep -qx 'timeouts=unit' "$r/result.txt" && grep -qx 'verdict=FAIL' "$r/result.txt"; check "result.txt 에 timeouts·FAIL 기록" 0 $?
! pgrep -f 'sleep 41' >/dev/null; check "시간 초과 게이트의 하위 프로세스까지 종료" 0 $?
cp "$T/.vibe/runs/latest-full.md" "$WORK/before-full.md"
cat > "$T/.vibe/gates.conf" <<'CONF'
unit     | 테스트설계 | sleep 42
lint     | 품질       | true
perf     | 성능       | true
security | 보안       | true
CONF
(cd "$T" && exec "$GATE" --label T-T > "$WORK/out" 2>&1) & gp=$!
sleep 1.5; kill -TERM $gp; wait $gp; rc=$?
check "실행 중 TERM → exit 130" 130 $rc "판정: INCOMPLETE"
r="$(ls -d "$T"/.vibe/runs/2*/ | tail -1)"
grep -qx 'verdict=INCOMPLETE' "$r/result.txt" && grep -qx 'not_run=unit,lint,perf,security' "$r/result.txt"; check "INCOMPLETE·중단으로 미실행 게이트 기록" 0 $?
cmp -s "$WORK/before-full.md" "$T/.vibe/runs/latest-full.md"; check "중단 실행은 latest-full.md 를 덮어쓰지 않음" 0 $?
! pgrep -f 'sleep 42' >/dev/null; check "중단 시 실행 중 게이트 프로세스 종료" 0 $?
grep -qF '중단: T-T (회차로 세지 않음' "$WORK/out"; check "중단은 루프 회차로 세지 않음" 0 $?
(cd "$T" && exec "$GATE" > "$WORK/out" 2>&1) & gp=$!
sleep 1.5; kill -KILL $gp; wait $gp 2>/dev/null; pkill -f 'sleep 42' 2>/dev/null
r="$(ls -d "$T"/.vibe/runs/2*/ | tail -1)"; grep -qx 'verdict=RUNNING' "$r/result.txt"; check "강제 종료된 실행은 RUNNING 으로 남아 통과 근거가 되지 않음" 0 $?

echo "▶ 커밋 기록"
G2="$WORK/git"; mkdir -p "$G2/.vibe" && cp "$P/.vibe/gates.conf" "$G2/.vibe/" && touch "$G2/ok.txt" && echo fast > "$G2/perf.txt"
git -C "$G2" init -q && git -C "$G2" add . && git -C "$G2" -c user.email=t@t -c user.name=t commit -qm init
for i in $(seq 1 20000); do : > "$G2/u$i"; done
(cd "$G2" && "$GATE" > "$WORK/out" 2>&1); grep -qF '미커밋 변경 있음' "$G2/.vibe/runs/latest.md"; check "미커밋 파일이 많아도 미커밋 변경 표시 (pipefail SIGPIPE)" 0 $?

echo
echo "결과: 통과 $PASS · 실패 $FAIL"
[ $FAIL -eq 0 ]
