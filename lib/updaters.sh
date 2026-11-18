# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Tracking, classification, delta extraction, and universal update phases.
# Bash 3.2 parse-compatible; sourced by bin/update-all.

UPDATE_ALL_BUILD_TIMEOUT="${UPDATE_ALL_BUILD_TIMEOUT:-1200s}"
UPDATE_ALL_EDITOR_TIMEOUT="${UPDATE_ALL_EDITOR_TIMEOUT:-120s}"
UPDATE_ALL_SNAP_TIMEOUT="${UPDATE_ALL_SNAP_TIMEOUT:-600s}"
UPDATE_ALL_FLATPAK_TIMEOUT="${UPDATE_ALL_FLATPAK_TIMEOUT:-600s}"
UPDATE_ALL_HEADLESS_EDITORS="${UPDATE_ALL_HEADLESS_EDITORS:-0}"

: "${_ua_count_updated:=0}"
: "${_ua_count_unchanged:=0}"
: "${_ua_count_ok:=0}"
: "${_ua_count_skip:=0}"
: "${_ua_count_fail:=0}"
_ua_last_status="OK"

if ! declare -p _ua_delta_pkgs >/dev/null 2>&1; then
  declare -a _ua_delta_pkgs=()
  declare -a _ua_delta_before=()
  declare -a _ua_delta_after=()
  declare -a _ua_delta_via=()
fi

# --- TUI phase/step hooks (safe no-ops if tui.sh is not loaded) ---
_ua_phase() {
  declare -F tui_set_phase >/dev/null 2>&1 && tui_set_phase "$1"
  banner "$1"
}
_ua_step_begin() {
  _ua_last_status="OK"
  declare -F tui_step_begin >/dev/null 2>&1 && tui_step_begin "$1" "${2:-$1}"
}
_ua_step_end() {
  declare -F tui_step_end >/dev/null 2>&1 && tui_step_end "$1" "${2:-$_ua_last_status}"
}

# --- Tracking, counters, and changelog delta recording ---
record_pkg_delta() {
  local pkg="${1:-}" bef="${2:-}" aft="${3:-}" via="${4:-update-all}" i
  [ -n "$pkg" ] || return 0
  [ -n "$bef" ] && [ -n "$aft" ] && [ "$bef" = "$aft" ] && return 0
  for ((i = 0; i < ${#_ua_delta_pkgs[@]}; i++)); do
    if [ "${_ua_delta_pkgs[$i]}" = "$pkg" ] && [ "${_ua_delta_via[$i]}" = "$via" ]; then
      _ua_delta_before[$i]="${bef:-${_ua_delta_before[$i]}}"
      _ua_delta_after[$i]="${aft:-${_ua_delta_after[$i]}}"
      return 0
    fi
  done
  _ua_delta_pkgs+=("$pkg")
  _ua_delta_before+=("${bef:--}")
  _ua_delta_after+=("${aft:--}")
  _ua_delta_via+=("$via")
}

track() {
  local label="$1" code_or_stat="$2" before="${3:-}" after="${4:-}" note="${5:-}" forced_status="${6:-}" status="" cb ca
  _ua_labels+=("$label")
  _ua_before+=("$before")
  _ua_after+=("$after")
  _ua_notes+=("$note")

  case "$code_or_stat" in
    UPDATED|OK|UNCHANGED|SKIP|FAIL)
      status="$code_or_stat"
      [ "$status" = "FAIL" ] && rc=1
      ;;
    *)
      if [ "${code_or_stat:-1}" -ne 0 ]; then
        status="FAIL"
        rc=1
      elif [ -n "$forced_status" ]; then
        status="$forced_status"
      elif [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
        status="UPDATED"
      elif [ -n "$before" ] && [ -n "$after" ]; then
        status="UNCHANGED"
      else
        status="OK"
      fi
      ;;
  esac

  _ua_stats+=("$status")
  _ua_last_status="$status"
  case "$status" in
    UPDATED)   _ua_count_updated=$(( _ua_count_updated + 1 )) ;;
    OK)        _ua_count_ok=$(( _ua_count_ok + 1 )) ;;
    UNCHANGED) _ua_count_unchanged=$(( _ua_count_unchanged + 1 )) ;;
    SKIP)      _ua_count_skip=$(( _ua_count_skip + 1 )) ;;
    FAIL)      _ua_count_fail=$(( _ua_count_fail + 1 )) ;;
  esac

  if [ "$status" = "UPDATED" ] && [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
    case "$before" in
      *" upgradable") ;;
      *)
        case "$label" in
          "brew formula: "*|"uv tool: "*) ;;
          *)
            if declare -F receipt_version >/dev/null 2>&1; then
              cb="$(receipt_version "$before")"
              ca="$(receipt_version "$after")"
            else
              cb="$before"
              ca="$after"
            fi
            [ "$cb" != "$ca" ] && record_pkg_delta "$label" "$cb" "$ca" "$label"
            ;;
        esac
        ;;
    esac
  fi

  tool_result "$status" "$note"
  if [ -n "$before" ] || [ -n "$after" ]; then
    print_receipt_version_pair "$status" "$before" "$after" "version" "   " 15
  fi
}

skip_step() {
  _ua_labels+=("$1")
  _ua_stats+=("SKIP")
  _ua_before+=("")
  _ua_after+=("")
  _ua_notes+=("${2:-not installed}")
  _ua_last_status="SKIP"
  _ua_count_skip=$(( _ua_count_skip + 1 ))
  tool_result "SKIP" "${2:-not installed}"
}

skip_tool() {
  local key="$1" title="$2" label="$3" note="${4:-not installed}" package="${5:-$1}"
  section "$label"
  tool_card "$key" "$title" "" "$package"
  skip_step "$label" "$note"
}

add_concern() {
  _ua_concern_titles+=("$1")
  _ua_concern_notes+=("$2")
  _ua_concern_actions+=("$3")
}

# --- Classification & firmware review helpers (selftest contract) ---
fwupd_has_installable_updates() {
  grep -F "New version:" >/dev/null 2>&1
}

fwupd_needs_manual_attention() {
  grep -Eiq 'Update State:[[:space:]]*Failed|Update Error:|failed to write-firmware|efivarsfs|UEFI Secure Boot|Signature Database|Key Exchange Key' >/dev/null 2>&1
}

firmware_summary_rows() {
  awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function clean(s) { gsub(/\r/, "", s); gsub(/^[[:space:]│├└─]+/, "", s); return trim(s) }
    function after_colon(s) { sub(/^.*:[[:space:]]*/, "", s); return clean(s) }
    {
      line = clean($0)
      if (line ~ /:$/ && line !~ /^(Device Flags|Release Flags|Description|Issues?|GUIDs|Checksum):/) {
        heading = line; sub(/:$/, "", heading)
      }
      if (line ~ /^Current version:/) { current = after_colon(line); device = heading }
      if (line ~ /^New version:/) {
        count++
        devices[count] = device; releases[count] = heading
        old_versions[count] = current; new_versions[count] = after_colon(line)
        urgencies[count] = "unknown"; summaries[count] = ""
      }
      if (count > 0 && line ~ /^Summary:/ && summaries[count] == "") summaries[count] = after_colon(line)
      if (count > 0 && line ~ /^Urgency:/ && urgencies[count] == "unknown") urgencies[count] = after_colon(line)
    }
    END {
      for (i = 1; i <= count; i++) {
        printf "%s|%s|%s|%s|%s|%s\n", devices[i], releases[i], old_versions[i], new_versions[i], urgencies[i], summaries[i]
      }
    }
  '
}

