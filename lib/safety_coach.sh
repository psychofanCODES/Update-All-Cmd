# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Safety Coach: Homebrew tap trust (cached), OSV malicious/advisory package audit,
# read-only exposed-port audit, and guided post-receipt remediation walkthrough.
# Public-safe: zero hardcoded user paths, private IPs, or secrets.

: "${UPDATE_ALL_SECURITY_SCAN:=1}"
: "${UPDATE_ALL_NONINTERACTIVE:=0}"
: "${UPDATE_ALL_OSV_MOCK_FILE:=}"
: "${UPDATE_ALL_OSV_TUPLES_MOCK_FILE:=}"
: "${UPDATE_ALL_OSV_VULN_MOCK_DIR:=}"
: "${UPDATE_ALL_PORTS_MOCK_FILE:=}"
: "${_ua_brew_trust_inspected:=0}"
: "${_ua_brew_preflight_shown:=0}"
: "${_ua_count_security:=0}"
: "${G_OK:=✓}"
: "${G_FAIL:=✗}"
: "${G_SKIP:=·}"
: "${G_WARN:=▲}"
: "${G_SAFETY:=◆}"
: "${G_ARROW:=→}"
: "${G_GUTTER:=│}"

if ! declare -p _ua_sec_kind >/dev/null 2>&1; then
  declare -a _ua_sec_kind=()
  declare -a _ua_sec_sev=()
  declare -a _ua_sec_target=()
  declare -a _ua_sec_id=()
  declare -a _ua_sec_summary=()
  declare -a _ua_sec_remedy_desc=()
  declare -a _ua_sec_remedy_cmd=()
  declare -a _ua_sec_alt_cmd=()
fi
if ! declare -p _ua_brew_all_taps >/dev/null 2>&1; then
  declare -a _ua_brew_all_taps=()
fi
if ! declare -p _ua_osv_eco >/dev/null 2>&1; then
  declare -a _ua_osv_eco=()
  declare -a _ua_osv_mgr=()
  declare -a _ua_osv_pkg=()
  declare -a _ua_osv_ver=()
fi

add_security_finding() {
  local kind="$1" sev="$2" target="$3" id="$4" summary="$5"
  local remedy_desc="$6" remedy_cmd="$7" alt_cmd="${8:-}"
  _ua_sec_kind+=("$kind")
  _ua_sec_sev+=("$sev")
  _ua_sec_target+=("$target")
  _ua_sec_id+=("$id")
  _ua_sec_summary+=("$summary")
  _ua_sec_remedy_desc+=("$remedy_desc")
  _ua_sec_remedy_cmd+=("$remedy_cmd")
  _ua_sec_alt_cmd+=("$alt_cmd")
  _ua_count_security=$(( _ua_count_security + 1 ))

  if declare -F add_concern >/dev/null 2>&1; then
    add_concern \
      "Safety Coach [${sev}]: ${target} (${id})" \
      "$summary" \
      "${remedy_desc}${remedy_cmd:+ Command: ${remedy_cmd}}"
  fi
}

_safety_valid_pkg_token() {
  local re='^[A-Za-z0-9@][A-Za-z0-9@._/+:-]*$'
  [[ "$1" =~ $re ]]
}

_safety_valid_brew_tap() {
  local re='^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$'
  [[ "$1" =~ $re ]]
}

_safety_valid_osv_id() {
  local re='^[A-Za-z0-9][A-Za-z0-9._-]*$'
  [[ "$1" =~ $re ]]
}

