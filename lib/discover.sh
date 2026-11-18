# shellcheck shell=bash
# Universal Linux/macOS host discovery, bounded version probes,
# coverage preflight, and upfront optional choice collection.
# Bash 3.2 parse-compatible; sourced by bin/update-all.

UPDATE_ALL_PROBE_TIMEOUT="${UPDATE_ALL_PROBE_TIMEOUT:-8s}"
UPDATE_ALL_DRY_RUN_PROBES="${UPDATE_ALL_DRY_RUN_PROBES:-0}"
UPDATE_ALL_FIRMWARE_FLAG="${UPDATE_ALL_FIRMWARE_FLAG:-0}"
UPDATE_ALL_NONINTERACTIVE="${UPDATE_ALL_NONINTERACTIVE:-${UPDATE_ALL_NON_INTERACTIVE:-0}}"

_ua_env_discovered=0 _ua_has_systemd=0 _ua_is_headless=0 _ua_needs_sudo=0 _ua_step_total=0
_ua_distro_id="" _ua_distro_like="" _ua_distro_name="" _ua_os_kernel="" _ua_sys_pkg_mgr="none"
_ua_brew_prefix="" _ua_brew_prefix_checked=0

_ua_has_apt=0 _ua_has_rpm_ostree=0 _ua_has_dnf=0 _ua_has_pacman=0 _ua_has_zypper=0 _ua_has_apk=0 _ua_has_xbps=0
_ua_has_snap=0 _ua_has_flatpak=0 _ua_has_fwupd=0
_ua_has_node=0 _ua_has_update_node=0 _ua_has_mise=0 _ua_has_volta=0 _ua_has_fnm=0
_ua_has_corepack=0 _ua_has_pnpm=0 _ua_has_yarn=0 _ua_has_bun=0 _ua_has_deno=0
_ua_has_npm=0 _ua_has_claude=0 _ua_has_codex=0
_ua_has_brew=0 _ua_has_uv=0 _ua_has_pipx=0 _ua_has_rustup=0 _ua_has_cargo=0 _ua_has_cargo_install_update=0
_ua_has_gh=0 _ua_has_code=0 _ua_has_codium=0 _ua_has_code_insiders=0

if ! declare -p _ua_planned_keys >/dev/null 2>&1; then
  declare -a _ua_planned_keys=()
fi

_ua_probe_bounded() {
  local limit="${UPDATE_ALL_PROBE_TIMEOUT:-8s}"
  if declare -F run_probe_bounded >/dev/null 2>&1; then
    run_probe_bounded "$limit" \
      env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
      "$@"
    return $?
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout "$limit" \
      env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
      "$@" </dev/null 2>/dev/null
    return $?
  fi
  env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    "$@" </dev/null 2>/dev/null
}

augment_safe_path() {
  local dir
  for dir in \
    "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.bun/bin" "$HOME/.deno/bin" \
    "$HOME/.volta/bin" "$HOME/.local/share/mise/shims" \
    "/home/linuxbrew/.linuxbrew/bin" "$HOME/.linuxbrew/bin" "/snap/bin"
  do
    [ -d "$dir" ] || continue
    case ":${PATH}:" in
      *":${dir}:"*) ;;
      *) PATH="${PATH}:${dir}" ;;
    esac
  done
  export PATH
}

discover_host() {
  local k v os_id="" os_like="" os_pretty="" os_name=""
  _ua_os_kernel="$(uname -s 2>/dev/null || printf 'unknown')"

  if [ -r /etc/os-release ]; then
    while IFS='=' read -r k v || [ -n "$k" ]; do
      case "$k" in ""|\#*) continue ;; esac
      v="${v%$'\r'}"
      case "$v" in
        \"*\") v="${v#\"}"; v="${v%\"}" ;;
        \'*\') v="${v#\'}"; v="${v%\'}" ;;
      esac
      case "$k" in
        ID) os_id="$v" ;;
        ID_LIKE) os_like="$v" ;;
        PRETTY_NAME) os_pretty="$v" ;;
        NAME) os_name="$v" ;;
      esac
    done < /etc/os-release
  fi

  _ua_distro_id="$(printf '%s' "${os_id:-$_ua_os_kernel}" | tr '[:upper:]' '[:lower:]')"
  _ua_distro_like="$(printf '%s' "$os_like" | tr '[:upper:]' '[:lower:]')"
  if [ -n "$os_pretty" ]; then _ua_distro_name="$os_pretty"
  elif [ -n "$os_name" ]; then _ua_distro_name="$os_name"
  else _ua_distro_name="$_ua_os_kernel $(uname -r 2>/dev/null || true)"
  fi

  [ -d /run/systemd/system ] && _ua_has_systemd=1 || _ua_has_systemd=0
  if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    _ua_is_headless=1
  else
    _ua_is_headless=0
  fi

  if command -v rpm-ostree >/dev/null 2>&1; then _ua_sys_pkg_mgr="rpm-ostree"
  elif command -v apt-get >/dev/null 2>&1; then _ua_sys_pkg_mgr="apt-get"
  elif command -v dnf5 >/dev/null 2>&1; then _ua_sys_pkg_mgr="dnf5"
  elif command -v dnf >/dev/null 2>&1; then _ua_sys_pkg_mgr="dnf"
  elif command -v yum >/dev/null 2>&1; then _ua_sys_pkg_mgr="yum"
  elif command -v pacman >/dev/null 2>&1; then _ua_sys_pkg_mgr="pacman"
  elif command -v zypper >/dev/null 2>&1; then _ua_sys_pkg_mgr="zypper"
  elif command -v apk >/dev/null 2>&1; then _ua_sys_pkg_mgr="apk"
  elif command -v xbps-install >/dev/null 2>&1; then _ua_sys_pkg_mgr="xbps-install"
  else _ua_sys_pkg_mgr="none"
  fi
}

