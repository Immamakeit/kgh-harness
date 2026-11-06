#!/usr/bin/env bash
# install/lib.sh — install/setup · install/update 공용 함수.
# interactive-script 스킬 표준: 색상 안내/성공/주의/오류, 대화형+디폴트(비TTY 폴백),
# HRN 에러 포맷터, .harnessignore 기반 배포 복사.
#
# source하는 스크립트가 `set -euo pipefail`을 이미 걸었다고 가정한다.
# 이 파일 자체는 실행되지 않고 source 전용이다.

# ---- 색상 출력 -------------------------------------------------------------

if [ -t 1 ]; then
  _C_INFO=$'\033[36m'; _C_OK=$'\033[32m'; _C_WARN=$'\033[33m'; _C_ERR=$'\033[31m'; _C_RESET=$'\033[0m'
else
  _C_INFO=''; _C_OK=''; _C_WARN=''; _C_ERR=''; _C_RESET=''
fi

say()  { printf '%s%s%s\n' "$_C_INFO" "$*" "$_C_RESET"; }
ok()   { printf '%s%s%s\n' "$_C_OK" "$*" "$_C_RESET"; }
warn() { printf '%s%s%s\n' "$_C_WARN" "$*" "$_C_RESET" >&2; }
err()  { printf '%s%s%s\n' "$_C_ERR" "$*" "$_C_RESET" >&2; }
# note: say와 같은 색이지만 stderr로 나간다. ask/ask_yn처럼 함수의 stdout이
# $(...)로 캡처되어 반환값으로 쓰이는 곳의 내부 로그는 반드시 이걸 쓴다
# (stdout에 섞으면 반환값이 오염된다).
note() { printf '%s%s%s\n' "$_C_INFO" "$*" "$_C_RESET" >&2; }

# ---- 대화형 + 디폴트 (비TTY 폴백) ------------------------------------------

# ask "질문 문구" "디폴트값"  → 응답을 stdout으로 echo
# stdin이 TTY가 아니면(비대화형: CI 등) 디폴트를 채택하고 그 사실을 로그한다.
ask() {
  local prompt="$1" default="$2" ans
  if [ -t 0 ]; then
    read -rp "${prompt} [기본: ${default:-없음}] " ans
    printf '%s\n' "${ans:-$default}"
  else
    note "(비대화형) ${prompt} → 디폴트 적용: ${default:-없음}"
    printf '%s\n' "$default"
  fi
}

# ask_yn "질문 문구" "Y|N(디폴트)"  → "Y" 또는 "N"을 stdout으로 echo
ask_yn() {
  local prompt="$1" default="${2:-Y}" ans hint
  hint="[Y/n]"
  [ "$default" = "N" ] && hint="[y/N]"
  if [ -t 0 ]; then
    read -rp "${prompt} ${hint} " ans
    ans="${ans:-$default}"
  else
    note "(비대화형) ${prompt} → 디폴트 적용: ${default}"
    ans="$default"
  fi
  case "$ans" in
    [Yy]*) printf 'Y\n' ;;
    *) printf 'N\n' ;;
  esac
}

