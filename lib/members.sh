# members.sh — 팀 설정(teams/*.conf) 로더 (setup-team.sh · bin/team-send 가 source)
# bash 3.2 호환 (macOS 기본 bash): 연관 배열·mapfile 미사용.
#
# load_members <file>
#   성공 시 아래 배열을 채운다 (인덱스 = tmux 페인 인덱스).
#   M_NAME M_ROLE M_LABEL M_ENGINE M_MODEL M_EFFORT M_ALIASES M_PLUGINS M_WINDOW, M_COUNT
#   W_NAME (창 이름, 등장 순서), W_COUNT
#   M_DUTY (멤버별 프로젝트 책임, @duty — 여러 줄은 줄바꿈으로 연결)
#   M_WORKTREE (1 = 전용 git worktree 에서 기동, @worktree)
#   SUB_ABSENT SUB_TO SUB_NOTE, SUB_COUNT (팀에 없는 멤버의 대체 담당, @substitute)
#
# '[창이름]' 줄은 이후 멤버를 그 tmux 창에 배치한다. 첫 구획 이전 멤버는 창 'team'.
# '@project <설명>' 줄은 팀의 프로젝트 종류(TEAM_PROJECT). 멤버 정체 블록에 표시되어
# 역할 파일의 프로젝트 유형별 항목(예: 학습 게임 전용)을 적용할지 판단하는 기준이 된다.
# '@worktree <이름...>' 줄은 그 멤버들을 작업 폴더 저장소의 전용 worktree 에서 기동한다 (브랜치·인덱스 분리).
# '@substitute <팀에 없는 이름> <대체 담당> [범위]' 줄은 역할 파일이 부르는 부재 멤버를 이 팀에서 누가 맡는지 정한다.
# '@duty <이름> <책임>' 줄은 이 프로젝트에서 그 멤버의 책임을 정체 블록에 넣는다 (역할 파일보다 우선).
#   실패 시 stderr 에 사유를 출력하고 1 반환.

_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

