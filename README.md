# vibe-team

tmux + Claude Code + Codex 로 **SW 개발 단계별 파트**를 구성하고, 파트마다 **Claude·Codex 비판적 페어**를 두어
실제 팀처럼 협업하게 하는 팀 셋업 도구입니다. [claude-ecg-team](../claude-ecg-team) 의 실행 도구(`setup-team`·`team-send`·`team-status`·체크포인트 훅)를 바탕으로
조직을 범용 SW 개발 파이프라인으로 다시 설계했습니다.

- **단계 → 파트 → 페어.** 기획·비즈니스분석·통계 → 시스템설계·디자인·테스트설계 → 코어개발·개발구현·아트·배경·사운드 → 품질·성능·보안 → 빌드·CI·CD·배포. 만들 SW 유형에 따라 필요한 파트만 띄웁니다.
- **모든 파트는 Claude 1 + Codex 1.** 한 모델이 만들고 다른 모델이 반증합니다. 같은 모델은 같은 실수를 같이 놓치기 때문입니다.
- **결과물은 검증을 거쳐 다음 파트로.** 인계 패킷 → 받는 파트의 수령 검증 → 문제가 있으면 상류로 변경 요청(CR) → 영향 전파.
- **개발은 전부 통과할 때까지 루프.** 테스트 코드 → 구현 → `team-gate`(테스트·품질·성능·보안) → 검증 파트 판정 → 실패하면 다시. 테스트를 지우거나 기준을 낮춰 통과시키지 않습니다.

## 빠른 시작

```bash
# 1. 발견 팀 띄우기 (-c 생략 = 발견 팀): 아이디어 → 컨셉 → SW 유형 → 팀 구성
setup-team discovery -d ~/MyProject/discovery
tmux attach -t discovery          # 왼쪽 큰 페인(진행-클로드)에게 주제를 준다

# 2. 유형이 정해지면 프로젝트 팀 띄우기
setup-team shop -d ~/MyProject/shop -c web-service      # 웹 서비스
setup-team mygame -d ~/MyProject/mygame -c game         # 게임

# 띄우기 전에 구성만 확인 (tmux·훅을 건드리지 않음)
setup-team shop -d ~/MyProject/shop -c web-service -n
```

tmux 조작은 **[tmux 사용 가이드](docs/guides/tmux-guide.md)** 를 참고하세요.

## 설치

의존성은 claude-ecg-team 과 같습니다: `tmux`, `claude` CLI, `codex` CLI(로그인), `jq`, `lsof`, `python3`(security-guidance), `npx`(playwright MCP), `rsync`(선택).

```zsh
# ~/.zshrc
export VIBE_TEAM_HOME="$HOME/MyProject/vibe-team"
export PATH="$VIBE_TEAM_HOME/bin:$PATH"
setup-team() { bash "$VIBE_TEAM_HOME/setup-team.sh" "$@"; }
```

> claude-ecg-team 과 함께 쓰면 `setup-team`·`team-send` 이름이 겹칩니다. 둘 다 쓰려면 함수 이름을 나누세요
> (예: `vibe-team() { bash "$VIBE_TEAM_HOME/setup-team.sh" "$@"; }`). 멤버 페인 안에서는 각 저장소의 `bin/` 이 PATH 앞에 들어가므로 섞이지 않습니다.
> 심볼릭 링크는 쓰지 마세요 — `setup-team.sh` 는 자기 위치로 `roles/`·`teams/`·`bin/` 을 찾습니다.

```bash
setup-team [세션이름] [-d <작업디렉터리>] [-c <팀 이름|설정 파일>] [-n]
```

## 조직

### 단계와 파트

| 단계 | 파트 | 핵심 질문 | 대표 산출물 |
|---|---|---|---|
| 운영 | 진행 | 누가 무엇을 해야 하고, 무엇이 막혀 있나 | 파이프라인 보드, 결정 요청서 |
| S1 발견 | 기획 | 누구의 어떤 문제를 어떤 경험으로 푸는가 | PRD, 사용자 스토리·인수 조건 |
| | 비즈니스분석 | 가치·수익·규정 측면에서 성립하는가 | 비즈니스 케이스, 비기능 요구, 추적 매트릭스 |
| | 통계 | 성공을 무엇으로 재고 믿을 수 있는가 | 지표 체계, 실험 설계, 이벤트 명세 |
| S2 설계 | 시스템설계 | 가장 단순하게 요구를 만족하는 구조는 | ADR, 아키텍처, 계약, 구현 가이드 |
| | 디자인 | 설명 없이 목표에 도달하는가 | 화면·상태, 디자인 토큰·컴포넌트, 접근성 |
| | 테스트설계 | 완성을 무엇으로 증명하는가 | 테스트 전략, 인수 테스트 코드, `.vibe/gates.conf` |
| S3 제작 | 코어개발 | 제품의 심장이 정확하고 단단한가 | 도메인·엔진·공용 모듈 + 단위 테스트 |
| | 개발구현 | 기능이 테스트로 증명되게 동작하는가 | 기능 코드·테스트·PR (그린 루프 주인) |
| | 아트 · 배경 · 사운드 | 시각·공간·소리가 경험을 받쳐 주는가 | 스타일 가이드, 에셋·명세, 큐 시트, 라이선스 기록 |
| S4 검증 | 품질 · 성능 · 보안 | 정확·회귀 없음 / 예산 이내 / 공격에 견딤 | 판정, 성능 예산·베이스라인, 위협 모델 |
| S5 전달 | 빌드 · CI · CD · 배포 | 재현 가능 / 자동 게이트 / 안전한 승격 / 되돌릴 수 있는 출시 | 빌드 스크립트, CI·배포 파이프라인, 릴리스 계획·런북 |