# ask_choice "질문 문구" "기본번호" "선택지1" "선택지2" ...
#   → 선택된 번호(1-based)를 stdout으로 echo
#
# 라벨이 아니라 번호를 반환한다 — 호출부가 자기 배열을 인덱싱하게 해서
# 표시 문자열과 값이 엉키지 않게 한다.
#
# ⚠ stdout은 $(...)로 캡처된다. 목록·안내는 전부 stderr로 나간다.
#   (위 note() 주석 참조 — 같은 함정이다)
ask_choice() {
  local prompt="$1" default="$2"
  shift 2
  local -a opts=("$@")
  local n=${#opts[@]} i ans tries=0

  if [ "$n" -eq 0 ]; then
    note "(선택지 없음) ${prompt} → 기본값 적용: ${default}"
    printf '%s\n' "$default"
    return 0
  fi

  # 기본번호 검증 — 호출부 실수를 조용히 통과시키지 않는다.
  if ! printf '%s' "$default" | grep -qE '^[0-9]+$' || \
     [ "$default" -lt 1 ] || [ "$default" -gt "$n" ]; then
    warn "ask_choice: 기본번호 '${default}' 가 1~${n} 범위 밖입니다 — 1로 보정합니다."
    default=1
  fi

  if [ ! -t 0 ]; then
    note "(비대화형) ${prompt} → 기본 선택 적용: ${default}) ${opts[$((default - 1))]:-}"
    printf '%s\n' "$default"
    return 0
  fi

  while :; do
    printf '%s\n' "$prompt" >&2
    for ((i = 0; i < n; i++)); do
      if [ "$((i + 1))" = "$default" ]; then
        printf '  %d) %s   [기본]\n' "$((i + 1))" "${opts[$i]}" >&2
      else
        printf '  %d) %s\n' "$((i + 1))" "${opts[$i]}" >&2
      fi
    done
    if ! read -rp "번호 입력 [${default}]: " ans; then
      note "(입력 종료) 기본값 ${default} 을(를) 적용합니다."
      printf '%s\n' "$default"
      return 0
    fi
    ans="${ans:-$default}"

    if printf '%s' "$ans" | grep -qE '^[0-9]+$' && [ "$ans" -ge 1 ] && [ "$ans" -le "$n" ]; then
      printf '%s\n' "$ans"
      return 0
    fi

    tries=$((tries + 1))
    if [ "$tries" -ge 3 ]; then
      warn "입력을 3회 인식하지 못했습니다 — 기본값 ${default}을(를) 적용합니다."
      printf '%s\n' "$default"
      return 0
    fi
    warn "1~${n} 사이의 번호를 입력하세요 (입력값: '${ans}')"
  done
}

# ---- 문자열 유틸 ------------------------------------------------------------

# join_lines <구분자>  — stdin의 줄들을 <구분자>로 이어붙여 stdout에 낸다(개행 없음).
# `paste -sd`는 구분자를 "문자 리스트"로 취급해 줄마다 한 글자씩 순환 삽입한다.
# 다중바이트 구분자(예: '·', UTF-8 2바이트)는 바이트 단위로 쪼개져 깨지고, 다문자
# 구분자(예: ', ')도 같은 이유로 순환되어 "a,b c,d"처럼 어긋난다(검증 루프 1회차
# F1/F2). 그래서 paste -d 대신 순수 셸 루프로 이어붙인다.
join_lines() {
  local sep="$1" first=1 line out=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" -eq 1 ]; then
      out="$line"
      first=0
    else
      out="${out}${sep}${line}"
    fi
  done
  printf '%s' "$out"
}

# ---- HRN 에러/경고 포맷터 ---------------------------------------------------

# hrn_err "E006" "메시지" "조치 1" "조치 2"
hrn_err() {
  local code="$1" msg="$2" a="${3:-}" b="${4:-}"
  err "HRN-${code} — ${msg}"
  [ -n "$a" ] && err "  조치 1: ${a}"
  [ -n "$b" ] && err "  조치 2: ${b}"
}

# hrn_warn "W010" "메시지" "안내문" ["안내문2"]
# 안내문을 1개만 주면 기존과 동일하게 "안내: ..." 한 줄. 2개를 주면(W014처럼 복구
# 경로가 2가지인 경고) "안내 1:"/"안내 2:" 두 줄로 나눠 출력한다.
hrn_warn() {
  local code="$1" msg="$2" a="${3:-}" b="${4:-}"
  warn "HRN-${code} — ${msg}"
  if [ -n "$a" ] && [ -n "$b" ]; then
    warn "  안내 1: ${a}"
    warn "  안내 2: ${b}"
  elif [ -n "$a" ]; then
    warn "  안내: ${a}"
  fi
}

# ---- .harnessignore 기반 배포 복사 -----------------------------------------

# harnessignore_patterns <소스경로>
# .harnessignore를 주석/공백 제거 후 한 줄씩 stdout으로 출력.
harnessignore_patterns() {
  local src="$1" file
  file="${src}/.harnessignore"
  [ -f "$file" ] || return 0
  grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$file" || true
}

# harness_copy <소스경로> <대상경로>
# .harnessignore 제외 목록을 적용해 소스 트리를 대상으로 복사한다. rsync 필수
# (cp 폴백 없음 — [B1, 2026-07-18] 폴백의 삭제 동기화 가드가 검증 5라운드에 걸쳐
# 사용자 work/를 지울 수 있는 위험 표면으로 실증되어, 위험 로직을 방어하는 대신
# 제거했다. 호출자(setup/update)는 이 함수를 부르기 전에 반드시 rsync 존재를
# 사전 점검에서 확인하고, 없으면 HRN-E008로 중단해야 한다 — 이 함수 자체는
# rsync가 있다고 가정하고 바로 사용한다).
# 변경된 파일 수를 stdout에 한 줄 숫자로 마지막에 출력한다(호출자가 캡처).
harness_copy() {
  local src="$1" dest="$2"
  mkdir -p "$dest"
  local -a excludes=()
  local pat
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    excludes+=(--exclude="$pat")
  done < <(harnessignore_patterns "$src")
  # work/·.meta·preferences.yaml은 target 전용 산출물이라 소스에 애초에 없지만,
  # 방어적으로 명시 제외.
  # --delete와 함께 쓰여도 --exclude에 매칭되는 항목은 rsync 기본 동작상 삭제 대상에서
  # 제외된다(rsync는 --delete-excluded가 아닌 한 제외 항목을 "안 보이는" 것으로 취급) —
  # 그래서 세 항목은 재복사에 소스 삭제분을 반영(F5)해도 항상 보존된다.
  # 앞에 "/"를 붙여 전송 루트 기준 최상위로 앵커링한다(G4) — 앵커가 없으면 rsync는
  # 임의 깊이의 동명 디렉토리(예: skills/foo/work/)까지 오제외할 수 있다.
  # preferences.yaml: preference-options 스킬이 write_to: project 일 때 대상에서 lazy
  # 생성하는 학습 파일이다. 대상에서만 자라므로 제외하지 않으면 update 마다 --delete로
  # 지워져 학습이 통째로 초기화된다(work/와 같은 성격 — 사용자 산출물).
  excludes+=(--exclude="/work/" --exclude="/.meta" --exclude="/preferences.yaml")
  local out count
  # --delete: 소스에서 삭제된 파일을 대상에서도 제거(F5). work/·.meta·기타 제외 목록은
  # 위 --exclude로 보호되므로 삭제되지 않는다.
  out="$(rsync -ai --delete "${excludes[@]}" "${src}/" "${dest}/")"
  [ -n "$out" ] && printf '%s\n' "$out" >&2
  count=0
  if [ -n "$out" ]; then
    count="$(printf '%s\n' "$out" | grep -c . || true)"
  fi
  printf '%s\n' "$count"
}

# ---- .meta 안전 파싱 (F1: source 무검증 실행 금지) --------------------------

# harness_meta_read <.meta 파일 경로>
# .meta를 절대 source하지 않는다(임의 코드 실행 PoC 방지). 화이트리스트
# key=value 파싱만 수행 — 허용 키: SOURCE_PATH, SOURCE_COMMIT, INSTALLED_AT,
# UPDATED_AT. 값은 그대로 문자열로만 대입되며(치환/실행 없음), 허용 키 밖의
# 줄이나 key=value 형태가 아닌 줄이 하나라도 있으면 파손으로 간주해 1을 반환한다
# (호출자가 HRN 안내를 낸다). 파일이 없으면 1을 반환한다.
# 성공 시 SOURCE_PATH/SOURCE_COMMIT/INSTALLED_AT/UPDATED_AT 변수를 호출자
# 스코프에 설정한다(호출자가 미리 선언한 디폴트는 파일에 없는 키에 한해 유지됨).
harness_meta_read() {
  local file="$1" line
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    # shellcheck disable=SC2034
    # 의도적으로 local 없이 대입 — 이 함수의 계약(위 주석)이 호출자 스코프에
    # SOURCE_PATH/SOURCE_COMMIT/INSTALLED_AT/UPDATED_AT을 설정하는 것이라, 여기서는
    # "사용되지 않음"으로 보이지만 실제 소비자는 setup·update의 전역 스코프다.
    case "$line" in
      SOURCE_PATH=*)   SOURCE_PATH="${line#SOURCE_PATH=}" ;;
      SOURCE_COMMIT=*) SOURCE_COMMIT="${line#SOURCE_COMMIT=}" ;;
      INSTALLED_AT=*)  INSTALLED_AT="${line#INSTALLED_AT=}" ;;
      UPDATED_AT=*)    UPDATED_AT="${line#UPDATED_AT=}" ;;
      *) return 1 ;;
    esac
  done < "$file"
  return 0
}

