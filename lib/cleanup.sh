# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Distro-aware package manager cleanup and safe, bounded workstation cache cleanup.
# Public-safe: no hardcoded user home paths, private IPs, or secrets.

: "${_ua_reclaimed_kb:=0}"
: "${_ua_has_systemd:=0}"

_cleanup_detect_pkg_mgr() {
  local raw=""
  if [ -n "${_ua_sys_pkg_mgr:-}" ] && [ "${_ua_sys_pkg_mgr:-}" != "none" ]; then
    raw="$_ua_sys_pkg_mgr"
  elif [ -n "${_ua_pkg_mgr:-}" ] && [ "${_ua_pkg_mgr:-}" != "none" ]; then
    raw="$_ua_pkg_mgr"
  fi
  if [ -n "$raw" ]; then
    case "$raw" in
      apt|apt-get) printf 'apt' ;;
      dnf|dnf5|yum) printf 'dnf' ;;
      pacman|zypper|apk) printf '%s' "$raw" ;;
      xbps|xbps-install|xbps-remove) printf 'xbps' ;;
      *) printf '%s' "$raw" ;;
    esac
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    printf 'apt'
  elif command -v dnf5 >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    printf 'dnf'
  elif command -v pacman >/dev/null 2>&1; then
    printf 'pacman'
  elif command -v zypper >/dev/null 2>&1; then
    printf 'zypper'
  elif command -v apk >/dev/null 2>&1; then
    printf 'apk'
  elif command -v xbps-install >/dev/null 2>&1 || command -v xbps-remove >/dev/null 2>&1; then
    printf 'xbps'
  else
    printf 'none'
  fi
}

_cleanup_detect_dnf_bin() {
  case "${_ua_sys_pkg_mgr:-}" in
    dnf5|dnf|yum)
      printf '%s' "$_ua_sys_pkg_mgr"
      return 0
      ;;
  esac
  if command -v dnf5 >/dev/null 2>&1; then
    printf 'dnf5'
  elif command -v dnf >/dev/null 2>&1; then
    printf 'dnf'
  elif command -v yum >/dev/null 2>&1; then
    printf 'yum'
  else
    printf 'dnf'
  fi
}

_cleanup_has_systemd() {
  if [ "${_ua_has_systemd:-0}" = 1 ]; then
    return 0
  fi
  [ -d /run/systemd/system ]
}

dir_size_kb() {
  local total=0 p kb out
  for p in "$@"; do
    [ -n "$p" ] || continue
    [ -e "$p" ] || continue
    if command -v timeout >/dev/null 2>&1; then
      out="$(timeout 5s du -sk -- "$p" 2>/dev/null || true)"
    else
      out="$(du -sk -- "$p" 2>/dev/null || true)"
    fi
    kb="${out%%[[:space:]]*}"
    case "$kb" in
      ''|*[!0-9]*) kb=0 ;;
    esac
    total=$((total + kb))
  done
  printf '%s' "$total"
}

format_kb_human() {
  local kb="${1:-0}"
  case "$kb" in
    ''|*[!0-9]*) kb=0 ;;
  esac
  if [ "$kb" -ge 1048576 ]; then
    awk -v k="$kb" 'BEGIN { printf "%.1f GB", k / 1048576.0 }'
  elif [ "$kb" -ge 10240 ]; then
    printf '%d MB' $(( (kb + 512) / 1024 ))
  elif [ "$kb" -ge 1024 ]; then
    awk -v k="$kb" 'BEGIN { printf "%.1f MB", k / 1024.0 }'
  else
    printf '%d KB' "$kb"
  fi
}

