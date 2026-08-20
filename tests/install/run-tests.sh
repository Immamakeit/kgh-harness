#!/usr/bin/env bash
# tests/install/run-tests.sh — install/setup · install/update · install/lib.sh 계약 회귀 스위트.
#
# 대상 계약 (구현계획.md §4.6 B2):
#   - rsync 계약: work/·.meta 보존(/work/·/.meta 앵커), --delete 전파, 정상 제외,
#     중첩 동명 디렉토리 오제외 없음
#   - setup 계약: 개발용 파일 부재, 컨피그 생성·재실행 보존, 훅 병합 멱등·기존 키 보존, .meta 기록
#   - update 계약: work/ 보존, 루트 컨피그 미접촉, .meta 갱신, 새 컨피그 키 안내만,
#     소스 삭제 파일 전파
#   - 예외: .meta 파손/명령주입 → HRN-E006 + 미실행, rsync 부재 → HRN-E008 중단,
#     하네스 CLI 부재 → HRN-W013 경고(비차단)
#
# 자체 격리: 모든 산출물은 mktemp로 만든 임시 디렉토리 아래에만 생기며, 스위트 종료 시
# (성공이든 실패든) trap으로 정리한다. 이 저장소 안에는 아무것도 남기지 않는다.
# 임시 디렉토리 위치를 제어하려면 TMPDIR을 지정해서 실행: TMPDIR=/원하는/경로 tests/install/run-tests.sh
#
# 실행: tests/install/run-tests.sh (레포 어느 위치에서 실행해도 무관 — 자기 경로 기준으로 계산)
# 종료 코드: 전부 PASS면 0, 하나라도 FAIL이면 1.

set -uo pipefail  # -e는 쓰지 않는다 — 개별 케이스 실패가 스위트 전체를 죽이면 안 된다.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL_DIR="${REPO_ROOT}/install"

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
WORK="$(mktemp -d "${TMP_BASE}/kgh-harness-install-tests.XXXXXX")" || {
  echo "치명적 오류: 격리 작업 디렉토리를 만들 수 없습니다 (TMPDIR=${TMP_BASE})" >&2
  exit 1
}
# shellcheck disable=SC2329
# 검증 루프: 원래 SC2317("도달 불가")로 표기돼 있었으나 shellcheck 0.11.0 실측 결과
# 실제 발생 코드는 SC2329("함수가 호출되지 않음")였다 — trap으로만 호출되어 직접
# 호출부가 안 보이는 탓에 미사용으로 오판되지만, 실제로는 EXIT 시 실행된다.
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# shellcheck source=/dev/null
source "${INSTALL_DIR}/lib.sh"

PASS=0
FAIL=0
FAILED_NAMES=()
CURRENT_GROUP=""

group() {
  CURRENT_GROUP="$1"
  printf '\n=== %s ===\n' "$1"
}

pass_case() {
  PASS=$((PASS + 1))
  printf '  [PASS] %s\n' "$1"
}

fail_case() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("${CURRENT_GROUP} :: $1")
  printf '  [FAIL] %s — %s\n' "$1" "$2"
}

assert_eq() {
  local actual="$1" expected="$2" desc="$3"
  if [ "$actual" = "$expected" ]; then
    pass_case "$desc"
  else
    fail_case "$desc" "기대='${expected}' 실제='${actual}'"
  fi
}

assert_ne() {
  local actual="$1" not_expected="$2" desc="$3"
  if [ "$actual" != "$not_expected" ]; then
    pass_case "$desc"
  else
    fail_case "$desc" "값이 '${not_expected}'와 같으면 안 됨"
  fi
}

assert_present() {
  local path="$1" desc="$2"
  if [ -e "$path" ]; then
    pass_case "$desc"
  else
    fail_case "$desc" "존재해야 하는데 없음: ${path}"
  fi
}

assert_absent() {
  local path="$1" desc="$2"
  if [ ! -e "$path" ]; then
    pass_case "$desc"
  else
    fail_case "$desc" "없어야 하는데 존재함: ${path}"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" desc="$3"
  case "$haystack" in
    *"$needle"*) pass_case "$desc" ;;
    *) fail_case "$desc" "'${needle}'를 찾지 못함" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" desc="$3"
  case "$haystack" in
    *"$needle"*) fail_case "$desc" "'${needle}'가 있으면 안 되는데 있음" ;;
    *) pass_case "$desc" ;;
  esac
}

# ---- 픽스처 헬퍼 ------------------------------------------------------------

