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
- **`<카테고리>`를 모르면 되묻는다.** 기존 `wiki/` 하위 폴더 목록을 보여주고 고르게 한다.
  임의 창작 금지.
- `harness/` 폴더는 정의(템플릿·규칙) 전용이다 — **산출 문서를 거기 두지 않는다.**

## 문서 규칙

- 템플릿: `<vault_root>/harness/templates/`의 설계·구현계획·구현후보고 3종을 사용한다.
- frontmatter의 `project` · `task` · `date` 채움, `status`는 실제 상태로 갱신
  (설계=승인, 구현계획=완료, 구현후보고=보고 등).
- summary 블록에 **10자 이내 요약** 필수.

## 저장 절차 (순서 고정)

1. **vault_root 확인** — 미지정이면 저장을 건너뛰되 **작업을 막지 않는다**:
   문서를 작업 공간에 보관하고 보고에 남긴다:
   `⚠️ HRN-W010 — storage.vault_root 미지정. 문서는 <경로>에 보관. 컨피그 지정 시 다음부터 저장됨.`
2. **CLI 가용성 확인** — `obsidian version` 실행 (Obsidian 앱이 켜져 있어야 동작).
3. **가용하면 CLI로 저장** — 링크 자동 갱신 등 이점:
   ```bash
   obsidian vault=<vault명> create path="wiki/<카테고리>/<프로젝트>/_work/<작업명>/<YYYY-MM-DD>/설계.md" content="..."
   ```
   (vault= 파라미터는 맨 앞. 멀티라인은 `\n`. 상세: `obsidian help create`)
4. **미가용하면 파일 직접 쓰기로 폴백하되, 반드시 경고를 보고에 남긴다**:
   `⚠️ HRN-W011 — Obsidian CLI 미가용(앱 꺼짐 또는 미등록). 파일 직접 쓰기로 저장함. 링크 자동 갱신 등 CLI 이점 없음.`
   경고 없는 폴백 = 위반.
5. **결과 보고** — 저장된 전체 경로 목록 + 사용 방식(CLI/폴백) + 발생 경고를 숨김없이.

## 완료 기준 (제출 전 자가 점검)

- [ ] 경로가 계약과 일치 (wiki/ 루트, _work, 작업명·날짜 폴더, 고정 파일명 3종)
- [ ] 카테고리를 임의 창작하지 않음 (기존 폴더 선택 or 되물음)
- [ ] 템플릿 구조 + status 갱신 + ≤10자 요약
- [ ] CLI 확인 흔적이 보고에 있음 (사용 or HRN-W011 경고)
- [ ] vault_root 미지정 시 HRN-W010 + 비차단 보관
- [ ] 저장 경로 전체 목록 보고
