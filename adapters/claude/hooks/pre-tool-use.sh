#!/usr/bin/env bash
#
# kgh-harness PreToolUse 훅 — ⑤ 설계 승인 게이트의 **집행체**.
#
# 플레이북 §2 는 "⑤ 승인 전 구현 금지"를 어떤 경우에도 생략 불가로 선언한다. 이 훅이
# 없으면 그 선언은 프롬프트 텍스트일 뿐이고, 긴 세션에서 모델이 표류하면 그냥 구현한다.
#
# 무장 신호를 **파일에서 유도한다** (상태 파일·모델의 선언 없음):
#   <workdocs.path>/<작업명>/<날짜>/ 에 설계 문서가 있고 .approved 가 없으면 → 승인 대기.
# ⑤ 설계는 문서를 생산하는 구간이므로(플레이북 §5), 흐름이 ⑤를 지나면 무장은 모델의
# 협조 없이 자동으로 일어난다. 이것이 이 설계의 핵심이다.
#
# 한계를 과장하지 않는다: 셸 경유 임의 수정(`python - <<EOF`, `cat >` 등)까지 전부
# 봉쇄하지는 못한다. **표류를 잡는 장치지 적대적 우회를 막는 장치가 아니다.**
#
# 설치 스크립트에 의존하지 않는다(install/lib.sh 를 source 하지 않는다) — 설치가 깨져도
# 게이트는 살아 있어야 하고, 매 도구 호출의 비용을 최소로 둬야 한다.
#
# 종료코드 계약 (Claude Code PreToolUse): 0 = 통과, 2 = 차단(stderr 가 모델에게 전달됨).
# -e 를 쓰지 않는다: 게이트 자체의 어떤 실패도 작업을 세우지 않는다(fail-open, HRN-W021).
#
# ⚠️ 출력 경로의 실측 제약 (공식 훅 문서):
#   "Claude never sees stderr from a hook that exits 0. To read it yourself on events
#    such as PreToolUse, enable debug logging."
# 즉 **exit 0 + stderr 는 사용자도 모델도 못 본다** — 디버그 로깅을 켠 사람만 본다.
# 그래서 통과시키면서 알려야 하는 모든 경고는 세 경로로 낸다:
#   (1) .harness/gate.log 파일 기록 — 확실하다. 이것이 중심이다.
#   (2) stdout JSON 의 systemMessage(사용자) · hookSpecificOutput.additionalContext(모델)
#       — PreToolUse 에서 실제로 표시되는지는 **미확인**이라 보조로만 쓴다.
#   (3) stderr — 디버그 로깅 사용자용. 비용 0 이라 남긴다.
# 차단(exit 2)은 stderr 가 모델에게 전달되는 것이 문서로 확인되므로 그대로 둔다.
set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"      # stdin 은 항상 먼저 비운다(SIGPIPE 방지)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
CONFIG="${PROJECT_DIR}/harness.config.yaml"

GATE_LOG="${PROJECT_DIR}/.harness/gate.log"
GATE_NOTES=""

# 통과 경로에서 전달할 경고를 모아둔다. 즉시 내지 않는 이유: 뒤에서 차단(exit 2)으로
# 끝날 수도 있고, 그때는 stdout JSON 이 아니라 **차단 메시지 본문**에 섞어야 모델이 본다.
note() { GATE_NOTES="${GATE_NOTES}${GATE_NOTES:+ · }$1"; }

# 확실한 경로. 이 함수의 실패는 **조용히 넘긴다** — 로그를 못 써서 게이트가 작업을 세우면
# fail-open 의 취지를 거스른다. 이 설계가 허용하는 유일한 침묵이고, 그래서 침묵을
# 여기 한 곳에 **가둬** 둔다. 다른 어떤 경로도 조용히 끝나지 않는다.
log_gate() {
  local tool target
  tool="$(printf '%s' "$INPUT" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[A-Za-z_]+"' | head -n1 | grep -oE '[A-Za-z_]+"$' | tr -d '"')"
  target="$(printf '%s' "$INPUT" | grep -oE '"(file_path|command)"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*:[[:space:]]*"//; s/"$//')"
  mkdir -p "$(dirname "$GATE_LOG")" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Iseconds 2>/dev/null || date 2>/dev/null || echo '?')" \
    "$1" "$2" "${tool:-?}" "${target:-?}" >> "$GATE_LOG" 2>/dev/null || true
}