print_firmware_summary() {
  local output="$1" rows device release old_version new_version urgency summary
  rows="$(printf '%s\n' "$output" | firmware_summary_rows)"

  printf '   %bFIRMWARE REVIEW%b\n' "$C_HEADER" "$C_RESET"
  if [ -z "$rows" ]; then
    printf '   %bPlain English:%b fwupd did not report installable firmware updates.\n' "$C_HEADER" "$C_RESET"
    printf '   %b%s%b nothing to do here right now.\n\n' "$C_TIP" "action:" "$C_RESET"
    return 0
  fi

  printf '   %bPlain English:%b firmware updates touch hardware-level code and can require reboot, vendor trust, or Secure Boot setup.\n' "$C_HEADER" "$C_RESET"
  printf '   update-all is showing the useful parts here instead of dumping the scary raw fwupd tree.\n'
  printf '   %bDefault action:%b review these manually later; update-all will not auto-apply risky firmware from the unattended flow.\n\n' "$C_TIP" "$C_RESET"

  while IFS='|' read -r device release old_version new_version urgency summary; do
    [ -n "$device$release$old_version$new_version" ] || continue
    printf '   %b>%b %b%s%b\n' "$C_UNIT" "$C_RESET" "$C_HEADER" "${device:-Firmware device}" "$C_RESET"
    [ -z "$release" ] || printf '      %b%-8s%b %s\n' "$C_LABEL" "release" "$C_RESET" "$release"
    if [ -n "$old_version$new_version" ]; then
      printf '      %b%-8s%b %b%s%b %b->%b %b%s%b\n' \
        "$C_LABEL" "version" "$C_RESET" "$C_VERSION_BEFORE" "${old_version:-unknown}" "$C_RESET" \
        "$C_FRAME" "$C_RESET" "$C_VERSION_AFTER" "${new_version:-unknown}" "$C_RESET"
    fi
    [ -z "$urgency" ] || [ "$urgency" = "unknown" ] || printf '      %b%-8s%b %s\n' "$C_WARN" "urgency" "$C_RESET" "$urgency"
    [ -z "$summary" ] || printf '      %b%-8s%b %s\n' "$C_TIP" "means" "$C_RESET" "$summary"
  done <<< "$rows"

  printf '\n   %b%s%b review with %b%s%b when you can watch the machine and reboot if needed.\n\n' \
    "$C_TIP" "action:" "$C_RESET" "$C_CMD" "fwupdmgr get-updates" "$C_RESET"
}

npm_output_needs_claude_script_retry() {
  grep -Eiq 'allow-scripts.*@anthropic-ai/claude-code|@anthropic-ai/claude-code.*allowScripts|@anthropic-ai/claude-code.*postinstall' >/dev/null 2>&1
}

uv_output_has_stale_extra_warning() {
  grep -Eiq 'does not have an extra named' >/dev/null 2>&1
}

output_implies_update() {
  grep -Eiq '(^|[[:space:]])changed [1-9][0-9]* packages?|(^|[[:space:]])(added|removed|updated|upgraded) [1-9][0-9]* packages?|(^|[[:space:]])Upgraded [1-9][0-9]* outdated packages?' >/dev/null 2>&1
}

first_arrow_delta() {
  sed -nE 's/^[[:space:]]*([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+->[[:space:]]+([^[:space:]()]+).*/\1|\2|\3/p' | sed -n '1p'
}

uv_tool_delta() {
  awk '
    /^Modified .* environment/ { env=$0; sub(/^Modified /, "", env); sub(/ environment$/, "", env) }
    /^[[:space:]]*-[[:space:]]*[^=]+==/ && old == "" { old=$0; sub(/^[[:space:]]*-[[:space:]]*/, "", old) }
    /^[[:space:]]*\+[[:space:]]*[^=]+==/ && new == "" { new=$0; sub(/^[[:space:]]*\+[[:space:]]*/, "", new) }
    END {
      if (old != "" && new != "") {
        old_pkg=old; new_pkg=new; sub(/==.*/, "", old_pkg); sub(/==.*/, "", new_pkg)
        old_ver=old; new_ver=new; sub(/^[^=]+==/, "", old_ver); sub(/^[^=]+==/, "", new_ver)
        if (old_pkg == new_pkg) printf "%s|%s|%s|%s\n", old_pkg, old_ver, new_ver, env
      }
    }
  '
}

# --- Individual package delta extractors for Receipt Changelog Table ---
extract_apt_deltas() {
  local out="${1:-}" pkg old new
  [ -n "$out" ] || return 0
  while IFS='|' read -r pkg old new; do
    [ -n "$pkg" ] && record_pkg_delta "$pkg" "$old" "$new" "apt"
  done < <(printf '%s\n' "$out" | sed -nE 's/^Unpacking[[:space:]]+([^[:space:]:]+)(:[^[:space:]]+)?[[:space:]]+\(([^)]+)\)[[:space:]]+over[[:space:]]+\(([^)]+)\).*/\1|\4|\3/p')
}