brew_tap_index() {
  local tap="$1" i
  for ((i = 0; i < ${#_ua_brew_taps[@]}; i++)); do
    if [ "${_ua_brew_taps[$i]}" = "$tap" ]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

inspect_brew_tap_trust() {
  local taps tap info source installed="" installed_from_tap
  if [ "${_ua_brew_trust_inspected:-0}" = 1 ]; then
    return 0
  fi
  _ua_brew_trust_inspected=1
  _ua_brew_all_taps=()
  _ua_brew_taps=()
  _ua_brew_sources=()
  _ua_brew_installed=()
  _ua_brew_untap_choices=()

  command -v brew >/dev/null 2>&1 || return 0
  if declare -F run_probe_bounded >/dev/null 2>&1; then
    taps="$(run_probe_bounded "${UPDATE_ALL_PROBE_TIMEOUT:-15s}" env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew tap || true)"
  else
    taps="$(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew tap 2>/dev/null || true)"
  fi
  [ -n "$taps" ] || return 0

  while IFS= read -r tap; do
    [ -n "$tap" ] || continue
    if ! _safety_valid_brew_tap "$tap"; then
      continue
    fi
    _ua_brew_all_taps+=("$tap")
    if declare -F run_probe_bounded >/dev/null 2>&1; then
      info="$(run_probe_bounded "${UPDATE_ALL_PROBE_TIMEOUT:-15s}" env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew tap-info "$tap" || true)"
    else
      info="$(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew tap-info "$tap" 2>&1 || true)"
    fi
    if printf '%s\n' "$info" | grep -Eq '(^|[[:space:]])Untrusted($|[[:space:]])'; then
      source="$(printf '%s\n' "$info" | sed -n 's/^From:[[:space:]]*//p' | sed -n '1p')"
      if [ -z "$installed" ]; then
        if declare -F run_probe_bounded >/dev/null 2>&1; then
          installed="$(
            run_probe_bounded "${UPDATE_ALL_PROBE_TIMEOUT:-15s}" env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew list --formula --full-name || true
            run_probe_bounded "${UPDATE_ALL_PROBE_TIMEOUT:-15s}" env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew list --cask --full-name || true
          )"
        else
          installed="$(
            HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew list --formula --full-name 2>/dev/null || true
            HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew list --cask --full-name 2>/dev/null || true
          )"
        fi
      fi
      installed_from_tap="$(printf '%s\n' "$installed" | grep -F "${tap}/" || true)"
      _ua_brew_taps+=("$tap")
      _ua_brew_sources+=("$source")
      _ua_brew_installed+=("$installed_from_tap")
      _ua_brew_untap_choices+=("no")
    fi
  done <<< "$taps"
}

insight_row() {
  local icon="$1" label="$2" text="$3" label_color="${4:-${C_LABEL:-}}"
  printf '  %b%s%b %b%s%b %b%-12s%b %s\n' \
    "${C_FRAME:-}" "$G_GUTTER" "${C_RESET:-}" \
    "${C_UNIT:-}" "$icon" "${C_RESET:-}" \
    "$label_color" "$label" "${C_RESET:-}" "$text"
}

print_brew_tap_insight() {
  local tap="$1" source="${2:-}" installed_from_tap="${3:-}" item
  local top_corner="╭─" bot_corner="╰─"
  if [ "${_ua_utf8:-1}" -eq 0 ]; then
    top_corner="+-"
    bot_corner="+-"
  fi

  printf '\n  %b%s%b %bINSIGHT%b %bHomebrew trust warning%b\n' \
    "${C_FRAME:-}" "$top_corner" "${C_RESET:-}" "${C_ORANGE:-}" "${C_RESET:-}" "${C_HEADER:-}" "${C_RESET:-}"
  printf '  %b%s%b\n' "${C_FRAME:-}" "$G_GUTTER" "${C_RESET:-}"
  insight_row "$G_WARN" "Signal" "Homebrew marks this tap as Untrusted: $tap" "${C_WARN:-}"
  insight_row "?" "Tap" "A tap is an extra Homebrew package source, like an added shelf outside the default store." "${C_LABEL:-}"
  insight_row "?" "Untrusted" "Homebrew cannot prove who controls this source. That is a provenance warning, not a malware verdict." "${C_LABEL:-}"
  insight_row "?" "Untap means" "brew untap removes this package source from Homebrew, so future brew runs stop reading it." "${C_LABEL:-}"
  insight_row "$G_OK" "Boundary" "It does not delete your projects or random files. Homebrew may refuse if installed tools still depend on it." "${C_OK:-}"
  insight_row "$G_OK" "Panic level" "Do not panic. Pause, check whether you use it, and remove it if it is unfamiliar or unused." "${C_OK:-}"
  [ -n "$source" ] && insight_row "$G_ARROW" "Source" "$source" "${C_PATH:-}"
  if [ -n "$installed_from_tap" ]; then
    insight_row "$G_ARROW" "Installed" "Tools from this tap were found below; keep only if you intentionally rely on them." "${C_WARN:-}"
    printf '%s\n' "$installed_from_tap" | while IFS= read -r item; do
      [ -n "$item" ] || continue
      printf '  %b%s%b   %b-%b %s\n' "${C_FRAME:-}" "$G_GUTTER" "${C_RESET:-}" "${C_TIP:-}" "${C_RESET:-}" "$item"
    done
    insight_row "$G_ARROW" "Action" "Keep for now if you recognize those tools, then review the source before future upgrades." "${C_WARN:-}"
  else
    insight_row "$G_ARROW" "Installed" "None detected from this tap by brew list --full-name." "${C_OK:-}"
    insight_row "$G_ARROW" "Action" "Recommended: untap it now. Unused untrusted taps should not stay in your update path." "${C_OK:-}"
  fi
  insight_row "$" "Command" "brew untap $tap" "${C_CMD:-}"
  printf '  %b%s%b %bPlain English:%b scary word, boring rule: unknown package sources deserve review.\n' \
    "${C_FRAME:-}" "$bot_corner" "${C_RESET:-}" "${C_HEADER:-}" "${C_RESET:-}"
}

show_brew_tap_trust_preflight() {
  local i tap idx untrusted_count=0 remove_code=0 tap_remedy_cmd="" tap_alt_cmd=""

  _ua_brew_preflight_shown=1
  inspect_brew_tap_trust

  pending_updates_begin "brew tap trust preflight"
  printf '  %bWhat this checks:%b extra Homebrew tap repositories outside the default Homebrew set.\n' "${C_HEADER:-}" "${C_RESET:-}"
  printf '  %bPlain English:%b an Untrusted tap is not automatically malware and it is not an expired license.\n' "${C_HEADER:-}" "${C_RESET:-}"
  printf '  It means Homebrew cannot prove the tap belongs to a trusted source. A tap can define install and update code, so it deserves a pause.\n'
  printf '  %bGold standard:%b remove unused or unrecognized untrusted taps; keep one only when you intentionally need it and trust its source.\n' "${C_HEADER:-}" "${C_RESET:-}"
  printf '  update-all collected any untap choices before the update sweep started.\n'

  if [ "${#_ua_brew_all_taps[@]}" -eq 0 ]; then
    pending_update_note "no third-party taps are configured"
    printf '\n'
    track "brew tap trust" 0 "" "" "no third-party taps configured"
    return 0
  fi

  for ((i = 0; i < ${#_ua_brew_all_taps[@]}; i++)); do
    tap="${_ua_brew_all_taps[$i]}"
    if ! _safety_valid_brew_tap "$tap"; then
      continue
    fi
    idx="$(brew_tap_index "$tap" 2>/dev/null || true)"
    if [ -n "$idx" ]; then
      untrusted_count=$((untrusted_count + 1))
      pending_update_note "$tap: insight shown during upfront choices"
      if choice_is_yes "${_ua_brew_untap_choices[$idx]}"; then
        if [ "${UPDATE_ALL_DRY_RUN:-0}" = 1 ]; then
          show_cmd brew untap "$tap"
          add_concern "Trust source action" \
            "Dry-run previewed removing the untrusted Homebrew tap $tap." \
            "In a live run, answer yes only if you do not recognize or use this tap; Homebrew may refuse if installed tools still depend on it."
        else
          printf '%bRUN%b upfront choice was yes: untapping %s before brew update.\n' "${C_OK:-}" "${C_RESET:-}" "$tap"
          if run_cmd env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew untap "$tap"; then
            add_concern "Trust source removed" \
              "Homebrew no longer reads package definitions from $tap." \
              "Nothing else is needed unless you later discover a tool expected that tap; then install from a trusted source."
          else
            remove_code=1
            add_concern "Trust source removal failed" \
              "Homebrew could not untap $tap. This often happens when installed tools still depend on that tap." \
              "Read the error above, decide whether those tools are still needed, and retry manually with care."
          fi
        fi
      else
        printf '%bKEEP%b %s left installed by upfront choice.\n' "${C_WARN:-}" "${C_RESET:-}" "$tap"
        tap_remedy_cmd=""
        tap_alt_cmd=""
        if _safety_valid_brew_tap "$tap"; then
          tap_remedy_cmd="brew untap $tap"
          tap_alt_cmd="brew tap-info $tap"
        fi
        add_security_finding \
          "UNTRUSTED TAP" \
          "WARN" \
          "$tap" \
          "BREW-UNTRUSTED-TAP" \
          "The untrusted Homebrew tap $tap stayed in your update path because the upfront answer was no. Keep it only if you recognize and trust its maintainer." \
          "Remove this tap if unused or unfamiliar." \
          "$tap_remedy_cmd" \
          "$tap_alt_cmd"
      fi
    else
      pending_update_note "$tap: no untrusted marker reported"
    fi
  done

  if [ "$untrusted_count" -eq 0 ]; then
    pending_update_note "no untrusted taps reported by brew tap-info"
    track "brew tap trust" 0 "" "" "no untrusted taps reported"
  elif [ "$remove_code" -eq 0 ]; then
    track "brew tap trust" 0 "" "" "reviewed $untrusted_count untrusted tap(s); removals were prompt-gated"
  else
    track "brew tap trust" 1 "" "" "one or more requested brew untap commands failed"
  fi
  printf '\n'
  return "$remove_code"
}

_safety_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

_safety_osv_remedy_for() {
  local mgr="$1" pkg="$2" is_mal="$3" __cmd_var="$4" __alt_var="$5"
  local _sel_cmd="" _sel_alt=""
  if ! _safety_valid_pkg_token "$pkg"; then
    printf -v "$__cmd_var" '%s' ""
    printf -v "$__alt_var" '%s' ""
    return 0
  fi
  case "$mgr" in
    npm)
      if [ "$is_mal" = 1 ]; then
        _sel_cmd="npm uninstall -g $pkg"
        _sel_alt="npm list -g $pkg"
      else
        _sel_cmd="npm install -g ${pkg}@latest"
        _sel_alt="npm uninstall -g $pkg"
      fi
      ;;
    uv)
      if [ "$is_mal" = 1 ]; then
        _sel_cmd="uv tool uninstall $pkg"
        _sel_alt="uv tool list"
      else
        _sel_cmd="uv tool upgrade $pkg"
        _sel_alt="uv tool uninstall $pkg"
      fi
      ;;
    pipx|PyPI)
      if [ "$is_mal" = 1 ]; then
        _sel_cmd="pipx uninstall $pkg"
        _sel_alt="pipx list"
      else
        _sel_cmd="pipx upgrade $pkg"
        _sel_alt="pipx uninstall $pkg"
      fi
      ;;
    cargo|crates.io)
      if [ "$is_mal" = 1 ]; then
        _sel_cmd="cargo uninstall $pkg"
        _sel_alt="cargo install --list"
      else
        _sel_cmd="cargo install $pkg"
        _sel_alt="cargo uninstall $pkg"
      fi
      ;;
    brew|Homebrew)
      if [ "$is_mal" = 1 ]; then
        _sel_cmd="brew uninstall $pkg"
        _sel_alt="brew info $pkg"
      else
        _sel_cmd="brew upgrade $pkg"
        _sel_alt="brew uninstall $pkg"
      fi
      ;;
  esac
  printf -v "$__cmd_var" '%s' "$_sel_cmd"
  printf -v "$__alt_var" '%s' "$_sel_alt"
}

_safety_osv_query_cmd() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 6s "$@" 2>/dev/null || true
  else
    "$@" 2>/dev/null || true
  fi
}