# ---- 컨피그 최상위 키 diff ---------------------------------------------------

# yaml_top_keys <yaml파일>  → 최상위(들여쓰기 없는) 키 목록을 정렬해 stdout
yaml_top_keys() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -oE '^[A-Za-z_][A-Za-z0-9_]*:' "$f" | sed 's/:$//' | sort -u || true
}

# ---- YAML 중첩 스칼라 읽기 ---------------------------------------------------

# yaml_get <yaml파일> <점 경로>  → 값을 stdout (없으면 빈 출력, 종료코드 0)
#   예: yaml_get harness.config.yaml workdocs.names.design  → 설계.md
#
# PyYAML 없이도 돌아야 하는 자리(설치·게이트)에서만 쓴다. 2칸 들여쓰기를 전제하는
# 최소 파서다 — 값에 ':' 나 '#' 가 들어가는 키(commit.format 등)에는 쓰지 않는다.
#
# ⚠ 같은 awk 가 adapters/claude/hooks/pre-tool-use.sh 에도 들어 있다. 의도적 중복이다 —
#   런타임 훅은 설치 스크립트에 의존하지 않아야 한다(설치가 깨져도 게이트는 살아 있어야
#   하고, 매 도구 호출 비용을 최소로 둬야 한다). 드리프트는 회귀가 고정한다
#   (tests/install/run-tests.sh "게이트 — 승인 마커 계약" 의 양쪽 일치 케이스).
yaml_get() {
  local file="$1" path="$2"
  [ -f "$file" ] || return 0
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

# workdocs_root <프로젝트경로>  → 작업 문서 루트 절대경로를 stdout
workdocs_root() {
  local target="$1" rel
  rel="$(yaml_get "${target}/harness.config.yaml" "workdocs.path")"
  [ -n "$rel" ] || rel=".harness/work"
  case "$rel" in
    /*) printf '%s\n' "$rel" ;;
    *)  printf '%s/%s\n' "$target" "$rel" ;;
  esac
}

# design_doc_name <프로젝트경로>  → 설계 문서 파일명을 stdout
design_doc_name() {
  local n
  n="$(yaml_get "${1}/harness.config.yaml" "workdocs.names.design")"
  [ -n "$n" ] || n="설계.md"
  printf '%s\n' "$n"
}

# write_approval_marker <작업디렉터리> <작업명> <승인경로> <설계문서명> [<프로젝트루트>]
# 마커는 **언제·어떤 경로로** 승인됐는지를 적는다. 모델이 마커를 만들 수는 있어도
# 조용히 만들 수는 없게 하는 것이 목적이다 — git diff 에 그대로 드러난다.
#
# 설계 문서 경로는 **프로젝트 루트 기준 상대경로**로 적는다. 절대경로를 적으면 마커가
# 커밋될 때 그 머신의 경로가 이력에 박힌다(실측: 스크래치패드 경로가 들어갔다).
write_approval_marker() {
  local dir="$1" task="$2" via="$3" design="$4" root="${5:-}" rel
  rel="$dir"
  if [ -n "$root" ]; then
    case "$dir" in "${root}/"*) rel="${dir#"${root}/"}" ;; esac
  fi
  {
    printf '# kgh-harness 승인 마커 — 이 파일이 있으면 그 작업은 ⑤ 승인을 통과한 것이다.\n'
    printf '# 지우면 그 작업은 다시 "승인 대기" 가 된다 (게이트 재무장).\n'
    printf '작업명=%s\n' "$task"
    printf '승인시각=%s\n' "$(date -Iseconds 2>/dev/null || date)"
    printf '승인경로=%s\n' "$via"
    printf '설계문서=%s\n' "${rel}/${design}"
  } > "${dir}/.approved"
}

# backfill_approvals <프로젝트경로>  → 백필한 개수를 stdout (로그는 stderr)
#
# 설계 §2-2 "부트스트랩 함정" 방어. 승인 마커 부재를 "승인 전"으로 읽는 게이트를
# 기존 프로젝트에 얹으면, **이미 끝난 작업 전부가 승인 대기로 판정되어 설치 직후 모든
# 편집이 차단된다**(이 레포에서 실측: 13건이 일제히 "대기"로 떨어졌다). 설치·업데이트
# 시점에 한 번 백필하고, 그 사실과 되돌리는 법을 요약에 낸다.
backfill_approvals() {
  local target="$1" root design count=0 d task f
  root="$(workdocs_root "$target")"
  design="$(design_doc_name "$target")"
  if [ ! -d "$root" ]; then printf '0\n'; return 0; fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    d="$(dirname "$f")"
    [ -f "${d}/.approved" ] && continue
    task="$(basename "$(dirname "$d")")"
    write_approval_marker "$d" "$task" "backfill(게이트 도입 전 작업)" "$design" "$target"
    count=$((count + 1))
  done < <(find "$root" -mindepth 1 -maxdepth 4 -type f -name "$design" 2>/dev/null | sort)
  printf '%s\n' "$count"
}

# ---- 스킬 노출 (.claude/skills/, PRD §5 2026-11-06 개정) ---------------------

# harness_skill_names <하네스경로>  → 스킬 이름을 한 줄씩 stdout
harness_skill_names() {
  local hn="$1" d
  [ -d "${hn}/skills" ] || return 0
  for d in "${hn}/skills"/*/; do
    [ -f "${d}SKILL.md" ] || continue
    basename "$d"
  done
}

# exposed_skill_names <프로젝트경로>  → **우리가 소유한** 노출 링크의 이름만 stdout
#
# 하네스 스킬 목록이 아니라 "실제로 우리가 만든 링크"를 센다. 충돌로 건너뛴 이름
# (= 그 프로젝트 자신의 스킬)을 섞으면 .gitignore 가 남의 스킬을 가려버린다
# (2026-11-06 실측: design-doc 충돌 케이스에서 그 프로젝트의 스킬이 무시 목록에 들어갔다).
exposed_skill_names() {
  local target="$1" dir link
  dir="${target}/.claude/skills"
  [ -d "$dir" ] || return 0
  for link in "$dir"/*; do
    [ -L "$link" ] || continue
    case "$(readlink "$link")" in
      */.harness/skills/*) basename "$link" ;;
    esac
  done
}

# expose_skills <프로젝트경로> <하네스경로>  → 상태 한 줄을 stdout (로그는 stderr)
#
# <프로젝트>/.claude/skills/<이름> → ../../.harness/skills/<이름> 상대 심링크.
# 상대 링크를 쓰는 이유: 프로젝트를 다른 경로로 옮겨도 살아 있어야 한다.
#
# **조용히 가리지 않는다.** 같은 이름의 남의 스킬(실디렉터리이거나, 우리 것이 아닌
# 링크)이 있으면 HRN-W022 로 보고하고 건너뛴다 — HRN-E015 와 같은 철학이지만 설치를
# 막을 이유는 없어 경고(W)다.
#
# 이 노출은 플레이북 §1의 파일 직독을 **대체하지 않는다.** 구간별 실행은 그대로 직독이고,
# 노출은 자동 트리거와 사용자의 직접 호출(/<스킬명>)을 가능하게 하는 추가 경로다.
expose_skills() {
  local target="$1" hn="$2" enabled dir name link created=0 kept=0 conflict=0 stale=0
  local -a conflicts=()

  enabled="$(yaml_get "${target}/harness.config.yaml" "skills.expose_to_claude")"
  # 해석 규칙: false 가 아닌 값은 전부 true (노출은 추가 경로일 뿐이라 켜진 쪽 부작용이 작다)
  if [ "$enabled" = "false" ]; then
    printf '꺼짐 (skills.expose_to_claude: false)\n'
    return 0
  fi

  dir="${target}/.claude/skills"
  mkdir -p "$dir" 2>/dev/null || {
    printf '실패 (%s 를 만들 수 없음)\n' "$dir"
    return 0
  }

  # 1) 죽은 링크 청소 — 하네스에서 사라진 스킬의 링크를 남기지 않는다
  for link in "$dir"/*; do
    [ -L "$link" ] || continue
    case "$(readlink "$link")" in
      *.harness/skills/*|*/skills/*)
        if [ ! -e "$link" ]; then rm -f "$link"; stale=$((stale + 1)); fi
        ;;
    esac
  done

  # 2) 노출
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    link="${dir}/${name}"
    if [ -L "$link" ]; then
      case "$(readlink "$link")" in
        */.harness/skills/"$name"|*/skills/"$name") kept=$((kept + 1)); continue ;;
        *) conflicts+=("$name (남의 심링크)"); conflict=$((conflict + 1)); continue ;;
      esac
    elif [ -e "$link" ]; then
      conflicts+=("$name (실디렉터리)"); conflict=$((conflict + 1)); continue
    fi
    if ln -s "../../.harness/skills/${name}" "$link" 2>/dev/null; then
      created=$((created + 1))
    elif cp -R "${hn}/skills/${name}" "$link" 2>/dev/null; then
      created=$((created + 1))
      note "  ${name}: 심링크 불가 → 복사로 열화했습니다 (update 때 다시 동기화됩니다)"
    else
      conflicts+=("$name (링크·복사 모두 실패)"); conflict=$((conflict + 1))
    fi
  done < <(harness_skill_names "$hn")

  if [ "$conflict" -gt 0 ]; then
    hrn_warn "W022" "같은 이름의 스킬이 이미 있어 노출을 건너뛴 항목 ${conflict}개: ${conflicts[*]}" \
      "한쪽 스킬 이름을 바꾼 뒤 install/update 를 다시 실행하세요" \
      "노출 자체가 필요 없으면 harness.config.yaml 의 skills.expose_to_claude 를 false 로 바꾸세요"
  fi

  printf '생성 %d · 유지 %d · 충돌 %d · 죽은링크 정리 %d\n' "$created" "$kept" "$conflict" "$stale"
}

