# kgh-harness

Claude Code에 개발 워크플로를 얹는 하네스. 작업을 지시하면 판단 게이트 → 요구 파악 →
영향도 → 설계 → 계획 → 구현 → 검증 → 보고 → 판정 → 저장 순으로 흐르고,
설계 승인과 최종 판정에서만 사용자에게 묻는다. 구간별 스킬·모델·게이트는
프로젝트 루트의 `harness.config.yaml` 하나로 정한다.

---

## 🤖 에이전트용 — 이 블록만 실행하면 설치가 끝난다

```bash
# 1. 하네스를 받는다 (이미 있으면 git -C ~/.kgh-harness pull --ff-only)
git clone https://github.com/Immamakeit/kgh-harness.git ~/.kgh-harness

# 2. 대상 프로젝트에 설치한다 — 경로를 반드시 인자로 넘긴다
~/.kgh-harness/install/setup /absolute/path/to/project

# 3. 검증
cd /absolute/path/to/project && .harness/install/validate-config
```

- 2번의 경로 인자를 빼면 안 된다. 빼면 하네스 자신에 설치하려는 것으로 보고 `HRN-E007`로 막는다.
- 터미널이 아니면 모든 질문에 기본값을 쓰고, 무엇을 골랐는지 로그에 남긴다. 추가 플래그는 없다.
- 3번이 `검증 통과`로 끝나면 설치가 끝난 것이다.
- Obsidian 저장은 꺼진 채로 시작한다(`HRN-W010`). 문서는 `<프로젝트>/.harness/work/`에 쌓인다.
  vault에 쌓으려면 `harness.config.yaml`의 `storage.vault_root`를 채운다.

---

## 전제

