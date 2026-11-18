#!/usr/bin/env bash
# lib/colors_and_glyphs.sh - Color palette, monochrome glyphs, banners, and tool cards.
# Bash 3.2+ parse-compatible; sourced by bin/update-all.
# Cross-module palette and glyph globals are consumed by bin/update-all and sibling libs.
# shellcheck disable=SC2034,SC2154

glyphs_init() {
  local locale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  _ua_utf8=0
  if [ "${UPDATE_ALL_ASCII:-0}" != "1" ]; then
    case "$locale" in
      *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*)
        _ua_utf8=1
        ;;
    esac
  fi

  if [ "$_ua_utf8" -eq 1 ]; then
    G_UPDATED="↗"
    G_OK="✓"
    G_UNCHANGED="="
    G_FAIL="✗"
    G_SKIP="·"
    G_WARN="▲"
    G_SAFETY="◆"
    G_ARROW="→"
    G_GUTTER="│"
    G_CARD="▌"
    G_LIVE="●"
    G_IDLE="○"
    G_BAR_FULL="█"
    G_BAR_EMPTY="░"
    G_RULE="─"
    G_DOCK_RULE="━"
  else
    G_UPDATED="^"
    G_OK="+"
    G_UNCHANGED="="
    G_FAIL="x"
    G_SKIP="."
    G_WARN="!"
    G_SAFETY="*"
    G_ARROW="->"
    G_GUTTER="|"
    G_CARD=">"
    G_LIVE="*"
    G_IDLE="o"
    G_BAR_FULL="#"
    G_BAR_EMPTY="-"
    G_RULE="-"
    G_DOCK_RULE="="
  fi
}

color_init() {
  local ncolors=0
  glyphs_init

  if [ "${UPDATE_ALL_COLOR:-1}" = "1" ] && [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
    if command -v tput >/dev/null 2>&1; then
      ncolors="$(tput colors 2>/dev/null || echo 0)"
    else
      case "${TERM:-}" in
        *256color*|*truecolor*|*direct*) ncolors=256 ;;
        ""|dumb) ncolors=0 ;;
        *) ncolors=8 ;;
      esac
    fi
  fi

  case "${ncolors:-0}" in
    *[!0-9]*|"") ncolors=0 ;;
  esac

  if [ "$ncolors" -ge 256 ]; then
    _ua_color_depth=256
    C_RESET=$'\033[0m'
    C_OK=$'\033[38;5;35m'
    C_WARN=$'\033[38;5;214m'
    C_BAD=$'\033[38;5;203m'
    C_CMD=$'\033[38;5;222m'
    C_TIP=$'\033[38;5;245m'
    C_HEADER=$'\033[1m\033[38;5;231m'
    C_LABEL=$'\033[38;5;222m'
    C_FRAME=$'\033[38;5;240m'
    C_ORANGE=$'\033[1m\033[38;5;214m'
    C_UNIT=$'\033[1m\033[38;5;215m'
    C_NEON="$C_ORANGE"
    C_PURPOSE=$'\033[38;5;109m'
    C_VERSION_LABEL=$'\033[38;5;250m'
    C_VERSION_BEFORE_LABEL=$'\033[38;5;66m'
    C_VERSION_AFTER_LABEL=$'\033[38;5;109m'
    C_VERSION_BEFORE=$'\033[1m\033[38;5;159m'
    C_VERSION_AFTER=$'\033[1m\033[38;5;121m'
    C_PATH=$'\033[38;5;110m'
    C_RESULT=$'\033[38;5;179m'
    C_LOG=$'\033[38;5;244m'
    C_APT_SOURCE=$'\033[38;5;67m'
    C_APT_PROGRESS=$'\033[38;5;215m'
    C_BINARY=$'\033[38;5;30m'
    C_CLEANUP_WORD=$'\033[38;5;230m'
    C_CLEANUP_PUNCT=$'\033[38;5;223m'
    C_SEC_CRIT=$'\033[1m\033[38;5;203m'
    C_BAR_FILL=$'\033[38;5;214m'
    C_BAR_BG=$'\033[38;5;240m'
  elif [ "$ncolors" -ge 8 ]; then
    _ua_color_depth=8
    C_RESET=$'\033[0m'
    C_OK=$'\033[32m'
    C_WARN=$'\033[33m'
    C_BAD=$'\033[31m'
    C_CMD=$'\033[33m'
    C_TIP=$'\033[2m'
    C_HEADER=$'\033[1m'
    C_LABEL=$'\033[33m'
    C_FRAME=$'\033[2m'
    C_ORANGE=$'\033[1m\033[33m'
    C_UNIT="$C_ORANGE"
    C_NEON="$C_ORANGE"
    C_PURPOSE=$'\033[36m'
    C_VERSION_LABEL=$'\033[1m\033[36m'
    C_VERSION_BEFORE_LABEL=$'\033[36m'
    C_VERSION_AFTER_LABEL=$'\033[1m\033[36m'
    C_VERSION_BEFORE=$'\033[1m\033[33m'
    C_VERSION_AFTER=$'\033[1m\033[32m'
    C_PATH=$'\033[36m'
    C_RESULT=$'\033[35m'
    C_LOG=$'\033[2m'
    C_APT_SOURCE=$'\033[36m'
    C_APT_PROGRESS=$'\033[33m'
    C_BINARY=$'\033[36m'
    C_CLEANUP_WORD=$'\033[33m'
    C_CLEANUP_PUNCT=$'\033[2m\033[33m'
    C_SEC_CRIT=$'\033[1m\033[31m'
    C_BAR_FILL=$'\033[33m'
    C_BAR_BG=$'\033[2m'
  else
    _ua_color_depth=0
    C_RESET=""; C_OK=""; C_WARN=""; C_BAD=""
    C_CMD=""; C_TIP=""; C_HEADER=""; C_LABEL=""; C_FRAME=""
    C_ORANGE=""; C_NEON=""; C_UNIT=""; C_PURPOSE=""
    C_VERSION_LABEL=""; C_VERSION_BEFORE_LABEL=""; C_VERSION_AFTER_LABEL=""
    C_VERSION_BEFORE=""; C_VERSION_AFTER=""; C_PATH=""; C_RESULT=""; C_LOG=""
    C_APT_SOURCE=""; C_APT_PROGRESS=""; C_BINARY=""
    C_CLEANUP_WORD=""; C_CLEANUP_PUNCT=""
    C_SEC_CRIT=""; C_BAR_FILL=""; C_BAR_BG=""
  fi
}

