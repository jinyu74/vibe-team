# 팀 설정 (`teams/*.conf`)

SW 유형별 팀 구성의 단일 소스입니다. `setup-team.sh` 는 이 파일로 tmux 창·페인 배치, 라벨, 엔진·모델·effort, 역할 주입을 만들고,
`team-send` 는 같은 파일로 수신자 이름·별칭을 찾습니다. 파트·페어 규칙은 `roles/_team-workflow.md` §1~§3 에 있습니다.

| 파일 | 팀 | 인원 (Claude : Codex) | 창 | 용도 |
|---|---|---|---|---|
| `discovery.conf` | 발견 팀 (**기본값**) | 10 (5 : 5) | 발견 | 아이디어 발산·검증 → 컨셉·SW 유형·프로젝트 팀 결정 (공통 §12) |
| `web-service.conf` | 웹 서비스 팀 | 28 (14 : 14) | 기획·설계·개발·검증·전달 | 브라우저 프런트 + 백엔드 |
| `mobile-app.conf` | 모바일 앱 팀 | 28 (14 : 14) | 기획·설계·개발·검증·전달 | iOS·Android + 백엔드, 스토어 출시 |
| `game.conf` | 게임 팀 | 32 (16 : 16) | 기획·설계·개발·아트·검증·전달 | 코어 루프·엔진·아트·배경·사운드 |
| `backend-api.conf` | 백엔드 API 팀 | 24 (12 : 12) | 기획·설계·개발·검증·전달 | 개발자 대상 API 서비스 |
| `tool-lib.conf` | 도구·라이브러리 팀 | 16 (8 : 8) | 팀 | CLI·라이브러리·SDK |
| `full.conf` | 전체 파트 카탈로그 | 38 (19 : 19) | 기획·설계·개발·아트·검증·전달 | 19개 파트 전부 — 대형 제품 또는 비교용 |

```bash
setup-team discovery -d ~/MyProject/discovery              # -c 생략 → teams/discovery.conf
setup-team shop -d ~/MyProject/shop -c web-service          # 이름만 쓰면 teams/<이름>.conf
setup-team x -d ~/MyProject/x -c ./my-team.conf             # 경로도 가능
setup-team shop -d ~/MyProject/shop -c web-service -n       # 드라이런 — tmux 없이 구성 검증·주입 지시만 생성
```

## 파트 겹침

| 프로필 | 겹친 파트 (한 페어가 맡음) |
|---|---|
| web-service · mobile-app | `빌드+CI`, `CD+배포` |
| game | `비즈니스분석+통계`, `빌드+CI`, `CD+배포` |
| backend-api | `기획+비즈니스분석`, `빌드+CI`, `CD+배포` |
| tool-lib | `기획+비즈니스분석`, `코어개발+개발구현`, `품질+보안`, `빌드+CI+CD+배포` |

- 역할파일 열에 `A+B` 로 쓰면 그 멤버에게 두 역할 파일이 모두 주입된다. 책임은 줄지 않는다.
- 멤버 이름은 첫 파트(`빌드-클로드`), 나머지 파트 이름은 별칭(`CI-클로드`)이다 — 역할 파일이 `CI-클로드` 를 불러도 그대로 전달된다.
- 팀에 아예 없는 파트는 `@substitute` 로 가장 가까운 파트가 맡는다(예: 웹 서비스의 아트·배경·사운드 → 디자인).

## 형식

```
@project <설명>                                    # 프로젝트 종류(SW 유형) — 멤버 정체 블록에 표시
@worktree <이름...>                                # 전용 git worktree 에서 기동할 멤버 (공통 §9.3)
@substitute <팀에 없는 이름> <대체 담당> [범위]    # 역할 파일이 부르는 부재 멤버를 이 팀에서 맡는 사람 (공통 §10.1)
@duty <이름> <책임>                                # 이 프로젝트에서의 책임 — 정체 블록에 주입, 역할 파일보다 우선 (여러 줄 가능)
[창이름]                                           # 이후 멤버를 이 tmux 창에 배치
이름 | 역할파일[+역할파일…] | 페인 라벨 | 엔진 | 모델 | effort | 별칭(공백 구분) | 플러그인(공백 구분, 선택)
```