# 통과(exit 0)로 끝내면서 모아둔 경고를 세 경로로 낸다.
pass_with_notes() {
  [ -n "$GATE_NOTES" ] || exit 0
  # permissionDecision 은 **넣지 않는다**: "allow" 는 권한 프롬프트를 건너뛴다. fail-open 의
  # 뜻은 "훅이 없는 것처럼 진행"이지 권한 승격이 아니다 — 게이트 고장이 안전한 쪽이 아니라
  # 반대쪽으로 실패하게 만들면 안 된다.
  if command -v python3 >/dev/null 2>&1; then
    GATE_MSG="$GATE_NOTES" python3 -I -c 'import json,os
m = os.environ["GATE_MSG"]
print(json.dumps({"systemMessage": m,
                  "hookSpecificOutput": {"hookEventName": "PreToolUse",
                                         "additionalContext": m}},
                 ensure_ascii=False))' 2>/dev/null || true
  fi
  printf '%s\n' "$GATE_NOTES" >&2
  exit 0
}

fail_open() {   # HRN-W021 — 판정 전제 미충족. 통과시키고 사실을 세 경로로 알린다.
  log_gate "W021" "fail-open: $1"
  note "⚠️ HRN-W021 — 승인 게이트 판정 전제 미충족($1) — 이번 호출은 통과시킵니다. 조치: (a) 위 사유를 고친 뒤 재시도 (b) 게이트 없이 진행 — 게이트 고장이 작업을 세우지 않습니다. 기록: ${GATE_LOG}"
  pass_with_notes
}

# ---- YAML 스칼라 읽기 (중첩 경로 지원, 2칸 들여쓰기 전제) --------------------
# 외부 의존 없이 돌아야 한다 — 이 훅은 매 도구 호출마다 실행된다.
yaml_get() {
  local file="$1" path="$2"
  [ -f "$file" ] || return 1
  awk -v path="$path" '
    { raw = $0
      sub(/#.*$/, "", raw)
      if (raw ~ /^[[:space:]]*$/) next
      n = match(raw, /[^ ]/); if (n == 0) next
      ind = n - 1
      rest = substr(raw, n)
      if (substr(rest, 1, 1) == "-") next
      ci = index(rest, ":"); if (ci == 0) next
      key = substr(rest, 1, ci - 1)
      val = substr(rest, ci + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", val)
      gsub(/^"|"$/, "", val); gsub(/^'"'"'|'"'"'$/, "", val)
      lvl = int(ind / 2)
      stack[lvl] = key
      for (i = lvl + 1; i < 10; i++) stack[i] = ""
      cur = stack[0]
      for (i = 1; i <= lvl; i++) cur = cur "." stack[i]
      if (cur == path && val != "") { print val; exit }
    }' "$file"
}

# ---- 1. 모드 판정 -----------------------------------------------------------
# §1-5 해석 원칙: off·warn 이 아닌 모든 값(부재·오타 포함)은 block.
# 안전 방향이 "멈춘다"쪽인 이유 — 승인 없이 구현이 나가는 쪽이, 한 번 더 멈춰서
# approve 를 실행하게 하는 쪽보다 훨씬 놀랍다.
MODE="$(yaml_get "$CONFIG" "gate.enforce" 2>/dev/null || true)"
case "$MODE" in
  off)  exit 0 ;;
  warn) MODE="warn" ;;
  *)    MODE="block" ;;
esac

# ---- 2. 무장 판정 (순수 bash 빠른 길 — 평시 비용 거의 0) --------------------
WORKDOCS="$(yaml_get "$CONFIG" "workdocs.path" 2>/dev/null || true)"
[ -n "$WORKDOCS" ] || WORKDOCS=".harness/work"
DESIGN="$(yaml_get "$CONFIG" "workdocs.names.design" 2>/dev/null || true)"
[ -n "$DESIGN" ] || DESIGN="설계.md"

