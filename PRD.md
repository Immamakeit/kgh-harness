# PRD — kgh-dev-harness

> **요약(≤10자):** 개발 하네스 패키지

AI 코딩 하네스(Claude Code, 추후 Codex)에 설치하는 **개발 워크플로 자동화 패키지**.
사용자가 작업을 지시하면 각 구간에 맞는 스킬이 자동 로드되고, 정의된 워크플로대로
흐름이 진행되며, 사용자는 **결과 확인과 필수 승인 게이트에서만** 개입한다.

- 정의(진실의 기준): Obsidian vault `LLM-Wiki/harness/` (workflow.md · commit-convention.md · script-standards.md · templates/)
- 실행체(이 레포): 스킬 · 어댑터 · 오케스트레이터 · 훅 · 설치 스크립트

---

## 1. 정체성

**개인 도구다 (2026-11-06 명시).** 범용 제품이 아니라 **한 사람의 작업 방식을 박아 넣은
개인 하네스**다. 전제가 환경에 박혀 있다: WSL(Obsidian vault 탐지) · Obsidian(저장
단계) · 한국어(플레이북·스킬·보고 전부). 호환성·지원·안정 인터페이스를 약속하지
않는다. MIT는 유지한다 — 남이 써서 좋을 것은 설치 스크립트와 에러 계약 정도이고,
그건 포크해서 고쳐 쓰는 편이 맞다.

**소스 레포 → 설치/배포형 패키지.**

- 이 레포에서 하네스를 빌드하고, 완성본을 **내 프로젝트에** 설치해서 쓴다.
- 설치 → 1회 세팅 → 해당 프로젝트에 맞춰 워크플로가 굴러간다.
- 루트 컨피그 파일이 **설정의 단일 진실원**이며, 값 변경은 **즉시 반영**된다(런타임 read, 캐시 없음).

## 2. 핵심 요구사항

| # | 요구 | 비고 |
|---|---|---|
| R1 | 멀티 하네스: Claude Code **와** Codex, 하나 또는 둘 다 | v1은 Claude 완성, Codex는 §10 추후 작업 |
| R2 | 구간(단계)별 `model` · `effort`(추론레벨) 설정 | 각 하네스 규격에 맞춰 매핑 |
| R3 | 구간별 `skills[]` 로드 — 넣기/빼기/교체 전부 컨피그에서 | |
| R4 | 패키지 설치형 — **superpowers 플러그인이 설치된** Claude Code 환경이면 어느 프로젝트든 설치만 하면 동작 | 대화형 설치 스크립트, 전제 미충족 시 `HRN-W014` 안내 |
| R5 | 루트 컨피그(`harness.config.yaml`) 단일 진실원 + 즉시 반영 | YAML |
| R6 | 스킬 내장: 내 스킬(vendored) + **오픈소스 스킬은 사용자 전역 설치를 전제**(superpowers) | 핀 고정 pull은 §10 추후 |
| R7 | 승인 게이트 최소화 — 사용자는 확인/승인만 | §6 게이트 구성 |
| R8 | silent 에러 금지 — 명시적 에러코드 + 2가지 복구 경로 안내 | §8 에러 계약 |
| R9 | 산출 문서 3종(설계/구현계획/구현후보고)을 obsidian-cli로 vault 저장 | §7 저장 규칙 |
| R10 | **업데이트 스크립트 동봉** — 명령어 한 번으로 하네스 최신본 수신, 기존 워크플로에서 즉시 사용 가능 | 설치 스크립트와 별도 |
| R11 | 개발용 파일(PRD.md·저장소 룰 등)은 **배포 패키징에서 제외** | git에는 커밋, 설치 대상엔 미포함 |

## 3. v1 범위

**포함:** Claude Code 어댑터 · 컨피그 로더/리졸버 · 오케스트레이터 지침 · SessionStart 훅 ·
내 스킬 번들(7종 신규 제작 — cost-bottleneck-check·design-doc·plan-doc·report-doc·
obsidian-cli·interactive-script·scope-splitter, + 9구간 워크플로 밖의 독립 유틸리티
스킬 2종 — 기반 문서 세팅 set-initial, 원격 GitHub 브랜치 보호 branch-strategy) +
superpowers 전제 · 대화형 설치 스크립트 ·
9단계 워크플로 + 게이트.