파트별 요구 역량·책임·입력·산출물·완료 기준·비판 체크리스트는 `roles/<파트>.md` 에 있습니다.

### SW 유형별 팀 (`teams/`)

| 팀 | 설정 | 인원 (Claude : Codex) | 구성 |
|---|---|---|---|
| 발견 팀 | `discovery` (기본) | 10 (5 : 5) | 진행·기획·비즈니스분석·통계·시스템설계(규모 추정) |
| 웹 서비스 | `web-service` | 28 (14 : 14) | 아트·배경·사운드 제외, 빌드+CI·CD+배포 겹침 |
| 모바일 앱 | `mobile-app` | 28 (14 : 14) | 웹과 같은 파트, 모바일 클라이언트·스토어 책임 |
| 게임 | `game` | 32 (16 : 16) | 아트·배경·사운드 포함, 비즈니스분석+통계 겹침 |
| 백엔드 API | `backend-api` | 24 (12 : 12) | 디자인·아트 제외, 기획+비즈니스분석 겹침 |
| 도구·라이브러리 | `tool-lib` | 16 (8 : 8) | 8개 페어로 압축 (겹침 4개) |
| 전체 카탈로그 | `full` | 38 (19 : 19) | 19개 파트 전부 |

형식·겹침·배정 원칙·멤버별 플러그인은 [`teams/README.md`](teams/README.md).

### 페어 — 비판적 사고를 구조로

| | 만드는 파트 (기획·설계·제작·전달) | 검증 파트 (품질·성능·보안) |
|---|---|---|
| 주도 | **Claude** 가 작성·구현 | **Codex** 가 판정 (Claude 가 만든 코드를 다른 모델이) |
| 반증 | **Codex** 가 반례·대안·비용으로 비판 | **Claude** 가 판정의 오탐·누락·과잉을 검증 |

- **산출물 모드**: 작성 → 반증 리뷰 → 항목별 반영/미반영 사유 → **페어 서명**. 서명 없는 산출물은 넘기지 않습니다.
- **쟁점 모드**: 선택지가 갈리면 독립 초안(상대 안을 읽지 않음) → 상호 비판 ≤2라운드 → 합의면 파트 결정, 이견이면 결정 요청서.
- 공통 비판 체크리스트: 전제 · 요구 추적 · 반례 · 대안 · 비용과 되돌리기 · 검증 가능성 · 다른 파트 영향 (공통 §3.4).

### 결정 권한

| 단위 | 결정자 |
|---|---|
| 파트 안 판단 | 그 파트 페어의 합의 |
| 파트 사이 판단 | 관련 파트 합동 리뷰의 합의 |
| 컨셉·범위·우선순위·SW 유형·팀 구성·유료 도구·운영 배포·남은 이견 | **사용자** (진행 파트가 결정 요청서로 상정) |

### 흐름

```
발견 팀 ── 컨셉·SW 유형 결정(사용자) ── 팀 구성 결정(사용자) ──▶ 프로젝트 팀

S1 기획·비즈니스분석·통계 ─인계▶ S2 시스템설계·디자인·테스트설계 ─인계▶ S3 제작 ─PR▶ S4 검증 ─통과▶ S5 전달 ─▶ 출시(사용자 승인)
        ▲                               ▲                                   │
        └──────────── 변경 요청(CR) ────┴──────── 반려·CR ──────────────────┘

그린 루프 (S3 ↔ S4):  RED 테스트 → GREEN 구현 → team-gate 전부 통과 → 품질·성능·보안 페어 판정 → 실패 시 반복
                       같은 게이트 3회 연속 실패 → 원인 분석·상류 CR / 5회차 미통과 → 합동 리뷰
```

## 그린 루프 게이트 — `team-gate`

프로젝트마다 `.vibe/gates.conf` 에 게이트를 정의하고(테스트설계 파트), 누구나 같은 명령으로 객관 판정을 얻습니다.

```bash
# <프로젝트>/.vibe/gates.conf — 이름 | 담당 파트 | 명령
unit     | 테스트설계 | npm test -- --coverage
lint     | 품질       | npm run lint && npm run typecheck
perf     | 성능       | node scripts/perf-budget.js
security | 보안       | npm audit --audit-level=high
```

