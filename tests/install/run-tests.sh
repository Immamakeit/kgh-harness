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

# assert_regex <haystack> <ERE 패턴> <설명>
# 문장 전문 일치도 아니고 단일 키워드 grep도 아닌 "근접·순서" 단언에 쓴다
# (예: 'single.{0,150}dispatch.{0,80}무시' — 두 단어가 이 순서로 이 거리 안에
# 같이 나오는지만 본다. 문구가 다듬어져도 순서·근접성만 유지되면 통과한다).
assert_regex() {
  local haystack="$1" pattern="$2" desc="$3"
  if printf '%s' "$haystack" | grep -Eq -- "$pattern"; then
    pass_case "$desc"
  else
    fail_case "$desc" "패턴 불일치: ${pattern}"
  fi
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
/harness.config.yaml
.git/
.gitignore
tests/
.harnessignore
.harness/
.claude/
EOF

  # 배포 템플릿 — 대상 컨피그는 반드시 이것으로부터 생성돼야 한다.
  mkdir -p "$dir/config"
  cat > "$dir/config/harness.config.template.yaml" <<'EOF'
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

  # 소스 레포 자신의 실사용 컨피그 — 개인 경로가 박혀 있고 배포에서 제외돼야 한다.
  cat > "$dir/harness.config.yaml" <<'EOF'
active_harness: claude
defaults:
  model: sonnet
storage:
  enabled: true
  vault_root: "/SOURCE-PRIVATE/vault"
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

  # 대상에는 이미 target 전용 산출물(work/·.meta·preferences.yaml)이 있다고 가정 —
  # 소스엔 없음. preferences.yaml 은 preference-options 스킬이 대상에서 lazy 생성하는
  # 학습 파일이라, 제외하지 않으면 update 마다 --delete 로 날아간다.
  mkdir -p "$dest/work"
  echo "사용자 작업 문서" > "$dest/work/mydoc.md"
  printf 'SOURCE_PATH=%s\n' "$src" > "$dest/.meta"
  printf 'version: 1\nstats: {}\n' > "$dest/preferences.yaml"
  # 앵커(/preferences.yaml)가 없으면 임의 깊이의 동명 파일까지 오제외된다 — 그 회귀를
  # 잡기 위해 소스에 중첩 동명 파일을 하나 둔다(정상 복사되어야 한다).
  echo "nested-pref" > "$src/skills/dummy/preferences.yaml"

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
  assert_present "$dest/preferences.yaml" "preferences.yaml 보존 (앵커 /preferences.yaml)"
  assert_contains "$(cat "$dest/preferences.yaml")" "stats" "preferences.yaml 내용 불변"
  assert_present "$dest/skills/dummy/preferences.yaml" \
    "중첩 동명 preferences.yaml 오제외 없음 (앵커가 최상위만 적용)"

  # 소스에서 파일 삭제 → 재복사 시 대상에서도 사라져야 함(--delete 전파)
  rm -f "$src/tobedeleted.txt"
  local count2
  count2="$(harness_copy "$src" "$dest" 2>/dev/null)"
  assert_absent "$dest/tobedeleted.txt" "--delete 전파: 소스 삭제 파일이 대상에서도 제거됨"
  assert_present "$dest/work/mydoc.md" "--delete 적용 후에도 work/ 보존"
  assert_present "$dest/.meta" "--delete 적용 후에도 .meta 보존"
  assert_present "$dest/skills/dummy/work/keepme.txt" \
    "--delete 적용 후에도 중첩 동명 work/ 보존(오삭제 없음)"
  assert_present "$dest/preferences.yaml" "--delete 적용 후에도 preferences.yaml 보존"
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
  # 프로젝트 선호 프로필(preference-options, write_to: project) — 대상에서만 자라는
  # 학습 파일이다. 이게 날아가면 업데이트마다 학습이 초기화된다.
  printf 'version: 1\nstats:\n  set-initial.commit_format:\n    bracket-type: 4\n' \
    > "${target}/.harness/preferences.yaml"
  local cfg_before installed_at_before
  cfg_before="$(cat "${target}/harness.config.yaml")"
  installed_at_before="$(grep '^INSTALLED_AT=' "${target}/.harness/.meta")"

  # 소스 변형: 파일 삭제 + 새 컨피그 키 추가 + 새 커밋
  rm -f "${src}/adapters/marker.txt"
  printf '\nnew_feature_key: true\n' >> "${src}/config/harness.config.template.yaml"
  git -C "$src" -c user.email=test@test.local -c user.name=test add -A
  git -C "$src" -c user.email=test@test.local -c user.name=test commit -q -m "bump: remove marker, add config key"

  local out rc
  out="$("${target}/.harness/install/update" </dev/null 2>&1)"; rc=$?
  assert_eq "$rc" "0" "update 정상 종료"

  assert_present "${target}/.harness/work/mydoc.md" "update 후 work/ 보존"
  assert_eq "$(cat "${target}/.harness/work/mydoc.md")" "사용자 작업 문서" "work/ 내용 불변"
  assert_present "${target}/.harness/preferences.yaml" "update 후 프로젝트 선호 프로필 보존"
  assert_contains "$(cat "${target}/.harness/preferences.yaml")" "bracket-type: 4" \
    "프로젝트 선호 프로필 내용 불변 (학습 카운트 유지)"

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

  # ── T6: 사라진 키 안내 (project-conventions) ────────────────────────────
  # update 는 지금까지 **새 키만** 보고 제거된 키는 보지 않았다(comm -23 한 방향).
  # 그 비대칭 때문에, 스키마에서 키를 없애면 기존 설치본이 다음 검증에서 **이유 없이**
  # 멈춘다. 방향을 뒤집은 비교를 추가해 "대상에만 남은 키"도 안내한다(자동 삭제 금지).
  printf '\nlegacy_dead_key: true\n' >> "${target}/harness.config.yaml"
  local out2
  out2="$("${target}/.harness/install/update" </dev/null 2>&1)"
  assert_contains "$out2" "legacy_dead_key" "대상에만 남은 키를 안내에 명시"
  assert_contains "$(cat "${target}/harness.config.yaml")" "legacy_dead_key" \
    "사라진 키를 자동으로 지우지 않음 (안내만)"
  assert_not_contains "$(cat "${target}/harness.config.yaml")" "new_feature_key" \
    "새 설정 키를 자동으로 추가하지 않음(안내만)"
}