ua_rule_line() {
  local width="${1:-}" char="${2:-${G_RULE:-─}}" spaces
  if [ -z "$width" ]; then
    if declare -F tui_rule_width >/dev/null 2>&1; then
      width="$(tui_rule_width)"
    else
      width=88
    fi
  fi
  case "$width" in
    *[!0-9]*|"") width=88 ;;
  esac
  [ "$width" -gt 0 ] || return 0
  printf -v spaces '%*s' "$width" ''
  printf '%s' "${spaces// /$char}"
}

intro() {
  local update_binary all_binary divider_padding

  printf '\n'
  printf '%b ██╗   ██╗██████╗ ██████╗  █████╗ ████████╗███████╗      █████╗ ██╗     ██╗     %b\n' "$C_ORANGE" "$C_RESET"
  printf '%b ██║   ██║██╔══██╗██╔══██╗██╔══██╗╚══██╔══╝██╔════╝     ██╔══██╗██║     ██║     %b\n' "$C_ORANGE" "$C_RESET"
  printf '%b ██║   ██║██████╔╝██║  ██║███████║   ██║   █████╗       ███████║██║     ██║     %b\n' "$C_ORANGE" "$C_RESET"
  printf '%b ██║   ██║██╔═══╝ ██║  ██║██╔══██║   ██║   ██╔══╝       ██╔══██║██║     ██║     %b\n' "$C_ORANGE" "$C_RESET"
  printf '%b ╚██████╔╝██║     ██████╔╝██║  ██║   ██║   ███████╗     ██║  ██║███████╗███████╗%b\n' "$C_ORANGE" "$C_RESET"
  printf '%b  ╚═════╝ ╚═╝     ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝     ╚═╝  ╚═╝╚══════╝╚══════╝%b\n' "$C_ORANGE" "$C_RESET"

  update_binary='01110101  01110000  01100100  01100001  01110100  01100101'
  all_binary='01100001  01101100  01101100'
  divider_padding=$(( (${#update_binary} - ${#all_binary}) / 2 ))

  printf '      %b%s%b\n' "$C_BINARY" "$update_binary" "$C_RESET"
  printf '%*s%b%s%b\n' "$((6 + divider_padding))" '' "$C_BINARY" "$all_binary" "$C_RESET"
  printf '\n'
}

banner() {
  local label="$1" rendered="" line rule2
  printf '\n'
  if command -v figlet >/dev/null 2>&1; then
    rendered="$(figlet -f future "$label" 2>/dev/null || true)"
    if [ -z "$rendered" ]; then
      rendered="$(figlet -f pagga "$label" 2>/dev/null || true)"
    fi
  fi

  if [ -n "$rendered" ]; then
    while IFS= read -r line; do
      printf '%b%s%b\n' "$C_HEADER" "$line" "$C_RESET"
    done <<< "$rendered"
  else
    rule2="${G_RULE:-─}${G_RULE:-─}"
    printf '%b%s %s %s%b\n' "$C_HEADER" "$rule2" "$label" "$rule2" "$C_RESET"
  fi
}

section() {
  local label="$1" heading
  heading="$(printf '%s' "$label" | tr '[:lower:]' '[:upper:]')"
  printf '\n'
  if [ "${_ua_utf8:-1}" -eq 1 ]; then
    printf '%b╾────%b %b%s%b %b────╼%b\n' "$C_FRAME" "$C_RESET" "$C_UNIT" "$heading" "$C_RESET" "$C_FRAME" "$C_RESET"
  else
    printf '%b----%b %b%s%b %b----%b\n' "$C_FRAME" "$C_RESET" "$C_UNIT" "$heading" "$C_RESET" "$C_FRAME" "$C_RESET"
  fi
  printf '\n'
}

package_color_hash() {
  local key="$1" i char=0 len hash=0
  len="${#key}"
  for ((i = 0; i < len; i++)); do
    printf -v char '%d' "'${key:i:1}"
    hash=$(( (hash * 33 + char) & 0x7fffffff ))
  done
  printf '%s' "$((hash % 7))"
}

styled_package_color() {
  if [ "${_ua_color_depth:-0}" -eq 0 ]; then
    return 0
  fi
  local style_key
  style_key="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  case "$style_key" in
    apt|dnf|rpm-ostree|pacman|zypper|apk|xbps)
      printf '%s' "$C_ORANGE" ;;
    brew)
      printf '%s' "$C_NEON" ;;
    node|deno)
      printf '%s' "$C_PATH" ;;
    corepack|mise|volta|fnm)
      printf '%s' "$C_APT_PROGRESS" ;;
    pnpm)
      printf '%s' "$C_RESULT" ;;
    *npm*)
      printf '%s' "$C_VERSION_AFTER" ;;
    yarn)
      printf '%s' "$C_PURPOSE" ;;
    uv)
      printf '%s' "$C_LABEL" ;;
    pipx)
      printf '%s' "$C_APT_PROGRESS" ;;
    rustup|cargo)
      printf '%s' "$C_RESULT" ;;
    gh|safety)
      printf '%s' "$C_WARN" ;;
    dpkg|snap|flatpak|codex|claude|ports)
      printf '%s' "$C_VERSION_BEFORE" ;;
    cleanup|cache|trash)
      printf '%s' "$C_CLEANUP_WORD" ;;
    *)
      case "$(package_color_hash "$style_key")" in
        0) printf '%s' "$C_VERSION_LABEL" ;;
        1) printf '%s' "$C_PURPOSE" ;;
        2) printf '%s' "$C_PATH" ;;
        3) printf '%s' "$C_RESULT" ;;
        4) printf '%s' "$C_APT_PROGRESS" ;;
        5) printf '%s' "$C_NEON" ;;
        *) printf '%s' "$C_WARN" ;;
      esac
      ;;
  esac
}