# ---- 실행체 실존 예외처리 (B7, 설계 §3-4 L1) --------------------------------

# read_active_harness <yaml파일>  → active_harness 값(주석·따옴표 제거)을 stdout
# 파일이 없거나 키가 없으면 빈 문자열.
read_active_harness() {
  local f="$1" line val
  [ -f "$f" ] || return 0
  line="$(grep -E '^active_harness:' "$f" | head -n1)"
  [ -z "$line" ] && return 0
  val="${line#active_harness:}"
  val="${val%%#*}"                       # 인라인 주석 제거
  val="$(printf '%s' "$val" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  val="${val%\"}"; val="${val#\"}"       # 따옴표 제거
  val="${val%\'}"; val="${val#\'}"
  printf '%s\n' "$val"
}

# harness_executable_for <active_harness 값>  → 확인할 실행체 이름을 stdout
# (claude→claude, codex→codex, 그 외/미상→빈 문자열: 확인 방법이 해당 어댑터
# 소유라 여기서는 판단하지 않고 건너뜀 — 설계 §3-4 L1).
harness_executable_for() {
  case "$1" in
    claude) printf 'claude\n' ;;
    codex)  printf 'codex\n' ;;
    *) printf '\n' ;;
  esac
}

# ---- superpowers 전제 검출 (설계 §3-2, HRN-W014) ----------------------------