# ============================================================================
# 3b. 컨피그 검증기 실행불가 (HRN-W020)
# ============================================================================
test_validator_unavailable() {
  group "컨피그 검증기 실행불가 — HRN-W020"

  # (1) 회귀 방지: 검증기 파일 자체가 없으면 setup의 기존 메시지 그대로.
  #     build_fake_source는 install/{lib.sh,setup,update}만 두고 validate-config를
  #     두지 않으므로, 이 경로는 항상 "검증기 없음"이어야 한다.
  local src1 target1 out1
  src1="$(mktemp -d "${WORK}/w020-src1.XXXXXX")"
  build_fake_source "$src1"
  target1="$(mktemp -d "${WORK}/w020-target1.XXXXXX")"
  out1="$(cd "$src1" && ./install/setup "$target1" </dev/null 2>&1)"
  assert_contains "$out1" "건너뜀 (검증기 없음 — install/update로 최신본을 받으세요)" \
    "검증기 파일 부재 — setup 기존 메시지 유지(회귀 없음)"
  assert_not_contains "$out1" "HRN-W020" "검증기 파일 부재 시 W020 오발화 없음(setup)"

  # (2)(3) 검증기 파일은 있으나 실행 비트가 없음 → HRN-W020, rc=0 (setup·update 둘 다)
  # root 함정: access()/execve() 둘 다 실행 비트가 하나도 없는 파일은 root라도 거부한다
  # (capabilities(7): CAP_DAC_OVERRIDE도 "적어도 하나의 x비트 존재"를 전제한다)는 것이
  # 알려진 커널 동작이지만, 이 실행 환경에서 실측하지 않은 채 단정하지는 않는다 —
  # test_hook_doc_state의 선례를 따라 root면 건너뛰고 사유를 pass 메시지에 남긴다.
  if [ "$(id -u)" = "0" ]; then
    pass_case "검증기 실행 비트 없음 → W020 (root 실행 — 권한 검사 신뢰 불가, 건너뜀)"
  else
    local src2 target2 out2 rc2
    src2="$(mktemp -d "${WORK}/w020-src2.XXXXXX")"
    build_fake_source "$src2"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${src2}/install/validate-config"
    chmod 644 "${src2}/install/validate-config"
    git -C "$src2" -c user.email=test@test.local -c user.name=test add -A
    git -C "$src2" -c user.email=test@test.local -c user.name=test commit -q \
      -m "add non-exec validate-config"

    target2="$(mktemp -d "${WORK}/w020-target2.XXXXXX")"
    out2="$(cd "$src2" && ./install/setup "$target2" </dev/null 2>&1)"; rc2=$?
    assert_eq "$rc2" "0" "검증기 실행 비트 없음 — setup은 rc=0으로 완주(비차단)"
    assert_contains "$out2" "HRN-W020" "검증기 실행 비트 없음 → HRN-W020 출력(setup)"
    assert_contains "$out2" "건너뜀 (검증기 실행 불가 — 위 HRN-W020 참조)" \
      "종료 요약 문구가 '검증기 없음'과 구분됨(setup)"
    local out2_flat
    out2_flat="$(tr '\n' ' ' <<< "$out2")"
    assert_regex "$out2_flat" 'HRN-W020[^~]{0,300}chmod \+x' \
      "HRN-W020 복구경로 1: chmod +x 안내 실존"
    assert_regex "$out2_flat" 'HRN-W020[^~]{0,400}검증 없이 진행' \
      "HRN-W020 복구경로 2: 검증 없이 진행 안내 실존"

    # update 경로 — 재복사 후에도 같은 비실행 파일이 유지되어 W020이 재현되는지
    local out3 rc3
    out3="$("${target2}/.harness/install/update" </dev/null 2>&1)"; rc3=$?
    assert_eq "$rc3" "0" "검증기 실행 비트 없음 — update도 rc=0으로 완주(비차단)"
    assert_contains "$out3" "HRN-W020" "검증기 실행 비트 없음 → HRN-W020 출력(update)"
    assert_contains "$out3" "건너뜀 (검증기 실행 불가 — 위 HRN-W020 참조)" \
      "종료 요약 문구가 '검증기 없음'과 구분됨(update)"
  fi

  # (4) 회귀 방지: 검증기 파일 자체가 없으면 update의 기존 메시지도 그대로.
  local src4 target4 out4
  src4="$(mktemp -d "${WORK}/w020-src4.XXXXXX")"
  build_fake_source "$src4"
  target4="$(mktemp -d "${WORK}/w020-target4.XXXXXX")"
  ( cd "$src4" && ./install/setup "$target4" </dev/null >/dev/null 2>&1 )
  echo "dummy adapter v2" > "${src4}/adapters/marker.txt"
  git -C "$src4" -c user.email=test@test.local -c user.name=test add -A
  git -C "$src4" -c user.email=test@test.local -c user.name=test commit -q -m "bump marker"
  out4="$("${target4}/.harness/install/update" </dev/null 2>&1)"
  assert_contains "$out4" "건너뜀 (검증기 없음 — 소스가 오래됐을 수 있음)" \
    "검증기 파일 부재 — update 기존 메시지 유지(회귀 없음)"
  assert_not_contains "$out4" "HRN-W020" "검증기 파일 부재 시 W020 오발화 없음(update)"
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
  #     2026-11-06: 기본 컨피그·배포 템플릿에서 effort 를 **주석 처리**했다(갓 설치한
  #     프로젝트의 첫 검증부터 "무시됩니다" 경고가 나오던 노이즈 제거). 없앤 것은
  #     기본값이고 "지정하면 알린다"는 계약은 그대로다 — 그래서 명시적으로 넣어 본다.
  sed 's/^defaults:/defaults:\n  effort: high/' "${REPO_ROOT}/harness.config.yaml" > "${dir}/eff.yaml"
  "$vc" "${dir}/eff.yaml" >"${dir}/eff.log" 2>&1 || true
  assert_contains "$(cat "${dir}/eff.log")" "effort" "effort 를 지정하면 미지원 사실을 알린다"
  assert_not_contains "$(cat "${dir}/ok.log")" "effort 는" \
    "기본 컨피그는 effort 경고를 내지 않는다 (배포 기본값의 노이즈 0)"

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

  # ── agent_mode (2026-08-25 신설) ──────────────────────────────────────
  # (14) agent_mode 없는 구버전 컨피그 → 그대로 통과 (하위호환, 설계 §3-6)
  #      원본 harness.config.yaml 자체가 이미 agent_mode 미보유 상태이므로 (1)과 같은
  #      픽스처를 재사용해도 되지만, 의도를 분명히 하기 위해 별도 케이스로 남긴다.
  if "$vc" "${dir}/harness.config.yaml" >"${dir}/am-none.log" 2>&1; then
    pass_case "agent_mode 없는 구버전 컨피그 → 통과 (하위호환)"
  else
    fail_case "agent_mode 없는 구버전 컨피그 → 통과" "exit=$? — $(tail -2 "${dir}/am-none.log")"
  fi

  # (15) agent_mode: single → 통과
  { cat "${REPO_ROOT}/harness.config.yaml"; printf 'agent_mode: single\n'; } \
    > "${dir}/am-single.yaml"
  if "$vc" "${dir}/am-single.yaml" >"${dir}/am-single.log" 2>&1; then
    pass_case "agent_mode: single → 통과"
  else
    fail_case "agent_mode: single → 통과" "exit=$? — $(tail -2 "${dir}/am-single.log")"
  fi

  # (16) agent_mode: multi → 통과
  { cat "${REPO_ROOT}/harness.config.yaml"; printf 'agent_mode: multi\n'; } \
    > "${dir}/am-multi.yaml"
  if "$vc" "${dir}/am-multi.yaml" >"${dir}/am-multi.log" 2>&1; then
    pass_case "agent_mode: multi → 통과"
  else
    fail_case "agent_mode: multi → 통과" "exit=$? — $(tail -2 "${dir}/am-multi.log")"
  fi

  # (17) agent_mode: 오타값 → 구조 검사는 여전히 통과 (설계 §3-3의 의도된 한계 —
  #      top_level 스칼라 값은 검증기가 검사하지 않는다. 여기서 비-PASS가 나오면
  #      오히려 그 한계가 깨졌다는 뜻이므로 먼저 원인을 규명해야 한다)
  { cat "${REPO_ROOT}/harness.config.yaml"; printf 'agent_mode: bogus\n'; } \
    > "${dir}/am-typo.yaml"
  if "$vc" "${dir}/am-typo.yaml" >"${dir}/am-typo.log" 2>&1; then
    pass_case "agent_mode: 오타값도 구조검사는 통과 (설계 §3-3 의도된 한계)"
  else
    fail_case "agent_mode: 오타값도 구조검사는 통과" "exit=$? — $(tail -2 "${dir}/am-typo.log")"
  fi

  # ── preferences (2026-08-25 신설, preference-options 국면 B T5) ────────
  # 스킬 문서(skills/preference-options/SKILL.md)가 preferences.write_to 를
  # 설명하는데 스키마에 그 키가 없으면, 사용자가 문서대로 컨피그를 적는 순간
  # HRN-E004(알 수 없는 최상위 키)로 차단된다. 아래가 그 불일치를 잡는다.

  # (18) preferences 블록이 있는 컨피그 → 통과 (top_level 등록 확인)
  { cat "${REPO_ROOT}/harness.config.yaml"
    printf 'preferences:\n  write_to: global\n'; } > "${dir}/pref-global.yaml"
  if "$vc" "${dir}/pref-global.yaml" >"${dir}/pref-global.log" 2>&1; then
    pass_case "preferences.write_to: global → 통과"
  else
    fail_case "preferences.write_to: global → 통과" "exit=$? — $(tail -2 "${dir}/pref-global.log")"
  fi

  # (19) write_to: project → 통과 (허용값 둘 다 살아 있는지)
  { cat "${REPO_ROOT}/harness.config.yaml"
    printf 'preferences:\n  write_to: project\n'; } > "${dir}/pref-project.yaml"
  if "$vc" "${dir}/pref-project.yaml" >"${dir}/pref-project.log" 2>&1; then
    pass_case "preferences.write_to: project → 통과"
  else
    fail_case "preferences.write_to: project → 통과" "exit=$? — $(tail -2 "${dir}/pref-project.log")"
  fi

  # (20) write_to 오타값 → 구조 검사는 통과 (bootstrap.prompt·agent_mode 와 같은
  #      의도된 한계 — 검증기는 top_level 하위 스칼라 값을 보지 않는다. 여기서
  #      비-PASS가 나오면 한계가 깨진 것이므로 원인부터 규명한다).
  #      값 해석("project 가 아니면 전부 global")은 스킬 문서가 소유한다.
  { cat "${REPO_ROOT}/harness.config.yaml"
    printf 'preferences:\n  write_to: bogus\n'; } > "${dir}/pref-typo.yaml"
  if "$vc" "${dir}/pref-typo.yaml" >"${dir}/pref-typo.log" 2>&1; then
    pass_case "preferences.write_to: 오타값도 구조검사는 통과 (의도된 한계)"
  else
    fail_case "preferences.write_to: 오타값도 구조검사는 통과" "exit=$? — $(tail -2 "${dir}/pref-typo.log")"
  fi

  # (21) preferences 블록이 통째로 없는 구버전 컨피그 → 통과 (하위호환)
  awk '/^preferences:/{skip=1; next} skip && /^[[:space:]]/{next} {skip=0; print}' \
    "${REPO_ROOT}/harness.config.yaml" > "${dir}/pref-none.yaml"
  assert_not_contains "$(cat "${dir}/pref-none.yaml")" "write_to" \
    "구버전 픽스처에서 preferences 블록이 실제로 제거됨"
  if "$vc" "${dir}/pref-none.yaml" >"${dir}/pref-none.log" 2>&1; then
    pass_case "preferences 없는 구버전 컨피그 → 통과 (하위호환)"
  else
    fail_case "preferences 없는 구버전 컨피그 → 통과" "exit=$? — $(tail -2 "${dir}/pref-none.log")"
  fi

  # (22) 루트 컨피그와 배포 템플릿 **둘 다** 그대로 검증을 통과한다.
  #      스키마에만 키를 넣고 컨피그에는 안 넣으면 (18)은 통과하지만 실사용
  #      파일에는 그 키가 없어, 다음 사람이 문서를 보고 손으로 적어야 한다.
  assert_contains "$(cat "${REPO_ROOT}/harness.config.yaml")" "write_to" \
    "루트 컨피그에 preferences.write_to 실존"
  assert_contains "$(cat "${REPO_ROOT}/config/harness.config.template.yaml")" "write_to" \
    "배포 템플릿에 preferences.write_to 실존"
  if "$vc" "${REPO_ROOT}/config/harness.config.template.yaml" >"${dir}/tmpl.log" 2>&1; then
    pass_case "배포 템플릿 컨피그 → 검증 통과"
  else
    fail_case "배포 템플릿 컨피그 → 검증 통과" "exit=$? — $(tail -2 "${dir}/tmpl.log")"
  fi

  # ── preferences.as_recommended (2026-08-25 신설, 국면 C T8) ─────────────
  # 검증기는 preferences 하위 키를 보지 않으므로 (23)~(25)는 "차단되지 않는다"만
  # 확인한다 — 값 해석(true 가 아니면 전부 false)은 플레이북·스킬 문서가 소유한다.
  # 실질적인 RED 는 (26): 스키마·루트·템플릿 셋 다에 키가 실존하는가.

  # (23) as_recommended: true → 통과
  awk '/^preferences:/{print; print "  as_recommended: true"; next} {print}' \
    "${REPO_ROOT}/harness.config.yaml" > "${dir}/ar-true.yaml"
  if "$vc" "${dir}/ar-true.yaml" >"${dir}/ar-true.log" 2>&1; then
    pass_case "preferences.as_recommended: true → 통과"
  else
    fail_case "preferences.as_recommended: true → 통과" "exit=$? — $(tail -2 "${dir}/ar-true.log")"
  fi

  # (24) as_recommended: false → 통과
  awk '/^preferences:/{print; print "  as_recommended: false"; next} {print}' \
    "${REPO_ROOT}/harness.config.yaml" > "${dir}/ar-false.yaml"
  if "$vc" "${dir}/ar-false.yaml" >"${dir}/ar-false.log" 2>&1; then
    pass_case "preferences.as_recommended: false → 통과"
  else
    fail_case "preferences.as_recommended: false → 통과" "exit=$? — $(tail -2 "${dir}/ar-false.log")"
  fi

  # (25) as_recommended 오타값 → 구조 검사는 통과 (의도된 한계).
  #      값 해석은 "true 가 아니면 전부 false" — write_to·bootstrap.prompt 와
  #      안전 방향이 각각 다르다(플레이북 §1-5).
  awk '/^preferences:/{print; print "  as_recommended: yess"; next} {print}' \
    "${REPO_ROOT}/harness.config.yaml" > "${dir}/ar-typo.yaml"
  if "$vc" "${dir}/ar-typo.yaml" >"${dir}/ar-typo.log" 2>&1; then
    pass_case "preferences.as_recommended: 오타값도 구조검사는 통과 (의도된 한계)"
  else
    fail_case "preferences.as_recommended: 오타값도 구조검사는 통과" "exit=$? — $(tail -2 "${dir}/ar-typo.log")"
  fi

  # (26) 스키마·루트·템플릿 셋 다에 as_recommended 가 실존한다.
  #      스키마에만 적고 실사용 파일에 안 넣으면 다음 사람이 문서를 보고 손으로
  #      적어야 한다 — write_to 때와 같은 계약이다.
  assert_contains "$(cat "${REPO_ROOT}/config/schema.yaml")" "as_recommended" \
    "스키마에 preferences.as_recommended 정의 실존"
  assert_contains "$(cat "${REPO_ROOT}/harness.config.yaml")" "as_recommended" \
    "루트 컨피그에 preferences.as_recommended 실존"
  assert_contains "$(cat "${REPO_ROOT}/config/harness.config.template.yaml")" "as_recommended" \
    "배포 템플릿에 preferences.as_recommended 실존"

  # ── workdocs.layout · names (project-conventions T4) ───────────────────
  # 역할 3개(design/plan/report)는 게이트와 묶여 있어 개수·의미를 못 바꾼다.
  # 바뀌는 것은 표시 이름과 하위 경로뿐이다 — 그래서 **부분 지정이 가장 위험한 입력**
  # 이다(둘만 적으면 나머지 하나를 무엇으로 부를지 아무도 모른다).

  # (28) layout·names 를 전부 지정 → 통과
  wd_fixture "$REPO_ROOT" "design: design.md|plan: plan.md|report: report.md" \
    > "${dir}/wd-full.yaml"
  if "$vc" "${dir}/wd-full.yaml" >"${dir}/wd-full.log" 2>&1; then
    pass_case "workdocs.layout + names 전부 지정 → 통과"
  else
    fail_case "workdocs.layout + names 전부 지정 → 통과" "exit=$? — $(tail -3 "${dir}/wd-full.log")"
  fi

  # (29) names 를 아예 안 쓰면 → 통과 (하위호환)
  if "$vc" "${REPO_ROOT}/harness.config.yaml" >"${dir}/wd-none.log" 2>&1; then
    pass_case "workdocs.names 부재 → 통과 (하위호환)"
  else
    fail_case "workdocs.names 부재 → 통과" "exit=$? — $(tail -3 "${dir}/wd-none.log")"
  fi

  # (30) 역할 하나를 빼면 → HRN-E004 차단
  wd_fixture "$REPO_ROOT" "design: design.md|plan: plan.md" > "${dir}/wd-part.yaml"
  if "$vc" "${dir}/wd-part.yaml" >"${dir}/wd-part.log" 2>&1; then
    fail_case "workdocs.names 역할 누락 → 차단" "exit 0 으로 통과함"
  else
    assert_contains "$(cat "${dir}/wd-part.log")" "HRN-E004" "workdocs.names 역할 누락 → HRN-E004"
    assert_contains "$(cat "${dir}/wd-part.log")" "report" "누락된 역할명을 그대로 지목"
  fi

  # (31) storage.docs 제거 — 읽는 곳이 0곳인 채 스키마에만 선언돼 "설정 표면이 있는 척"
  #      을 하던 키다. 문서 이름은 workdocs.names 가 소유한다(같은 것을 두 곳에서 정하지 않는다).
  #
  #      **주의 — 계획 §6 의 가정은 틀렸다.** "제거하면 기존 설치본이 HRN-E004 로 멈춘다"
  #      고 적었지만, 검증기는 **최상위 키만** 미지 여부를 본다(validate_config.py ① 구조).
  #      storage.docs 는 하위 키라 애초에 검증 대상이 아니었고, 제거해도 차단되지 않는다.
  #      아래 두 케이스가 그 사실을 고정한다 — 잘못된 가정이 다시 들어오지 못하게.
  python3 - "$REPO_ROOT" > "${dir}/legacy-docs.yaml" <<'PYEOF'
import io, sys
s = io.open(sys.argv[1] + "/harness.config.yaml", encoding="utf-8").read()
s = s.replace("storage:\n", "storage:\n  docs: [설계, 구현계획, 구현후보고]\n")
sys.stdout.write(s)
PYEOF
  if "$vc" "${dir}/legacy-docs.yaml" >"${dir}/legacy-docs.log" 2>&1; then
    pass_case "storage.docs 잔존은 차단되지 않는다 (하위 키는 검증 대상이 아님)"
  else
    fail_case "storage.docs 잔존은 차단되지 않는다" "exit=$? — $(tail -3 "${dir}/legacy-docs.log")"
  fi
  # 반면 **최상위** 미지 키는 여전히 차단된다 — GONE_KEYS 안내가 필요한 쪽은 이쪽이다
  { cat "${REPO_ROOT}/harness.config.yaml"; printf 'legacy_top_key: 1\n'; } > "${dir}/legacy-top.yaml"
  if "$vc" "${dir}/legacy-top.yaml" >"${dir}/legacy-top.log" 2>&1; then
    fail_case "최상위 미지 키는 차단됨" "exit 0 으로 통과함"
  else
    assert_contains "$(cat "${dir}/legacy-top.log")" "HRN-E004" "최상위 미지 키 → HRN-E004"
  fi
  # 스키마에서 실제로 빠졌는지 (workdocs: 가 'docs:' 를 부분문자열로 포함하므로 앵커를 건다)
  if grep -qE '^  docs:' "${REPO_ROOT}/config/schema.yaml"; then
    fail_case "스키마에서 storage.docs 제거됨" "^  docs: 가 아직 존재함"
  else
    pass_case "스키마에서 storage.docs 제거됨"
  fi

  # ── commit.format · commit.types (project-conventions T7) ──────────────
  # 검증기는 **구조만** 본다 — 어떤 작업유형이 옳은지는 프로젝트가 소유한다.
  # 그 계약 자체를 케이스로 고정해, 나중에 과잉 검증이 끼어들지 못하게 한다.

  # (32) 기본값(하네스 현행 형식) → 통과
  if "$vc" "${REPO_ROOT}/harness.config.yaml" >"${dir}/cm-def.log" 2>&1; then
    pass_case "commit 기본값 → 통과"
  else
    fail_case "commit 기본값 → 통과" "exit=$? — $(tail -3 "${dir}/cm-def.log")"
  fi
  assert_contains "$(cat "${REPO_ROOT}/harness.config.yaml")" "commit:" "루트 컨피그에 commit 블록 실존"
  # 스키마에만 키를 넣고 컨피그에는 안 넣으면 다음 사람이 문서를 보고 손으로 적어야 한다
  # (preference-options T5 에서 세운 계약). ⑧ 검증에서 skills 키가 실제로 이 구멍에
  # 빠져 있던 것을 발견해 단언으로 고정한다.
  assert_contains "$(cat "${REPO_ROOT}/harness.config.yaml")" "project_path" \
    "루트 컨피그에 skills.project_path 실존"
  assert_contains "$(cat "${REPO_ROOT}/config/harness.config.template.yaml")" "project_path" \
    "배포 템플릿에 skills.project_path 실존"
  assert_contains "$(cat "${REPO_ROOT}/config/harness.config.template.yaml")" "commit:" \
    "배포 템플릿에 commit 블록 실존"

  # (33) 대괄호 없는 형식(후보 저장소 규약) → 통과
  cm_fixture "$REPO_ROOT" '"{type}: {message}"' "feat, fix, merge" > "${dir}/cm-plain.yaml"
  if "$vc" "${dir}/cm-plain.yaml" >"${dir}/cm-plain.log" 2>&1; then
    pass_case "commit.format 대괄호 없는 형식 → 통과"
  else
    fail_case "commit.format 대괄호 없는 형식 → 통과" "exit=$? — $(tail -3 "${dir}/cm-plain.log")"
  fi

  # (34) 치환자가 빠진 format → 차단
  cm_fixture "$REPO_ROOT" '"고정 메시지"' "feat, fix" > "${dir}/cm-noph.yaml"
  if "$vc" "${dir}/cm-noph.yaml" >"${dir}/cm-noph.log" 2>&1; then
    fail_case "commit.format 치환자 누락 → 차단" "exit 0 으로 통과함"
  else
    assert_contains "$(cat "${dir}/cm-noph.log")" "HRN-E004" "치환자 누락 → HRN-E004"
    assert_contains "$(cat "${dir}/cm-noph.log")" "{type}" "누락된 치환자를 그대로 지목"
  fi

  # (35) 빈 types → 차단
  cm_fixture "$REPO_ROOT" '"[{type}]: {message}"' "" > "${dir}/cm-empty.yaml"
  if "$vc" "${dir}/cm-empty.yaml" >"${dir}/cm-empty.log" 2>&1; then
    fail_case "commit.types 비어 있음 → 차단" "exit 0 으로 통과함"
  else
    assert_contains "$(cat "${dir}/cm-empty.log")" "HRN-E004" "빈 commit.types → HRN-E004"
  fi

  # (36) 플레이북이 형식을 하드코딩하지 않고 commit.format 을 참조한다
  local pb2_flat
  pb2_flat="$(tr '\n' ' ' < "${REPO_ROOT}/core/playbook.md" | tr -s ' ')"
  assert_contains "$pb2_flat" "commit.format" "플레이북 §6: commit.format 참조 실존"

  # (27) 배포 템플릿의 as_recommended 는 꺼진 채로 나간다 — 설치하자마자 질문이
  #      자동으로 건너뛰어지면 새 사용자에게 가장 놀랍다(설계 §3-3 안전측 기본).
  assert_regex "$(grep -E '^\s*as_recommended:' "${REPO_ROOT}/config/harness.config.template.yaml")" \
    'as_recommended:[[:space:]]*false' "배포 템플릿의 as_recommended 는 false"
}