_cleanup_print_banner_art() {
  local title="$1" word1="$2" word2="$3"
  local cleanup_art_color="${C_CLEANUP_WORD:-}" cleanup_punct_color="${C_ORANGE:-}"
  local line
  printf '\n'
  if command -v figlet >/dev/null 2>&1; then
    figlet -f future "$title" 2>/dev/null | while IFS= read -r line; do
      printf '%b%s%b\n' "$cleanup_art_color" "$line" "${C_RESET:-}"
    done
  elif [ "$word1" = "APT" ]; then
    printf '%b%s%b\n' "$cleanup_art_color" "  ___  ___ _____   ___ _    ___   _   _  _ _   _ ___  ___" "${C_RESET:-}"
    printf '%b%s%b\n' "${C_CLEANUP_PUNCT:-}" " / _ \\| _ \\_   _| / __| |  | __| /_\\ | \\| | | | | _ \\/ __|" "${C_RESET:-}"
    printf '%b%s%b\n' "$cleanup_art_color" "| (_) |  _/ | |  | (__| |__| _| / _ \\| .\\ | |_| |  _/\\__ \\" "${C_RESET:-}"
    printf '%b%s%b\n' "${C_CLEANUP_PUNCT:-}" " \\___/|_|   |_|   \\___|____|___/_/ \\_\\_|\\_|\\___/|_|  |___/" "${C_RESET:-}"
  else
    printf '   %b%s%b\n' "$cleanup_art_color" "$title" "${C_RESET:-}"
  fi
  printf '   %b%s%b %b%s%b%b?%b\n' \
    "$cleanup_punct_color" "$word1" "${C_RESET:-}" \
    "$cleanup_art_color" "$word2" "${C_RESET:-}" \
    "$cleanup_punct_color" "${C_RESET:-}"
}

cleanup_question() {
  local mode="${1:-prompt}" indent="   " pkg_mgr
  pkg_mgr="$(_cleanup_detect_pkg_mgr)"

  case "$pkg_mgr" in
    apt)
      _cleanup_print_banner_art "APT CLEANUP?" "APT" "CLEANUP"
      printf '%s%bThis will run apt-owned cleanup only.%b\n' "$indent" "${C_PURPOSE:-}" "${C_RESET:-}"
      printf '%s%bIt may purge packages apt marks as no longer needed and clear downloaded apt caches.%b\n' "$indent" "${C_PURPOSE:-}" "${C_RESET:-}"
      printf '%s%bNothing outside apt is deleted here.%b\n\n' "$indent" "${C_TIP:-}" "${C_RESET:-}"
      ;;
    dnf)
      _cleanup_print_banner_art "DNF CLEANUP?" "DNF" "CLEANUP"
      printf '%s%bThis will run dnf-owned cleanup only (autoremove unused packages and clear cached RPMs).%b\n' "$indent" "${C_PURPOSE:-}" "${C_RESET:-}"
      printf '%s%bNothing outside dnf is deleted here.%b\n\n' "$indent" "${C_TIP:-}" "${C_RESET:-}"
      ;;
    pacman)
      _cleanup_print_banner_art "PACMAN CACHE CLEANUP?" "PACMAN" "CACHE CLEANUP"
      printf '%s%bThis will clear uninstalled package tarballs from the pacman cache (pacman -Sc).%b\n' "$indent" "${C_PURPOSE:-}" "${C_RESET:-}"
      printf '%s%bInstalled packages and user files are left alone.%b\n\n' "$indent" "${C_TIP:-}" "${C_RESET:-}"
      ;;
    zypper)
      _cleanup_print_banner_art "ZYPPER CLEANUP?" "ZYPPER" "CLEANUP"
      printf '%s%bThis will clear downloaded zypper repository caches (zypper --non-interactive clean --all).%b\n' "$indent" "${C_PURPOSE:-}" "${C_RESET:-}"
      printf '%s%bInstalled packages and user files are left alone.%b\n\n' "$indent" "${C_TIP:-}" "${C_RESET:-}"
      ;;
    apk)
      _cleanup_print_banner_art "APK CACHE CLEANUP?" "APK" "CACHE CLEANUP"
      printf '%s%bThis will clear cached Alpine package archives (apk cache clean).%b\n' "$indent" "${C_PURPOSE:-}" "${C_RESET:-}"
      printf '%s%bInstalled packages and user files are left alone.%b\n\n' "$indent" "${C_TIP:-}" "${C_RESET:-}"
      ;;
    xbps)
      _cleanup_print_banner_art "XBPS CLEANUP?" "XBPS" "CLEANUP"
      printf '%s%bThis will remove orphaned Void packages and obsolete cached archives (xbps-remove -Ooy).%b\n' "$indent" "${C_PURPOSE:-}" "${C_RESET:-}"
      printf '%s%bNothing outside xbps is deleted here.%b\n\n' "$indent" "${C_TIP:-}" "${C_RESET:-}"
      ;;
    *)
      printf '\n'
      printf '%s%bSYSTEM PACKAGE CLEANUP%b\n' "$indent" "${C_CLEANUP_WORD:-}" "${C_RESET:-}"
      printf '%s%bNo supported Linux system package manager (apt/dnf/pacman/zypper/apk/xbps) detected on this host.%b\n\n' "$indent" "${C_TIP:-}" "${C_RESET:-}"
      return 0
      ;;
  esac

  if [ "$mode" = "preview" ]; then
    printf '%s%bDry-run previews these commands without asking for input.%b\n\n' "$indent" "${C_UNIT:-}" "${C_RESET:-}"
  else
    printf '%s%bAnswer y/N at the prompt below.%b\n\n' "$indent" "${C_UNIT:-}" "${C_RESET:-}"
  fi
}