# superpowers_skills_in_config <yaml파일>
# stages.*.skills 배열에서 "superpowers:" 접두사 항목을 "<구간>:<스킬>" 형식으로
# 한 줄씩 stdout에 낸다(0개면 빈 출력). 영향 구간명·스킬명을 하드코딩하지 않고
# 컨피그를 단일 소스로 읽기 위한 헬퍼 — YAML 라이브러리 없이, harness.config.yaml의
# 정해진 들여쓰기(구간명 2칸, skills: 4칸 인라인 배열)만 대상으로 하는 최소 파서다.
# 파일이 없으면 빈 출력.
superpowers_skills_in_config() {
  local f="$1" in_stages=0 stage="" line items item
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^stages:[[:space:]]*(#.*)?$ ]]; then
      in_stages=1
      continue
    fi
    [ "$in_stages" -eq 0 ] && continue
    if [[ "$line" =~ ^[A-Za-z_] ]]; then
      # 들여쓰기 없는 다음 최상위 키 — stages 블록 종료.
      in_stages=0
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]{2}([A-Za-z_][A-Za-z0-9_]*): ]]; then
      stage="${BASH_REMATCH[1]}"
      continue
    fi
    if [ -n "$stage" ] && [[ "$line" =~ skills:[[:space:]]*\[([^]]*)\] ]]; then
      items="${BASH_REMATCH[1]}"
      IFS=',' read -ra _sp_items <<< "$items"
      for item in "${_sp_items[@]}"; do
        item="$(printf '%s' "$item" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        case "$item" in
          superpowers:*) printf '%s:%s\n' "$stage" "$item" ;;
        esac
      done
    fi
  done < "$f"
  return 0
}

