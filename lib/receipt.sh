# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Receipt rendering, dramatic WHAT CHANGED changelog table, and visual previews.
# Public-safe: no hardcoded user home paths, private IPs, or secrets.

: "${_ua_reclaimed_kb:=0}"
: "${_ua_count_security:=0}"
: "${G_UPDATED:=↗}"
: "${G_OK:=✓}"
: "${G_UNCHANGED:==}"
: "${G_FAIL:=✗}"
: "${G_SKIP:=·}"
: "${G_WARN:=▲}"
: "${G_SAFETY:=◆}"
: "${G_ARROW:=→}"

if ! declare -p _ua_delta_pkgs >/dev/null 2>&1; then
  declare -a _ua_delta_pkgs=()
  declare -a _ua_delta_before=()
  declare -a _ua_delta_after=()
  declare -a _ua_delta_via=()
fi

if ! declare -F record_delta >/dev/null 2>&1; then
  record_delta() {
    _ua_delta_pkgs+=("$1")
    _ua_delta_before+=("$2")
    _ua_delta_after+=("$3")
    _ua_delta_via+=("${4:-update-all}")
  }
fi

_receipt_rule_width() {
  local w=88
  if declare -F tui_rule_width >/dev/null 2>&1; then
    w="$(tui_rule_width 2>/dev/null || printf '88')"
  fi
  case "$w" in
    ''|*[!0-9]*) w=88 ;;
  esac
  [ "$w" -lt 74 ] && w=74
  [ "$w" -gt 120 ] && w=120
  printf '%s' "$w"
}

_receipt_repeat() {
  local chunk="$1" count="${2:-0}" out=""
  while [ "$count" -gt 0 ]; do
    if [ $((count & 1)) -eq 1 ]; then
      out="${out}${chunk}"
    fi
    chunk="${chunk}${chunk}"
    count=$((count >> 1))
  done
  printf '%s' "$out"
}