_cleanup_cache_dirs() {
  printf '%s\n' \
    "$HOME/.cache/camoufox" \
    "$HOME/.cache/ms-playwright" \
    "$HOME/.cache/BraveSoftware" \
    "$HOME/.cache/electron" \
    "$HOME/.cache/node-gyp" \
    "$HOME/.cache/node" \
    "$HOME/.cache/Homebrew" \
    "$HOME/.cache/pip"
}

_cleanup_present_targets_summary() {
  local items="" d
  command -v npm >/dev/null 2>&1 && items="${items:+${items}, }npm/npx"
  command -v pip3 >/dev/null 2>&1 && items="${items:+${items}, }pip3"
  command -v brew >/dev/null 2>&1 && items="${items:+${items}, }Homebrew"
  command -v uv >/dev/null 2>&1 && items="${items:+${items}, }uv prune"
  while IFS= read -r d; do
    if [ -e "$d" ]; then
      items="${items:+${items}, }~/.cache/${d##*/}"
    fi
  done < <(_cleanup_cache_dirs)
  if [ -e "$HOME/.codex/.tmp/plugins" ] || [ -e "$HOME/.codex/.tmp/plugins.sha" ]; then
    items="${items:+${items}, }codex plugin tmp"
  fi
  command -v snap >/dev/null 2>&1 && items="${items:+${items}, }disabled snap revisions"
  if command -v journalctl >/dev/null 2>&1 && _cleanup_has_systemd; then
    items="${items:+${items}, }systemd journal trim"
  fi
  [ -n "$items" ] || items="no active cache targets detected right now"
  printf '%s' "$items"
}

workstation_cleanup_question() {
  local mode="${1:-prompt}" targets_summary est_kb
  targets_summary="$(_cleanup_present_targets_summary)"
  est_kb="$(dir_size_kb \
    "$HOME/.npm/_npx" \
    "$HOME/.npm/_cacache" \
    "$HOME/.cache/camoufox" \
    "$HOME/.cache/ms-playwright" \
    "$HOME/.cache/BraveSoftware" \
    "$HOME/.cache/electron" \
    "$HOME/.cache/node-gyp" \
    "$HOME/.cache/node" \
    "$HOME/.cache/Homebrew" \
    "$HOME/.cache/pip" \
    "$HOME/.cache/uv" \
    "$HOME/.codex/.tmp/plugins")"

  printf '\n'
  printf '   %b%s WORKSTATION CACHE CLEANUP?%b\n' "${C_CLEANUP_WORD:-${C_UNIT:-}}" "${G_CARD:-▌}" "${C_RESET:-}"
  printf '   %bThis removes rebuildable caches and old update leftovers only.%b\n' "${C_PURPOSE:-}" "${C_RESET:-}"
  printf '   %bIt leaves archives, LLM weights, project data, active virtualenvs, and databases alone.%b\n' "${C_TIP:-}" "${C_RESET:-}"
  printf '   %bDetected on this host:%b %s\n' "${C_LABEL:-}" "${C_RESET:-}" "$targets_summary"
  if [ "${est_kb:-0}" -gt 0 ]; then
    printf '   %bEstimated cache footprint:%b %b%s%b\n' \
      "${C_LABEL:-}" "${C_RESET:-}" "${C_CLEANUP_WORD:-}" "$(format_kb_human "$est_kb")" "${C_RESET:-}"
  fi
  printf '\n'
  if [ "$mode" = "preview" ]; then
    printf '   %bDry-run previews these commands without asking for input.%b\n\n' "${C_UNIT:-}" "${C_RESET:-}"
  else
    printf '   %bAnswer y/N at the prompt below.%b\n\n' "${C_UNIT:-}" "${C_RESET:-}"
  fi
}

