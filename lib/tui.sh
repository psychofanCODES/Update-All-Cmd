#!/usr/bin/env bash
# lib/tui.sh - Persistent DECSTBM 2-row TUI dock, kinetic watcher, and EWMA ETA store.
# Bash 3.2+ parse-compatible; sourced by bin/update-all.
# Cross-module TUI state and palette globals are shared with bin/update-all and lib/runner.sh.
# shellcheck disable=SC2034,SC2154

UPDATE_ALL_ANIM="${UPDATE_ALL_ANIM:-1}"
UPDATE_ALL_DRY_RUN="${UPDATE_ALL_DRY_RUN:-0}"
UPDATE_ALL_BAR="${UPDATE_ALL_BAR:-bottom}"
UPDATE_ALL_WATCHER="${UPDATE_ALL_WATCHER:-hybrid}"
UPDATE_ALL_TIMINGS_FILE="${UPDATE_ALL_TIMINGS_FILE:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/update-all/timings.tsv}"

_ua_term_rows="${_ua_term_rows:-24}"; _ua_term_cols="${_ua_term_cols:-80}"
_ua_tui_compact="${_ua_tui_compact:-0}"; _ua_tui_min_size_warned="${_ua_tui_min_size_warned:-0}"
_ua_tui_active="${_ua_tui_active:-0}"; _ua_tui_paused="${_ua_tui_paused:-0}"
_ua_tui_inline_visible="${_ua_tui_inline_visible:-0}"; _ua_tui_phase="${_ua_tui_phase:-INIT}"
_ua_tui_step_index="${_ua_tui_step_index:-0}"; _ua_tui_step_total="${_ua_tui_step_total:-0}"
_ua_tui_step_key="${_ua_tui_step_key:-}"; _ua_tui_step_label="${_ua_tui_step_label:-}"
_ua_tui_step_start_s="${_ua_tui_step_start_s:-0}"; _ua_tui_pct="${_ua_tui_pct:-0}"
_ua_tui_eta_str="${_ua_tui_eta_str:-calibrating...}"
_ua_tui_cnt_updated="${_ua_tui_cnt_updated:-0}"; _ua_tui_cnt_ok="${_ua_tui_cnt_ok:-0}"
_ua_tui_cnt_unchanged="${_ua_tui_cnt_unchanged:-0}"; _ua_tui_cnt_skip="${_ua_tui_cnt_skip:-0}"
_ua_tui_cnt_fail="${_ua_tui_cnt_fail:-0}"
_ua_timings_loaded="${_ua_timings_loaded:-0}"; _ua_timings_has_history="${_ua_timings_has_history:-0}"
_ua_timing_idx=-1; _ua_st_plain=""; _ua_st_col=""

if ! declare -p _ua_timing_keys >/dev/null 2>&1; then declare -a _ua_timing_keys=(); fi
if ! declare -p _ua_timing_secs >/dev/null 2>&1; then declare -a _ua_timing_secs=(); fi
if ! declare -p _ua_planned_keys >/dev/null 2>&1; then declare -a _ua_planned_keys=(); fi
if ! declare -p _ua_done_keys >/dev/null 2>&1; then declare -a _ua_done_keys=(); fi

anim_enabled() {
  [ "${UPDATE_ALL_ANIM:-1}" = "1" ] && [ "${UPDATE_ALL_DRY_RUN:-0}" = "0" ] \
    && [ -t 1 ] && [ "${CI:-}" != "true" ] && [ "${CI:-}" != "1" ] \
    && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ]
}