# build_fake_source <dir>
# update 계약 테스트(소스 커밋 변경·새 컨피그 키·소스 파일 삭제 전파)를 위해 현재
# install/{lib.sh,setup,update}를 그대로 옮겨 심은 최소 소스 레포를 만든다. 실제
# 레포를 건드리지 않고 소스 쪽을 자유롭게 변형(커밋 추가·파일 삭제 등)하기 위함이다.
build_fake_source() {
  local dir="$1"
  mkdir -p "$dir/core" "$dir/install" "$dir/adapters" "$dir/skills/dummy/work" "$dir/tests" "$dir/.claude"
  cp "${INSTALL_DIR}/lib.sh" "${INSTALL_DIR}/setup" "${INSTALL_DIR}/update" "$dir/install/"
  chmod +x "$dir/install/setup" "$dir/install/update"

  cat > "$dir/core/playbook.md" <<'EOF'
# 테스트용 fake 플레이북
EOF

  cat > "$dir/.harnessignore" <<'EOF'
PRD.md
CLAUDE.md
.git/
.gitignore
tests/
.harnessignore
.harness/
.claude/
EOF

  cat > "$dir/harness.config.yaml" <<'EOF'
active_harness: claude
defaults:
  model: sonnet
  effort: medium
workdocs:
  path: .harness/work
storage:
  enabled: true
  vault_root: null
EOF

  echo "dummy adapter" > "$dir/adapters/marker.txt"
  echo "keep" > "$dir/skills/dummy/work/keepme.txt"   # 중첩 동명(work) — 앵커 테스트용
  echo "개발용 문서" > "$dir/PRD.md"
  echo "개발용" > "$dir/CLAUDE.md"
  echo "테스트 픽스처" > "$dir/tests/sample.txt"
  echo '{}' > "$dir/.claude/settings.json"

  git -C "$dir" init -q
  git -C "$dir" -c user.email=test@test.local -c user.name=test add -A
  git -C "$dir" -c user.email=test@test.local -c user.name=test commit -q -m "fake source init"
}

# build_min_path <label> [--no-rsync]
# rsync/claude/codex를 뺀(혹은 rsync만 뺀) 최소 PATH 디렉토리를 만들어 경로를 stdout으로 낸다.
# claude·codex는 애초에 포함하지 않으므로 두 케이스 모두에서 하네스 CLI는 항상 "미발견" 상태다.
build_min_path() {
  local label="$1" no_rsync="${2:-}"
  local dir="${WORK}/minpath-${label}"
  mkdir -p "$dir"
  local tools=(bash env mkdir cat cp mv rm find grep sed comm sort head tail date
    dirname basename python3 git realpath mktemp id chmod ln awk cut wc printf touch diff)
  [ "$no_rsync" != "--no-rsync" ] && tools+=(rsync)
  local t p
  for t in "${tools[@]}"; do
    p="$(command -v "$t" 2>/dev/null)" || continue
    ln -sf "$p" "${dir}/${t}"
  done
  printf '%s\n' "$dir"
}

count_hook_entries() {
  local settings_file="$1" cmd="$2"
  python3 -c '
import json, sys
path, cmd = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print(0)
    sys.exit(0)
count = 0
for group in data.get("hooks", {}).get("SessionStart", []):
    for h in group.get("hooks", []):
        if h.get("command") == cmd:
            count += 1
print(count)
' "$settings_file" "$cmd"
}

# shellcheck disable=SC2016
# 의도적 단일 따옴표: install/setup의 HOOK_CMD와 문자 그대로 일치해야 하는 리터럴 문자열이다
# ($CLAUDE_PROJECT_DIR는 여기서 확장되면 안 됨 — settings.json에 기록되는 원본 그대로 비교).
EXPECTED_HOOK_CMD='"$CLAUDE_PROJECT_DIR"/.harness/adapters/claude/hooks/session-start.sh'