_cleanup_run_apt() {
  if declare -F sudo_noninteractive_apt >/dev/null 2>&1; then
    sudo_noninteractive_apt apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 -o APT::Progress-Fancy=0 -o Dpkg::Progress-Fancy=0 \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=60 "$@"
    return $?
  fi
  sudo_cmd env DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true NEEDRESTART_MODE=l UCF_FORCE_CONFFOLD=1 APT_LISTCHANGES_FRONTEND=none PAGER=cat TERM=dumb \
    apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 -o APT::Progress-Fancy=0 -o Dpkg::Progress-Fancy=0 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=60 "$@"
}

run_system_pkg_cleanup() {
  local pkg_mgr dnf_bin="" code_a=0 code_b=0 code_c=0 before_kb=0 after_kb=0 reclaimed=0
  pkg_mgr="$(_cleanup_detect_pkg_mgr)"

  case "$pkg_mgr" in
    apt)
      if [ "${UPDATE_ALL_DRY_RUN:-0}" = 1 ]; then
        show_cmd sudo apt-get autoremove --purge -y
        show_cmd sudo apt-get autoclean
        show_cmd sudo apt-get clean
        printf '   %bnote%b            live runs set DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l\n' "${C_TIP:-}" "${C_RESET:-}"
        return 0
      fi
      before_kb="$(dir_size_kb /var/cache/apt/archives)"
      _cleanup_run_apt autoremove --purge -y || code_a=$?
      _cleanup_run_apt autoclean || code_b=$?
      _cleanup_run_apt clean || code_c=$?
      after_kb="$(dir_size_kb /var/cache/apt/archives)"
      if [ "$before_kb" -gt "$after_kb" ]; then
        reclaimed=$((before_kb - after_kb))
        _ua_reclaimed_kb=$(( ${_ua_reclaimed_kb:-0} + reclaimed ))
        printf '   %b%-15s%b %b%s%b\n' "${C_LABEL:-}" "reclaimed" "${C_RESET:-}" "${C_OK:-}" "$(format_kb_human "$reclaimed")" "${C_RESET:-}"
      fi
      [ "$code_a" -eq 0 ] && [ "$code_b" -eq 0 ] && [ "$code_c" -eq 0 ]
      return $?
      ;;
    dnf)
      dnf_bin="$(_cleanup_detect_dnf_bin)"
      if [ "${UPDATE_ALL_DRY_RUN:-0}" = 1 ]; then
        show_cmd sudo "$dnf_bin" autoremove -y
        show_cmd sudo "$dnf_bin" clean packages
        return 0
      fi
      before_kb="$(dir_size_kb /var/cache/dnf /var/cache/libdnf5 /var/cache/yum)"
      sudo_cmd "$dnf_bin" autoremove -y || code_a=$?
      sudo_cmd "$dnf_bin" clean packages || code_b=$?
      after_kb="$(dir_size_kb /var/cache/dnf /var/cache/libdnf5 /var/cache/yum)"
      if [ "$before_kb" -gt "$after_kb" ]; then
        reclaimed=$((before_kb - after_kb))
        _ua_reclaimed_kb=$(( ${_ua_reclaimed_kb:-0} + reclaimed ))
        printf '   %b%-15s%b %b%s%b\n' "${C_LABEL:-}" "reclaimed" "${C_RESET:-}" "${C_OK:-}" "$(format_kb_human "$reclaimed")" "${C_RESET:-}"
      fi
      [ "$code_a" -eq 0 ] && [ "$code_b" -eq 0 ]
      return $?
      ;;
    pacman)
      if [ "${UPDATE_ALL_DRY_RUN:-0}" = 1 ]; then
        show_cmd sudo pacman -Sc --noconfirm
        return 0
      fi
      before_kb="$(dir_size_kb /var/cache/pacman/pkg)"
      sudo_cmd pacman -Sc --noconfirm || code_a=$?
      after_kb="$(dir_size_kb /var/cache/pacman/pkg)"
      if [ "$before_kb" -gt "$after_kb" ]; then
        reclaimed=$((before_kb - after_kb))
        _ua_reclaimed_kb=$(( ${_ua_reclaimed_kb:-0} + reclaimed ))
        printf '   %b%-15s%b %b%s%b\n' "${C_LABEL:-}" "reclaimed" "${C_RESET:-}" "${C_OK:-}" "$(format_kb_human "$reclaimed")" "${C_RESET:-}"
      fi
      return "$code_a"
      ;;
    zypper)
      if [ "${UPDATE_ALL_DRY_RUN:-0}" = 1 ]; then
        show_cmd sudo zypper --non-interactive clean --all
        return 0
      fi
      before_kb="$(dir_size_kb /var/cache/zypp)"
      sudo_cmd zypper --non-interactive clean --all || code_a=$?
      after_kb="$(dir_size_kb /var/cache/zypp)"
      if [ "$before_kb" -gt "$after_kb" ]; then
        reclaimed=$((before_kb - after_kb))
        _ua_reclaimed_kb=$(( ${_ua_reclaimed_kb:-0} + reclaimed ))
        printf '   %b%-15s%b %b%s%b\n' "${C_LABEL:-}" "reclaimed" "${C_RESET:-}" "${C_OK:-}" "$(format_kb_human "$reclaimed")" "${C_RESET:-}"
      fi
      return "$code_a"
      ;;
    apk)
      if [ "${UPDATE_ALL_DRY_RUN:-0}" = 1 ]; then
        show_cmd sudo apk cache clean
        return 0
      fi
      sudo_cmd apk cache clean
      return $?
      ;;
    xbps)
      if [ "${UPDATE_ALL_DRY_RUN:-0}" = 1 ]; then
        show_cmd sudo xbps-remove -Ooy
        return 0
      fi
      before_kb="$(dir_size_kb /var/cache/xbps)"
      sudo_cmd xbps-remove -Ooy || code_a=$?
      after_kb="$(dir_size_kb /var/cache/xbps)"
      if [ "$before_kb" -gt "$after_kb" ]; then
        reclaimed=$((before_kb - after_kb))
        _ua_reclaimed_kb=$(( ${_ua_reclaimed_kb:-0} + reclaimed ))
        printf '   %b%-15s%b %b%s%b\n' "${C_LABEL:-}" "reclaimed" "${C_RESET:-}" "${C_OK:-}" "$(format_kb_human "$reclaimed")" "${C_RESET:-}"
      fi
      return "$code_a"
      ;;
    *)
      return 1
      ;;
  esac
}

