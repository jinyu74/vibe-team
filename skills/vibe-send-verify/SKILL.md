---
name: vibe-send-verify
description: (vibe-team) team-send 전달 확인 방식(입력창 잔존 검사·Enter 재발사)과 전송 이력 Hook 의 동작·진단·비활성화 가이드. team-send 가 "delivery 미확인"(exit 5)이나 exit 1/3/4 를 냈을 때, 수신자가 메시지를 처리하지 않는 것 같을 때 참조.
---

# team-send 전달 확인 가이드

> 2026-10-04 갱신 — 미확인 시 exit 5, 입력창을 못 찾으면 성공으로 치지 않음, 세션 선택 규칙.
> 2026-10-02 갱신. 2026-07-09 부터 전달 확인은 `team-send` 자체가 수행하고, 이 이름의 PostToolUse Hook 은 **전송 이력 기록만** 한다.
> 이전 방식(Hook 이 수신 페인의 활성 패턴을 판정하고 Enter 를 보강, 실패 시 exit 2)은 폐기되었다.

## 1. 전달 확인은 team-send 가 한다

`team-send <이름> "<메시지>"` 는 다음 순서로 동작한다.

1. 대상 세션을 정한다: `--session` → `TEAM_SESSION`(멤버 페인에 setup-team.sh 가 지정) → 호출 페인의 세션. tmux 밖에서 세션이 여럿이면 `--session` 없이는 거절한다(exit 1).
   세션의 팀 설정(`@team_members_file`)에서 수신자 이름·별칭을 찾고, 페인 태그(`@member`)로 수신 페인을 찾는다.
2. 수신 페인의 실행 중 명령이 셸이면 비활성으로 보고 거절한다(exit 4).
3. 메시지를 bracketed paste 로 한 번에 넣고, 길이에 따라 0.5~2초 기다린 뒤 Enter.
4. **입력창 잔존 검사** (최대 3회, 0.7초 간격) — 화면의 마지막 입력 프롬프트(Claude `❯`, Codex `›`) 아래만 본다.
   - 대기열 표시(Claude `Press up to edit queued`, Codex `Messages to be submitted`)가 있으면 → 전달 성공
   - 입력창에 붙여넣기 표시(Claude `Pasted text`, Codex `Pasted Content`)나 메시지 첫 줄이 남아 있으면 → 미제출로 보고 Enter 재발사
   - 입력창이 비어 있으면 → 전달 성공
   - 입력 프롬프트를 화면에서 찾지 못하면 → 판정 불가(성공으로 치지 않고 Enter 도 보내지 않음)
5. 3회 후에도 잔존하거나 판정 불가이면 `⚠️ <발신> → <수신> (pane N, …B) delivery 미확인 — <이유>` 를 출력하고 **exit 5** 로 끝난다. `✅` 는 출력하지 않는다.
6. 성공 출력: `✅ <발신> → <수신> (pane <멤버번호>, <바이트>B)`, exit 0
7. 수신자가 Codex 이고 5시간 사용 한도가 30% 미만이면 경고를 덧붙인다(전송은 이미 완료).

Esc 등 수신자 작업을 방해하는 키는 보내지 않는다.

## 2. 종료 코드와 대처

| 결과 | 뜻 | 대처 |
|---|---|---|
| exit 0 + `✅` | 전달됨 | — |
| exit 5 + `delivery 미확인` | 입력창에 메시지가 남아 있거나, 입력창을 찾지 못해 확인할 수 없음 | `team-status --tail 15` 로 수신자 화면 확인. 남아 있으면 같은 메시지를 다시 보내지 말고 진행-클로드에게 보고 |
| exit 1 | 사용법 오류, 알 수 없는 수신자, 팀 설정 읽기 실패 | `team-send -h` 로 이름·별칭 확인 |
| exit 3 | 세션 또는 수신자 페인을 찾을 수 없음 | 세션 이름 확인(`tmux ls`), `--session <이름>` 지정 |
| exit 4 | 수신자 CLI 가 종료됨 (비활성) | 사용자에게 `[시스템 장애] <대상> 페인 비활성. 재시작 결정 요청드립니다.` 형식으로만 보고 (공통 §10.5) |

## 3. 전송 이력 Hook

- 등록: `setup-team.sh` 가 `~/.claude/settings.json` 의 PostToolUse(matcher `Bash`)에 `bin/team-send-verify.sh` 를 병합 등록한다(중복 없음, 다른 Hook 보존, 등록 전 백업).
- 동작: `team-send` 성공 출력이 있으면 `/tmp/team-send-verify.log` 에 한 줄 기록하고 항상 exit 0. 판정·보강·차단은 하지 않는다.
- Claude 멤버에게만 적용된다. Codex 멤버의 전송도 `team-send` 자체의 전달 확인은 똑같이 거친다.
- 이력 보기: `tail -20 /tmp/team-send-verify.log`

## 4. 수신자가 메시지를 처리하지 않는 것 같을 때

1. `team-status --tail 5` — 수신자가 `[OK]` 인지, 화면 마지막 줄이 무엇인지 확인.
2. 작업 중 표시(Claude `esc to interrupt` / Codex `Working`)가 있으면 처리 중이다. 끝나면 대기열의 메시지를 이어서 처리한다.
3. 복사 모드(화면 위쪽 `[0/123]` 같은 표시)라면 사용자가 스크롤 중인 것이다 — 기다린다.
4. 입력창에 메시지가 그대로 남아 있으면 진행-클로드에게 보고한다. 다른 페인에 직접 키 입력을 보내지 않는다.

## 5. Hook 비활성화

```bash
jq 'del(.hooks.PostToolUse[]?.hooks[]? | select(.command | endswith("team-send-verify.sh")))' \
    ~/.claude/settings.json > /tmp/settings.json && mv /tmp/settings.json ~/.claude/settings.json
```

다음 `setup-team` 실행 때 다시 등록된다. 전달 확인은 `team-send` 에 있으므로 Hook 을 꺼도 전달 확인은 유지된다.

## 6. 관련 문서

- 공통 워크플로 §10.2 송신, §10.3 송신 후 검증, §10.5 사용자에게 전달 부탁 금지 (`roles/_team-workflow.md`)
- ADR: `docs/decisions/2026-06-09-team-send-verify-hook.md` (갱신 이력의 2026-07-09 설계 전환)
- 구현: `bin/team-send` (전달 확인), `bin/team-send-verify.sh` (이력 로그)