extract_brew_deltas() {
  local out="${1:-}" pkg old new
  [ -n "$out" ] || return 0
  while IFS='|' read -r pkg old new; do
    [ -n "$pkg" ] && record_pkg_delta "$pkg" "$old" "$new" "brew"
  done < <(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*([A-Za-z0-9_.@\/-]+)[[:space:]]+([0-9][^[:space:]]*)[[:space:]]+->[[:space:]]+([0-9][^[:space:]()]*).*/\1|\2|\3/p')
}

extract_npm_deltas() {
  local out="${1:-}" pkg old new
  [ -n "$out" ] || return 0
  while IFS='|' read -r pkg old new; do
    [ -n "$pkg" ] && record_pkg_delta "$pkg" "$old" "$new" "npm"
  done < <(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*(@?[A-Za-z0-9_.-]+(\/[A-Za-z0-9_.-]+)?)[[:space:]]+([0-9][^[:space:]]*)[[:space:]]+->[[:space:]]+([0-9][^[:space:]()]*).*/\1|\3|\4/p')
}

extract_uv_deltas() {
  local out="${1:-}" pkg old new
  [ -n "$out" ] || return 0
  while IFS='|' read -r pkg old new; do
    [ -n "$pkg" ] && record_pkg_delta "$pkg" "$old" "$new" "uv"
  done < <(printf '%s\n' "$out" | awk '
    /^[[:space:]]*-[[:space:]]*[^=]+==/ {
      s=$0; sub(/^[[:space:]]*-[[:space:]]*/, "", s); p=s; v=s; sub(/==.*/, "", p); sub(/^[^=]+==/, "", v)
      old_pkg=p; old_ver=v
    }
    /^[[:space:]]*\+[[:space:]]*[^=]+==/ {
      s=$0; sub(/^[[:space:]]*\+[[:space:]]*/, "", s); p=s; v=s; sub(/==.*/, "", p); sub(/^[^=]+==/, "", v)
      if (p == old_pkg && old_ver != "" && v != old_ver) {
        printf "%s|%s|%s\n", p, old_ver, v; old_pkg=""; old_ver=""
      }
    }
  ')
}

extract_pipx_deltas() {
  local out="${1:-}" pkg old new
  [ -n "$out" ] || return 0
  while IFS='|' read -r pkg old new; do
    [ -n "$pkg" ] && record_pkg_delta "$pkg" "$old" "$new" "pipx"
  done < <(printf '%s\n' "$out" | sed -nE 's/.*upgraded package[[:space:]]+([^[:space:]]+)[[:space:]]+from[[:space:]]+([^[:space:]]+)[[:space:]]+to[[:space:]]+([^[:space:],!]+).*/\1|\2|\3/p')
}

extract_snap_deltas() {
  local out="${1:-}" pkg ver
  [ -n "$out" ] || return 0
  while IFS='|' read -r pkg ver; do
    [ -n "$pkg" ] && record_pkg_delta "$pkg" "prev" "$ver" "snap"
  done < <(printf '%s\n' "$out" | sed -nE 's/^([A-Za-z0-9._-]+)[[:space:]]+(\([^)]+\)[[:space:]]+)?([^[:space:]]+)[[:space:]]+from[[:space:]].*refreshed.*/\1|\3/p')
}

extract_flatpak_deltas() {
  local out="${1:-}" pkg ver
  [ -n "$out" ] || return 0
  while IFS='|' read -r pkg ver; do
    [ -n "$pkg" ] && record_pkg_delta "$pkg" "prev" "${ver:-updated}" "flatpak"
  done < <(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*Updating[[:space:]]+([A-Za-z0-9._-]+)\/?([^[:space:]]*).*/\1|\2/p')
}

extract_pacman_deltas() {
  local out="${1:-}" pkg old new
  [ -n "$out" ] || return 0
  while IFS='|' read -r pkg old new; do
    [ -n "$pkg" ] && record_pkg_delta "$pkg" "$old" "$new" "pacman"
  done < <(printf '%s\n' "$out" | sed -nE 's/.*upgrading[[:space:]]+([^[:space:]]+)[[:space:]]+\(([^[:space:]]+)[[:space:]]+->[[:space:]]+([^)]+)\).*/\1|\2|\3/p')
}

extract_dnf_deltas() {
  local out="${1:-}" pkg ver
  [ -n "$out" ] || return 0
  while IFS='|' read -r pkg ver; do
    [ -n "$pkg" ] && record_pkg_delta "$pkg" "prev" "$ver" "dnf"
  done < <(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*Upgrading[[:space:]]*:[[:space:]]*([A-Za-z0-9_.+-]+)-([0-9][^-]*-[^[:space:]]+).*/\1|\2/p')
}

extract_zypper_deltas() {
  local out="${1:-}" pkg ver
  [ -n "$out" ] || return 0
  while IFS='|' read -r pkg ver; do
    [ -n "$pkg" ] && record_pkg_delta "$pkg" "prev" "$ver" "zypper"
  done < <(printf '%s\n' "$out" | sed -nE 's/.*(Upgrading|Installing):[[:space:]]*([A-Za-z0-9_.+-]+)-([0-9][^-]*-[^[:space:]]+).*/\2|\3/p')
}

extract_apk_deltas() {
  local out="${1:-}" pkg old new
  [ -n "$out" ] || return 0
  while IFS='|' read -r pkg old new; do
    [ -n "$pkg" ] && record_pkg_delta "$pkg" "$old" "$new" "apk"
  done < <(printf '%s\n' "$out" | sed -nE 's/.*Upgrading[[:space:]]+([^[:space:]]+)[[:space:]]+\(([^[:space:]]+)[[:space:]]+->[[:space:]]+([^)]+)\).*/\1|\2|\3/p')
}

extract_xbps_deltas() {
  local out="${1:-}" pkg old new
  [ -n "$out" ] || return 0
  while IFS='|' read -r pkg old new; do
    [ -n "$pkg" ] && record_pkg_delta "$pkg" "$old" "$new" "xbps"
  done < <(printf '%s\n' "$out" | sed -nE 's/^([A-Za-z0-9_.+-]+)-([0-9][^:[:space:]]*):[[:space:]]+updating to[[:space:]]+([^[:space:]]+).*/\1|\2|\3/p')
}

# Non-interactive apt capture helper using runner.sh's sudo_cmd_capture.
_ua_sudo_apt_capture() {
  local __var="$1"
  shift
  if declare -F sudo_cmd_capture >/dev/null 2>&1; then
    sudo_cmd_capture "$__var" env \
      DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
      NEEDRESTART_MODE=l UCF_FORCE_CONFFOLD=1 APT_LISTCHANGES_FRONTEND=none PAGER=cat TERM=dumb \
      "$@"
    return $?
  fi
  sudo_noninteractive_apt "$@"
  local code=$?
  printf -v "$__var" '%s' ''
  return "$code"
}

# --- Phase helpers (keep run_updates readable and modular) ---
_ua_run_system_pkg_mgr() {
  local before="" after="" out="" code=0 pkgs="" delta_count_before=0 forced_status=""
  case "$_ua_sys_pkg_mgr" in
    apt-get)
      _ua_step_begin "dpkg" "dpkg audit"
      section "dpkg audit"
      tool_card "dpkg" "dpkg audit"
      if [ "$UPDATE_ALL_DRY_RUN" = 1 ]; then
        show_cmd sudo dpkg --audit
        track "dpkg audit" 0 "" "" "dry-run: dpkg state not changed"
      else
        local dpkg_audit="" dpkg_code=0
        _ua_sudo_apt_capture dpkg_audit dpkg --audit
        dpkg_code=$?
        if [ "$dpkg_code" -ne 0 ]; then
          track "dpkg audit" "$dpkg_code" "" "" "could not inspect dpkg state"
        elif [ -n "$dpkg_audit" ]; then
          track "dpkg audit" 0 "" "" "pending package configuration detected"
          section "dpkg configure"
          sudo_noninteractive_apt dpkg --configure -a --force-confdef --force-confold
          track "dpkg configure" $?
        else
          track "dpkg audit" 0 "" "" "dpkg state clean"
        fi
      fi
      _ua_step_end "dpkg"

      _ua_step_begin "apt-update" "apt update"
      section "apt update"
      tool_card "apt" "apt package index"
      sudo_noninteractive_apt apt-get \
        -o Dpkg::Use-Pty=0 -o APT::Color=0 -o APT::Progress-Fancy=0 -o Dpkg::Progress-Fancy=0 \
        update -y \
        -o DPkg::Lock::Timeout=60 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=3
      track "apt update" $?
      _ua_step_end "apt-update"

      _ua_step_begin "apt-upgrade" "apt upgrade"
      before="$(version_of apt-upgradable 2>/dev/null || true)"
      section "apt upgrade"
      tool_card "apt" "apt package upgrade" "$before"
      show_pending_apt_updates
      _ua_sudo_apt_capture out apt-get \
        -o Dpkg::Use-Pty=0 -o APT::Color=0 -o APT::Progress-Fancy=0 -o Dpkg::Progress-Fancy=0 \
        -o DPkg::Lock::Timeout=60 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=3 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y
      code=$?
      extract_apt_deltas "$out"
      after="$(version_of apt-upgradable 2>/dev/null || true)"
      track "apt upgrade" "$code" "$before" "$after"
      case "$after" in
        ""|"0 upgradable") ;;
        *) add_concern "System packages still pending" "apt still reports $after after the upgrade. Ubuntu may defer phased updates or hold packages for safety." "Usually this is not urgent. Run update-all later, or inspect with apt list --upgradable if you want to learn what remains." ;;
      esac
      if [ -f /var/run/reboot-required ]; then
        pkgs=""
        [ -r /var/run/reboot-required.pkgs ] && pkgs="$(tr '\n' ' ' < /var/run/reboot-required.pkgs | sed 's/[[:space:]]*$//')"
        add_concern "Reboot required" "The system created /var/run/reboot-required${pkgs:+ (packages: $pkgs)}." "Reboot when convenient so kernel and core library updates take effect."
      fi
      if printf '%s\n' "$out" | grep -Eiq 'Pending kernel upgrade|Services to be restarted|Daemons using outdated libraries'; then
        add_concern "Services or kernel need restart" "needrestart reported outdated libraries or a pending kernel during apt upgrade." "Inspect with sudo needrestart -r l or reboot when convenient."
      fi
      _ua_step_end "apt-upgrade"
      ;;
    rpm-ostree)
      _ua_step_begin "rpm-ostree" "rpm-ostree upgrade"
      before="$(version_of rpm-ostree 2>/dev/null || true)"
      section "rpm-ostree upgrade"
      tool_card "rpm-ostree" "Immutable OS image" "$before" "rpm-ostree"
      if [ "$UPDATE_ALL_DRY_RUN" = 1 ]; then
        show_cmd rpm-ostree upgrade --check
        track "rpm-ostree upgrade" 0 "$before" "$before" "dry-run: rpm-ostree image not changed"
      else
        run_cmd_capture out rpm-ostree upgrade
        code=$?
        after="$(version_of rpm-ostree 2>/dev/null || true)"
        track "rpm-ostree upgrade" "$code" "$before" "$after" "immutable Fedora/Bazzite OS deployment"
        if printf '%s\n' "$out" | grep -Eiq 'Run "systemctl reboot"|Queued.*upgrade'; then
          add_concern "Reboot required" "rpm-ostree staged a new OS deployment." "Reboot when convenient to boot into the updated image."
        fi
      fi
      _ua_step_end "rpm-ostree"
      ;;
    dnf5|dnf|yum)
      _ua_step_begin "dnf-upgrade" "$_ua_sys_pkg_mgr upgrade"
      before="$(version_of dnf 2>/dev/null || true)"
      section "$_ua_sys_pkg_mgr upgrade"
      tool_card "dnf" "$_ua_sys_pkg_mgr OS packages" "$before" "$_ua_sys_pkg_mgr"
      delta_count_before="${#_ua_delta_pkgs[@]}"
      forced_status=""
      sudo_cmd_capture out "$_ua_sys_pkg_mgr" upgrade -y
      code=$?
      extract_dnf_deltas "$out"
      [ "${#_ua_delta_pkgs[@]}" -gt "$delta_count_before" ] && forced_status="UPDATED"
      after="$(version_of dnf 2>/dev/null || true)"
      track "$_ua_sys_pkg_mgr upgrade" "$code" "$before" "$after" "" "$forced_status"
      _ua_step_end "dnf-upgrade"
      ;;
    pacman)
      _ua_step_begin "pacman-upgrade" "pacman -Syu"
      before="$(version_of pacman 2>/dev/null || true)"
      section "pacman upgrade"
      tool_card "pacman" "Arch OS packages" "$before" "pacman"
      delta_count_before="${#_ua_delta_pkgs[@]}"
      forced_status=""
      sudo_cmd_capture out pacman -Syu --noconfirm
      code=$?
      extract_pacman_deltas "$out"
      [ "${#_ua_delta_pkgs[@]}" -gt "$delta_count_before" ] && forced_status="UPDATED"
      after="$(version_of pacman 2>/dev/null || true)"
      track "pacman -Syu" "$code" "$before" "$after" "official Arch repos only; AUR stays manual" "$forced_status"
      _ua_step_end "pacman-upgrade"
      ;;
    zypper)
      _ua_step_begin "zypper-upgrade" "zypper upgrade"
      before="$(version_of zypper 2>/dev/null || true)"
      section "zypper upgrade"
      tool_card "zypper" "openSUSE OS packages" "$before" "zypper"
      local zyp_sub="up"
      case "$_ua_distro_id $_ua_distro_name" in *tumbleweed*|*Tumbleweed*) zyp_sub="dup" ;; esac
      delta_count_before="${#_ua_delta_pkgs[@]}"
      forced_status=""
      sudo_cmd_capture out zypper --non-interactive "$zyp_sub"
      code=$?
      extract_zypper_deltas "$out"
      [ "${#_ua_delta_pkgs[@]}" -gt "$delta_count_before" ] && forced_status="UPDATED"
      after="$(version_of zypper 2>/dev/null || true)"
      track "zypper $zyp_sub" "$code" "$before" "$after" "" "$forced_status"
      _ua_step_end "zypper-upgrade"
      ;;
    apk)
      _ua_step_begin "apk-upgrade" "apk upgrade"
      before="$(version_of apk 2>/dev/null || true)"
      section "apk upgrade"
      tool_card "apk" "Alpine OS packages" "$before" "apk"
      delta_count_before="${#_ua_delta_pkgs[@]}"
      forced_status=""
      sudo_cmd apk update
      code=$?
      if [ "$code" -eq 0 ]; then
        sudo_cmd_capture out apk upgrade
        code=$?
        extract_apk_deltas "$out"
        [ "${#_ua_delta_pkgs[@]}" -gt "$delta_count_before" ] && forced_status="UPDATED"
      fi
      after="$(version_of apk 2>/dev/null || true)"
      track "apk upgrade" "$code" "$before" "$after" "" "$forced_status"
      _ua_step_end "apk-upgrade"
      ;;
    xbps-install)
      _ua_step_begin "xbps-upgrade" "xbps-install -Suy"
      before="$(version_of xbps 2>/dev/null || true)"
      section "xbps upgrade"
      tool_card "xbps" "Void OS packages" "$before" "xbps-install"
      delta_count_before="${#_ua_delta_pkgs[@]}"
      forced_status=""
      sudo_cmd_capture out xbps-install -Suy
      code=$?
      extract_xbps_deltas "$out"
      [ "${#_ua_delta_pkgs[@]}" -gt "$delta_count_before" ] && forced_status="UPDATED"
      after="$(version_of xbps 2>/dev/null || true)"
      track "xbps-install -Suy" "$code" "$before" "$after" "" "$forced_status"
      _ua_step_end "xbps-upgrade"
      ;;
    *)
      skip_tool "apt" "OS package manager" "OS package manager" "no supported Linux system package manager detected ($_ua_distro_name)" "system"
      ;;
  esac
}