is_path_writable() {
  local target="${1:-}" cur parent
  [ -n "$target" ] || return 1
  if [ -e "$target" ]; then
    [ -w "$target" ]
    return $?
  fi
  cur="$target"
  while [ ! -e "$cur" ]; do
    parent="$(dirname "$cur")"
    [ "$parent" != "$cur" ] || return 1
    cur="$parent"
  done
  [ -w "$cur" ]
}

_ua_get_brew_prefix() {
  if [ "$_ua_brew_prefix_checked" = 1 ]; then
    printf '%s' "$_ua_brew_prefix"
    return 0
  fi
  _ua_brew_prefix_checked=1
  if command -v brew >/dev/null 2>&1; then
    _ua_brew_prefix="$(_ua_probe_bounded brew --prefix | sed -n '1p' || true)"
  fi
  printf '%s' "$_ua_brew_prefix"
}

tool_install_owner() {
  local cmd="$1" bin_path real_path brew_pfx
  bin_path="$(command -v "$cmd" 2>/dev/null || true)"
  [ -n "$bin_path" ] || { printf 'missing'; return 1; }
  real_path="$(readlink -f "$bin_path" 2>/dev/null || true)"
  [ -n "$real_path" ] || real_path="$bin_path"

  brew_pfx="$(_ua_get_brew_prefix)"
  if [ -n "$brew_pfx" ]; then
    case "$bin_path" in "${brew_pfx}"/*) printf 'brew'; return 0 ;; esac
    case "$real_path" in "${brew_pfx}"/*) printf 'brew'; return 0 ;; esac
  fi

  case "$real_path" in
    /snap/*) printf 'snap'; return 0 ;;
    /usr/bin/*|/usr/sbin/*|/bin/*|/sbin/*)
      is_path_writable "$real_path" && printf 'user' || printf 'distro'
      return 0 ;;
  esac

  if is_path_writable "$bin_path" && is_path_writable "$real_path"; then
    printf 'user'
  else
    printf 'root'
  fi
}

recompute_needs_sudo() {
  _ua_needs_sudo=0
  [ "$(id -u 2>/dev/null || printf '1000')" -eq 0 ] && return 0
  if [ "$_ua_has_apt" = 1 ] || [ "$_ua_has_dnf" = 1 ] || [ "$_ua_has_pacman" = 1 ] \
     || [ "$_ua_has_zypper" = 1 ] || [ "$_ua_has_apk" = 1 ] || [ "$_ua_has_xbps" = 1 ] \
     || [ "$_ua_has_snap" = 1 ]; then
    _ua_needs_sudo=1
  elif [ "$_ua_has_fwupd" = 1 ] && choice_is_yes "${_ua_firmware_choice:-no}"; then
    _ua_needs_sudo=1
  elif choice_is_yes "${_ua_apt_cleanup_choice:-no}" && [ "$_ua_sys_pkg_mgr" != "none" ]; then
    _ua_needs_sudo=1
  elif choice_is_yes "${_ua_workstation_cleanup_choice:-no}" && [ "$_ua_has_systemd" = 1 ]; then
    _ua_needs_sudo=1
  fi
}

discover_environment() {
  augment_safe_path
  discover_host

  _ua_has_apt=0 _ua_has_rpm_ostree=0 _ua_has_dnf=0 _ua_has_pacman=0 _ua_has_zypper=0 _ua_has_apk=0 _ua_has_xbps=0
  case "$_ua_sys_pkg_mgr" in
    rpm-ostree)   _ua_has_rpm_ostree=1 ;;
    apt-get)      _ua_has_apt=1 ;;
    dnf5|dnf|yum) _ua_has_dnf=1 ;;
    pacman)       _ua_has_pacman=1 ;;
    zypper)       _ua_has_zypper=1 ;;
    apk)          _ua_has_apk=1 ;;
    xbps-install) _ua_has_xbps=1 ;;
  esac

  command -v snap >/dev/null 2>&1 && _ua_has_snap=1 || _ua_has_snap=0
  command -v flatpak >/dev/null 2>&1 && _ua_has_flatpak=1 || _ua_has_flatpak=0
  command -v fwupdmgr >/dev/null 2>&1 && _ua_has_fwupd=1 || _ua_has_fwupd=0
  command -v node >/dev/null 2>&1 && _ua_has_node=1 || _ua_has_node=0
  command -v update-node >/dev/null 2>&1 && _ua_has_update_node=1 || _ua_has_update_node=0
  command -v mise >/dev/null 2>&1 && _ua_has_mise=1 || _ua_has_mise=0
  command -v volta >/dev/null 2>&1 && _ua_has_volta=1 || _ua_has_volta=0
  command -v fnm >/dev/null 2>&1 && _ua_has_fnm=1 || _ua_has_fnm=0
  command -v corepack >/dev/null 2>&1 && _ua_has_corepack=1 || _ua_has_corepack=0
  command -v pnpm >/dev/null 2>&1 && _ua_has_pnpm=1 || _ua_has_pnpm=0
  command -v yarn >/dev/null 2>&1 && _ua_has_yarn=1 || _ua_has_yarn=0
  command -v bun >/dev/null 2>&1 && _ua_has_bun=1 || _ua_has_bun=0
  command -v deno >/dev/null 2>&1 && _ua_has_deno=1 || _ua_has_deno=0
  command -v npm >/dev/null 2>&1 && _ua_has_npm=1 || _ua_has_npm=0
  command -v claude >/dev/null 2>&1 && _ua_has_claude=1 || _ua_has_claude=0
  command -v codex >/dev/null 2>&1 && _ua_has_codex=1 || _ua_has_codex=0
  command -v brew >/dev/null 2>&1 && _ua_has_brew=1 || _ua_has_brew=0
  command -v uv >/dev/null 2>&1 && _ua_has_uv=1 || _ua_has_uv=0
  command -v pipx >/dev/null 2>&1 && _ua_has_pipx=1 || _ua_has_pipx=0
  command -v rustup >/dev/null 2>&1 && _ua_has_rustup=1 || _ua_has_rustup=0
  command -v cargo >/dev/null 2>&1 && _ua_has_cargo=1 || _ua_has_cargo=0
  command -v cargo-install-update >/dev/null 2>&1 && _ua_has_cargo_install_update=1 || _ua_has_cargo_install_update=0
  command -v gh >/dev/null 2>&1 && _ua_has_gh=1 || _ua_has_gh=0
  command -v code >/dev/null 2>&1 && _ua_has_code=1 || _ua_has_code=0
  command -v codium >/dev/null 2>&1 && _ua_has_codium=1 || _ua_has_codium=0
  command -v code-insiders >/dev/null 2>&1 && _ua_has_code_insiders=1 || _ua_has_code_insiders=0

  _ua_planned_keys=()
  [ "$_ua_has_apt" = 1 ] && _ua_planned_keys+=("dpkg" "apt-update" "apt-upgrade")
  [ "$_ua_has_rpm_ostree" = 1 ] && _ua_planned_keys+=("rpm-ostree")
  [ "$_ua_has_dnf" = 1 ] && _ua_planned_keys+=("dnf-upgrade")
  [ "$_ua_has_pacman" = 1 ] && _ua_planned_keys+=("pacman-upgrade")
  [ "$_ua_has_zypper" = 1 ] && _ua_planned_keys+=("zypper-upgrade")
  [ "$_ua_has_apk" = 1 ] && _ua_planned_keys+=("apk-upgrade")
  [ "$_ua_has_xbps" = 1 ] && _ua_planned_keys+=("xbps-upgrade")
  [ "$_ua_has_snap" = 1 ] && _ua_planned_keys+=("snap")
  [ "$_ua_has_flatpak" = 1 ] && _ua_planned_keys+=("flatpak")
  [ "$_ua_has_fwupd" = 1 ] && _ua_planned_keys+=("fwupd")
  [ "$_ua_has_update_node" = 1 ] && _ua_planned_keys+=("node")
  [ "$_ua_has_mise" = 1 ] && _ua_planned_keys+=("mise")
  [ "$_ua_has_volta" = 1 ] && _ua_planned_keys+=("volta")
  [ "$_ua_has_corepack" = 1 ] && _ua_planned_keys+=("corepack")
  [ "$_ua_has_pnpm" = 1 ] && _ua_planned_keys+=("pnpm")
  [ "$_ua_has_yarn" = 1 ] && _ua_planned_keys+=("yarn")
  [ "$_ua_has_bun" = 1 ] && _ua_planned_keys+=("bun")
  [ "$_ua_has_deno" = 1 ] && _ua_planned_keys+=("deno")
  [ "$_ua_has_npm" = 1 ] && _ua_planned_keys+=("npm-self" "npm-globals")
  [ "$_ua_has_claude" = 1 ] && _ua_planned_keys+=("claude")
  [ "$_ua_has_codex" = 1 ] && _ua_planned_keys+=("codex")
  [ "$_ua_has_brew" = 1 ] && _ua_planned_keys+=("brew-upgrade")
  [ "$_ua_has_uv" = 1 ] && _ua_planned_keys+=("uv" "uv-tools")
  [ "$_ua_has_pipx" = 1 ] && _ua_planned_keys+=("pipx")
  [ "$_ua_has_rustup" = 1 ] && _ua_planned_keys+=("rustup")
  [ "$_ua_has_cargo_install_update" = 1 ] && _ua_planned_keys+=("cargo-installed")
  [ "$_ua_has_gh" = 1 ] && _ua_planned_keys+=("gh")
  [ "$_ua_has_code" = 1 ] && _ua_planned_keys+=("code")
  [ "$_ua_has_codium" = 1 ] && _ua_planned_keys+=("codium")
  [ "$_ua_has_code_insiders" = 1 ] && _ua_planned_keys+=("code-insiders")
  _ua_planned_keys+=("apt-cleanup" "workstation-cleanup" "safety")

  _ua_step_total="${#_ua_planned_keys[@]}"
  if declare -F timings_set_planned_keys >/dev/null 2>&1; then
    timings_set_planned_keys "${_ua_planned_keys[@]}"
  fi
  recompute_needs_sudo
  _ua_env_discovered=1
}

pkg_json_version() {
  local file="$1"
  [ -r "$file" ] || return 1
  sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | sed -n '1p'
}

_ua_ver_line() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || return 1
  printf '%s %s' "$(command -v "$cmd")" "$(_ua_probe_bounded "$@" | sed -n '1p')"
}

version_of() {
  local v out dnf_bin=""
  case "$1" in
    dpkg) command -v dpkg >/dev/null 2>&1 && _ua_probe_bounded dpkg --version | sed -n '1p' ;;
    apt) command -v apt-get >/dev/null 2>&1 && _ua_probe_bounded apt-get --version | sed -n '1p' ;;
    apt-upgradable) command -v apt >/dev/null 2>&1 && _ua_probe_bounded apt list --upgradable | awk 'NR>1{n++} END{printf "%s upgradable", n+0}' ;;
    rpm-ostree) command -v rpm-ostree >/dev/null 2>&1 && printf '%s %s' "$(command -v rpm-ostree)" "$(_ua_probe_bounded rpm-ostree --version | awk '/Version:/{print $2; exit}')" ;;
    dnf)
      if command -v dnf5 >/dev/null 2>&1; then dnf_bin="dnf5"
      elif command -v dnf >/dev/null 2>&1; then dnf_bin="dnf"
      elif command -v yum >/dev/null 2>&1; then dnf_bin="yum"
      fi
      [ -n "$dnf_bin" ] && _ua_ver_line "$dnf_bin" --version ;;
    pacman) _ua_ver_line pacman --version ;;
    zypper) _ua_ver_line zypper --version ;;
    apk) _ua_ver_line apk --version ;;
    xbps) _ua_ver_line xbps-install --version ;;
    node|mise|volta|fnm|corepack|pnpm|yarn|bun|deno|claude|codex|brew|uv|pipx|rustup|cargo|cargo-install-update|gh|code|codium|code-insiders|flatpak)
      _ua_ver_line "$1" --version ;;
    npm-active) _ua_ver_line npm --version ;;
    npm-bundled)
      local bundled="$HOME/.local/lib/node-current/lib/node_modules/npm/package.json" bundled_v
      bundled_v="$(pkg_json_version "$bundled" 2>/dev/null || true)"
      [ -n "$bundled_v" ] && printf '%s %s' "$bundled" "$bundled_v" ;;
    npm-globals) command -v npm >/dev/null 2>&1 && printf 'prefix %s' "$(_ua_probe_bounded npm prefix -g | sed -n '1p')" ;;
    fwupd)
      if command -v fwupdmgr >/dev/null 2>&1; then
        out="$(_ua_probe_bounded fwupdmgr --version || true)"
        v="$(printf '%s\n' "$out" | awk '$1 == "runtime" && $2 == "org.freedesktop.fwupd" {print $3; exit}')"
        [ -n "$v" ] || v="$(printf '%s\n' "$out" | awk '$2 == "org.freedesktop.fwupd" {print $3; exit}')"
        [ -n "$v" ] || v="$(printf '%s\n' "$out" | sed -n '1p')"
        printf '%s fwupd %s' "$(command -v fwupdmgr)" "$v"
      fi ;;
    snap) command -v snap >/dev/null 2>&1 && printf '%s %s' "$(command -v snap)" "$(_ua_probe_bounded snap version | awk '/^snap /{print $2; exit}')" ;;
  esac
}

show_pending_apt_updates() {
  local line pkg old new count=0 output
  pending_updates_begin "apt list --upgradable"
  if [ "$UPDATE_ALL_DRY_RUN" = 1 ] && [ "${UPDATE_ALL_DRY_RUN_PROBES:-0}" != 1 ]; then
    pending_update_note "dry-run: skipped live probe for speed (set UPDATE_ALL_DRY_RUN_PROBES=1 to query)"
    printf '\n'; return 0
  fi
  output="$(_ua_probe_bounded apt list --upgradable || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in Listing*) continue ;; esac
    pkg="${line%%/*}"
    new="$(printf '%s\n' "$line" | awk '{print $2}')"
    old="$(printf '%s\n' "$line" | sed -n 's/.*\[upgradable from: \([^]]*\)\].*/\1/p')"
    [ -n "$pkg" ] || continue
    pending_update_line "$pkg" "${old:-installed}" "${new:-available}"
    count=$((count + 1))
  done <<< "$output"
  [ "$count" -gt 0 ] || pending_update_note "none detected before this step"
  printf '\n'
}

