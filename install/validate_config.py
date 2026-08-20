#!/usr/bin/env python3
"""harness.config.yaml 3단계 검증. 종료코드 0=통과 1=차단."""
import sys, os, json, yaml

C_ERR, C_WARN, C_OK, C_RST = "\033[31m", "\033[33m", "\033[32m", "\033[0m"
errors, warns, checked = [], [], 0


def err(code, msg, fix_a, fix_b):
    errors.append(f"{C_ERR}❌ HRN-{code} — {msg}{C_RST}\n"
                  f"   조치: (a) {fix_a}\n         (b) {fix_b}")


def warn(code, msg, fix_a, fix_b):
    warns.append(f"{C_WARN}⚠ HRN-{code} — {msg}{C_RST}\n"
                 f"   조치: (a) {fix_a}\n         (b) {fix_b}")


def load(path):
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def superpowers_state():
    """('found', ver) | ('notfound', None) | ('unknown', 사유) — lib.sh detect_superpowers 와 동일 원천."""
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    manifest = os.path.join(base, "plugins", "installed_plugins.json")
    if not os.path.isfile(manifest):
        return "unknown", manifest
    try:
        with open(manifest, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return "unknown", manifest
    plugins = data.get("plugins", {}) if isinstance(data, dict) else {}
    if not isinstance(plugins, dict):
        return "unknown", manifest
    for k, v in plugins.items():
        if isinstance(k, str) and k.startswith("superpowers@"):
            ver = v.get("version", "unknown") if isinstance(v, dict) else "unknown"
            return "found", ver
    return "notfound", manifest


def check_type(val, spec, where):
    """타입·허용값 검사. 위반 시 사유 문자열, 통과 시 None."""
    t = spec.get("type")
    if val is None and spec.get("nullable"):
        return None
    if t == "enum":
        allowed = [str(v) for v in spec.get("values", [])]
        if str(val) not in allowed:
            return f"{where}: '{val}' 은 허용값이 아님 (허용: {', '.join(allowed)})"
    elif t == "bool":
        if not isinstance(val, bool):
            return f"{where}: '{val}' 은 참/거짓이 아님"
    elif t == "list":
        if not isinstance(val, list):
            return f"{where}: 목록이 아님"
    elif t == "map":
        if not isinstance(val, dict):
            return f"{where}: 매핑이 아님"
    return None


def main(config_path, schema_path, adapter_dir, source_dir):
    global checked
    cfg, sch = load(config_path), load(schema_path)

    # ── ① 구조 ────────────────────────────────────────────────────────────
    top = sch.get("top_level", {})
    for key in cfg:
        checked += 1
        if key not in top:
            err("E004", f"알 수 없는 최상위 키 '{key}'",
                "harness.config.yaml 에서 해당 키를 제거하거나 철자를 고치세요",
                f"의도한 키라면 {schema_path} 의 top_level 에 추가하세요")
    for key, spec in top.items():
        if spec.get("required") and key not in cfg:
            err("E004", f"필수 키 '{key}' 누락",
                f"harness.config.yaml 에 {key} 를 추가하세요",
                f"필수가 아니라면 {schema_path} 에서 required 를 내리세요")

    stages_sch = sch.get("stages", {})
    known = stages_sch.get("known", [])
    stage_keys = stages_sch.get("keys", {})
    for name, body in (cfg.get("stages") or {}).items():
        checked += 1
        if name not in known:
            err("E004", f"알 수 없는 구간 '{name}'",
                "harness.config.yaml 의 구간명 철자를 고치세요 "
                f"(알려진 구간: {', '.join(known)})",
                f"새 구간이라면 {schema_path} 의 stages.known 에 추가하세요")
            continue
        for k, v in (body or {}).items():
            checked += 1
            if k not in stage_keys:
                err("E004", f"알 수 없는 키 'stages.{name}.{k}'",
                    "해당 키를 제거하거나 철자를 고치세요 "
                    f"(허용: {', '.join(stage_keys)})",
                    f"의도한 키라면 {schema_path} 의 stages.keys 에 추가하세요")
                continue
            reason = check_type(v, stage_keys[k], f"stages.{name}.{k}")
            if reason:
                err("E004", reason,
                    "값을 허용 범위로 고치세요",
                    f"{schema_path} 의 허용값을 넓히세요")

    # ── ② 값 (어댑터 위임) ────────────────────────────────────────────────
    active = cfg.get("active_harness")
    caps_path = os.path.join(adapter_dir, str(active), "capabilities.yaml")
    caps = None
    if not os.path.isfile(caps_path):
        err("E010", f"active_harness '{active}' 의 어댑터 능력 파일 미발견 ({caps_path})",
            "active_harness 를 claude 로 변경하세요",
            f"해당 어댑터를 구현하고 {caps_path} 를 추가하세요")
    else:
        caps = load(caps_path)
        if not caps.get("implemented", False):
            err("E010", f"active_harness '{active}' 는 아직 구현되지 않은 어댑터",
                "active_harness 를 claude 로 변경하세요",
                "해당 어댑터를 구현한 뒤 capabilities.yaml 의 implemented 를 true 로 바꾸세요")

    if caps:
        models = caps.get("models", [])
        eff = caps.get("effort", {}) or {}
        eff_values = eff.get("values", [])

        def check_val(val, kind, where):
            global checked
            checked += 1
            if kind == "model" and val not in models:
                err("E001", f"{where}: 알 수 없는 model '{val}' (지원: {', '.join(models)})",
                    "harness.config.yaml 의 model 값을 지원 목록에서 고르세요",
                    f"모델이 새로 나왔다면 {caps_path} 의 models 를 갱신하세요")
            if kind == "effort" and val not in eff_values:
                err("E002", f"{where}: 알 수 없는 effort '{val}' (지원: {', '.join(eff_values)})",
                    "harness.config.yaml 의 effort 값을 지원 목록에서 고르세요",
                    f"{caps_path} 의 effort.values 를 갱신하세요")

        d = cfg.get("defaults") or {}
        if "model" in d:
            check_val(d["model"], "model", "defaults.model")
        if "effort" in d:
            check_val(d["effort"], "effort", "defaults.effort")
        for name, body in (cfg.get("stages") or {}).items():
            for k in ("model", "effort"):
                if body and k in body:
                    check_val(body[k], k, f"stages.{name}.{k}")

        if not eff.get("dispatch_supported", False):
            used = [f"stages.{n}" for n, b in (cfg.get("stages") or {}).items()
                    if b and "effort" in b]
            if "effort" in (cfg.get("defaults") or {}):
                used.insert(0, "defaults")
            if used:
                print(f"{C_WARN}⚠ effort 는 {active} 어댑터의 Agent 디스패치에서 "
                      f"지원되지 않아 무시됩니다 — 지정된 곳: {', '.join(used)}{C_RST}")

    # ── ③ 참조 실존 ───────────────────────────────────────────────────────
    sp_refs = []   # (구간, 스킬명) — 루프에서 수집만 한다
    for name, body in (cfg.get("stages") or {}).items():
        for s in ((body or {}).get("skills") or []):
            checked += 1
            if str(s).startswith("superpowers:"):
                sp_refs.append((name, str(s).split(":", 1)[1]))
                continue
            path = os.path.join(source_dir, "skills", str(s), "SKILL.md")
            if not os.path.isfile(path):
                err("E005", f"stages.{name}: 스킬 '{s}' 의 파일 미발견 ({path})",
                    f"stages.{name}.skills 의 스킬명 철자를 고치세요",
                    f"의도한 스킬이라면 skills/{s}/SKILL.md 를 만드세요")

    # 루프 밖: superpowers 설치 상태를 한 번만 판정해 한 번만 보고한다
    if sp_refs:
        state, info = superpowers_state()
        where = ", ".join(f"{n}:{s}" for n, s in sp_refs)
        if state == "found":
            print(f"{C_OK}✓ superpowers v{info} 확인 — 사용 구간: {where}{C_RST}")
        elif state == "notfound":
            warn("W014", f"superpowers 플러그인 미발견 — 영향 구간: {where}",
                 "/plugin marketplace add obra/superpowers-marketplace 후 /plugin install superpowers",
                 "쓰지 않는다면 해당 구간의 skills[] 에서 superpowers: 항목을 제거하세요")
        else:
            warn("W014", f"superpowers 설치 여부 확인 불가 ({info}) — 영향 구간: {where}",
                 "플러그인 매니페스트를 확인하거나 /plugin install superpowers 를 실행하세요",
                 "확인 불가 상태로 진행 — 해당 구간에서 스킬 없이 동작할 수 있습니다")

    # ── 요약 (결과 비은닉) ────────────────────────────────────────────────
    for w in warns:
        print(w)
    for e in errors:
        print(e)
    print()
    print("=== 검증 요약 ===")
    print(f"검사 항목 : {checked}")
    print(f"경고      : {len(warns)}")
    print(f"오류      : {len(errors)}")
    if errors:
        print(f"{C_ERR}검증 실패 — 위 오류를 해결한 뒤 재실행하세요.{C_RST}")
        return 1
    print(f"{C_OK}검증 통과{C_RST}")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:5]))