**제외(추후, §10):** Codex 어댑터 구현 · **Ollama(로컬 모델) 어댑터**(Codex 적용 이후 착수) ·
**오픈소스 스킬 vendoring·버전 핀 고정**(superpowers는 v1에서 사용자 전역 설치 전제로만 다룸).
단, **어댑터 추상화는 v1 설계 시점부터 로컬 모델 런타임까지 수용 가능한 범위로** 잡는다 —
model/effort 개념이 하네스·런타임마다 다름(클라우드 모델명 vs 로컬 모델 태그, effort 미지원
런타임 존재)을 전제로 인터페이스를 설계한다.

## 4. 아키텍처

```
harness.config.yaml (단일 진실원, YAML, 런타임 read)
        │
  Config Loader / Resolver     ← 스키마 검증 + 하네스 규격 대조 (§8 에러코드)
        │  정규화된 흐름 플랜
  Orchestrator (지휘자)         ← 9단계 엔진, 게이트에서 정지
        │  구간별 {model, effort, skills[]}
  Harness Adapter (인터페이스)
   ├ adapters/claude/  (v1)    → 서브에이전트/Workflow 디스패치
   └ adapters/codex/   (스텁)
```

- **SessionStart 훅 = 방아쇠.** 세션 시작 시 흐름 지침 + resolved 컨피그를 컨텍스트로 주입.
- **오케스트레이터 구현 방식 확정 (A안):** 얇은 훅(`adapters/claude/hooks/session-start.sh`)
  + 지휘 플레이북(`core/playbook.md`). 컨피그 해석·검증·게이트·디스패치는 플레이북 지침에
  따라 메인 세션이 수행한다. 결정적 코드 리졸버로의 승격은 흐름이 실사용으로 검증된 뒤
  증분으로 진행.
- **실행 구조 = 오케스트레이터 + 서브에이전트 디스패치.** Claude Code는 메인 세션 도중
  모델 변경이 불가하므로, 구간별 `model`/`effort`는 **각 구간을 서브에이전트로 디스패치**하여 적용한다.
  메인 세션은 지휘자 역할만 한다. `agent_mode: single`이거나 디스패치가 열화된 경우에는
  이 디스패치 자체가 적용되지 않는다(§7 `agent_mode`, `HRN-W016`).

## 5. 레포 구조

```
kgh-dev-harness/                (공개 원격: kgh-harness)
├─ PRD.md                     # 이 문서
├─ README.md                  # 공개용 설치·사용 안내 (사람 + 에이전트)
├─ LICENSE                    # MIT
├─ harness.config.yaml        # ★ 이 레포 자신의 실사용 컨피그 — 배포 제외
├─ config/                    # 스키마 단일 진실원 (schema.yaml)
│  └─ harness.config.template.yaml   # ★ 배포 템플릿 (vault_root: null) — 대상 컨피그의 원본
├─ core/                      # 하네스 무관: loader·resolver·orchestrator 지침
├─ adapters/
│  ├─ claude/                 # v1
│  └─ codex/                  # 스텁 (추후)
├─ skills/                    # 내 스킬 (vendored, 소유) — set-initial 포함
├─ templates/                 # 설계·구현계획·구현후보고 (vault와 동기화)
├─ install/                   # 대화형 설치·세팅 스크립트 (script-standards 준수)
│  ├─ setup                   #   최초 설치 + 1회 세팅
│  └─ update                  #   ★ 하네스 업데이트 — 명령어 한 번으로 최신본 수신,
│                             #     기존 프로젝트 workflow에서 즉시 사용 가능해야 함
└─ .harnessignore             # 배포 패키징 제외 목록 (PRD.md, 저장소 룰 등 개발용 파일)
```

**패키징 제외 규칙:** PRD.md · 저장소 룰 등 "하네스를 만드는 데 필요한" 개발용 파일은
git에는 커밋하되, `install/setup`·`install/update`가 대상 프로젝트로 복사할 때
`.harnessignore` 목록 기준으로 **제외**한다.

**컨피그 두 갈래 (2026-08-24 확정):** 루트 `harness.config.yaml`은 **이 레포 자신의**
설정이고 배포 대상이 아니다. 대상 프로젝트의 컨피그는 `config/harness.config.template.yaml`
로부터 생성된다. 한 파일이 두 역할을 겸하던 시절, 소스의 개인 `vault_root`가 설치 대상에
그대로 상속되는 결함이 있었다 — 역할 분리가 그 재발 방지책이다.

