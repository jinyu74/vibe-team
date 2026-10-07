#!/bin/bash
# setup-team.sh — vibe-team: 파트별 Claude·Codex 페어 팀 환경 자동 구성

set -e

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SESSION=""

# ── 옵션 파싱: [세션이름] [-d|--dir <workdir>] [-c|--config <팀 이름|설정 파일>] ──
WORKDIR=""
MEMBERS_FILE=""
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dir) WORKDIR="$2"; shift 2 ;;
        -c|--config) MEMBERS_FILE="$2"; shift 2 ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            echo "Usage: $0 [session-name] [-d|--dir <workdir>] [-c|--config <팀 이름|설정 파일>] [-n|--dry-run]"
            echo "  session-name : tmux 세션 이름 (기본: team)"
            echo "  -d, --dir    : 작업 디렉터리 (기본: 현재 디렉터리)"
            echo "  -c, --config : 팀 이름(teams/<이름>.conf) 또는 설정 파일 경로 (기본: discovery — 발견 팀)"
            echo "                 팀 목록: $(cd "$(dirname "$0")/teams" 2>/dev/null && ls *.conf 2>/dev/null | sed 's/\.conf$//' | tr '\n' ' ')"
            echo "  -n, --dry-run: tmux·훅을 건드리지 않고 구성 검증 + 멤버별 주입 지시(roles/.merged/<세션>/)만 만든다"
            exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) SESSION="$1"; shift ;;
    esac
done
SESSION="${SESSION:-team}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROLES_DIR="$SCRIPT_DIR/roles"

