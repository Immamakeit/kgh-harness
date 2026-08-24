# kgh-harness

Claude Code 세션에 **9구간 개발 워크플로**(판단 게이트 → 요구 파악 → 영향도 → 설계 →
계획 → 구현 → 검증 → 보고 → 판정 → 저장)를 얹는 하네스. 프로젝트 루트의
`harness.config.yaml` 하나로 구간별 스킬·모델·게이트를 정하고, 세션이 시작될 때
SessionStart 훅이 지휘 플레이북을 주입한다.

---

## 🤖 에이전트용 — 이 블록만 그대로 실행하면 설치가 끝난다

```bash
# 1. 하네스 소스를 받는다 (이미 있으면 git -C ~/.kgh-harness pull --ff-only)
git clone https://github.com/Immamakeit/kgh-harness.git ~/.kgh-harness

# 2. 대상 프로젝트에 설치한다 — 경로는 반드시 인자로 넘긴다
~/.kgh-harness/install/setup /absolute/path/to/project

# 3. 설치 검증
cd /absolute/path/to/project && .harness/install/validate-config
```

- 표준입력이 TTY가 아니면 모든 질문이 **디폴트로 자동 처리**되고 그 사실이 로그에 남는다.
  추가 플래그는 없다.
- 2번의 경로 인자를 **생략하면 안 된다.** 생략 시 대상이 하네스 소스 자신이 되어
  `HRN-E007` 로 차단된다.
- 3번이 `검증 통과` 로 끝나면 설치 완료다. 대상 프로젝트에서 Claude Code 세션을
  새로 시작하면 플레이북이 자동으로 로드된다.
- 비대화형 설치에서는 Obsidian 저장 경로(`storage.vault_root`)가 비어 `HRN-W010`
  경고가 뜬다. **비차단**이며, 문서는 `<프로젝트>/.harness/work/` 에 남는다.
  vault에 저장하려면 설치 후 `harness.config.yaml` 의 `storage.vault_root` 를 채운다.

---

## 전제