show_pending_npm_globals() {
  local output line name current latest count=0
  pending_updates_begin "npm outdated -g"
  if [ "$UPDATE_ALL_DRY_RUN" = 1 ] && [ "${UPDATE_ALL_DRY_RUN_PROBES:-0}" != 1 ]; then
    pending_update_note "dry-run: skipped remote network probe (set UPDATE_ALL_DRY_RUN_PROBES=1 to query)"
    printf '\n'; return 0
  fi
  output="$(_ua_probe_bounded npm outdated -g --depth=0 || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in Package\ *|---*) continue ;; esac
    name="$(printf '%s\n' "$line" | awk '{print $1}')"
    current="$(printf '%s\n' "$line" | awk '{print $2}')"
    latest="$(printf '%s\n' "$line" | awk '{print $4}')"
    [ -n "$name" ] || continue
    pending_update_line "$name" "${current:-installed}" "${latest:-available}"
    count=$((count + 1))
  done <<< "$output"
  [ "$count" -gt 0 ] || pending_update_note "none detected before this step"
  printf '\n'
}

show_pending_brew_updates() {
  local output line name old new count=0
  pending_updates_begin "brew outdated --verbose"
  if [ "$UPDATE_ALL_DRY_RUN" = 1 ] && [ "${UPDATE_ALL_DRY_RUN_PROBES:-0}" != 1 ]; then
    pending_update_note "dry-run: skipped remote network probe (set UPDATE_ALL_DRY_RUN_PROBES=1 to query)"
    printf '\n'; return 0
  fi
  output="$(_ua_probe_bounded brew outdated --verbose || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="$(printf '%s\n' "$line" | awk '{print $1}')"
    old="$(printf '%s\n' "$line" | sed -n 's/^[^ ]* (\([^)]*\)).*/\1/p')"
    new="$(printf '%s\n' "$line" | sed -n 's/.*< \(.*\)$/\1/p')"
    if [ -n "$name" ] && [ -n "$old" ] && [ -n "$new" ]; then
      pending_update_line "$name" "$old" "$new"
    else
      pending_update_note "$line"
    fi
    count=$((count + 1))
  done <<< "$output"
  [ "$count" -gt 0 ] || pending_update_note "none detected before this step"
  printf '\n'
}