# detect_superpowers  → 2줄을 stdout으로 출력:
#   1줄: "found:<버전>" | "notfound" | "unknown"
#   2줄: 확인한 매니페스트 경로(호출자가 W014 안내 문구에 사용)
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json 을 조회한다.
# python3 있으면 JSON 파싱, 없으면 `grep -q '"superpowers@'` 폴백. 둘 다 불가면
# fail-open으로 "unknown"을 반환한다(오탐보다 미확인 쪽이 낫다 — 설계 §3-2 6항).
# 매니페스트 파일 자체가 없으면 "unknown"(확인 불가)이다 — **"미발견"이 아니다.**
# 플러그인을 다른 경로·다른 방식으로 깔았을 수 있고, 없다고 단정할 근거가 아니다.
# 2026-11-06 수정: 이전에는 이 경우를 "nomanifest" 로 내고 setup 이 W014("미발견")로
# 보고했는데, 같은 상황을 validate_config.py 는 "확인 불가"로 봤다. 한 번의 setup 실행이
# 두 문구를 동시에 출력하는 것이 실측돼(평가 보고) **python 쪽(fail-open)에 맞췄다.**
# 주석은 "동일 원천"이라 적혀 있었지만 실제로는 갈라져 있었다.
detect_superpowers() {
  local manifest="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"
  if [ ! -f "$manifest" ]; then
    printf 'unknown\n%s\n' "$manifest"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    local result
    result="$(python3 - "$manifest" <<'PYEOF'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("unknown")
    sys.exit(0)

plugins = data.get("plugins", {}) if isinstance(data, dict) else {}
if not isinstance(plugins, dict):
    print("unknown")
    sys.exit(0)

for key, val in plugins.items():
    if isinstance(key, str) and key.startswith("superpowers@"):
        version = "unknown"
        if isinstance(val, dict):
            version = val.get("version", "unknown")
        print(f"found:{version}")
        sys.exit(0)
print("notfound")
PYEOF
)"
    [ -z "$result" ] && result="unknown"
    printf '%s\n%s\n' "$result" "$manifest"
    return 0
  fi
  if command -v grep >/dev/null 2>&1; then
    if grep -q '"superpowers@' "$manifest" 2>/dev/null; then
      printf 'found:unknown\n%s\n' "$manifest"
    else
      printf 'notfound\n%s\n' "$manifest"
    fi
    return 0
  fi
  printf 'unknown\n%s\n' "$manifest"
  return 0
}