# ============================================================================
# 1. rsync 계약 (harness_copy 단위 테스트)
# ============================================================================
test_rsync_contract() {
  group "rsync 계약 (harness_copy)"

  local src dest
  src="$(mktemp -d "${WORK}/r-src.XXXXXX")"
  dest="$(mktemp -d "${WORK}/r-dest.XXXXXX")"

  mkdir -p "$src/core" "$src/skills/dummy/work"
  echo "playbook" > "$src/core/playbook.md"
  echo "nested-work-file" > "$src/skills/dummy/work/keepme.txt"
  echo "devfile" > "$src/PRD.md"
  echo "delete-me" > "$src/tobedeleted.txt"
  cat > "$src/.harnessignore" <<'EOF'
PRD.md
EOF

  # 대상에는 이미 target 전용 산출물(work/·.meta)이 있다고 가정 — 소스엔 없음.
  mkdir -p "$dest/work"
  echo "사용자 작업 문서" > "$dest/work/mydoc.md"
  printf 'SOURCE_PATH=%s\n' "$src" > "$dest/.meta"

  local count1
  count1="$(harness_copy "$src" "$dest" 2>/dev/null)"
  assert_ne "$count1" "" "1차 복사 실행됨 (count 출력)"

  assert_present "$dest/work/mydoc.md" "work/ 보존 (앵커 /work/)"
  assert_eq "$(cat "$dest/work/mydoc.md")" "사용자 작업 문서" "work/ 내용 불변"
  assert_present "$dest/.meta" ".meta 보존 (앵커 /.meta)"
  assert_eq "$(cat "$dest/.meta")" "SOURCE_PATH=${src}" ".meta 내용 불변"
  assert_absent "$dest/PRD.md" "정상 제외 (.harnessignore의 PRD.md)"
  assert_present "$dest/tobedeleted.txt" "삭제 전 파일 정상 복사(--delete 테스트 준비)"
  assert_present "$dest/skills/dummy/work/keepme.txt" \
    "중첩 동명 work/ 오제외 없음 (앵커가 최상위만 적용)"

  # 소스에서 파일 삭제 → 재복사 시 대상에서도 사라져야 함(--delete 전파)
  rm -f "$src/tobedeleted.txt"
  local count2
  count2="$(harness_copy "$src" "$dest" 2>/dev/null)"
  assert_absent "$dest/tobedeleted.txt" "--delete 전파: 소스 삭제 파일이 대상에서도 제거됨"
  assert_present "$dest/work/mydoc.md" "--delete 적용 후에도 work/ 보존"
  assert_present "$dest/.meta" "--delete 적용 후에도 .meta 보존"
  assert_present "$dest/skills/dummy/work/keepme.txt" \
    "--delete 적용 후에도 중첩 동명 work/ 보존(오삭제 없음)"
  : "$count2"
}

# ============================================================================
# 2. setup 계약
# ============================================================================
test_setup_contract() {
  group "setup 계약"

  # --- 기본 설치: 개발용 파일 부재 / 컨피그 생성 / .meta 기록 ---
  local target1
  target1="$(mktemp -d "${WORK}/s-target1.XXXXXX")"
  local out1 rc1
  out1="$(cd "$REPO_ROOT" && ./install/setup "$target1" </dev/null 2>&1)"; rc1=$?
  assert_eq "$rc1" "0" "기본 설치 정상 종료"

  for f in PRD.md CLAUDE.md; do
    assert_absent "${target1}/.harness/${f}" "설치물에 개발용 파일 부재: ${f}"
  done
  for d in tests .claude .git; do
    assert_absent "${target1}/.harness/${d}" "설치물에 개발용 디렉토리 부재: ${d}"
  done
  assert_present "${target1}/harness.config.yaml" "컨피그 신규 생성"
  assert_contains "$out1" "신규 생성" "종료 요약에 '신규 생성' 표기"
  assert_present "${target1}/.harness/.meta" ".meta 파일 생성"
  assert_contains "$(cat "${target1}/.harness/.meta")" "SOURCE_PATH=" ".meta에 SOURCE_PATH 기록"
  assert_contains "$(cat "${target1}/.harness/.meta")" "SOURCE_COMMIT=" ".meta에 SOURCE_COMMIT 기록"
  assert_contains "$(cat "${target1}/.harness/.meta")" "INSTALLED_AT=" ".meta에 INSTALLED_AT 기록"

  # --- 재실행 시 컨피그 보존 ---
  printf '\n# 사용자 커스텀 마커\n' >> "${target1}/harness.config.yaml"
  local before_cfg out2 rc2 after_cfg
  before_cfg="$(cat "${target1}/harness.config.yaml")"
  out2="$(cd "$REPO_ROOT" && ./install/setup "$target1" </dev/null 2>&1)"; rc2=$?
  after_cfg="$(cat "${target1}/harness.config.yaml")"
  assert_eq "$rc2" "0" "재설치(재실행) 정상 종료"
  assert_eq "$before_cfg" "$after_cfg" "재실행 시 기존 컨피그(사용자 마커 포함) 보존"
  assert_contains "$out2" "기존 유지" "재실행 시 '기존 유지' 안내 출력"

  # --- 훅 병합 멱등성 (같은 대상에 2번 설치했으니 target1로 확인) ---
  local hook_count
  hook_count="$(count_hook_entries "${target1}/.claude/settings.json" "$EXPECTED_HOOK_CMD")"
  assert_eq "$hook_count" "1" "SessionStart 훅 중복 없음 (2회 설치에도 정확히 1개)"

  # --- 기존 settings.json 키 보존 ---
  local target2
  target2="$(mktemp -d "${WORK}/s-target2.XXXXXX")"
  mkdir -p "${target2}/.claude"
  cat > "${target2}/.claude/settings.json" <<'EOF'
{
  "env": { "FOO": "bar" },
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "echo existing-hook" } ] }
    ]
  }
}
EOF
  local rc3
  ( cd "$REPO_ROOT" && ./install/setup "$target2" </dev/null >/dev/null 2>&1 ); rc3=$?
  assert_eq "$rc3" "0" "기존 settings.json 있는 대상 설치 정상 종료"
  local settings2
  settings2="$(cat "${target2}/.claude/settings.json")"
  assert_contains "$settings2" '"FOO": "bar"' "기존 env 키 보존"
  assert_contains "$settings2" "echo existing-hook" "기존 SessionStart 훅 보존"
  local hook_count2
  hook_count2="$(count_hook_entries "${target2}/.claude/settings.json" "$EXPECTED_HOOK_CMD")"
  assert_eq "$hook_count2" "1" "새 SessionStart 훅이 기존 훅 옆에 정확히 1개 추가됨"
}