**스킬 구동 방식 (2026-11-06 개정 — 직독 + 노출 병행):** 플레이북 §1의 파일 직독
방식(`skills/<이름>/SKILL.md`를 읽고 따름)이 **여전히 주 경로**다. 거기에 대상
프로젝트의 `.claude/skills/<이름>` → `.harness/skills/<이름>` **상대 심링크 노출을
추가**한다(`skills.expose_to_claude`, 기본 켜짐).

> **번복된 이전 결정:** "`.claude/skills/`에 등록하지 않는다 — 직독으로만 구동한다."
> 당시 근거는 "플레이북이 경로로 직독하니 등록은 중복"이었다. 그 결정의 부작용이
> 실측으로 드러나 번복한다: 스킬 10종의 `description` 을 superpowers 규율대로
> "Use when…" 트리거만으로 작성했는데 **그 description을 읽는 주체가 없었다.**
> 자동 트리거도, 사용자의 직접 호출(`/<스킬명>`)도 불가능했다 — 공들인 트리거 문구가
> 사문이었다. 노출은 직독을 **대체하지 않는다**(구간별 실행은 그대로 직독이다).
> 충돌 시 조용히 가리지 않고 `HRN-W022`로 건너뛴다.

**업데이트 규칙:** `install/update`는 (a) 소스 최신본 수신 → (b) `.harnessignore` 적용 복사
→ (c) 대상의 `harness.config.yaml` **보존**(사용자 설정 덮어쓰기 금지 — 스키마 diff는
템플릿 기준으로 안내만) → (d) 스키마 변경 시
마이그레이션 안내(§8 에러 계약 준수) 순으로 동작한다. 업데이트 직후 재세팅 없이
기존 워크플로가 그대로 굴러가야 한다.

## 6. 워크플로 · 게이트 · 구간별 스킬 매핑

vault `workflow.md` 2장(9단계)을 실행한다. 게이트 구성:

| 단계 | 기본 스킬(`skills[]` 컨피그로 교체 가능) | 게이트 |
|---|---|---|
| ① 입구 판단 게이트 | `cost-bottleneck-check` 🔨 (+옵션: deep-research) | **조건부** — 판단형 요청일 때만 |
| ②③ 요구·의도 파악 | `superpowers:brainstorming` | — (clarify까지 반복) |
| ④ 영향도 분석 | `impact-scan` 🔨(선택) 또는 Explore 서브에이전트 | — |
| ⑤ 설계 | `design-doc` 🔨 + 설계 템플릿 | **필수 승인** |
| ⑥ 구현 계획 | `scope-splitter` ✅ + `superpowers:writing-plans` | 조건부(기본 자동통과) |
| ⑦ 구현 | `superpowers:test-driven-development` (+systematic-debugging, `interactive-script` 🔨선택) | — |
| ⑧ 검증 | 코드리뷰 + lint + `verify` 계열 | **자동 루프** — 실패 시 계획서에 처리 기록 후 구현 복귀 |
| ⑨ 보고 | `report-doc` 🔨 + 구현후보고 템플릿 (직접 확인 시나리오 포함) | — |
| ⑩ 사용자 판정 | — (오케스트레이터 로직) | **필수** — "통과/실패"만 입력. 실패 시 보완계획 → ⑦ 재진입 |
| ⑪ 산출물 저장 | `obsidian-cli` 🔨 | 컨피그 on/off (`storage.approval`) |

🔨 = v1에서 신규 제작(이 레포 소유) · ✅ = 보유

**게이트 집행 (2026-11-06 추가):** ⑤ 설계 승인 게이트는 **프롬프트 선언이 아니라
`PreToolUse` 훅이 집행한다.** 설계 문서가 있고 승인 마커(`.approved`)가 없는 작업이
있으면 작업 문서 밖의 편집·커밋이 `HRN-E016` 으로 차단된다. 모드는
`gate.enforce`(`block` 기본 / `warn` / `off`). 셸 경유 임의 수정까지 전부 봉쇄하지는
못한다 — **표류를 잡는 장치지 적대적 우회를 막는 장치가 아니다.** 과장하지 않는다.