# ---- 플레이북 규칙 실존 계약 (agent-mode T7·T9) -----------------------------
# 주의: 이 그룹은 "행동을 검증"하지 않는다 — 플레이북은 LLM이 읽는 프롬프트
# 문서라 셸로는 그 지침대로 실제로 행동했는지 확인할 수 없다(설계 §4 비대상).
# 여기서 잡는 것은 딱 하나, **문서 계약**이다: §1-2-1·§3 핵심 문단이 리팩터링
# 중 통째로 사라지거나, HRN-W016 근거 명시 요구가 빠지는 것. 단언은 "근접·순서"
# 정도로만 걸어 문구를 다듬어도 깨지지 않게 하되(느슨한 grep agent_mode 하나로는
# 아무것도 보증 못 함), 문장 전문 일치도 요구하지 않는다(사소한 수정마다 깨짐).
test_playbook_rule_contracts() {
  group "플레이북 — 규칙 실존 계약 (문서 계약 단언, 행동 검증 아님)"

  local pb="${REPO_ROOT}/core/playbook.md"
  assert_present "$pb" "core/playbook.md 실존"

  local flat
  flat="$(tr '\n' ' ' < "$pb" | tr -s ' ')"

  # §1-2-1: agent_mode 해석 항목이 §1 안에 실존
  assert_regex "$flat" '2-1\.[^~]{0,60}agent_mode[^~]{0,100}해석' \
    "§1-2-1: agent_mode 해석 항목 실존"

  # "single이면 dispatch를 무시한다" 취지 (정확한 문장이 아니라 세 키워드의 근접·순서)
  assert_regex "$flat" 'single[^~]{0,150}dispatch[^~]{0,80}무시' \
    "'single이면 dispatch 무시' 취지 문장 실존"

  # HRN-W016 코드 자체 + 복구 경로 2개(a)/(b)가 그 코드 근처에 실존
  assert_contains "$flat" "HRN-W016" "HRN-W016 코드 문구 실존"
  assert_regex "$flat" 'HRN-W016[^~]{0,400}\(a\)[^~]{0,150}\(b\)' \
    "HRN-W016 근처 복구 경로 2개 (a)/(b) 실존"

  # §3의 "실효 모드 판정" — 설계 문서가 아닌 이 문서 §3의 정의어. 리뷰어가 이번에
  # 지적한 번호 겹침(T6)을 해소하며 도입한 표현이라 그대로 고정 문구로 단언한다.
  assert_contains "$flat" "실효 모드 판정" "§3: '실효 모드 판정' 실존"

  # T9: HRN-W016 판단 근거 명시 요구 — 사전 신호(관찰한 근거)와 사후 신호(거부 응답
  # 인용)를 각각 요구하는 문장이 해당 항목 근처에 실존하는지 따로 확인한다.
  assert_regex "$flat" '사전 신호 확인[^~]{0,700}관찰한 근거' \
    "HRN-W016 사전 신호: 관찰 근거 명시 요구 실존 (T9)"
  assert_regex "$flat" '시도 후에만 드러나는 실패[^~]{0,700}거부 응답' \
    "HRN-W016 사후 신호: 거부 응답 인용 요구 실존 (T9)"

  # validator-unavailable (2026-08-25): 검증기가 있는데 실행 불가한 경우의 분기.
  # HRN-E005("검증기가 없으면")와 나란히, HRN-W020("있는데 실행되지 않으면")이
  # 실존해야 한다 — 이 칸이 빠져 있던 것이 agent-mode 관찰에서 드러난 결함의 근본
  # 원인이었다(HRN-W015를 잘못 골라 씀).
  assert_contains "$flat" "HRN-W020" "HRN-W020 코드 문구 실존"
  assert_regex "$flat" 'HRN-E005[^~]{0,60}install/update[^~]{0,80}실행되지 않으면[^~]{0,150}HRN-W020' \
    "검증기 '없음(E005)'과 '있으나 실행 불가(W020)' 분기가 나란히 실존"
  assert_regex "$flat" 'HRN-W020[^~]{0,80}흐름은 계속한다' \
    "HRN-W020: 비차단 취지 실존"

  # ── as_recommended (preference-options 국면 C T9) ──────────────────────
  # 여기서 잡는 것은 **문서 계약**뿐이다 — 플레이북대로 실제로 행동했는지는 셸로
  # 확인할 수 없다(§ 이 그룹 머리 주석). 그 한계 때문에 이 국면의 실질 행동 검증은
  # T10 헤드리스 관찰이 맡는다. 여기서는 "리팩터링 중 조항이 통째로 사라지는 것"만 막는다.

  assert_contains "$flat" "as_recommended" "as_recommended 조항 실존"

  # 해석 규칙: true 가 아니면 전부 false (write_to·bootstrap.prompt 와 방향이 다르다)
  assert_regex "$flat" 'as_recommended[^~]{0,200}true[^~]{0,120}false' \
    "as_recommended: 'true 가 아니면 false' 취지 실존"

  # 자동 채택 절차: 표로 모아 보여준 뒤 진행 + 되돌리기 안내
  assert_regex "$flat" 'as_recommended[^~]{0,900}표[^~]{0,200}다시' \
    "자동 채택: '표로 모아 보여주고 Qn 다시로 되돌린다' 취지 실존"

  # **제외 3개**가 한 자리에 모여 실존 — 이 국면에서 가장 중요한 조항이다.
  # 하나라도 빠지면 "승인 전 구현 금지" 규율이 무너진다.
  assert_regex "$flat" '자동 채택[^~]{0,600}설계 승인[^~]{0,200}판정[^~]{0,200}삭제' \
    "자동 채택 제외 3개(⑤ 설계 승인·⑩ 판정·프로필 삭제) 실존"

  # 제외의 근거가 되는 원칙 하나 — 되돌릴 길이 없는 동작
  assert_regex "$flat" '되돌릴 길[^~]{0,200}되돌릴 수 없는' \
    "제외 원칙('되돌릴 길이 미치지 않는 되돌릴 수 없는 동작') 실존"

  # 자유서술 질문은 애초에 대상이 아니다
  assert_regex "$flat" '자유서술[^~]{0,200}(대상이 아니|자동 채택하지)' \
    "자유서술 질문은 자동 채택 대상이 아님 실존"
}

# ---- 질문 라벨 계약 (question-labels, 2026-08-25) --------------------------
# 사고: 오케스트레이터가 이메일 처리 선택지를 추천 순으로 재배열하면서 라벨을
# 갱신하지 않아 `(b) (a) (c) (d)` 순서로 나갔다. 선택지=번호(표시 순서와 항상
# 일치)·HRN 복구 경로 (a)(b)=선택지가 아닌 안내 라는 규칙이 플레이북 §6에
# 실존하는지, 그리고 set-initial·branch-strategy 두 스킬이 같은 문구를 그대로
# 상속했는지 단언한다. 행동 검증은 못 한다 — 이 결함도 테스트가 아니라
# 사용자의 눈으로 발견됐다(설계 §4 비대상).
test_question_label_contracts() {
  group "질문 라벨 계약 — 선택지=번호, 복구 경로=안내 (question-labels)"

  local pb="${REPO_ROOT}/core/playbook.md"
  local si="${REPO_ROOT}/skills/set-initial/SKILL.md"
  local bs="${REPO_ROOT}/skills/branch-strategy/SKILL.md"
  assert_present "$pb" "core/playbook.md 실존"
  assert_present "$si" "skills/set-initial/SKILL.md 실존"
  assert_present "$bs" "skills/branch-strategy/SKILL.md 실존"

  local pb_flat si_flat bs_flat
  pb_flat="$(tr '\n' ' ' < "$pb" | tr -s ' ')"
  si_flat="$(tr '\n' ' ' < "$si" | tr -s ' ')"
  bs_flat="$(tr '\n' ' ' < "$bs" | tr -s ' ')"

  # "번호는 표시 순서와 일치" 취지 — 재정렬 시 재넘버링까지 근접해 실존
  assert_regex "$pb_flat" '번호는[^~]{0,20}표시 순서[^~]{0,20}일치' \
    "§6: '번호는 표시 순서와 일치' 취지 실존"

  # "복구 경로 (a)(b)는 선택지가 아니라 안내" 취지 — HRN 근처에 (a)(b)와
  # "선택지가 아니"가 함께 실존해야 한다
  assert_regex "$pb_flat" 'HRN[^~]{0,30}복구 경로[^~]{0,10}\(a\)[^~]{0,10}\(b\)[^~]{0,40}선택지가 아니' \
    "§6: HRN 복구 경로 (a)(b)는 '선택지가 아니다' 취지 실존"

  # 상속 문구 — 두 스킬에 동일하게 실존. 문구가 갈리면 이 작업의 취지가 무너진다
  assert_regex "$si_flat" '번호는[^~]{0,20}표시 순서[^~]{0,20}일치' \
    "set-initial 질문 계약: '번호는 표시 순서와 일치' 상속 실존"
  assert_regex "$bs_flat" '번호는[^~]{0,20}표시 순서[^~]{0,20}일치' \
    "branch-strategy 질문 계약: '번호는 표시 순서와 일치' 상속 실존"

  # plan-doc 범위 게이트 — 사용자가 고르는 선택지이므로 번호여야 한다
  local pd_flat
  pd_flat="$(tr '\n' ' ' < "${REPO_ROOT}/skills/plan-doc/SKILL.md")"
  assert_regex "$pd_flat" '비대상입니다[^~]{0,80}1\)[^~]{0,80}2\)' \
    "plan-doc 범위 게이트 선택지가 번호(1)/2))로 제시됨"
  assert_regex "$pb_flat" '이진 확인[^~]{0,60}예외|Y/n[^~]{0,60}예외' \
    "플레이북: Y/n 이진 확인이 번호 규칙의 예외임을 명시"
  # 리터럴 한 문자열만 막으면 볼드를 떼거나 문구를 바꿔 다시 넣을 수 있다(⑧ 검증에서
  # 뮤테이션으로 실증됨). plan-doc 은 HRN 코드를 내지 않으므로 (a)/(b) 가 정당하게
  # 쓰일 자리가 없다 — 문서 전체에서 부재를 단언한다. 나중에 이 스킬이 HRN 복구 경로를
  # 갖게 되면 그때 이 단언을 의식적으로 고친다.
  assert_regex "$pd_flat" '^[^~]*$' "plan-doc 읽기 성공"
  case "$pd_flat" in
    *'(a)'*|*'(b)'*) fail_case "plan-doc 에 알파벳 라벨 부재" "(a) 또는 (b) 가 발견됨" ;;
    *) pass_case "plan-doc 에 알파벳 라벨 부재" ;;
  esac
}

# ---- 플레이북 절 참조 정합 (agent-mode T8) ----------------------------------
# `§x-y` 형태의 문서 내부 참조가 실재하는 절을 가리키는지 파이썬으로 파싱해 대조한다.
# ⑧ 리뷰어가 지난 회차에 손으로 확인해준 항목 — 손으로 할 일이면 테스트가 할 일이다.
# 외부 문서 참조(예: "설계 §3-4", "PRD §10")는 대상이 아니다 — § 바로 앞 문맥에
# 다른 문서 이름이 있으면 내부 참조 검사에서 제외한다.
check_playbook_cross_refs() {
  python3 - "$1" <<'PYEOF'
import re, sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
lines = text.split("\n")

EXTERNAL_MARKERS = ("설계", "PRD", "구현계획", "계획서")

# 1) 절 헤더 수집: "## N. 제목" / "### N-M. 제목"
headings = set()
# 2) 절 내부의 번호 목록 항목 수집: 줄 시작이 "N." 또는 "**N."(굵게 시작)인 항목.
#    현재 소속 절(직전 "## N." 헤더)에 귀속시킨다 — §1-5, §1-2-1 처럼
#    "절-항목" 형태 참조를 해소하기 위함.
items = {}  # section(str) -> set of item numbers(str)
current_section = None

heading_re = re.compile(r'^#{2,3}\s+(\d+(?:-\d+)?)\.')
top_heading_re = re.compile(r'^##\s+(\d+)\.')
item_re = re.compile(r'^\**(\d+(?:-\d+)?)\.\s')

for line in lines:
    hm = heading_re.match(line)
    if hm:
        headings.add(hm.group(1))
    thm = top_heading_re.match(line)
    if thm:
        current_section = thm.group(1)
        items.setdefault(current_section, set())
        continue
    im = item_re.match(line)
    if im and current_section is not None:
        items[current_section].add(im.group(1))

# 3) 문서 전체에서 "§X" / "§X-Y" 형태 참조를 위치와 함께 수집, 직전 문맥으로
#    외부 문서 참조를 걸러낸다.
ref_re = re.compile(r'§(\d+(?:-\d+)*)')
broken = []
checked = 0
for m in ref_re.finditer(text):
    start = m.start()
    context = text[max(0, start - 15):start]
    if any(marker in context for marker in EXTERNAL_MARKERS):
        continue  # 다른 문서의 절 참조 — 이 문서 헤더 구조와 무관
    checked += 1
    ref = m.group(1)
    if "-" in ref:
        section, rest = ref.split("-", 1)
    else:
        section, rest = ref, None

    if rest is None:
        ok = section in headings
    else:
        ok = (f"{section}-{rest}" in headings) or (rest in items.get(section, set()))

    if not ok:
        line_no = text.count("\n", 0, start) + 1
        broken.append(f"§{ref} (line {line_no}) → 대응하는 절을 찾지 못함")

if broken:
    print("BROKEN:" + " | ".join(broken))
    sys.exit(1)
print(f"OK:{checked}")
sys.exit(0)
PYEOF
}

# wd_fixture <레포루트> "<names 줄들 | 로 구분>"
# 루트 컨피그에서 workdocs 블록을 통째로 걷어내고 지정한 names 만 다시 넣는다.
# 루트 컨피그에 이미 layout·names 가 있으므로, 단순 삽입은 키 중복이 되어
# YAML last-wins 로 의도와 다른 픽스처가 만들어진다(T4 에서 실제로 겪음).
wd_fixture() {
  python3 - "$1" "$2" <<'PYEOF'
import io, sys
src, names = sys.argv[1] + "/harness.config.yaml", sys.argv[2]
out, skip = [], False
for line in io.open(src, encoding="utf-8"):
    if line.startswith("workdocs:"):
        skip = True
        out.append("workdocs:\n")
        out.append("  path: .harness/work\n")
        if names:
            out.append("  names:\n")
            for n in names.split("|"):
                out.append("    %s\n" % n)
        continue
    if skip:
        if line.strip() == "" or not line.startswith(" "):
            skip = False
        else:
            continue
    out.append(line)
sys.stdout.write("".join(out))
PYEOF
}

# cm_fixture <레포루트> <format> <types 쉼표구분>
# 루트 컨피그의 commit 블록을 통째로 갈아끼운다(wd_fixture 와 같은 이유).
cm_fixture() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import io, sys
src, fmt, types = sys.argv[1] + "/harness.config.yaml", sys.argv[2], sys.argv[3]
out, skip = [], False
for line in io.open(src, encoding="utf-8"):
    if line.startswith("commit:"):
        skip = True
        out.append("commit:\n")
        out.append("  format: %s\n" % fmt)
        out.append("  types: [%s]\n" % types)
        continue
    if skip:
        if line.strip() == "" or not line.startswith(" "):
            skip = False
        else:
            continue
    out.append(line)
sys.stdout.write("".join(out))
PYEOF
}