_tui_now_s() {
  local __out="$1"
  if [ "${BASH_VERSINFO[0]:-3}" -ge 5 ] || { [ "${BASH_VERSINFO[0]:-3}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 2 ]; }; then
    printf -v "$__out" '%(%s)T' -1
  else
    printf -v "$__out" '%s' "$(date +%s 2>/dev/null || echo 0)"
  fi
}

_tui_repeat_var() {
  local __out="$1" count="$2" ch="$3" spaces=""
  if [ "$count" -le 0 ]; then printf -v "$__out" '%s' ""; return 0; fi
  printf -v spaces '%*s' "$count" ''
  printf -v "$__out" '%s' "${spaces// /$ch}"
}

_tui_truncate_var() {
  local __out="$1" text="$2" max_len="$3" ell="…" ell_len=1
  if [ "${_ua_utf8:-1}" -eq 0 ]; then ell="..."; ell_len=3; fi
  if [ "$max_len" -le 0 ]; then printf -v "$__out" '%s' ""
  elif [ "${#text}" -le "$max_len" ]; then printf -v "$__out" '%s' "$text"
  elif [ "$max_len" -le "$ell_len" ]; then printf -v "$__out" '%s' "${text:0:$max_len}"
  else printf -v "$__out" '%s%s' "${text:0:$((max_len - ell_len))}" "$ell"
  fi
}

tui_query_size() {
  local sz="" r="" c=""
  if { [ -t 0 ] || [ -t 1 ]; } && [ -r /dev/tty ]; then
    sz="$({ stty size </dev/tty; } 2>/dev/null || true)"
  fi
  if [ -n "$sz" ]; then r="${sz%% *}"; c="${sz#* }"; fi
  case "$r" in *[!0-9]*|"") r="" ;; esac
  case "$c" in *[!0-9]*|"") c="" ;; esac
  if { [ -z "$r" ] || [ -z "$c" ]; } && command -v tput >/dev/null 2>&1; then
    r="$(tput lines 2>/dev/null || true)"
    c="$(tput cols 2>/dev/null || true)"
  fi
  case "$r" in *[!0-9]*|"") r=24 ;; esac
  case "$c" in *[!0-9]*|"") c=80 ;; esac
  [ "$r" -gt 0 ] || r=24; [ "$c" -gt 0 ] || c=80
  _ua_term_rows="$r"; _ua_term_cols="$c"
}

tui_rule_width() {
  local w=88
  if [ -t 1 ]; then
    [ "${_ua_term_cols:-0}" -gt 0 ] || tui_query_size
    w=$(( _ua_term_cols - 4 ))
    [ "$w" -lt 48 ] && w=48
    [ "$w" -gt 88 ] && w=88
  fi
  printf '%s' "$w"
}

tui_check_min_size() {
  if [ -t 1 ]; then
    tui_query_size
    if [ "$_ua_term_cols" -lt 60 ] || [ "$_ua_term_rows" -lt 14 ]; then
      _ua_tui_compact=1
      if [ "${_ua_tui_min_size_warned:-0}" -eq 0 ]; then
        _ua_tui_min_size_warned=1
        printf '   %b%s Tip:%b terminal is %sx%s; at least 80x24 is recommended for the full layout (continuing in compact mode).\n' \
          "${C_TIP:-}" "${G_WARN:-!}" "${C_RESET:-}" "$_ua_term_cols" "$_ua_term_rows"
      fi
      return 0
    fi
  fi
  _ua_tui_compact=0
}

tui_bar_enabled() {
  anim_enabled && [ "${UPDATE_ALL_BAR:-bottom}" != "off" ] \
    && [ "${BASH_VERSINFO[0]:-3}" -ge 4 ] \
    && [ "${_ua_term_rows:-0}" -ge 12 ] && [ "${_ua_term_cols:-0}" -ge 50 ]
}

_tui_watcher_glyph_var() {
  local __out="$1" tick="${2:-0}" style="${3:-${UPDATE_ALL_WATCHER:-hybrid}}"
  case "$tick" in *[!0-9]*|"") tick=0 ;; esac
  if [ "$style" = "off" ]; then printf -v "$__out" '%s' ""; return 0; fi
  if [ "${_ua_utf8:-1}" -eq 0 ]; then
    local -a ascii_f=('|' '/' '-' "\\")
    printf -v "$__out" '%s' "${ascii_f[$((tick % 4))]}"; return 0
  fi
  case "$style" in
    braille) local -a b_f=('⣾' '⣽' '⣻' '⢿' '⡿' '⣟' '⣯' '⣷'); printf -v "$__out" '%s' "${b_f[$((tick % 8))]}" ;;
    *) local -a a_f=('·' '✢' '✳' '✶' '✻' '✽' '✻' '✶' '✳' '✢'); printf -v "$__out" '%s' "${a_f[$((tick % 10))]}" ;;
  esac
}

tui_watcher_glyph() {
  local out=""; _tui_watcher_glyph_var out "${1:-0}" "${2:-${UPDATE_ALL_WATCHER:-hybrid}}"; printf '%s' "$out"
}

