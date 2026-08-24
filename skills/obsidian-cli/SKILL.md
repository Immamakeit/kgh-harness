---
name: obsidian-cli
description: Use when saving harness output documents (설계/구현계획/구현후보고) to the Obsidian vault after user judgment passes, or when the workflow's storage stage runs. 산출 문서 저장, vault 기록, 판정 통과 후 마무리 시. Obsidian vault에 문서를 쓰는 모든 하네스 작업에 사용한다.
---

# Obsidian-CLI (산출물 저장)

## 핵심 원칙

저장 위치와 절차는 **계약**이다 — 창작하지 않는다. 경로의 빈칸을 채울 수 없으면
임의 결정하지 말고 되묻는다. 폴백은 허용되지만 **silent 폴백은 금지**다.

## 경로 계약 (창작 금지)

```
<vault_root>/wiki/<카테고리>/<프로젝트>/_work/<작업명>/<YYYY-MM-DD>/설계.md
<vault_root>/wiki/<카테고리>/<프로젝트>/_work/<작업명>/<YYYY-MM-DD>/구현계획.md
<vault_root>/wiki/<카테고리>/<프로젝트>/_work/<작업명>/<YYYY-MM-DD>/구현후보고.md
```

- 파일명은 **고정 3종** — 날짜·작업명을 파일명에 넣지 않는다 (폴더가 그 역할).
- `vault_root` · `path_template`은 `harness.config.yaml`의 `storage` 블록에서 읽는다.
  컨피그가 없으면 사용자에게 vault 경로를 확인받는다.
- **우선순위: 컨피그가 이긴다.** `storage.path_template`이 지정돼 있으면 위 기본 구조
  대신 **그 템플릿을 그대로** 쓴다(컨피그 = 단일 진실원). 위 경로 계약은 컨피그에
  path_template이 없을 때의 기본값이다.
- **`<카테고리>`를 모르면 되묻는다.** 기존 `wiki/` 하위 폴더 목록을 보여주고 고르게 한다.
  임의 창작 금지.
- `harness/` 폴더는 정의(템플릿·규칙) 전용이다 — **산출 문서를 거기 두지 않는다.**

## 문서 규칙

- 템플릿: `<vault_root>/harness/templates/`의 설계·구현계획·구현후보고 3종을 사용한다.
- frontmatter의 `project` · `task` · `date` 채움. `status`는 **소유 스킬이 정의한
  수명주기의 최종 상태**로 갱신한다 (값을 창작하지 않는다 — 정의처는 각 소유 스킬):

  | 문서 | 소유 스킬 | 최종 상태 |
  |---|---|---|
  | 설계 | design-doc | `승인` |
  | 구현계획 | plan-doc | `확정` (저장 시 변경 없음 — 이미 완결 상태로 들어옴) |
  | 구현후보고 | report-doc | `판정통과` |

- summary 블록에 **10자 이내 요약** 필수.

## CLI 위치 찾기 (환경별 — 실측 규격)

`obsidian`이 PATH에 없다고 CLI 미가용으로 단정하지 않는다. 순서대로 탐색한다:

1. `command -v obsidian` — 있으면 그대로 사용
2. **WSL/Windows**: `Obsidian.com` 리다이렉터 전체 경로 호출 (PATH 등록과 무관하게 동작)
   ```bash
   ls /mnt/c/Users/*/AppData/Local/Programs/obsidian/Obsidian.com
   OBS="/mnt/c/Users/<user>/AppData/Local/Programs/obsidian/Obsidian.com"
   ```
3. 둘 다 없으면 CLI 미설치 (installer 1.12.7+ 필요)

## 저장 절차 (순서 고정)

1. **vault_root 확인** — 미지정이면 저장을 건너뛰되 **작업을 막지 않는다**:
   문서를 작업 공간에 보관하고 보고에 남긴다:
   `⚠️ HRN-W010 — storage.vault_root 미지정. 문서는 <경로>에 보관. 컨피그 지정 시 다음부터 저장됨.`
2. **CLI 가용성 확인** — `"$OBS" version` 실행. **⚠️ 실측 함정: 연결 실패여도 exit code가
   0이다.** 판정은 반드시 출력 텍스트로 한다 — 버전 문자열(예: `1.12.7 (installer 1.12.7)`)이면
   가용, `"unable to find Obsidian"`이면 미가용(가장 흔한 원인: **앱이 꺼져 있음**).
3. **가용하면 CLI로 저장** — 링크 자동 갱신 등 이점:
   ```bash
   "$OBS" vault=<vault명> create path="wiki/<카테고리>/<프로젝트>/_work/<작업명>/<YYYY-MM-DD>/설계.md" content="---\ntype: 설계\n..."
   ```
   실측 확인: `vault=`는 맨 앞 · `path=`는 vault 루트 기준 · `content=`의 `\n`은 개행으로
   확장됨(frontmatter 포함 문서 전체를 한 줄로 전달 가능) · 대상 vault는 Obsidian에 등록된
   vault여야 함(`"$OBS" vaults`로 목록 확인, vault_root가 등록 vault가 아니면 4번 폴백).
4. **미가용하면 파일 직접 쓰기로 폴백하되, 반드시 경고를 보고에 남긴다**:
   `⚠️ HRN-W011 — Obsidian CLI 미가용(앱 꺼짐/미등록/미설치). 파일 직접 쓰기로 저장함. 링크 자동 갱신 등 CLI 이점 없음. 앱 실행 후 재시도 가능.`
   경고 없는 폴백 = 위반. CLI 위치 탐색(위 섹션)을 하지 않고 폴백하는 것도 위반.
5. **결과 보고** — 저장된 전체 경로 목록 + 사용 방식(CLI/폴백) + 발생 경고를 숨김없이.
6. **사용 보고 (하네스 공통 규칙)** — 그 턴의 보고 마지막에 반드시 명시한다:
   `— 적용 스킬: obsidian-cli` (여러 스킬 적용 시 쉼표로 병기). 미보고 = 위반.

## 완료 기준 (제출 전 자가 점검)

- [ ] 경로가 계약과 일치 (wiki/ 루트, _work, 작업명·날짜 폴더, 고정 파일명 3종)
- [ ] 카테고리를 임의 창작하지 않음 (기존 폴더 선택 or 되물음)
- [ ] 템플릿 구조 + status 갱신 + ≤10자 요약
- [ ] CLI 확인 흔적이 보고에 있음 (사용 or HRN-W011 경고)
- [ ] vault_root 미지정 시 HRN-W010 + 비차단 보관
- [ ] 저장 경로 전체 목록 보고
- [ ] 사용 보고: `— 적용 스킬: obsidian-cli`