coverage_item() {
  local title="$1" command_name="$2" action="$3"
  if command -v "$command_name" >/dev/null 2>&1; then
    printf '   %b%-24s%b %b%-11s%b %s\n' "$C_LABEL" "$title" "$C_RESET" "$C_OK" "will check" "$C_RESET" "$action"
  else
    printf '   %b%-24s%b %b%-11s%b %s\n' "$C_LABEL" "$title" "$C_RESET" "$C_TIP" "skip" "$C_RESET" "$command_name not installed"
  fi
}

coverage_manual_item() {
  printf '   %b%-24s%b %b%-11s%b %s\n' "$C_LABEL" "$1" "$C_RESET" "$C_WARN" "manual" "$C_RESET" "$2"
}

show_update_coverage_preflight() {
  local headless_tag=""
  [ "$_ua_env_discovered" = 1 ] || discover_environment
  [ "$_ua_is_headless" = 1 ] && headless_tag=", headless"
  banner "COVERAGE"
  section "coverage preflight"
  tool_card "coverage" "update coverage" "current run" "installed tools only"
  printf '   %b%-15s%b %s (pkg manager: %s%s)\n' "$C_LABEL" "host / os" "$C_RESET" "$_ua_distro_name" "$_ua_sys_pkg_mgr" "$headless_tag"
  printf '   %bPlain English:%b update-all updates the common workstation things it can safely detect.\n' "$C_HEADER" "$C_RESET"
  printf '   It calls first-party/package-manager commands; it never invents a private updater or silently edits projects.\n'
  printf '   Secret safety: updater logs are redacted for common token/key shapes, and internal shell calls avoid shell startup files.\n\n'

  case "$_ua_sys_pkg_mgr" in
    rpm-ostree)   coverage_item "rpm-ostree" "rpm-ostree" "immutable OS image updates" ;;
    apt-get)      coverage_item "apt / dpkg" "apt-get" "OS packages and package database health" ;;
    dnf5|dnf|yum) coverage_item "$_ua_sys_pkg_mgr" "$_ua_sys_pkg_mgr" "Fedora/RHEL OS packages" ;;
    pacman)       coverage_item "pacman" "pacman" "Arch Linux OS packages (non-AUR)" ;;
    zypper)       coverage_item "zypper" "zypper" "openSUSE OS packages" ;;
    apk)          coverage_item "apk" "apk" "Alpine Linux OS packages" ;;
    xbps-install) coverage_item "xbps" "xbps-install" "Void Linux OS packages" ;;
    *)            coverage_item "apt / dpkg" "apt-get" "OS packages and package database health" ;;
  esac
  coverage_item "snap apps" "snap" "snap refresh"
  coverage_item "flatpak apps" "flatpak" "flatpak update"
  coverage_item "Node runtime" "update-node" "user-local Node runtime when update-node exists"
  [ "$_ua_has_mise" = 1 ] && coverage_item "mise runtimes" "mise" "mise upgrade"
  [ "$_ua_has_volta" = 1 ] && coverage_item "Volta shims" "volta" "pinned Node toolchain status"
  coverage_item "Corepack / pnpm / yarn" "corepack" "package-manager shims and activated managers"
  coverage_item "npm globals" "npm" "npm itself and globally installed npm CLIs"
  coverage_item "Claude Code CLI" "claude" "claude update"
  coverage_item "Codex CLI" "codex" "codex update"
  coverage_item "Homebrew/Linuxbrew" "brew" "brew update, tap trust preflight, brew upgrade"
  coverage_item "Bun runtime" "bun" "bun upgrade"
  [ "$_ua_has_deno" = 1 ] && coverage_item "Deno runtime" "deno" "deno upgrade"
  coverage_item "uv tools" "uv" "uv self/tool updates"
  coverage_item "pipx apps" "pipx" "pipx upgrade-all"
  coverage_item "Rust toolchains" "rustup" "rustup update"
  coverage_item "Cargo-installed CLIs" "cargo-install-update" "cargo install-update -a when helper exists"
  coverage_item "GitHub extensions" "gh" "gh extension upgrade --all"
  if [ "$_ua_has_code" = 1 ] || [ "$_ua_has_codium" = 1 ] || [ "$_ua_has_code_insiders" = 1 ]; then
    [ "$_ua_has_code" = 1 ] && coverage_item "VS Code extensions" "code" "code --update-extensions"
    [ "$_ua_has_codium" = 1 ] && coverage_item "VSCodium extensions" "codium" "codium --update-extensions"
    [ "$_ua_has_code_insiders" = 1 ] && coverage_item "VS Code Insiders ext" "code-insiders" "code-insiders --update-extensions"
  else
    printf '   %b%-24s%b %b%-11s%b %s\n' "$C_LABEL" "editor extensions" "$C_RESET" "$C_TIP" "skip" "$C_RESET" "code/codium not installed"
  fi
  coverage_item "Linux firmware" "fwupdmgr" "fwupdmgr update, opt-in / prompt-gated"

  printf '\n'
  coverage_manual_item "project repositories" "manual by design; each repo needs tests and rollback context"
  coverage_manual_item "active agent runtimes" "manual by design; Hermes/OpenClaw-style stacks should not be surprise-upgraded"
  coverage_manual_item "containers/images" "manual by design; updating images can break running services"
  coverage_manual_item "conda environments" "manual by design; environment solves are project-specific"
  coverage_manual_item "shell profiles" "never sourced for update logic; do not store raw secrets in .bashrc"
  coverage_manual_item "AUR PKGBUILDs" "manual by design; community build scripts require human review"
  coverage_manual_item "large LLM weights" "manual by design; downloads are large and workload-specific"

  track "coverage preflight" 0 "" "" "installed safe surfaces are updated; project-specific stacks stay explicit"
}