_ua_run_editor_step() {
  local bin="$1" key="$2" title="$3" label="$4" before="" after="" code=0
  _ua_step_begin "$key" "$label"
  before="$(version_of "$bin" 2>/dev/null || true)"
  section "$label"
  tool_card "code" "$title" "$before" "$bin --update-extensions"
  if [ "$UPDATE_ALL_DRY_RUN" = 1 ]; then
    show_cmd "$bin" --update-extensions
    after="$(version_of "$bin" 2>/dev/null || true)"
    track "$label" 0 "$before" "$after" "updates installed $title only"
  elif [ "$_ua_is_headless" = 1 ] && [ "${UPDATE_ALL_HEADLESS_EDITORS:-0}" != 1 ]; then
    skip_step "$label" "headless session (no DISPLAY/WAYLAND_DISPLAY); set UPDATE_ALL_HEADLESS_EDITORS=1 to run"
  else
    run_bounded "$UPDATE_ALL_EDITOR_TIMEOUT" "$bin" --update-extensions
    code=$?
    after="$(version_of "$bin" 2>/dev/null || true)"
    track "$label" "$code" "$before" "$after" "updates installed $title only"
  fi
  _ua_step_end "$key"
}

run_updates() {
  local before="" after="" code=0 out="" owner="" delta_count_before=0 forced_status=""
  [ "${_ua_env_discovered:-0}" = 1 ] || discover_environment
  show_update_coverage_preflight

  # ===== SYSTEM =====
  _ua_phase "SYSTEM"
  _ua_run_system_pkg_mgr

  if [ "$_ua_has_snap" = 1 ]; then
    _ua_step_begin "snap" "snap refresh"
    before="$(version_of snap 2>/dev/null || true)"
    section "snap refresh"
    tool_card "snap" "snap packages" "$before"
    delta_count_before="${#_ua_delta_pkgs[@]}"
    forced_status=""
    if [ "$UPDATE_ALL_DRY_RUN" = 1 ]; then
      show_cmd sudo snap refresh
      code=0; out=""
    else
      UPDATE_ALL_STEP_TIMEOUT="$UPDATE_ALL_SNAP_TIMEOUT" sudo_cmd_capture out snap refresh
      code=$?
    fi
    extract_snap_deltas "$out"
    [ "${#_ua_delta_pkgs[@]}" -gt "$delta_count_before" ] && forced_status="UPDATED"
    after="$(version_of snap 2>/dev/null || true)"
    track "snap refresh" "$code" "$before" "$after" "" "$forced_status"
    _ua_step_end "snap"
  else
    skip_tool "snap" "snap packages" "snap refresh" "snap command not installed" "snap"
  fi

  if [ "$_ua_has_flatpak" = 1 ]; then
    _ua_step_begin "flatpak" "flatpak update"
    before="$(version_of flatpak 2>/dev/null || true)"
    section "flatpak update"
    tool_card "flatpak" "flatpak apps" "$before"
    delta_count_before="${#_ua_delta_pkgs[@]}"
    forced_status=""
    UPDATE_ALL_STEP_TIMEOUT="$UPDATE_ALL_FLATPAK_TIMEOUT" run_cmd_capture out flatpak update -y --noninteractive
    code=$?
    extract_flatpak_deltas "$out"
    [ "${#_ua_delta_pkgs[@]}" -gt "$delta_count_before" ] && forced_status="UPDATED"
    after="$(version_of flatpak 2>/dev/null || true)"
    track "flatpak update" "$code" "$before" "$after" "" "$forced_status"
    _ua_step_end "flatpak"
  else
    skip_tool "flatpak" "flatpak apps" "flatpak update" "flatpak command not installed" "flatpak"
  fi

  if [ "$_ua_has_fwupd" = 1 ]; then
    _ua_step_begin "fwupd" "firmware updates"
    before="$(version_of fwupd 2>/dev/null || true)"
    section "firmware updates"
    tool_card "fwupd" "Linux firmware updates" "$before" "fwupdmgr update"
    if [ "$UPDATE_ALL_DRY_RUN" = 1 ]; then
      show_cmd fwupdmgr refresh --force
      show_cmd fwupdmgr get-updates
      show_cmd sudo fwupdmgr update -y --no-reboot-check
      after="$(version_of fwupd 2>/dev/null || true)"
      track "firmware updates" 0 "$before" "$after" "dry-run: firmware update is prompt-gated in a live run"
    elif choice_is_yes "$_ua_firmware_choice"; then
      local fw_updates_output="" fw_update_output="" fw_refresh=0 fw_updates=0 fw_update=0
      run_cmd fwupdmgr refresh --force
      fw_refresh=$?
      if declare -F ua_exec_watched >/dev/null 2>&1; then
        ua_exec_watched --capture fw_updates_output --quiet --timeout "${UPDATE_ALL_STEP_TIMEOUT:-600s}" -- fwupdmgr get-updates
      else
        run_cmd_capture fw_updates_output fwupdmgr get-updates
      fi
      fw_updates=$?
      print_firmware_summary "$fw_updates_output"
      after="$(version_of fwupd 2>/dev/null || true)"
      if [ "$fw_refresh" -ne 0 ] && [ "$fw_refresh" -ne 2 ]; then
        track "firmware updates" 1 "$before" "$after" "fwupd metadata refresh failed with exit=$fw_refresh"
      elif [ "$fw_updates" -eq 2 ]; then
        track "firmware updates" "UNCHANGED" "$before" "$after" "No firmware updates available"
      elif [ "$fw_updates" -ne 0 ] && ! printf '%s\n' "$fw_updates_output" | fwupd_needs_manual_attention; then
        track "firmware updates" 1 "$before" "$after" "fwupd get-updates failed with exit=$fw_updates"
      elif ! printf '%s\n' "$fw_updates_output" | fwupd_has_installable_updates; then
        track "firmware updates" "UNCHANGED" "$before" "$after" "No firmware updates available"
      elif printf '%s\n' "$fw_updates_output" | fwupd_needs_manual_attention; then
        track "firmware updates" 0 "$before" "$after" "fwupd reports UEFI/Secure Boot firmware needing manual attention; not auto-applied"
        add_concern "Firmware needs manual attention" "fwupd has UEFI/Secure Boot firmware updates, and at least one previous attempt is marked failed by fwupd. This is hardware/firmware state, not a broken package update." "Review with fwupdmgr get-updates when you are ready to watch it. Expect possible firmware setup, Secure Boot, efivars, or reboot work outside update-all."
      else
        sudo_cmd_capture fw_update_output fwupdmgr update -y --no-reboot-check
        fw_update=$?
        after="$(version_of fwupd 2>/dev/null || true)"
        if [ "$fw_update" -eq 0 ] || [ "$fw_update" -eq 2 ]; then
          track "firmware updates" 0 "$before" "$after" "fwupd completed; follow any reboot guidance it printed"
        elif printf '%s\n' "$fw_update_output" | fwupd_needs_manual_attention; then
          track "firmware updates" 0 "$before" "$after" "fwupd returned manual UEFI/Secure Boot attention; not counted as a workstation update failure"
          add_concern "Firmware needs manual attention" "fwupd could not apply a UEFI/Secure Boot firmware update automatically. This usually needs a watched firmware flow, reboot, or machine-specific setup." "Review the fwupd output above, then handle firmware manually outside an unattended update-all run."
        else
          track "firmware updates" 1 "$before" "$after" "refresh exit=$fw_refresh, get-updates exit=$fw_updates, update exit=$fw_update"
        fi
      fi
    else
      skip_step "firmware updates" "skipped by upfront choice; firmware was not changed"
      add_concern "Firmware skipped" "Firmware updates can require hardware trust prompts or a reboot, so they were skipped by the upfront choice." "Run update-all again with --firmware or answer yes when ready to watch and reboot if needed."
    fi
    _ua_step_end "fwupd"
  else
    skip_tool "fwupd" "Linux firmware updates" "firmware updates" "fwupdmgr command not installed" "fwupdmgr update"
  fi

  # ===== NODE / JS =====
  _ua_phase "NODE"
  if [ "$_ua_has_update_node" = 1 ]; then
    _ua_step_begin "node" "node runtime"
    before="$(version_of node 2>/dev/null || true)"
    section "node runtime"
    tool_card "node" "Node.js runtime" "$before" "node"
    run_bounded "$UPDATE_ALL_NODE_TIMEOUT" update-node
    code=$?
    after="$(version_of node 2>/dev/null || true)"
    track "node runtime" "$code" "$before" "$after" "bounded by UPDATE_ALL_NODE_TIMEOUT (default 300s); update-node keeps Node inside the current major line"
    _ua_step_end "node"
  else
    skip_tool "node" "Node.js runtime" "node runtime" "update-node command not installed" "node"
  fi

  if [ "$_ua_has_mise" = 1 ]; then
    _ua_step_begin "mise" "mise upgrade"
    before="$(version_of mise 2>/dev/null || true)"
    section "mise upgrade"
    tool_card "mise" "mise version manager" "$before" "mise"
    run_cmd mise upgrade
    code=$?
    after="$(version_of mise 2>/dev/null || true)"
    track "mise upgrade" "$code" "$before" "$after" "updates mise-managed runtimes and shims"
    _ua_step_end "mise"
  fi

  if [ "$_ua_has_volta" = 1 ]; then
    _ua_step_begin "volta" "volta toolchain"
    before="$(version_of volta 2>/dev/null || true)"
    section "volta toolchain"
    tool_card "volta" "Volta Node manager" "$before" "volta"
    track "volta toolchain" "OK" "$before" "$before" "Volta pins Node versions per project; run volta install node@lts manually to bump default"
    _ua_step_end "volta"
  fi

  if [ "$_ua_has_fnm" = 1 ]; then
    _ua_step_begin "fnm" "fnm Node manager"
    before="$(version_of fnm 2>/dev/null || true)"
    section "fnm Node manager"
    tool_card "fnm" "FNM NODE MANAGER" "$before" "fnm"
    local fnm_list=""
    if [ "$UPDATE_ALL_DRY_RUN" != 1 ]; then
      fnm_list="$(_ua_probe_bounded fnm list 2>/dev/null | awk '{sub(/^[[:space:]]*/, ""); sub(/^\*[[:space:]]*/, ""); if (length($0) > 0) { if (out != "") out = out ", "; out = out $0 }} END { print out }' || true)"
      if [ -n "$fnm_list" ]; then
        printf '   %b%-15s%b %s\n' "$C_LABEL" "installed" "$C_RESET" "$fnm_list"
      fi
    fi
    track "fnm" "OK" "$before" "$before" "fnm manages project-pinned Node versions; run fnm install --lts manually to add a runtime without surprise switching"
    _ua_step_end "fnm"
  fi

  if [ "$_ua_has_corepack" = 1 ]; then
    _ua_step_begin "corepack" "corepack enable"
    before="$(version_of corepack 2>/dev/null || true)"
    section "corepack enable"
    tool_card "corepack" "Corepack shims" "$before" "corepack"
    local cp_dir=""
    cp_dir="$(dirname "$(command -v corepack 2>/dev/null || printf '/nonexistent')")"
    if [ "$UPDATE_ALL_DRY_RUN" != 1 ] && ! is_path_writable "$cp_dir"; then
      skip_step "corepack enable" "corepack bin directory ($cp_dir) is not user-writable; skipped without sudo"
    else
      run_bounded "$UPDATE_ALL_COREPACK_TIMEOUT" env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack enable
      code=$?
      hash -r 2>/dev/null || true
      after="$(version_of corepack 2>/dev/null || true)"
      track "corepack enable" "$code" "$before" "$after" "bounded by UPDATE_ALL_COREPACK_TIMEOUT (default 90s)"
    fi
    _ua_step_end "corepack"

    if [ "$_ua_has_pnpm" = 1 ]; then
      _ua_step_begin "pnpm" "pnpm self-update"
      before="$(version_of pnpm 2>/dev/null || true)"
      section "pnpm self-update"
      tool_card "pnpm" "pnpm package manager" "$before" "pnpm@latest"
      run_bounded "$UPDATE_ALL_COREPACK_TIMEOUT" env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack prepare pnpm@latest --activate
      code=$?
      after="$(version_of pnpm 2>/dev/null || true)"
      track "pnpm (corepack)" "$code" "$before" "$after" "bounded by UPDATE_ALL_COREPACK_TIMEOUT (default 90s)"
      _ua_step_end "pnpm"
    else
      skip_tool "pnpm" "pnpm package manager" "pnpm self-update" "pnpm is not activated/installed" "pnpm@latest"
    fi

    if [ "$_ua_has_yarn" = 1 ]; then
      _ua_step_begin "yarn" "yarn self-update"
      before="$(version_of yarn 2>/dev/null || true)"
      section "yarn self-update"
      tool_card "yarn" "Yarn package manager" "$before" "yarn@stable"
      run_bounded "$UPDATE_ALL_COREPACK_TIMEOUT" env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack prepare yarn@stable --activate
      code=$?
      after="$(version_of yarn 2>/dev/null || true)"
      track "yarn (corepack)" "$code" "$before" "$after" "bounded by UPDATE_ALL_COREPACK_TIMEOUT (default 90s)"
      _ua_step_end "yarn"
    else
      skip_tool "yarn" "Yarn package manager" "yarn self-update" "yarn is not activated/installed" "yarn@stable"
    fi
  else
    skip_tool "corepack" "Corepack shims" "corepack enable" "corepack command not installed" "corepack"
    if [ "$_ua_has_pnpm" = 1 ]; then
      _ua_step_begin "pnpm" "pnpm self-update"
      before="$(version_of pnpm 2>/dev/null || true)"
      section "pnpm self-update"
      tool_card "pnpm" "pnpm package manager" "$before" "pnpm"
      owner="$(tool_install_owner pnpm 2>/dev/null || printf 'unknown')"
      if [ "$owner" = "user" ] || [ "$UPDATE_ALL_DRY_RUN" = 1 ]; then
        run_cmd pnpm self-update
        code=$?
        after="$(version_of pnpm 2>/dev/null || true)"
        track "pnpm self-update" "$code" "$before" "$after" "standalone pnpm updater"
      else
        skip_step "pnpm self-update" "pnpm is managed by $owner; updated through its owning manager"
      fi
      _ua_step_end "pnpm"
    else
      skip_tool "pnpm" "pnpm package manager" "pnpm self-update" "pnpm command not installed" "pnpm@latest"
    fi
    if [ "$_ua_has_yarn" = 1 ]; then
      _ua_step_begin "yarn" "yarn self-update"
      before="$(version_of yarn 2>/dev/null || true)"
      section "yarn self-update"
      tool_card "yarn" "Yarn package manager" "$before" "yarn"
      track "yarn" "OK" "$before" "$before" "standalone yarn detected (without corepack); managed by its installer"
      _ua_step_end "yarn"
    else
      skip_tool "yarn" "Yarn package manager" "yarn self-update" "yarn command not installed" "yarn@stable"
    fi
  fi

  if [ "$_ua_has_bun" = 1 ]; then
    _ua_step_begin "bun" "bun upgrade"
    before="$(version_of bun 2>/dev/null || true)"
    section "bun upgrade"
    tool_card "bun" "Bun runtime" "$before" "bun upgrade"
    owner="$(tool_install_owner bun 2>/dev/null || printf 'user')"
    if [ "$owner" = "brew" ] && [ "$_ua_has_brew" = 1 ] && [ "$UPDATE_ALL_DRY_RUN" != 1 ]; then
      track "bun upgrade" "OK" "$before" "$before" "bun is managed by Homebrew; upgraded during brew step"
    else
      run_cmd bun upgrade
      code=$?
      after="$(version_of bun 2>/dev/null || true)"
      track "bun upgrade" "$code" "$before" "$after" "uses Bun's first-party updater"
    fi
    _ua_step_end "bun"
  else
    skip_tool "bun" "Bun runtime" "bun upgrade" "bun command not installed" "bun upgrade"
  fi

  if [ "$_ua_has_deno" = 1 ]; then
    _ua_step_begin "deno" "deno upgrade"
    before="$(version_of deno 2>/dev/null || true)"
    section "deno upgrade"
    tool_card "deno" "Deno runtime" "$before" "deno upgrade"
    owner="$(tool_install_owner deno 2>/dev/null || printf 'user')"
    if [ "$owner" = "brew" ] && [ "$_ua_has_brew" = 1 ] && [ "$UPDATE_ALL_DRY_RUN" != 1 ]; then
      track "deno upgrade" "OK" "$before" "$before" "deno is managed by Homebrew; upgraded during brew step"
    else
      run_cmd deno upgrade
      code=$?
      after="$(version_of deno 2>/dev/null || true)"
      track "deno upgrade" "$code" "$before" "$after" "uses Deno's first-party updater"
    fi
    _ua_step_end "deno"
  fi

  # ===== NPM & AI CLIS =====
  _ua_phase "NPM"
  if [ "$_ua_has_npm" = 1 ]; then
    local npm_prefix="" npm_writable=1
    npm_prefix="$(_ua_probe_bounded npm prefix -g | sed -n '1p' || true)"
    if [ "$UPDATE_ALL_DRY_RUN" != 1 ] && [ -n "$npm_prefix" ] && ! is_path_writable "$npm_prefix"; then
      npm_writable=0
    fi

    _ua_step_begin "npm-self" "npm self-update"
    before="$(version_of npm-active 2>/dev/null || true)"
    section "npm self-update"
    tool_card "npm" "npm self-update" "$before" "npm@latest"
    if [ "$npm_writable" = 0 ]; then
      skip_step "npm self-update" "npm prefix ($npm_prefix) is root/distro-owned; skipped without sudo"
    else
      local npm_self_output="" npm_self_code=0
      run_cmd_capture npm_self_output npm install -g npm@latest --no-fund
      npm_self_code=$?
      after="$(version_of npm-active 2>/dev/null || true)"
      if printf '%s\n' "$npm_self_output" | output_implies_update; then
        track "npm self-update" "$npm_self_code" "$before" "$after" "active npm is PATH-selected; bundled npm is shown separately in RECEIPT" "UPDATED"
      else
        track "npm self-update" "$npm_self_code" "$before" "$after" "active npm is PATH-selected; bundled npm is shown separately in RECEIPT"
      fi
    fi
    _ua_step_end "npm-self"

    _ua_step_begin "npm-globals" "npm globals"
    section "npm globals"
    tool_card "npm-globals" "npm global packages"
    if [ "$npm_writable" = 0 ]; then
      skip_step "npm globals" "npm prefix ($npm_prefix) is root/distro-owned; skipped without sudo"
    else
      show_pending_npm_globals
      local npm_globals_output="" npm_globals_code=0 npm_claude_code=0
      run_cmd_capture npm_globals_output npm update -g --no-fund
      npm_globals_code=$?
      extract_npm_deltas "$npm_globals_output"
      if printf '%s\n' "$npm_globals_output" | npm_output_needs_claude_script_retry; then
        printf '   %b%s%b npm blocked Claude Code postinstall during the global sweep; retrying that trusted package with scripts enabled for this command.\n' "$C_LABEL" "note" "$C_RESET"
        run_cmd npm install -g --ignore-scripts=false @anthropic-ai/claude-code@latest --no-fund
        npm_claude_code=$?
        if [ "$npm_globals_code" -eq 0 ] && [ "$npm_claude_code" -eq 0 ]; then
          track "npm globals" 0 "" "" "global packages updated; Claude Code postinstall warning auto-resolved"
        else
          track "npm globals" 1 "" "" "npm update exit=$npm_globals_code, Claude Code script retry exit=$npm_claude_code"
        fi
      else
        track "npm globals" "$npm_globals_code"
      fi
    fi
    _ua_step_end "npm-globals"
  else
    skip_tool "npm" "npm self-update" "npm self-update" "npm command not installed" "npm@latest"
    skip_tool "npm-globals" "npm global packages" "npm globals" "npm command not installed" "npm"
  fi

  # Claude Code & Codex CLI are DECOUPLED from npm (works for native, brew, and npm installs)
  if [ "$_ua_has_claude" = 1 ]; then
    _ua_step_begin "claude" "claude code"
    before="$(version_of claude 2>/dev/null || true)"
    section "claude code"
    tool_card "claude" "Claude Code CLI" "$before" "claude update"
    run_cmd claude update
    code=$?
    after="$(version_of claude 2>/dev/null || true)"
    track "claude code" "$code" "$before" "$after" "uses Claude Code's first-party updater"
    _ua_step_end "claude"
  else
    skip_tool "claude" "Claude Code CLI" "claude code" "claude command not installed" "claude update"
  fi

  if [ "$_ua_has_codex" = 1 ]; then
    _ua_step_begin "codex" "codex"
    before="$(version_of codex 2>/dev/null || true)"
    section "codex"
    tool_card "codex" "OpenAI Codex CLI" "$before" "codex update"
    owner="$(tool_install_owner codex 2>/dev/null || printf 'user')"
    if [ "$UPDATE_ALL_DRY_RUN" = 1 ]; then
      show_cmd codex update
      after="$(version_of codex 2>/dev/null || true)"
      track "codex" 0 "$before" "$after" "uses Codex CLI's first-party updater"
    elif [ "$owner" = "brew" ] && [ "$_ua_has_brew" = 1 ]; then
      track "codex" "OK" "$before" "$before" "codex is managed by Homebrew; upgraded during brew step"
    else
      local codex_help="" codex_output="" codex_code=0
      codex_help="$(_ua_probe_bounded codex --help 2>&1 || true)"
      if printf '%s\n' "$codex_help" | grep -Eq '(^|[[:space:]])update([[:space:]]|$)'; then
        run_cmd_capture codex_output codex update
        codex_code=$?
        after="$(version_of codex 2>/dev/null || true)"
        if printf '%s\n' "$codex_output" | output_implies_update; then
          track "codex" "$codex_code" "$before" "$after" "uses Codex CLI's first-party updater" "UPDATED"
        else
          track "codex" "$codex_code" "$before" "$after" "uses Codex CLI's first-party updater"
        fi
      else
        skip_step "codex" "installed codex CLI has no update subcommand; upgrade via its package manager"
      fi
    fi
    _ua_step_end "codex"
  else
    skip_tool "codex" "OpenAI Codex CLI" "codex" "codex command not installed" "codex update"
  fi

  skip_tool "hermes" "Hermes Agent" "Hermes Agent" "intentionally not updated here; avoids breaking active agent workflows" "hermes-agent"

  # ===== TOOLS =====
  _ua_phase "TOOLS"
  if [ "$_ua_has_brew" = 1 ]; then
    _ua_step_begin "brew-upgrade" "brew update + upgrade"
    before="$(version_of brew 2>/dev/null || true)"
    section "brew update + upgrade"
    tool_card "brew" "Homebrew formulae" "$before"
    if declare -F show_brew_tap_trust_preflight >/dev/null 2>&1; then
      show_brew_tap_trust_preflight || true
    fi
    show_pending_brew_updates
    local brew_output="" brew_code=0
    run_shell_capture brew_output 'HOMEBREW_NO_ENV_HINTS=1 brew update && HOMEBREW_NO_ENV_HINTS=1 brew upgrade'
    brew_code=$?
    extract_brew_deltas "$brew_output"
    after="$(version_of brew 2>/dev/null || true)"
    if printf '%s\n' "$brew_output" | output_implies_update; then
      local brew_delta="" brew_name="" brew_old="" brew_new=""
      brew_delta="$(printf '%s\n' "$brew_output" | first_arrow_delta)"
      if [ -n "$brew_delta" ]; then
        IFS='|' read -r brew_name brew_old brew_new <<< "$brew_delta"
        track "brew formula: $brew_name" "$brew_code" "$brew_name $brew_old" "$brew_new" "Homebrew upgraded this formula; Homebrew itself is $(receipt_version "$after")" "UPDATED"
      else
        track "brew upgrade" "$brew_code" "$before" "$after" "Homebrew upgraded one or more formulae; see the Homebrew lines above for package names" "UPDATED"
      fi
    else
      track "brew upgrade" "$brew_code" "$before" "$after" "Homebrew updates itself and brew-managed formulae"
    fi
    _ua_step_end "brew-upgrade"
  else
    skip_tool "brew" "Homebrew formulae" "brew upgrade" "brew command not installed" "brew"
  fi

  if [ "$_ua_has_uv" = 1 ]; then
    _ua_step_begin "uv" "uv self update"
    before="$(version_of uv 2>/dev/null || true)"
    owner="$(tool_install_owner uv 2>/dev/null || printf 'user')"
    if [ "$owner" = "brew" ] && [ "$_ua_has_brew" = 1 ]; then
      section "uv upgrade (brew)"
      tool_card "uv" "uv Python toolchain" "$before" "uv"
      track "uv upgrade (brew)" "UNCHANGED" "$before" "$before" "uv is managed by Homebrew and was already covered by brew upgrade"
    elif [ "$owner" = "user" ] || [ "$UPDATE_ALL_DRY_RUN" = 1 ]; then
      section "uv self update"
      tool_card "uv" "uv Python toolchain" "$before" "uv"
      run_cmd uv self update
      code=$?
      after="$(version_of uv 2>/dev/null || true)"
      track "uv self update" "$code" "$before" "$after"
    else
      section "uv self update"
      tool_card "uv" "uv Python toolchain" "$before" "uv"
      skip_step "uv self update" "uv is managed by $owner; skipped standalone uv self update"
    fi
    _ua_step_end "uv"

    _ua_step_begin "uv-tools" "uv tool upgrade"
    section "uv tool upgrade"
    tool_card "uv" "uv-installed tools"
    local uv_tool_output="" uv_tool_code=0 uv_delta="" uv_pkg="" uv_old="" uv_new="" uv_env="" uv_note="" uv_forced=""
    run_cmd_capture uv_tool_output uv tool upgrade --all
    uv_tool_code=$?
    extract_uv_deltas "$uv_tool_output"
    uv_delta="$(printf '%s\n' "$uv_tool_output" | uv_tool_delta)"
    if [ -n "$uv_delta" ]; then
      IFS='|' read -r uv_pkg uv_old uv_new uv_env <<< "$uv_delta"
      uv_note="uv updated ${uv_env:-an installed tool} environment"
      uv_forced="UPDATED"
    fi
    if [ "$uv_tool_code" -eq 0 ] && printf '%s\n' "$uv_tool_output" | uv_output_has_stale_extra_warning; then
      uv_note="${uv_note:+$uv_note; }one installed tool reports stale optional-extra metadata"
      add_concern "uv tool metadata warning" "uv reported that an installed Python tool references an optional extra that no longer exists, but the tool-upgrade command still completed." "This is not an update-all failure. If it keeps appearing, reinstall or replace the specific uv tool that prints the warning."
    fi
    if [ -n "$uv_forced" ]; then
      track "uv tool: $uv_pkg" "$uv_tool_code" "$uv_pkg $uv_old" "$uv_new" "$uv_note" "$uv_forced"
    elif [ "$uv_tool_code" -eq 0 ] && [ -n "$uv_note" ]; then
      track "uv tool upgrade" 0 "" "" "$uv_note"
    else
      track "uv tool upgrade" "$uv_tool_code"
    fi
    _ua_step_end "uv-tools"
  else
    skip_tool "uv" "uv Python toolchain" "uv self update" "uv command not installed" "uv"
    skip_tool "uv" "uv-installed tools" "uv tool upgrade" "uv command not installed" "uv tool upgrade --all"
  fi

  if [ "$_ua_has_pipx" = 1 ]; then
    _ua_step_begin "pipx" "pipx upgrade-all"
    before="$(version_of pipx 2>/dev/null || true)"
    section "pipx upgrade-all"
    tool_card "pipx" "pipx Python CLIs" "$before"
    delta_count_before="${#_ua_delta_pkgs[@]}"
    forced_status=""
    run_cmd_capture out env PIP_NO_INPUT=1 pipx upgrade-all
    code=$?
    extract_pipx_deltas "$out"
    [ "${#_ua_delta_pkgs[@]}" -gt "$delta_count_before" ] && forced_status="UPDATED"
    after="$(version_of pipx 2>/dev/null || true)"
    track "pipx upgrade-all" "$code" "$before" "$after" "" "$forced_status"
    _ua_step_end "pipx"
  else
    skip_tool "pipx" "pipx Python CLIs" "pipx upgrade-all" "pipx command not installed" "pipx"
  fi

  if [ "$_ua_has_rustup" = 1 ]; then
    _ua_step_begin "rustup" "rustup update"
    local cargo_before="" cargo_after=""
    before="$(version_of rustup 2>/dev/null || true)"
    cargo_before="$(version_of cargo 2>/dev/null || true)"
    section "rustup update"
    tool_card "rustup" "Rust toolchains" "$before"
    run_cmd rustup update
    code=$?
    after="$(version_of rustup 2>/dev/null || true)"
    cargo_after="$(version_of cargo 2>/dev/null || true)"
    track "rustup update" "$code" "$before" "$after"
    track "cargo version" 0 "$cargo_before" "$cargo_after" "cargo is updated through rustup toolchains"
    _ua_step_end "rustup"
  else
    skip_tool "rustup" "Rust toolchains" "rustup update" "rustup command not installed" "rustup"
    skip_tool "rustup" "cargo version" "cargo version" "rustup command not installed" "cargo"
  fi

  if [ "$_ua_has_cargo" = 1 ]; then
    if [ "$_ua_has_cargo_install_update" = 1 ]; then
      _ua_step_begin "cargo-installed" "cargo install-update"
      before="$(version_of cargo-install-update 2>/dev/null || true)"
      section "cargo install-update"
      tool_card "cargo-installed" "Cargo-installed CLIs" "$before" "cargo install-update -a"
      run_bounded "$UPDATE_ALL_BUILD_TIMEOUT" cargo install-update -a
      code=$?
      after="$(version_of cargo-install-update 2>/dev/null || true)"
      track "cargo installed CLIs" "$code" "$before" "$after" "updates cargo-installed binaries through the existing cargo-update helper"
      _ua_step_end "cargo-installed"
    else
      skip_tool "cargo-installed" "Cargo-installed CLIs" "cargo installed CLIs" "cargo exists, but cargo-install-update is not installed; not installing new Rust helpers automatically" "cargo install-update -a"
    fi
  else
    skip_tool "cargo-installed" "Cargo-installed CLIs" "cargo installed CLIs" "cargo command not installed" "cargo install-update -a"
  fi

  if [ "$_ua_has_gh" = 1 ]; then
    _ua_step_begin "gh" "gh extension upgrade"
    before="$(version_of gh 2>/dev/null || true)"
    section "gh extension upgrade"
    tool_card "gh" "GitHub CLI extensions" "$before"
    run_cmd env GH_PROMPT_DISABLED=1 gh extension upgrade --all
    code=$?
    after="$(version_of gh 2>/dev/null || true)"
    track "gh extensions" "$code" "$before" "$after"
    _ua_step_end "gh"
  else
    skip_tool "gh" "GitHub CLI extensions" "gh extensions" "gh command not installed" "gh"
  fi

  if [ "$_ua_has_code" = 1 ] || [ "$_ua_has_codium" = 1 ] || [ "$_ua_has_code_insiders" = 1 ]; then
    [ "$_ua_has_code" = 1 ] && _ua_run_editor_step "code" "code" "VS Code extensions" "code extensions"
    [ "$_ua_has_codium" = 1 ] && _ua_run_editor_step "codium" "codium" "VSCodium extensions" "codium extensions"
    [ "$_ua_has_code_insiders" = 1 ] && _ua_run_editor_step "code-insiders" "code-insiders" "VS Code Insiders extensions" "code-insiders extensions"
  else
    skip_tool "code" "Editor extensions" "editor extensions" "code/codium command not installed" "code --update-extensions"
  fi

  # ===== CLEANUP =====
  if declare -F run_cleanup_phase >/dev/null 2>&1; then
    run_cleanup_phase
  fi

  # ===== SAFETY COACH =====
  if declare -F run_safety_coach_scan >/dev/null 2>&1; then
    run_safety_coach_scan
  fi
}