_tui_watcher_wave_var() {
  local __out="$1" tick="${2:-0}" style="${3:-${UPDATE_ALL_WATCHER:-hybrid}}"
  case "$tick" in *[!0-9]*|"") tick=0 ;; esac
  case "$style" in off|anthropic) printf -v "$__out" '%s' ""; return 0 ;; esac
  if [ "${_ua_utf8:-1}" -eq 0 ]; then
    local -a aw_f=('|/-' "/-\\" "-\\|" "\\|/")
    printf -v "$__out" '%s' "${aw_f[$((tick % 4))]}"; return 0
  fi
  local -a w_f=('⣿⣷⣯' '⣷⣯⣟' '⣯⣟⡿' '⣟⡿⢿' '⡿⢿⣻' '⢿⣻⣽' '⣻⣽⣾' '⣽⣾⣿')
  printf -v "$__out" '%s' "${w_f[$((tick % 8))]}"
}

tui_watcher_wave() {
  local out=""; _tui_watcher_wave_var out "${1:-0}" "${2:-${UPDATE_ALL_WATCHER:-hybrid}}"; printf '%s' "$out"
}

_tui_watcher_amber_var() {
  local __out="$1" tick="${2:-0}"
  case "$tick" in *[!0-9]*|"") tick=0 ;; esac
  if [ "${_ua_color_depth:-0}" -ge 256 ]; then
    local -a pulse=(208 214 215 221 223 230 223 221 215 214)
    printf -v "$__out" '\033[38;5;%sm' "${pulse[$((tick % 10))]}"
  else
    printf -v "$__out" '%s' "${C_ORANGE:-}"
  fi
}

_timings_find_index() {
  local key="$1" i n="${#_ua_timing_keys[@]}"
  _ua_timing_idx=-1
  for ((i = 0; i < n; i++)); do
    if [ "${_ua_timing_keys[$i]}" = "$key" ]; then _ua_timing_idx="$i"; return 0; fi
  done
  return 1
}

_timings_is_done() {
  local key="$1" i n="${#_ua_done_keys[@]}"
  for ((i = 0; i < n; i++)); do
    [ "${_ua_done_keys[$i]}" = "$key" ] && return 0
  done
  return 1
}

_timings_mark_done() {
  [ -n "$1" ] || return 0
  _timings_is_done "$1" || _ua_done_keys[${#_ua_done_keys[@]}]="$1"
}

timings_default_for_key() {
  case "$1" in
    safety|safety-brew|safety-osv|safety-ports|coverage|preflight|dpkg|ports) printf '3' ;;
    apt-update|dnf-check|pacman-sync|zypper-refresh|apk-update|xbps-sync) printf '10' ;;
    apt-upgrade|dnf-upgrade|rpm-ostree|pacman-upgrade|zypper-upgrade|apk-upgrade|xbps-upgrade) printf '35' ;;
    snap|flatpak) printf '20' ;;
    brew|brew-update|brew-upgrade) printf '25' ;;
    rustup|cargo|cargo-installed) printf '25' ;;
    corepack|pnpm|yarn|npm|npm-self|npm-globals) printf '15' ;;
    node|mise|volta|fnm|deno|bun|claude|codex|uv|pipx|gh|code) printf '12' ;;
    fwupd|firmware|cleanup|apt-cleanup|workstation-cleanup) printf '10' ;;
    *) printf '12' ;;
  esac
}

_timings_get_est_var() {
  if _timings_find_index "$2"; then printf -v "$1" '%s' "${_ua_timing_secs[$_ua_timing_idx]}"
  else printf -v "$1" '%s' "$(timings_default_for_key "$2")"
  fi
}

timings_get_estimate() {
  local est=""; _timings_get_est_var est "$1"; printf '%s' "$est"
}

timings_load() {
  local file="${1:-${UPDATE_ALL_TIMINGS_FILE:-}}" line="" key="" secs="" extra="" idx=0
  _ua_timing_keys=(); _ua_timing_secs=(); _ua_timings_loaded=1; _ua_timings_has_history=0
  [ -n "$file" ] && [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    key=""; secs=""; extra=""
    IFS=$'\t' read -r key secs extra <<< "$line"
    [ -n "$key" ] && [ -n "$secs" ] && [ -z "$extra" ] || continue
    case "$key" in *[!A-Za-z0-9._:-]*) continue ;; esac
    case "$secs" in *[!0-9]*) continue ;; esac
    [ "$secs" -ge 1 ] && [ "$secs" -le 86400 ] || continue
    if _timings_find_index "$key"; then
      _ua_timing_secs[_ua_timing_idx]="$secs"
    else
      idx="${#_ua_timing_keys[@]}"
      _ua_timing_keys[idx]="$key"; _ua_timing_secs[idx]="$secs"
    fi
    _ua_timings_has_history=1
  done < "$file"
}

