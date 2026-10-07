#!/usr/bin/env bash
# team-send PostToolUse Hook — 송신 후 수신자 페인 활성 검증 + Enter 보강
#
# 동작:
#   1. stdin 으로 PostToolUse JSON 페이로드 수신 (Claude Code hook 규약)
#   2. tool_name == "Bash" 이고 command 가 team-send 호출인 경우만 진입
#   3. team-send stdout 의 `pane N` 파싱 → 수신자 페인 식별
#   4. sleep 2.5 후 capture-pane → 단일 패턴 매칭 (PATTERN_ACTIVE)
#   5. 미활성 → tmux send-keys Enter 보강 → 1초 후 재확인
#   6. 여전히 미활성 → stderr 안내 + exit 2 (Esc 자동 발사 금지 — S6 β)
#
# Exit codes:
#   0 — 정상 (active 확인 또는 본 hook 비대상)
#   2 — 보강 실패 (수신자 페인 잔존 가능 — 발신자 Claude 진단 진입)
#
# 의존: jq (미설치 시 graceful exit 0 + stderr 안내), tmux, awk, grep
# 로그: /tmp/team-send-verify.log
# Refs: docs/decisions/2026-06-09-team-send-verify-hook.md (ADR)

set -uo pipefail

LOG=/tmp/team-send-verify.log
SLEEP_INITIAL=2.5        # claude-ecg-team 측정 (1M ctx TTFT p95 ≈ 2.5s) — 회귀 빈도 < 5% 충족
SLEEP_RECHECK=1          # Enter 보강 후 재확인 대기

# ── 1. jq 가용성 — 미설치 시 graceful degradation (S8) ────────────────────
if ! command -v jq >/dev/null 2>&1; then
    echo "[team-send-verify] jq 미설치 — 검증 skip. brew install jq 또는 apt install jq 권장." >&2
    exit 0
fi

# ── 2. stdin JSON 파싱 — tool_name 이 Bash 가 아니면 즉시 exit 0 ──────────
PAYLOAD=$(cat)
TOOL_NAME=$(jq -r '.tool_name // ""' <<<"$PAYLOAD" 2>/dev/null)
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# ── 3. team-send 명령이 아니면 즉시 exit 0 (S2) ──────────────────────────
COMMAND=$(jq -r '.tool_input.command // ""' <<<"$PAYLOAD" 2>/dev/null)
case "$COMMAND" in
    # stdin 파이프 (`cat x | team-send`) 는 §10.2 공식 사용법 — 패턴 누락 시 검증이 조용히 skip 됨.
    team-send\ *|*/team-send\ *|*\;\ team-send\ *|*\&\&\ team-send\ *|*\|\ team-send\ *) ;;
    *) exit 0 ;;
esac

# ── 4. team-send 자체 실패 시 검증 skip (S7) ─────────────────────────────
# 성공 출력 패턴: "✅ <발신> → <수신> (pane N, KB)"
STDOUT=$(jq -r '.tool_response.stdout // ""' <<<"$PAYLOAD" 2>/dev/null)
case "$STDOUT" in
    *"✅"*"→"*"(pane"*) ;;
    *) exit 0 ;;
esac

# ── 5. 발신자·수신자·pane 인덱스 파싱 ────────────────────────────────────
TARGET_PANE=$(printf '%s' "$STDOUT" | grep -oE 'pane [0-9]+' | head -1 | awk '{print $2}')
if [ -z "$TARGET_PANE" ]; then
    echo "[team-send-verify] pane 인덱스 추출 실패 — stdout: $STDOUT" >&2
    exit 0
fi

# ── 6. tmux 세션·타깃 결정 ───────────────────────────────────────────────
SESSION=$(tmux display-message -p '#S' 2>/dev/null)
if [ -z "$SESSION" ]; then
    echo "[team-send-verify] tmux 세션 식별 실패 — TMUX 환경변수 미설정 가능." >&2
    exit 0
fi
TARGET="${SESSION}:0.${TARGET_PANE}"

TS=$(date +'%Y-%m-%d %H:%M:%S')

# ── 7. non-blocking 로그 전용 ─────────────────────────────────────────────
# delivery 확인은 team-send 내 positive delivery 루프로 이관 (2026-07-09).
# 구 PATTERN_ACTIVE blocking 검증·Enter 보강·exit 2 차단 제거.
# 본 hook 는 전송 이력 로깅만 수행하고 exit 0 으로 종료한다.
echo "[$TS] LOG pane=${TARGET_PANE} team-send 완료" >>"$LOG" 2>/dev/null || true
exit 0
