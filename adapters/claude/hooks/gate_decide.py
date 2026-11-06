#!/usr/bin/env python3
"""PreToolUse 게이트의 판정부. stdin = Claude Code 훅 JSON.

출력 한 줄 (TAB 구분), 종료코드는 항상 0 — 차단 여부는 호출자(pre-tool-use.sh)가 정한다:
    ALLOW\t<사유>
    BLOCK\t<도구>\t<대상>
    UNKNOWN\t<사유>          → 호출자가 fail-open(HRN-W021)

쉘에서 heredoc 으로 인라인하지 않고 별 파일로 두는 이유: `python3 - <<'PY'` 는 스크립트
본문이 stdin 을 차지해 훅 JSON 을 먹어버린다(2026-11-06 구현 중 실측 — 모든 판정이
UNKNOWN 으로 떨어졌다). 파일로 분리하면 stdin 은 JSON 전용이 된다.
"""
import json
import os
import sys

WRITE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit", "Update"}

# 셸 경유 "제자리 편집"만 본다. git commit·git push 는 막지 않는다 — 승인 전에 설계
# 문서를 커밋하는 것이 이 하네스의 정상 흐름이고(⑤ "설계 — 승인대기" 커밋이 git 이력에
# 실제로 있다), 커밋은 소스를 바꾸지 못한다. 소스를 바꾸는 경로는 위 쓰기 도구와 아래
# 패턴이며, 그쪽을 막으면 커밋할 변경 자체가 생기지 않는다.
INPLACE = ("sed -i", "sed --in-place", "perl -i", "perl -pi")


def main():
    if len(sys.argv) < 3:
        print("UNKNOWN\t인자 부족 (workroot·project_dir 필요)")
        return 0
    workroot = os.path.abspath(sys.argv[1])
    project_dir = sys.argv[2]

    def under(path):
        """작업 문서 디렉터리 안인가. ⑤⑥이 문서를 쓰는 구간이라 문서는 항상 허용한다."""
        if not path:
            return True
        p = path if os.path.isabs(path) else os.path.join(project_dir, path)
        return os.path.abspath(p).startswith(workroot + os.sep) or os.path.abspath(p) == workroot

    try:
        data = json.load(sys.stdin)
    except Exception as e:  # noqa: BLE001 — 사유를 그대로 올려야 W021 이 쓸모 있다
        print("UNKNOWN\tJSON 파싱 실패: %s" % e)
        return 0
    if not isinstance(data, dict):
        print("UNKNOWN\t훅 입력 최상위가 매핑이 아님: %s" % type(data).__name__)
        return 0

    tool = str(data.get("tool_name", ""))
    ti = data.get("tool_input")
    if not isinstance(ti, dict):
        ti = {}

    if tool in WRITE_TOOLS:
        paths = [ti.get(k) for k in ("file_path", "notebook_path", "path")]
        for e in ti.get("edits") or []:
            if isinstance(e, dict):
                paths.append(e.get("file_path"))
        paths = [str(p) for p in paths if p]
        if not paths:
            print("UNKNOWN\t%s 호출에서 대상 경로를 찾지 못함" % tool)
            return 0
        outside = [p for p in paths if not under(p)]
        if outside:
            print("BLOCK\t%s\t%s" % (tool, outside[0]))
        else:
            print("ALLOW\t작업 문서 안")
    elif tool == "Bash":
        cmd = str(ti.get("command", ""))
        hit = next((pat for pat in INPLACE if pat in cmd), None)
        if hit:
            print("BLOCK\t%s\t%s" % (tool, hit))
        else:
            print("ALLOW\t셸 — 제자리 편집 아님")
    else:
        print("ALLOW\t쓰기 도구 아님")
    return 0


if __name__ == "__main__":
    sys.exit(main())