| 구분 | 항목 | 없으면 |
|---|---|---|
| 필수 | `bash`, `git`, `rsync` | 설치 중단 (`HRN-E008`) |
| 권장 | `python3` | vault 경로 반영·훅 연결을 손으로 해야 한다 |
| 권장 | `PyYAML` (`pip install pyyaml`) | 컨피그 검증만 건너뛴다 (`HRN-W015`) |
| 실행체 | [Claude Code](https://claude.com/claude-code) | 경고만 (`HRN-W013`) — 설치는 끝난다 |
| 선택 | [superpowers](https://github.com/obra/superpowers-marketplace) | 그 스킬을 쓰는 구간만 스킬 없이 돈다 (`HRN-W014`) |

superpowers 설치: `/plugin marketplace add obra/superpowers-marketplace` →
`/plugin install superpowers`. 안 쓰려면 `harness.config.yaml`의 `stages[].skills`에서
`superpowers:` 항목을 지운다.

## 설치

```bash
git clone https://github.com/Immamakeit/kgh-harness.git ~/.kgh-harness
~/.kgh-harness/install/setup ~/dev/내프로젝트
```

설치 경로와 Obsidian vault를 물어본다. 질문마다 기본값이 붙어 있어 Enter로 넘길 수 있다.
`install/setup --help`로 동작을 볼 수 있다.

## 설치 후

```bash
cd ~/dev/내프로젝트
.harness/install/validate-config     # "검증 통과"면 정상
```

이 프로젝트에서 Claude Code를 새로 시작하면 첫 컨텍스트에 워크플로가 실려 있다.
그다음은 평소처럼 작업을 지시하면 된다.

## 초기 세팅

`PRD.md`·`CLAUDE.md`·`AGENTS.md` 가 없으면 세션 시작 때 하네스가 먼저 묻는다.
"지금 한다"를 고르면 질문에 답하는 것만으로 세 문서가 만들어진다.

1. 무엇을 · 왜 (3문항) → 2. 스택 고르기 → 3. 작업 규칙 (6문항)

- 모든 질문에 기본값이 있다. Enter로 넘기면 기본값으로 간다.
- 마음에 드는 선택지가 없으면 **직접 입력**, 안 정하고 싶으면 **건너뛰기** 를 고른다.
- 이미 문서가 있으면 목록을 보여주고 어떻게 할지 묻는다. 덮어쓰기 전에 백업한다.
- 문서만 만든다. 설치·초기화는 하지 않는다.

아무 때나 다시 부를 수 있다. 이미 있는 문서를 갈아엎을 때도 이 길로 간다.

```
초기 세팅 해줘
```

매번 묻는 게 싫으면 `harness.config.yaml` 에서 끈다.

```yaml
bootstrap:
  prompt: off
```

에이전트는 `.harness/skills/set-initial/SKILL.md` 를 읽고 그대로 따르면 된다.

## 브랜치 보호

GitHub 원격 저장소에 main 직접 푸시 금지·PR 필수 규칙을 걸어준다. **세션 시작
때 먼저 제안하지 않는다** — 명시적으로 요청할 때만 실행된다.

```
브랜치 보호 설정해줘
```

- 적용 전에 현재 상태(보호 없음/있음)와 위협 모델을 있는 그대로 보여준다
  ("PUBLIC이라도 협력자 아닌 사람은 애초에 push 불가" 등 — 과장하지 않는다).
- 표준/최소/엄격 중 고르거나 직접 입력한다. 협력자가 1명뿐이면 승인 인원 기본값을
  0으로 낮추고, "엄격"을 고르면 자기잠금 위험을 경고한다.
- 실제로 보낼 요청 내용을 미리 보여준 뒤에만 적용 여부를 묻는다(기본: 적용 안 함).
- 적용 전 상태를 저장해두고, 되돌리는 명령을 항상 알려준다.
- `CLAUDE.md`는 건드리지 않는다 — 문서와 실제 설정이 어긋나면 안내만 하고,
  고치는 건 초기 세팅(`set-initial`) 쪽에서 한다.
- v1은 GitHub·`main` 계열 브랜치 1개만 지원한다.

에이전트는 `.harness/skills/branch-strategy/SKILL.md` 를 읽고 그대로 따르면 된다.

## 설치되는 것

```
<프로젝트>/
├─ harness.config.yaml        # 설정 — 직접 고쳐 쓴다
├─ .claude/settings.json      # SessionStart 훅 추가 (기존 설정은 그대로 둔다)
└─ .harness/
   ├─ core/playbook.md        # 세션에 주입되는 워크플로 본문
   ├─ adapters/claude/        # Claude Code 어댑터
   ├─ skills/                 # 하네스 스킬 9종
   ├─ templates/              # 문서 서식 3종
   ├─ config/schema.yaml      # 컨피그 스키마
   ├─ install/                # setup · update · validate-config
   └─ work/                   # 작업 문서 (첫 작업 때 생긴다)
```

## 업데이트

```bash
cd ~/dev/내프로젝트
.harness/install/update
```

하네스만 최신으로 바꾼다. `harness.config.yaml`은 건드리지 않고, 새 설정 항목이 생기면
알려만 준다. `.harness/work/`의 문서도 그대로 둔다.

## 제거

```bash
rm -rf ~/dev/내프로젝트/.harness ~/dev/내프로젝트/harness.config.yaml
```

`.claude/settings.json`의 SessionStart 훅 항목은 직접 지운다.

## 설정

`harness.config.yaml`은 흐름이 시작될 때마다 다시 읽는다. 고치면 바로 먹는다.

| 키 | 뜻 |
|---|---|
| `active_harness` | 실행체. 지금은 `claude`만 된다 |
| `defaults.model` | 구간이 모델을 안 정했을 때 쓸 값 |
| `workdocs.path` | 작업 문서 위치 (기본 `.harness/work`) |
| `storage.vault_root` | Obsidian vault 절대경로. `null`이면 저장하지 않는다 |
| `bootstrap.prompt` | `ask` 면 문서가 없을 때 초기 세팅을 제안한다. `off` 면 안 묻는다 |
| `agent_mode` | `multi`(기본)면 일부 구간을 서브에이전트로 돌린다. `single`이면 전부 메인 세션에서 한다 |
| `preferences.write_to` | 선택 이력을 어디에 쌓을지. `global`(기본)은 `~/.claude/harness/`, `project`는 `<프로젝트>/.harness/` |
| `preferences.as_recommended` | `true`면 번호 선택형 질문을 추천대로 자동 채택하고 무엇을 왜 골랐는지 표로 남긴다. 기본은 `false` |
| `stages.<구간>.gate` | `required`면 사용자 승인까지 멈춘다 |
| `stages.<구간>.skills` | 그 구간에서 쓸 스킬 |

고친 뒤에는 `.harness/install/validate-config`로 검증한다.

> **모르는 값을 만나면 어떻게 되나** — 검증기는 위 세 키의 *값*까지는 검사하지 않는다.
> 오타를 냈을 때 어느 쪽으로 떨어지는지는 키마다 다르고, 기준은 하나다: **덜 놀라운 쪽.**
> `agent_mode`는 `single`이 아니면 `multi`(하던 대로), `bootstrap.prompt`는 `off`가
> 아니면 `ask`(한 번 더 묻는다), `preferences.write_to`는 `project`가 아니면
> `global`(남의 git 히스토리에 이력을 흘리지 않는다), `preferences.as_recommended`는
> `true`가 아니면 `false`(질문을 건너뛰지 않는다).

## 에러 코드

모든 실패는 `HRN-Exxx`(멈춤) 또는 `HRN-Wxxx`(경고) 코드와 복구 방법 두 가지를 함께 낸다.

| 코드 | 뜻 | 첫 조치 |
|---|---|---|
| `HRN-E005` | 필수 파일이 없다 | 클론 상태 확인 후 `install/update` |
| `HRN-E007` | 대상 경로 문제 (권한, 또는 하네스 자신을 지정) | 프로젝트 경로를 인자로 넘긴다 |
| `HRN-E008` | 필요한 CLI가 없다 (rsync 등) | 그 CLI를 설치한다 |
| `HRN-E010` | 아직 없는 어댑터를 지정했다 | `active_harness: claude` |
| `HRN-W010` | vault 경로가 비어 있다 | 컨피그에 경로를 넣는다 (문서는 로컬에 쌓인다) |
| `HRN-W014` | superpowers가 없다 | 플러그인을 깔거나 컨피그에서 뺀다 |

## 한계

- Obsidian vault 자동 찾기는 WSL에서만 된다. macOS·Linux에서는 경로를 직접 넣는다.
- `codex`·`ollama` 어댑터는 아직 없다. 지금은 Claude Code 전용이다.
- 하네스 자신에 설치하는 것은 아직 안 된다.

## 라이선스

MIT — [LICENSE](LICENSE)