# ---- Obsidian vault 탐지 (WSL 전용, 설계 §3-2) ------------------------------

# detect_obsidian_vaults
#   → "<이름>\t<절대경로>" 를 한 줄씩 stdout. 탐지 실패 시 빈 출력(성공 종료).
#
# WSL/Windows 전용이다 — obsidian.json 이 Windows AppData 에 있다.
# Linux·macOS 는 표준 위치가 다르나 이 저장소에서 실측할 수 없어 다루지 않는다
# (설계 §4 비대상). 그 환경에서는 빈 출력 → 호출부가 자유 입력으로 열화한다.
#
# 탐지 실패를 에러로 만들지 않는다 — vault 지정은 선택이지 요건이 아니다.
detect_obsidian_vaults() {
  local cfg raw winpath unixpath

  cfg="$(ls /mnt/c/Users/*/AppData/Roaming/obsidian/obsidian.json 2>/dev/null | head -n1)"
  [ -n "$cfg" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  command -v wslpath >/dev/null 2>&1 || return 0

  raw="$(python3 - "$cfg" <<'PYEOF'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

vaults = data.get("vaults", {}) if isinstance(data, dict) else {}
if not isinstance(vaults, dict):
    sys.exit(0)

for v in vaults.values():
    if isinstance(v, dict) and v.get("path"):
        print(v["path"])
PYEOF
  )" || return 0
  [ -n "$raw" ] || return 0

  while IFS= read -r winpath; do
    [ -n "$winpath" ] || continue
    unixpath="$(wslpath -u "$winpath" 2>/dev/null)" || continue
    [ -d "$unixpath" ] || continue          # 삭제된 vault 가 목록에 남아 있을 수 있다
    printf '%s\t%s\n' "$(basename "$unixpath")" "$unixpath"
  done <<< "$raw"
}