styled_package_name() {
  local name="$1" width="${2:-0}" color
  color="$(styled_package_color "$name")"

  if [ "${width:-0}" -gt 0 ]; then
    printf '%b%-*s%b' "$color" "$width" "$name" "$C_RESET"
  else
    printf '%b%s%b' "$color" "$name" "$C_RESET"
  fi
}

describe_tool() {
  case "$1" in
    dpkg) printf 'Debian package database integrity check; catches interrupted installs before apt runs.' ;;
    apt) printf 'Ubuntu/Debian system package manager; updates OS packages and security fixes.' ;;
    dnf) printf 'Fedora/RHEL system package manager; updates OS packages and security fixes.' ;;
    rpm-ostree) printf 'Atomic Fedora/Silverblue OS updater; stages immutable system updates for the next reboot.' ;;
    pacman) printf 'Arch Linux system package manager; syncs repositories and updates installed OS packages.' ;;
    zypper) printf 'openSUSE system package manager; refreshes repositories and applies OS updates.' ;;
    apk) printf 'Alpine Linux system package manager; updates repository indexes and installed packages.' ;;
    xbps) printf 'Void Linux system package manager; syncs repositories and upgrades installed packages.' ;;
    snap) printf 'Canonical app package system; refreshes installed snap applications.' ;;
    flatpak) printf 'Sandboxed desktop app package system; updates installed Flatpak apps.' ;;
    node) printf 'JavaScript runtime used by npm, Codex, Claude Code, and many developer CLIs.' ;;
    mise) printf 'Polyglot developer runtime manager; updates managed language runtimes and plugins.' ;;
    volta) printf 'JavaScript toolchain manager; keeps pinned Node, npm, and CLI shims up to date.' ;;
    fnm) printf 'Fast Node Manager; manages installed Node.js versions cleanly.' ;;
    deno) printf 'TypeScript and JavaScript runtime; updated through its first-party deno upgrade command.' ;;
    corepack) printf 'Node-shipped package-manager shim that activates pnpm/yarn without manual installs.' ;;
    pnpm) printf 'Fast JavaScript package manager with a content-addressable store that saves disk space across projects.' ;;
    yarn) printf 'JavaScript dependency manager used for project installs, workspaces, lock files, and reproducible package graphs.' ;;
    bun) printf 'JavaScript runtime, package manager, and test runner; updated with Bun'\''s first-party upgrade command.' ;;
    npm) printf 'Default Node.js package manager; updates npm itself and globally installed JavaScript command-line tools.' ;;
    npm-globals) printf 'Updates globally installed npm CLIs already present on PATH.' ;;
    claude) printf 'Anthropic terminal assistant for codebase work; updated through its first-party claude update command.' ;;
    codex) printf 'OpenAI local coding-agent CLI; updated through its first-party codex update command.' ;;
    hermes) printf 'Skipped on purpose: active agent runtimes should not be surprise-upgraded mid-workflow.' ;;
    brew) printf 'Homebrew package manager for Linux/macOS developer tools and formulae.' ;;
    uv) printf 'Fast Python package and tool manager; upgraded by its owning package manager here.' ;;
    pipx) printf 'Installs and upgrades isolated Python CLI applications.' ;;
    rustup) printf 'Rust toolchain manager; updates rustc/cargo toolchains when installed.' ;;
    cargo-installed) printf 'Rust command-line tools installed with cargo; updated only when the cargo-install-update helper already exists.' ;;
    gh) printf 'GitHub official command-line tool for pull requests, issues, repositories, auth, and extensions.' ;;
    code) printf 'Editor extensions for Visual Studio Code-compatible CLIs; updates extensions, not editor settings or projects.' ;;
    fwupd) printf 'Linux firmware update service; checks vendor firmware updates and asks before applying them.' ;;
    safety) printf 'Pre-update workstation safety check; verifies disk space, package locks, and security posture.' ;;
    ports) printf 'Local listening-port inspection; highlights exposed network services on this workstation.' ;;
    coverage) printf 'Preflight coverage map that explains what update-all will handle and what remains intentionally manual.' ;;
    cleanup) printf 'Removes stale package-manager caches, disabled update leftovers, and known rebuildable workstation caches.' ;;
    *) printf 'Updater step.' ;;
  esac
}