| 열 | 내용 |
|---|---|
| 이름 | `<파트>-클로드` / `<파트>-코덱스` 규칙. `team-send` 수신자·메시지 헤더 |
| 역할파일 | `roles/<파트>.md` (확장자 제외), 겹침은 `+`. 없으면 `setup-team` 이 세션을 만들기 전에 실패한다. 페어는 같은 값을 쓴다 |
| 페인 라벨 | tmux 페인 보더와 `team-status` 역할 칸 |
| 엔진 | `claude` \| `codex` |
| 모델 | claude: `claude-opus-5-5` · `claude-sonnet-5-5[1m]` … / codex: `gpt-6.1-sol` … |
| effort | `low` · `medium` · `high` · `xhigh` · `max` |
| 별칭 | 영문 단축(`sec-x`) + 겹친 파트 이름 |
| 플러그인 | 이 멤버에게만 부여할 플러그인 (선택). 엔진에 맞는 이름을 쓴다 |

- **행 순서 = 멤버 번호** (페인 태그 `@member`). 창마다 첫 멤버가 좌측 메인 페인이다. 만드는 파트는 Claude 를, 검증 파트(품질·성능·보안)는 판정을 주도하는 Codex 를 먼저 둔다.
- 별칭은 다른 멤버의 이름·별칭과 겹칠 수 없다. 지시어의 이름은 대표 이름(1열)으로 쓴다.
- 형식 오류·중복 이름/라벨·잘못된 엔진·effort·알 수 없는 `@` 지시어는 tmux 세션을 만들기 전에 중단된다.
- 실행 중인 세션은 기동 시점 스냅샷(`roles/.merged/<세션>/team.conf`)을 쓴다.

## 배정 원칙

- **모든 파트 = Claude 1 + Codex 1 페어** (공통 §3). 만드는 파트는 Claude 주도·Codex 반증, 검증 파트는 Codex 판정·Claude 판정 검증.
- **Claude Opus 5.5** — 진행·기획·설계·구현·검증 판정 검증 / **Claude Sonnet 5.5 (1M)** — 배경·사운드처럼 조사·반복이 많은 제작
- **Codex gpt-6.1-sol** — 모든 파트의 반증·검증 주도. 웹 검색 켜짐, 기동 시 업데이트 확인 꺼짐
- effort: 설계·구현·테스트설계 Claude `xhigh`, 검증 파트·테스트설계·설계·구현 Codex `high`, 그 밖 Claude `high`·Codex `medium`
- **Codex 멤버는 계정 사용 한도를 공유한다.** 프로젝트 팀은 Codex 가 12~19명이므로 단계별로 필요한 창만 바쁘게 하고 `team-status --limits` 로 확인한다(공통 §8.2). 부족하면 effort 하향·대기·Claude 단독 진행(교차 검증 누락 명시) 중 사용자가 고른다.

## 플러그인

멤버별로 부여한다. 사용자 전역 설정에는 켜지 않는다(방식은 claude-ecg-team 과 같음 — Claude `--plugin-dir`, Codex 미부여 스킬 경로 비활성화).

| 플러그인 | 엔진 | 부여 |
|---|---|---|
| `feature-dev` | Claude | 시스템설계·코어개발·개발구현 |
| `code-simplifier` | Claude | 코어개발·개발구현·품질 |
| `security-guidance` | Claude | 코어개발·개발구현·보안 |
| `frontend-design` | Claude | 디자인·개발구현·아트 |
| `playground` | Claude | 기획·디자인·아트·배경 |
| `playwright` | Claude | 테스트설계·개발구현 |
| `context7` | Claude | 시스템설계·코어개발·개발구현·빌드 |
| `product-design` | Codex | 기획·비즈니스분석·디자인 |
| `build-web-apps` | Codex | 테스트설계·개발구현·품질·성능 |
| `codex-security` | Codex | 보안 |
| `game-studio` | Codex | (게임 팀) 기획·아트·배경·성능 |

- 없는 플러그인 이름은 `setup-team` 이 기동 전에 경고하고 건너뛴다. 새 Codex 플러그인은 먼저 설치하고 `~/.codex/config.toml` 에서 전역으로 끈다.

## 새 팀 만들기

발견 팀에서 컨셉·SW 유형이 결정되면 진행·시스템설계 페어가 가장 가까운 프로필을 출발점으로 `teams/<프로젝트>.conf` 초안을 제안하고 사용자가 결정한다(공통 §12).
직접 만들 때는 가장 가까운 파일을 복사해 파트를 빼거나(`@substitute` 추가) 겹친다(`A+B`). `-n` 드라이런으로 먼저 검증한다.