**신규 제작 스킬 6종:** `cost-bottleneck-check` · `obsidian-cli` · `design-doc` · `report-doc` ·
`impact-scan`(선택) · `interactive-script`(선택). 제작은 superpowers:writing-skills 규율
(RED→GREEN→REFACTOR, 스킬당 개별 테스트·커밋)을 따른다.

## 7. 컨피그 스키마 (`harness.config.yaml`)

스키마의 단일 진실원은 **`config/schema.yaml`** 이다 — 키·타입·허용값·필수여부·기본값을
그 파일이 정의한다. 이 문서에 예시를 중복 기재하지 않는다(드리프트 방지).

허용값 중 **model·effort 는 어댑터 소유**다: `adapters/<active_harness>/capabilities.yaml`.
검증은 `install/validate-config` 가 ① 구조 → ② 값(어댑터 위임) → ③ 참조 실존 순으로
수행한다.

### 7.1 저장 규칙 (`storage`)

- 3종 문서는 흐름 중 작업 공간에 생성되고, **⑩ 판정 "통과" 시** obsidian-cli로 vault에 저장.
- 저장 경로: `vault_root` + `path_template` 치환. 문서 맨 윗줄 ≤10자 요약(템플릿 반영).
- **`vault_root`는 디폴트값이 없다.** 하드코딩 금지(이식성).
  - **미지정이어도 작업은 절대 막지 않는다.** 문서는 작업 공간에 보관하고,
    저장 단계마다 다음을 안내한다: *"`storage.vault_root` 미지정 — 저장 건너뜀.
    문서는 `<경로>`에 보관. 컨피그 지정 시 다음부터 저장됨."* (`HRN-W010`)
  - 지정 전까지 **매 실행 재안내**한다. 결과를 숨기지 않는다.

## 8. 에러 처리 계약 (silent 금지)

Claude/Codex의 모델명·규격은 변할 수 있다. 흐름 시작 시 Resolver가
① 컨피그 스키마 검증 → ② 활성 하네스의 model/effort 규격 대조를 수행하고,
불일치 시 **명시적 에러코드 + 2가지 복구 경로**를 항상 제시한다:
(a) 컨피그 값 재입력 (b) 하네스 자체(어댑터/스키마) 수정.

**코드 대장 규칙:** 새 에러/경고 코드가 필요하면 코드보다 **이 표에 먼저 등재**하고
번호를 잡는다 — 표에 없는 코드를 구현체(스킬·어댑터·훅)에 먼저 쓰지 않는다. 여러 작업이
동시에 설계되면 각자 "현재 최대 번호"만 보고 다음 번호를 추측하다 충돌한다(2026-08-25,
`HRN-W016`이 세 작업 설계에서 동시에 배정된 사례로 실증됨) — 번호 배정은 이 표 한 곳에서만
한다. 아직 구현되지 않은 코드는 코드 칸에 `(예정)`을 붙여 구분하고, 구현이 끝나면
표기를 지운다.

