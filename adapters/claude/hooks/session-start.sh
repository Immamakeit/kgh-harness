#!/usr/bin/env bash
#
# kgh-harness SessionStart 훅 — 얇은 방아쇠.
# 하는 일 딱 하나: 지휘 플레이북 + 프로젝트 컨피그를 세션 컨텍스트로 주입한다.
# 해석·검증·디스패치는 전부 플레이북 지침에 따라 메인 세션이 수행한다 (설계 A안).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 플레이북 탐색 — 소스 레포 배치(adapters/claude/hooks/ 기준)와 설치 배치 모두 지원
PLAYBOOK=""
for cand in \
  "$SCRIPT_DIR/../../../core/playbook.md" \
  "$SCRIPT_DIR/../../core/playbook.md" \
  "$SCRIPT_DIR/../core/playbook.md"; do
  if [ -f "$cand" ]; then PLAYBOOK="$cand"; break; fi
done

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
CONFIG="$PROJECT_DIR/harness.config.yaml"

# 기반 문서 유무 — 사실만 보고한다. 제안 여부·문구는 플레이북이 정한다.
# "없음" = 파일이 없거나 공백뿐. 내용의 품질은 판정하지 않는다(오검출 방지).
doc_state() {
  if [ -f "$1" ] && grep -q '[^[:space:]]' "$1" 2>/dev/null; then
    printf '있음'
  else
    printf '없음'
  fi
}

echo "<harness-orchestrator>"

if [ -z "$PLAYBOOK" ]; then
  echo "❌ HRN-E005 — 지휘 플레이북(core/playbook.md)을 찾지 못했습니다. 하네스 설치가 손상됐을 수 있습니다."
  echo "조치: (a) install/update 재실행 (b) 하네스 소스에서 core/playbook.md 복원"
  echo "이번 세션은 하네스 흐름 없이 진행하되, 사용자에게 위 사실을 첫 응답에서 알리십시오."
else
  cat "$PLAYBOOK"
  echo
  echo "## 프로젝트 기반 문서 상태"
  printf 'PRD.md: %s · CLAUDE.md: %s · AGENTS.md: %s\n' \
    "$(doc_state "$PROJECT_DIR/PRD.md")" \
    "$(doc_state "$PROJECT_DIR/CLAUDE.md")" \
    "$(doc_state "$PROJECT_DIR/AGENTS.md")"
  echo
  if [ -f "$CONFIG" ]; then
    echo "## 프로젝트 컨피그 (harness.config.yaml 원문 — 흐름 시작 시 파일을 다시 읽을 것)"
    echo '```yaml'
    cat "$CONFIG"
    echo '```'
  else
    echo "⚠️ HRN-W012 — 이 프로젝트에 harness.config.yaml이 없습니다 (탐색 위치: $CONFIG)."
    echo "플레이북 §2의 기본 실행표로 흐름을 진행하되, 첫 흐름 시작 보고에서 사용자에게"
    echo "install/setup으로 컨피그를 생성할 수 있음을 안내하십시오. (비차단)"
  fi
fi

echo "</harness-orchestrator>"