# ---- setup 의 .gitignore 안내 (project-conventions T8) ----------------------
# **설치 스크립트가 대상 저장소의 파일을 고치는 첫 사례다.** 지금까지는
# harness.config.yaml 생성뿐이었다. 되돌릴 길(중복 방지·거절 시 무변경)과
# 비대화형 폴백이 핵심이라 통합 실행으로 검증한다.
test_setup_gitignore() {
  group "setup — 대상 .gitignore 안내"

  # (1) git 저장소 대상 + 기본 선택(비대화형) → 설치본 경로가 .gitignore 에 들어간다
  local g1
  g1="$(mktemp -d "${WORK}/gi1.XXXXXX")"
  git -C "$g1" init -q
  printf 'node_modules/\n' > "${g1}/.gitignore"
  ( cd "$REPO_ROOT" && ./install/setup "$g1" </dev/null >"${WORK}/gi1.log" 2>&1 )
  assert_contains "$(cat "${g1}/.gitignore")" "/.harness/install/" \
    ".gitignore 에 설치본 경로 추가됨"
  assert_contains "$(cat "${g1}/.gitignore")" "node_modules/" "기존 .gitignore 내용 보존"
  # 작업 산출물은 프로젝트 자산이라 제외하지 않는다
  assert_not_contains "$(cat "${g1}/.gitignore")" "/.harness/work/" \
    ".harness/work/ 는 제외 목록에 넣지 않음 (작업 산출물은 프로젝트 자산)"

  # (2) 재설치 → 중복 추가 없음
  ( cd "$REPO_ROOT" && ./install/setup "$g1" </dev/null >/dev/null 2>&1 )
  local n
  n="$(grep -c '^/\.harness/install/$' "${g1}/.gitignore" || true)"
  assert_eq "$n" "1" "재설치해도 중복 추가 없음"

  # (3) .gitignore 가 없던 대상 → 새로 만들고 그 사실을 보고
  local g2
  g2="$(mktemp -d "${WORK}/gi2.XXXXXX")"
  git -C "$g2" init -q
  ( cd "$REPO_ROOT" && ./install/setup "$g2" </dev/null >"${WORK}/gi2.log" 2>&1 )
  assert_present "${g2}/.gitignore" ".gitignore 가 없으면 새로 만든다"
  assert_contains "$(cat "${WORK}/gi2.log")" ".gitignore" "생성 사실을 보고에 남김"

  # (4) git 저장소가 아니면 질문 자체를 건너뛰고 파일을 만들지 않는다
  local g3
  g3="$(mktemp -d "${WORK}/gi3.XXXXXX")"
  ( cd "$REPO_ROOT" && ./install/setup "$g3" </dev/null >"${WORK}/gi3.log" 2>&1 )
  assert_absent "${g3}/.gitignore" "비-git 대상에는 .gitignore 를 만들지 않음"

  # (5) 설치 요약에 처리 결과가 남는다 (결과 비은닉)
  assert_contains "$(cat "${WORK}/gi1.log")" "gitignore" "설치 요약에 .gitignore 처리 결과 명시"

  # (6) **거절 경로** — 사용자가 2)를 고르면 아무것도 바꾸지 않는다.
  #     파이프로는 ask_choice 가 비대화형 폴백(기본 1)을 타므로 확인할 수 없다.
  #     pty 를 붙여야 실제 선택 경로가 돈다 — 이 절이 대상 저장소 파일을 고치는
  #     유일한 자리라서, "거절하면 무변경"은 실물로 확인해야 하는 계약이다.
  local g4 before4
  g4="$(mktemp -d "${WORK}/gi4.XXXXXX")"
  git -C "$g4" init -q
  printf 'foo/\n' > "${g4}/.gitignore"
  before4="$(cat "${g4}/.gitignore")"
  local mp4
  mp4="$(build_min_path gi4)"
  # 입력 순서: 설치확인 Enter → vault 경로 → .gitignore 선택 2
  run_with_tty '\n/tmp/gi4-vault\n2\n' \
    "export PATH=${mp4}; cd ${REPO_ROOT}; ./install/setup ${g4}" \
    > "${WORK}/gi4.log" 2>&1 || true
  assert_eq "$(cat "${g4}/.gitignore")" "$before4" "거절(2) 시 .gitignore 무변경"
  assert_not_contains "$(cat "${g4}/.gitignore")" ".harness" "거절 시 설치본 경로 미추가"
}

# ---- 작업 문서 이름 소유권 (project-conventions T5) -------------------------
# 문서 계약 단언이다 — 이 파일들은 LLM 이 읽는 지침이라 셸로 행동 검증이 불가능하다
# (agent-mode·preference-options 에서 확립된 방식). 여기서 막는 것은 "컨피그가
# 정한다"는 조항이 리팩터링 중 사라지고 하드코딩만 남는 것이다.
test_workdocs_naming_ownership() {
  group "작업 문서 이름 — workdocs.names 소유권"

  local f flat
  for f in core/playbook.md skills/design-doc/SKILL.md skills/plan-doc/SKILL.md \
           skills/report-doc/SKILL.md skills/obsidian-cli/SKILL.md; do
    assert_present "${REPO_ROOT}/${f}" "${f} 실존"
    flat="$(tr '\n' ' ' < "${REPO_ROOT}/${f}" | tr -s ' ')"
    assert_contains "$flat" "workdocs.names" "${f}: workdocs.names 참조 실존"
  done

  # 스킬 문서 3종은 기본값을 예시로 남기되 "컨피그가 우선"을 명시해야 한다
  # (storage.path_template 이 이미 쓰는 방식 — 예시를 지우면 읽는 쪽이 감을 잃는다)
  for f in skills/design-doc/SKILL.md skills/plan-doc/SKILL.md skills/report-doc/SKILL.md; do
    flat="$(tr '\n' ' ' < "${REPO_ROOT}/${f}" | tr -s ' ')"
    assert_regex "$flat" 'workdocs\.names[^~]{0,200}(우선|정한다|이긴다)' \
      "${f}: '컨피그가 우선' 취지 실존"
  done

  # obsidian-cli 는 vault 저장 파일명도 같은 이름을 따라야 한다 —
  # 같은 문서를 작업 공간과 vault 에서 다른 이름으로 부르면 대조가 불가능해진다
  flat="$(tr '\n' ' ' < "${REPO_ROOT}/skills/obsidian-cli/SKILL.md" | tr -s ' ')"
  assert_regex "$flat" 'workdocs\.names[^~]{0,300}(vault|저장)' \
    "obsidian-cli: vault 저장 파일명도 workdocs.names 를 따름"
}

# ---- 프로젝트 스킬 해석 (project-conventions) -------------------------------
# 설계 §2 가 짚은 테스트 구멍을 메운다: install/setup 은 지금까지 **빈 temp 디렉터리**
# 로만 검증돼, "대상이 자기 skills/ 를 가진 경우"가 한 번도 실행된 적이 없다.
# 소스 레포에서는 프로젝트 루트와 source_dir 가 같은 자리라 이 분기가 가려져 있었다.
test_project_skills_resolution() {
  group "프로젝트 스킬 해석 — 자기 skills/ 를 가진 대상"

  local t
  t="$(mktemp -d "${WORK}/psk.XXXXXX")"
  ( cd "$REPO_ROOT" && ./install/setup "$t" </dev/null >/dev/null 2>&1 )
  assert_present "${t}/.harness/install/validate-config" "대상에 검증기 설치됨"

  # 대상 프로젝트가 **자기 스킬**을 갖고 있다 (후보 저장소의 skills/ 12종과 같은 상황)
  mkdir -p "${t}/skills/myskill"
  cat > "${t}/skills/myskill/SKILL.md" <<'SK'
---
name: myskill
description: Use when the project's own convention applies.
---
# 프로젝트 소유 스킬
SK
  assert_present "${t}/skills/myskill/SKILL.md" "대상 루트에 프로젝트 스킬 존재"

  # 컨피그에서 그 스킬을 참조한다
  awk '/^  implement:/{f=1} f && /^    skills: \[/{sub(/\]$/, ", myskill]"); f=0} {print}' \
    "${t}/harness.config.yaml" > "${t}/c" && mv "${t}/c" "${t}/harness.config.yaml"
  assert_contains "$(cat "${t}/harness.config.yaml")" "myskill" "컨피그가 프로젝트 스킬을 참조"

  # (T1 기준선) 지금은 차단된다 — 프로젝트 루트 skills/ 를 아예 보지 않기 때문이다.
  local log="${t}/vc.log"
  if "${t}/.harness/install/validate-config" "${t}/harness.config.yaml" >"$log" 2>&1; then
    fail_case "프로젝트 스킬 참조가 현재는 차단됨 (T1 기준선)" "exit 0 으로 통과함"
  else
    assert_contains "$(cat "$log")" "HRN-E005" "프로젝트 스킬 참조 → HRN-E005 차단"
  fi
  # 에러가 지목하는 경로가 .harness/skills/ 라는 것이 "프로젝트 경로를 안 본다"의 증거다
  assert_contains "$(cat "$log")" ".harness/skills/myskill/SKILL.md" \
    "에러가 하네스 경로만 지목 (프로젝트 경로 미탐색의 증거)"

  # ── T2: skills.project_path 로 프로젝트 경로를 연다 ─────────────────────
  local cfg="${t}/harness.config.yaml"

  # (1) project_path 를 켜면 통과한다
  { cat "$cfg"; printf 'skills:\n  project_path: skills\n'; } > "${t}/on.yaml"
  if "${t}/.harness/install/validate-config" "${t}/on.yaml" >"${t}/on.log" 2>&1; then
    pass_case "skills.project_path 지정 시 프로젝트 스킬 참조 통과"
  else
    fail_case "skills.project_path 지정 시 프로젝트 스킬 참조 통과" \
      "exit=$? — $(tail -3 "${t}/on.log")"
  fi

  # (2) 하위호환 — project_path 가 없으면 T1 과 똑같이 차단된다.
  #     기본값을 'skills' 로 두면 skills/ 를 가진 기존 설치본의 해석이 조용히 바뀐다.
  if "${t}/.harness/install/validate-config" "$cfg" >"${t}/off.log" 2>&1; then
    fail_case "project_path 부재 시 기존 동작 유지 (차단)" "exit 0 으로 통과함"
  else
    assert_contains "$(cat "${t}/off.log")" "HRN-E005" \
      "project_path 부재 → 기존대로 HRN-E005 (하위호환)"
  fi

  # (3) 이름 충돌 → HRN-E015 차단. 조용히 가려지지 않는다.
  mkdir -p "${t}/skills/design-doc"
  printf -- '---\nname: design-doc\n---\n' > "${t}/skills/design-doc/SKILL.md"
  if "${t}/.harness/install/validate-config" "${t}/on.yaml" >"${t}/dup.log" 2>&1; then
    fail_case "이름 충돌 → HRN-E015 차단" "exit 0 으로 통과함"
  else
    assert_contains "$(cat "${t}/dup.log")" "HRN-E015" "이름 충돌 → HRN-E015"
    assert_contains "$(cat "${t}/dup.log")" "design-doc" "충돌한 이름을 그대로 지목"
  fi

  # (4) project: 접두사로 충돌을 푼다
  sed 's/skills: \[design-doc\]/skills: [project:design-doc]/' "${t}/on.yaml" > "${t}/pfx.yaml"
  if "${t}/.harness/install/validate-config" "${t}/pfx.yaml" >"${t}/pfx.log" 2>&1; then
    pass_case "project: 접두사로 충돌 해소"
  else
    fail_case "project: 접두사로 충돌 해소" "exit=$? — $(tail -3 "${t}/pfx.log")"
  fi

  # (5) project: 접두사인데 프로젝트 경로가 꺼져 있으면 E005
  sed 's/skills: \[design-doc\]/skills: [project:design-doc]/' "$cfg" > "${t}/pfx-off.yaml"
  if "${t}/.harness/install/validate-config" "${t}/pfx-off.yaml" >"${t}/pfxoff.log" 2>&1; then
    fail_case "project: 접두사 + project_path 꺼짐 → 차단" "exit 0 으로 통과함"
  else
    assert_contains "$(cat "${t}/pfxoff.log")" "HRN-E005" \
      "project: 접두사인데 경로 미지정 → HRN-E005"
  fi

  # (6) 결합부 — 플레이북 §1-4 가 같은 계약을 말하는가 (한 곳만 고치면 실행이 못 찾는다)
  local pb_flat
  pb_flat="$(tr '\n' ' ' < "${REPO_ROOT}/core/playbook.md" | tr -s ' ')"
  assert_contains "$pb_flat" "skills.project_path" "플레이북 §1-4: skills.project_path 조항 실존"
  assert_regex "$pb_flat" 'project:[^~]{0,200}(충돌|양쪽)' \
    "플레이북 §1-4: project: 접두사의 용도(충돌 해소) 실존"
  assert_contains "$pb_flat" "HRN-E015" "플레이북 §1-4: HRN-E015 실존"

  # ── T3: 도그푸딩 함정 — 프로젝트 루트와 source_dir 가 같은 자리인 경우 ──
  # 소스 레포에서는 이 둘이 같은 디렉터리다. 그대로 두면 번들 스킬 전부가
  # "양쪽에 존재"로 판정돼 HRN-E015 가 스킬 수만큼 터진다. realpath 가 같으면
  # 한 곳으로 취급해 막는다. **정반대 결과를 내는 두 케이스를 나란히 둔다** —
  # 한쪽만 보면 "동작한다"고 오판할 수 있다.

  # (7) 소스 트리 배치: 컨피그와 skills/ 가 같은 루트 → 충돌 아님
  local self="${WORK}/psk-self"
  rm -rf "$self"; mkdir -p "$self"
  { cat "${REPO_ROOT}/harness.config.yaml"; printf 'skills:\n  project_path: skills\n'; } \
    > "${REPO_ROOT}/psk-self-check.local.yaml"
  if "${REPO_ROOT}/install/validate-config" "${REPO_ROOT}/psk-self-check.local.yaml" \
       >"${WORK}/self.log" 2>&1; then
    pass_case "소스 트리 배치(프로젝트 루트 == source_dir) → 충돌 아님"
  else
    fail_case "소스 트리 배치(프로젝트 루트 == source_dir) → 충돌 아님" \
      "exit=$? — $(grep -c 'HRN-E015' "${WORK}/self.log") 건의 E015 발생"
  fi
  assert_not_contains "$(cat "${WORK}/self.log")" "HRN-E015" \
    "소스 트리 배치에서 HRN-E015 0건"
  rm -f "${REPO_ROOT}/psk-self-check.local.yaml"

  # (8) 심볼릭 링크로 우회해도 같은 곳이면 같은 취급 (realpath 를 쓰는 이유)
  ln -sfn "${REPO_ROOT}/skills" "${WORK}/psk-link"
  { cat "${REPO_ROOT}/harness.config.yaml"
    printf 'skills:\n  project_path: %s\n' "${WORK}/psk-link"; } \
    > "${REPO_ROOT}/psk-link-check.local.yaml"
  # 절대경로를 줘도 project_root 기준 join 이 절대경로를 그대로 쓴다(os.path.join 규약)
  if "${REPO_ROOT}/install/validate-config" "${REPO_ROOT}/psk-link-check.local.yaml" \
       >"${WORK}/link.log" 2>&1; then
    pass_case "심볼릭 링크 우회도 같은 곳으로 취급 (realpath)"
  else
    fail_case "심볼릭 링크 우회도 같은 곳으로 취급" \
      "exit=$? — $(grep -c 'HRN-E015' "${WORK}/link.log") 건의 E015 발생"
  fi
  rm -f "${REPO_ROOT}/psk-link-check.local.yaml"; rm -f "${WORK}/psk-link"

  # (9) 대조 — 설치본 배치(다른 자리)에서는 같은 이름이 여전히 차단된다.
  #     (3)이 이미 그 케이스다. 여기서는 두 결과가 실제로 갈렸음을 한 줄로 못 박는다.
  assert_contains "$(cat "${t}/dup.log")" "HRN-E015" \
    "대조: 설치본 배치(다른 자리)에서는 같은 이름이 차단됨"
}