```bash
team-gate --label T-12        # 전부 실행 → 0 = 전부 통과, 1 = 실패 있음, 2 = 설정 오류
team-gate --only unit,lint    # 일부만
team-gate --list              # 목록
```

- 기록: `.vibe/runs/<시각>/<게이트>.log`·`summary.md`, 최신 `.vibe/runs/latest.md`, 회차 이력 `.vibe/runs/history/<작업ID>.tsv`
- `--label` 이력으로 **같은 게이트 3회 연속 실패**와 **5회차 미통과**를 알려 주며, 이것이 루프 탈출·에스컬레이션 기준입니다(공통 §6.4).
- 템플릿: `templates/gates.conf`. `.vibe/runs/` 는 프로젝트 `.gitignore` 에 넣습니다.

## 멤버와 소통

```bash
team-send 보안-코덱스 "[리뷰] PR #12 · .vibe/runs/latest.md"      # 이름 또는 별칭(sec-x)
for who in 품질-코덱스 품질-클로드; do team-send "$who" -f review-request.md; done   # 파트 = 양쪽 모두에게
team-send -h                                                      # 이름·별칭 목록
team-status                     # 상태·창·컨텍스트 + Codex 한도
team-status --limits            # Codex 5시간·주간 한도만
```

## 동작 방식

claude-ecg-team 과 같습니다 — 멤버마다 **정체 블록 + 공통 워크플로(`roles/_team-workflow.md`) + 담당 파트 역할 파일**을 합쳐
`roles/.merged/<세션>/<이름>.md` 로 만들어 주입하고(Claude `--append-system-prompt-file`, Codex `developer_instructions`),
페인 태그(`@member`·`@role`·`@engine`)로 `team-send`·`team-status` 가 페인을 찾습니다. 체크포인트 자동 저장 훅, 멤버별 플러그인, `@worktree` 격리도 같습니다.

달라진 점:

| | claude-ecg-team | vibe-team |
|---|---|---|
| 조직 | 학습·내러티브 게임 중심, 인물 페르소나 | 범용 SW 파이프라인 19개 파트, `<파트>-클로드/코덱스` 이름 |
| 페어 | 기획 파트만 결정 페어, 개발은 Claude 작성·Codex 2명 게이트 | **모든 파트**가 Claude·Codex 페어 |
| 결정 | 모든 결정은 사용자 | 파트 안은 페어 합의, 파트 사이는 합동 리뷰, 사용자 결정 사항은 정의된 목록 |
| 역할 겹침 | — | 역할파일 열 `A+B` (작은 팀에서 한 페어가 여러 파트) |
| 루프 | PR 게이트 | `team-gate` 객관 판정 + 반복 실패 감지 |
| 기타 | | `setup-team -n` 드라이런, 기본 팀 `discovery` |

## 디렉터리 구조

```
.
├── setup-team.sh            # 팀 세션 구성 (메인, -n 드라이런)
├── bin/
│   ├── team-send            # 멤버 간 메시지 전송
│   ├── team-status          # 멤버 상태·컨텍스트·Codex 한도
│   ├── team-gate            # 그린 루프 게이트 실행기
│   ├── team-checkpoint      # 체크포인트 자동 저장 훅
│   └── team-send-verify.sh  # Claude PostToolUse Hook (전송 이력)
├── lib/                     # members.sh (팀 설정 로더) · codex.sh (한도 조회)
├── teams/                   # SW 유형별 팀 설정 + README
├── roles/                   # _team-workflow.md + 19개 파트 역할 파일
├── templates/               # 인계 패킷·CR·리뷰·결정 요청서·루프 분석·테스트 전략·게이트·보드
├── skills/vibe-send-verify/ # ~/.claude/skills/ 로 배포되는 Hook 가이드
├── tests/                   # team-tools.sh · team-gate.sh 회귀 테스트
└── docs/                    # 가이드·이 저장소의 결정 기록
```

## 테스트

```bash
bash tests/team-tools.sh     # team-send·team-status·설정 로더 (격리 tmux 서버)
bash tests/team-gate.sh      # team-gate 설정·판정·루프 이력
for c in teams/*.conf; do bash setup-team.sh check -c "$c" -n -d /tmp/vibe-check >/dev/null && echo "OK $c"; done
```

## team-send-verify Hook

`setup-team.sh` 실행 시 `~/.claude/settings.json` 에 PostToolUse Hook(`bin/team-send-verify.sh`, 전송 이력 로그 `/tmp/team-send-verify.log`)을 병합 등록하고
`skills/vibe-send-verify/` 를 `~/.claude/skills/` 에 배포합니다. 다른 저장소(claude-ecg-team)가 등록한 같은 Hook 은 이 저장소 것으로 바꿔 이력이 두 번 쌓이지 않게 합니다.