| 구분 | 항목 | 없으면 |
|---|---|---|
| 필수 | `bash`, `git`, **`rsync`** | rsync 부재 시 `HRN-E008` 로 설치 중단 |
| 권장 | `python3` | 없으면 vault_root 반영·훅 병합이 수동 안내로 열화(비차단) |
| 권장 | `PyYAML` (`pip install pyyaml`) | 없으면 컨피그 검증만 건너뜀(`HRN-W015`, 비차단) |
| 실행체 | [Claude Code](https://claude.com/claude-code) | 없으면 `HRN-W013` 경고(설치는 완료) |
| 선택 | [superpowers](https://github.com/obra/superpowers-marketplace) 플러그인 | 없으면 `HRN-W014` — 해당 구간을 그 스킬 없이 진행 |

superpowers 설치: Claude Code에서
`/plugin marketplace add obra/superpowers-marketplace` → `/plugin install superpowers`.
쓰지 않으려면 `harness.config.yaml` 의 `stages[].skills` 에서 `superpowers:` 항목을 지운다.

## 설치

```bash
git clone https://github.com/Immamakeit/kgh-harness.git ~/.kgh-harness
~/.kgh-harness/install/setup ~/dev/내프로젝트
```

대화형으로 진행하면 설치 경로 확인, Obsidian vault 선택(등록된 vault를 번호로 고른다)
까지 물어본다. 각 질문에는 디폴트가 표시되고 Enter로 그대로 진행할 수 있다.
`install/setup --help` 로 동작 요약을 볼 수 있다.

## 설치 후 확인

```bash
cd ~/dev/내프로젝트
.harness/install/validate-config     # 컨피그 검증 — "검증 통과"면 정상
cat harness.config.yaml              # 설정 (직접 수정해서 쓴다)
```

대상 프로젝트에서 Claude Code를 새로 시작하면 첫 컨텍스트에 지휘 플레이북이 실려 있다.
그다음부터는 평소처럼 작업을 지시하면 된다 — 실질 작업 지시는 9구간 흐름을 타고,
설계 승인과 최종 판정에서만 사용자에게 묻는다.

## 무엇이 설치되는가

```
<프로젝트>/
├─ harness.config.yaml        # 설정 (config/harness.config.template.yaml 에서 생성, 이후 미접촉)
├─ .claude/settings.json      # SessionStart 훅이 병합됨 (기존 훅·설정 보존)
└─ .harness/
   ├─ core/playbook.md        # 지휘 플레이북 — 세션에 주입되는 본문
   ├─ adapters/claude/        # Claude Code 어댑터 (훅·지원 모델 목록)
   ├─ skills/                 # 하네스 스킬 7종 (cost-bottleneck-check·design-doc 등)
   ├─ templates/              # 문서 서식 3종 (vault에 서식이 없을 때의 폴백)
   ├─ config/schema.yaml      # 컨피그 스키마
   ├─ install/                # setup·update·validate-config
   ├─ .meta                   # 소스 경로·커밋 기록 (update가 사용)
   └─ work/                   # 작업 문서 산출물 — update가 보존한다
```

개발용 파일(`PRD.md`·`CLAUDE.md`·`tests/`·소스 레포의 실사용 컨피그)은
`.harnessignore` 규칙으로 **배포되지 않는다.** 설치본에서 발견되면 패키징 버그다.

## 업데이트

```bash
cd ~/dev/내프로젝트
.harness/install/update
```

`.meta` 에 기록된 소스 레포를 `git pull` 한 뒤 배포물만 다시 깐다.
**`harness.config.yaml` 은 절대 덮어쓰지 않고**, 새 설정 키가 생기면 안내만 한다.
`.harness/work/` 의 작업 문서도 보존된다.

## 제거

```bash
rm -rf ~/dev/내프로젝트/.harness ~/dev/내프로젝트/harness.config.yaml
# .claude/settings.json 의 SessionStart 훅 항목은 직접 지운다
```

## 설정

`harness.config.yaml` 은 설정의 단일 진실원이고, 흐름이 시작될 때마다 다시 읽힌다
(캐시 없음 — 고치면 바로 반영된다). 주요 항목:

| 키 | 뜻 |
|---|---|
| `active_harness` | 실행체. v1은 `claude` 만 구현 (`codex`·`ollama` 는 `HRN-E010`) |
| `defaults.model` | 구간이 모델을 지정하지 않았을 때의 값 |
| `workdocs.path` | 작업 문서 위치 (기본 `.harness/work`) |
| `storage.vault_root` | Obsidian vault 절대경로. `null` 이면 저장을 건너뛴다 |
| `stages.<구간>.gate` | `required` 면 사용자 승인까지 멈춘다 |
| `stages.<구간>.skills` | 그 구간에서 적용할 스킬 목록 |

값을 고친 뒤에는 `.harness/install/validate-config` 로 검증한다.

## 에러 코드

모든 실패는 `HRN-Exxx`(차단) / `HRN-Wxxx`(경고) 코드와 **복구 경로 2개**를 함께 낸다.
자주 보는 것들:

| 코드 | 뜻 | 첫 조치 |
|---|---|---|
| `HRN-E005` | 소스·스키마·플레이북 등 필수 파일 부재 | 클론 상태 확인 후 `install/update` |
| `HRN-E007` | 대상 경로 문제 (권한, 또는 소스 자신을 대상으로 지정) | 프로젝트 경로를 인자로 넘긴다 |
| `HRN-E008` | 필수 실행체 부재 (rsync 등) | 해당 CLI 설치 |
| `HRN-E010` | 미구현 어댑터 지정 | `active_harness: claude` 로 변경 |
| `HRN-W010` | `vault_root` 미지정 | 컨피그에 vault 경로 지정 (문서는 로컬 보관) |
| `HRN-W014` | superpowers 미설치 | 플러그인 설치, 또는 컨피그에서 해당 스킬 제거 |

## 한계

- **Obsidian vault 자동 탐지는 WSL 전용**이다(`/mnt/c/Users/*/AppData/Roaming/obsidian`).
  macOS·순수 Linux에서는 탐지가 비고, 경로를 직접 입력하면 된다.
- `codex`·`ollama` 어댑터는 미구현 — v1은 Claude Code 전용이다.
- 자기 자신(하네스 소스 레포)에 설치하는 도그푸딩은 아직 지원하지 않는다.
- `.harness/work/` 에 들어 있는 문서는 이 하네스로 만든 **실제 산출물 예시**다.
  다른 프로젝트에는 복사되지 않는다.

## 라이선스

MIT — [LICENSE](LICENSE) 참고.

> 개발 문서(`PRD.md`·`CLAUDE.md`)는 하네스를 **만드는** 쪽 기준이라 배포물에서 제외된다.
> 그 문서들이 쓰는 `kgh-dev-harness` 는 이 저장소의 개발 코드네임이다.