receipt_version() {
  local value="${1:-}" path rest
  [ -n "$value" ] || {
    printf '-'
    return 0
  }
  case "$value" in
    /*)
      path="${value%% *}"
      rest="${value#"$path"}"
      rest="${rest# }"
      [ -n "$rest" ] || rest="installed"
      printf '%s' "$rest"
      ;;
    *)
      printf '%s' "$value"
      ;;
  esac
}

receipt_value() {
  local value="$1" max="${2:-74}" left right
  if [ "${#value}" -le "$max" ]; then
    printf '%s' "$value"
    return 0
  fi
  if [ "$max" -le 4 ]; then
    printf '%s' "${value:0:max}"
    return 0
  fi
  left=$(( (max - 3) / 2 ))
  right=$(( max - 3 - left ))
  printf '%s...%s' "${value:0:left}" "${value: -right}"
}

status_meaning() {
  case "$1" in
    UPDATED)   printf 'updated: something changed during this step' ;;
    OK)        printf 'checked: command completed normally' ;;
    UNCHANGED) printf 'already current: no visible version change' ;;
    SKIP)      printf 'skipped safely: tool is missing or intentionally left alone' ;;
    FAIL)      printf 'failed: this needs review before trusting the whole run' ;;
    *)         printf 'recorded by update-all' ;;
  esac
}

receipt_status_style() {
  local stat="$1" __icon_var="$2" __color_var="$3" selected_icon selected_color
  case "$stat" in
    UPDATED)   selected_icon="$G_UPDATED"; selected_color="${C_OK:-}" ;;
    OK)        selected_icon="$G_OK"; selected_color="${C_OK:-}" ;;
    UNCHANGED) selected_icon="$G_UNCHANGED"; selected_color="${C_WARN:-}" ;;
    FAIL)      selected_icon="$G_FAIL"; selected_color="${C_BAD:-}" ;;
    SKIP)      selected_icon="$G_SKIP"; selected_color="${C_TIP:-}" ;;
    *)         selected_icon="?"; selected_color="${C_RESET:-}" ;;
  esac
  printf -v "$__icon_var" '%s' "$selected_icon"
  printf -v "$__color_var" '%s' "$selected_color"
}

receipt_version_pair_colors() {
  local stat="$1" __before_var="$2" __after_var="$3" selected_before_color selected_after_color
  case "$stat" in
    UPDATED)
      selected_before_color="${C_VERSION_BEFORE:-}"
      selected_after_color="${C_VERSION_AFTER:-}"
      ;;
    FAIL)
      selected_before_color="${C_BAD:-}"
      selected_after_color="${C_BAD:-}"
      ;;
    UNCHANGED)
      selected_before_color="${C_VERSION_BEFORE:-}"
      selected_after_color="${C_VERSION_BEFORE:-}"
      ;;
    *)
      selected_before_color="${C_TIP:-}"
      selected_after_color="${C_TIP:-}"
      ;;
  esac
  printf -v "$__before_var" '%s' "$selected_before_color"
  printf -v "$__after_var" '%s' "$selected_after_color"
}

print_receipt_version_pair() {
  local stat="$1" before_raw="${2:-}" after_raw="${3:-}" label="${4:-version}" indent="${5:-     }" label_width="${6:-8}"
  local before after before_color after_color
  [ -n "$before_raw" ] || before_raw="-"
  [ -n "$after_raw" ] || after_raw="-"
  [ "$before_raw" != "-" ] || [ "$after_raw" != "-" ] || return 0

  before="$(receipt_value "$(receipt_version "$before_raw")" 34)"
  after="$(receipt_value "$(receipt_version "$after_raw")" 34)"
  receipt_version_pair_colors "$stat" before_color after_color
  if [ "$stat" = "UPDATED" ]; then
    printf '%s%b%-*s%b %b%-6s%b %b%s%b\n' \
      "$indent" "${C_LABEL:-}" "$label_width" "$label" "${C_RESET:-}" \
      "${C_VERSION_BEFORE_LABEL:-}" "before" "${C_RESET:-}" \
      "$before_color" "$before" "${C_RESET:-}"
    printf '%s%b%-*s%b %b%-6s%b %b%s%b\n' \
      "$indent" "${C_LABEL:-}" "$label_width" "" "${C_RESET:-}" \
      "${C_VERSION_AFTER_LABEL:-}" "after" "${C_RESET:-}" \
      "$after_color" "$after" "${C_RESET:-}"
  else
    printf '%s%b%-*s%b %b%-6s%b %b%s%b\n' \
      "$indent" "${C_LABEL:-}" "$label_width" "$label" "${C_RESET:-}" \
      "${C_VERSION_BEFORE_LABEL:-}" "before" "${C_RESET:-}" \
      "$before_color" "$before" "${C_RESET:-}"
    printf '%s%b%-*s%b %b%-6s%b %b%s%b\n' \
      "$indent" "${C_LABEL:-}" "$label_width" "" "${C_RESET:-}" \
      "${C_VERSION_BEFORE_LABEL:-}" "after" "${C_RESET:-}" \
      "$after_color" "$after" "${C_RESET:-}"
  fi
}

print_receipt_field() {
  local indent="$1" label="$2" text="$3" text_color="${4:-${C_RESET:-}}" label_width="${5:-8}" wrap_width="${6:-74}" label_color="${7:-${C_LABEL:-}}"
  local line first=1
  [ -n "$text" ] || return 0

  while IFS= read -r line; do
    if [ "$first" -eq 1 ]; then
      printf '%s%b%-*s%b %b%s%b\n' "$indent" "$label_color" "$label_width" "$label" "${C_RESET:-}" "$text_color" "$line" "${C_RESET:-}"
      first=0
    else
      printf '%s%*s %b%s%b\n' "$indent" "$label_width" "" "$text_color" "$line" "${C_RESET:-}"
    fi
  done < <(printf '%s\n' "$text" | fold -s -w "$wrap_width")
}

_receipt_infer_pkg_and_via() {
  local lbl="$1" __pkg_var="$2" __via_var="$3"
  local _sel_pkg="$lbl" _sel_via="update-all"
  case "$lbl" in
    "brew formula: "*) _sel_pkg="${lbl#brew formula: }"; _sel_via="brew" ;;
    "brew cask: "*)    _sel_pkg="${lbl#brew cask: }"; _sel_via="brew cask" ;;
    "uv tool: "*)      _sel_pkg="${lbl#uv tool: }"; _sel_via="uv" ;;
    "npm global: "*)   _sel_pkg="${lbl#npm global: }"; _sel_via="npm" ;;
    *"(corepack)"*)    _sel_pkg="$lbl"; _sel_via="corepack" ;;
    apt*|dpkg*)        _sel_pkg="$lbl"; _sel_via="apt" ;;
    dnf*)              _sel_pkg="$lbl"; _sel_via="dnf" ;;
    pacman*)           _sel_pkg="$lbl"; _sel_via="pacman" ;;
    brew*)             _sel_pkg="$lbl"; _sel_via="brew" ;;
    npm*)              _sel_pkg="$lbl"; _sel_via="npm" ;;
    uv*)               _sel_pkg="$lbl"; _sel_via="uv" ;;
    pipx*)             _sel_pkg="$lbl"; _sel_via="pipx" ;;
    cargo*|rustup*)    _sel_pkg="$lbl"; _sel_via="rust" ;;
    snap*)             _sel_pkg="$lbl"; _sel_via="snap" ;;
    flatpak*)          _sel_pkg="$lbl"; _sel_via="flatpak" ;;
    bun*)              _sel_pkg="$lbl"; _sel_via="bun" ;;
    claude*)           _sel_pkg="$lbl"; _sel_via="claude" ;;
    codex*)            _sel_pkg="$lbl"; _sel_via="codex" ;;
  esac
  printf -v "$__pkg_var" '%s' "$_sel_pkg"
  printf -v "$__via_var" '%s' "$_sel_via"
}

print_changed_story() {
  local bar="$1" i width table_w avail col_pkg col_bef col_aft col_via
  local seg_pkg seg_bef seg_arr seg_aft seg_via
  local h_ch="─" v_ch="│" tl="┌" tm="┬" tr="┐" ml="├" mm="┼" mr="┤" bl="└" bm="┴" br="┘" tbl_arrow="→"
  local -a rows_pkg=() rows_bef=() rows_aft=() rows_via=()
  local seen="|" pkg bef aft via lbl pkg_disp bef_disp aft_disp via_disp pkg_color

  printf '  %bWHAT CHANGED%b  %b(old -> new)%b\n' "${C_HEADER:-}" "${C_RESET:-}" "${C_TIP:-}" "${C_RESET:-}"
  printf '%b\n' "$bar"

  if [ "${#_ua_delta_pkgs[@]}" -gt 0 ]; then
    for ((i = 0; i < ${#_ua_delta_pkgs[@]}; i++)); do
      pkg="${_ua_delta_pkgs[$i]}"
      [ -n "$pkg" ] || continue
      bef="${_ua_delta_before[$i]:--}"
      aft="${_ua_delta_after[$i]:--}"
      via="${_ua_delta_via[$i]:-update-all}"
      rows_pkg+=("$pkg")
      rows_bef+=("$bef")
      rows_aft+=("$aft")
      rows_via+=("$via")
      seen="${seen}${pkg}|"
    done
  fi

  for ((i = 0; i < ${#_ua_labels[@]}; i++)); do
    [ "${_ua_stats[$i]}" = "UPDATED" ] || continue
    lbl="${_ua_labels[$i]}"
    _receipt_infer_pkg_and_via "$lbl" pkg via
    case "$seen" in
      *"|${lbl}|"*|*"|${pkg}|"*) continue ;;
    esac
    bef="$(receipt_version "${_ua_before[$i]}")"
    aft="$(receipt_version "${_ua_after[$i]}")"
    [ "$bef" != "$aft" ] || [ "$aft" != "-" ] || aft="updated"
    rows_pkg+=("$pkg")
    rows_bef+=("$bef")
    rows_aft+=("$aft")
    rows_via+=("$via")
    seen="${seen}${lbl}|${pkg}|"
  done

  if [ "${#rows_pkg[@]}" -eq 0 ]; then
    printf '  %b%s No visible version changes%b\n' "${C_OK:-}" "$G_OK" "${C_RESET:-}"
    printf '     %b%s%b   Everything checked was already current, skipped safely, or completed without a version bump.\n' "${C_TIP:-}" "means" "${C_RESET:-}"
    printf '%b\n' "$bar"
    return 0
  fi

  if [ "${_ua_utf8:-1}" -eq 0 ]; then
    h_ch="-"
    v_ch="|"
    tl="+"
    tm="+"
    tr="+"
    ml="+"
    mm="+"
    mr="+"
    bl="+"
    bm="+"
    br="+"
    tbl_arrow=">"
  fi

  width="$(_receipt_rule_width)"
  table_w=$((width - 2))
  avail=$((table_w - 19))
  [ "$avail" -lt 52 ] && avail=52
  col_via=10
  [ "$avail" -ge 76 ] && col_via=12
  col_bef=$(( (avail - col_via) * 28 / 100 ))
  [ "$col_bef" -lt 14 ] && col_bef=14
  col_aft="$col_bef"
  col_pkg=$((avail - col_via - col_bef - col_aft))
  [ "$col_pkg" -lt 18 ] && col_pkg=18

  seg_pkg="$(_receipt_repeat "$h_ch" "$((col_pkg + 4))")"
  seg_bef="$(_receipt_repeat "$h_ch" "$((col_bef + 2))")"
  seg_arr="$(_receipt_repeat "$h_ch" 3)"
  seg_aft="$(_receipt_repeat "$h_ch" "$((col_aft + 2))")"
  seg_via="$(_receipt_repeat "$h_ch" "$((col_via + 2))")"

  printf '  %b%s%s%s%s%s%s%s%s%s%s%s%b\n' \
    "${C_FRAME:-}" "$tl" "$seg_pkg" "$tm" "$seg_bef" "$tm" "$seg_arr" "$tm" "$seg_aft" "$tm" "$seg_via" "$tr" "${C_RESET:-}"
  printf '  %b%s%b %b%-*s%b %b%s%b %b%-*s%b %b%s%b %b%s%b %b%s%b %b%-*s%b %b%s%b %b%-*s%b %b%s%b\n' \
    "${C_FRAME:-}" "$v_ch" "${C_RESET:-}" \
    "${C_HEADER:-}" "$((col_pkg + 2))" "PROGRAM / PACKAGE" "${C_RESET:-}" \
    "${C_FRAME:-}" "$v_ch" "${C_RESET:-}" \
    "${C_HEADER:-}" "$col_bef" "BEFORE" "${C_RESET:-}" \
    "${C_FRAME:-}" "$v_ch" "${C_RESET:-}" \
    "${C_ORANGE:-}" "$tbl_arrow" "${C_RESET:-}" \
    "${C_FRAME:-}" "$v_ch" "${C_RESET:-}" \
    "${C_HEADER:-}" "$col_aft" "AFTER" "${C_RESET:-}" \
    "${C_FRAME:-}" "$v_ch" "${C_RESET:-}" \
    "${C_HEADER:-}" "$col_via" "VIA" "${C_RESET:-}" \
    "${C_FRAME:-}" "$v_ch" "${C_RESET:-}"
  printf '  %b%s%s%s%s%s%s%s%s%s%s%s%b\n' \
    "${C_FRAME:-}" "$ml" "$seg_pkg" "$mm" "$seg_bef" "$mm" "$seg_arr" "$mm" "$seg_aft" "$mm" "$seg_via" "$mr" "${C_RESET:-}"

  for ((i = 0; i < ${#rows_pkg[@]}; i++)); do
    pkg_disp="$(receipt_value "${rows_pkg[$i]}" "$col_pkg")"
    bef_disp="$(receipt_value "${rows_bef[$i]}" "$col_bef")"
    aft_disp="$(receipt_value "${rows_aft[$i]}" "$col_aft")"
    via_disp="$(receipt_value "${rows_via[$i]}" "$col_via")"
    if declare -F styled_package_color >/dev/null 2>&1; then
      pkg_color="$(styled_package_color "${rows_via[$i]}")"
    else
      pkg_color="${C_HEADER:-}"
    fi
    printf '  %b%s%b %b%s%b %b%-*s%b %b%s%b %b%-*s%b %b%s%b %b%s%b %b%s%b %b%-*s%b %b%s%b %b%-*s%b %b%s%b\n' \
      "${C_FRAME:-}" "$v_ch" "${C_RESET:-}" \
      "${C_OK:-}" "$G_UPDATED" "${C_RESET:-}" \
      "$pkg_color" "$col_pkg" "$pkg_disp" "${C_RESET:-}" \
      "${C_FRAME:-}" "$v_ch" "${C_RESET:-}" \
      "${C_VERSION_BEFORE:-}" "$col_bef" "$bef_disp" "${C_RESET:-}" \
      "${C_FRAME:-}" "$v_ch" "${C_RESET:-}" \
      "${C_ORANGE:-}" "$tbl_arrow" "${C_RESET:-}" \
      "${C_FRAME:-}" "$v_ch" "${C_RESET:-}" \
      "${C_VERSION_AFTER:-}" "$col_aft" "$aft_disp" "${C_RESET:-}" \
      "${C_FRAME:-}" "$v_ch" "${C_RESET:-}" \
      "${C_PATH:-}" "$col_via" "$via_disp" "${C_RESET:-}" \
      "${C_FRAME:-}" "$v_ch" "${C_RESET:-}"
  done

  printf '  %b%s%s%s%s%s%s%s%s%s%s%s%b\n' \
    "${C_FRAME:-}" "$bl" "$seg_pkg" "$bm" "$seg_bef" "$bm" "$seg_arr" "$bm" "$seg_aft" "$bm" "$seg_via" "$br" "${C_RESET:-}"
  printf '  %b%s UPDATED%b  %d upgraded item(s)\n' "${C_OK:-}" "$G_UPDATED" "${C_RESET:-}" "${#rows_pkg[@]}"
  printf '%b\n' "$bar"
}

print_no_action_needed() {
  local bar="$1" i count=0 icon color lbl note
  printf '  %bNO ACTION NEEDED%b\n' "${C_HEADER:-}" "${C_RESET:-}"
  printf '%b\n' "$bar"

  for ((i = 0; i < ${#_ua_labels[@]}; i++)); do
    case "${_ua_stats[$i]}" in
      OK|UNCHANGED|SKIP) ;;
      *) continue ;;
    esac
    count=$((count + 1))
    lbl="${_ua_labels[$i]}"
    note="${_ua_notes[$i]}"
    receipt_status_style "${_ua_stats[$i]}" icon color
    printf '  %b%s %-9s%b %-28s %b%s%b\n' \
      "$color" "$icon" "${_ua_stats[$i]}" "${C_RESET:-}" \
      "$(receipt_value "$lbl" 28)" \
      "${C_TIP:-}" "${note:-$(status_meaning "${_ua_stats[$i]}")}" "${C_RESET:-}"
  done

  [ "$count" -gt 0 ] || printf '  %bNo quiet rows recorded.%b\n' "${C_TIP:-}" "${C_RESET:-}"
  printf '%b\n' "$bar"
}

print_attention_story() {
  local bar="$1" i
  printf '  %bNEEDS YOUR ATTENTION%b\n' "${C_HEADER:-}" "${C_RESET:-}"
  printf '%b\n' "$bar"

  if [ "${rc:-0}" -ne 0 ]; then
    printf '  %b%s Failed step recorded%b\n' "${C_BAD:-}" "$G_FAIL" "${C_RESET:-}"
    printf '     %b%s%b  Read the FAIL rows in RUN DETAILS below before closing this tab.\n' "${C_TIP:-}" "action:" "${C_RESET:-}"
  fi

  if [ "${#_ua_concern_titles[@]}" -eq 0 ] && [ "${rc:-0}" -eq 0 ]; then
    printf '  %b%s Nothing urgent recorded%b\n' "${C_OK:-}" "$G_OK" "${C_RESET:-}"
    printf '     %b%s%b   No manual follow-up was detected during this run.\n' "${C_TIP:-}" "means:" "${C_RESET:-}"
  fi

  for ((i = 0; i < ${#_ua_concern_titles[@]}; i++)); do
    printf '  %b%s %s%b\n' "${C_UNIT:-}" "$G_WARN" "${_ua_concern_titles[$i]}" "${C_RESET:-}"
    print_receipt_field "     " "means:" "${_ua_concern_notes[$i]}" "${C_RESET:-}" 8 74 "${C_TIP:-}"
    print_receipt_field "     " "action:" "${_ua_concern_actions[$i]}" "${C_RESET:-}" 8 74 "${C_TIP:-}"
  done
  printf '%b\n' "$bar"
}

cleanup_status_for() {
  local label="$1" i
  for ((i = 0; i < ${#_ua_labels[@]}; i++)); do
    if [ "${_ua_labels[$i]}" = "$label" ]; then
      printf '%s' "${_ua_stats[$i]}"
      return 0
    fi
  done
  if [ "$label" = "apt autoremove" ]; then
    for ((i = 0; i < ${#_ua_labels[@]}; i++)); do
      case "${_ua_labels[$i]}" in
        "dnf autoremove"|"pacman cache clean"|"apk cache clean")
          printf '%s' "${_ua_stats[$i]}"
          return 0
          ;;
      esac
    done
  fi
  printf 'SKIP'
}

cleanup_note_for() {
  local label="$1" i
  for ((i = 0; i < ${#_ua_labels[@]}; i++)); do
    if [ "${_ua_labels[$i]}" = "$label" ]; then
      printf '%s' "${_ua_notes[$i]}"
      return 0
    fi
  done
  if [ "$label" = "apt autoremove" ]; then
    for ((i = 0; i < ${#_ua_labels[@]}; i++)); do
      case "${_ua_labels[$i]}" in
        "dnf autoremove"|"pacman cache clean"|"apk cache clean")
          printf '%s' "${_ua_notes[$i]}"
          return 0
          ;;
      esac
    done
  fi
  printf 'not reached'
}

cleanup_next_steps() {
  local bar="$1" apt_status cache_status apt_note cache_note
  apt_status="$(cleanup_status_for "apt autoremove")"
  cache_status="$(cleanup_status_for "workstation cache cleanup")"
  apt_note="$(cleanup_note_for "apt autoremove")"
  cache_note="$(cleanup_note_for "workstation cache cleanup")"

  printf '  %bCLEANUP NEXT STEPS%b\n' "${C_HEADER:-}" "${C_RESET:-}"
  printf '%b\n' "$bar"
  printf '  %b%-18s%b %b%s%b\n' "${C_LABEL:-}" "pkg cleanup" "${C_RESET:-}" "${C_RESULT:-}" "$apt_status" "${C_RESET:-}"
  print_receipt_field "     " "note:" "$apt_note" "${C_RESET:-}" 8 74 "${C_TIP:-}"
  printf '  %b%-18s%b %b%s%b\n' "${C_LABEL:-}" "cache cleanup" "${C_RESET:-}" "${C_RESULT:-}" "$cache_status" "${C_RESET:-}"
  print_receipt_field "     " "note:" "$cache_note" "${C_RESET:-}" 8 74 "${C_TIP:-}"
  if [ "${_ua_reclaimed_kb:-0}" -gt 0 ] && declare -F format_kb_human >/dev/null 2>&1; then
    printf '  %b%-18s%b %b%s%b\n' "${C_LABEL:-}" "space reclaimed" "${C_RESET:-}" "${C_OK:-}" "$(format_kb_human "$_ua_reclaimed_kb")" "${C_RESET:-}"
  fi
  print_receipt_field "  " "guidance" "Cleanup choices are collected before updates start: answer yes only for cleanup you understand, and use --dry-run to preview commands again." "${C_PURPOSE:-}" 18 64 "${C_LABEL:-}"
  printf '%b\n\n' "$bar"
}

after_run_check_in() {
  local bar="$1" i
  printf '  %bAFTER-RUN CHECK-IN%b\n' "${C_HEADER:-}" "${C_RESET:-}"
  printf '%b\n' "$bar"
  print_receipt_field "  " "purpose" "What to resolve after this run, in plain English." "${C_PURPOSE:-}" 18 64 "${C_LABEL:-}"

  if [ "${rc:-0}" -ne 0 ]; then
    print_receipt_field "  " "status" "One or more update steps failed. Start with the FAIL rows above; the command did not finish cleanly." "${C_BAD:-}" 18 64 "${C_LABEL:-}"
  elif [ "${#_ua_concern_titles[@]}" -eq 0 ]; then
    print_receipt_field "  " "status" "No unresolved concerns were recorded. You can close the terminal or read the receipt for learning." "${C_OK:-}" 18 64 "${C_LABEL:-}"
  else
    print_receipt_field "  " "status" "The update sweep finished; review these notes when you come back." "${C_WARN:-}" 18 64 "${C_LABEL:-}"
  fi

  for ((i = 0; i < ${#_ua_concern_titles[@]}; i++)); do
    printf '\n  %b%s%b %b%s%b\n' "${C_UNIT:-}" "$G_ARROW" "${C_RESET:-}" "${C_HEADER:-}" "${_ua_concern_titles[$i]}" "${C_RESET:-}"
    print_receipt_field "     " "means:" "${_ua_concern_notes[$i]}" "${C_RESET:-}" 8 74 "${C_TIP:-}"
    print_receipt_field "     " "action:" "${_ua_concern_actions[$i]}" "${C_RESET:-}" 8 74 "${C_TIP:-}"
  done

  printf '%b\n\n' "$bar"
}

report() {
  local width bar rule_ch="─" start_s i updated=0 ok=0 unchanged=0 failed=0 skipped=0 security="${_ua_count_security:-0}"
  local lbl stat before after note icon color npm_active npm_bundled

  if declare -F tui_teardown >/dev/null 2>&1; then
    tui_teardown
  fi

  _ua_ended_s="$(date +%s)"
  start_s="${_ua_started_s:-$_ua_ended_s}"
  _ua_elapsed=$(( _ua_ended_s - start_s ))

  for ((i = 0; i < ${#_ua_stats[@]}; i++)); do
    case "${_ua_stats[$i]}" in
      UPDATED)   updated=$((updated + 1)) ;;
      OK)        ok=$((ok + 1)) ;;
      UNCHANGED) unchanged=$((unchanged + 1)) ;;
      FAIL)      failed=$((failed + 1)) ;;
      SKIP)      skipped=$((skipped + 1)) ;;
    esac
  done

  banner "RECEIPT"
  width="$(_receipt_rule_width)"
  if [ "${_ua_utf8:-1}" -eq 0 ]; then
    rule_ch="-"
  fi
  bar="${C_FRAME:-}$(_receipt_repeat "$rule_ch" "$width")${C_RESET:-}"

  printf '%b\n' "$bar"
  printf '  %b%-16s%b %s\n' "${C_HEADER:-}" "started" "${C_RESET:-}" "${_ua_started_h:-unknown}"
  printf '  %b%-16s%b %ss\n' "${C_HEADER:-}" "elapsed" "${C_RESET:-}" "$_ua_elapsed"
  if [ "${_ua_reclaimed_kb:-0}" -gt 0 ] && declare -F format_kb_human >/dev/null 2>&1; then
    printf '  %b%-16s%b %b%s%b\n' "${C_HEADER:-}" "reclaimed" "${C_RESET:-}" "${C_OK:-}" "$(format_kb_human "$_ua_reclaimed_kb")" "${C_RESET:-}"
  fi
  printf '%b  receipt summary%b    %b%s %s updated%b  %b%s %s ok%b  %b%s %s unchanged%b  %b%s %s skipped%b  %b%s %s failed%b' \
    "${C_HEADER:-}" "${C_RESET:-}" \
    "${C_OK:-}" "$G_UPDATED" "$updated" "${C_RESET:-}" \
    "${C_OK:-}" "$G_OK" "$ok" "${C_RESET:-}" \
    "${C_RESULT:-}" "$G_UNCHANGED" "$unchanged" "${C_RESET:-}" \
    "${C_TIP:-}" "$G_SKIP" "$skipped" "${C_RESET:-}" \
    "${C_BAD:-}" "$G_FAIL" "$failed" "${C_RESET:-}"
  if [ "$security" -gt 0 ]; then
    printf '  %b%s %s security%b' "${C_WARN:-}" "$G_SAFETY" "$security" "${C_RESET:-}"
  fi
  printf '\n'
  printf '%b\n' "$bar"

  print_changed_story "$bar"
  print_attention_story "$bar"
  print_no_action_needed "$bar"
  printf '\n'

  printf '  %bRUN DETAILS%b\n' "${C_HEADER:-}" "${C_RESET:-}"
  printf '%b\n' "$bar"

  for ((i = 0; i < ${#_ua_labels[@]}; i++)); do
    lbl="${_ua_labels[$i]}"
    stat="${_ua_stats[$i]}"
    before="${_ua_before[$i]}"
    after="${_ua_after[$i]}"
    note="${_ua_notes[$i]}"
    receipt_status_style "$stat" icon color

    printf '  %b%s %-9s%b ' "$color" "$icon" "$stat" "${C_RESET:-}"
    if declare -F styled_package_name >/dev/null 2>&1; then
      printf '%s\n' "$(styled_package_name "$lbl")"
    else
      printf '%s\n' "$lbl"
    fi
    if [ -n "$before" ] || [ -n "$after" ]; then
      print_receipt_version_pair "$stat" "$before" "$after"
    fi
    if [ -n "$note" ]; then
      printf '     %b%-8s%b %s\n' "${C_TIP:-}" "note:" "${C_RESET:-}" "$note"
    fi
  done

  printf '%b\n' "$bar"
  npm_active="$(version_of npm-active 2>/dev/null || printf 'not found')"
  npm_bundled="$(version_of npm-bundled 2>/dev/null || printf 'not found')"
  print_receipt_field "  " "active npm" "$npm_active" "${C_RESET:-}" 12 72 "${C_HEADER:-}"
  print_receipt_field "  " "bundled npm" "$npm_bundled" "${C_RESET:-}" 12 72 "${C_HEADER:-}"
  print_receipt_field "  " "npm fund" "npm funding notices are optional donation links, not errors or bills." "${C_RESET:-}" 12 72 "${C_HEADER:-}"
  print_receipt_field "  " "notes" "package purpose notes are plain-English guidance; OSV/port findings belong to Safety Coach." "${C_RESET:-}" 12 72 "${C_HEADER:-}"
  printf '%b\n\n' "$bar"

  cleanup_next_steps "$bar"
  after_run_check_in "$bar"

  if [ "${rc:-0}" -eq 0 ]; then
    printf '%b%s  update-all finished without failed steps%b\n\n' "${C_OK:-}" "$G_OK" "${C_RESET:-}"
  else
    printf '%b%s  one or more steps failed - see FAIL rows above%b\n\n' "${C_BAD:-}" "$G_FAIL" "${C_RESET:-}"
  fi
}

receipt_visual_selftest() {
  _ua_started_s="$(date +%s)"
  _ua_started_h="2026-07-01 00:00:00 TEST"
  rc=0
  _ua_labels=("yarn (corepack)" "brew formula: libevent" "uv tool: pillow" "apt upgrade" "flatpak update" "coverage preflight")
  _ua_stats=("UPDATED" "UPDATED" "UPDATED" "UNCHANGED" "SKIP" "OK")
  _ua_before=("/usr/bin/yarn 1.22.22" "libevent 2.1.12_1" "pillow 12.2.0" "0 upgradable" "" "")
  _ua_after=("/usr/bin/yarn 4.17.0" "2.1.13" "12.3.0" "0 upgradable" "" "")
  _ua_notes=("bounded by UPDATE_ALL_COREPACK_TIMEOUT (default 90s)" "Homebrew upgraded a formula" "uv updated the nano-pdf tool environment" "" "flatpak command not installed" "installed safe surfaces are updated; project-specific stacks stay explicit")
  _ua_delta_pkgs=("yarn (corepack)" "libevent" "pillow")
  _ua_delta_before=("1.22.22" "2.1.12_1" "12.2.0")
  _ua_delta_after=("4.17.0" "2.1.13" "12.3.0")
  _ua_delta_via=("corepack" "brew" "uv")
  _ua_concern_titles=()
  _ua_concern_notes=()
  _ua_concern_actions=()
  add_concern "Firmware needs manual attention" "fwupd has UEFI/Secure Boot firmware updates that should not be blindly applied." "Review with fwupdmgr get-updates when you are ready to watch it."
  report
}

visual_preview_all() {
  local prev_nonint="${UPDATE_ALL_NONINTERACTIVE:-0}"
  UPDATE_ALL_NONINTERACTIVE=1

  if declare -F intro >/dev/null 2>&1; then
    intro
  fi

  if declare -F show_update_coverage_preflight >/dev/null 2>&1; then
    show_update_coverage_preflight
  fi

  if declare -F section >/dev/null 2>&1 && declare -F tool_card >/dev/null 2>&1; then
    section "sample tool update"
    tool_card "npm" "npm self-update" "/usr/local/bin/npm 10.9.0" "npm"
    tool_result "UPDATED" "preview card showing before/after stacked versions"
    print_receipt_version_pair "UPDATED" "/usr/local/bin/npm 10.9.0" "/usr/local/bin/npm 11.1.0" "version" "   " 15
  fi

  if declare -F cleanup_question >/dev/null 2>&1; then
    cleanup_question preview
  fi
  if declare -F workstation_cleanup_question >/dev/null 2>&1; then
    workstation_cleanup_question preview
  fi

  _ua_reclaimed_kb=421888
  _ua_sec_kind=()
  _ua_sec_sev=()
  _ua_sec_target=()
  _ua_sec_id=()
  _ua_sec_summary=()
  _ua_sec_remedy_desc=()
  _ua_sec_remedy_cmd=()
  _ua_sec_alt_cmd=()
  _ua_count_security=0

  if declare -F add_security_finding >/dev/null 2>&1; then
    add_security_finding "MALICIOUS" "CRITICAL" "demo-malicious-pkg@1.0.2 (npm)" "MAL-2026-0001" \
      "Sample preview: OpenSSF flagged this package as malicious." \
      "Uninstall immediately and rotate any credentials exposed in its environment." \
      "npm uninstall -g demo-malicious-pkg" "npm list -g demo-malicious-pkg"
    add_security_finding "EXPOSED PORT" "WARN" "dev-server (tcp/3000 on all interfaces (0.0.0.0))" "PORT-TCP-3000" \
      "Sample preview: process is bound to all interfaces instead of 127.0.0.1." \
      "Rebind to 127.0.0.1 or block port 3000 with ufw." \
      "sudo ufw deny 3000/tcp" "ss -tulnpH sport = :3000"
  fi

  receipt_visual_selftest

  if declare -F run_safety_coach_remedy >/dev/null 2>&1; then
    run_safety_coach_remedy
  fi

  UPDATE_ALL_NONINTERACTIVE="$prev_nonint"
}