run_workstation_cleanup() {
  local code=0 before_kb=0 after_kb=0 reclaimed=0 brew_cache="" d
  local -a tracked_paths=()

  if [ "${UPDATE_ALL_DRY_RUN:-0}" = 1 ]; then
    show_cmd npm cache clean --force
    show_cmd rm -rf -- "$HOME/.npm/_npx"
    show_cmd pip3 cache purge
    show_cmd brew cleanup -s
    show_cmd timeout 20s uv cache prune
    printf '%b$%b rm -rf -- ~/.cache/{camoufox,ms-playwright,BraveSoftware,electron,node-gyp,node,Homebrew,pip}\n' "${C_CMD:-}" "${C_RESET:-}"
    show_cmd rm -rf -- "$HOME/.codex/.tmp/plugins" "$HOME/.codex/.tmp/plugins.sha"
    printf '%b$%b sudo remove disabled snap revisions from snap list --all\n' "${C_CMD:-}" "${C_RESET:-}"
    show_cmd sudo journalctl --vacuum-size=512M
    return 0
  fi

  tracked_paths=(
    "$HOME/.npm/_npx"
    "$HOME/.npm/_cacache"
    "$HOME/.cache/camoufox"
    "$HOME/.cache/ms-playwright"
    "$HOME/.cache/BraveSoftware"
    "$HOME/.cache/electron"
    "$HOME/.cache/node-gyp"
    "$HOME/.cache/node"
    "$HOME/.cache/Homebrew"
    "$HOME/.cache/pip"
    "$HOME/.cache/uv"
    "$HOME/.codex/.tmp/plugins"
  )
  if command -v brew >/dev/null 2>&1; then
    brew_cache="$(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew --cache 2>/dev/null || true)"
    brew_cache="${brew_cache%/}"
    if [ -n "$brew_cache" ]; then
      local seen_brew_cache=0 tp=""
      for tp in "${tracked_paths[@]}"; do
        if [ "${tp%/}" = "$brew_cache" ]; then
          seen_brew_cache=1
          break
        fi
      done
      [ "$seen_brew_cache" -eq 0 ] && tracked_paths+=("$brew_cache")
    fi
  fi

  before_kb="$(dir_size_kb "${tracked_paths[@]}")"

  if command -v npm >/dev/null 2>&1; then
    run_cmd npm cache clean --force || code=1
    if [ -e "$HOME/.npm/_npx" ]; then
      rm -rf -- "$HOME/.npm/_npx" || code=1
    fi
  fi

  if command -v pip3 >/dev/null 2>&1; then
    run_cmd pip3 cache purge || code=1
  fi

  if command -v brew >/dev/null 2>&1; then
    run_cmd env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew cleanup -s || code=1
  fi

  if command -v uv >/dev/null 2>&1; then
    if declare -F run_bounded >/dev/null 2>&1; then
      run_bounded 20s uv cache prune || code=1
    elif command -v timeout >/dev/null 2>&1; then
      run_cmd timeout 20s uv cache prune || code=1
    else
      run_cmd uv cache prune || code=1
    fi
  fi

  while IFS= read -r d; do
    if [ -e "$d" ]; then
      rm -rf -- "$d" || code=1
    fi
  done < <(_cleanup_cache_dirs)

  for d in "$HOME/.codex/.tmp/plugins" "$HOME/.codex/.tmp/plugins.sha"; do
    if [ -e "$d" ]; then
      rm -rf -- "$d" || code=1
    fi
  done

  if command -v snap >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # Keep the root cleanup script literal until bash -c receives it.
    sudo_cmd env -u BASH_ENV -u ENV bash --noprofile --norc -c '
snap list --all </dev/null 2>/dev/null | while IFS=$'\'' \t'\'' read -r name _ rev _ _ notes; do
  [ -n "$name" ] || continue
  [ "$name" = "Name" ] && continue
  case "$notes" in
    *disabled*)
      if command -v timeout >/dev/null 2>&1; then
        timeout 60s snap remove "$name" --revision="$rev" </dev/null || true
      else
        snap remove "$name" --revision="$rev" </dev/null || true
      fi
      ;;
  esac