tool_card() {
  local key="$1" title="$2" version="${3:-}" package="${4:-}"
  local desc heading
  desc="$(describe_tool "$key")"
  heading="$(printf '%s' "$title" | tr '[:lower:]' '[:upper:]')"
  if [ -z "$version" ] && declare -F version_of >/dev/null 2>&1; then
    version="$(version_of "$key" 2>/dev/null || true)"
  fi
  if [ -z "$version" ]; then
    case "$key" in
      cleanup) version="post-update maintenance" ;;
      *) version="not installed" ;;
    esac
  fi

  printf '   %b%s %s%b\n' "$C_UNIT" "${G_CARD:-▌}" "$heading" "$C_RESET"
  [ -n "$package" ] && printf '   %b%-15s%b %s\n' "$C_LABEL" "package" "$C_RESET" "$(styled_package_name "$package")"
  version_rows "version before" "$version" "$C_VERSION_BEFORE"
  printf '   %b%-15s%b %b%s%b\n' "$C_PURPOSE" "purpose" "$C_RESET" "$C_PURPOSE" "$desc" "$C_RESET"
  printf '\n'
}

version_rows() {
  local label="$1" value="${2:-}" color="$3" label_color path rest
  label_color="$C_VERSION_LABEL"
  case "$label" in
    "version before") label_color="$C_VERSION_BEFORE_LABEL" ;;
    "version after") label_color="$C_VERSION_AFTER_LABEL" ;;
  esac
  [ -n "$value" ] || value="-"
  case "$value" in
    /*)
      path="${value%% *}"
      rest="${value#"$path"}"
      rest="${rest# }"
      [ -n "$rest" ] || rest="installed"
      if [ "$label" = "version before" ]; then
        printf '   %b%-15s%b %b%s%b\n' "$label_color" "$label" "$C_RESET" "$color" "$rest" "$C_RESET"
        printf '   %b%-15s%b %b%s%b\n' "$C_LABEL" "path" "$C_RESET" "$C_PATH" "$path" "$C_RESET"
      else
        printf '   %b%-15s%b %b%s%b\n' "$C_LABEL" "path" "$C_RESET" "$C_PATH" "$path" "$C_RESET"
        printf '   %b%-15s%b %b%s%b\n' "$label_color" "$label" "$C_RESET" "$color" "$rest" "$C_RESET"
      fi
      ;;
    *)
      printf '   %b%-15s%b %b%s%b\n' "$label_color" "$label" "$C_RESET" "$color" "$value" "$C_RESET"
      ;;
  esac
}

tool_version_after() {
  local version="${1:-}" status="${2:-OK}" color
  [ -n "$version" ] || version="-"
  case "$status" in
    UPDATED|OK) color="$C_VERSION_AFTER" ;;
    UNCHANGED|SKIP) color="$C_VERSION_AFTER" ;;
    FAIL) color="$C_BAD" ;;
    *) color="$C_VERSION_AFTER" ;;
  esac
  version_rows "version after" "$version" "$color"
}

tool_result() {
  local status="$1" note="${2:-}" color
  case "$status" in
    UPDATED|OK) color="$C_OK" ;;
    UNCHANGED|SKIP) color="$C_RESULT" ;;
    FAIL) color="$C_BAD" ;;
    *) color="$C_RESULT" ;;
  esac
  printf '   %b%-15s%b %b%s%b\n' "$C_LABEL" "result" "$C_RESET" "$color" "$status" "$C_RESET"
  [ -z "$note" ] || printf '   %b%-15s%b %b%s%b\n' "$C_LABEL" "note" "$C_RESET" "$C_TIP" "$note" "$C_RESET"
}

pending_updates_begin() {
  local source="$1"
  printf '   %b%-15s%b %b%s%b\n' "$C_LABEL" "pending updates" "$C_RESET" "$C_HEADER" "$source" "$C_RESET"
}

pending_update_line() {
  local name="$1" old="$2" new="$3"
  printf '      %s %b%s%b %b->%b %b%s%b\n' \
    "$(styled_package_name "$name" 30)" \
    "$C_VERSION_BEFORE" "$old" "$C_RESET" \
    "$C_FRAME" "$C_RESET" \
    "$C_VERSION_AFTER" "$new" "$C_RESET"
}

pending_update_note() {
  printf '      %b%s%b\n' "$C_TIP" "$1" "$C_RESET"
}

glyphs_init
