# PRD — kgh-dev-harness

> **요약(≤10자):** 개발 하네스 패키지

AI 코딩 하네스(Claude Code, 추후 Codex)에 설치하는 **개발 워크플로 자동화 패키지**.
사용자가 작업을 지시하면 각 구간에 맞는 스킬이 자동 로드되고, 정의된 워크플로대로
흐름이 진행되며, 사용자는 **결과 확인과 필수 승인 게이트에서만** 개입한다.

- 정의(진실의 기준): Obsidian vault `LLM-Wiki/harness/` (workflow.md · commit-convention.md · script-standards.md · templates/)
- 실행체(이 레포): 스킬 · 어댑터 · 오케스트레이터 · 훅 · 설치 스크립트

---

## 1. 정체성

**소스 레포 → 설치/배포형 패키지.**

- 이 레포에서 하네스를 빌드하고, 완성본을 **아무 프로젝트에나 설치**해서 쓴다.
- 설치 → 1회 세팅 → 해당 프로젝트에 맞춰 워크플로가 굴러간다.
- 루트 컨피그 파일이 **설정의 단일 진실원**이며, 값 변경은 **즉시 반영**된다(런타임 read, 캐시 없음).

## 2. 핵심 요구사항

| # | 요구 | 비고 |
|---|---|---|
| R1 | 멀티 하네스: Claude Code **와** Codex, 하나 또는 둘 다 | v1은 Claude 완성, Codex는 §10 추후 작업 |
| R2 | 구간(단계)별 `model` · `effort`(추론레벨) 설정 | 각 하네스 규격에 맞춰 매핑 |
| R3 | 구간별 `skills[]` 로드 — 넣기/빼기/교체 전부 컨피그에서 | |
| R4 | 패키지 설치형 — 어느 프로젝트든 설치만 하면 동작 | 대화형 설치 스크립트 |
| R5 | 루트 컨피그(`harness.config.yaml`) 단일 진실원 + 즉시 반영 | YAML |
| R6 | 스킬 내장: 내 스킬(vendored) + 오픈소스 스킬(핀 고정 pull) | superpowers 등 |
| R7 | 승인 게이트 최소화 — 사용자는 확인/승인만 | §6 게이트 구성 |
| R8 | silent 에러 금지 — 명시적 에러코드 + 2가지 복구 경로 안내 | §8 에러 계약 |
| R9 | 산출 문서 3종(설계/구현계획/구현후보고)을 obsidian-cli로 vault 저장 | §7 저장 규칙 |
| R10 | **업데이트 스크립트 동봉** — 명령어 한 번으로 하네스 최신본 수신, 기존 워크플로에서 즉시 사용 가능 | 설치 스크립트와 별도 |
| R11 | 개발용 파일(PRD.md·저장소 룰 등)은 **배포 패키징에서 제외** | git에는 커밋, 설치 대상엔 미포함 |

## 3. v1 범위

**포함:** Claude Code 어댑터 · 컨피그 로더/리졸버 · 오케스트레이터 지침 · SessionStart 훅 ·
하이브리드 스킬 번들(내 스킬 6종 신규 제작 + 오픈소스 핀 고정) · 대화형 설치 스크립트 ·
9단계 워크플로 + 게이트.

**제외(추후, §10):** Codex 어댑터 구현 · **Ollama(로컬 모델) 어댑터**(Codex 적용 이후 착수).
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
- **실행 구조 = 오케스트레이터 + 서브에이전트 디스패치.** Claude Code는 메인 세션 도중
  모델 변경이 불가하므로, 구간별 `model`/`effort`는 **각 구간을 서브에이전트로 디스패치**하여 적용한다.
  메인 세션은 지휘자 역할만 한다.

## 5. 레포 구조

```
kgh-dev-harness/
├─ PRD.md                     # 이 문서
├─ harness.config.yaml        # 템플릿 컨피그 (설치 시 프로젝트별 인스턴스 생성)
├─ config/                    # 스키마 + 디폴트값
├─ core/                      # 하네스 무관: loader·resolver·orchestrator 지침
├─ adapters/
│  ├─ claude/                 # v1
│  └─ codex/                  # 스텁 (추후)
├─ skills/                    # 내 스킬 (vendored, 소유)
├─ vendor/skills/             # 오픈소스 스킬 (버전 핀 고정 pull)
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

**업데이트 규칙:** `install/update`는 (a) 소스 최신본 수신 → (b) `.harnessignore` 적용 복사
→ (c) 기존 `harness.config.yaml` **보존**(사용자 설정 덮어쓰기 금지) → (d) 스키마 변경 시
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

**신규 제작 스킬 6종:** `cost-bottleneck-check` · `obsidian-cli` · `design-doc` · `report-doc` ·
`impact-scan`(선택) · `interactive-script`(선택). 제작은 superpowers:writing-skills 규율
(RED→GREEN→REFACTOR, 스킬당 개별 테스트·커밋)을 따른다.

## 7. 컨피그 스키마 (`harness.config.yaml`)

```yaml
active_harness: claude          # claude | codex | [claude, codex]
defaults:                        # 구간 미지정 시 상속
  model: sonnet
  effort: medium
storage:
  enabled: true
  tool: obsidian-cli
  vault_root: null               # ★ 디폴트 없음 — 반드시 사용자 지정 (§7.1)
  path_template: "<category>/<project>/_work/<task>/<YYYY-MM-DD>"
  docs: [설계, 구현계획, 구현후보고]
  approval: auto                 # auto | required(저장 직전 확인)
stages:
  entry_gate:
    enabled: conditional         # 판단형 요청일 때만
    skills: [cost-bottleneck-check]
  design:
    model: opus
    effort: high
    skills: [brainstorming, design-doc]
    gate: required
  plan:
    skills: [scope-splitter, writing-plans]
    gate: auto                   # optional로 바꾸면 승인 대기
  implement:
    model: sonnet
    skills: [test-driven-development]
  verify:
    skills: [requesting-code-review]
    loop: auto
  report:
    skills: [report-doc]
  judgment:
    gate: required
```

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

| 코드 | 의미 | 조치 |
|---|---|---|
| `HRN-E001` | 미지원/변경된 model 값 | 값 재입력 또는 어댑터 수정 |
| `HRN-E002` | 미지원/변경된 effort 값 | 값 재입력 또는 어댑터 수정 |
| `HRN-E003` | 활성 하네스 규격 변동(스펙 mismatch) | 어댑터 업데이트 |
| `HRN-E004` | 컨피그 스키마 위반(형식) | 컨피그 수정 |
| `HRN-W010` | `vault_root` 미지정 (경고, 비차단) | vault_root 지정 |

raw 에러 노출 금지 — 항상 위 형식으로 래핑한다. (vault `script-standards.md` 준수)

## 9. 성공 기준

1. 임의 프로젝트에 설치 → 세팅 → 작업 지시 한 번으로 9단계 흐름이 자동 진행된다.
2. 사용자 개입 지점이 게이트(설계 승인 · 최종 판정 · 조건부 게이트)로 한정된다.
3. `harness.config.yaml`에서 구간별 model/effort/skills를 바꾸면 다음 실행에 즉시 반영된다.
4. 검증 실패 시 사용자 개입 없이 자동 루프(계획서 기록 → 구현 복귀)가 돈다.
5. 판정 통과 시 3종 문서가 vault에 저장된다(vault_root 지정 시).
6. 어떤 실패도 silent 없이 에러코드 + 복구 경로 안내로 표면화된다.
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