| 코드 | 의미 | 조치 |
|---|---|---|
| `HRN-E001` | 미지원/변경된 model 값 | 값 재입력 또는 어댑터 수정 |
| `HRN-E002` | 미지원/변경된 effort 값 | 값 재입력 또는 어댑터 수정 |
| `HRN-E003` | 활성 하네스 규격 변동(스펙 mismatch) | 어댑터 업데이트 |
| `HRN-E004` | 컨피그 스키마 위반(형식) | 컨피그 수정 |
| `HRN-E005` | 지휘 플레이북·스킬 파일 등 필수 배포 파일 미발견 | install/update 재실행 또는 소스 복원 |
| `HRN-E006` | 업데이트 소스 레포 미발견 | 경로 재입력 또는 재설치 |
| `HRN-E007` | 대상 경로 생성/쓰기 불가 | 경로·권한 확인 또는 다른 경로 지정 |
| `HRN-E008` | 필수 실행체·도구 미발견 (하네스 CLI·rsync 등) | 설치 또는 active_harness 변경 |
| `HRN-E009` | 모델 디스패치 실패 (폐기·권한·플랜) — defaults 1회 폴백 후에도 실패 | 컨피그 model 변경 또는 어댑터 지원 목록 갱신 |
| `HRN-E010` | active_harness가 미구현 어댑터 (codex·ollama는 추후) | claude로 변경 또는 어댑터 구현 |
| `HRN-E011` | gh CLI 미인증 | gh auth login 또는 인증된 환경에서 재실행 |
| `HRN-E012` | gh 토큰 repo 스코프 없음 | gh auth refresh -s repo 또는 PAT 재발급 |
| `HRN-E013` | 원격이 GitHub 아님/원격 없음 | GitHub 원격 추가 또는 해당 플랫폼 수동 설정 |
| `HRN-E014` | 저장소 admin 권한 없음/조회 불가 | admin 계정 재인증 또는 admin에게 대신 요청 |
| `HRN-E015` | 스킬 이름이 하네스와 프로젝트 양쪽에 존재 (차단) | 컨피그에 `project:<이름>` 으로 어느 쪽인지 명시, 또는 한쪽 스킬 이름 변경·`skills.project_path` 비우기 |
| `HRN-E016` | ⑤ 설계 승인 전 구현 시도 (PreToolUse 게이트 차단) | 사용자 승인 후 `install/approve <작업명>` 실행, 또는 `gate.enforce: off` |
| `HRN-W010` | `vault_root` 미지정 (경고, 비차단) | vault_root 지정 |
| `HRN-W011` | Obsidian CLI 미가용(앱 꺼짐/미등록/미설치) → 파일 직접 쓰기로 폴백 (경고, 비차단) | Obsidian 앱 실행 후 재시도(CLI 이점 복원) 또는 폴백 결과 그대로 사용 |
| `HRN-W012` | 프로젝트에 harness.config.yaml 없음 (경고, 비차단 — 플레이북 기본값으로 진행) | install/setup으로 컨피그 생성 |
| `HRN-W013` | setup 시 하네스 실행체 미발견 (경고, 비차단) | CLI 설치 후 사용 |
| `HRN-W014` | superpowers 플러그인 미발견 (경고, 비차단) | 플러그인 설치 또는 컨피그에서 제거 |
| `HRN-W015` | 검증 전제(python3·PyYAML) 미충족으로 컨피그 검증 건너뜀 (경고, 비차단) | python3/PyYAML 설치 후 재실행 |
| `HRN-W016` | 서브에이전트 디스패치 불가(사전/사후 신호) — 싱글 모드로 열화 (경고, 비차단) | 세션 지침에서 서브에이전트 허용 후 재시도 또는 그대로 진행 |
| `HRN-W017` | 선호 프로필 파일 손상/파싱 실패 (비차단 — 프로필 없이 스킬 기본값으로 진행) | (a) `~/.claude/harness/preferences.yaml`을 고치거나 삭제(다음 접근 시 재생성) (b) `preferences.as_recommended`를 꺼서 추천 계층 자체를 우회 |
| `HRN-W018` | 선호 프로필 쓰기 실패, 권한 등 (비차단 — 이번 선택은 학습에 반영 안 됨, 진행은 계속) | (a) `~/.claude/harness/` 권한 확인 (b) `CLAUDE_CONFIG_DIR`로 쓰기 가능한 경로 지정 |
| `HRN-W019` | 브랜치 보호 설정 일부만 적용 성공 (경고, 비차단) | 실패 항목 수동 설정 또는 재실행 |
| `HRN-W020` | 컨피그 검증기 파일은 존재하나 실행 불가 (경고, 비차단) | 실행 권한 부여(chmod +x) 또는 해당 명령 실행 허용 후 재검증, 또는 검증 없이 진행 |
| `HRN-W021` | 승인 게이트 판정 전제 미충족 (컨피그·작업 디렉터리 해석 실패, python3 부재 등) → **통과시킨다**(fail-open, 비차단) | (a) 보고된 사유를 고친 뒤 재시도 (b) 게이트 없이 진행 — 게이트 고장이 작업을 세우지 않는다 — 기록은 `.harness/gate.log` 에 남고 `systemMessage`(사용자) · `additionalContext`(모델) 로도 전달된다 (2026-11-06 실측: `exit 0` 훅의 stderr 는 디버그 로그에만 남아 아무에게도 안 보이고, 두 JSON 필드는 각각 사용자·모델에게만 간다 — 셋 다 내야 둘 다에게 닿는다) |
| `HRN-W022` | `.claude/skills/` 에 같은 이름의 남의 스킬이 있어 하네스 스킬 노출을 건너뜀 (경고, 비차단) | (a) 한쪽 스킬 이름을 바꾼 뒤 `install/update` 재실행 (b) `skills.expose_to_claude: false` 로 노출 자체를 끈다 |
| `HRN-W023` | `storage.vault_root` 가 지정됐으나 그 경로가 실존하지 않음 (경고, 비차단 — ⑪ 저장만 건너뛴다) | (a) 실제 vault 경로로 고친 뒤 `install/setup` 재실행 (b) 다른 PC 의 볼트라면 그대로 둔다 — 문서는 로컬에 쌓이고 저장만 미뤄진다 |