choice_is_yes() {
  case "${1:-no}" in yes) return 0 ;; *) return 1 ;; esac
}

ask_optional_choice() {
  local prompt="$1" answer
  [ "$UPDATE_ALL_DRY_RUN" = 1 ] && return 1
  if [ "${UPDATE_ALL_NONINTERACTIVE:-0}" = 1 ] || [ "${UPDATE_ALL_NON_INTERACTIVE:-0}" = 1 ]; then
    printf '%bSKIP%b %s (non-interactive; defaulting to no).\n' "$C_WARN" "$C_RESET" "$prompt"
    return 1
  fi
  if choice_is_yes "$_ua_answer_all_choice"; then
    printf '%bALL%b %s -> yes\n' "$C_OK" "$C_RESET" "$prompt"
    return 0
  fi
  if [ ! -t 0 ]; then
    printf '%bSKIP%b %s requires an interactive terminal. Defaulting to no.\n' "$C_WARN" "$C_RESET" "$prompt"
    return 1
  fi

  printf '%b?%b %s [y/n/a/all] ' "$C_WARN" "$C_RESET" "$prompt"
  IFS= read -r answer || return 1
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    n|N|no|NO|No) return 1 ;;
    a|A|all|ALL|All)
      _ua_answer_all_choice="yes"
      printf '%bALL%b all mode: yes to every remaining optional question.\n' "$C_OK" "$C_RESET"
      return 0 ;;
    *) return 1 ;;
  esac
}