timings_set_planned_keys() {
  _ua_planned_keys=("$@"); _ua_done_keys=(); _ua_tui_step_total="$#"; _ua_tui_step_index=0
}

timings_record_step() {
  local key="$1" actual="${2:-1}" prev=0 ewma=1 idx=0
  [ -n "$key" ] || return 0
  actual="${actual%%.*}"
  case "$actual" in *[!0-9]*|"") actual=1 ;; esac
  [ "$actual" -lt 1 ] && actual=1
  _timings_mark_done "$key"
  if _timings_find_index "$key"; then
    prev="${_ua_timing_secs[$_ua_timing_idx]}"
    ewma=$(( (prev * 6 + actual * 4) / 10 ))
    [ "$ewma" -lt 1 ] && ewma=1
    _ua_timing_secs[_ua_timing_idx]="$ewma"
  else
    idx="${#_ua_timing_keys[@]}"
    _ua_timing_keys[idx]="$key"; _ua_timing_secs[idx]="$actual"
  fi
  _ua_timings_has_history=1
}

timings_save() {
  [ "${UPDATE_ALL_DRY_RUN:-0}" = "0" ] || return 0
  local file="${1:-${UPDATE_ALL_TIMINGS_FILE:-}}" dir="" tmp="" i=0 n="${#_ua_timing_keys[@]}"
  [ -n "$file" ] && [ "$n" -gt 0 ] || return 0
  dir="$(dirname -- "$file")"
  mkdir -p -- "$dir" 2>/dev/null || return 0
  tmp="$(mktemp "${dir}/.timings.XXXXXX" 2>/dev/null || printf '%s.tmp.%s' "$file" "$$")"
  if { for ((i = 0; i < n; i++)); do printf '%s\t%s\n' "${_ua_timing_keys[$i]}" "${_ua_timing_secs[$i]}"; done; } > "$tmp" 2>/dev/null; then
    mv -f -- "$tmp" "$file" 2>/dev/null || rm -f -- "$tmp" 2>/dev/null || true
  else
    rm -f -- "$tmp" 2>/dev/null || true
  fi
}

tui_format_duration() {
  local s="${1:-0}"; s="${s%%.*}"
  case "$s" in *[!0-9]*|"") s=0 ;; esac
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm %ss' "$((s / 60))" "$((s % 60))"
  else printf '%sh %sm' "$((s / 3600))" "$(((s % 3600) / 60))"
  fi
}

_tui_format_mmss_var() {
  local __out="$1" s="${2:-0}"; s="${s%%.*}"
  case "$s" in *[!0-9]*|"") s=0 ;; esac
  printf -v "$__out" '%02d:%02d' "$((s / 60))" "$((s % 60))"
}

_tui_update_progress() {
  local active_elapsed="${1:-0}" i=0 n_planned="${#_ua_planned_keys[@]}" n_done="${#_ua_done_keys[@]}"
  local total_est=0 done_est=0 active_est=0 est=0 cap=0 live=0 eff=0 pct=0 rem=0 k=""
  active_elapsed="${active_elapsed%%.*}"
  case "$active_elapsed" in *[!0-9]*|"") active_elapsed=0 ;; esac

  if [ "$n_planned" -gt 0 ]; then
    for ((i = 0; i < n_planned; i++)); do
      k="${_ua_planned_keys[$i]}"
      _timings_get_est_var est "$k"
      total_est=$(( total_est + est ))
      if _timings_is_done "$k"; then done_est=$(( done_est + est ))
      elif [ "$k" = "${_ua_tui_step_key:-}" ]; then active_est="$est"
      fi
    done
    if [ "$active_est" -gt 0 ]; then
      cap=$(( (active_est * 95) / 100 )); live="$active_elapsed"
      [ "$live" -gt "$cap" ] && live="$cap"
      eff=$(( done_est + live ))
    else eff="$done_est"
    fi
    [ "$total_est" -gt 0 ] && pct=$(( (eff * 100) / total_est ))
    [ "$pct" -lt 0 ] && pct=0; [ "$pct" -gt 100 ] && pct=100
    [ "$n_done" -lt "$n_planned" ] && [ "$pct" -ge 100 ] && pct=99
    rem=$(( total_est - eff )); [ "$rem" -lt 0 ] && rem=0
    if [ "${_ua_timings_has_history:-0}" -eq 0 ] && [ "$n_done" -eq 0 ]; then _ua_tui_eta_str="calibrating..."
    elif [ "$n_done" -ge "$n_planned" ]; then _ua_tui_eta_str="finishing..."
    else [ "$rem" -lt 1 ] && rem=1; _ua_tui_eta_str="~$(tui_format_duration "$rem") left"
    fi
  elif [ "${_ua_tui_step_total:-0}" -gt 0 ]; then
    local completed="$_ua_tui_step_index"
    [ -n "${_ua_tui_step_key:-}" ] && [ "$completed" -gt 0 ] && completed=$(( completed - 1 ))
    pct=$(( (completed * 100) / _ua_tui_step_total ))
    [ "$pct" -lt 0 ] && pct=0; [ "$pct" -gt 99 ] && [ -n "${_ua_tui_step_key:-}" ] && pct=99; [ "$pct" -gt 100 ] && pct=100
    _ua_tui_eta_str="calibrating..."
  else
    pct=0; _ua_tui_eta_str="calibrating..."
  fi
  _ua_tui_pct="$pct"
}