# ============================================================================
# 3. update 계약
# ============================================================================
test_update_contract() {
  group "update 계약"

  local src target
  src="$(mktemp -d "${WORK}/u-src.XXXXXX")"
  build_fake_source "$src"
  target="$(mktemp -d "${WORK}/u-target.XXXXXX")"
  ( cd "$src" && ./install/setup "$target" </dev/null >/dev/null 2>&1 )

  mkdir -p "${target}/.harness/work"
  echo "사용자 작업 문서" > "${target}/.harness/work/mydoc.md"
  local cfg_before installed_at_before
  cfg_before="$(cat "${target}/harness.config.yaml")"
  installed_at_before="$(grep '^INSTALLED_AT=' "${target}/.harness/.meta")"

  # 소스 변형: 파일 삭제 + 새 컨피그 키 추가 + 새 커밋
  rm -f "${src}/adapters/marker.txt"
  printf '\nnew_feature_key: true\n' >> "${src}/harness.config.yaml"
  git -C "$src" -c user.email=test@test.local -c user.name=test add -A
  git -C "$src" -c user.email=test@test.local -c user.name=test commit -q -m "bump: remove marker, add config key"

  local out rc
  out="$("${target}/.harness/install/update" </dev/null 2>&1)"; rc=$?
  assert_eq "$rc" "0" "update 정상 종료"

  assert_present "${target}/.harness/work/mydoc.md" "update 후 work/ 보존"
  assert_eq "$(cat "${target}/.harness/work/mydoc.md")" "사용자 작업 문서" "work/ 내용 불변"

  assert_eq "$(cat "${target}/harness.config.yaml")" "$cfg_before" "루트 harness.config.yaml 미접촉"

  assert_absent "${target}/.harness/adapters/marker.txt" "소스에서 삭제된 파일이 update로 전파됨"

  local installed_at_after
  installed_at_after="$(grep '^INSTALLED_AT=' "${target}/.harness/.meta")"
  assert_eq "$installed_at_after" "$installed_at_before" ".meta INSTALLED_AT 유지"
  assert_contains "$(cat "${target}/.harness/.meta")" "UPDATED_AT=" ".meta에 UPDATED_AT 갱신 기록"
  local commit_line
  commit_line="$(grep '^SOURCE_COMMIT=' "${target}/.harness/.meta")"
  local new_head
  new_head="$(git -C "$src" rev-parse HEAD)"
  assert_eq "$commit_line" "SOURCE_COMMIT=${new_head}" ".meta SOURCE_COMMIT이 새 커밋으로 갱신됨"

  assert_contains "$out" "new_feature_key" "새 설정 키를 안내에 명시"
  assert_not_contains "$(cat "${target}/harness.config.yaml")" "new_feature_key" \
    "새 설정 키를 자동으로 추가하지 않음(안내만)"
}

# ============================================================================
# 4. 예외 케이스
# ============================================================================
test_meta_corruption() {
  group "예외: .meta 파손/명령주입"

  local src target
  src="$(mktemp -d "${WORK}/e1-src.XXXXXX")"
  build_fake_source "$src"
  target="$(mktemp -d "${WORK}/e1-target.XXXXXX")"
  ( cd "$src" && ./install/setup "$target" </dev/null >/dev/null 2>&1 )

  # 4-1. 구조적 파손 (화이트리스트에 없는 줄)
  printf 'SOURCE_PATH=%s\nSOURCE_COMMIT=x\nINSTALLED_AT=x\nGARBAGE_NOT_A_KEY=1\n' "$src" \
    > "${target}/.harness/.meta"
  local out1 rc1
  out1="$("${target}/.harness/install/update" </dev/null 2>&1)"; rc1=$?
  assert_ne "$rc1" "0" "파손된 .meta로 update 실행 시 비정상 종료"
  assert_contains "$out1" "HRN-E006" "파손된 .meta → HRN-E006 보고"

  # 4-2. 명령주입 시도 — harness_meta_read가 절대 source하지 않는지 실측
  local marker
  marker="${WORK}/pwned_marker_$$"
  rm -f "$marker"
  # shellcheck disable=SC2016
  # $()·백틱을 의도적으로 미확장 리터럴로 파일에 기록한다(PoC) — harness_meta_read가
  # 이 줄을 절대 source/eval하지 않고 화이트리스트 밖 줄로 걸러내는지 확인한다.
  printf 'SOURCE_PATH=%s\nSOURCE_COMMIT=x\n$(touch %s)\n`touch %s`\n' "$src" "$marker" "$marker" \
    > "${target}/.harness/.meta"
  local out2 rc2
  out2="$("${target}/.harness/install/update" </dev/null 2>&1)"; rc2=$?
  assert_ne "$rc2" "0" "명령주입 시도 .meta로 update 실행 시 비정상 종료"
  assert_contains "$out2" "HRN-E006" "명령주입 시도 .meta → HRN-E006 보고"
  assert_absent "$marker" "명령주입 미실행 — 마커 파일이 생성되지 않음"
}