# ---- preference-options ↔ set-initial 통합 계약 (국면 C T10) ----------------
# 문서 계약 단언이다 — 실제 개인화·자동 채택이 일어나는지는 헤드리스 관찰(T12)이 본다.
# 여기서 막는 것은 통합의 뼈대가 리팩터링 중 사라지는 것이다: 참조 한 줄, question_id
# 매핑, 자동 채택 절차, 자유서술 비대상 선언.
test_preference_integration_contracts() {
  group "preference-options ↔ set-initial 통합 계약"

  local si="${REPO_ROOT}/skills/set-initial/SKILL.md"
  local po="${REPO_ROOT}/skills/preference-options/SKILL.md"
  assert_present "$si" "skills/set-initial/SKILL.md 실존"
  assert_present "$po" "skills/preference-options/SKILL.md 실존"

  local si_flat
  si_flat="$(tr '\n' ' ' < "$si" | tr -s ' ')"

  # 참조 한 줄 — 질문을 내기 전에 스킬을 본다
  assert_regex "$si_flat" 'preference-options[^~]{0,200}(순서|기본번호|추천)' \
    "set-initial: 질문 전 preference-options 참조 실존"

  # question_id 6종 — 안정 식별자가 없으면 통계가 표시 문구에 묶여 학습이 끊긴다
  local qid
  for qid in commit_format commit_unit branch_strategy boilerplate feature_scope docs_location; do
    assert_contains "$si_flat" "set-initial.${qid}" \
      "set-initial: question_id 'set-initial.${qid}' 실존"
  done

  # as_recommended 자동 채택 절차 — 표로 모아 + 되돌리기.
  # 간격 800: 이 스킬의 예시 표는 6문항이라 표 자체가 500자를 넘는다. 플레이북(2문항
  # 예시)에 쓴 300으로는 예시 표가 커졌다는 이유만으로 죽는다 — 단언의 취지는
  # "같은 절 안에 표 절차와 되돌리기 안내가 함께 있다"이지 두 문구의 물리적 거리가
  # 아니므로, 취지를 유지한 채 간격만 넓힌다.
  assert_regex "$si_flat" 'as_recommended[^~]{0,600}표[^~]{0,800}다시' \
    "set-initial: as_recommended 표 절차 + 되돌리기 안내 실존"

  # 자유서술 2문항은 자동 채택 대상이 아니다 (원래 질문 계약의 예외 2문항과 같은 것)
  assert_regex "$si_flat" '자유 ?서술[^~]{0,300}(자동 채택|대상이 아니)' \
    "set-initial: 자유서술 문항은 자동 채택 대상 아님 명시"

  # 회귀 방지 — 질문 계약 4요소 문구가 그대로 살아 있어야 한다
  assert_regex "$si_flat" '네 가지를 전부' "set-initial: 질문 계약 4요소 문구 유지"
  assert_regex "$si_flat" '직접 입력' "set-initial: '직접 입력' 요소 유지"
  assert_regex "$si_flat" '건너뛰기' "set-initial: '건너뛰기' 요소 유지"
  assert_regex "$si_flat" '\[기본:' "set-initial: 기본번호 표기 유지"

  # ── as-recommended 예시 표의 번호 정합 (국면 C T12 REFACTOR) ───────────
  # 자동 채택 예시 표는 **재배열 뒤의 상태**를 보여준다 — 추천을 1번으로 올렸으면
  # 표에 적히는 번호도 1이어야 한다(플레이북 §6 '번호는 표시 순서와 일치').
  # 예시가 `2) ...` 를 보여주면 그 예시 자체가 라벨 규칙 위반의 본보기가 된다.
  # T12 헤드리스 관찰이 실제로 이 어긋남을 지적해 도입한 단언이다.
  local exf exline
  for exf in "${REPO_ROOT}/core/playbook.md" "${REPO_ROOT}/skills/set-initial/SKILL.md"; do
    local bad=0
    while IFS= read -r exline; do
      case "$exline" in
        *"| 1)"*) ;;
        *) bad=$((bad + 1)) ;;
      esac
    done < <(grep -E '^\| Q[0-9][^|]*\| [0-9]\)' "$exf" || true)
    if [ "$bad" -eq 0 ]; then
      pass_case "as-recommended 예시 표: 선택 칸이 전부 1) — $(basename "$(dirname "$exf")")/$(basename "$exf")"
    else
      fail_case "as-recommended 예시 표: 선택 칸이 전부 1)" \
        "$(basename "$exf") 에 1) 이 아닌 선택 칸 ${bad}개 — 재배열 후 번호와 어긋남"
    fi
  done

  # preference-options 스킬이 as_recommended 해석을 **자기 문서로** 소유하는가.
  # 플레이북에만 있으면, 스킬 문서만 읽는 호출부는 일반 원칙에서 매번 새로 유도해야 한다.
  local po_flat
  po_flat="$(tr '\n' ' ' < "$po" | tr -s ' ')"
  assert_regex "$po_flat" 'as_recommended[^~]{0,300}true[^~]{0,200}false' \
    "preference-options: as_recommended 해석 규칙을 자기 문서가 소유"

  # ── 문서화 계약 (국면 C T11) ───────────────────────────────────────────
  # README 설정 표는 사용자가 컨피그를 알아보는 유일한 산문 안내다 — 여기 없는 키는
  # 실질적으로 존재하지 않는 키다. PRD §8 의 (예정) 표기는 구현이 끝나면 떼는 것이
  # 이 저장소의 계약이다(PRD:172, validator-unavailable·branch-strategy 선례).
  local rd="${REPO_ROOT}/README.md" prd="${REPO_ROOT}/PRD.md"
  assert_present "$rd" "README.md 실존"
  assert_present "$prd" "PRD.md 실존"

  local rd_flat prd_flat
  rd_flat="$(tr '\n' ' ' < "$rd" | tr -s ' ')"
  prd_flat="$(tr '\n' ' ' < "$prd" | tr -s ' ')"

  local key
  for key in "agent_mode" "preferences.write_to" "preferences.as_recommended" \
             "skills.project_path" "workdocs.names" "commit.format"; do
    assert_contains "$rd_flat" "$key" "README 설정 표에 '${key}' 실존"
  done

  # HRN-E015 는 PRD §8 에 등재돼야 한다 — 코드가 내는 코드인데 표에 없으면
  # 사용자가 받은 에러의 뜻과 복구 경로를 찾을 곳이 없다.
  assert_contains "$prd_flat" "HRN-E015" "PRD §8 에 HRN-E015 행 실존"
  assert_regex "$prd_flat" 'HRN-E015[^|]{0,200}\|[^|]{0,300}\|[^|]{0,400}(project:|project_path)' \
    "HRN-E015 행에 복구 경로(project: 접두사 / project_path)가 실존"

  # (예정) 표기 제거 — 코드가 실제로 구현됐는데 문서가 '예정'이라 적혀 있으면 거짓이다
  assert_regex "$prd_flat" 'HRN-W017[^|]{0,40}\|' "PRD: HRN-W017 행 실존"
  case "$prd_flat" in
    *'HRN-W017` *(예정'*) fail_case "PRD: HRN-W017 의 (예정) 표기 제거됨" "아직 (예정)이 붙어 있음" ;;
    *) pass_case "PRD: HRN-W017 의 (예정) 표기 제거됨" ;;
  esac
  case "$prd_flat" in
    *'HRN-W018` *(예정'*) fail_case "PRD: HRN-W018 의 (예정) 표기 제거됨" "아직 (예정)이 붙어 있음" ;;
    *) pass_case "PRD: HRN-W018 의 (예정) 표기 제거됨" ;;
  esac
}

test_playbook_cross_refs() {
  group "플레이북 — 절 참조 정합 (§x-y 내부 참조, 다른 문서 참조는 제외)"

  local pb="${REPO_ROOT}/core/playbook.md"
  local out rc
  out="$(check_playbook_cross_refs "$pb" 2>&1)"; rc=$?

  if [ "$rc" -eq 0 ]; then
    pass_case "현재 플레이북의 모든 내부 § 참조가 실재하는 절을 가리킴 (${out})"
  else
    fail_case "현재 플레이북의 모든 내부 § 참조가 실재하는 절을 가리킴" "$out"
  fi

  # 없는 절을 가리키는 참조를 주입하면 FAIL해야 한다 — 파서가 장식이 아님을 증명.
  local mdir mutated mout mrc
  mdir="$(mktemp -d "${WORK}/pb-mutate.XXXXXX")"
  mutated="${mdir}/playbook-mutated.md"
  cp "$pb" "$mutated"
  printf '\n없는 절 참조 뮤테이션 테스트: §9-9 를 보라.\n' >> "$mutated"
  mout="$(check_playbook_cross_refs "$mutated" 2>&1)"; mrc=$?
  if [ "$mrc" -ne 0 ] && case "$mout" in *"§9-9"*) true ;; *) false ;; esac; then
    pass_case "없는 절(§9-9) 참조 주입 → FAIL로 검출"
  else
    fail_case "없는 절(§9-9) 참조 주입 → FAIL로 검출" "rc=${mrc} out=${mout}"
  fi

  # 외부 문서 참조("설계 §3-4", "PRD §10")는 이 문서 헤더 구조로 검사하면 안 된다 —
  # 실제로 존재하는 두 참조가 여전히 통과 대상에서 제외되는지 확인한다.
  case "$out" in
    *"3-4"*) fail_case "설계 §3-4는 외부 참조로 제외됨" "출력에 3-4가 섞임: ${out}" ;;
    *) pass_case "설계 §3-4는 외부 참조로 제외됨 (헤더 구조 검사 대상 아님)" ;;
  esac
}

# ---- 번호 선택 입력 (ask-choice) -------------------------------------------

# pty를 붙여 대화형 경로를 실행한다. 입력은 $1, 나머지는 bash 코드.
# 출력의 \r 을 제거해 반환한다.
run_with_tty() {
  local input="$1" code="$2"
  # %s (원안)는 리터럴 백슬래시-n을 그대로 두어 read -rp 가 개행을 못 받고
  # 무한 대기한다(실측: 첫 케이스에서 행업 확인, 프로세스가 read 에서 멈춰 있었음).
  # %b로 백슬래시 이스케이프를 실제 개행으로 해석해야 pty에 Enter가 전달된다.
  printf '%b' "$input" | script -qec "bash -c '$code'" /dev/null 2>&1 | tr -d '\r'
}

test_ask_choice() {
  group "번호 선택 입력 — ask_choice"

  local lib="${REPO_ROOT}/install/lib.sh"

  if ! grep -q '^ask_choice()' "$lib"; then
    fail_case "ask_choice 실존" "install/lib.sh 에 ask_choice 없음 (RED 기대 상태)"
    return
  fi

  local base="source ${lib}; ask_choice \"고르세요\" 3 \"가\" \"나\" \"다\""

  # (1) 유효 번호 선택
  local out
  out="$(run_with_tty '2\n' "$base")"
  assert_contains "$out" "2" "유효 번호 입력 → 그 번호 반환"

  # (2) 빈 입력 → 기본번호
  out="$(run_with_tty '\n' "echo \$($base)")"
  assert_contains "$out" "3" "빈 입력(Enter) → 기본번호 3 반환"

  # (3) 범위 밖 → 재질문 후 유효값 수용
  out="$(run_with_tty '9\n1\n' "echo RESULT=\$($base)")"
  assert_contains "$out" "RESULT=1" "범위 밖 입력 후 재질문 → 유효값 수용"
  assert_contains "$out" "1~3" "범위 밖 입력 시 허용 범위를 알려준다"

  # (4) 3회 연속 잘못된 입력 → 기본값 채택 (무한 루프 방지)
  out="$(run_with_tty 'x\ny\nz\n' "echo RESULT=\$($base)")"
  assert_contains "$out" "RESULT=3" "3회 실패 → 기본값 채택"

  # (5) 비TTY → 기본값 + 로그 (ask·ask_yn 과 동일 계약)
  out="$(bash -c "source ${lib}; ask_choice '고르세요' 2 '가' '나' '다'" </dev/null 2>&1)"
  assert_contains "$out" "2" "비대화형 → 기본번호 반환"
  assert_contains "$out" "비대화형" "비대화형 사실을 로그로 알린다"

  # (6) ★ 출력 오염 — stdout에는 오직 번호만 (목록이 섞이면 반환값이 깨진다)
  local captured
  captured="$(bash -c "source ${lib}; ask_choice '고르세요' 1 '가' '나'" </dev/null 2>/dev/null)"
  assert_eq "$captured" "1" "stdout 에는 번호만 — 목록·안내가 섞이지 않음"

  # (7) 선택지 0개 → 기본값 (호출부 실수 방어)
  captured="$(bash -c "source ${lib}; ask_choice '고르세요' 1" </dev/null 2>/dev/null)"
  assert_eq "$captured" "1" "선택지 0개 → 기본값 반환 (크래시 없음)"

  # (8) 범위 밖 기본번호 → 1로 보정 + 경고 (호출부 실수 방어)
  out="$(bash -c "source ${lib}; ask_choice '고르세요' 99 '가' '나' '다'" </dev/null 2>&1)"
  assert_contains "$out" "범위 밖" "범위 밖 기본번호를 알린다"
  captured="$(bash -c "source ${lib}; ask_choice '고르세요' 99 '가' '나' '다'" </dev/null 2>/dev/null)"
  assert_eq "$captured" "1" "범위 밖 기본번호 → 1로 보정된 값 반환"

  # (9) 비숫자 기본번호도 보정
  captured="$(bash -c "source ${lib}; ask_choice '고르세요' abc '가' '나'" </dev/null 2>/dev/null)"
  assert_eq "$captured" "1" "비숫자 기본번호 → 1로 보정"

  # (10) ★ 입력 고갈 시 무한 대기하지 않는다 (pty, 입력 1줄뿐)
  local rc
  timeout 8 bash -c "printf '\n' | script -qec \"bash -c 'source ${lib}; ask_choice 고르세요 99 가 나 다'\" /dev/null" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 124 ]; then
    fail_case "입력 고갈 시 무한 대기 안 함" "timeout 8초 초과 — 무한 대기 중"
  else
    pass_case "입력 고갈 시 무한 대기 안 함 (rc=${rc})"
  fi
}