collect_optional_choices() {
  local i cli_all=0 nonint=0
  [ "$_ua_env_discovered" = 1 ] || discover_environment
  choice_is_yes "$_ua_answer_all_choice" && cli_all=1
  if [ "${UPDATE_ALL_NONINTERACTIVE:-0}" = 1 ] || [ "${UPDATE_ALL_NON_INTERACTIVE:-0}" = 1 ]; then
    nonint=1
  fi

  banner "CHOICES"
  section "optional choices preflight"
  if [ "$UPDATE_ALL_DRY_RUN" = 1 ]; then
    printf '   %bDry-run:%b previewing optional prompt-gated steps without asking for input.\n' "$C_HEADER" "$C_RESET"
    printf '   Live runs collect these choices here, before the update sweep starts.\n\n'
  elif [ "$cli_all" = 1 ]; then
    printf '   %bAll (-a/--all):%b safe cleanup choices auto-approved with zero interactive prompts.\n' "$C_OK" "$C_RESET"
    printf '   Firmware stays strictly opt-in via --firmware so hardware is never flashed unexpectedly.\n\n'
  elif [ "$nonint" = 1 ]; then
    printf '   %bNon-interactive:%b optional cleanup and firmware choices default to no.\n\n' "$C_HEADER" "$C_RESET"
  else
    printf '   %bAnswer the optional risky or cleanup questions now.%b\n' "$C_HEADER" "$C_RESET"
    printf '   Type %ba%b or %ball%b once to answer yes to every remaining optional question in this run.\n' "$C_CMD" "$C_RESET" "$C_CMD" "$C_RESET"
    printf '   update-all will then run the update sweep without stopping for more prompts.\n\n'
  fi

  if [ "$_ua_has_fwupd" = 1 ]; then
    if [ "$UPDATE_ALL_DRY_RUN" = 1 ]; then
      _ua_firmware_choice="yes"
      printf '%bDRY-RUN%b firmware updates will be previewed.\n' "$C_WARN" "$C_RESET"
    elif [ "${UPDATE_ALL_FIRMWARE_FLAG:-0}" = 1 ]; then
      _ua_firmware_choice="yes"
      printf '%bOPT-IN%b firmware updates enabled via --firmware.\n' "$C_OK" "$C_RESET"
    elif [ "$cli_all" = 1 ]; then
      _ua_firmware_choice="no"
      printf '%bSAFE%b firmware updates skipped under --all (pass --firmware to opt in).\n' "$C_TIP" "$C_RESET"
    elif ask_optional_choice "Check and apply firmware updates during this run? This may require vendor trust prompts or a reboot."; then
      _ua_firmware_choice="yes"
    else
      _ua_firmware_choice="no"
    fi
  fi

  if [ "$_ua_has_brew" = 1 ] && declare -F inspect_brew_tap_trust >/dev/null 2>&1; then
    inspect_brew_tap_trust
    if [ "${#_ua_brew_taps[@]}" -gt 0 ]; then
      pending_updates_begin "brew tap trust preflight"
      printf '  %bWhat this checks:%b extra Homebrew tap repositories outside the default Homebrew set.\n' "$C_HEADER" "$C_RESET"
      printf '  %bPlain English:%b an Untrusted tap is not automatically malware and it is not an expired license.\n' "$C_HEADER" "$C_RESET"
      printf '  It means Homebrew cannot prove the tap belongs to a trusted source. A tap can define install and update code, so it deserves a pause.\n'
      printf '  %bGold standard:%b remove unused or unrecognized untrusted taps; keep one only when you intentionally need it and trust its source.\n' "$C_HEADER" "$C_RESET"
      for ((i = 0; i < ${#_ua_brew_taps[@]}; i++)); do
        if declare -F print_brew_tap_insight >/dev/null 2>&1; then
          print_brew_tap_insight "${_ua_brew_taps[$i]}" "${_ua_brew_sources[$i]}" "${_ua_brew_installed[$i]}"
        fi
        if [ "$UPDATE_ALL_DRY_RUN" = 1 ]; then
          _ua_brew_untap_choices[i]="yes"
          printf '%bDRY-RUN%b untap command will be previewed for %s.\n' "$C_WARN" "$C_RESET" "${_ua_brew_taps[$i]}"
        elif [ "$cli_all" = 1 ]; then
          _ua_brew_untap_choices[i]="no"
          printf '%bKEEP%b %s left installed under --all (review taps interactively to untap).\n' "$C_WARN" "$C_RESET" "${_ua_brew_taps[$i]}"
        elif ask_optional_choice "Untap ${_ua_brew_taps[$i]} before brew update? Recommended yes if unused or unfamiliar; no if you intentionally rely on it."; then
          _ua_brew_untap_choices[i]="yes"
        fi
      done
      printf '\n'
    else
      pending_update_note "brew tap trust: no untrusted taps reported before this run"
    fi
  fi

  if [ "$_ua_has_apt" = 1 ] || [ "$_ua_has_dnf" = 1 ] || [ "$_ua_has_pacman" = 1 ] || [ "$_ua_has_zypper" = 1 ] || [ "$_ua_has_apk" = 1 ] || [ "$_ua_has_xbps" = 1 ]; then
    if declare -F cleanup_question >/dev/null 2>&1; then
      if [ "$UPDATE_ALL_DRY_RUN" = 1 ]; then cleanup_question preview
      elif [ "$cli_all" = 0 ] && [ "$nonint" = 0 ]; then cleanup_question
      fi
    fi
    if [ "$UPDATE_ALL_DRY_RUN" = 1 ]; then
      _ua_apt_cleanup_choice="yes"
      printf '%bDRY-RUN%b %s cleanup commands will be previewed.\n' "$C_WARN" "$C_RESET" "$_ua_sys_pkg_mgr"
    elif [ "$cli_all" = 1 ]; then
      _ua_apt_cleanup_choice="yes"
      printf '%bALL%b %s package cleanup -> yes\n' "$C_OK" "$C_RESET" "$_ua_sys_pkg_mgr"
    elif ask_optional_choice "Run ${_ua_sys_pkg_mgr} cleanup at the end? This can purge unneeded packages and clear package caches."; then
      _ua_apt_cleanup_choice="yes"
    else
      _ua_apt_cleanup_choice="no"
    fi
  else
    _ua_apt_cleanup_choice="no"
  fi

  if declare -F workstation_cleanup_question >/dev/null 2>&1; then
    if [ "$UPDATE_ALL_DRY_RUN" = 1 ]; then workstation_cleanup_question preview
    elif [ "$cli_all" = 0 ] && [ "$nonint" = 0 ]; then workstation_cleanup_question
    fi
  fi
  if [ "$UPDATE_ALL_DRY_RUN" = 1 ]; then
    _ua_workstation_cleanup_choice="yes"
    printf '%bDRY-RUN%b workstation cache cleanup commands will be previewed.\n' "$C_WARN" "$C_RESET"
  elif [ "$cli_all" = 1 ]; then
    _ua_workstation_cleanup_choice="yes"
    printf '%bALL%b workstation cache cleanup -> yes\n' "$C_OK" "$C_RESET"
  elif ask_optional_choice "Run workstation cache cleanup at the end? This removes rebuildable caches and old update leftovers."; then
    _ua_workstation_cleanup_choice="yes"
  else
    _ua_workstation_cleanup_choice="no"
  fi

  recompute_needs_sudo
  if [ "$UPDATE_ALL_DRY_RUN" = 1 ]; then
    printf '\n%bOK%b Optional dry-run previews saved. Starting the command preview now.\n' "$C_OK" "$C_RESET"
  else
    printf '\n%bOK%b Optional choices saved. Starting the update sweep now.\n' "$C_OK" "$C_RESET"
  fi
}