tui_calc_progress_pct() { _tui_update_progress "${1:-0}"; printf '%s' "$_ua_tui_pct"; }

tui_set_phase() {
  _ua_tui_phase="$1"
  if [ "${_ua_tui_active:-0}" -eq 1 ] && [ "${_ua_tui_paused:-0}" -eq 0 ]; then
    tui_draw_dock 0 0 0 1 || true
  fi
}

tui_step_begin() {
  local key="$1" label="${2:-$1}" idx="${3:-}" total="${4:-}"
  _ua_tui_step_key="$key"; _ua_tui_step_label="$label"
  if [ -n "$idx" ]; then _ua_tui_step_index="$idx"; else _ua_tui_step_index=$(( _ua_tui_step_index + 1 )); fi
  [ -n "$total" ] && _ua_tui_step_total="$total"
  _tui_now_s _ua_tui_step_start_s
  if [ "${_ua_tui_active:-0}" -eq 1 ] && [ "${_ua_tui_paused:-0}" -eq 0 ]; then
    tui_draw_dock 0 0 0 1 || true
  fi
}

tui_step_end() {
  local key="$1" status="${2:-OK}" actual="${3:-}" now_s=0
  case "$status" in
    UPDATED) _ua_tui_cnt_updated=$(( _ua_tui_cnt_updated + 1 )) ;;
    OK) _ua_tui_cnt_ok=$(( _ua_tui_cnt_ok + 1 )) ;;
    UNCHANGED) _ua_tui_cnt_unchanged=$(( _ua_tui_cnt_unchanged + 1 )) ;;
    SKIP) _ua_tui_cnt_skip=$(( _ua_tui_cnt_skip + 1 )) ;;
    FAIL) _ua_tui_cnt_fail=$(( _ua_tui_cnt_fail + 1 )) ;;
  esac
  if [ -z "$actual" ]; then
    _tui_now_s now_s; actual=$(( now_s - _ua_tui_step_start_s )); [ "$actual" -lt 1 ] && actual=1
  fi
  if [ "$status" = "SKIP" ]; then _timings_mark_done "$key"; else timings_record_step "$key" "$actual"; fi
  [ "${_ua_tui_step_key:-}" = "$key" ] && _ua_tui_step_key=""
  if [ "${_ua_tui_active:-0}" -eq 1 ] && [ "${_ua_tui_paused:-0}" -eq 0 ]; then
    tui_draw_dock 0 0 0 0 || true
  fi
}

_tui_apply_scroll_region() {
  if [ "${UPDATE_ALL_BAR:-bottom}" = "top" ]; then
    printf '\033[?2026h\033[3;%dr\033[3;1H\033[?2026l' "$_ua_term_rows"
  else
    local scroll_bot=$(( _ua_term_rows - 2 ))
    printf '\033[?2026h\n\n\033[2A\0337\033[1;%dr\0338\033[?2026l' "$scroll_bot"
  fi
}

tui_init() {
  tui_query_size
  tui_check_min_size
  if ! tui_bar_enabled; then
    _ua_tui_active=0
    return 0
  fi
  _tui_apply_scroll_region
  _ua_tui_active=1
  _ua_tui_paused=0
  tui_draw_dock 0 0 0 1
}