# 멤버 설정 로드 — 형식 오류는 tmux 세션을 만들기 전에 실패시킨다.
. "$SCRIPT_DIR/lib/members.sh"
# 팀 설정: 기본은 발견 팀(discovery). 이름만 주면 teams/<이름>.conf, 경로를 주면 그 파일.
MEMBERS_FILE="${MEMBERS_FILE:-discovery}"
case "$MEMBERS_FILE" in
    */*|*.conf) ;;
    *) MEMBERS_FILE="$SCRIPT_DIR/teams/$MEMBERS_FILE.conf" ;;
esac
[ -f "$MEMBERS_FILE" ] && MEMBERS_FILE="$(cd "$(dirname "$MEMBERS_FILE")" && pwd)/$(basename "$MEMBERS_FILE")"
load_members "$MEMBERS_FILE" || exit 1
# 역할 파일이 없는 멤버는 역할 지시 없이 기동되므로 세션을 만들기 전에 실패시킨다.
# 역할파일 열은 '+' 로 여러 파트를 겹칠 수 있다(예: 빌드+CI) — 작은 팀에서 한 페어가 여러 파트를 맡을 때.
role_files() { local r; for r in $(printf '%s' "$1" | tr '+' ' '); do echo "$ROLES_DIR/$r.md"; done; }
_missing_roles=""
i=0
while [ $i -lt $M_COUNT ]; do
    for f in $(role_files "${M_ROLE[$i]}"); do
        [ -f "$f" ] || _missing_roles="$_missing_roles ${M_NAME[$i]}(roles/$(basename "$f"))"
    done
    i=$((i + 1))
done
if [ -n "$_missing_roles" ]; then
    echo -e "\033[0;31m❌ 역할 파일 없음:$_missing_roles — 팀 설정의 역할파일 열 또는 roles/ 를 확인하세요.\033[0m"
    exit 1
fi
WORKDIR="${WORKDIR:-$PWD}"
if [ ! -d "$WORKDIR" ]; then
    echo -e "\033[0;36m📁 작업 디렉터리 생성: $WORKDIR\033[0m"
    mkdir -p "$WORKDIR" || {
        echo -e "\033[0;31m❌ 디렉터리 생성 실패: $WORKDIR\033[0m"
        exit 1
    }
fi
WORKDIR="$(cd "$WORKDIR" && pwd)"

# ── 유틸: 엔진별 준비 완료 화면 패턴 ───────────────────────
ready_pattern() {
    case "$1" in
        codex) echo "for shortcuts" ;;
        *)     echo "bypass permissions" ;;
    esac
}

# ── 유틸: 멤버 정체 블록 — 역할 지시 맨 앞에 붙는다 ────────────
# 페어처럼 여러 멤버가 같은 역할 파일을 쓸 때 각자 자기 이름·엔진·상대를 알게 한다.
member_identity() {
    local i="$1" j=0 partners="" eng
    for j in $(member_partner_indices "$i"); do
        [ "${M_ENGINE[$j]}" = "codex" ] && eng="Codex" || eng="Claude"
        partners="${partners:+$partners, }${M_NAME[$j]} ($eng; ${M_ROLE[$j]})"
    done
    [ "${M_ENGINE[$i]}" = "codex" ] && eng="Codex" || eng="Claude"
    local roster="" wt_note
    j=0
    while [ $j -lt $M_COUNT ]; do roster="${roster:+$roster, }${M_NAME[$j]}"; j=$((j + 1)); done
    if [ "${M_DIR[$i]}" != "$WORKDIR" ]; then
        wt_note="${M_DIR[$i]} — **전용 git worktree**. 브랜치 전환·커밋은 여기서만 한다. 커밋하지 않는 공유 산출물(분석·명세 문서 등)은 공유 작업 폴더 \`$WORKDIR\`(\$TEAM_WORKDIR)에 쓰고 절대 경로로 알린다 (공통 §9.3)"
    else
        wt_note="$WORKDIR — 공유 작업 폴더 (브랜치를 바꾸지 않는다 — 공통 §9.3)"
    fi
    cat <<EOF
## 당신의 정체 (setup-team.sh 가 팀 설정으로 생성)

- 이름: **${M_NAME[$i]}** — team-send 수신자 이름${M_ALIASES[$i]:+ (별칭: ${M_ALIASES[$i]})}
- 엔진: **$eng** (${M_MODEL[$i]}, effort ${M_EFFORT[$i]})
- 프로젝트: ${TEAM_PROJECT:-지정 없음}
- tmux 창: ${M_WINDOW[$i]}
- 담당 파트(역할 파일): $(printf '%s' "${M_ROLE[$i]}" | tr '+' '\n' | sed 's|.*|roles/&.md|' | paste -sd ' ' -)
- 담당 파트의 반대 엔진 페어: ${partners:-없음}
- 부여된 플러그인: ${M_PLUGINS[$i]:-없음} (팀 설정 플러그인 열 — 이 목록 밖의 스킬·플러그인이 설치돼 있다고 가정하지 않는다)
- 작업 폴더: $wt_note
- 팀 명단: $roster — 역할 파일·공통 워크플로가 이 명단에 없는 멤버를 부르면 아래 대체 담당에게, 표에도 없으면 진행-클로드에게 보낸다. 겹친 파트 이름(예: \`CI-클로드\`)은 다른 멤버의 별칭이므로 그대로 보내면 된다 (공통 §1·§10.1)
- 팀 구성은 \`team-send -h\`, 상태는 \`team-status\` 로 확인한다.
EOF
    if [ -n "${M_DUTY[$i]}" ]; then
        printf '\n### 이 프로젝트에서의 책임 (팀 설정 @duty — 역할 파일의 책임 범위보다 우선)\n\n'
        printf '%s\n' "${M_DUTY[$i]}" | sed 's/^/- /'
    fi
    if [ "$SUB_COUNT" -gt 0 ]; then
        printf '\n### 부재 멤버의 연락 대체 (팀 설정 @substitute — 실제 겸임·역할 주입 아님)\n\n| 역할 파일이 부르는 멤버 | 이 팀의 연락 담당 | 범위 |\n|---|---|---|\n'
        j=0
        while [ $j -lt $SUB_COUNT ]; do
            printf '| %s | %s | %s |\n' "${SUB_ABSENT[$j]}" "${SUB_TO[$j]}" "${SUB_NOTE[$j]:--}"
            j=$((j + 1))
        done
    fi
    printf '\n---\n\n'
}

# ── 유틸: 멤버별 작업 폴더 (@worktree) ─────────────────────
# 지정 멤버는 작업 폴더 저장소의 전용 worktree(<저장소>-wt/<이름>)에서 기동해 브랜치·인덱스·커밋이 섞이지 않게 한다.
# 이미 있는 worktree 는 그대로 재사용한다(체크아웃된 브랜치·변경을 건드리지 않음). 새로 만들 때는 저장소 HEAD 에서 detached 로 만든다.
# 작업 폴더가 git 저장소가 아니거나 커밋이 없으면 경고 후 공유 폴더에서 기동한다. 삭제는 자동으로 하지 않는다(git worktree remove).
M_DIR=()
prepare_worktrees() {
    local i=0 any=0 top rel dir common
    while [ $i -lt $M_COUNT ]; do
        M_DIR[$i]="$WORKDIR"; [ "${M_WORKTREE[$i]}" = 1 ] && any=1
        i=$((i + 1))
    done
    [ $any -eq 1 ] || return 0
    if ! top="$(git -C "$WORKDIR" rev-parse --show-toplevel 2>/dev/null)" || ! git -C "$top" rev-parse -q --verify HEAD >/dev/null; then
        echo -e "  ${YELLOW}⚠️  작업 폴더가 커밋이 있는 git 저장소가 아니라 @worktree 를 적용하지 않습니다 — 전원 공유 폴더에서 기동${NC}"
        return 0
    fi
    common="$(git -C "$top" rev-parse --path-format=absolute --git-common-dir)"
    rel="${WORKDIR#"$top"}"; rel="${rel#/}"
    i=0
    while [ $i -lt $M_COUNT ]; do
        if [ "${M_WORKTREE[$i]}" = 1 ]; then
            dir="$top-wt/${M_NAME[$i]}"
            if [ -e "$dir" ]; then
                if [ "$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" != "$common" ]; then
                    echo -e "  ${RED}❌ $dir 가 이미 있지만 이 저장소의 worktree 가 아닙니다 — 옮기거나 지운 뒤 다시 실행하세요${NC}"
                    exit 1
                fi
                echo "  ♻️  ${M_NAME[$i]}: 기존 worktree 재사용 ($dir, $(git -C "$dir" rev-parse --abbrev-ref HEAD))"
            else
                mkdir -p "$top-wt"
                git -C "$top" worktree add -q --detach "$dir" HEAD || { echo -e "  ${RED}❌ ${M_NAME[$i]}: worktree 생성 실패 ($dir)${NC}"; exit 1; }
                echo "  🌿 ${M_NAME[$i]}: worktree 생성 ($dir, detached $(git -C "$dir" rev-parse --short HEAD))"
            fi
            M_DIR[$i]="$dir${rel:+/$rel}"
            mkdir -p "${M_DIR[$i]}"
        fi
        i=$((i + 1))
    done
}

# ── 유틸: 멤버별 플러그인 (팀 설정 플러그인 열) ─────────────
# Claude: 공식 마켓플레이스 사본의 플러그인 폴더를 --plugin-dir 로 그 멤버 세션에만 로드 (전역 활성화 안 함).
# Codex : openai-curated-remote 플러그인을 설치해 두고 전역은 끈 상태(~/.codex/config.toml enabled=false)에서
#         멤버마다 -c plugins.<이름>@openai-curated-remote.enabled=true 로 켠다 (키에 따옴표를 쓰면 적용되지 않음).
CLAUDE_MARKET="$HOME/.claude/plugins/marketplaces/claude-plugins-official"
CODEX_PLUGIN_MARKET="openai-curated-remote"
CODEX_PLUGIN_CACHE="${CODEX_HOME:-$HOME/.codex}/plugins/cache/$CODEX_PLUGIN_MARKET"
# check_plugins — 기동 전 점검: 팀 설정의 플러그인이 실제로 있는지 (없는 것은 경고 후 건너뜀)
check_plugins() {
    local i=0 p
    while [ $i -lt $M_COUNT ]; do
        for p in ${M_PLUGINS[$i]}; do
            if [ "${M_ENGINE[$i]}" = "codex" ]; then
                [ -d "$CODEX_PLUGIN_CACHE/$p" ] || echo -e "  ${YELLOW}⚠️  ${M_NAME[$i]}: Codex 플러그인 '$p' 미설치 — codex plugin add $p@$CODEX_PLUGIN_MARKET${NC}"
            else
                [ -d "$CLAUDE_MARKET/plugins/$p" ] || [ -d "$CLAUDE_MARKET/external_plugins/$p" ] \
                    || echo -e "  ${YELLOW}⚠️  ${M_NAME[$i]}: Claude 플러그인 '$p' 가 공식 마켓플레이스 사본에 없음 ($CLAUDE_MARKET)${NC}"
            fi
        done
        i=$((i + 1))
    done
}

# 팀이 관리하는 Codex 플러그인 = 모든 팀 설정(teams/*.conf + 이번 설정)의 codex 멤버 플러그인 열 합집합.
# 대화형 Codex 는 원격 설치 플러그인의 enabled 설정을 따르지 않으므로(2026-10-02 확인), 멤버에게 부여되지 않은
# 관리 대상 플러그인의 스킬을 skills.config 로 경로 단위 비활성화해 멤버별 부여를 실현한다.
codex_managed_plugins() {
    awk -F'|' '!/^[[:space:]]*[#@[]/ && NF >= 8 {
        e = $4; gsub(/[[:space:]]/, "", e)
        if (e == "codex") { n = split($8, a, /[[:space:]]+/); for (k = 1; k <= n; k++) if (a[k] != "") print a[k] }
    }' "$SCRIPT_DIR"/teams/*.conf "$MEMBERS_FILE" 2>/dev/null | sort -u
}

# member_plugin_args <멤버 인덱스> — 엔진에 맞는 플러그인 인자를 한 줄에 하나씩 출력
member_plugin_args() {
    local i="$1" p dir off="" f
    if [ "${M_ENGINE[$i]}" = "codex" ]; then
        for p in $(codex_managed_plugins); do
            case " ${M_PLUGINS[$i]} " in *" $p "*) continue ;; esac
            [ -d "$CODEX_PLUGIN_CACHE/$p" ] || continue
            while IFS= read -r f; do
                [ -n "$f" ] && off="${off:+$off,}{path=\"$f\",enabled=false}"
            done <<EOF
$(find "$CODEX_PLUGIN_CACHE/$p" -name SKILL.md 2>/dev/null)
EOF
        done
        [ -n "$off" ] && { echo "-c"; echo "skills.config=[$off]"; }
    fi
    for p in ${M_PLUGINS[$i]}; do
        if [ "${M_ENGINE[$i]}" = "codex" ]; then
            if [ -d "$CODEX_PLUGIN_CACHE/$p" ]; then
                echo "-c"; echo "plugins.$p@$CODEX_PLUGIN_MARKET.enabled=true"
            fi
        else
            dir=""
            [ -d "$CLAUDE_MARKET/plugins/$p" ] && dir="$CLAUDE_MARKET/plugins/$p"
            [ -z "$dir" ] && [ -d "$CLAUDE_MARKET/external_plugins/$p" ] && dir="$CLAUDE_MARKET/external_plugins/$p"
            [ -n "$dir" ] && { echo "--plugin-dir"; echo "$dir"; }
        fi
    done
}

# ── 유틸: 멤버별 주입 지시 — 정체 블록 + 공통 워크플로(_team-workflow.md) + 담당 파트 역할 파일 ──
# 파일 이름은 멤버 이름 — 페어가 같은 역할 파일을 써도 서로 덮어쓰지 않는다.
# 세션별 폴더 — 여러 팀(세션)이 같은 멤버 이름을 써도 서로 덮어쓰지 않는다. 만든 파일 경로를 출력한다.
write_merged() {
    local idx="$1" f merged_dir="$ROLES_DIR/.merged/$SESSION"
    local merged_file="$merged_dir/${M_NAME[$idx]}.md"
    mkdir -p "$merged_dir" || return 1
    {
        member_identity "$idx" || return 1
        cat "$ROLES_DIR/_team-workflow.md" || return 1
        for f in $(role_files "${M_ROLE[$idx]}"); do
            printf "\n\n---\n\n" || return 1
            cat "$f" || return 1
        done
    } > "$merged_file" || return 1
    echo "$merged_file"
}

# ── 유틸: 멤버 실행 (claude | codex) + 다이얼로그 자동 처리 ──
start_member_in_pane() {
    local pane="$1" idx="$2" f
    local engine="${M_ENGINE[$idx]}" model="${M_MODEL[$idx]}" effort="${M_EFFORT[$idx]}"

    tmux send-keys -t "$pane" C-c 2>/dev/null; sleep 0.3
    tmux send-keys -t "$pane" C-u 2>/dev/null; sleep 0.2

    local merged_dir="$ROLES_DIR/.merged/$SESSION"
    local merged_file
    merged_file="$(write_merged "$idx")" || return 1

    # team-send 헬퍼를 PATH 에 노출 (페인 간 메시지 전송용)
    # TEAM_MEMBER·TEAM_ENGINE: 체크포인트 훅(bin/team-checkpoint)이 멤버를 식별하는 데 쓴다.
    # 한글 이름은 printf %q 로 감싸면 페인의 zsh 가 바이트를 잘못 해석하므로 큰따옴표로만 감싼다.
    local prefix="cd \"${M_DIR[$idx]}\" && export PATH=\"$SCRIPT_DIR/bin:\$PATH\" TEAM_WORKDIR=\"$WORKDIR\" TEAM_MEMBER=\"${M_NAME[$idx]}\" TEAM_ENGINE=$engine TEAM_SESSION=\"$SESSION\" && unset CLAUDECODE"
    # security-guidance: 여러 멤버가 한 작업 폴더를 공유하므로 턴 종료 LLM 리뷰는 끈다 (플러그인 README 권장 — 다른 멤버가 HEAD 를 옮길 수 있음)
    case " ${M_PLUGINS[$idx]} " in *" security-guidance "*) prefix="$prefix && export ENABLE_STOP_REVIEW=0" ;; esac
    local checkpoint="$SCRIPT_DIR/bin/team-checkpoint"
    local plugin_args=()
    while IFS= read -r line; do plugin_args[${#plugin_args[@]}]="$line"; done <<EOF
$(member_plugin_args "$idx")
EOF
    [ -n "${plugin_args[0]:-}" ] || plugin_args=()

    if [ "$engine" = "codex" ]; then
        # Codex 는 --append-system-prompt-file 이 없어 developer_instructions 설정으로 주입한다.
        # 역할 지시(~45KB)를 send-keys 로 타이핑하지 않도록 실행 스크립트를 만들어 호출한다.
        # TOML 멀티라인 리터럴 문자열(''') 은 이스케이프가 필요 없지만, 본문에 ''' 가 있으면 깨진다.
        local tq="'''"
        local launcher="$merged_dir/${M_NAME[$idx]}.codex.sh"
        local codex_cmd
        # --search: 웹 검색 사용 (조사 역할). check_for_update_on_startup=false: 기동 시 업데이트 안내가 뜨면
        # 자동 입력(Enter)이 "Update now" 로 선택돼 전역 npm 업데이트가 실행되므로 끈다 (업데이트는 사용자가 직접).
        # --no-daemon: 대화형 Codex 는 공유 백그라운드 서버에 붙고 플러그인 상태가 서버 단위로 잡혀, 멤버별 플러그인 지정이
        # 새어 나간다(2026-10-02 확인). 멤버마다 독립 프로세스로 띄워 멤버별 설정(-c)이 그대로 적용되게 한다.
        codex_cmd="exec $(printf '%q' "$(command -v codex)") --dangerously-bypass-approvals-and-sandbox --no-daemon --search -c check_for_update_on_startup=false -m $(printf '%q' "$model") -c model_reasoning_effort=$(printf '%q' "$effort")"
        if [ -n "$merged_file" ]; then
            if grep -qF "$tq" "$merged_file"; then
                echo -e "${RED}❌ $merged_file 에 $tq 가 있어 Codex 에 주입할 수 없습니다${NC}"
                return 1
            fi
            codex_cmd="$codex_cmd -c \"developer_instructions=$tq\$(cat $(printf '%q' "$merged_file"))$tq\""
        fi
        # 체크포인트 훅은 사용자 전역 ~/.codex/hooks.json 에 등록되어 있다(0.5단계). 신뢰 우회 옵션은 쓰지 않는다 —
        # 모든 활성 훅(RTK 등)의 검토를 건너뛰고 경고를 띄우기 때문 (2026-10-02 사용자 결정).
        local a
        for a in "${plugin_args[@]}"; do codex_cmd="$codex_cmd $(printf '%q' "$a")"; done
        printf '#!/bin/bash\n%s\n' "$codex_cmd" > "$launcher"
        tmux send-keys -t "$pane" "$prefix && bash \"$launcher\"" Enter

        # 다이얼로그: 폴더 신뢰 → Enter (1. Trust and continue)
        #            훅 검토   → Esc (이번 실행은 신뢰 없이 건너뜀 — 사용자 훅 신뢰는 사용자가 직접 결정)
        local waited=0 screen
        while [ $waited -lt 60 ]; do
            screen="$(tmux capture-pane -t "$pane" -p 2>/dev/null)"
            case "$screen" in
                *"for shortcuts"*) return 0 ;;
                *"Trust this folder"*) tmux send-keys -t "$pane" Enter; sleep 1 ;;
                *"Hooks need review"*) tmux send-keys -t "$pane" Escape; sleep 1 ;;
            esac
            sleep 1; waited=$((waited + 1))
        done
        return 1
    fi

    # 체크포인트 훅: PreCompact 에서 저장, 정리 후 SessionStart(source=compact) 에서 복구 지시 주입.
    # --settings 로 이 멤버 세션에만 등록한다 (사용자 전역 settings.json 은 건드리지 않음).
    local settings="$merged_dir/${M_NAME[$idx]}.settings.json"
    printf '{"hooks":{"PreCompact":[{"hooks":[{"type":"command","command":"%s pre","timeout":30}]}],"SessionStart":[{"matcher":"compact","hooks":[{"type":"command","command":"%s post","timeout":30}]}]}}\n' \
        "$checkpoint" "$checkpoint" > "$settings"
    local launcher="$merged_dir/${M_NAME[$idx]}.claude.sh"
    local claude_cmd a
    claude_cmd="exec $(printf '%q' "$(command -v claude)") --model $(printf '%q' "$model") --effort $(printf '%q' "$effort")"
    claude_cmd="$claude_cmd --append-system-prompt-file $(printf '%q' "$merged_file") --settings $(printf '%q' "$settings")"
    for a in "${plugin_args[@]}"; do claude_cmd="$claude_cmd $(printf '%q' "$a")"; done
    claude_cmd="$claude_cmd --dangerously-skip-permissions"
    printf '#!/bin/bash\n%s\n' "$claude_cmd" > "$launcher"
    tmux send-keys -t "$pane" "$prefix && bash \"$launcher\"" Enter

    # 다이얼로그 자동 처리 — 선택 항목을 확인한 뒤 고른다.
    #   폴더 신뢰: 기본 선택이 "No, exit" 이므로 Enter 만 보내면 Claude 가 종료된다.
    #             커서(❯)가 "Yes, I trust this folder" 에 올 때까지 Down 후 Enter.
    #   약관 동의: Down + Enter (구버전 화면)
    local waited=0 screen
    while [ $waited -lt 60 ]; do
        screen="$(tmux capture-pane -t "$pane" -p 2>/dev/null)"
        case "$screen" in
            *"Yes, I trust this folder"*)
                if printf '%s\n' "$screen" | grep -q "❯.*Yes, I trust this folder"; then
                    tmux send-keys -t "$pane" Enter
                else
                    tmux send-keys -t "$pane" Down
                fi
                sleep 1 ;;
            *"I accept"*)
                tmux send-keys -t "$pane" Down; sleep 0.5
                tmux send-keys -t "$pane" Enter; sleep 1 ;;
            *"bypass permissions"*) return 0 ;;
        esac
        sleep 1; waited=$((waited + 1))
    done
    return 1
}

# ── 드라이런: 구성 검증 + 주입 지시 생성만 (tmux·전역 훅·worktree 를 건드리지 않음) ──
if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${YELLOW}[dry-run] $MEMBERS_FILE (${M_COUNT}명, 창 ${W_COUNT}개)${NC}"
    [ -n "$TEAM_PROJECT" ] && echo "  🎯 프로젝트: $TEAM_PROJECT"
    check_plugins
    i=0
    while [ $i -lt $M_COUNT ]; do
        M_DIR[$i]="$WORKDIR"
        [ "${M_WORKTREE[$i]}" = 1 ] && M_DIR[$i]="$(git -C "$WORKDIR" rev-parse --show-toplevel 2>/dev/null || echo "$WORKDIR")-wt/${M_NAME[$i]}"
        f="$(write_merged "$i")" || { echo "역할 주입 생성 실패: ${M_NAME[$i]}" >&2; exit 1; }
        printf '  %-3s %-12s %-24s %-7s %-22s %-6s %s\n' "$i" "[${M_WINDOW[$i]}]" "${M_NAME[$i]}" "${M_ENGINE[$i]}" "${M_MODEL[$i]}" "${M_EFFORT[$i]}" "$(wc -c < "$f" | tr -d ' ')B"
        i=$((i + 1))
    done
    echo -e "  ${GREEN}✅ 주입 지시: $ROLES_DIR/.merged/$SESSION/${NC}"
    exit 0
fi

# ── [0/4] 사전 요구사항 확인 ────────────────────────────────
echo -e "${YELLOW}[0/4] 사전 요구사항 확인...${NC}"

MISSING=()
command -v tmux   &>/dev/null || MISSING+=("tmux (sudo apt install -y tmux)")
# 엔진 CLI 는 팀 설정에서 실제로 쓰는 것만 요구한다.
case " ${M_ENGINE[*]} " in *" claude "*)
    command -v claude &>/dev/null || MISSING+=("claude (npm install -g @anthropic-ai/claude-code)") ;; esac
case " ${M_ENGINE[*]} " in *" codex "*)
    command -v codex &>/dev/null || MISSING+=("codex (npm install -g @openai/codex)") ;; esac
# jq — team-send-verify hook 가 stdin JSON 파싱에 사용. 미설치 시 hook 가 graceful skip 하지만 검증 자동화가 동작 안 함.
JQ_OK=1
if ! command -v jq &>/dev/null; then
    JQ_OK=0
    echo -e "${YELLOW}  ⚠️  jq 미설치 — team-send-verify hook 가 graceful skip 됩니다.${NC}"
    echo -e "${YELLOW}     설치 권장: brew install jq (macOS) / apt install -y jq (Ubuntu)${NC}"
fi
# rsync — 스킬 디렉토리 idempotent 배포에 사용. 미설치 시 cp -R fallback.
RSYNC_OK=1
command -v rsync &>/dev/null || RSYNC_OK=0

if [ ${#MISSING[@]} -gt 0 ]; then
    echo -e "${RED}❌ 누락된 의존성:${NC}"
    for m in "${MISSING[@]}"; do echo "   - $m"; done
    exit 1
fi

echo "  ✅ tmux $(tmux -V | awk '{print $2}')"
command -v claude &>/dev/null && echo "  ✅ claude $(claude --version 2>/dev/null | head -1)"
command -v codex  &>/dev/null && echo "  ✅ $(codex --version 2>/dev/null | head -1)"
[ "$JQ_OK" -eq 1 ] && echo "  ✅ jq $(jq --version 2>/dev/null)"
[ "$JQ_OK" -eq 1 ] || echo -e "  ${YELLOW}⚠️  jq 미설치 — 체크포인트 훅·Codex 한도 조회가 동작하지 않습니다${NC}"
check_plugins
echo "  📂 작업 디렉터리: $WORKDIR"
echo "  🏷️  세션 이름: $SESSION"
echo "  👥 멤버 설정: $MEMBERS_FILE (${M_COUNT}명)"
[ -n "$TEAM_PROJECT" ] && echo "  🎯 프로젝트: $TEAM_PROJECT"

# ── [0.5/4] team-send-verify hook + 스킬 배포 (사용자 전역) ─────────────
# 본 단계는 jq 가 있을 때만 hook 등록 진행. 스킬은 jq 없이도 배포.
echo -e "\n${YELLOW}[0.5/4] 훅 + 스킬 배포 (team-send-verify, Codex 체크포인트)...${NC}"

HOOK_CMD="$SCRIPT_DIR/bin/team-send-verify.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"
SKILL_SRC="$SCRIPT_DIR/skills/vibe-send-verify"
SKILL_DST="$HOME/.claude/skills/vibe-send-verify"

if [ ! -x "$HOOK_CMD" ]; then
    chmod +x "$HOOK_CMD" 2>/dev/null || true
fi

if [ "$JQ_OK" -eq 1 ] && [ -x "$HOOK_CMD" ]; then
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    if [ ! -f "$SETTINGS_FILE" ]; then
        echo '{}' > "$SETTINGS_FILE"
    fi
    # 백업 (timestamp suffix). 누적되지만 사용자가 정리 가능.
    cp "$SETTINGS_FILE" "$SETTINGS_FILE.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

    # smart merge — 동일 (matcher, command) 중복 추가 방지, 다른 hook 보존.
    # 다른 저장소(claude-ecg-team 등)가 등록한 team-send-verify.sh 는 이 저장소 것으로 바꾼다 — 같은 전송이 두 번 기록되지 않게.
    PATCH_JSON=$(jq -n --arg cmd "$HOOK_CMD" '{
        hooks: {
            PostToolUse: [
                {
                    matcher: "Bash",
                    hooks: [{type: "command", command: $cmd}]
                }
            ]
        }
    }')

    MERGED=$(jq -s --arg cmd "$HOOK_CMD" --argjson patch "$PATCH_JSON" '
        .[0] as $base |
        $base
        | .hooks //= {}
        | .hooks.PostToolUse =
            ([($base.hooks.PostToolUse // [])[], ($patch.hooks.PostToolUse // [])[]]
              | group_by(.matcher)
              | map({
                  matcher: .[0].matcher,
                  hooks: ([.[].hooks[]] | map(select(((.command // "") | endswith("team-send-verify.sh") | not) or .command == $cmd)) | unique_by(.command))
              })
            )
    ' "$SETTINGS_FILE" 2>/dev/null)

    if [ -n "$MERGED" ]; then
        TMP_SETTINGS=$(mktemp)
        printf '%s\n' "$MERGED" > "$TMP_SETTINGS" && mv "$TMP_SETTINGS" "$SETTINGS_FILE"
        echo -e "  ${GREEN}✅${NC} ~/.claude/settings.json — team-send-verify hook 등록"
    else
        echo -e "  ${RED}❌${NC} jq smart merge 실패 — settings.json 백업 보존, hook 미등록"
    fi
else
    [ "$JQ_OK" -eq 0 ] && echo -e "  ${YELLOW}⏭️${NC} jq 미설치 — hook 등록 skip"
    [ ! -x "$HOOK_CMD" ] && echo -e "  ${YELLOW}⏭️${NC} $HOOK_CMD 실행 권한 없음 — hook 등록 skip"
fi

# Codex 체크포인트 훅 — 사용자 전역 ~/.codex/hooks.json 에 병합 등록 (공통 §8.1)
# 신뢰는 사용자가 /hooks 에서 한 번 직접 한다(자동 기동은 훅 검토 화면을 건너뛴다). 신뢰 기록은 "파일:이벤트:순번" 단위라
# 기존 훅(예: RTK)의 순번을 바꾸지 않도록 이벤트 목록 끝에 붙이고, 내용이 같으면 다시 쓰지 않는다(신뢰 유지).
# 팀 멤버가 아닌 세션에서는 bin/team-checkpoint 가 TEAM_MEMBER 가 없어 즉시 끝나므로 개인 Codex 세션에는 영향이 없다.
case " ${M_ENGINE[*]} " in *" codex "*)
    CODEX_HOOKS="${CODEX_HOME:-$HOME/.codex}/hooks.json"
    CODEX_CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
    if [ "$JQ_OK" -eq 1 ]; then
        [ -f "$CODEX_HOOKS" ] || echo '{}' > "$CODEX_HOOKS"
        CK="$SCRIPT_DIR/bin/team-checkpoint"
        CODEX_HOOKS_NEW=$(jq --arg pre "$CK pre" --arg post "$CK post" '
            def strip: map(select([.hooks[]?.command // ""] | any(test("team-checkpoint")) | not));
            .hooks //= {}
            | .hooks.PreCompact       = ((.hooks.PreCompact // [])       | strip) + [{hooks: [{type: "command", command: $pre,  timeout: 30}]}]
            | .hooks.SessionStart     = ((.hooks.SessionStart // [])     | strip) + [{matcher: "compact", hooks: [{type: "command", command: $post, timeout: 30}]}]
            | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) | strip) + [{hooks: [{type: "command", command: $post, timeout: 30}]}]
        ' "$CODEX_HOOKS" 2>/dev/null)
        if [ -z "$CODEX_HOOKS_NEW" ]; then
            echo -e "  ${RED}❌${NC} ~/.codex/hooks.json 병합 실패 — 체크포인트 훅 미등록 (파일 보존)"
        elif [ "$CODEX_HOOKS_NEW" = "$(jq . "$CODEX_HOOKS" 2>/dev/null)" ]; then
            echo -e "  ${GREEN}✅${NC} ~/.codex/hooks.json — 체크포인트 훅 등록됨 (변경 없음)"
        else
            cp "$CODEX_HOOKS" "$CODEX_HOOKS.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
            printf '%s\n' "$CODEX_HOOKS_NEW" > "$CODEX_HOOKS"
            echo -e "  ${GREEN}✅${NC} ~/.codex/hooks.json — 체크포인트 훅 등록 (기존 훅 보존, 백업 생성)"
        fi
        # 신뢰 여부: config.toml 의 [hooks.state."<파일>:<이벤트>:<순번>:0"] 에 trusted_hash 가 있는지
        CODEX_UNTRUSTED=""
        for ev in PreCompact:pre_compact SessionStart:session_start UserPromptSubmit:user_prompt_submit; do
            idx=$(jq --arg e "${ev%%:*}" '(.hooks[$e] | length) - 1' "$CODEX_HOOKS" 2>/dev/null)
            key="[hooks.state.\"$CODEX_HOOKS:${ev##*:}:$idx:0\"]"
            awk -v k="$key" '$0 == k { f = 1; next } f && /^\[/ { exit } f && /^trusted_hash/ { t = 1 } END { exit !t }' "$CODEX_CONFIG" 2>/dev/null \
                || CODEX_UNTRUSTED="$CODEX_UNTRUSTED ${ev%%:*}"
        done
        if [ -n "$CODEX_UNTRUSTED" ]; then
            echo -e "  ${YELLOW}⚠️  Codex 체크포인트 훅 미신뢰:${CODEX_UNTRUSTED} — 신뢰 전에는 Codex 멤버의 자동 체크포인트가 동작하지 않습니다.${NC}"
            echo -e "  ${YELLOW}     한 번만: 터미널에서 codex 실행 → /hooks → team-checkpoint 훅 3개 검토 후 신뢰${NC}"
        else
            echo -e "  ${GREEN}✅${NC} Codex 체크포인트 훅 신뢰됨"
        fi
    else
        echo -e "  ${YELLOW}⏭️${NC} jq 미설치 — Codex 체크포인트 훅 등록 skip"
    fi
    ;;
esac

# 스킬 배포 — idempotent
if [ -d "$SKILL_SRC" ]; then
    mkdir -p "$HOME/.claude/skills"
    if [ "$RSYNC_OK" -eq 1 ]; then
        rsync -a --delete "$SKILL_SRC/" "$SKILL_DST/"
    else
        rm -rf "$SKILL_DST" && mkdir -p "$SKILL_DST" && cp -R "$SKILL_SRC/." "$SKILL_DST/"
    fi
    echo -e "  ${GREEN}✅${NC} ~/.claude/skills/vibe-send-verify/ 배포"
fi

# ── [1/4] 기존 세션 정리 ────────────────────────────────────
echo -e "\n${YELLOW}[1/4] 기존 세션 확인...${NC}"
if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo -ne "  기존 '$SESSION' 세션이 존재합니다. 재생성하시겠습니까? [y/N]: "
    read -r CONFIRM </dev/tty
    case "$CONFIRM" in
        y|Y|yes|YES)
            tmux kill-session -t "$SESSION"
            echo "  기존 '$SESSION' 세션 종료 → 새로 생성합니다"
            ;;
        *)
            echo "  ✋ 재생성 취소. 기존 세션에 attach 합니다."
            [ -t 1 ] && exec tmux attach -t "$SESSION"
            exit 0
            ;;
    esac
fi

# 멤버별 작업 폴더 — 세션을 만들기 전에 준비한다(실패하면 세션 없이 끝남).
prepare_worktrees

# ── [2/4] TMUX 세션 & 레이아웃 구성 ────────────────────────
echo -e "\n${YELLOW}[2/4] TMUX 세션 & 레이아웃 구성...${NC}"

# 팀 설정의 [창이름] 구획마다 tmux 창 하나. 구획이 없으면 창 'team' 하나.
# 창마다 레이아웃: 그 창의 첫 멤버는 좌측 메인, 나머지는 우측 2열 그리드에 행 우선 배치.
#   ┌─────────┬──────────┬──────────┐
#   │         │ 2번째    │ 3번째    │
#   │ 첫 멤버 ├──────────┼──────────┤
#   │ (메인)  │ 4번째    │ 5번째    │
#   │         ├──────────┼──────────┤
#   │         │ 6번째    │ 7번째    │   ← 우측 인원이 홀수면 마지막 행은 1칸
#   └─────────┴──────────┴──────────┘
# 페인은 ID(#{pane_id}) 로 추적하고 @member 태그로 찾으므로 tmux 인덱스·창 번호와 무관하다.
# 같은 창의 멤버는 팀 설정에서 연속이다 (lib/members.sh 가 중복 구획을 거부).

# 창별 우측 행 수 중 최댓값으로 터미널 최소 높이를 정한다.
MAX_ROWS=0
w=0
while [ $w -lt $W_COUNT ]; do
    n=0; i=0
    while [ $i -lt $M_COUNT ]; do [ "${M_WINDOW[$i]}" = "${W_NAME[$w]}" ] && n=$((n + 1)); i=$((i + 1)); done
    rows=$(( n / 2 )); [ $rows -gt $MAX_ROWS ] && MAX_ROWS=$rows
    w=$((w + 1))
done

TERM_WIDTH=$(tput cols 2>/dev/null || echo 340)
TERM_HEIGHT=$(tput lines 2>/dev/null || echo 85)
# 최소 크기 보강 — 행당 최소 14줄 확보
MIN_HEIGHT=$(( MAX_ROWS * 14 )); [ "$MIN_HEIGHT" -lt 85 ] && MIN_HEIGHT=85
[ "${TERM_WIDTH:-0}" -lt 300 ] && TERM_WIDTH=340
[ "${TERM_HEIGHT:-0}" -lt "$MIN_HEIGHT" ] && TERM_HEIGHT=$MIN_HEIGHT

MAIN_WIDTH=180
RIGHT_AREA_WIDTH=$((TERM_WIDTH - MAIN_WIDTH - 1))

# build_window <첫 페인 ID> <첫 멤버 인덱스> <멤버 수> — 창 하나를 분할하고 PANE_IDS 에 멤버 순서대로 추가
build_window() {
    local first="$1" start="$2" count="$3"
    local right=$((count - 1)) rows=$(( count / 2 )) r
    local row_ids=()
    PANE_IDS[$start]="$first"
    [ $rows -gt 0 ] || return 0
    # Phase 1: 좌측 메인 + 우측 영역
    row_ids[0]=$(tmux split-window -h -P -F '#{pane_id}' -t "$first" -l "$RIGHT_AREA_WIDTH")
    # Phase 2: 우측 영역을 rows 행으로 균등 분할 (남은 영역에서 아래쪽을 계속 떼어냄)
    r=1
    while [ $r -lt $rows ]; do
        row_ids[$r]=$(tmux split-window -v -P -F '#{pane_id}' -t "${row_ids[$((r - 1))]}" -p $(( 100 * (rows - r) / (rows - r + 1) )))
        r=$((r + 1))
    done
    # Phase 3: 각 행을 좌·우로 분할 (마지막 행은 남은 멤버가 1명이면 분할하지 않음)
    r=0
    while [ $r -lt $rows ]; do
        PANE_IDS[$((start + 1 + 2 * r))]="${row_ids[$r]}"
        if [ $(( 2 * r + 2 )) -le $right ]; then
            PANE_IDS[$((start + 2 + 2 * r))]=$(tmux split-window -h -P -F '#{pane_id}' -t "${row_ids[$r]}" -p 50)
        fi
        r=$((r + 1))
    done
}

PANE_IDS=()
WINDOW_IDS=()
start=0
w=0
while [ $w -lt $W_COUNT ]; do
    count=0
    while [ $((start + count)) -lt $M_COUNT ] && [ "${M_WINDOW[$((start + count))]}" = "${W_NAME[$w]}" ]; do
        count=$((count + 1))
    done
    if [ $w -eq 0 ]; then
        tmux new-session -d -s "$SESSION" -n "${W_NAME[$w]}" -x "$TERM_WIDTH" -y "$TERM_HEIGHT"
        # team-send 가 이 세션의 멤버 설정을 찾을 수 있도록 세션 옵션에 기록.
        # 원본이 아니라 기동 시점 스냅샷을 가리킨다 — 실행 중 원본의 행 순서를 바꿔도 이름 ↔ @member 대응이 어긋나지 않게.
        mkdir -p "$ROLES_DIR/.merged/$SESSION"
        cp "$MEMBERS_FILE" "$ROLES_DIR/.merged/$SESSION/team.conf"
        tmux set-option -t "$SESSION" @team_members_file "$ROLES_DIR/.merged/$SESSION/team.conf"
        tmux set-option -t "$SESSION" @team_members_source "$MEMBERS_FILE"
        # 첫 페인 — tmux base-index 설정과 무관하게 세션의 활성 페인으로 잡는다.
        first="$(tmux display-message -p -t "$SESSION" '#{pane_id}')"
    else
        first="$(tmux new-window -d -P -F '#{pane_id}' -t "$SESSION:" -n "${W_NAME[$w]}")"
    fi
    WINDOW_IDS[$w]="$(tmux display-message -p -t "$first" '#{window_id}')"

    # 페인 보더·타이틀 옵션(창 옵션)을 분할 전에 활성화해야 페인 생성 시점부터 보더가 그려진다.
    # pane_title 은 Claude Code 가 OSC 2 escape 로 task 설명을 덮어쓰므로 우리 역할명이 사라진다.
    # 회피책: per-pane user option @role 에 역할명을 저장하고 보더 포맷이 @role 을 표시.
    tmux set-option -w -t "${WINDOW_IDS[$w]}" pane-border-status top
    tmux set-option -w -t "${WINDOW_IDS[$w]}" pane-border-format " #{@role} "
    tmux set-option -w -t "${WINDOW_IDS[$w]}" allow-rename off
    tmux set-option -w -t "${WINDOW_IDS[$w]}" automatic-rename off

    build_window "$first" "$start" "$count"
    echo "  ✅ 창 '${W_NAME[$w]}' — ${count}명 (메인 1 + 우측 $(( count / 2 ))행 × 2열)"
    start=$((start + count))
    w=$((w + 1))
done
# 첫 창을 띄운 상태로 attach
tmux select-window -t "${WINDOW_IDS[0]}"

# 페인 태그 — @role: 보더 표시용 라벨 (Claude OSC 2 영향 없음)
#             @member: 팀 설정 행 번호. team-send·team-status 는 tmux 인덱스가 아니라 이 태그로 페인을 찾는다.
#             @engine: claude | codex. team-status 가 엔진별로 컨텍스트·사용 한도를 읽는 데 쓴다.
i=0
while [ $i -lt $M_COUNT ]; do
    tmux set-option -p -t "${PANE_IDS[$i]}" @role "${M_LABEL[$i]}"
    tmux set-option -p -t "${PANE_IDS[$i]}" @member "$i"
    tmux set-option -p -t "${PANE_IDS[$i]}" @engine "${M_ENGINE[$i]}"
    i=$((i + 1))
done

echo "  ✅ 레이아웃 구성 완료 (${M_COUNT} panes, ${W_COUNT}개 창)"

# ── 페인 매핑 자가 검증 ────────────────────────────────────
# team-send 는 @member 태그로 수신 페인을 찾는다. 태그가 어긋나면 메시지가 다른 멤버에게
# 오배달되므로 기동 전에 멤버마다 태그 페인이 정확히 하나이고 라벨이 일치하는지 검증한다.
MAPPING_OK=1
i=0
while [ $i -lt $M_COUNT ]; do
    found="$(tmux list-panes -s -t "$SESSION" -F '#{@member}' | grep -cx "$i")"
    pid="$(member_pane_id "$SESSION" "$i")"
    actual="$(tmux display-message -p -t "${pid:-none}" '#{@role}' 2>/dev/null)"
    if [ "$found" -ne 1 ] || [ "$actual" != "${M_LABEL[$i]}" ]; then
        echo -e "  ${RED}❌ member $i: 태그 페인 ${found}개, 기대 '${M_LABEL[$i]}' ≠ 실제 '$actual'${NC}"
        MAPPING_OK=0
    fi
    i=$((i + 1))
done
if [ "$MAPPING_OK" -eq 1 ]; then
    echo -e "  ${GREEN}✅ 멤버 ↔ 페인 태그 매핑 일치 (team-send 기준)${NC}"
else
    echo -e "  ${RED}⚠️  매핑 불일치 — team-send 가 잘못된 페인으로 송신됩니다. 세션을 종료하고 레이아웃을 수정하세요.${NC}"
    tmux kill-session -t "$SESSION"
    exit 1
fi

# ── [3/4] Claude 자동 실행 ──────────────────────────────────
echo -e "\n${YELLOW}[3/4] 멤버 실행 중 (Claude / Codex)... (페인당 최대 1분)${NC}"

# 멤버별 엔진·모델·effort·역할 파일은 팀 설정(teams/*.conf)이 단일 소스. 역할 파일 존재는 시작 전에 검증했다.
# 기동 함수 실패와 준비 화면 미확인을 모두 실패로 집계해 완료 배너에 반영한다.
NOT_READY=""
i=0
while [ $i -lt $M_COUNT ]; do
    pane_id="${PANE_IDS[$i]}"
    echo -n "  Pane $i (${M_NAME[$i]} · ${M_ENGINE[$i]} ${M_MODEL[$i]} · ${M_EFFORT[$i]}): "
    started=1
    start_member_in_pane "$pane_id" "$i" || started=0

    if [ "$started" -eq 1 ] && tmux capture-pane -t "$pane_id" -p 2>/dev/null | grep -q "$(ready_pattern "${M_ENGINE[$i]}")"; then
        echo -e "${GREEN}✅ 준비 완료${NC}"
    else
        echo -e "${RED}⚠️  준비 미확인 — 수동 확인 필요${NC}"
        NOT_READY="$NOT_READY ${M_NAME[$i]}"
    fi
    i=$((i + 1))
done

# ── [4/4] 완료 ──────────────────────────────────────────────
if [ -z "$NOT_READY" ]; then
    echo -e "\n${GREEN}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   ✅ 팀 환경 구성 완료 (전원 준비)   ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${NC}"
else
    n_bad=$(echo $NOT_READY | wc -w | tr -d ' ')
    echo -e "\n${RED}  ⚠️  부분 준비 — $((M_COUNT - n_bad))/${M_COUNT}명 준비, 미확인:${NOT_READY}${NC}"
    echo -e "${RED}     해당 페인을 확인하세요 (team-status --session '$SESSION' --tail 10). 준비되지 않은 멤버에게는 team-send 가 거절되거나 전달 미확인(exit 5)이 됩니다.${NC}"
fi

# 터미널에서 직접 실행한 경우 자동 attach
[ -t 1 ] && tmux attach -t "$SESSION"
