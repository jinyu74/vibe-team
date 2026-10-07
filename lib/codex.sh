# codex.sh — Codex 멤버의 컨텍스트·사용 한도 조회 (team-status · team-send 가 source)
#
# Codex 의 /status 와 같은 값을 세션 기록(~/.codex/sessions/**/rollout-*.jsonl)의
# token_count 이벤트에서 읽는다. 페인에 /status 를 입력하지 않으므로 작업 중인 멤버를 방해하지 않는다.
# 의존: jq (없으면 조회 결과 없음), lsof, ps. bash 3.2 호환.

CODEX_SESSIONS_DIR="${CODEX_HOME:-$HOME/.codex}/sessions"

# codex_rollout_for_pane <pane_id> — 그 페인의 Codex 프로세스가 열어 둔 세션 기록 파일 경로
codex_rollout_for_pane() {
    local root pid
    root="$(tmux display-message -p -t "$1" '#{pane_pid}' 2>/dev/null)" || return 0
    [ -n "$root" ] || return 0
    # 페인 셸의 자손 중 Codex 네이티브 바이너리(.../bin/codex)
    for pid in $(ps -A -o pid=,ppid=,comm= | awk -v r="$root" '
        { pid[NR] = $1; pp[NR] = $2; c[NR] = $3 }
        END {
            a[r] = 1; ch = 1
            while (ch) { ch = 0; for (i = 1; i <= NR; i++) if (a[pp[i]] && !a[pid[i]]) { a[pid[i]] = 1; ch = 1; if (c[i] ~ /\/bin\/codex$/) print pid[i] } }
        }'); do
        lsof -a -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | grep -m1 '/rollout-.*\.jsonl$' && return 0
    done
    # 아직 첫 요청 전이라 세션 기록이 없으면 빈 결과 — set -e 호출자를 멈추지 않도록 성공으로 끝낸다.
    return 0
}

# codex_latest_rollout — 가장 최근에 갱신된 세션 기록 (사용 한도는 계정 단위라 아무 세션이나 최신이면 된다)
codex_latest_rollout() {
    [ -d "$CODEX_SESSIONS_DIR" ] || return 0
    find "$CODEX_SESSIONS_DIR" -name 'rollout-*.jsonl' -mtime -7 -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null | head -1
}

# codex_usage <rollout 파일> — 한 줄 출력: "ctx_left|5h_left|5h_reset_epoch|week_left|week_reset_epoch"
#   ctx_left: 컨텍스트 남은 % (Codex /status 와 같은 계산: 기본 12K 토큰 제외)
#   *_left  : 한도 남은 % (리셋 시각이 지났으면 100)
#   값이 없으면 빈 칸.
codex_usage() {
    local file="$1"
    [ -f "$file" ] && command -v jq >/dev/null 2>&1 || return 0
    tail -n 3000 "$file" | grep '"token_count"' | tail -1 | jq -r --argjson now "$(date +%s)" '
        .payload as $p
        | ($p.info // {}) as $i
        | (if $i.model_context_window and $i.last_token_usage then
              ($i.model_context_window - 12000) as $eff
              | ($i.last_token_usage.total_tokens - 12000) as $used
              | (if $used <= 0 then 100 else ((($eff - $used) / $eff) * 100 | floor) end)
              | if . < 0 then 0 elif . > 100 then 100 else . end
           else "" end) as $ctx
        | def left(w): if w == null then "" elif (w.resets_at // 0) < $now then 100 else (100 - w.used_percent | floor) end;
        ($p.rate_limits // {}) as $r
        | [$ctx, left($r.primary), ($r.primary.resets_at // ""), left($r.secondary), ($r.secondary.resets_at // "")]
        | map(tostring) | join("|")' 2>/dev/null
}

# codex_fmt_time <epoch> [형식] — 로컬 시각 (BSD/GNU date 모두 지원)
codex_fmt_time() {
    [ -n "$1" ] || return 0
    date -r "$1" "+${2:-%H:%M}" 2>/dev/null || date -d "@$1" "+${2:-%H:%M}" 2>/dev/null
}

# codex_limit_marker <남은 %> — 5시간 한도 경고 표시 (30% 미만 ⚠️, 10% 미만 🚨)
codex_limit_marker() {
    [ -n "$1" ] || { printf '  '; return; }
    if   [ "$1" -lt 10 ]; then printf '🚨'
    elif [ "$1" -lt 30 ]; then printf '⚠️ '
    else                       printf '  '
    fi
}
