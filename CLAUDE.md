# 저장소 룰 — kgh-dev-harness

> **요약(≤10자):** 하네스 소스 룰

이 파일은 이 저장소에서 작업하는 에이전트가 **매 세션 반드시 따르는 룰**이다.
개발용 파일이므로 배포 패키징에서 제외된다(`.harnessignore`).

## 1. 저장소 정체성

- 이 레포는 **하네스의 소스**다. 완성본을 다른 프로젝트에 설치/배포한다.
- **정의(진실의 기준)는 vault** `/mnt/c/gh-obsidian-vaults/LLM-Wiki/harness/`
  (workflow.md · commit-convention.md · script-standards.md · templates/),
  **실행체는 이 레포**다.
- 정의와 실행체가 어긋나면 **vault가 이긴다.** 실행체를 vault에 맞춰 수정한다.
- 요구사항·범위의 기준 문서는 `PRD.md`다. PRD와 어긋나는 구현 금지.
- 개발용 파일(PRD.md, CLAUDE.md 등)과 배포물(skills/, adapters/, core/,
  install/, templates/, config/)을 엄격히 구분한다. 구분 기준은 `.harnessignore`.

## 2. 커밋 룰

- **실제 파일 변경이 있을 때마다 커밋한다.** 몰아서 커밋 금지.
- 형식: `[작업유형]: 메시지` — 작업유형은 feat / fix / refactor / docs / test / chore / style.
- 브랜치: **master 직접 커밋** (1인 소스 레포). 실험적 대공사만 브랜치를 딴다.

## 3. 디렉토리 소유권 룰

- 새 파일은 반드시 PRD §5 구조의 제자리에 둔다. **루트에 파일 늘어놓기 금지.**
- `vendor/skills/`는 **수정 금지 구역.** 오픈소스 스킬은 고치지 않고 버전 핀만 관리한다.
  고치고 싶으면 `skills/`로 fork해서 소유권을 가져온 뒤 고친다.
- `templates/`는 vault가 원본. **직접 수정 금지**, vault에서 동기화만 한다.

## 4. 스킬 제작 룰

- 모든 신규/수정 스킬은 **superpowers:writing-skills 규율**을 따른다:
  RED(스킬 없이 베이스라인 실패 관찰) → GREEN(작성) → REFACTOR(허점 봉쇄).
- **스킬 하나를 완성·테스트·커밋한 뒤에 다음 스킬로 넘어간다.** 일괄 생산 금지.
- description은 "Use when…"으로 **트리거 조건만** 적는다. 워크플로 요약 금지.

## 5. 스크립트 룰

- vault `script-standards.md` 준수: `install/` 스크립트는 **대화형**,
  선택지·디폴트 명확 안내, **결과 비은닉**, 모든 것을 명확히 보고.
- **silent 에러 금지.** 모든 에러는 PRD §8 에러코드 체계(`HRN-Exxx` / `HRN-Wxxx`)로
  래핑하고, 항상 2가지 복구 경로(값 재입력 / 하네스 수정)를 제시한다.

## 6. 패키징 룰

- `.harnessignore`에 있는 파일은 `install/setup` · `install/update`가
  대상 프로젝트로 복사할 때 **반드시 제외**한다.
- 개발용 파일이 설치된 대상 프로젝트에서 발견되면 **버그(패키징 누출)** 로 취급한다.
- `install/update`는 대상의 `harness.config.yaml`을 **절대 덮어쓰지 않는다.**

## 7. 이 레포 개발 자체의 워크플로

- 하네스 v1 완성 전: 브레인스토밍 → 설계 승인 → 구현 → 검증 → 커밋의 수동 흐름.
- v1이 돌기 시작하면: **이 레포 자신에게 설치(dogfooding)** 해서
  이 레포의 개발도 하네스 흐름으로 태운다.
