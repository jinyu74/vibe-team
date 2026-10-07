#!/usr/bin/env bash
# team-send · team-status · lib/members.sh 회귀 테스트 — 격리된 tmux 서버와 가짜 CLI 페인으로 실행한다.
# 실제 팀 세션·기본 tmux 서버에는 영향이 없다. 사용: tests/team-tools.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$ROOT/tests/fake"
# 소켓 경로 길이 제한(macOS 104바이트) 때문에 짧은 임시 경로를 쓴다.
export TMUX_TMPDIR="$(mktemp -d /tmp/tt.XXXX)"
unset TMUX TMUX_PANE TEAM_SESSION TEAM_MEMBERS_FILE
WORK="$TMUX_TMPDIR/work"; mkdir -p "$WORK"
trap 'tmux kill-server 2>/dev/null; rm -rf "$TMUX_TMPDIR"' EXIT

PASS=0; FAIL=0
check() {  # check <설명> <기대 exit> <실제 exit> [출력에 있어야 할 문자열] [출력에 없어야 할 문자열]
    local desc="$1" want="$2" got="$3" must="${4:-}" mustnot="${5:-}" ok=1
    [ "$want" = "$got" ] || ok=0
    [ -z "$must" ] || grep -qF -- "$must" "$WORK/out" || ok=0
    [ -z "$mustnot" ] || ! grep -qF -- "$mustnot" "$WORK/out" || ok=0
    if [ $ok -eq 1 ]; then PASS=$((PASS + 1)); echo "  ✅ $desc"
    else FAIL=$((FAIL + 1)); echo "  ❌ $desc (exit $got, 기대 $want)"; sed 's/^/       │ /' "$WORK/out"; fi
}

cat > "$WORK/t.conf" <<'CONF'
@project 테스트
[기획]
가 | 가 | 가 상태줄 | claude | m | high | ga
나 | 나 | 나 막힘   | claude | m | high | na
다 | 다 | 다 정상   | claude | m | high | da
라 | 페어 | 라 페어 | claude | m | high | ra
마 | 페어 | 마 페어 | claude | m | high | ma
CONF

# new_team <세션> — 멤버 0~2 페인에 가짜 CLI 를 띄우고 setup-team.sh 처럼 태그를 붙인다
new_team() {
    local s="$1" p i=0
    tmux new-session -d -s "$s" -x 200 -y 60 "$FAKE/status-only-cli"
    tmux split-window -t "$s" "$FAKE/stuck-cli"
    tmux split-window -t "$s" "$FAKE/ok-cli"
    tmux set-option -t "$s" @team_members_file "$WORK/t.conf"
    for p in $(tmux list-panes -t "$s" -F '#{pane_id}'); do
        tmux set-option -p -t "$p" @member "$i"; i=$((i + 1))
    done
}
new_team own
sleep 1

echo "── team-send 전달 판정"
"$ROOT/bin/team-send" --session own 다 '정상 전달 테스트' >"$WORK/out" 2>&1
check "정상 제출 → ✅ exit 0" 0 $? "✅"
"$ROOT/bin/team-send" --session own 나 '한글 메시지 막힘 테스트' >"$WORK/out" 2>&1
check "입력창 잔존 → exit 5, ✅ 없음" 5 $? "delivery 미확인" "✅"
"$ROOT/bin/team-send" --session own 가 'no prompt' >"$WORK/out" 2>&1
check "입력창 판독 불가 → exit 5" 5 $? "입력창(❯/›)을 화면에서 찾지 못함" "✅"

echo "── team-send 세션 선택"
new_team other
"$ROOT/bin/team-send" 다 hi >"$WORK/out" 2>&1
check "tmux 밖·세션 여럿·--session 없음 → exit 1" 1 $? "--session"
TEAM_SESSION=other "$ROOT/bin/team-send" 다 'via env' >"$WORK/out" 2>&1
check "TEAM_SESSION 이 가리키는 세션으로 전송" 0 $?
tmux capture-pane -t "$(tmux list-panes -t other -F '#{@member} #{pane_id}' | awk '$1==2{print $2}')" -p | grep -q 'via env'
check "  └ other 세션 수신자 화면에 도착" 0 $?
"$ROOT/bin/team-send" --session nope 다 hi >"$WORK/out" 2>&1
check "없는 세션 → exit 3" 3 $?

echo "── 수신자 이름 해석"
"$ROOT/bin/team-send" --session own 페어 hi >"$WORK/out" 2>&1
check "페어가 공유하는 역할 파일 이름 → 모호하므로 거절(exit 1)" 1 $? "알 수 없는 수신자"
sed 's/| ma$/| ma da/' "$WORK/t.conf" > "$WORK/dup.conf"
bash -c ". '$ROOT/lib/members.sh'; load_members '$WORK/dup.conf'" >"$WORK/out" 2>&1
check "별칭 중복 → 설정 로드 실패" 1 $? "중복"
sed 's/| ma$/| ma 가/' "$WORK/t.conf" > "$WORK/dup2.conf"
bash -c ". '$ROOT/lib/members.sh'; load_members '$WORK/dup2.conf'" >"$WORK/out" 2>&1
check "별칭이 다른 멤버 이름과 겹침 → 설정 로드 실패" 1 $? "겹칩니다"

echo "── 팀 설정 지시어"
dir_conf() { { cat "$WORK/t.conf"; printf '%s\n' "$@"; } > "$WORK/dir.conf"; bash -c ". '$ROOT/lib/members.sh'; load_members '$WORK/dir.conf'" >"$WORK/out" 2>&1; }
dir_conf '@worktree 다' '@duty 다 첫째' '@duty 다 둘째' '@substitute 보안-코덱스 가 품질'
check "@worktree·@duty·@substitute 정상 로드" 0 $?
bash -c ". '$ROOT/lib/members.sh'; load_members '$WORK/dir.conf' && [ \"\${M_WORKTREE[2]}\" = 1 ] && [ \"\$(printf '%s' \"\${M_DUTY[2]}\" | wc -l | tr -d ' ')\" = 1 ]" >"$WORK/out" 2>&1
check "  └ worktree 표시·@duty 두 줄 누적" 0 $?
dir_conf '@duty 없는사람 책임'
check "@duty 에 팀에 없는 이름 → 로드 실패" 1 $? "팀 멤버가 아닙니다"
dir_conf '@substitute 가 다'
check "@substitute 부재 이름이 실제 멤버 → 로드 실패" 1 $? "이 팀 멤버입니다"
dir_conf '@worktree 없는사람'
check "@worktree 에 팀에 없는 이름 → 로드 실패" 1 $? "팀 멤버가 아닙니다"

echo "── team-status"
tmux kill-session -t own; tmux kill-session -t other
new_team own; sleep 1
"$ROOT/bin/team-status" --session own >"$WORK/out" 2>&1
check "상태 표시줄만 있는 페인이 있어도 끝까지 출력" 0 $? "컨텍스트 임계 안내"

for f in "$ROOT"/teams/*.conf; do
    bash -c ". '$ROOT/lib/members.sh'; load_members '$f'" >"$WORK/out" 2>&1
    check "팀 설정 로드: $(basename "$f")" 0 $?
done

echo
echo "결과: 통과 $PASS · 실패 $FAIL"
[ "$FAIL" -eq 0 ]