_safety_collect_osv_tuples() {
  local pkg ver raw
  _ua_osv_eco=()
  _ua_osv_mgr=()
  _ua_osv_pkg=()
  _ua_osv_ver=()

  if command -v npm >/dev/null 2>&1; then
    raw="$(_safety_osv_query_cmd npm list -g --depth=0 | sed -nE 's/^.* ([^[:space:]@][^[:space:]]*|@[^[:space:]]+\/[^[:space:]@]+)@([0-9][^[:space:]]*).*$/\1|\2/p' || true)"
    while IFS='|' read -r pkg ver; do
      [ -n "$pkg" ] && [ -n "$ver" ] || continue
      _ua_osv_eco+=("npm"); _ua_osv_mgr+=("npm"); _ua_osv_pkg+=("$pkg"); _ua_osv_ver+=("$ver")
    done <<< "$raw"
  fi

  if command -v uv >/dev/null 2>&1; then
    raw="$(_safety_osv_query_cmd uv tool list | sed -nE 's/^([A-Za-z0-9._-]+)[[:space:]]+v?([0-9][A-Za-z0-9._+-]*).*$/\1|\2/p' || true)"
    while IFS='|' read -r pkg ver; do
      [ -n "$pkg" ] && [ -n "$ver" ] || continue
      _ua_osv_eco+=("PyPI"); _ua_osv_mgr+=("uv"); _ua_osv_pkg+=("$pkg"); _ua_osv_ver+=("$ver")
    done <<< "$raw"
  fi

  if command -v pipx >/dev/null 2>&1; then
    raw="$(_safety_osv_query_cmd pipx list --short | sed -nE 's/^([A-Za-z0-9._-]+)[[:space:]]+([0-9][A-Za-z0-9._+-]*).*$/\1|\2/p' || true)"
    while IFS='|' read -r pkg ver; do
      [ -n "$pkg" ] && [ -n "$ver" ] || continue
      _ua_osv_eco+=("PyPI"); _ua_osv_mgr+=("pipx"); _ua_osv_pkg+=("$pkg"); _ua_osv_ver+=("$ver")
    done <<< "$raw"
  fi

  if command -v cargo >/dev/null 2>&1; then
    raw="$(_safety_osv_query_cmd cargo install --list | sed -nE 's/^([A-Za-z0-9._-]+)[[:space:]]+v([0-9][A-Za-z0-9._+-]*):.*$/\1|\2/p' || true)"
    while IFS='|' read -r pkg ver; do
      [ -n "$pkg" ] && [ -n "$ver" ] || continue
      _ua_osv_eco+=("crates.io"); _ua_osv_mgr+=("cargo"); _ua_osv_pkg+=("$pkg"); _ua_osv_ver+=("$ver")
    done <<< "$raw"
  fi
}