raw 에러 노출 금지 — 항상 위 형식으로 래핑한다. (vault `script-standards.md` 준수)

## 9. 성공 기준

1. 임의 프로젝트에 설치 → 세팅 → 작업 지시 한 번으로 9단계 흐름이 자동 진행된다.
2. 사용자 개입 지점이 게이트(설계 승인 · 최종 판정 · 조건부 게이트)로 한정된다.
3. `harness.config.yaml`에서 구간별 model/effort/skills를 바꾸면 다음 실행에 즉시 반영된다.
4. 검증 실패 시 사용자 개입 없이 자동 루프(계획서 기록 → 구현 복귀)가 돈다.
5. 판정 통과 시 3종 문서가 vault에 저장된다(vault_root 지정 시).
6. 어떤 실패도 silent 없이 에러코드 + 복구 경로 안내로 표면화된다.
6-1. **⑤ 승인 게이트는 선언이 아니라 집행된다** — 승인 마커 없이 작업 문서 밖을
   편집하려 하면 실제로 막힌다(`HRN-E016`). 게이트 자체가 고장 나면 작업을 세우지
   않고 통과시킨다(`HRN-W021`, fail-open).
6-2. **조용한 실패를 남기지 않는다** — ⑥ 기준의 구체화. (a) 컨피그에 적힌 vault 경로가
   실제로 없으면 그 사실이 검증·설치·업데이트 중 **최소 한 곳**에서 보고되고(`HRN-W023`),
   ⑪ 저장은 vault 밖에 유령 트리를 만들지 않는다. (b) 게이트 fail-open 은
   `.harness/gate.log` 에 기록되고, stdout JSON 의 `systemMessage`(사용자) ·
   `additionalContext`(모델) 로 전달된다 — `exit 0` 훅의 stderr 는 디버그 로그에만 남아
   사용자도 모델도 보지 못하므로 stderr 만으로는 ⑥ 기준을 만족하지 않는다
   (2026-11-06 실측, Claude Code 2.1.319). (c) 경고가 보고하는 **원인이 실제 원인과
   일치한다** — 열화 사유를 "python3 부재"로 단정하지 않는다.
7. `install/update` 한 번으로 최신 하네스가 반영되고, 사용자 컨피그는 보존되며,
   재세팅 없이 기존 워크플로가 즉시 동작한다. 개발용 파일은 설치 대상에 나타나지 않는다.

## 10. 추후 작업 (v1 미포함 — 명시적 박제)

- **Codex 어댑터 완성**: Codex 규격에 맞춘 model/effort 매핑, 스킬 로드 방식, 설치 경로,
  크로스-하네스 컨피그 검증. `adapters/codex/`는 v1에서 인터페이스 스텁만 둔다.
- **Ollama 로컬 모델 어댑터** (Codex 적용 이후 착수 — v1·v2 공통 비목표):
  구간별 `model`에 로컬 모델 태그(예: `llama3`, `qwen2.5-coder`) 지정, effort 미지원
  런타임의 대체 매핑 정의, 로컬 서빙 엔드포인트 설정. **비목표이나 어댑터 추상화
  설계는 v1부터 이 범위를 포함한다**(§3).
- `active_harness: [claude, codex]` 동시 모드 검증.
- 흐름 UI 단위 제어(vault workflow.md 4장 아이디어) — 대화형 TUI 확장.
- **오픈소스 스킬 vendoring / 버전 핀 고정 pull**: v1은 superpowers를 사용자 전역 설치
  전제로만 다룬다(R6). 포기가 아니라 이월 — `vendor/skills/` 디렉토리·핀 고정 pull
  파이프라인은 이 항목이 착수될 때 신설한다.