test_rsync_missing() {
  group "예외: rsync 부재 → HRN-E008"

  local minpath
  minpath="$(build_min_path "no-rsync" "--no-rsync")"

  # setup: rsync 부재 시 대상 디렉토리 생성 전에 조기 중단되어야 한다.
  local target_setup out rc
  target_setup="${WORK}/e2-target-setup"
  out="$(cd "$REPO_ROOT" && PATH="$minpath" ./install/setup "$target_setup" </dev/null 2>&1)"; rc=$?
  assert_ne "$rc" "0" "rsync 부재 시 setup 비정상 종료"
  assert_contains "$out" "HRN-E008" "rsync 부재 → setup에서 HRN-E008 보고"
  assert_absent "$target_setup" "rsync 부재 시 대상 경로가 생성되지 않음(조기 중단)"

  # update: 정상 설치(rsync 있는 상태로) 후, rsync를 가리고 update 실행.
  local src target3
  src="$(mktemp -d "${WORK}/e2-src.XXXXXX")"
  build_fake_source "$src"
  target3="$(mktemp -d "${WORK}/e2-target3.XXXXXX")"
  ( cd "$src" && ./install/setup "$target3" </dev/null >/dev/null 2>&1 )
  local meta_before
  meta_before="$(cat "${target3}/.harness/.meta")"

  out="$(PATH="$minpath" "${target3}/.harness/install/update" </dev/null 2>&1)"; rc=$?
  assert_ne "$rc" "0" "rsync 부재 시 update 비정상 종료"
  assert_contains "$out" "HRN-E008" "rsync 부재 → update에서 HRN-E008 보고"
  assert_eq "$(cat "${target3}/.harness/.meta")" "$meta_before" \
    "rsync 부재 시 .meta 미변경(조기 중단, 부분 실행 없음)"
}

test_harness_cli_missing() {
  group "예외: 하네스 CLI 부재 → HRN-W013 (비차단)"

  local minpath
  minpath="$(build_min_path "no-cli")"   # rsync는 포함, claude/codex는 애초에 미포함

  local target out rc
  target="${WORK}/e3-target"
  out="$(cd "$REPO_ROOT" && PATH="$minpath" ./install/setup "$target" </dev/null 2>&1)"; rc=$?
  assert_eq "$rc" "0" "하네스 CLI 부재는 비차단 — setup 정상 종료"
  assert_contains "$out" "HRN-W013" "하네스 CLI 부재 → HRN-W013 경고 출력"
  assert_present "${target}/.harness/.meta" "CLI 부재여도 설치는 완료됨(.meta 존재)"
  assert_present "${target}/harness.config.yaml" "CLI 부재여도 설치는 완료됨(컨피그 존재)"
}