test_detect_obsidian_vaults() {
  group "Obsidian vault 탐지 — detect_obsidian_vaults"

  local lib="${REPO_ROOT}/install/lib.sh"

  if ! grep -q '^detect_obsidian_vaults()' "$lib"; then
    fail_case "detect_obsidian_vaults 실존" "install/lib.sh 에 함수 없음 (RED 기대 상태)"
    return
  fi

  local out rc
  out="$(bash -c "source ${lib}; detect_obsidian_vaults" 2>/dev/null)"; rc=$?
  assert_eq "$rc" "0" "탐지 함수는 항상 성공 종료 (실패는 빈 출력으로 표현)"

  if [ -n "$out" ]; then
    # 이 환경(WSL)에서는 탐지가 되어야 한다
    assert_contains "$out" "	" "출력이 <이름>TAB<경로> 형식"
    local first_path
    first_path="$(printf '%s' "$out" | head -n1 | cut -f2)"
    assert_present "$first_path" "탐지된 경로가 실제로 존재한다"
    case "$first_path" in
      /*) pass_case "탐지 경로가 절대 유닉스 경로 (wslpath 변환됨)" ;;
      *)  fail_case "탐지 경로 형식" "유닉스 절대경로가 아님: ${first_path}" ;;
    esac
  else
    pass_case "탐지 결과 없음 — 비WSL 환경이거나 등록 vault 0개 (열화 정상)"
  fi
}


# ============================================================================
# 12. 공개 배포 계약 — 클론본이 남의 프로젝트에 깨끗하게 깔리는가
# ============================================================================
test_public_distribution() {
  group "공개 배포 계약"

  local tmpl="${REPO_ROOT}/config/harness.config.template.yaml"

  # (1) 배포 템플릿은 vault_root가 비어 있어야 한다 — 개발자 개인 경로 유출 차단
  assert_present "$tmpl" "배포 템플릿 실존 (config/harness.config.template.yaml)"
  assert_contains "$(grep -E '^\s*vault_root:' "$tmpl")" "null" \
    "배포 템플릿의 vault_root는 null"

  # (2) 소스의 실사용 컨피그는 배포물에 들어가지 않는다
  local t1
  t1="$(mktemp -d "${WORK}/pub-t1.XXXXXX")"
  ( cd "$REPO_ROOT" && ./install/setup "$t1" </dev/null >/dev/null 2>&1 )
  assert_absent "${t1}/.harness/harness.config.yaml" \
    "배포물에 소스의 실사용 컨피그 부재"
  assert_present "${t1}/.harness/config/harness.config.template.yaml" \
    "배포물에 템플릿 컨피그 존재"
  assert_present "${t1}/.harness/templates/설계.md" \
    "배포물에 문서 서식 폴백(templates/) 존재"

  # (2b) 파이썬 바이트코드 캐시는 배포물에 들어가지 않는다.
  #      소스 레포에서 validate-config 를 한 번만 돌려도 install/__pycache__ 가 생기고,
  #      .harnessignore 에 항목이 없으면 그대로 대상에 복사된다 — CLAUDE.md §6 의
  #      "개발용 파일이 설치 대상에서 발견되면 패키징 누출 버그" 에 해당한다.
  #      (2026-09-03 실제로 누출을 확인하고 추가한 케이스)
  python3 -m py_compile "${REPO_ROOT}/install/validate_config.py" 2>/dev/null || true
  local t1b
  t1b="$(mktemp -d "${WORK}/pub-t1b.XXXXXX")"
  ( cd "$REPO_ROOT" && ./install/setup "$t1b" </dev/null >/dev/null 2>&1 )
  assert_absent "${t1b}/.harness/install/__pycache__" "배포물에 __pycache__ 부재"
  if find "${t1b}/.harness" -name '*.pyc' -print -quit 2>/dev/null | grep -q .; then
    fail_case "배포물에 .pyc 부재" "$(find "${t1b}/.harness" -name '*.pyc' | head -1)"
  else
    pass_case "배포물에 .pyc 부재"
  fi

  # (3) 새 대상 컨피그에 소스의 개인 vault 경로가 스며들지 않는다
  local src_vault
  src_vault="$(grep -E '^\s*vault_root:' "${REPO_ROOT}/harness.config.yaml" | sed 's/.*vault_root:[[:space:]]*//; s/[[:space:]]*#.*//; s/"//g')"
  if [ -n "$src_vault" ] && [ "$src_vault" != "null" ]; then
    assert_not_contains "$(cat "${t1}/harness.config.yaml")" "$src_vault" \
      "새 대상 컨피그에 소스의 vault_root 미유입"
  else
    pass_case "새 대상 컨피그에 소스의 vault_root 미유입 (소스 vault_root가 비어 검사 생략)"
  fi

  # (4) 값이 박힌 템플릿이어도 사용자가 고른 값이 이긴다 (치환 정규식 회귀)
  local src2 t2
  src2="$(mktemp -d "${WORK}/pub-src2.XXXXXX")"
  build_fake_source "$src2"
  sed -i 's|^  vault_root: null|  vault_root: "/OLD/PRIVATE/vault"   # 오염된 템플릿|' \
    "${src2}/config/harness.config.template.yaml"
  t2="$(mktemp -d "${WORK}/pub-t2.XXXXXX")"
  # vault 자동탐지를 끈 PATH로 돌린다(wslpath 부재 → 탐지 빈 출력 → 자유 입력 경로).
  # 그래야 입력 순서가 환경과 무관하게 "설치확인 Enter → vault 경로" 로 고정된다.
  local mp2
  mp2="$(build_min_path pub2)"
  run_with_tty '\n/NEW/vault\n' "export PATH=${mp2}; cd ${src2}; ./install/setup ${t2}" >/dev/null 2>&1
  local cfg2
  cfg2="$(cat "${t2}/harness.config.yaml" 2>/dev/null || echo "")"
  assert_contains "$cfg2" "/NEW/vault" "오염된 템플릿에도 사용자 입력 vault_root 반영"
  assert_not_contains "$cfg2" "/OLD/PRIVATE/vault" "오염된 템플릿 값이 대상에 남지 않음"

  # (5) 자기 자신(소스 레포)에 설치하려 하면 차단된다
  local out rc
  out="$(cd "$REPO_ROOT" && ./install/setup "$REPO_ROOT" </dev/null 2>&1)"; rc=$?
  assert_eq "$rc" "1" "소스 자신을 대상으로 지정 → 차단(rc=1)"
  assert_contains "$out" "HRN-E007" "차단 사유를 HRN-E007로 안내"
  assert_absent "${REPO_ROOT}/.harness/core" "차단 시 소스 트리에 배포물 미생성"

  # (6) 인자 없이 비대화형 실행해도 소스에 설치되지 않는다
  local out6 rc6
  out6="$(cd "$REPO_ROOT" && ./install/setup </dev/null 2>&1)"; rc6=$?
  assert_eq "$rc6" "1" "인자 없는 비대화형 실행 → 차단(rc=1)"
  assert_contains "$out6" "HRN-E007" "인자 없는 실행도 같은 사유로 차단됨"

  # (7) --help 는 설치를 수행하지 않고 사용법만 낸다
  local out7 rc7
  out7="$(cd "$REPO_ROOT" && ./install/setup --help </dev/null 2>&1)"; rc7=$?
  assert_eq "$rc7" "0" "--help 정상 종료"
  assert_contains "$out7" "install/setup <대상 프로젝트 경로>" "--help 에 사용법 표기"

  # (8) 공개 저장소 필수 파일
  assert_present "${REPO_ROOT}/README.md" "README.md 존재"
  assert_present "${REPO_ROOT}/LICENSE" "LICENSE 존재"
  assert_contains "$(cat "${REPO_ROOT}/README.md")" "install/setup /absolute/path/to/project" \
    "README에 에이전트용 설치 명령 존재"
}


# ============================================================================
# 13. 훅 — 기반 문서 상태 보고 (set-initial 방아쇠)
# ============================================================================
test_hook_doc_state() {
  group "훅 — 기반 문서 상태"

  local hook="${REPO_ROOT}/adapters/claude/hooks/session-start.sh"

  # (1) 셋 다 없음
  local d1 out1
  d1="$(mktemp -d "${WORK}/hook-none.XXXXXX")"
  out1="$(CLAUDE_PROJECT_DIR="$d1" bash "$hook" 2>&1)"
  assert_contains "$out1" "PRD.md: 없음 · CLAUDE.md: 없음 · AGENTS.md: 없음" \
    "문서 셋 다 없으면 셋 다 '없음'"

  # (2) 일부만 있음
  local d2 out2
  d2="$(mktemp -d "${WORK}/hook-some.XXXXXX")"
  printf '# 규칙\n- 뭔가 있다\n' > "${d2}/CLAUDE.md"
  out2="$(CLAUDE_PROJECT_DIR="$d2" bash "$hook" 2>&1)"
  assert_contains "$out2" "PRD.md: 없음 · CLAUDE.md: 있음 · AGENTS.md: 없음" \
    "내용 있는 파일만 '있음'"

  # (3) 공백뿐인 파일은 '없음' — [ -s ] 로는 못 거르는 경계
  local d3 out3
  d3="$(mktemp -d "${WORK}/hook-blank.XXXXXX")"
  printf '\n   \n\t\n' > "${d3}/CLAUDE.md"
  : > "${d3}/PRD.md"
  out3="$(CLAUDE_PROJECT_DIR="$d3" bash "$hook" 2>&1)"
  assert_contains "$out3" "PRD.md: 없음 · CLAUDE.md: 없음 · AGENTS.md: 없음" \
    "공백뿐인 파일도 '없음'으로 본다"

  # (4) 훅은 어떤 경우에도 성공 종료 — 세션을 막지 않는다
  local rc4
  CLAUDE_PROJECT_DIR="$d1" bash "$hook" >/dev/null 2>&1; rc4=$?
  assert_eq "$rc4" "0" "훅은 문서가 없어도 rc=0"

  # (5) 훅은 판단하지 않는다 — 제안 문구는 플레이북 소관
  assert_not_contains "$out1" "set-initial 을 실행" \
    "훅이 스킬 실행을 직접 지시하지 않음 (사실만 보고)"

  # (6) 스킬이 배포물에 실린다
  assert_present "${REPO_ROOT}/skills/set-initial/SKILL.md" "set-initial 스킬 실존"

  # (7) PRD.md 자리가 디렉토리인 경우 → 훅 rc=0, "없음" (-f 검사가 자연스럽게 걸러냄)
  local d7 out7 rc7
  d7="$(mktemp -d "${WORK}/hook-dir.XXXXXX")"
  mkdir -p "${d7}/PRD.md"
  out7="$(CLAUDE_PROJECT_DIR="$d7" bash "$hook" 2>&1)"; rc7=$?
  assert_eq "$rc7" "0" "PRD.md 자리가 디렉토리여도 훅 rc=0"
  assert_contains "$out7" "PRD.md: 없음 · CLAUDE.md: 없음 · AGENTS.md: 없음" \
    "PRD.md 자리가 디렉토리면 '없음' (파일 아님)"

  # (8) 읽기 권한 없는 파일(내용 있음) → 훅 rc=0, "없음"
  # root로 돌리면 권한 검사가 무의미해져 통과하지 못할 수 있으니 root 실행 시 건너뛰고
  # 그 사실을 pass 사유로 남긴다.
  if [ "$(id -u)" = "0" ]; then
    pass_case "읽기 권한 없는 파일 → '없음' (root 실행 — 권한 검사 무의미, 건너뜀)"
  else
    local d8 out8 rc8
    d8="$(mktemp -d "${WORK}/hook-noperm.XXXXXX")"
    printf '내용 있음\n' > "${d8}/PRD.md"
    chmod 000 "${d8}/PRD.md"
    out8="$(CLAUDE_PROJECT_DIR="$d8" bash "$hook" 2>&1)"; rc8=$?
    chmod 644 "${d8}/PRD.md"
    assert_eq "$rc8" "0" "읽기 권한 없는 PRD.md여도 훅 rc=0"
    assert_contains "$out8" "PRD.md: 없음 · CLAUDE.md: 없음 · AGENTS.md: 없음" \
      "읽기 권한 없는 파일은 '없음' (grep 실패 → 없음 취급)"
  fi
}

# ============================================================================
# 실행
# ============================================================================
test_rsync_contract
test_setup_contract
test_update_contract
test_validator_unavailable
test_meta_corruption
test_rsync_missing
test_harness_cli_missing
test_superpowers_prereq
test_join_lines
test_validate_config
test_playbook_rule_contracts
test_question_label_contracts
test_preference_integration_contracts
test_project_skills_resolution
test_workdocs_naming_ownership
test_setup_gitignore
test_playbook_cross_refs
test_ask_choice
test_detect_obsidian_vaults
test_public_distribution
# ---- enforcement-gate (2026-11-06) -----------------------------------------
# 계약: ⑤ 승인 게이트가 **실제로 막는가**, approve 가 승인 경로를 남기는가,
# 주입 모드가 라우터로 줄어드는가, 스킬 노출이 남의 것을 가리지 않는가.

GATE_HOOK="${REPO_ROOT}/adapters/claude/hooks/pre-tool-use.sh"

# gate_fixture <dir> [enforce값]  — 컨피그 + 작업 디렉터리만 갖춘 최소 대상
gate_fixture() {
  local dir="$1" enforce="${2:-block}"
  mkdir -p "${dir}/.harness/work/demo/2026-11-06"
  cat > "${dir}/harness.config.yaml" <<EOF
active_harness: claude
workdocs:
  path: .harness/work
  names:
    design: 설계.md
    plan:   구현계획.md
    report: 구현후보고.md
gate:
  enforce: ${enforce}
EOF
}

# gate_call <대상> <JSON>  → "rc<TAB>stderr" 를 stdout
gate_call() {
  local target="$1" json="$2" rc=0 out
  out="$(printf '%s' "$json" | CLAUDE_PROJECT_DIR="$target" bash "$GATE_HOOK" 2>&1 1>/dev/null)" || rc=$?
  printf '%s\t%s' "$rc" "$out"
}