load_members() {
    local file="$1" line lineno=0 name role label engine model effort aliases plugins extra i window="team" w a
    M_NAME=(); M_ROLE=(); M_LABEL=(); M_ENGINE=(); M_MODEL=(); M_EFFORT=(); M_ALIASES=(); M_PLUGINS=(); M_WINDOW=(); M_COUNT=0
    W_NAME=(); W_COUNT=0; TEAM_PROJECT=""
    M_DUTY=(); M_WORKTREE=(); SUB_ABSENT=(); SUB_TO=(); SUB_NOTE=(); SUB_COUNT=0
    local wt_names="" duty_raw=() rest who

    [ -f "$file" ] || { echo "멤버 설정 파일 없음: $file" >&2; return 1; }

    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line="$(_trim "$line")"
        case "$line" in ''|'#'*) continue ;; esac

        # 프로젝트 종류: @project <설명>
        case "$line" in
            '@project '*) TEAM_PROJECT="$(_trim "${line#@project }")"; continue ;;
            '@worktree '*) wt_names="$wt_names ${line#@worktree }"; continue ;;
            '@substitute '*)
                rest="$(_trim "${line#@substitute }")"
                SUB_ABSENT[$SUB_COUNT]="${rest%% *}"; rest="$(_trim "${rest#"${SUB_ABSENT[$SUB_COUNT]}"}")"
                SUB_TO[$SUB_COUNT]="${rest%% *}"; SUB_NOTE[$SUB_COUNT]="$(_trim "${rest#"${SUB_TO[$SUB_COUNT]}"}")"
                [ -n "${SUB_TO[$SUB_COUNT]}" ] || { echo "$file:$lineno: @substitute <팀에 없는 이름> <대체 담당> [범위]" >&2; return 1; }
                SUB_COUNT=$((SUB_COUNT + 1)); continue ;;
            '@duty '*)
                rest="$(_trim "${line#@duty }")"
                [ "${rest#* }" != "$rest" ] || { echo "$file:$lineno: @duty <이름> <책임>" >&2; return 1; }
                duty_raw[${#duty_raw[@]}]="$lineno|$rest"; continue ;;
            '@'*) echo "$file:$lineno: 알 수 없는 지시어 '${line%% *}' (@project @worktree @substitute @duty)" >&2; return 1 ;;
        esac

        # 창 구획: [창이름]
        case "$line" in
            '['*']')
                window="$(_trim "${line#[}")"; window="$(_trim "${window%]}")"
                [ -n "$window" ] || { echo "$file:$lineno: 빈 창 이름" >&2; return 1; }
                w=0
                while [ $w -lt $W_COUNT ]; do
                    [ "${W_NAME[$w]}" = "$window" ] && { echo "$file:$lineno: 중복 창 '$window'" >&2; return 1; }
                    w=$((w + 1))
                done
                continue ;;
        esac

        IFS='|' read -r name role label engine model effort aliases plugins extra <<EOF
$line
EOF
        name="$(_trim "$name")"; role="$(_trim "$role")"; label="$(_trim "$label")"; engine="$(_trim "$engine")"
        model="$(_trim "$model")"; effort="$(_trim "$effort")"; aliases="$(_trim "$aliases")"; plugins="$(_trim "$plugins")"

        if [ -n "$extra" ] || [ -z "$name" ] || [ -z "$label" ] || [ -z "$engine" ] || [ -z "$model" ] || [ -z "$effort" ]; then
            echo "$file:$lineno: 형식 오류 — '이름 | 역할파일 | 페인 라벨 | 엔진 | 모델 | effort | 별칭 | 플러그인(선택)'" >&2
            return 1
        fi
        case "$engine" in
            claude|codex) ;;
            *) echo "$file:$lineno: 잘못된 엔진 '$engine' (claude/codex)" >&2; return 1 ;;
        esac
        # 두 엔진 모두 low~max 를 받는다 (Codex 는 minimal 도 있으나 gpt-6.1-sol 이 거부).
        case "$effort" in
            low|medium|high|xhigh|max) ;;
            *) echo "$file:$lineno: 잘못된 effort '$effort' (low/medium/high/xhigh/max)" >&2; return 1 ;;
        esac
        i=0
        while [ $i -lt $M_COUNT ]; do
            [ "${M_NAME[$i]}" = "$name" ] && { echo "$file:$lineno: 중복 이름 '$name'" >&2; return 1; }
            [ "${M_LABEL[$i]}" = "$label" ] && { echo "$file:$lineno: 중복 페인 라벨 '$label'" >&2; return 1; }
            i=$((i + 1))
        done

        M_NAME[$M_COUNT]="$name"; M_ROLE[$M_COUNT]="${role:-$name}"; M_LABEL[$M_COUNT]="$label"; M_ENGINE[$M_COUNT]="$engine"; M_WINDOW[$M_COUNT]="$window"
        M_MODEL[$M_COUNT]="$model"; M_EFFORT[$M_COUNT]="$effort"; M_ALIASES[$M_COUNT]="$aliases"; M_PLUGINS[$M_COUNT]="$plugins"
        M_DUTY[$M_COUNT]=""; M_WORKTREE[$M_COUNT]=0
        M_COUNT=$((M_COUNT + 1))
        # 멤버가 있는 창만 등록 (등장 순서 유지)
        if [ $W_COUNT -eq 0 ] || [ "${W_NAME[$((W_COUNT - 1))]}" != "$window" ]; then
            W_NAME[$W_COUNT]="$window"; W_COUNT=$((W_COUNT + 1))
        fi
    done < "$file"

    [ "$M_COUNT" -gt 0 ] || { echo "$file: 멤버가 없습니다" >&2; return 1; }

    # 지시어의 멤버 이름 검증 — 멤버 행보다 앞에 적어도 되므로 다 읽은 뒤 해석한다.
    for who in $wt_names; do
        i="$(_name_index "$who")"
        [ -n "$i" ] || { echo "$file: @worktree 의 '$who' 는 팀 멤버가 아닙니다" >&2; return 1; }
        M_WORKTREE[$i]=1
    done
    for rest in ${duty_raw[@]+"${duty_raw[@]}"}; do
        lineno="${rest%%|*}"; rest="${rest#*|}"; who="${rest%% *}"
        i="$(_name_index "$who")"
        [ -n "$i" ] || { echo "$file:$lineno: @duty 의 '$who' 는 팀 멤버가 아닙니다" >&2; return 1; }
        M_DUTY[$i]="${M_DUTY[$i]:+${M_DUTY[$i]}
}$(_trim "${rest#"$who"}")"
    done
    i=0
    while [ $i -lt $SUB_COUNT ]; do
        [ -z "$(_name_index "${SUB_ABSENT[$i]}")" ] || { echo "$file: @substitute 의 '${SUB_ABSENT[$i]}' 는 이 팀 멤버입니다 (부재 멤버만 적는다)" >&2; return 1; }
        [ -n "$(_name_index "${SUB_TO[$i]}")" ] || { echo "$file: @substitute 대체 담당 '${SUB_TO[$i]}' 는 팀 멤버가 아닙니다" >&2; return 1; }
        i=$((i + 1))
    done

    # 별칭 충돌 — 다른 멤버의 이름·별칭과 겹치면 member_index 가 앞 멤버를 골라 오배달된다.
    local j k
    i=0
    while [ $i -lt $M_COUNT ]; do
        for a in ${M_ALIASES[$i]}; do
            j=0
            while [ $j -lt $M_COUNT ]; do
                if [ $j -ne $i ]; then
                    [ "$a" = "${M_NAME[$j]}" ] && { echo "$file: 별칭 '$a'(${M_NAME[$i]}) 이 멤버 이름 '${M_NAME[$j]}' 과 겹칩니다" >&2; return 1; }
                    for k in ${M_ALIASES[$j]}; do
                        [ "$a" = "$k" ] && { echo "$file: 별칭 '$a' 이 ${M_NAME[$i]}·${M_NAME[$j]} 에 중복됩니다" >&2; return 1; }
                    done
                fi
                j=$((j + 1))
            done
        done
        i=$((i + 1))
    done
}