case "$WORKDOCS" in
  /*) WORKROOT="$WORKDOCS" ;;
  *)  WORKROOT="${PROJECT_DIR}/${WORKDOCS}" ;;
esac

[ -d "$WORKROOT" ] || exit 0            # 작업 디렉터리가 없다 = 흐름이 시작된 적 없다

PENDING=""
# layout 은 컨피그로 바뀔 수 있으므로 깊이를 고정하지 않고 설계 문서를 직접 찾는다.
while IFS= read -r design_file; do
  [ -n "$design_file" ] || continue
  d="$(dirname "$design_file")"
  [ -f "${d}/.approved" ] && continue
  PENDING="$(basename "$(dirname "$d")")"
  [ -n "$PENDING" ] || PENDING="$(basename "$d")"
  PENDING_DIR="$d"
  break
done < <(find "$WORKROOT" -mindepth 1 -maxdepth 4 -type f -name "$DESIGN" 2>/dev/null)

[ -n "$PENDING" ] || exit 0             # 승인 대기 작업 없음 → 미무장. 즉시 통과.

# ---- 3. 차단 판정 (무장 상태에서만 비용을 낸다) -----------------------------
VERDICT=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DECIDER="${SCRIPT_DIR}/gate_decide.py"
if command -v python3 >/dev/null 2>&1 && [ -f "$DECIDER" ]; then
  # -I: 격리 모드. 훅은 임의 디렉터리에서 돌고 sys.path[0] 오염을 받을 이유가 없다.
  VERDICT="$(printf '%s' "$INPUT" | python3 -I "$DECIDER" "$WORKROOT" "$PROJECT_DIR" 2>/dev/null)"
fi

if [ -z "$VERDICT" ]; then
  # python3 부재·실패 → 휴리스틱으로 열화한다. 열화 사실을 숨기지 않는다.
  TOOL_H="$(printf '%s' "$INPUT" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[A-Za-z_]+"' | head -n1 | grep -oE '"[A-Za-z_]+"$' | tr -d '"')"
  case "$TOOL_H" in
    Edit|Write|MultiEdit|NotebookEdit|Update)
      PATH_H="$(printf '%s' "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*:[[:space:]]*"//; s/"$//')"
      case "$PATH_H" in
        "$WORKROOT"/*|"$WORKDOCS"/*) VERDICT="ALLOW	작업 문서 안(휴리스틱)" ;;
        *) VERDICT="BLOCK	${TOOL_H}	${PATH_H:-대상 미상}" ;;
      esac
      ;;
    *) VERDICT="ALLOW	쓰기 도구 아님(휴리스틱)" ;;
  esac
  # 즉시 내지 않고 모아둔다 — 이 경로는 아래에서 차단(exit 2)으로 끝날 수도 있고,
  # 그때는 stdout JSON 이 아니라 차단 메시지 본문에 섞어야 모델이 본다.
  log_gate "W021" "휴리스틱 열화: python3 부재 또는 판정기 실패"
  note '⚠️ HRN-W021 — python3 가 없어 게이트가 휴리스틱 판정으로 열화했습니다. 조치: (a) python3 를 설치하면 정확 판정으로 돌아옵니다 (b) 그대로 진행 — 판정은 보수적입니다.'
fi

case "$VERDICT" in
  UNKNOWN*) fail_open "$(printf '%s' "$VERDICT" | cut -f2-)" ;;
  ALLOW*)   pass_with_notes ;;   # 모아둔 경고가 없으면 stdout 은 비어 있다(잡음 금지)
esac

BLOCKED_TOOL="$(printf '%s' "$VERDICT" | cut -f2)"
BLOCKED_WHAT="$(printf '%s' "$VERDICT" | cut -f3)"

if [ "$MODE" = "warn" ]; then
  # 구현 중 발견: 이 경로도 exit 0 + stderr 였다 — 즉 warn 모드의 경고를 아무도 보지
  # 못했고, 그러면 warn 모드는 사실상 off 와 같다. fail_open 과 같은 세 경로로 낸다.
  log_gate "E016" "warn 모드 통과: ${PENDING}"
  note "$(printf '⚠️ HRN-E016(warn) — ⑤ 설계 승인 전 구현입니다 (승인 대기: %s). gate.enforce 가 warn 이라 통과시킵니다. 차단되지 않은 조작: %s %s' "$PENDING" "$BLOCKED_TOOL" "$BLOCKED_WHAT")"
  pass_with_notes
fi

# 안내할 approve 경로를 **실제로 해석한다** (설계 §3-5). 하드코딩하면 소스 레포를
# 도그푸딩할 때 없는 경로(.harness/install/approve)를 안내한다 — 실측으로 확인했다.
# session-start.sh 와 같은 후보 탐색이다.
log_gate "E016" "차단: ${PENDING}"

APPROVE_CMD=".harness/install/approve"
for _cand in "$SCRIPT_DIR/../../.." "$SCRIPT_DIR/../.." "$SCRIPT_DIR/.."; do
  if [ -x "$_cand/install/approve" ]; then
    APPROVE_CMD="$(cd "$_cand" && pwd)/install/approve"
    break
  fi
done

{
  printf '❌ HRN-E016 — ⑤ 설계 승인 전에는 구현할 수 없습니다 (승인 대기: %s)\n' "$PENDING"
  printf '   차단된 조작: %s %s\n' "$BLOCKED_TOOL" "$BLOCKED_WHAT"
  printf '   설계 문서  : %s/%s\n' "$PENDING_DIR" "$DESIGN"
  # 모아둔 경고(휴리스틱 열화 등)를 차단 메시지에 섞는다 — exit 2 의 stderr 는 모델에게
  # 전달되는 것이 문서로 확인된 유일한 경로다.
  [ -n "$GATE_NOTES" ] && printf '   %s\n' "$GATE_NOTES"
  printf '   조치: (a) 사용자에게 설계를 제시해 승인을 받은 뒤 `%s %s` 를 실행하십시오\n' "$APPROVE_CMD" "$PENDING"
  printf '         (b) 이 작업에 게이트를 적용하지 않으려면 harness.config.yaml 의 gate.enforce 를 off 로 바꾸십시오\n'
  printf '   (작업 문서 자체는 계속 쓸 수 있습니다 — %s 밑은 차단 대상이 아닙니다)\n' "$WORKDOCS"
} >&2
exit 2
