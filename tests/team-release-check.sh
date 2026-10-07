#!/usr/bin/env bash
# bin/team-release-check 회귀 테스트 — 임시 git 저장소에서 정상 릴리스와 불일치 사례를 검사한다. 사용: tests/team-release-check.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/bin/team-release-check" GATE="$ROOT/bin/team-gate"
WORK="$(mktemp -d /tmp/trc.XXXX)"
trap 'rm -rf "$WORK"' EXIT
unset VIBE_GATES

PASS=0; FAIL=0
check() {  # check <설명> <기대 exit> <실제 exit> [출력에 있어야 할 문자열] [출력에 없어야 할 문자열]
    local desc="$1" want="$2" got="$3" must="${4:-}" mustnot="${5:-}" ok=1
    [ "$want" = "$got" ] || ok=0
    [ -z "$must" ] || grep -qF -- "$must" "$WORK/out" || ok=0
    [ -z "$mustnot" ] || ! grep -qF -- "$mustnot" "$WORK/out" || ok=0
    if [ $ok -eq 1 ]; then PASS=$((PASS + 1)); echo "  ✅ $desc"
    else FAIL=$((FAIL + 1)); echo "  ❌ $desc (exit $got, 기대 $want)"; sed 's/^/       │ /' "$WORK/out" | tail -25; fi
}
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

# ── 프로젝트: 게이트 4종, 문서, 아티팩트 ──
P="$WORK/p"; mkdir -p "$P/.vibe" "$P/docs" "$P/dist"
cat > "$P/.vibe/gates.conf" <<'CONF'
unit     | 테스트설계 | true
lint     | 품질       | true
perf     | 성능       | true
security | 보안       | true
CONF
printf '.vibe/runs/\n.vibe/releases/\ndist/\n' > "$P/.gitignore"
for f in defects rollback plan; do echo "# $f" > "$P/docs/$f.md"; done
git -C "$P" init -q && git -C "$P" add . && git -C "$P" -c user.email=t@t -c user.name=t commit -qm init
SRC="$(git -C "$P" rev-parse HEAD)"
echo "artifact-v1" > "$P/dist/app.tar.gz"; ART="$(sha "$P/dist/app.tar.gz")"
(cd "$P" && "$GATE" > /dev/null 2>&1); RUN=".vibe/runs/$(cd "$P/.vibe/runs" && ls -d 2*/ | tail -1 | tr -d /)"
for part in 테스트설계 품질 성능 보안; do
    printf -- '- 확인 대상: repo @ %s\n- 실행 명령: team-gate\n- 환경: macOS, bash\n- 결과: 통과\n' "$SRC" > "$P/docs/ev-$part.md"
done
verdict() { printf '{"part":"%s","claude":"%s-클로드","codex":"%s-코덱스","source_sha":"%s","result":"통과","status":"합의","rounds":1,"codex_evidence":"docs/ev-%s.md"}' "$1" "$1" "$1" "$SRC" "$1"; }
mkdir -p "$P/.vibe/releases"; M="$P/.vibe/releases/1.0.0.json"
jq -n --arg src "$SRC" --arg run "$RUN" --arg art "$ART" \
   --argjson v1 "$(verdict 테스트설계)" --argjson v2 "$(verdict 품질)" --argjson v3 "$(verdict 성능)" --argjson v4 "$(verdict 보안)" '{
  version: "1.0.0", source_sha: $src, gate_run: $run, required_parts: [],
  artifacts: [{name: "app", path: "dist/app.tar.gz", sha256: $art, ci_run: "ci-1", staging_sha256: $art}],
  verdicts: [$v1, $v2, $v3, $v4],
  defects: {blocking: 0, critical: 0, high: 0, medium: 0, list: "docs/defects.md"},
  rollback: {verified: true, evidence: "docs/rollback.md"},
  approval: {by: "user", version: "1.0.0", source_sha: $src, artifacts_sha256: [$art], plan: "docs/plan.md", date: "2026-10-07"}
}' > "$M"
BASE="$WORK/base.json"; cp "$M" "$BASE"
# mutate <jq 식> — 기준 매니페스트를 바꿔 쓴다
mutate() { jq "$1" "$BASE" > "$M"; }
run() { (cd "$P" && "$CHECK" "$M" "$@" > "$WORK/out" 2>&1); }

echo "▶ 정상 릴리스"
run; check "모든 근거 일치 → RELEASABLE" 0 $? "판정: RELEASABLE"
run -- touch "$WORK/deployed"; check "통과 시 배포 명령 실행" 0 $?
[ -f "$WORK/deployed" ]; check "배포 명령 실제 실행됨" 0 $?

