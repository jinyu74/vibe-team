#!/usr/bin/env bash
# 페어 불변식·겸임·프로젝트 책임·역할 주입 드라이런 검증. tmux·실제 CLI·전역 설정을 사용하지 않는다.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/vibe-setup.XXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo/lib" "$WORK/repo/roles" "$WORK/repo/teams" "$WORK/project"
cp "$ROOT/setup-team.sh" "$WORK/repo/"
cp "$ROOT/lib/members.sh" "$WORK/repo/lib/"
cp "$ROOT/roles/"*.md "$WORK/repo/roles/"
cp "$ROOT/teams/"*.conf "$WORK/repo/teams/"
. "$ROOT/lib/members.sh"
PASS=0; FAIL=0
check() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then PASS=$((PASS + 1)); echo "  ✅ $desc"
    else FAIL=$((FAIL + 1)); echo "  ❌ $desc (exit $got, 기대 $want)"; cat "$WORK/out"; fi
}
load() { load_members "$WORK/team.conf" > "$WORK/out" 2>&1; }
printf 'A | 기획 | A | claude | m | high | a\n' > "$WORK/team.conf"
load; check "단독 멤버는 거부" 1 $?
bash "$WORK/repo/setup-team.sh" invalid -n -c "$WORK/team.conf" -d "$WORK/project" > "$WORK/out" 2>&1
check "단독 팀은 주입 생성·기동 전에 중단" 1 $?
[ ! -e "$WORK/repo/roles/.merged/invalid" ]; check "거부된 팀의 주입 파일을 만들지 않음" 0 $?
printf 'B | 기획 | B | claude | m | high | b\n' >> "$WORK/team.conf"
load; check "같은 엔진 두 명은 거부" 1 $?
printf 'A | 기획+통계 | A | claude | m | high | a\nB | 기획 | B | codex | m | high | b\n' > "$WORK/team.conf"
load; check "겸임 파트의 상대 누락은 거부" 1 $?
printf 'C | 통계 | C | codex | m | high | c\n@duty A 공통 책임\n' >> "$WORK/team.conf"
load; check "문자열이 달라도 각 파트의 양쪽 엔진 인정" 0 $?
[ "$(member_partner_indices 0 | tr '\n' ' ')" = '1 2 ' ] && [ "${M_DUTY[0]}" = '공통 책임' ] && [ "${M_DUTY[1]}" = '공통 책임' ] && [ "${M_DUTY[2]}" = '공통 책임' ]; check "파트별 상대와 양쪽 공통 책임" 0 $?
printf '@duty B 공통 책임\n' >> "$WORK/team.conf"
load; [ "${M_DUTY[0]}" = '공통 책임' ]; check "양쪽에 같은 책임을 지정해도 중복 없음" 0 $?
printf '@substitute 보안-코덱스 A 연락\n' >> "$WORK/team.conf"
load; check "연락 대체의 엔진 불일치는 거부" 1 $?
printf 'A | 기획++통계 | A | claude | m | high | a\n' > "$WORK/team.conf"
load; check "빈 역할 목록 요소는 거부" 1 $?
printf 'A | 기획+기획 | A | claude | m | high | a\n' > "$WORK/team.conf"
load; check "중복 역할은 거부" 1 $?

for profile in backend-api discovery full game mobile-app tool-lib web-service; do
    bash "$WORK/repo/setup-team.sh" "test-$profile" -n -c "$WORK/repo/teams/$profile.conf" -d "$WORK/project" > "$WORK/out" 2> "$WORK/err"
    check "$profile 드라이런" 0 $?
    [ ! -s "$WORK/err" ]; check "$profile stderr 오류 없음" 0 $?
    load_members "$WORK/repo/teams/$profile.conf" > "$WORK/out" 2>&1
    i=0; ok=0
    while [ $i -lt $M_COUNT ]; do
        f="$WORK/repo/roles/.merged/test-$profile/${M_NAME[$i]}.md"
        grep -qF '예: `CI-클로드`' "$f" || ok=1
        grep -qF '담당 파트의 반대 엔진 페어:' "$f" || ok=1
        grep -qF '담당 파트의 반대 엔진 페어: 없음' "$f" && ok=1
        for part in $(printf '%s' "${M_ROLE[$i]}" | tr '+' ' '); do
            grep -qF "# 파트: $part " "$f" || grep -qF "# 파트: $part (" "$f" || ok=1
        done
        i=$((i + 1))
    done
    check "$profile 상대·예시·모든 겸임 역할 주입" 0 "$ok"
done

for profile in web-service mobile-app backend-api; do
    load_members "$ROOT/teams/$profile.conf" > "$WORK/out" 2>&1
    ok=0
    for part in 운영신뢰성 데이터관리; do
        for engine in 클로드 코덱스; do
            idx="$(member_index "$part-$engine")"
            [ -n "$idx" ] && member_has_part "$idx" "$part" || ok=1
        done
    done
    check "$profile 새 파트 양쪽 역할·별칭" 0 "$ok"
done
mv "$WORK/repo/roles/_team-workflow.md" "$WORK/repo/roles/unavailable.md"
bash "$WORK/repo/setup-team.sh" missing-workflow -n -c "$WORK/repo/teams/discovery.conf" -d "$WORK/project" > "$WORK/out" 2>&1
check "공통 지시를 읽지 못하면 생성 성공으로 보고하지 않음" 1 $?
grep -qF '역할 주입 생성 실패' "$WORK/out"; check "주입 실패 원인을 상위 실행으로 전달" 0 $?
echo "결과: 통과 $PASS · 실패 $FAIL"
[ $FAIL -eq 0 ]