# ============================================================================
# 5. 전제: superpowers 플러그인 → HRN-W014 (설계 §3-2·3-4)
# ============================================================================
# CLAUDE_CONFIG_DIR을 샌드박스로 가리켜 4분기를 실측한다. ①②③은 REPO_ROOT의 실제
# harness.config.yaml(clarify·plan·implement·verify 4개 구간에 superpowers: 항목 존재)을
# 그대로 사용 — 영향 구간명을 하드코딩하지 않고 컨피그에서 읽는지까지 실증한다.
test_superpowers_prereq() {
  group "전제: superpowers 플러그인 → HRN-W014"

  # --- ① 매니페스트에 superpowers 있음: W014 미출력, 요약에 확인됨 ---
  local cfgdir1 target1 out1 rc1
  cfgdir1="$(mktemp -d "${WORK}/sp-cfg1.XXXXXX")"
  mkdir -p "${cfgdir1}/plugins"
  cat > "${cfgdir1}/plugins/installed_plugins.json" <<'EOF'
{
  "plugins": {
    "superpowers@superpowers-marketplace": { "version": "6.1.1", "scope": "user" }
  }
}
EOF
  target1="$(mktemp -d "${WORK}/sp-target1.XXXXXX")"
  out1="$(cd "$REPO_ROOT" && CLAUDE_CONFIG_DIR="$cfgdir1" ./install/setup "$target1" </dev/null 2>&1)"; rc1=$?
  assert_eq "$rc1" "0" "① superpowers 발견 — setup 정상 종료"
  assert_not_contains "$out1" "HRN-W014" "① superpowers 발견 — W014 미출력"
  assert_contains "$out1" "확인됨" "① 종료 요약에 '확인됨' 표기"

  # --- ② 매니페스트 있으나 superpowers 키 없음: 비차단·W014·영향 구간 4개 포함 ---
  local cfgdir2 target2 out2 rc2 stage
  cfgdir2="$(mktemp -d "${WORK}/sp-cfg2.XXXXXX")"
  mkdir -p "${cfgdir2}/plugins"
  cat > "${cfgdir2}/plugins/installed_plugins.json" <<'EOF'
{ "plugins": { "other-plugin@marketplace": { "version": "1.0.0" } } }
EOF
  target2="$(mktemp -d "${WORK}/sp-target2.XXXXXX")"
  out2="$(cd "$REPO_ROOT" && CLAUDE_CONFIG_DIR="$cfgdir2" ./install/setup "$target2" </dev/null 2>&1)"; rc2=$?
  assert_eq "$rc2" "0" "② superpowers 키 없음 — 비차단(setup 정상 종료)"
  assert_contains "$out2" "HRN-W014" "② superpowers 키 없음 — W014 출력"
  # W014 라인의 "영향 구간:" 필드만 추출해서 검사한다. out2 전체를 grep하면
  # skills/plan-doc/(rsync 복사 로그)·superpowers:writing-plans(스킬명)에 부분매칭돼
  # 'plan' 어서션이 결함 주입에도 반응하지 않는 tautology가 됐다(검증 루프 1회차 F3).
  local stages_field2
  stages_field2="$(printf '%s\n' "$out2" | sed -n 's/.*영향 구간: \([^(]*\)(스킬:.*/\1/p')"
  for stage in clarify plan implement verify; do
    assert_contains "$stages_field2" "$stage" "② W014 '영향 구간:' 필드에 '${stage}' 포함"
  done
  assert_present "${target2}/.harness/.meta" "② 비차단 — 설치는 끝까지 완료(.meta 존재)"

  # --- ③ 매니페스트 파일 부재: 비차단·W014·확인 경로 문자열 포함 ---
  local cfgdir3 target3 out3 rc3
  cfgdir3="$(mktemp -d "${WORK}/sp-cfg3.XXXXXX")"
  target3="$(mktemp -d "${WORK}/sp-target3.XXXXXX")"
  out3="$(cd "$REPO_ROOT" && CLAUDE_CONFIG_DIR="$cfgdir3" ./install/setup "$target3" </dev/null 2>&1)"; rc3=$?
  assert_eq "$rc3" "0" "③ 매니페스트 부재 — 비차단(setup 정상 종료)"
  assert_contains "$out3" "HRN-W014" "③ 매니페스트 부재 — W014 출력"
  assert_contains "$out3" "${cfgdir3}/plugins/installed_plugins.json" "③ W014 메시지에 확인 경로 포함"

  # --- ④ 컨피그에 superpowers: 0개: 점검 자체를 건너뜀(W014 미출력) ---
  local src4 cfgdir4 target4 out4 rc4
  src4="$(mktemp -d "${WORK}/sp-src4.XXXXXX")"
  build_fake_source "$src4"   # fixture 컨피그에는 stages 자체가 없음 → superpowers: 0개
  cfgdir4="$(mktemp -d "${WORK}/sp-cfg4.XXXXXX")"
  target4="$(mktemp -d "${WORK}/sp-target4.XXXXXX")"
  out4="$(cd "$src4" && CLAUDE_CONFIG_DIR="$cfgdir4" ./install/setup "$target4" </dev/null 2>&1)"; rc4=$?
  assert_eq "$rc4" "0" "④ superpowers 0개 — setup 정상 종료"
  assert_not_contains "$out4" "HRN-W014" "④ superpowers 0개 — 점검 건너뜀(W014 미출력)"
}

# ============================================================================
# 6. join_lines 단위 테스트 (install/lib.sh)
# ============================================================================
test_join_lines() {
  group "join_lines 단위 테스트"

  local out
  out="$(printf '' | join_lines '·')"
  assert_eq "$out" "" "0줄 입력 → 빈 출력"

  out="$(printf 'a\n' | join_lines '·')"
  assert_eq "$out" "a" "1줄 입력 → 그 줄 그대로"

  out="$(printf 'a\nb\nc\n' | join_lines '·')"
  assert_eq "$out" "a·b·c" "다줄(개행 종료) → 구분자로 연결"

  out="$(printf 'a\nb\nc' | join_lines '·')"
  assert_eq "$out" "a·b·c" "개행 없이 끝나는 마지막 줄도 유실 없이 포함됨"

  out="$(printf 'a\nb\nc\n' | join_lines '·')"
  local hex
  hex="$(printf '%s' "$out" | xxd -p | tr -d '\n')"
  assert_contains "$hex" "c2b7" "다중바이트 구분자(·)가 바이트 손상 없이 c2b7로 보존됨"
}