echo "▶ 차단 사례"
expect_block() { run -- touch "$WORK/should-not"; check "$1" 1 $? "${2:-판정: BLOCKED}"; }
mutate '.source_sha = "0000000000000000000000000000000000000000"'; expect_block "다른 SHA" "작업 트리 HEAD = source_sha"
mutate '.defects.medium = 1'; expect_block "MEDIUM 1건" "결함 medium = 0"
mutate 'del(.defects.high)'; expect_block "결함 수 누락" "결함 high = 0"
mutate '.artifacts[0].sha256 = "deadbeef"'; expect_block "아티팩트 digest 불일치" "파일 digest"
mutate '.artifacts[0].staging_sha256 = "deadbeef"'; expect_block "staging 과 다른 아티팩트" "staging 검증 digest"
mutate '.artifacts = []'; expect_block "아티팩트 없음" "아티팩트 1개 이상"
mutate '.verdicts |= map(select(.part != "보안"))'; expect_block "보안 판정 누락" "[보안] 판정 없음"
mutate '.verdicts[1].status = "이견"'; expect_block "이견 남은 판정" "[품질] 결과 통과·상태 합의"
mutate '.verdicts[1].source_sha = "1111111111111111111111111111111111111111"'; expect_block "오래된 판정" "[품질] 판정 커밋"
mutate '.verdicts[1].codex = "품질-클로드"'; expect_block "같은 사람·같은 엔진 서명" "[품질] 서로 다른"
mutate '.verdicts[1].rounds = 4'; expect_block "토론 4라운드" "[품질] 토론 라운드"
mutate '.required_parts = ["디자인"]'; expect_block "필수 파트 추가 시 판정 요구" "[디자인] 판정 없음"
mutate '.approval.by = "진행-클로드"'; expect_block "사용자 아닌 승인" "승인자 = 사용자"
mutate '.approval.artifacts_sha256 = ["other"]'; expect_block "승인 안 된 아티팩트" "승인한 아티팩트"
mutate '.rollback.verified = false'; expect_block "롤백 미검증" "롤백 검증 완료"
cp "$BASE" "$M"
printf -- '- 확인 대상: repo @ %s\n- 결과: 통과\n' "$SRC" > "$P/docs/ev-성능.md"; expect_block "Codex 근거에 실행 명령·환경 없음" "빠짐: 실행 명령 환경"
printf -- '- 확인 대상: repo @ abc\n- 실행 명령: x\n- 환경: y\n- 결과: z\n' > "$P/docs/ev-성능.md"; expect_block "Codex 근거가 다른 커밋" "[성능] Codex 근거가 같은 커밋"
printf -- '- 확인 대상: repo @ %s\n- 실행 명령: team-gate\n- 환경: macOS, bash\n- 결과: 통과\n' "$SRC" > "$P/docs/ev-성능.md"
echo "changed" >> "$P/docs/plan.md"; expect_block "추적 파일 미커밋 변경" "추적 파일 미커밋 변경 없음"
git -C "$P" checkout -q docs/plan.md
echo "lint2 | 품질 | true" >> "$P/.vibe/gates.conf"; expect_block "게이트 정책 변경 후 옛 결과" "게이트 정책 파일"
git -C "$P" checkout -q .vibe/gates.conf
sed -i.bak 's/^verdict=.*/verdict=PARTIAL_PASS/' "$P/$RUN/result.txt"; expect_block "부분 실행 결과" "판정 FULL_PASS"
sed -i.bak 's/^verdict=.*/verdict=FULL_PASS/; s/^scope=.*/scope=task/' "$P/$RUN/result.txt"; expect_block "작업 범위 결과로 릴리스" "범위 release"
sed -i.bak 's/^scope=.*/scope=release/' "$P/$RUN/result.txt"
[ ! -e "$WORK/should-not" ]; check "차단 시 배포 명령은 한 번도 실행되지 않음" 0 $?
run; check "원상 복구 후 다시 RELEASABLE" 0 $? "판정: RELEASABLE"

echo "▶ 사용법"
(cd "$P" && "$CHECK" > "$WORK/out" 2>&1); check "매니페스트 없음 → exit 2" 2 $?
echo '[' > "$WORK/bad.json"; (cd "$P" && "$CHECK" "$WORK/bad.json" --root "$P" > "$WORK/out" 2>&1); check "깨진 JSON → exit 2" 2 $?

echo
echo "결과: 통과 $PASS · 실패 $FAIL"
[ $FAIL -eq 0 ]