test_gate_hook() {
  group "게이트 — PreToolUse 승인 마커 계약"

  local t r
  t="$(mktemp -d "${WORK}/gate1.XXXXXX")"
  gate_fixture "$t"

  # (1) 설계 문서가 없으면 흐름이 시작된 적 없다 → 무장하지 않는다
  r="$(gate_call "$t" '{"tool_name":"Edit","tool_input":{"file_path":"src/a.js"}}')"
  assert_eq "${r%%$'\t'*}" "0" "설계 문서 없으면 통과 (미무장)"

  # (2) 설계 문서 + 마커 없음 → 무장. 작업 문서 **밖**의 쓰기는 차단된다.
  printf '# 설계\n' > "${t}/.harness/work/demo/2026-11-06/설계.md"
  r="$(gate_call "$t" '{"tool_name":"Edit","tool_input":{"file_path":"src/a.js"}}')"
  assert_eq "${r%%$'\t'*}" "2" "승인 전 소스 Edit 차단 (rc=2)"
  assert_contains "$r" "HRN-E016" "차단 사유를 HRN-E016 으로 안내"
  assert_contains "$r" "approve" "복구 경로에 approve 안내"
  assert_contains "$r" "demo" "어느 작업이 승인 대기인지 명시"

  r="$(gate_call "$t" '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x/other.py"}}')"
  assert_eq "${r%%$'\t'*}" "2" "절대경로 Write 도 차단"
  r="$(gate_call "$t" '{"tool_name":"MultiEdit","tool_input":{"edits":[{"file_path":"src/b.js"}]}}')"
  assert_eq "${r%%$'\t'*}" "2" "MultiEdit 의 edits[].file_path 도 본다"

  # (3) 작업 문서 자체는 항상 쓸 수 있다 — ⑤⑥이 문서를 만드는 구간이다
  r="$(gate_call "$t" '{"tool_name":"Write","tool_input":{"file_path":".harness/work/demo/2026-11-06/구현계획.md"}}')"
  assert_eq "${r%%$'\t'*}" "0" "작업 문서 쓰기는 통과 (⑤⑥이 문서를 만든다)"

  # (4) 읽기·탐색·커밋은 막지 않는다
  r="$(gate_call "$t" '{"tool_name":"Read","tool_input":{"file_path":"src/a.js"}}')"
  assert_eq "${r%%$'\t'*}" "0" "Read 통과"
  r="$(gate_call "$t" '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}')"
  assert_eq "${r%%$'\t'*}" "0" "Bash ls 통과"
  r="$(gate_call "$t" '{"tool_name":"Bash","tool_input":{"command":"git commit -m 설계"}}')"
  assert_eq "${r%%$'\t'*}" "0" "git commit 통과 (승인 전 설계 문서 커밋은 정상 흐름)"

  # (5) 셸 경유 제자리 편집은 막는다
  r="$(gate_call "$t" '{"tool_name":"Bash","tool_input":{"command":"sed -i s/a/b/ src/a.js"}}')"
  assert_eq "${r%%$'\t'*}" "2" "sed -i 차단"

  # (6) 마커가 생기면 풀린다
  touch "${t}/.harness/work/demo/2026-11-06/.approved"
  r="$(gate_call "$t" '{"tool_name":"Edit","tool_input":{"file_path":"src/a.js"}}')"
  assert_eq "${r%%$'\t'*}" "0" "승인 마커가 있으면 통과"
  rm -f "${t}/.harness/work/demo/2026-11-06/.approved"

  # (7) fail-open — 판정 불가는 **통과**시키고 W021 을 낸다
  r="$(gate_call "$t" 'not a json')"
  assert_eq "${r%%$'\t'*}" "0" "깨진 입력은 fail-open (게이트 고장이 작업을 세우지 않는다)"
  assert_contains "$r" "HRN-W021" "fail-open 사실을 HRN-W021 로 알린다"

  # (8) 모드 — warn / off / 오타
  local tw to tx
  tw="$(mktemp -d "${WORK}/gatew.XXXXXX")"; gate_fixture "$tw" warn
  printf '# 설계\n' > "${tw}/.harness/work/demo/2026-11-06/설계.md"
  r="$(gate_call "$tw" '{"tool_name":"Edit","tool_input":{"file_path":"src/a.js"}}')"
  assert_eq "${r%%$'\t'*}" "0" "warn 모드는 통과시킨다"
  assert_contains "$r" "warn" "warn 모드도 사실은 보고한다 (silent 금지)"

  to="$(mktemp -d "${WORK}/gateo.XXXXXX")"; gate_fixture "$to" off
  printf '# 설계\n' > "${to}/.harness/work/demo/2026-11-06/설계.md"
  r="$(gate_call "$to" '{"tool_name":"Edit","tool_input":{"file_path":"src/a.js"}}')"
  assert_eq "${r%%$'\t'*}" "0" "off 모드는 집행하지 않는다"
  assert_not_contains "$r" "HRN-E016" "off 모드는 경고도 내지 않는다"

  tx="$(mktemp -d "${WORK}/gatex.XXXXXX")"; gate_fixture "$tx" blokc
  printf '# 설계\n' > "${tx}/.harness/work/demo/2026-11-06/설계.md"
  r="$(gate_call "$tx" '{"tool_name":"Edit","tool_input":{"file_path":"src/a.js"}}')"
  assert_eq "${r%%$'\t'*}" "2" "오타 모드는 block 으로 떨어진다 (§1-5 안전측)"

  # (9) 컨피그가 아예 없는 프로젝트 — 무장 근거가 없으니 통과
  local tn
  tn="$(mktemp -d "${WORK}/gaten.XXXXXX")"
  r="$(gate_call "$tn" '{"tool_name":"Edit","tool_input":{"file_path":"src/a.js"}}')"
  assert_eq "${r%%$'\t'*}" "0" "컨피그 없는 프로젝트는 통과 (게이트가 남의 집을 막지 않는다)"

  # (10) 드리프트 고정 — lib.sh yaml_get 과 훅의 awk 가 같은 값을 읽어야 한다
  #      (훅은 설치 스크립트에 의존하지 않으려 같은 파서를 복제해 들고 있다)
  local via_lib via_hook
  via_lib="$(yaml_get "${t}/harness.config.yaml" "workdocs.names.design")"
  via_hook="$(awk -v path="workdocs.names.design" '
    { raw = $0; sub(/#.*$/, "", raw)
      if (raw ~ /^[[:space:]]*$/) next
      n = match(raw, /[^ ]/); if (n == 0) next
      ind = n - 1; rest = substr(raw, n)
      if (substr(rest, 1, 1) == "-") next
      ci = index(rest, ":"); if (ci == 0) next
      key = substr(rest, 1, ci - 1); val = substr(rest, ci + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", val)
      lvl = int(ind / 2); stack[lvl] = key
      for (i = lvl + 1; i < 10; i++) stack[i] = ""
      cur = stack[0]
      for (i = 1; i <= lvl; i++) cur = cur "." stack[i]
      if (cur == path && val != "") { print val; exit }
    }' "${t}/harness.config.yaml")"
  assert_eq "$via_hook" "$via_lib" "복제된 YAML 파서가 lib.sh 와 같은 값을 읽는다 (드리프트 고정)"
}

test_approve_cli() {
  group "게이트 — install/approve 계약"

  local t out rc
  t="$(mktemp -d "${WORK}/appr.XXXXXX")"
  gate_fixture "$t"
  printf -- '---\ntype: 설계\n---\n> [!summary] 요약(≤10자)\n> 테스트승인\n' \
    > "${t}/.harness/work/demo/2026-11-06/설계.md"
  # 설치본 배치를 모사한다: <대상>/.harness/install/{approve,lib.sh}
  mkdir -p "${t}/.harness/install"
  cp "${INSTALL_DIR}/approve" "${INSTALL_DIR}/lib.sh" "${t}/.harness/install/"
  chmod +x "${t}/.harness/install/approve"

  # (1) --list — 승인 대기를 숨기지 않는다
  out="$("${t}/.harness/install/approve" --list 2>&1 || true)"
  assert_contains "$out" "demo" "--list 가 작업을 보여준다"
  assert_contains "$out" "대기" "승인 대기 상태를 명시"

  # (2) 비대화형 승인은 --by-user 없이는 거부된다 (게이트의 존재 이유)
  rc=0; out="$("${t}/.harness/install/approve" demo </dev/null 2>&1)" || rc=$?
  assert_eq "$rc" "1" "비대화형에서 --by-user 없이는 승인되지 않는다"
  assert_contains "$out" "HRN-E016" "거부 사유를 코드로 안내"
  assert_absent "${t}/.harness/work/demo/2026-11-06/.approved" "거부되면 마커를 만들지 않는다"

  # (3) --by-user → 마커 생성 + **승인 경로가 기록된다**
  rc=0; out="$("${t}/.harness/install/approve" demo --by-user </dev/null 2>&1)" || rc=$?
  assert_eq "$rc" "0" "--by-user 로 승인된다"
  assert_present "${t}/.harness/work/demo/2026-11-06/.approved" "마커 생성됨"
  local marker
  marker="$(cat "${t}/.harness/work/demo/2026-11-06/.approved")"
  assert_contains "$marker" "승인경로=flag" "승인 경로가 마커에 기록된다 (조용히 승인할 수 없다)"
  assert_contains "$marker" "승인시각=" "승인 시각이 기록된다"
  assert_not_contains "$marker" "${t}" "설계문서 경로는 절대경로가 아니다 (머신 경로를 이력에 박지 않는다)"
  assert_contains "$marker" ".harness/work/demo" "설계문서 경로가 프로젝트 기준 상대경로"

  # (4) 멱등 — 이미 승인된 작업은 다시 만들지 않고 상태를 보여준다
  rc=0; out="$("${t}/.harness/install/approve" demo --by-user </dev/null 2>&1)" || rc=$?
  assert_eq "$rc" "0" "이미 승인된 작업에 다시 실행해도 성공 종료"
  assert_contains "$out" "이미 승인" "이미 승인됨을 알린다"

  # (5) 승인 후 게이트가 풀렸는가 — 실물 확인
  local r
  r="$(gate_call "$t" '{"tool_name":"Edit","tool_input":{"file_path":"src/a.js"}}')"
  assert_eq "${r%%$'\t'*}" "0" "approve 후 게이트가 실제로 풀린다"

  # (6) 없는 작업 → E005
  rc=0; out="$("${t}/.harness/install/approve" nosuch --by-user </dev/null 2>&1)" || rc=$?
  assert_eq "$rc" "1" "없는 작업은 승인되지 않는다"
  assert_contains "$out" "HRN-E005" "없는 작업은 E005 로 안내"

  # (7) 백필 — 기존 마커는 덮지 않는다 (진행 중 작업의 상태를 지우면 안 된다)
  mkdir -p "${t}/.harness/work/old/2026-01-01"
  printf '# 설계\n' > "${t}/.harness/work/old/2026-01-01/설계.md"
  local n
  n="$(backfill_approvals "$t")"
  assert_eq "$n" "1" "마커 없는 기존 작업만 백필한다"
  assert_contains "$(cat "${t}/.harness/work/demo/2026-11-06/.approved")" "flag" \
    "백필이 기존 승인 경로를 덮어쓰지 않는다"
  assert_contains "$(cat "${t}/.harness/work/old/2026-01-01/.approved")" "backfill" \
    "백필한 마커는 backfill 로 표시된다 (사용자 승인과 구분)"
}

test_injection_modes() {
  group "주입 — injection.mode (라우터 / 전문)"

  local hook t out_router out_full
  hook="${REPO_ROOT}/adapters/claude/hooks/session-start.sh"
  t="$(mktemp -d "${WORK}/inj.XXXXXX")"
  cat > "${t}/harness.config.yaml" <<'EOF'
active_harness: claude
injection:
  mode: router
EOF
  out_router="$(CLAUDE_PROJECT_DIR="$t" bash "$hook" 2>/dev/null)"
  assert_contains "$out_router" "하네스 라우터" "router 모드는 라우터를 주입한다"
  assert_contains "$out_router" "core/playbook.md" "플레이북의 **경로**를 알려준다"
  assert_not_contains "$out_router" "구간 실행표 (workflow 9단계)" \
    "router 모드는 플레이북 전문을 주입하지 않는다"
  assert_not_contains "$out_router" "active_harness: claude" \
    "router 모드는 컨피그 원문을 주입하지 않는다 (흐름 시작 시 다시 읽는다)"
  assert_contains "$out_router" "프로젝트 기반 문서 상태" "기반 문서 상태는 두 모드 공통"
  assert_contains "$out_router" "HRN-E016" "게이트가 실제로 막는다는 사실을 라우터가 알린다"

  sed -i 's/^  mode: router/  mode: full/' "${t}/harness.config.yaml"
  out_full="$(CLAUDE_PROJECT_DIR="$t" bash "$hook" 2>/dev/null)"
  assert_contains "$out_full" "구간 실행표 (workflow 9단계)" "full 모드는 플레이북 전문을 주입한다"
  assert_contains "$out_full" "active_harness: claude" "full 모드는 컨피그 원문도 주입한다"

  # 다이어트가 실제로 줄였는가 — 숫자로 고정한다(회귀가 조용히 되돌려지는 것 방지)
  local n_router n_full
  n_router="$(printf '%s' "$out_router" | wc -m)"
  n_full="$(printf '%s' "$out_full" | wc -m)"
  if [ "$n_router" -lt "$((n_full / 3))" ]; then
    pass_case "router 주입량이 full 의 1/3 미만 (실측 ${n_router} vs ${n_full}자)"
  else
    fail_case "router 주입량이 full 의 1/3 미만" "router=${n_router} full=${n_full}"
  fi

  # 오타 → router (§1-5)
  sed -i 's/^  mode: full/  mode: roooter/' "${t}/harness.config.yaml"
  out_router="$(CLAUDE_PROJECT_DIR="$t" bash "$hook" 2>/dev/null)"
  assert_contains "$out_router" "하네스 라우터" "오타 모드는 router 로 떨어진다"

  # 컨피그가 없으면 router + W012 안내
  local t2 out2
  t2="$(mktemp -d "${WORK}/inj2.XXXXXX")"
  out2="$(CLAUDE_PROJECT_DIR="$t2" bash "$hook" 2>/dev/null)"
  assert_contains "$out2" "HRN-W012" "컨피그 없으면 W012 로 안내 (비차단)"
  assert_contains "$out2" "하네스 라우터" "컨피그 없어도 라우터는 주입된다"
}

test_skill_exposure() {
  group "스킬 노출 — .claude/skills/ (PRD §5 개정)"

  local t out
  t="$(mktemp -d "${WORK}/expo.XXXXXX")"
  git -C "$t" init -q
  # 같은 이름의 **프로젝트 자신의 스킬**을 미리 심어 충돌을 만든다
  mkdir -p "${t}/.claude/skills/design-doc"
  printf -- '---\nname: design-doc\n---\n프로젝트 것\n' > "${t}/.claude/skills/design-doc/SKILL.md"

  ( cd "$REPO_ROOT" && ./install/setup "$t" </dev/null >"${WORK}/expo.log" 2>&1 )
  out="$(cat "${WORK}/expo.log")"

  assert_present "${t}/.claude/skills/report-doc/SKILL.md" "하네스 스킬이 노출된다 (심링크 해석됨)"
  assert_eq "$(readlink "${t}/.claude/skills/report-doc")" "../../.harness/skills/report-doc" \
    "노출은 상대 심링크 (프로젝트를 옮겨도 산다)"
  assert_contains "$out" "HRN-W022" "이름이 겹치면 W022 로 알린다"
  assert_eq "$(cat "${t}/.claude/skills/design-doc/SKILL.md" | tail -1)" "프로젝트 것" \
    "충돌 시 **남의 스킬을 가리지 않는다** (조용히 덮지 않음)"
  assert_contains "$out" "스킬 노출" "설치 요약에 노출 결과 명시 (결과 비은닉)"

  # .gitignore — 우리가 만든 링크만 무시한다. 남의 스킬을 가리면 안 된다.
  assert_contains "$(cat "${t}/.gitignore")" "/.claude/skills/report-doc" \
    ".gitignore 에 우리 링크를 넣는다"
  assert_not_contains "$(cat "${t}/.gitignore")" "/.claude/skills/design-doc" \
    "충돌로 건너뛴 이름은 .gitignore 에 넣지 않는다 (남의 스킬을 가리지 않는다)"

  # 재설치 멱등
  ( cd "$REPO_ROOT" && ./install/setup "$t" </dev/null >"${WORK}/expo2.log" 2>&1 )
  assert_contains "$(cat "${WORK}/expo2.log")" "유지" "재설치는 기존 링크를 유지한다 (멱등)"

  # 죽은 링크 청소
  ln -s "../../.harness/skills/gone-skill" "${t}/.claude/skills/gone-skill"
  ( cd "$REPO_ROOT" && ./install/setup "$t" </dev/null >/dev/null 2>&1 )
  assert_absent "${t}/.claude/skills/gone-skill" "하네스에서 사라진 스킬의 죽은 링크를 청소한다"

  # 끄면 만들지 않는다
  local t2
  t2="$(mktemp -d "${WORK}/expo3.XXXXXX")"
  ( cd "$REPO_ROOT" && ./install/setup "$t2" </dev/null >/dev/null 2>&1 )
  # 덧붙이면 skills: 가 중복돼 앞의 true 가 읽힌다(최소 파서는 첫 일치를 쓴다) —
  # 기존 키의 값을 바꿔야 한다. 2026-11-06 이 테스트 자신의 결함으로 실측됨.
  sed -i 's/^  expose_to_claude: true/  expose_to_claude: false/' "${t2}/harness.config.yaml"
  rm -rf "${t2}/.claude/skills"
  ( source "${INSTALL_DIR}/lib.sh" >/dev/null 2>&1
    out="$(expose_skills "$t2" "${t2}/.harness" 2>/dev/null)"
    printf '%s' "$out" > "${WORK}/expo_off.txt" )
  assert_contains "$(cat "${WORK}/expo_off.txt")" "꺼짐" "expose_to_claude: false 면 노출하지 않는다"

  # 게이트 훅이 설치본에 실제로 들어왔는가 + settings.json 에 연결됐는가
  assert_present "${t}/.harness/adapters/claude/hooks/pre-tool-use.sh" "게이트 훅이 배포된다"
  assert_present "${t}/.harness/adapters/claude/hooks/gate_decide.py" "게이트 판정부가 배포된다"
  assert_present "${t}/.harness/install/approve" "approve 가 배포된다"
  assert_present "${t}/.harness/core/router.md" "라우터가 배포된다"
  assert_contains "$(cat "${t}/.claude/settings.json")" "PreToolUse" "PreToolUse 훅이 연결된다"
  assert_contains "$(cat "${t}/.claude/settings.json")" "pre-tool-use.sh" "게이트 훅 경로가 연결된다"
  assert_absent "${t}/.harness/.github" "CI 정의는 배포되지 않는다 (개발용)"
}


# ---- silent-failure-guard 회귀 -----------------------------------------------
# 두 그룹 모두 "실패가 아무에게도 안 보인다"는 한 병을 고정한다. 느슨해지기 쉬운
# 계약이라 숫자와 키 부재까지 못박는다.

# gate_call 은 stderr 만 돌려준다. 여기서는 stdout(JSON)도 봐야 하므로 셋을 분리한다.
# "rc<TAB>stdout경로<TAB>stderr경로" 를 돌려준다.
gate_call3() {
  local target="$1" json="$2" rc=0 o e
  o="$(mktemp "${WORK}/go.XXXXXX")"; e="$(mktemp "${WORK}/ge.XXXXXX")"
  printf '%s' "$json" | CLAUDE_PROJECT_DIR="$target" bash "$GATE_HOOK" >"$o" 2>"$e" || rc=$?
  printf '%s\t%s\t%s' "$rc" "$o" "$e"
}

# storage.vault_root 만 든 최소 컨피그
vault_fixture() {
  local f="$1" value="$2"
  cat > "$f" <<EOF
active_harness: claude
storage:
  vault_root: ${value}
EOF
}

test_vault_root_guard() {
  group "vault_root 가드 — HRN-W023 (조용한 오배송 차단)"

  local t st out
  t="$(mktemp -d "${WORK}/vr.XXXXXX")"

  # (1~3) 3상태 — lib.sh 와 검증기가 같은 이름을 쓴다
  mkdir -p "${t}/realvault"
  vault_fixture "${t}/ok.yaml" "${t}/realvault"
  st="$(vault_root_state "${t}/ok.yaml" | cut -f1)"
  assert_eq "$st" "ok" "실존 경로 → ok"

  vault_fixture "${t}/empty.yaml" "null"
  st="$(vault_root_state "${t}/empty.yaml" | cut -f1)"
  assert_eq "$st" "empty" "null → empty (YAML 미지정)"

  vault_fixture "${t}/dead.yaml" "${t}/no-such-vault"
  st="$(vault_root_state "${t}/dead.yaml" | cut -f1)"
  assert_eq "$st" "missing" "없는 경로 → missing"

  # (4) 하필 "null" 이라는 이름의 디렉터리가 있어도 empty 다.
  #     접지 않으면 YAML 미지정이 ok 로 오판되어 저장이 ./null 로 간다.
  ( cd "$t" && mkdir -p null && printf 'storage:\n  vault_root: null\n' > nulldir.yaml )
  st="$(cd "$t" && vault_root_state nulldir.yaml | cut -f1)"
  assert_eq "$st" "empty" '"null" 이름의 디렉터리가 있어도 empty (오판 방지)'

  # (5~7) 검증기 — W023 은 비차단이고, W010 영역을 침범하지 않는다
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    local rc
    cp "${REPO_ROOT}/harness.config.yaml" "${t}/full-dead.yaml"
    python3 -I -c 'import io,sys,re
p=sys.argv[1]; s=io.open(p,encoding="utf-8").read()
io.open(p,"w",encoding="utf-8").write(re.sub(r"^  vault_root: .*$","  vault_root: /nonexistent/kgh-test-vault",s,count=1,flags=re.M))' "${t}/full-dead.yaml"
    rc=0
    out="$(python3 -I "${REPO_ROOT}/install/validate_config.py" "${t}/full-dead.yaml" \
            "${REPO_ROOT}/config/schema.yaml" "${REPO_ROOT}/adapters" "${REPO_ROOT}" 2>&1)" || rc=$?
    assert_contains "$out" "HRN-W023" "검증기: 죽은 경로 → W023"
    assert_eq "$rc" "0" "검증기: W023 은 비차단 (종료코드 0)"

    cp "${REPO_ROOT}/harness.config.yaml" "${t}/full-ok.yaml"
    python3 -I -c 'import io,sys,re
p=sys.argv[1]; s=io.open(p,encoding="utf-8").read()
io.open(p,"w",encoding="utf-8").write(re.sub(r"^  vault_root: .*$","  vault_root: "+sys.argv[2],s,count=1,flags=re.M))' \
      "${t}/full-ok.yaml" "${t}/realvault"
    out="$(python3 -I "${REPO_ROOT}/install/validate_config.py" "${t}/full-ok.yaml" \
            "${REPO_ROOT}/config/schema.yaml" "${REPO_ROOT}/adapters" "${REPO_ROOT}" 2>&1)" || true
    assert_not_contains "$out" "HRN-W023" "검증기: 실존 경로 → W023 없음"

    out="$(python3 -I "${REPO_ROOT}/install/validate_config.py" \
            "${REPO_ROOT}/config/harness.config.template.yaml" \
            "${REPO_ROOT}/config/schema.yaml" "${REPO_ROOT}/adapters" "${REPO_ROOT}" 2>&1)" || true
    assert_not_contains "$out" "HRN-W023" "검증기: 미지정(null) → W023 없음 (W010 영역 불침범)"
  else
    note "python3/PyYAML 없음 — 검증기 W023 단정 3건 건너뜀"
  fi

  # (8~10) setup 비대화형 + 죽은 경로 → 묻지 않고, 경고하고, 값을 보존한다
  local p2 log
  p2="$(mktemp -d "${WORK}/vrsetup.XXXXXX")"
  ( cd "$p2" && git init -q . )
  "${INSTALL_DIR}/setup" "$p2" </dev/null >/dev/null 2>&1 || true
  if [ -f "${p2}/harness.config.yaml" ]; then
    python3 -I -c 'import io,sys,re
p=sys.argv[1]; s=io.open(p,encoding="utf-8").read()
io.open(p,"w",encoding="utf-8").write(re.sub(r"^  vault_root: .*$","  vault_root: /nonexistent/kgh-dead",s,count=1,flags=re.M))' \
      "${p2}/harness.config.yaml" 2>/dev/null || true
    log="$(mktemp "${WORK}/vrlog.XXXXXX")"
    "${INSTALL_DIR}/setup" "$p2" </dev/null >"$log" 2>&1 || true
    assert_contains "$(cat "$log")" "HRN-W023" "setup: 죽은 경로를 보고한다"
    assert_not_contains "$(cat "$log")" "storage.vault_root 를 지정하시겠습니까" \
      "setup: 비대화형에서는 묻지 않는다 (CI 를 세우지 않는다)"
    assert_contains "$(cat "${p2}/harness.config.yaml")" "/nonexistent/kgh-dead" \
      "setup: 비대화형은 컨피그 값을 고치지 않는다"
    # (11) gate.log 는 커밋 대상이 아니다
    assert_contains "$(cat "${p2}/.gitignore" 2>/dev/null || echo '')" "/.harness/gate.log" \
      ".gitignore 가 gate.log 를 제외한다"
  else
    note "setup 산출물 없음 — setup W023 단정 4건 건너뜀"
  fi

  # (12) 배포에서 gate.log 가 빠진다
  assert_contains "$(cat "${REPO_ROOT}/.harnessignore")" "gate.log" \
    ".harnessignore 가 gate.log 를 배포에서 제외한다"
}

test_fail_open_visibility() {
  group "fail-open 가시성 — exit 0 + stderr 는 아무도 못 본다"

  local t r rc o e n1 n2
  t="$(mktemp -d "${WORK}/fo.XXXXXX")"
  gate_fixture "$t"
  : > "${t}/.harness/work/demo/2026-11-06/설계.md"     # 무장 (.approved 없음)

  # (1) 미무장 상태에서는 stdout 이 비어 있어야 한다 — 매 호출 잡음 금지
  local u
  u="$(mktemp -d "${WORK}/fo-unarmed.XXXXXX")"
  gate_fixture "$u"                                    # 설계 문서 없음 → 미무장
  r="$(gate_call3 "$u" '{"tool_name":"Edit","tool_input":{"file_path":"src/x.ts"}}')"
  rc="$(printf '%s' "$r" | cut -f1)"; o="$(printf '%s' "$r" | cut -f2)"
  assert_eq "$rc" "0" "미무장 → 통과"
  assert_eq "$(wc -c < "$o" | tr -d ' ')" "0" "미무장 → stdout 0바이트 (잡음 금지)"

  # (2~6) fail-open: 깨진 입력 → 통과 + 로그 + JSON 3채널
  n1=0; [ -f "${t}/.harness/gate.log" ] && n1="$(wc -l < "${t}/.harness/gate.log")"
  r="$(gate_call3 "$t" 'not json at all')"
  rc="$(printf '%s' "$r" | cut -f1)"; o="$(printf '%s' "$r" | cut -f2)"; e="$(printf '%s' "$r" | cut -f3)"
  assert_eq "$rc" "0" "fail-open → 통과시킨다 (게이트 고장이 작업을 세우지 않는다)"
  assert_present "${t}/.harness/gate.log" "fail-open 이 gate.log 를 남긴다"
  n2="$(wc -l < "${t}/.harness/gate.log")"
  assert_eq "$((n2 - n1))" "1" "fail-open 1회 → 로그 1줄"
  assert_contains "$(cat "${t}/.harness/gate.log")" "W021" "로그 줄이 W021 로 분류된다"
  assert_contains "$(cat "$e")" "HRN-W021" "stderr 에도 남는다 (디버그 로깅 사용자용)"

  # (7~9) stdout JSON 계약 — 여기가 핵심이다
  if command -v python3 >/dev/null 2>&1; then
    local j
    j="$(python3 -I -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as ex:
    print("INVALID"); raise SystemExit(0)
raw = json.dumps(d)
print("ok"
      + ("|sys" if "systemMessage" in d else "")
      + ("|ctx" if "additionalContext" in d.get("hookSpecificOutput", {}) else "")
      + ("|PERM" if "permissionDecision" in raw else ""))' "$o")"
    assert_contains "$j" "ok" "fail-open stdout 이 유효 JSON 이다"
    assert_contains "$j" "|sys" "stdout JSON 에 systemMessage 가 있다 (사용자 채널)"
    assert_contains "$j" "|ctx" "stdout JSON 에 additionalContext 가 있다 (모델 채널)"
    # allow 는 권한 프롬프트를 건너뛴다. fail-open 이 권한 승격이 되면 안전한 쪽이
    # 아니라 반대쪽으로 실패한다 — 키 부재를 계약으로 못박는다.
    assert_not_contains "$j" "|PERM" "stdout JSON 에 permissionDecision 이 없다 (권한 승격 금지)"
  else
    note "python3 없음 — stdout JSON 단정 4건 건너뜀"
  fi

  # (10~11) 차단 경로는 JSON 을 내지 않고, 안내하는 approve 가 실제로 존재한다
  r="$(gate_call3 "$t" '{"tool_name":"Edit","tool_input":{"file_path":"src/x.ts"}}')"
  rc="$(printf '%s' "$r" | cut -f1)"; o="$(printf '%s' "$r" | cut -f2)"; e="$(printf '%s' "$r" | cut -f3)"
  assert_eq "$rc" "2" "무장 + block → 차단"
  assert_eq "$(wc -c < "$o" | tr -d ' ')" "0" "차단 시 stdout 에 JSON 을 내지 않는다"
  local apath
  apath="$(grep -oE '`[^`]*/approve [^`]*`' "$e" | head -n1 | tr -d '`' | awk '{print $1}')"
  if [ -n "$apath" ]; then
    assert_present "$apath" "차단 메시지가 안내하는 approve 경로가 실제로 존재한다"
  else
    assert_eq "found" "notfound" "차단 메시지에서 approve 경로를 못 찾았다"
  fi

  # (12~13) warn 모드도 같은 침묵이었다 — 이제 보여야 한다
  local w
  w="$(mktemp -d "${WORK}/fo-warn.XXXXXX")"
  gate_fixture "$w" "warn"
  : > "${w}/.harness/work/demo/2026-11-06/설계.md"
  r="$(gate_call3 "$w" '{"tool_name":"Edit","tool_input":{"file_path":"src/x.ts"}}')"
  rc="$(printf '%s' "$r" | cut -f1)"; o="$(printf '%s' "$r" | cut -f2)"
  assert_eq "$rc" "0" "warn 모드 → 통과시킨다"
  assert_contains "$(cat "$o")" "systemMessage" "warn 모드 경고가 stdout JSON 으로 나간다"
  assert_contains "$(cat "${w}/.harness/gate.log" 2>/dev/null || echo '')" "E016" \
    "warn 모드 통과가 gate.log 에 남는다"

  # (14) 로그를 못 써도 게이트는 작업을 세우지 않는다 (침묵을 한 함수에 가둔 결과)
  local ro
  ro="$(mktemp -d "${WORK}/fo-ro.XXXXXX")"
  gate_fixture "$ro"
  : > "${ro}/.harness/work/demo/2026-11-06/설계.md"
  chmod a-w "${ro}/.harness"
  r="$(gate_call3 "$ro" 'broken input')"
  rc="$(printf '%s' "$r" | cut -f1)"
  chmod u+w "${ro}/.harness"
  assert_eq "$rc" "0" "gate.log 를 못 써도 통과시킨다 (로그 실패가 작업을 세우지 않는다)"

  # (15~16) approve --list 가 fail-open 누적을 보고한다 / 0건이면 침묵한다
  local lt out
  lt="$(mktemp -d "${WORK}/fo-list.XXXXXX")"
  "${INSTALL_DIR}/setup" "$lt" </dev/null >/dev/null 2>&1 || true
  if [ -x "${lt}/.harness/install/approve" ]; then
    out="$("${lt}/.harness/install/approve" --list 2>&1)" || true
    assert_not_contains "$out" "fail-open 기록" "fail-open 0건이면 그 줄을 내지 않는다"
    printf '2026-11-06T13:00:00+09:00\tW021\tfail-open: 테스트\tEdit\tfoo\n' > "${lt}/.harness/gate.log"
    out="$("${lt}/.harness/install/approve" --list 2>&1)" || true
    assert_contains "$out" "fail-open 기록 1건" "approve --list 가 fail-open 누적을 보고한다"
  else
    note "approve 미배포 — --list 단정 2건 건너뜀"
  fi
}

test_hook_doc_state
test_gate_hook
test_approve_cli
test_injection_modes
test_skill_exposure
test_degradation_cause() {
  group "휴리스틱 열화 — 보고하는 원인이 실제 원인과 일치한다"

  # 실측(2026-11-06)에서 잡혔다: 메시지가 늘 "python3 가 없어"라고 단정했고, python3 가
  # 멀쩡하고 판정기만 없는 환경에서도 그렇게 보고했다. 틀린 원인은 틀린 조치를 부른다.
  local t h o e rc msg
  t="$(mktemp -d "${WORK}/dg.XXXXXX")"
  gate_fixture "$t"
  : > "${t}/.harness/work/demo/2026-11-06/설계.md"        # 무장 (.approved 없음)

  # 판정기 없는 위치로 훅을 복사한다 — python3 는 그대로 있다.
  h="${t}/hooks"; mkdir -p "$h"
  cp "$GATE_HOOK" "${h}/pre-tool-use.sh"
  assert_absent "${h}/gate_decide.py" "픽스처 전제: 판정기 파일이 없다"

  o="$(mktemp "${WORK}/dgo.XXXXXX")"; e="$(mktemp "${WORK}/dge.XXXXXX")"
  rc=0
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' \
    "${t}/.harness/work/demo/2026-11-06/메모.md" \
    | CLAUDE_PROJECT_DIR="$t" bash "${h}/pre-tool-use.sh" >"$o" 2>"$e" || rc=$?
  assert_eq "$rc" "0" "판정기 부재 → 작업 문서 안 쓰기는 휴리스틱으로 통과"
  assert_present "${t}/.harness/gate.log" "열화 사실이 gate.log 에 남는다"

  msg="$(cat "$o" "$e" 2>/dev/null)"
  if command -v python3 >/dev/null 2>&1; then
    assert_contains "$msg" "판정기 파일이 없습니다" "경고가 실제 원인(판정기 부재)을 말한다"
    assert_not_contains "$msg" "python3 가 없" "python3 가 있는데 없다고 단정하지 않는다"
    assert_contains "$(cat "${t}/.harness/gate.log")" "판정기 파일이 없습니다" \
      "로그도 실제 원인을 남긴다"
  else
    note "python3 없음 — 원인 분별 단정 3건 건너뜀 (이 환경에서는 python3 부재가 실제 원인)"
  fi
}

test_vault_root_guard
test_fail_open_visibility
test_degradation_cause

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