_safety_parse_osv_batch() {
  local json_text="$1"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json_text" | python3 -c '
import json, math, sys

def cvss_roundup(val):
    int_input = round(val * 100000)
    if (int_input % 10000) == 0:
        return int_input / 100000.0
    return (math.floor(int_input / 10000) + 1) / 10.0

def cvss_v3_score(vector):
    if not isinstance(vector, str):
        return None
    s = vector.strip().upper()
    if not (s.startswith("CVSS:3.0/") or s.startswith("CVSS:3.1/")):
        return None
    metrics = {}
    for part in s.split("/")[1:]:
        if ":" in part:
            k, v = part.split(":", 1)
            metrics[k] = v
    scope = metrics.get("S")
    if scope not in ("U", "C"):
        return None
    av_map = {"N": 0.85, "A": 0.62, "L": 0.55, "P": 0.20}
    ac_map = {"L": 0.77, "H": 0.44}
    pr_map = {"N": 0.85, "L": 0.62, "H": 0.27} if scope == "U" else {"N": 0.85, "L": 0.68, "H": 0.50}
    ui_map = {"N": 0.85, "R": 0.62}
    impact_map = {"H": 0.56, "L": 0.22, "N": 0.0}
    try:
        av = av_map[metrics["AV"]]
        ac = ac_map[metrics["AC"]]
        pr = pr_map[metrics["PR"]]
        ui = ui_map[metrics["UI"]]
        c = impact_map[metrics["C"]]
        i = impact_map[metrics["I"]]
        a = impact_map[metrics["A"]]
    except KeyError:
        return None
    impact_sub = 1.0 - ((1.0 - c) * (1.0 - i) * (1.0 - a))
    if scope == "U":
        impact = 6.42 * impact_sub
    else:
        impact = 7.52 * (impact_sub - 0.029) - 3.25 * ((impact_sub - 0.02) ** 15)
    if impact <= 0.0:
        return 0.0
    exploitability = 8.22 * av * ac * pr * ui
    raw = (impact + exploitability) if scope == "U" else (1.08 * (impact + exploitability))
    return cvss_roundup(min(raw, 10.0))

def cvss_to_sev(score):
    if isinstance(score, bool):
        return ""
    val = None
    if isinstance(score, (int, float)):
        val = float(score)
    elif isinstance(score, str):
        st = score.strip()
        if st.upper().startswith(("CVSS:3.0/", "CVSS:3.1/")):
            val = cvss_v3_score(st)
        else:
            try:
                val = float(st)
            except (TypeError, ValueError):
                val = None
    if val is None:
        return ""
    if val >= 9.0:
        return "CRITICAL"
    if val >= 7.0:
        return "HIGH"
    if val >= 4.0:
        return "MEDIUM"
    if val > 0.0:
        return "LOW"
    return ""

def extract_sev(v):
    db = v.get("database_specific")
    if isinstance(db, dict):
        if db.get("severity"):
            return str(db.get("severity")).upper().strip()
        cvss = db.get("cvss")
        if isinstance(cvss, dict) and cvss.get("score") is not None:
            s = cvss_to_sev(cvss.get("score"))
            if s:
                return s
    for a in (v.get("affected") or []):
        if not isinstance(a, dict):
            continue
        for key in ("database_specific", "ecosystem_specific"):
            sub = a.get(key)
            if isinstance(sub, dict) and sub.get("severity"):
                return str(sub.get("severity")).upper().strip()
    best = ""
    order = {"": 0, "LOW": 1, "MEDIUM": 2, "MODERATE": 2, "HIGH": 3, "CRITICAL": 4}
    for sev_obj in (v.get("severity") or []):
        if isinstance(sev_obj, dict):
            s = cvss_to_sev(sev_obj.get("score"))
            if order.get(s, 0) > order.get(best, 0):
                best = s
    return best

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
results = data.get("results") or []
for idx, entry in enumerate(results):
    if not isinstance(entry, dict):
        continue
    for v in (entry.get("vulns") or []):
        if not isinstance(v, dict):
            continue
        vid = str(v.get("id") or "").strip()
        if not vid:
            continue
        raw_sum = str(v.get("summary") or v.get("details") or "")
        summary = " ".join(raw_sum.replace("|", "/").split())[:180].strip()
        sev = extract_sev(v)
        if vid.startswith("MAL-"):
            sev = "CRITICAL"
        needs_hydrate = "1" if (not summary or not sev) else "0"
        aff_pkg = ""
        aff_eco = ""
        for a in (v.get("affected") or []):
            if not isinstance(a, dict):
                continue
            p = a.get("package") or {}
            if isinstance(p, dict) and p.get("name"):
                aff_pkg = str(p.get("name"))
                aff_eco = str(p.get("ecosystem") or "")
                break
        print(f"{idx}|{vid}|{sev}|{needs_hydrate}|{aff_pkg}|{aff_eco}|{summary}")
' 2>/dev/null || true
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # jq variables and string interpolation are intentional
    printf '%s' "$json_text" | jq -r '
      def norm_sev:
        if type == "string" then ascii_upcase | gsub("^\\s+|\\s+$"; "") else "" end;
      def pow15:
        . as $x | ($x * $x) as $x2 | ($x2 * $x2) as $x4 | ($x4 * $x4) as $x8 | ($x8 * $x4 * $x2 * $x);
      def cvss_roundup:
        ((. * 100000 + 0.5) | floor) as $i |
        if ($i - (($i / 10000 | floor) * 10000)) == 0 then ($i / 100000)
        else ((($i / 10000) | floor) + 1) / 10 end;
      def cvss_v3_num($vec):
        ($vec | ascii_upcase | split("/")[1:] | reduce .[] as $p ({}; ($p | split(":")) as $kv | if ($kv | length) >= 2 then .[$kv[0]] = $kv[1] else . end)) as $m |
        ($m.S // "") as $s |
        if ($s != "U" and $s != "C") then empty
        else
          ({"N": 0.85, "A": 0.62, "L": 0.55, "P": 0.20}[$m.AV // ""]) as $av |
          ({"L": 0.77, "H": 0.44}[$m.AC // ""]) as $ac |
          ((if $s == "U" then {"N": 0.85, "L": 0.62, "H": 0.27} else {"N": 0.85, "L": 0.68, "H": 0.50} end)[$m.PR // ""]) as $pr |
          ({"N": 0.85, "R": 0.62}[$m.UI // ""]) as $ui |
          ({"H": 0.56, "L": 0.22, "N": 0.0}[$m.C // ""]) as $c |
          ({"H": 0.56, "L": 0.22, "N": 0.0}[$m.I // ""]) as $ci |
          ({"H": 0.56, "L": 0.22, "N": 0.0}[$m.A // ""]) as $ca |
          if ($av == null or $ac == null or $pr == null or $ui == null or $c == null or $ci == null or $ca == null) then empty
          else
            (1.0 - ((1.0 - $c) * (1.0 - $ci) * (1.0 - $ca))) as $impact_sub |
            (if $s == "U" then (6.42 * $impact_sub) else (7.52 * ($impact_sub - 0.029) - 3.25 * (($impact_sub - 0.02) | pow15)) end) as $imp |
            if $imp <= 0 then 0.0
            else
              (8.22 * $av * $ac * $pr * $ui) as $exp |
              (if $s == "U" then ($imp + $exp) else (1.08 * ($imp + $exp)) end) as $raw |
              ((if $raw > 10.0 then 10.0 else $raw end) | cvss_roundup)
            end
          end
        end;
      def cvss_num($val):
        if ($val | type) == "number" then $val
        elif ($val | type) == "string" then
          ($val | gsub("^\\s+|\\s+$"; "")) as $t |
          if ($t | test("^[0-9]+(\\.[0-9]+)?$")) then ($t | tonumber)
          elif ($t | ascii_upcase | test("^CVSS:3\\.[01]/")) then cvss_v3_num($t)
          else empty end
        else empty end;
      def cvss_sev($arr; $db_score):
        ([($arr[]? | cvss_num(.score?)), cvss_num($db_score)] | max) as $m |
        if $m == null then ""
        elif $m >= 9.0 then "CRITICAL"
        elif $m >= 7.0 then "HIGH"
        elif $m >= 4.0 then "MEDIUM"
        elif $m > 0 then "LOW"
        else "" end;
      def extract_sev($v):
        (($v.database_specific.severity? // "" | norm_sev) as $s1 |
         if $s1 != "" then $s1
         else ([$v.affected[]? | (.database_specific.severity? // .ecosystem_specific.severity? // empty)] | first // "" | norm_sev) as $s2 |
           if $s2 != "" then $s2
           else cvss_sev(($v.severity // []); ($v.database_specific.cvss.score? // null))
           end
         end);
      (.results // []) | to_entries[] | .key as $idx | (.value.vulns // [])[] |
      (.id // "" | tostring) as $vid |
      select($vid != "") |
      (if ($vid | startswith("MAL-")) then "CRITICAL" else extract_sev(.) end) as $sev |
      ((.summary // .details // "") | tostring | gsub("[\r\n\t]+"; " ") | gsub("\\|"; "/") | gsub("^ +| +$"; "") | .[0:180]) as $sum |
      (if ($sum == "" or $sev == "") then "1" else "0" end) as $need |
      ((.affected // [])[0].package.name? // "" | tostring) as $pkg |
      ((.affected // [])[0].package.ecosystem? // "" | tostring) as $eco |
      "\($idx)|\($vid)|\($sev)|\($need)|\($pkg)|\($eco)|\($sum)"
    ' 2>/dev/null || true
    return 0
  fi

  return 1
}

_safety_parse_osv_vuln() {
  local json_text="$1"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json_text" | python3 -c '
import json, math, sys

def cvss_roundup(val):
    int_input = round(val * 100000)
    if (int_input % 10000) == 0:
        return int_input / 100000.0
    return (math.floor(int_input / 10000) + 1) / 10.0

def cvss_v3_score(vector):
    if not isinstance(vector, str):
        return None
    s = vector.strip().upper()
    if not (s.startswith("CVSS:3.0/") or s.startswith("CVSS:3.1/")):
        return None
    metrics = {}
    for part in s.split("/")[1:]:
        if ":" in part:
            k, v = part.split(":", 1)
            metrics[k] = v
    scope = metrics.get("S")
    if scope not in ("U", "C"):
        return None
    av_map = {"N": 0.85, "A": 0.62, "L": 0.55, "P": 0.20}
    ac_map = {"L": 0.77, "H": 0.44}
    pr_map = {"N": 0.85, "L": 0.62, "H": 0.27} if scope == "U" else {"N": 0.85, "L": 0.68, "H": 0.50}
    ui_map = {"N": 0.85, "R": 0.62}
    impact_map = {"H": 0.56, "L": 0.22, "N": 0.0}
    try:
        av = av_map[metrics["AV"]]
        ac = ac_map[metrics["AC"]]
        pr = pr_map[metrics["PR"]]
        ui = ui_map[metrics["UI"]]
        c = impact_map[metrics["C"]]
        i = impact_map[metrics["I"]]
        a = impact_map[metrics["A"]]
    except KeyError:
        return None
    impact_sub = 1.0 - ((1.0 - c) * (1.0 - i) * (1.0 - a))
    if scope == "U":
        impact = 6.42 * impact_sub
    else:
        impact = 7.52 * (impact_sub - 0.029) - 3.25 * ((impact_sub - 0.02) ** 15)
    if impact <= 0.0:
        return 0.0
    exploitability = 8.22 * av * ac * pr * ui
    raw = (impact + exploitability) if scope == "U" else (1.08 * (impact + exploitability))
    return cvss_roundup(min(raw, 10.0))

def cvss_to_sev(score):
    if isinstance(score, bool):
        return ""
    val = None
    if isinstance(score, (int, float)):
        val = float(score)
    elif isinstance(score, str):
        st = score.strip()
        if st.upper().startswith(("CVSS:3.0/", "CVSS:3.1/")):
            val = cvss_v3_score(st)
        else:
            try:
                val = float(st)
            except (TypeError, ValueError):
                val = None
    if val is None:
        return ""
    if val >= 9.0:
        return "CRITICAL"
    if val >= 7.0:
        return "HIGH"
    if val >= 4.0:
        return "MEDIUM"
    if val > 0.0:
        return "LOW"
    return ""

try:
    v = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(v, dict):
    sys.exit(0)

sev = ""
db = v.get("database_specific")
if isinstance(db, dict):
    if db.get("severity"):
        sev = str(db.get("severity")).upper().strip()
    elif isinstance(db.get("cvss"), dict) and db["cvss"].get("score") is not None:
        sev = cvss_to_sev(db["cvss"].get("score"))
if not sev:
    for a in (v.get("affected") or []):
        if not isinstance(a, dict):
            continue
        for key in ("database_specific", "ecosystem_specific"):
            sub = a.get(key)
            if isinstance(sub, dict) and sub.get("severity"):
                sev = str(sub.get("severity")).upper().strip()
                break
        if sev:
            break
if not sev:
    order = {"": 0, "LOW": 1, "MEDIUM": 2, "MODERATE": 2, "HIGH": 3, "CRITICAL": 4}
    for sev_obj in (v.get("severity") or []):
        if isinstance(sev_obj, dict):
            s = cvss_to_sev(sev_obj.get("score"))
            if order.get(s, 0) > order.get(sev, 0):
                sev = s

raw_sum = str(v.get("summary") or v.get("details") or "")
summary = " ".join(raw_sum.replace("|", "/").split())[:180].strip()
aff_pkg = ""
aff_eco = ""
for a in (v.get("affected") or []):
    if not isinstance(a, dict):
        continue
    p = a.get("package") or {}
    if isinstance(p, dict) and p.get("name"):
        aff_pkg = str(p.get("name"))
        aff_eco = str(p.get("ecosystem") or "")
        break
print(f"{sev}|{aff_pkg}|{aff_eco}|{summary}")
' 2>/dev/null || true
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # jq variables and string interpolation are intentional
    printf '%s' "$json_text" | jq -r '
      def norm_sev:
        if type == "string" then ascii_upcase | gsub("^\\s+|\\s+$"; "") else "" end;
      def pow15:
        . as $x | ($x * $x) as $x2 | ($x2 * $x2) as $x4 | ($x4 * $x4) as $x8 | ($x8 * $x4 * $x2 * $x);
      def cvss_roundup:
        ((. * 100000 + 0.5) | floor) as $i |
        if ($i - (($i / 10000 | floor) * 10000)) == 0 then ($i / 100000)
        else ((($i / 10000) | floor) + 1) / 10 end;
      def cvss_v3_num($vec):
        ($vec | ascii_upcase | split("/")[1:] | reduce .[] as $p ({}; ($p | split(":")) as $kv | if ($kv | length) >= 2 then .[$kv[0]] = $kv[1] else . end)) as $m |
        ($m.S // "") as $s |
        if ($s != "U" and $s != "C") then empty
        else
          ({"N": 0.85, "A": 0.62, "L": 0.55, "P": 0.20}[$m.AV // ""]) as $av |
          ({"L": 0.77, "H": 0.44}[$m.AC // ""]) as $ac |
          ((if $s == "U" then {"N": 0.85, "L": 0.62, "H": 0.27} else {"N": 0.85, "L": 0.68, "H": 0.50} end)[$m.PR // ""]) as $pr |
          ({"N": 0.85, "R": 0.62}[$m.UI // ""]) as $ui |
          ({"H": 0.56, "L": 0.22, "N": 0.0}[$m.C // ""]) as $c |
          ({"H": 0.56, "L": 0.22, "N": 0.0}[$m.I // ""]) as $ci |
          ({"H": 0.56, "L": 0.22, "N": 0.0}[$m.A // ""]) as $ca |
          if ($av == null or $ac == null or $pr == null or $ui == null or $c == null or $ci == null or $ca == null) then empty
          else
            (1.0 - ((1.0 - $c) * (1.0 - $ci) * (1.0 - $ca))) as $impact_sub |
            (if $s == "U" then (6.42 * $impact_sub) else (7.52 * ($impact_sub - 0.029) - 3.25 * (($impact_sub - 0.02) | pow15)) end) as $imp |
            if $imp <= 0 then 0.0
            else
              (8.22 * $av * $ac * $pr * $ui) as $exp |
              (if $s == "U" then ($imp + $exp) else (1.08 * ($imp + $exp)) end) as $raw |
              ((if $raw > 10.0 then 10.0 else $raw end) | cvss_roundup)
            end
          end
        end;
      def cvss_num($val):
        if ($val | type) == "number" then $val
        elif ($val | type) == "string" then
          ($val | gsub("^\\s+|\\s+$"; "")) as $t |
          if ($t | test("^[0-9]+(\\.[0-9]+)?$")) then ($t | tonumber)
          elif ($t | ascii_upcase | test("^CVSS:3\\.[01]/")) then cvss_v3_num($t)
          else empty end
        else empty end;
      def cvss_sev($arr; $db_score):
        ([($arr[]? | cvss_num(.score?)), cvss_num($db_score)] | max) as $m |
        if $m == null then ""
        elif $m >= 9.0 then "CRITICAL"
        elif $m >= 7.0 then "HIGH"
        elif $m >= 4.0 then "MEDIUM"
        elif $m > 0 then "LOW"
        else "" end;
      ((.database_specific.severity? // "" | norm_sev) as $s1 |
       if $s1 != "" then $s1
       else ([.affected[]? | (.database_specific.severity? // .ecosystem_specific.severity? // empty)] | first // "" | norm_sev) as $s2 |
         if $s2 != "" then $s2
         else cvss_sev((.severity // []); (.database_specific.cvss.score? // null))
         end
       end) as $sev |
      ((.summary // .details // "") | tostring | gsub("[\r\n\t]+"; " ") | gsub("\\|"; "/") | gsub("^ +| +$"; "") | .[0:180]) as $sum |
      ((.affected // [])[0].package.name? // "" | tostring) as $pkg |
      ((.affected // [])[0].package.ecosystem? // "" | tostring) as $eco |
      "\($sev)|\($pkg)|\($eco)|\($sum)"
    ' 2>/dev/null || true
    return 0
  fi

  return 1
}

scan_osv_packages() {
  local payload="" i max_q=150 max_hydrate=15 response="" parsed=""
  local idx vid sev needs_hydrate aff_pkg aff_eco summary pkg mgr ver kind rcmd acmd found=0 is_mal=0
  local m_eco m_mgr m_pkg m_ver vuln_json hydrated_line h_sev h_pkg h_eco h_sum
  local cache_i cache_hit=0 hydrated_count=0
  local -a cache_id_list=() cache_sev_list=() cache_pkg_list=() cache_eco_list=() cache_sum_list=()

  if [ "${UPDATE_ALL_SECURITY_SCAN:-1}" = 0 ]; then
    skip_step "safety coach: OSV package scan" "disabled via UPDATE_ALL_SECURITY_SCAN=0"
    return 0
  fi

  if [ "${UPDATE_ALL_DRY_RUN:-0}" = 1 ] && [ -z "${UPDATE_ALL_OSV_MOCK_FILE:-}" ]; then
    show_cmd curl -fsS --max-time 8 -H "Content-Type: application/json" https://api.osv.dev/v1/querybatch
    track "safety coach: OSV package scan" 0 "" "" "dry-run preview (sends only package name, ecosystem, and version)"
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1 && ! command -v jq >/dev/null 2>&1; then
    skip_step "safety coach: OSV package scan" "OSV response parser requires python3 or jq"
    return 0
  fi

  if [ -n "${UPDATE_ALL_OSV_MOCK_FILE:-}" ] && [ -r "$UPDATE_ALL_OSV_MOCK_FILE" ]; then
    _ua_osv_eco=()
    _ua_osv_mgr=()
    _ua_osv_pkg=()
    _ua_osv_ver=()
    if [ -n "${UPDATE_ALL_OSV_TUPLES_MOCK_FILE:-}" ] && [ -r "$UPDATE_ALL_OSV_TUPLES_MOCK_FILE" ]; then
      while IFS='|' read -r m_eco m_mgr m_pkg m_ver; do
        [ -n "$m_pkg" ] || continue
        _ua_osv_eco+=("$m_eco")
        _ua_osv_mgr+=("$m_mgr")
        _ua_osv_pkg+=("$m_pkg")
        _ua_osv_ver+=("$m_ver")
      done < "$UPDATE_ALL_OSV_TUPLES_MOCK_FILE"
    fi
    response="$(cat "$UPDATE_ALL_OSV_MOCK_FILE")"
  else
    _safety_collect_osv_tuples
    if ! command -v curl >/dev/null 2>&1; then
      skip_step "safety coach: OSV package scan" "curl not installed"
      return 0
    fi
    if [ "${#_ua_osv_pkg[@]}" -eq 0 ]; then
      track "safety coach: OSV package scan" 0 "" "" "no global packages discovered to query"
      return 0
    fi

    payload='{"queries":['
    for ((i = 0; i < ${#_ua_osv_pkg[@]} && i < max_q; i++)); do
      [ "$i" -gt 0 ] && payload="${payload},"
      payload="${payload}{\"package\":{\"name\":\"$(_safety_json_escape "${_ua_osv_pkg[$i]}")\",\"ecosystem\":\"$(_safety_json_escape "${_ua_osv_eco[$i]}")\"},\"version\":\"$(_safety_json_escape "${_ua_osv_ver[$i]}")\"}"
    done
    payload="${payload}]}"

    if ! response="$(curl -fsS --max-time 8 -H 'Content-Type: application/json' -d "$payload" 'https://api.osv.dev/v1/querybatch' 2>/dev/null)"; then
      skip_step "safety coach: OSV package scan" "offline or api.osv.dev unreachable; skipped safely"
      return 0
    fi
  fi

  parsed="$(_safety_parse_osv_batch "$response")"
  while IFS='|' read -r idx vid sev needs_hydrate aff_pkg aff_eco summary; do
    [ -n "$vid" ] || continue
    if ! _safety_valid_osv_id "$vid"; then
      continue
    fi

    if [ "$needs_hydrate" = "1" ] && { [ -z "${UPDATE_ALL_OSV_MOCK_FILE:-}" ] || [ -n "${UPDATE_ALL_OSV_VULN_MOCK_DIR:-}" ]; }; then
      cache_hit=0
      h_sev=""
      h_pkg=""
      h_eco=""
      h_sum=""
      for ((cache_i = 0; cache_i < ${#cache_id_list[@]}; cache_i++)); do
        if [ "${cache_id_list[$cache_i]}" = "$vid" ]; then
          h_sev="${cache_sev_list[$cache_i]}"
          h_pkg="${cache_pkg_list[$cache_i]}"
          h_eco="${cache_eco_list[$cache_i]}"
          h_sum="${cache_sum_list[$cache_i]}"
          cache_hit=1
          break
        fi
      done

      if [ "$cache_hit" -eq 0 ] && [ "$hydrated_count" -lt "$max_hydrate" ]; then
        hydrated_count=$((hydrated_count + 1))
        vuln_json=""
        if [ -n "${UPDATE_ALL_OSV_VULN_MOCK_DIR:-}" ] && [ -r "${UPDATE_ALL_OSV_VULN_MOCK_DIR}/${vid}.json" ]; then
          vuln_json="$(cat "${UPDATE_ALL_OSV_VULN_MOCK_DIR}/${vid}.json")"
        elif [ -z "${UPDATE_ALL_OSV_MOCK_FILE:-}" ] && command -v curl >/dev/null 2>&1; then
          vuln_json="$(curl -fsS --max-time 4 "https://api.osv.dev/v1/vulns/${vid}" 2>/dev/null || true)"
        fi
        if [ -n "$vuln_json" ]; then
          hydrated_line="$(_safety_parse_osv_vuln "$vuln_json")"
          IFS='|' read -r h_sev h_pkg h_eco h_sum <<< "$hydrated_line"
        fi
        cache_id_list+=("$vid")
        cache_sev_list+=("$h_sev")
        cache_pkg_list+=("$h_pkg")
        cache_eco_list+=("$h_eco")
        cache_sum_list+=("$h_sum")
      fi

      [ -n "$sev" ] || sev="$h_sev"
      [ -n "$aff_pkg" ] || aff_pkg="$h_pkg"
      [ -n "$aff_eco" ] || aff_eco="$h_eco"
      [ -n "$summary" ] || summary="$h_sum"
    fi

    is_mal=0
    kind="ADVISORY"
    case "$vid" in
      MAL-*)
        is_mal=1
        kind="MALICIOUS"
        sev="CRITICAL"
        [ -n "$summary" ] || summary="OpenSSF Malicious Package match reported by OSV."
        ;;
      GHSA-*|CVE-*|PYSEC-*|RUSTSEC-*)
        case "$sev" in
          CRITICAL|HIGH) ;;
          LOW|MODERATE|MEDIUM) continue ;;
          "") sev="WARN" ;;
          *) continue ;;
        esac
        [ -n "$summary" ] || summary="Security advisory reported by OSV."
        ;;
      *)
        case "$sev" in
          CRITICAL|HIGH) ;;
          *) continue ;;
        esac
        [ -n "$summary" ] || summary="Security advisory reported by OSV."
        ;;
    esac

    found=$((found + 1))
    pkg=""
    mgr=""
    ver=""
    if [ -n "$idx" ] && [ "$idx" -ge 0 ] && [ "$idx" -lt "${#_ua_osv_pkg[@]}" ]; then
      pkg="${_ua_osv_pkg[$idx]}"
      mgr="${_ua_osv_mgr[$idx]}"
      ver="${_ua_osv_ver[$idx]}"
    fi
    [ -n "$pkg" ] || pkg="${aff_pkg:-unknown-package}"
    [ -n "$mgr" ] || mgr="${aff_eco:-npm}"

    _safety_osv_remedy_for "$mgr" "$pkg" "$is_mal" rcmd acmd
    if [ "$is_mal" = 1 ]; then
      add_security_finding "$kind" "$sev" "${pkg}${ver:+@${ver}} (${mgr})" "$vid" \
        "OpenSSF flagged this package as malicious: ${summary}" \
        "Uninstall this package immediately and rotate any credentials exposed in its environment." \
        "$rcmd" "$acmd"
    elif [ "$sev" = "WARN" ]; then
      add_security_finding "$kind" "$sev" "${pkg}${ver:+@${ver}} (${mgr})" "$vid" \
        "Security advisory (severity unrated in OSV): ${summary}" \
        "Review this advisory and upgrade to a patched version or remove the package if unused." \
        "$rcmd" "$acmd"
    else
      add_security_finding "$kind" "$sev" "${pkg}${ver:+@${ver}} (${mgr})" "$vid" \
        "High-severity security advisory: ${summary}" \
        "Upgrade to a patched version or remove the package if unused." \
        "$rcmd" "$acmd"
    fi
  done <<< "$parsed"

  if [ "$found" -eq 0 ]; then
    track "safety coach: OSV package scan" 0 "" "" "checked ${#_ua_osv_pkg[@]} global package(s); no MAL-* or critical/high advisories found"
  else
    track "safety coach: OSV package scan" 0 "" "" "found ${found} package security finding(s) — guided walkthrough will appear after receipt"
  fi
}

_safety_is_loopback_addr() {
  local addr="$1"
  case "$addr" in
    127.*|::1|'[::1]'|localhost|*%lo) return 0 ;;
    *) return 1 ;;
  esac
}

_safety_describe_bind_addr() {
  local raw="$1" clean o1 o2 rest
  clean="${raw#\[}"
  clean="${clean%\]}"
  clean="${clean%%%*}"

  case "$clean" in
    0.0.0.0|'*')
      printf 'all interfaces (0.0.0.0)'
      return 0
      ;;
    ::|'')
      printf 'all IPv6 interfaces (::)'
      return 0
      ;;
    fe80:*|FE80:*|fc*|FC*|fd*|FD*)
      printf 'LAN interface'
      return 0
      ;;
  esac

  case "$clean" in
    *.*.*.*)
      o1="${clean%%.*}"
      rest="${clean#*.}"
      o2="${rest%%.*}"
      if [ -z "$o1" ] || [ -z "$o2" ]; then
        printf 'non-loopback interface'
        return 0
      fi
      case "$o1:$o2" in
        *[!0-9:]*) printf 'non-loopback interface'; return 0 ;;
      esac
      if [ "$o1" -eq 10 ]; then
        printf 'LAN interface'
        return 0
      elif [ "$o1" -eq 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; then
        printf 'LAN interface'
        return 0
      elif [ "$o1" -eq 192 ] && [ "$o2" -eq 168 ]; then
        printf 'LAN interface'
        return 0
      elif [ "$o1" -eq 100 ] && [ "$o2" -ge 64 ] && [ "$o2" -le 127 ]; then
        printf 'LAN interface'
        return 0
      elif [ "$o1" -eq 169 ] && [ "$o2" -eq 254 ]; then
        printf 'LAN interface'
        return 0
      fi
      ;;
  esac

  printf 'non-loopback interface'
}

_safety_firewall_posture() {
  local out=""
  if command -v ufw >/dev/null 2>&1; then
    out="$(ufw status 2>/dev/null | sed -n '1p' || true)"
    if [ -z "$out" ] && command -v sudo >/dev/null 2>&1; then
      out="$(sudo -n ufw status 2>/dev/null | sed -n '1p' || true)"
    fi
    if [ -n "$out" ]; then
      printf 'ufw (%s)' "$out"
      return 0
    fi
    if command -v systemctl >/dev/null 2>&1; then
      out="$(systemctl is-active ufw 2>/dev/null || true)"
      [ -n "$out" ] && printf 'ufw service (%s)' "$out" && return 0
    fi
  elif command -v firewall-cmd >/dev/null 2>&1; then
    out="$(firewall-cmd --state 2>/dev/null || true)"
    [ -n "$out" ] && printf 'firewalld (%s)' "$out" && return 0
  fi
  printf 'firewall status not readable without sudo'
}

scan_public_ports() {
  local raw="" fw_note parsed="" seen="|" proto addr port proc bind_desc key found=0 proto_up
  local use_firewalld=0 fw_remedy_desc="" fw_remedy_cmd=""

  if [ "${UPDATE_ALL_SECURITY_SCAN:-1}" = 0 ]; then
    skip_step "safety coach: open ports" "disabled via UPDATE_ALL_SECURITY_SCAN=0"
    return 0
  fi

  if [ -n "${UPDATE_ALL_PORTS_MOCK_FILE:-}" ] && [ -r "$UPDATE_ALL_PORTS_MOCK_FILE" ]; then
    raw="$(cat "$UPDATE_ALL_PORTS_MOCK_FILE")"
  elif [ "${UPDATE_ALL_DRY_RUN:-0}" = 1 ]; then
    show_cmd ss -tulnpH
    track "safety coach: open ports" 0 "" "" "dry-run preview (read-only local listener check)"
    return 0
  elif command -v ss >/dev/null 2>&1; then
    raw="$(ss -tulnpH 2>/dev/null || ss -tulnH 2>/dev/null || true)"
  elif command -v netstat >/dev/null 2>&1; then
    raw="$(netstat -tulnp 2>/dev/null || netstat -tuln 2>/dev/null || true)"
  else
    skip_step "safety coach: open ports" "ss and netstat not installed"
    return 0
  fi

  fw_note="$(_safety_firewall_posture)"
  if ! command -v ufw >/dev/null 2>&1 && command -v firewall-cmd >/dev/null 2>&1; then
    use_firewalld=1
  fi

  parsed="$(printf '%s\n' "$raw" | awk '
    /^[[:space:]]*(tcp|udp|tcp6|udp6)[[:space:]]/ {
      proto = $1
      sub(/6$/, "", proto)
      local_col = ""
      # ss -tulnpH: Netid State Recv-Q Send-Q Local_Address:Port Peer_Address:Port [Process]
      # netstat -tulnp: Proto Recv-Q Send-Q Local_Address Foreign_Address [State] [PID/Program]
      if ($2 ~ /^(LISTEN|UNCONN|ESTAB|TIME-WAIT)$/) {
        local_col = $5
      } else {
        local_col = $4
      }
      if (local_col == "" || local_col !~ /:/) next
      n = split(local_col, parts, ":")
      port = parts[n]
      if (port !~ /^[0-9]+$/) next
      addr = substr(local_col, 1, length(local_col) - length(port) - 1)
      proc = "unknown"
      if (match($0, /users:\(\("[^"]+"/)) {
        proc = substr($0, RSTART + 9, RLENGTH - 10)
      } else if ($NF ~ /^[0-9]+\//) {
        proc = $NF
        sub(/^[0-9]+\//, "", proc)
        sub(/:$/, "", proc)
      }
      printf "%s|%s|%s|%s\n", proto, addr, port, proc
    }
  ')"

  while IFS='|' read -r proto addr port proc; do
    [ -n "$proto" ] && [ -n "$port" ] || continue
    if _safety_is_loopback_addr "$addr"; then
      continue
    fi
    key="${proto}:${port}:${proc}"
    case "$seen" in
      *"|${key}|"*) continue ;;
    esac
    seen="${seen}${key}|"

    found=$((found + 1))
    bind_desc="$(_safety_describe_bind_addr "$addr")"
    proto_up="$(printf '%s' "$proto" | tr '[:lower:]' '[:upper:]')"

    if [ "$use_firewalld" -eq 1 ]; then
      fw_remedy_desc="Rebind '${proc}' to 127.0.0.1 in its config if only local access is needed, or close port ${port}/${proto} in firewalld and reload."
      fw_remedy_cmd="sudo firewall-cmd --permanent --remove-port=${port}/${proto} && sudo firewall-cmd --reload"
    else
      fw_remedy_desc="Rebind '${proc}' to 127.0.0.1 in its config if only local access is needed, or deny inbound traffic via firewall."
      fw_remedy_cmd="sudo ufw deny ${port}/${proto}"
    fi

    add_security_finding \
      "EXPOSED PORT" \
      "WARN" \
      "${proc} (${proto}/${port} on ${bind_desc})" \
      "PORT-${proto_up}-${port}" \
      "Process '${proc}' is listening on ${bind_desc} port ${port}/${proto} instead of localhost-only. Firewall check: ${fw_note}." \
      "$fw_remedy_desc" \
      "$fw_remedy_cmd" \
      "ss -tulnpH sport = :${port}"
  done <<< "$parsed"

  if [ "$found" -eq 0 ]; then
    track "safety coach: open ports" 0 "" "" "no non-loopback listening sockets detected (${fw_note})"
  else
    track "safety coach: open ports" 0 "" "" "detected ${found} non-loopback listener(s) (${fw_note}) — review in Safety Coach after receipt"
  fi
}

run_safety_coach_scan() {
  if declare -F tui_set_phase >/dev/null 2>&1; then
    tui_set_phase "SAFETY"
  fi
  banner "SAFETY"
  section "safety coach scan"
  if declare -F tool_card >/dev/null 2>&1; then
    tool_card "safety" "safety coach" "read-only audit" "OSV + open ports + tap trust"
  fi

  if command -v brew >/dev/null 2>&1 && [ "${_ua_brew_preflight_shown:-0}" != 1 ]; then
    _ua_last_status="OK"
    if declare -F tui_step_begin >/dev/null 2>&1; then
      tui_step_begin "safety-brew" "brew tap trust"
    fi
    show_brew_tap_trust_preflight
    if declare -F tui_step_end >/dev/null 2>&1; then
      tui_step_end "safety-brew" "${_ua_last_status:-OK}"
    fi
  fi

  _ua_last_status="OK"
  if declare -F tui_step_begin >/dev/null 2>&1; then
    tui_step_begin "safety-osv" "safety coach: OSV package scan"
  fi
  scan_osv_packages
  if declare -F tui_step_end >/dev/null 2>&1; then
    tui_step_end "safety-osv" "${_ua_last_status:-OK}"
  fi

  _ua_last_status="OK"
  if declare -F tui_step_begin >/dev/null 2>&1; then
    tui_step_begin "safety-ports" "safety coach: open ports"
  fi
  scan_public_ports
  if declare -F tui_step_end >/dev/null 2>&1; then
    tui_step_end "safety-ports" "${_ua_last_status:-OK}"
  fi
}

_safety_exec_single_remedy_cmd() {
  local cmd="$1" tok
  local -a parts=()
  [ -n "$cmd" ] || return 1
  IFS=' ' read -r -a parts <<< "$cmd"
  [ "${#parts[@]}" -gt 0 ] || return 1

  for tok in "${parts[@]}"; do
    case "$tok" in
      *';'*|*'|'*|*'&'*|*'$'*|*'`'*|*'<'*|*'>'*)
        printf '  %b%s%b Refusing unsafe command token: %s\n' "${C_BAD:-}" "$G_FAIL" "${C_RESET:-}" "$tok"
        return 1
        ;;
    esac
  done

  if [ "${parts[0]}" = "sudo" ]; then
    sudo_cmd "${parts[@]:1}"
  else
    run_cmd "${parts[@]}"
  fi
}

_safety_exec_remedy_cmd() {
  local cmd="$1" left right
  [ -n "$cmd" ] || return 1
  case "$cmd" in
    *" && "*)
      left="${cmd%% && *}"
      right="${cmd#* && }"
      _safety_exec_single_remedy_cmd "$left" && _safety_exec_single_remedy_cmd "$right"
      ;;
    *)
      _safety_exec_single_remedy_cmd "$cmd"
      ;;
  esac
}

run_safety_coach_remedy() {
  local total="${#_ua_sec_kind[@]}" i sev kind target vid summary rdesc rcmd acmd
  local badge_color interactive=0 choice

  if [ "$total" -eq 0 ]; then
    printf '  %b%s%b %bSafety Coach:%b No malicious packages, critical advisories, or exposed public ports detected.\n\n' \
      "${C_OK:-}" "$G_SAFETY" "${C_RESET:-}" "${C_HEADER:-}" "${C_RESET:-}"
    return 0
  fi

  if [ -t 0 ] && [ -t 1 ] && [ "${UPDATE_ALL_DRY_RUN:-0}" = 0 ] && [ "${UPDATE_ALL_NONINTERACTIVE:-0}" != 1 ]; then
    interactive=1
  fi

  printf '\n'
  if [ "${_ua_utf8:-1}" -eq 0 ]; then
    printf '  %b+------------------------------------------------------------------------------+%b\n' "${C_ORANGE:-}" "${C_RESET:-}"
    printf '  %b|%b %b%s SAFETY COACH -- ISSUES FOUND (%d)%b\n' \
      "${C_ORANGE:-}" "${C_RESET:-}" "${C_BAD:-${C_ORANGE:-}}" "$G_SAFETY" "$total" "${C_RESET:-}"
    printf '  %b|%b %bGuided review: nothing is deleted or blocked automatically, even with --all.%b\n' \
      "${C_ORANGE:-}" "${C_RESET:-}" "${C_PURPOSE:-}" "${C_RESET:-}"
    printf '  %b+------------------------------------------------------------------------------+%b\n\n' "${C_ORANGE:-}" "${C_RESET:-}"
  else
    printf '  %b╭──────────────────────────────────────────────────────────────────────────────╮%b\n' "${C_ORANGE:-}" "${C_RESET:-}"
    printf '  %b│%b %b%s SAFETY COACH — ISSUES FOUND (%d)%b\n' \
      "${C_ORANGE:-}" "${C_RESET:-}" "${C_BAD:-${C_ORANGE:-}}" "$G_SAFETY" "$total" "${C_RESET:-}"
    printf '  %b│%b %bGuided review: nothing is deleted or blocked automatically, even with --all.%b\n' \
      "${C_ORANGE:-}" "${C_RESET:-}" "${C_PURPOSE:-}" "${C_RESET:-}"
    printf '  %b╰──────────────────────────────────────────────────────────────────────────────╯%b\n\n' "${C_ORANGE:-}" "${C_RESET:-}"
  fi

  for ((i = 0; i < total; i++)); do
    sev="${_ua_sec_sev[$i]}"
    kind="${_ua_sec_kind[$i]}"
    target="${_ua_sec_target[$i]}"
    vid="${_ua_sec_id[$i]}"
    summary="${_ua_sec_summary[$i]}"
    rdesc="${_ua_sec_remedy_desc[$i]}"
    rcmd="${_ua_sec_remedy_cmd[$i]}"
    acmd="${_ua_sec_alt_cmd[$i]}"

    case "$sev" in
      CRITICAL|HIGH) badge_color="${C_BAD:-}" ;;
      *)             badge_color="${C_WARN:-}" ;;
    esac

    printf '  %b[%d/%d]%b %b%s · %s%b  %b%s%b  %b(%s)%b\n' \
      "${C_FRAME:-}" "$((i + 1))" "$total" "${C_RESET:-}" \
      "$badge_color" "$sev" "$kind" "${C_RESET:-}" \
      "${C_HEADER:-}" "$target" "${C_RESET:-}" \
      "${C_TIP:-}" "$vid" "${C_RESET:-}"
    printf '     %bWhat this means:%b %s\n' "${C_LABEL:-}" "${C_RESET:-}" "$summary"
    printf '     %bRecommended fix:%b %s\n' "${C_LABEL:-}" "${C_RESET:-}" "$rdesc"
    if [ -n "$rcmd" ]; then
      printf '     %bCommand:%b         %b$ %s%b\n' "${C_LABEL:-}" "${C_RESET:-}" "${C_CMD:-}" "$rcmd" "${C_RESET:-}"
    fi
    if [ -n "$acmd" ]; then
      printf '     %bAlternate:%b       %b$ %s%b\n' "${C_LABEL:-}" "${C_RESET:-}" "${C_TIP:-}" "$acmd" "${C_RESET:-}"
    fi

    if [ "$interactive" -eq 1 ]; then
      printf '\n     %b[1]%b Run recommended fix now  %b·%b  %b[2]%b Run alternate / inspect  %b·%b  %b[3]%b Skip for now  %b·%b  %b[q]%b Exit\n' \
        "${C_CMD:-}" "${C_RESET:-}" "${C_FRAME:-}" "${C_RESET:-}" \
        "${C_CMD:-}" "${C_RESET:-}" "${C_FRAME:-}" "${C_RESET:-}" \
        "${C_CMD:-}" "${C_RESET:-}" "${C_FRAME:-}" "${C_RESET:-}" \
        "${C_CMD:-}" "${C_RESET:-}"
      printf '     %bChoice [1/2/3/q]:%b ' "${C_WARN:-}" "${C_RESET:-}"
      IFS= read -r choice || break
      case "$choice" in
        1)
          if [ -n "$rcmd" ]; then
            if _safety_exec_remedy_cmd "$rcmd"; then
              printf '     %b%s Remedy completed:%b %s\n' "${C_OK:-}" "$G_OK" "${C_RESET:-}" "$rcmd"
            else
              printf '     %b%s Remedy returned non-zero exit:%b %s\n' "${C_BAD:-}" "$G_FAIL" "${C_RESET:-}" "$rcmd"
            fi
          else
            printf '     %b%s No automated command available for this finding.%b\n' "${C_TIP:-}" "$G_SKIP" "${C_RESET:-}"
          fi
          ;;
        2)
          if [ -n "$acmd" ]; then
            if _safety_exec_remedy_cmd "$acmd"; then
              printf '     %b%s Alternate action completed:%b %s\n' "${C_OK:-}" "$G_OK" "${C_RESET:-}" "$acmd"
            else
              printf '     %b%s Alternate action returned non-zero exit:%b %s\n' "${C_BAD:-}" "$G_FAIL" "${C_RESET:-}" "$acmd"
            fi
          else
            printf '     %b%s No alternate command available for this finding.%b\n' "${C_TIP:-}" "$G_SKIP" "${C_RESET:-}"
          fi
          ;;
        q|Q)
          printf '     %b%s Exiting Safety Coach walkthrough. Remaining findings stay listed above.%b\n\n' "${C_TIP:-}" "$G_SKIP" "${C_RESET:-}"
          break
          ;;
        *)
          printf '     %b%s Skipped for now.%b\n' "${C_TIP:-}" "$G_SKIP" "${C_RESET:-}"
          ;;
      esac
    fi
    printf '\n'
  done

  if [ "$interactive" -eq 0 ]; then
    printf '  %b%s%b Non-interactive / preview mode: no remediation commands were executed.\n\n' \
      "${C_TIP:-}" "$G_SAFETY" "${C_RESET:-}"
  fi
}