# ---- 컨피그 검증기 (config-schema) -----------------------------------------
test_validate_config() {
  group "컨피그 검증기 — install/validate-config"

  local vc="${REPO_ROOT}/install/validate-config"
  local dir="${WORK}/vc"; mkdir -p "$dir"

  if [ ! -x "$vc" ]; then
    fail_case "검증기 실존" "install/validate-config 없음 (RED 기대 상태)"
    return
  fi

  # (1) 정상 컨피그 → 통과
  cp "${REPO_ROOT}/harness.config.yaml" "${dir}/harness.config.yaml"
  if "$vc" "${dir}/harness.config.yaml" >"${dir}/ok.log" 2>&1; then
    pass_case "정상 컨피그 통과 (exit 0)"
  else
    fail_case "정상 컨피그 통과" "exit=$? — $(tail -2 "${dir}/ok.log")"
  fi

  # (2) 알 수 없는 구간 → HRN-E004 차단
  sed 's/^  design:/  desing:/' "${REPO_ROOT}/harness.config.yaml" > "${dir}/typo-stage.yaml"
  "$vc" "${dir}/typo-stage.yaml" >"${dir}/e004a.log" 2>&1 && \
    fail_case "알 수 없는 구간 차단" "exit 0으로 통과함" || \
    { assert_contains "$(cat "${dir}/e004a.log")" "HRN-E004" "알 수 없는 구간 → HRN-E004"
      assert_contains "$(cat "${dir}/e004a.log")" "desing" "오타 구간명을 그대로 지목"; }

  # (3) 알 수 없는 키 → HRN-E004 차단
  sed 's/^    model: opus/    modle: opus/' "${REPO_ROOT}/harness.config.yaml" > "${dir}/typo-key.yaml"
  "$vc" "${dir}/typo-key.yaml" >"${dir}/e004b.log" 2>&1 && \
    fail_case "알 수 없는 키 차단" "exit 0으로 통과함" || \
    assert_contains "$(cat "${dir}/e004b.log")" "HRN-E004" "알 수 없는 키 → HRN-E004"

  # (4) 미지원 model 값 → HRN-E001 차단
  sed 's/^    model: opus/    model: gpt4/' "${REPO_ROOT}/harness.config.yaml" > "${dir}/bad-model.yaml"
  "$vc" "${dir}/bad-model.yaml" >"${dir}/e001.log" 2>&1 && \
    fail_case "미지원 model 차단" "exit 0으로 통과함" || \
    { assert_contains "$(cat "${dir}/e001.log")" "HRN-E001" "미지원 model → HRN-E001"
      assert_contains "$(cat "${dir}/e001.log")" "adapters/claude" "복구 경로가 실존 파일을 지목"; }

  # (5) 없는 하네스 스킬 참조 → HRN-E005 차단
  sed 's/skills: \[design-doc\]/skills: [desgin-doc]/' "${REPO_ROOT}/harness.config.yaml" > "${dir}/bad-ref.yaml"
  "$vc" "${dir}/bad-ref.yaml" >"${dir}/e005.log" 2>&1 && \
    fail_case "없는 스킬 참조 차단" "exit 0으로 통과함" || \
    assert_contains "$(cat "${dir}/e005.log")" "HRN-E005" "없는 하네스 스킬 → HRN-E005"

  # (6) superpowers 미설치는 비차단 — 기존 W014 계약 유지
  #     (참조 문자열이 superpowers: 접두사면 파일 실존을 요구하지 않는다)
  sed 's/skills: \[superpowers:brainstorming\]/skills: [superpowers:nonexistent-xyz]/' \
    "${REPO_ROOT}/harness.config.yaml" > "${dir}/sp-ref.yaml"
  if "$vc" "${dir}/sp-ref.yaml" >"${dir}/w014.log" 2>&1; then
    pass_case "superpowers 미상 스킬은 비차단 (exit 0)"
  else
    fail_case "superpowers 미상 스킬 비차단" "차단됨 — W014 계약 위반"
  fi

  # (7) effort 미적용 사실을 보고에 노출
  assert_contains "$(cat "${dir}/ok.log")" "effort" "요약이 effort 미지원 사실을 알린다"

  # (8) superpowers 설치 상태에서는 W014를 내지 않는다 (오발화 회귀 방지)
  if [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" ] &&
     grep -q 'superpowers@' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" 2>/dev/null; then
    assert_not_contains "$(cat "${dir}/ok.log")" "HRN-W014" \
      "superpowers 설치됨 → W014 미출력 (오발화 회귀 방지)"
    assert_contains "$(cat "${dir}/ok.log")" "superpowers v" \
      "superpowers 설치됨 → 확인 메시지 출력"
  else
    pass_case "superpowers 미설치 환경 — 오발화 케이스 건너뜀"
  fi

  # (9) 미설치 환경 모사 — 빈 매니페스트 디렉토리를 CLAUDE_CONFIG_DIR로 주입
  local fakecfg="${dir}/fakecfg"; mkdir -p "${fakecfg}/plugins"
  printf '{"version":2,"plugins":{}}' > "${fakecfg}/plugins/installed_plugins.json"
  CLAUDE_CONFIG_DIR="$fakecfg" "$vc" "${dir}/harness.config.yaml" >"${dir}/w014.real.log" 2>&1
  assert_contains "$(cat "${dir}/w014.real.log")" "HRN-W014" \
    "superpowers 미설치 → W014 출력"
  assert_contains "$(cat "${dir}/w014.real.log")" "미발견" \
    "미설치 경고 문구가 PRD §8 정의(미발견)와 일치"

  # (10) 깨진 YAML → raw Traceback 금지, HRN-E004 래핑
  printf 'active_harness: claude\ndefaults: model: sonnet\n  effort: x\n' > "${dir}/broken.yaml"
  "$vc" "${dir}/broken.yaml" >"${dir}/broken.log" 2>&1
  assert_not_contains "$(cat "${dir}/broken.log")" "Traceback" \
    "깨진 YAML → 파이썬 Traceback 미노출"
  assert_not_contains "$(cat "${dir}/broken.log")" "yaml.scanner" \
    "깨진 YAML → 라이브러리 예외명 미노출"
  assert_contains "$(cat "${dir}/broken.log")" "HRN-E004" \
    "깨진 YAML → HRN-E004 로 래핑"
  assert_contains "$(cat "${dir}/broken.log")" "행" \
    "깨진 YAML → 오류 위치(행) 안내"

  # (11) 최상위가 매핑이 아님 → HRN-E004
  printf -- "- a\n- b\n" > "${dir}/notmap.yaml"
  "$vc" "${dir}/notmap.yaml" >"${dir}/notmap.log" 2>&1
  assert_not_contains "$(cat "${dir}/notmap.log")" "Traceback" "리스트 최상위 → Traceback 미노출"
  assert_contains "$(cat "${dir}/notmap.log")" "HRN-E004" "리스트 최상위 → HRN-E004"

  # (12) 빈 컨피그 → E004 만, 'None' 문자열 누출 금지
  printf '{}\n' > "${dir}/empty.yaml"
  "$vc" "${dir}/empty.yaml" >"${dir}/empty.log" 2>&1
  assert_contains "$(cat "${dir}/empty.log")" "HRN-E004" "빈 컨피그 → 필수 키 누락 E004"
  assert_not_contains "$(cat "${dir}/empty.log")" "'None'" \
    "빈 컨피그 → 파이썬 None 문자열 미노출"
  assert_not_contains "$(cat "${dir}/empty.log")" "adapters/None" \
    "빈 컨피그 → None 이 경로에 섞이지 않음"

  # (13) 스키마 손상 → HRN-E005 (배포물 문제)
  #      검증기에 스키마 경로를 주입할 수단이 없으므로, 손상 스키마를 가진
  #      소스 트리 복제본을 만들어 그쪽 validate-config 를 호출한다
  local fakesrc="${dir}/fakesrc"
  mkdir -p "${fakesrc}/config" "${fakesrc}/install" "${fakesrc}/adapters/claude" "${fakesrc}/skills"
  cp "${REPO_ROOT}/install/validate-config" "${REPO_ROOT}/install/validate_config.py" \
     "${REPO_ROOT}/install/lib.sh" "${fakesrc}/install/"
  cp "${REPO_ROOT}/adapters/claude/capabilities.yaml" "${fakesrc}/adapters/claude/"
  printf 'top_level: [broken\n' > "${fakesrc}/config/schema.yaml"
  "${fakesrc}/install/validate-config" "${dir}/harness.config.yaml" >"${dir}/badschema.log" 2>&1
  assert_not_contains "$(cat "${dir}/badschema.log")" "Traceback" "손상 스키마 → Traceback 미노출"
  assert_contains "$(cat "${dir}/badschema.log")" "HRN-E005" "손상 스키마 → HRN-E005"
}

# ============================================================================
# 실행
# ============================================================================
test_rsync_contract
test_setup_contract
test_update_contract
test_meta_corruption
test_rsync_missing
test_harness_cli_missing
test_superpowers_prereq
test_join_lines
test_validate_config

printf '\n=== 요약 ===\n'
printf 'PASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n실패 목록:\n'
  for n in "${FAILED_NAMES[@]}"; do
    printf '  - %s\n' "$n"
  done
  exit 1
fi
exit 0