_tui_status_vars() {
  local alive="$1" silence="$2" dot="${G_SKIP:-·}"
  if [ "$alive" -eq 0 ]; then
    _ua_st_plain="${G_IDLE:-○} idle"
    _ua_st_col="${C_TIP:-}${_ua_st_plain}${C_RESET:-}"
  elif [ "$silence" -ge 45 ]; then
    _ua_st_plain="quiet ${silence}s (alive ${dot} Ctrl+C to stop)"
    _ua_st_col="${C_WARN:-}${_ua_st_plain}${C_RESET:-}"
  elif [ "$silence" -ge 15 ]; then
    _ua_st_plain="quiet ${silence}s (still running)"
    _ua_st_col="${C_WARN:-}${_ua_st_plain}${C_RESET:-}"
  else
    _ua_st_plain="${G_LIVE:-●} live"
    _ua_st_col="${C_OK:-}${_ua_st_plain}${C_RESET:-}"
  fi
}

tui_draw_dock() {
  [ "${_ua_tui_active:-0}" -eq 1 ] && [ "${_ua_tui_paused:-0}" -eq 0 ] || return 0
  local tick="${1:-0}" elapsed="${2:-0}" silence="${3:-0}" alive="${4:-1}"
  elapsed="${elapsed%%.*}"; silence="${silence%%.*}"
  case "$elapsed" in *[!0-9]*|"") elapsed=0 ;; esac
  case "$silence" in *[!0-9]*|"") silence=0 ;; esac

  _tui_update_progress "$elapsed"
  local r1=1 r2=2 max_cols=$(( _ua_term_cols - 1 ))
  if [ "${UPDATE_ALL_BAR:-bottom}" != "top" ]; then r1=$(( _ua_term_rows - 1 )); r2="$_ua_term_rows"; fi

  local bar_w=16
  if [ "$_ua_term_cols" -ge 100 ]; then bar_w=18
  elif [ "$_ua_term_cols" -lt 64 ]; then bar_w=8
  elif [ "$_ua_term_cols" -lt 80 ]; then bar_w=12
  fi
  local filled=$(( (_ua_tui_pct * bar_w) / 100 )) empty=0
  [ "$filled" -gt "$bar_w" ] && filled="$bar_w"
  empty=$(( bar_w - filled ))

  local fill_s="" empty_s="" pct_s="" dot="${G_SKIP:-·}" drule2="${G_DOCK_RULE:-━}${G_DOCK_RULE:-━}"
  _tui_repeat_var fill_s "$filled" "${G_BAR_FULL:-█}"
  _tui_repeat_var empty_s "$empty" "${G_BAR_EMPTY:-░}"
  printf -v pct_s '%3d%%' "$_ua_tui_pct"

  local step_s="Step ${_ua_tui_step_index}"
  [ "${_ua_tui_step_total:-0}" -gt 0 ] && step_s="Step ${_ua_tui_step_index}/${_ua_tui_step_total}"
  local cnt_plain="${G_UPDATED:-↗}${_ua_tui_cnt_updated} ${G_OK:-✓}${_ua_tui_cnt_ok} ${G_UNCHANGED:-=}${_ua_tui_cnt_unchanged} ${G_SKIP:-·}${_ua_tui_cnt_skip} ${G_FAIL:-✗}${_ua_tui_cnt_fail}"
  local cnt_col="${C_OK:-}${G_UPDATED:-↗}${_ua_tui_cnt_updated} ${G_OK:-✓}${_ua_tui_cnt_ok}${C_RESET:-} ${C_TIP:-}${G_UNCHANGED:-=}${_ua_tui_cnt_unchanged} ${G_SKIP:-·}${_ua_tui_cnt_skip}${C_RESET:-} ${C_BAD:-}${G_FAIL:-✗}${_ua_tui_cnt_fail}${C_RESET:-}"

  local row1="" r1_vis=0 sep_col="${C_FRAME:-} ${dot} ${C_RESET:-}"
  if [ "$max_cols" -ge 74 ]; then row1="${C_FRAME:-}${drule2}${C_RESET:-} "; r1_vis=3; fi
  row1="${row1}${C_FRAME:-}[${C_RESET:-}${C_BAR_FILL:-}${fill_s}${C_RESET:-}${C_BAR_BG:-}${empty_s}${C_RESET:-}${C_FRAME:-}]${C_RESET:-} ${C_HEADER:-}${pct_s}${C_RESET:-}"
  r1_vis=$(( r1_vis + bar_w + 3 + ${#pct_s} ))

  if [ $(( r1_vis + 3 + ${#_ua_tui_eta_str} )) -le "$max_cols" ]; then
    row1="${row1}${sep_col}${C_TIP:-}${_ua_tui_eta_str}${C_RESET:-}"; r1_vis=$(( r1_vis + 3 + ${#_ua_tui_eta_str} ))
  fi
  if [ $(( r1_vis + 3 + ${#step_s} )) -le "$max_cols" ]; then
    row1="${row1}${sep_col}${C_LABEL:-}${step_s}${C_RESET:-}"; r1_vis=$(( r1_vis + 3 + ${#step_s} ))
  fi
  if [ -n "${_ua_tui_phase:-}" ] && [ $(( r1_vis + 3 + ${#_ua_tui_phase} )) -le "$max_cols" ]; then
    row1="${row1}${sep_col}${C_UNIT:-}${_ua_tui_phase}${C_RESET:-}"; r1_vis=$(( r1_vis + 3 + ${#_ua_tui_phase} ))
  fi
  if [ $(( r1_vis + 3 + ${#cnt_plain} )) -le "$max_cols" ]; then
    row1="${row1}${sep_col}${cnt_col}"; r1_vis=$(( r1_vis + 3 + ${#cnt_plain} ))
  fi
  [ $(( r1_vis + 3 )) -le "$max_cols" ] && row1="${row1} ${C_FRAME:-}${drule2}${C_RESET:-}"
  row1="${row1}${C_RESET:-}"

  local glyph="" wave="" amber="" mmss="" wstyle="${UPDATE_ALL_WATCHER:-hybrid}"
  _tui_watcher_glyph_var glyph "$tick" "$wstyle"
  _tui_watcher_wave_var wave "$tick" "$wstyle"
  _tui_watcher_amber_var amber "$tick"
  _tui_format_mmss_var mmss "$elapsed"
  _tui_status_vars "$alive" "$silence"

  local prefix_vis=0 prefix_col="" right_vis=0 right_col="" label_raw="${_ua_tui_step_label:-Running update-all}" label_out=""
  if [ -n "$glyph" ]; then prefix_col="${amber}${glyph}${C_RESET:-} "; prefix_vis=2; fi
  if [ -n "$wave" ]; then
    right_vis=$(( 6 + ${#wave} + ${#mmss} + 3 + ${#_ua_st_plain} ))
    right_col="   ${C_BAR_FILL:-}${wave}${C_RESET:-}   ${C_TIP:-}${mmss}${C_RESET:-}${sep_col}${_ua_st_col}"
  else
    right_vis=$(( 2 + ${#mmss} + 3 + ${#_ua_st_plain} ))
    right_col="  ${C_TIP:-}${mmss}${C_RESET:-}${sep_col}${_ua_st_col}"
  fi
  local budget=$(( max_cols - prefix_vis - right_vis ))
  if [ "$budget" -lt 10 ] && [ -n "$wave" ]; then
    right_vis=$(( 2 + ${#mmss} + 3 + ${#_ua_st_plain} ))
    right_col="  ${C_TIP:-}${mmss}${C_RESET:-}${sep_col}${_ua_st_col}"
    budget=$(( max_cols - prefix_vis - right_vis ))
  fi
  if [ "$budget" -lt 6 ]; then
    right_vis=$(( 1 + ${#mmss} ))
    right_col=" ${C_TIP:-}${mmss}${C_RESET:-}"
    budget=$(( max_cols - prefix_vis - right_vis ))
  fi
  _tui_truncate_var label_out "$label_raw" "$budget"
  local row2="${prefix_col}${C_HEADER:-}${label_out}${C_RESET:-}${right_col}${C_RESET:-}"

  printf '\033[?2026h\0337\033[?25l\033[?7l\033[%d;1H\033[2K%s\033[%d;1H\033[2K%s\033[?7h\033[?25h\0338\033[?2026l' \
    "$r1" "$row1" "$r2" "$row2"
}

tui_handle_resize() {
  tui_query_size
  tui_check_min_size
  [ "${_ua_tui_active:-0}" -eq 1 ] || return 0
  if ! tui_bar_enabled; then tui_teardown; return 0; fi
  if [ "${_ua_tui_paused:-0}" -eq 0 ]; then
    if [ "${UPDATE_ALL_BAR:-bottom}" = "top" ]; then
      printf '\033[?2026h\0337\033[3;%dr\0338\033[?2026l' "$_ua_term_rows"
    else
      printf '\033[?2026h\0337\033[1;%dr\0338\033[?2026l' "$(( _ua_term_rows - 2 ))"
    fi
    tui_draw_dock 0 0 0 1
  fi
}

tui_pause_for_tty() {
  [ "${_ua_tui_active:-0}" -eq 1 ] && [ "${_ua_tui_paused:-0}" -eq 0 ] || return 0
  local r1=$(( _ua_term_rows - 1 )) r2="$_ua_term_rows"
  [ "${UPDATE_ALL_BAR:-bottom}" = "top" ] && r1=1 && r2=2
  printf '\033[?2026h\0337\033[%d;1H\033[2K\033[%d;1H\033[2K\033[r\033[?7h\033[?25h\033[0m\0338\033[?2026l' "$r1" "$r2"
  _ua_tui_paused=1
}

tui_resume_after_tty() {
  [ "${_ua_tui_paused:-0}" -eq 1 ] || return 0
  _ua_tui_paused=0
  tui_query_size
  if tui_bar_enabled; then
    _tui_apply_scroll_region
    _ua_tui_active=1
    tui_draw_dock 0 0 0 1
  else
    _ua_tui_active=0
  fi
}

tui_clear_inline_watcher() {
  if [ "${_ua_tui_inline_visible:-0}" -eq 1 ]; then
    printf '\r\033[2K'
    _ua_tui_inline_visible=0
  fi
}

tui_draw_inline_watcher() {
  anim_enabled || return 0
  [ "${_ua_tui_active:-0}" -eq 0 ] || return 0
  local tick="${1:-0}" elapsed="${2:-0}" silence="${3:-0}" label="${4:-${_ua_tui_step_label:-Running}}"
  local glyph="" wave="" amber="" mmss="" label_out="" dot="${G_SKIP:-·}"
  elapsed="${elapsed%%.*}"; silence="${silence%%.*}"
  case "$elapsed" in *[!0-9]*|"") elapsed=0 ;; esac
  case "$silence" in *[!0-9]*|"") silence=0 ;; esac

  _tui_watcher_glyph_var glyph "$tick" "${UPDATE_ALL_WATCHER:-hybrid}"
  _tui_watcher_wave_var wave "$tick" "${UPDATE_ALL_WATCHER:-hybrid}"
  _tui_watcher_amber_var amber "$tick"
  _tui_format_mmss_var mmss "$elapsed"
  _tui_status_vars 1 "$silence"

  local max_cols=$(( _ua_term_cols - 1 ))
  local sep_col="${C_FRAME:-} ${dot} ${C_RESET:-}"
  local right_vis=$(( 2 + ${#mmss} + 3 + ${#_ua_st_plain} ))
  local right_col="  ${C_TIP:-}${mmss}${C_RESET:-}${sep_col}${_ua_st_col}"
  if [ -n "$wave" ]; then
    right_vis=$(( 2 + ${#wave} + 2 + ${#mmss} + 3 + ${#_ua_st_plain} ))
    right_col="  ${C_BAR_FILL:-}${wave}${C_RESET:-}  ${C_TIP:-}${mmss}${C_RESET:-}${sep_col}${_ua_st_col}"
  fi
  local prefix_vis=$(( 3 + ${#glyph} + 1 ))
  local budget=$(( max_cols - prefix_vis - right_vis ))
  if [ "$budget" -lt 8 ] && [ -n "$wave" ]; then
    right_vis=$(( 2 + ${#mmss} + 3 + ${#_ua_st_plain} ))
    right_col="  ${C_TIP:-}${mmss}${C_RESET:-}${sep_col}${_ua_st_col}"
    budget=$(( max_cols - prefix_vis - right_vis ))
  fi
  if [ "$budget" -lt 6 ]; then
    right_vis=$(( 1 + ${#mmss} ))
    right_col=" ${C_TIP:-}${mmss}${C_RESET:-}"
    budget=$(( max_cols - prefix_vis - right_vis ))
  fi
  _tui_truncate_var label_out "$label" "$budget"
  printf '\r\033[2K   %s%s%s %s%s%s%s%s' \
    "$amber" "$glyph" "${C_RESET:-}" "${C_HEADER:-}" "$label_out" "${C_RESET:-}" "$right_col" "${C_RESET:-}"
  _ua_tui_inline_visible=1
}

tui_teardown() {
  tui_clear_inline_watcher
  if [ "${_ua_tui_active:-0}" -eq 1 ]; then
    local r1=$(( _ua_term_rows - 1 )) r2="$_ua_term_rows"
    [ "${UPDATE_ALL_BAR:-bottom}" = "top" ] && r1=1 && r2=2
    printf '\033[?2026h\0337\033[%d;1H\033[2K\033[%d;1H\033[2K\033[r\033[?7h\033[?25h\033[0m\0338\033[?2026l' "$r1" "$r2"
    _ua_tui_active=0
    _ua_tui_paused=0
  fi
}