# _name_index <이름> — 대표 이름이 정확히 일치하는 멤버 인덱스 (지시어 검증용)
_name_index() {
    local i=0
    while [ $i -lt $M_COUNT ]; do
        [ "$1" = "${M_NAME[$i]}" ] && { echo $i; return 0; }
        i=$((i + 1))
    done
    return 0
}

# member_index <이름|별칭|역할파일> — 페인 인덱스 출력, 없으면 빈 문자열
# 이름·별칭이 우선. 역할파일 이름은 그 역할을 쓰는 멤버가 한 명일 때만 받는다 (페어 역할은 모호하므로 거절).
member_index() {
    local key="$1" i=0 a hit="" n=0
    while [ $i -lt $M_COUNT ]; do
        [ "$key" = "${M_NAME[$i]}" ] && { echo $i; return; }
        for a in ${M_ALIASES[$i]}; do
            [ "$key" = "$a" ] && { echo $i; return; }
        done
        [ "$key" = "${M_ROLE[$i]}" ] && { hit=$i; n=$((n + 1)); }
        i=$((i + 1))
    done
    if [ "$n" -eq 1 ]; then echo "$hit"; fi   # 불일치에도 0 반환 — 호출부 set -e 에서 조용히 끝나지 않게
}

# member_pane_id <session> <멤버 인덱스> — 해당 멤버 페인의 pane_id(%N) 출력
# tmux base-index·pane-base-index·창 분리와 무관하도록 인덱스가 아닌 페인 태그(@member)로 찾는다.
member_pane_id() {
    tmux list-panes -s -t "$1" -F '#{@member} #{pane_id}' 2>/dev/null \
        | awk -v i="$2" 'NF == 2 && $1 == i { print $2; exit }'
}
