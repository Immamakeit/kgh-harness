#!/usr/bin/env bash
#
# kgh-harness SessionStart 훅 — 얇은 방아쇠.
# 하는 일 딱 하나: 세션 컨텍스트에 "무엇을 읽어야 하는지"를 주입한다.
# 해석·검증·디스패치는 전부 플레이북 지침에 따라 메인 세션이 수행한다 (설계 A안).
#
# injection.mode (컨피그):
#   router(기본) — core/router.md(짧은 판별표) + 기반 문서 상태 + 컨피그/플레이북 **경로**.
#     흐름을 시작할 때 모델이 playbook.md 전문을 직접 읽는다(지연 적재).
#     옛 방식은 매 세션 16,450자(플레이북 전문 11,899 + 컨피그 원문 4,371)를 선불했고,
#     "오타 고쳐줘" 세션도 같은 값을 냈다. 플레이북 §1 자신이 "컨피그는 흐름 시작마다
#     다시 읽는다, 캐시 금지"라고 하므로 원문 주입은 자기모순이기도 했다.
#   full — 옛 동작. 플레이북 전문 + 컨피그 원문을 주입한다.
#   해석 규칙(§1-5): full 이 아닌 모든 값(부재·오타 포함)은 router.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 하네스 루트 탐색 — 소스 레포 배치(adapters/claude/hooks/ 기준)와 설치 배치 모두 지원
HARNESS_ROOT=""
for cand in \
  "$SCRIPT_DIR/../../.." \
  "$SCRIPT_DIR/../.." \
  "$SCRIPT_DIR/.."; do
  if [ -f "$cand/core/playbook.md" ]; then HARNESS_ROOT="$(cd "$cand" && pwd)"; break; fi
done

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
CONFIG="$PROJECT_DIR/harness.config.yaml"

# 컨피그에서 주입 모드만 읽는다. 외부 의존 없이(awk) — install/lib.sh 의 yaml_get 과
# 같은 최소 파서다. 훅이 설치 스크립트에 의존하지 않게 복제해 둔다.
read_mode() {
  [ -f "$CONFIG" ] || return 0
  awk '
    { raw = $0; sub(/#.*$/, "", raw)
      if (raw ~ /^[[:space:]]*$/) next
      n = match(raw, /[^ ]/); if (n == 0) next
      rest = substr(raw, n)
      if (int((n - 1) / 2) == 0) { top = (index(rest, ":") ? substr(rest, 1, index(rest, ":") - 1) : "") ; next }
      if (top != "injection") next
      ci = index(rest, ":"); if (ci == 0) next
      if (substr(rest, 1, ci - 1) != "mode") next
      val = substr(rest, ci + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", val)
      if (val != "") { print val; exit }
    }' "$CONFIG"
}

# 기반 문서 유무 — 사실만 보고한다. 제안 여부·문구는 플레이북/라우터가 정한다.
# "없음" = 파일이 없거나 공백뿐. 내용의 품질은 판정하지 않는다(오검출 방지).
doc_state() {
  if [ -f "$1" ] && grep -q '[^[:space:]]' "$1" 2>/dev/null; then
    printf '있음'
  else
    printf '없음'
  fi
}

echo "<harness-orchestrator>"

if [ -z "$HARNESS_ROOT" ]; then
  echo "❌ HRN-E005 — 지휘 플레이북(core/playbook.md)을 찾지 못했습니다. 하네스 설치가 손상됐을 수 있습니다."
  echo "조치: (a) install/update 재실행 (b) 하네스 소스에서 core/playbook.md 복원"
  echo "이번 세션은 하네스 흐름 없이 진행하되, 사용자에게 위 사실을 첫 응답에서 알리십시오."
else
  MODE="$(read_mode || true)"
  [ "$MODE" = "full" ] || MODE="router"

  if [ "$MODE" = "router" ] && [ -f "$HARNESS_ROOT/core/router.md" ]; then
    cat "$HARNESS_ROOT/core/router.md"
    echo
    echo "## 이 프로젝트의 경로 (절대경로 — 그대로 Read 하십시오)"
    printf -- '- 플레이북(흐름 시작 시 **반드시 먼저 읽을 것**): %s\n' "$HARNESS_ROOT/core/playbook.md"
    printf -- '- 컨피그(흐름 시작마다 다시 읽을 것): %s\n' "$CONFIG"
    printf -- '- 하네스 스킬: %s\n' "$HARNESS_ROOT/skills/<이름>/SKILL.md"
    printf -- '- 승인 명령: %s <작업명>\n' "$HARNESS_ROOT/install/approve"
    if [ ! -f "$CONFIG" ]; then
      echo
      echo "⚠️ HRN-W012 — 이 프로젝트에 harness.config.yaml이 없습니다 (탐색 위치: $CONFIG)."
      echo "플레이북 §2의 기본 실행표로 흐름을 진행하되, 첫 흐름 시작 보고에서 사용자에게"
      echo "install/setup으로 컨피그를 생성할 수 있음을 안내하십시오. (비차단)"
    fi
  else
    if [ "$MODE" = "router" ]; then
      echo "⚠️ HRN-W021 — core/router.md 를 찾지 못해 플레이북 전문 주입으로 되돌립니다."
      echo "조치: (a) install/update 로 router.md 를 받으세요 (b) 그대로 진행 — 동작은 같고 토큰만 더 씁니다."
    fi
    cat "$HARNESS_ROOT/core/playbook.md"
    if [ -f "$CONFIG" ]; then
      echo
      echo "## 프로젝트 컨피그 (harness.config.yaml 원문 — 흐름 시작 시 파일을 다시 읽을 것)"
      echo '```yaml'
      cat "$CONFIG"
      echo '```'
    else
      echo
      echo "⚠️ HRN-W012 — 이 프로젝트에 harness.config.yaml이 없습니다 (탐색 위치: $CONFIG)."
      echo "플레이북 §2의 기본 실행표로 흐름을 진행하되, 첫 흐름 시작 보고에서 사용자에게"
      echo "install/setup으로 컨피그를 생성할 수 있음을 안내하십시오. (비차단)"
    fi
  fi

  echo
  echo "## 프로젝트 기반 문서 상태"
  printf 'PRD.md: %s · CLAUDE.md: %s · AGENTS.md: %s\n' \
    "$(doc_state "$PROJECT_DIR/PRD.md")" \
    "$(doc_state "$PROJECT_DIR/CLAUDE.md")" \
    "$(doc_state "$PROJECT_DIR/AGENTS.md")"
fi

echo "</harness-orchestrator>"