done
' || code=1
  fi

  if command -v journalctl >/dev/null 2>&1 && _cleanup_has_systemd && command -v sudo >/dev/null 2>&1; then
    sudo_cmd journalctl --vacuum-size=512M || code=1
  fi

  after_kb="$(dir_size_kb "${tracked_paths[@]}")"
  if [ "$before_kb" -gt "$after_kb" ]; then
    reclaimed=$((before_kb - after_kb))
    _ua_reclaimed_kb=$(( ${_ua_reclaimed_kb:-0} + reclaimed ))
  fi
  printf '   %b%-15s%b %b%s%b\n' \
    "${C_LABEL:-}" "reclaimed" "${C_RESET:-}" \
    "${C_OK:-}" "$(format_kb_human "$reclaimed")" "${C_RESET:-}"

  return "$code"
}

run_cleanup_phase() {
  local pkg_mgr dnf_bin="" step_label step_title step_status="SKIP" ws_status="SKIP" clean_rc=0 ws_rc=0 ws_note supported_pkg_mgr=1
  pkg_mgr="$(_cleanup_detect_pkg_mgr)"

  if declare -F tui_set_phase >/dev/null 2>&1; then
    tui_set_phase "CLEANUP"
  fi
  banner "CLEANUP"

  case "$pkg_mgr" in
    apt)    step_label="apt autoremove"; step_title="apt cleanup" ;;
    dnf)
      dnf_bin="$(_cleanup_detect_dnf_bin)"
      step_label="${dnf_bin} autoremove"; step_title="${dnf_bin} cleanup"
      ;;
    pacman) step_label="pacman cache clean"; step_title="pacman cache cleanup" ;;
    zypper) step_label="zypper cleanup"; step_title="zypper cleanup" ;;
    apk)    step_label="apk cache clean"; step_title="apk cache cleanup" ;;
    xbps)   step_label="xbps cleanup"; step_title="xbps cleanup" ;;
    *)      step_label="system package cleanup"; step_title="system package cleanup"; supported_pkg_mgr=0 ;;
  esac

  if declare -F tui_step_begin >/dev/null 2>&1; then
    tui_step_begin "apt-cleanup" "$step_label"
  fi
  section "${step_title}"
  tool_card "cleanup" "$step_title"
  if [ "$supported_pkg_mgr" -eq 0 ]; then
    if [ "$pkg_mgr" = "none" ]; then
      skip_step "$step_label" "no supported Linux system package manager (apt/dnf/pacman/zypper/apk/xbps) detected"
    else
      skip_step "$step_label" "system package cleanup not supported for ${pkg_mgr} (managed separately)"
    fi
    step_status="SKIP"
  else
    printf '   %b%s%b %s\n\n' "${C_LABEL:-}" "upfront choice" "${C_RESET:-}" "${_ua_apt_cleanup_choice:-no}"
    if choice_is_yes "${_ua_apt_cleanup_choice:-no}"; then
      run_system_pkg_cleanup
      clean_rc=$?
      if [ "$clean_rc" -eq 0 ]; then
        track "$step_label" 0 "" "" "${pkg_mgr}-owned cleanup completed"
        step_status="OK"
      else
        track "$step_label" 1 "" "" "${pkg_mgr} cleanup returned exit=${clean_rc}"
        step_status="FAIL"
      fi
    else
      skip_step "$step_label" "skipped by upfront choice; no packages removed or cache cleaned"
      step_status="SKIP"
      add_concern "System package cleanup skipped" \
        "No ${pkg_mgr}-owned cleanup ran, so auto-removable packages and download caches may remain." \
        "This is safe. Run update-all again and answer yes to ${pkg_mgr} cleanup when you want that maintenance."
    fi
  fi
  if declare -F tui_step_end >/dev/null 2>&1; then
    tui_step_end "apt-cleanup" "$step_status"
  fi

  if declare -F tui_step_begin >/dev/null 2>&1; then
    tui_step_begin "workstation-cleanup" "workstation cache cleanup"
  fi
  section "workstation cache cleanup"
  tool_card "cleanup" "workstation cache cleanup"
  printf '   %b%s%b %s\n\n' "${C_LABEL:-}" "upfront choice" "${C_RESET:-}" "${_ua_workstation_cleanup_choice:-no}"
  if choice_is_yes "${_ua_workstation_cleanup_choice:-no}"; then
    run_workstation_cleanup
    ws_rc=$?
    ws_note="safe rebuildable cache sweep; archives, LLM weights, databases, and project data left alone"
    if [ "${_ua_reclaimed_kb:-0}" -gt 0 ]; then
      ws_note="${ws_note} ($(format_kb_human "$_ua_reclaimed_kb") reclaimed)"
    fi
    track "workstation cache cleanup" "$ws_rc" "" "" "$ws_note"
    if [ "$ws_rc" -eq 0 ]; then
      ws_status="OK"
    else
      ws_status="FAIL"
    fi
  else
    skip_step "workstation cache cleanup" "skipped by upfront choice; no non-apt caches removed"
    ws_status="SKIP"
    add_concern "Cache cleanup skipped" \
      "No broader rebuildable cache cleanup ran, so npm/pip/browser caches may remain." \
      "This is safe. Run update-all again and answer yes to workstation cache cleanup when you want to reclaim space."
  fi
  if declare -F tui_step_end >/dev/null 2>&1; then
    tui_step_end "workstation-cleanup" "$ws_status"
  fi
}
