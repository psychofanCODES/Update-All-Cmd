# shellcheck shell=bash
# Zero-stall command runner, streaming redactor, and sudo engine for update-all.
# Strictly Bash 3.2+ parse-compatible (macOS bash 3.2.57 & Linux bash 5.x).

UPDATE_ALL_STEP_TIMEOUT="${UPDATE_ALL_STEP_TIMEOUT:-600s}"
UPDATE_ALL_PROBE_TIMEOUT="${UPDATE_ALL_PROBE_TIMEOUT:-15s}"
UPDATE_ALL_DRY_RUN="${UPDATE_ALL_DRY_RUN:-0}"
UPDATE_ALL_NONINTERACTIVE="${UPDATE_ALL_NONINTERACTIVE:-0}"

_ua_tmp_dir="${_ua_tmp_dir:-}"; _ua_runtime_initialized="${_ua_runtime_initialized:-0}"
_ua_tools_probed="${_ua_tools_probed:-0}"; _ua_has_timeout="${_ua_has_timeout:-0}"
_ua_has_timeout_k="${_ua_has_timeout_k:-0}"; _ua_has_stdbuf="${_ua_has_stdbuf:-0}"
_ua_exiting="${_ua_exiting:-0}"; _ua_interrupted="${_ua_interrupted:-0}"
_ua_tui_resized="${_ua_tui_resized:-0}"; _ua_fifo_seq="${_ua_fifo_seq:-0}"
_ua_active_cmd_pid="${_ua_active_cmd_pid:-}"; _ua_active_filter_pid="${_ua_active_filter_pid:-}"
_ua_sudo_keepalive_pid="${_ua_sudo_keepalive_pid:-}"; _ua_sudo_keepalive_stopped="${_ua_sudo_keepalive_stopped:-0}"
_ua_needs_sudo="${_ua_needs_sudo:-0}"
_ua_last_tick_cs=0; _ua_last_tick_s=-1; _ua_last_output_line=""

_UA_SECRET_HINT_RE='(sk-|github_pat_|gh[pousr]_|xox[baprs]-|AKIA[0-9A-Z]{16}|PRIVATE KEY-----|(TOKEN|PASSWORD|PASS|SECRET|API_KEY|APIKEY|ACCESS_KEY)[A-Za-z0-9_]*[[:space:]]*=)'

# ---------------------------------------------------------------------------
# 1. Unified Temp Dir & Trap Manager
# ---------------------------------------------------------------------------
_ua_probe_runner_tools() {
  [ "${_ua_tools_probed:-0}" -eq 0 ] || return 0
  _ua_tools_probed=1
  _ua_has_timeout=0
  _ua_has_timeout_k=0
  _ua_has_stdbuf=0
  if command -v timeout >/dev/null 2>&1; then
    _ua_has_timeout=1
    timeout -k 1s 2s true >/dev/null 2>&1 && _ua_has_timeout_k=1
  fi
  if command -v stdbuf >/dev/null 2>&1 && stdbuf -i0 -o0 true >/dev/null 2>&1; then
    _ua_has_stdbuf=1
  fi
}

_ua_reap_pid() {
  local pid="${1:-}"
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    if kill -0 "$pid" 2>/dev/null; then
      sleep 0.05 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

ua_init_runtime() {
  _ua_probe_runner_tools
  if [ "${_ua_runtime_initialized:-0}" -eq 1 ] && [ -n "${_ua_tmp_dir:-}" ] && [ -d "$_ua_tmp_dir" ]; then
    return 0
  fi

  local base_tmp="${TMPDIR:-/tmp}"
  base_tmp="${base_tmp%/}"
  _ua_tmp_dir="$(mktemp -d "${base_tmp}/update-all.XXXXXX")"
  chmod 700 "$_ua_tmp_dir"
  _ua_exiting=0
  _ua_interrupted=0
  _ua_runtime_initialized=1

  trap '_ua_on_exit' EXIT
  trap '_ua_on_signal INT 130' INT
  trap '_ua_on_signal TERM 143' TERM
  trap '_ua_tui_resized=1' WINCH
}

_ua_on_exit() {
  [ "${_ua_exiting:-0}" -eq 0 ] || return 0
  _ua_exiting=1

  _ua_reap_pid "${_ua_active_cmd_pid:-}"
  _ua_active_cmd_pid=""
  _ua_reap_pid "${_ua_active_filter_pid:-}"
  _ua_active_filter_pid=""

  sudo_keepalive_stop
  declare -F tui_teardown >/dev/null 2>&1 && tui_teardown

  if [ -n "${_ua_tmp_dir:-}" ] && [ -d "$_ua_tmp_dir" ]; then
    rm -rf -- "$_ua_tmp_dir" 2>/dev/null || true
  fi
  _ua_tmp_dir=""
  _ua_runtime_initialized=0
}

_ua_on_signal() {
  local sig="${1:-INT}" code="${2:-130}"
  _ua_interrupted=1
  trap - INT TERM
  _ua_on_exit
  if [ "$sig" = "INT" ]; then
    printf '\n%bInterrupted (Ctrl+C). Terminal restored.%b\n' "${C_WARN:-}" "${C_RESET:-}" >&2
  fi
  exit "$code"
}

# ---------------------------------------------------------------------------
# 2. Fast-Path Redaction & Zero-Fork Coloring
# ---------------------------------------------------------------------------
redact_secrets() {
  local text="${1:-}"
  if [ -z "$text" ] || [[ ! "$text" =~ $_UA_SECRET_HINT_RE ]]; then
    printf '%s' "$text"
    return 0
  fi
  printf '%s' "$text" | sed -E \
    -e 's/sk-[A-Za-z0-9_-]{20,}/[REDACTED_OPENAI_KEY]/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED_GITHUB_TOKEN]/g' \
    -e 's/gh[pousr]_[A-Za-z0-9_]{20,}/[REDACTED_GITHUB_TOKEN]/g' \
    -e 's/xox[baprs]-[A-Za-z0-9-]{20,}/[REDACTED_SLACK_TOKEN]/g' \
    -e 's/AKIA[0-9A-Z]{16}/[REDACTED_AWS_ACCESS_KEY]/g' \
    -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/[REDACTED_PRIVATE_KEY_BEGIN]/g' \
    -e 's/([A-Za-z_][A-Za-z0-9_]*(TOKEN|PASSWORD|PASS|SECRET|API_KEY|APIKEY|ACCESS_KEY)[A-Za-z0-9_]*[[:space:]]*=[[:space:]]*)[^[:space:]\[]+/\1[REDACTED]/g'
}

_ua_redact_into() {
  local __var="$1" text="$2" cleaned=""
  if [ -z "$text" ] || [[ ! "$text" =~ $_UA_SECRET_HINT_RE ]]; then
    printf -v "$__var" '%s' "$text"
    return 0
  fi
  cleaned="$(redact_secrets "$text")"
  printf -v "$__var" '%s' "$cleaned"
}

_ua_normalize_cr_into() {
  local __var="$1" raw="$2"
  if [[ "$raw" != *$'\r'* ]]; then
    printf -v "$__var" '%s' "$raw"
    return 0
  fi
  local rest="$raw" seg="" last=""
  while [ -n "$rest" ]; do
    if [[ "$rest" == *$'\r'* ]]; then
      seg="${rest%%$'\r'*}"
      rest="${rest#*$'\r'}"
    else
      seg="$rest"
      rest=""
    fi
    [ -n "${seg//[[:space:]]/}" ] && last="$seg"
  done
  printf -v "$__var" '%s' "$last"
}

color_log_line() {
  local line="${1:-}"
  if [ -z "$line" ]; then
    printf '\n'
    return 0
  fi

  local prefix=""
  if [ "${UPDATE_ALL_DRY_RUN:-0}" != 1 ] && [ "${UPDATE_ALL_REDACTION_SELFTEST:-0}" != 1 ] \
    && [ "${UPDATE_ALL_STDIN_SELFTEST:-0}" != 1 ] && [ -z "${UPDATE_ALL_SUDO_SELFTEST:-}" ] \
    && declare -F tui_bar_enabled >/dev/null 2>&1 && tui_bar_enabled; then
    prefix="${C_FRAME:-}    │ ${C_RESET:-}"
  fi

  local had_nocasematch=0 color="${C_LOG:-}"
  shopt -q nocasematch && had_nocasematch=1
  shopt -s nocasematch

  if [[ "$line" == *error* || "$line" == *failed* || "$line" == *fatal* || "$line" == "e: "* || "$line" == *"cannot "* || "$line" == *"not found"* ]]; then
    color="${C_BAD:-}"
  elif [[ "$line" == *warn* || "$line" == *deprecated* || "$line" == *audit* || "$line" == *vulnerab* || "$line" == *notice* || "$line" == *"held back"* ]]; then
    color="${C_WARN:-}"
  elif [[ "$line" == *added* || "$line" == *changed* || "$line" == *updated* || "$line" == *upgraded* || "$line" == *installed* || "$line" == *success* || "$line" == *done* || "$line" == *"already up to date"* ]]; then
    color="${C_OK:-}"
  elif [[ "$line" == *removed* || "$line" == *removing* || "$line" == *autoremove* || "$line" == *prune* || "$line" == *cleanup* ]]; then
    color="${C_TIP:-}"
  elif [[ "$line" == *fund* || "$line" == *donation* ]]; then
    color="${C_TIP:-}"
  elif [[ "$line" == "preparing "*"@"*" for immediate activation"* ]]; then
    color="${C_APT_PROGRESS:-}"
  elif [[ "$line" == *@anthropic-ai/claude-code* || "$line" == *@openai/codex* || "$line" == *pnpm@* || "$line" == *npm@* || "$line" == *yarn@* ]]; then
    color="${C_HEADER:-}"
  elif [[ "$line" == "fetched "* || "$line" == "reading package lists"* || "$line" == "building dependency tree"* || "$line" == "reading state information"* ]]; then
    color="${C_APT_PROGRESS:-}"
  elif [[ "$line" == hit:* || "$line" == get:* || "$line" == ign:* ]]; then
    color="${C_APT_SOURCE:-}"
  fi

  [ "$had_nocasematch" -eq 0 ] && shopt -u nocasematch
  printf '%b%b%s%b\n' "$prefix" "$color" "$line" "${C_RESET:-}"
}

_ua_strip_nul_stream() {
  [ "${_ua_tools_probed:-0}" -eq 0 ] && _ua_probe_runner_tools
  if [ "${_ua_has_stdbuf:-0}" -eq 1 ]; then
    stdbuf -i0 -o0 tr -d '\000'
  else
    tr -d '\000'
  fi
}

color_log_stream() {
  local line
  _ua_strip_nul_stream | while IFS= read -r line || [ -n "$line" ]; do
    line="${line//^@/}"
    _ua_redact_into line "$line"
    color_log_line "$line"
  done
}

# ---------------------------------------------------------------------------
# 3. Single-Writer Live Concurrent Watcher Engine
# ---------------------------------------------------------------------------
_ua_watcher_tick() {
  local label="${1:-}" force="${2:-0}"

  if [ "${_ua_tui_resized:-0}" -eq 1 ]; then
    _ua_tui_resized=0
    declare -F tui_handle_resize >/dev/null 2>&1 && tui_handle_resize
  fi

  [ "${UPDATE_ALL_DRY_RUN:-0}" != 1 ] || return 0
  declare -F tui_draw_dock >/dev/null 2>&1 || return 0

  if [ "$force" -eq 0 ]; then
    if [ "${BASH_VERSINFO[0]:-3}" -ge 5 ] && [ -n "${EPOCHREALTIME:-}" ]; then
      local now_cs="${EPOCHREALTIME/./}"
      now_cs="${now_cs:0:${#now_cs}-4}"
      [ $(( now_cs - _ua_last_tick_cs )) -lt 10 ] && return 0
      _ua_last_tick_cs="$now_cs"
    else
      local now_s="${SECONDS:-0}"
      [ "$now_s" -eq "${_ua_last_tick_s:--1}" ] && return 0
      _ua_last_tick_s="$now_s"
    fi
  fi

  tui_draw_dock "$label"
}

_ua_emit_watched_line() {
  local raw="$1" cap_file="$2" quiet="$3" had_cr=0 line=""
  raw="${raw//^@/}"
  [[ "$raw" == *$'\r'* ]] && had_cr=1
  _ua_normalize_cr_into line "$raw"
  [ "$had_cr" -eq 1 ] && [ -z "$line" ] && return 0

  _ua_redact_into line "$line"
  [ -n "$cap_file" ] && printf '%s\n' "$line" >> "$cap_file"
  [ "$quiet" -eq 0 ] && color_log_line "$line"
  [ -n "$line" ] && _ua_last_output_line="$line"
}

_ua_exec_fallback() {
  local capture_var="$1" cap_file="$2" quiet="$3" secret_key="$4"
  shift 4
  local code=0 line=""

  if [ -n "$capture_var" ]; then
    if [ -n "$secret_key" ]; then
      secret get "$secret_key" 2>/dev/null | "$@" 2>&1 | _ua_strip_nul_stream \
        | while IFS= read -r line || [ -n "$line" ]; do _ua_emit_watched_line "$line" "$cap_file" "$quiet"; done
      code="${PIPESTATUS[1]}"
    else
      "$@" </dev/null 2>&1 | _ua_strip_nul_stream \
        | while IFS= read -r line || [ -n "$line" ]; do _ua_emit_watched_line "$line" "$cap_file" "$quiet"; done
      code="${PIPESTATUS[0]}"
    fi
    local captured=""
    if [ -f "$cap_file" ]; then
      captured="$(< "$cap_file")"
      rm -f -- "$cap_file"
    fi
    printf -v "$capture_var" '%s' "$captured"
    return "$code"
  fi

  if [ "$quiet" -eq 1 ]; then
    if [ -n "$secret_key" ]; then
      secret get "$secret_key" 2>/dev/null | "$@" >/dev/null 2>&1; code="${PIPESTATUS[1]}"
    else
      "$@" </dev/null >/dev/null 2>&1 || code=$?
    fi
  elif [ -n "$secret_key" ]; then
    secret get "$secret_key" 2>/dev/null | "$@" 2>&1 | color_log_stream; code="${PIPESTATUS[1]}"
  else
    "$@" </dev/null 2>&1 | color_log_stream; code="${PIPESTATUS[0]}"
  fi
  return "$code"
}

ua_exec_watched() {
  local capture_var="" quiet=0 limit="" label="" secret_key=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --capture) capture_var="${2:-}"; shift 2 ;;
      --quiet) quiet=1; shift ;;
      --timeout) limit="${2:-}"; shift 2 ;;
      --label) label="${2:-}"; shift 2 ;;
      --stdin-secret) secret_key="${2:-}"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  if [ $# -eq 0 ]; then
    [ -n "$capture_var" ] && printf -v "$capture_var" '%s' ''
    return 0
  fi
  if [ "${UPDATE_ALL_DRY_RUN:-0}" = 1 ]; then
    show_cmd "$@"
    [ -n "$capture_var" ] && printf -v "$capture_var" '%s' ''
    return 0
  fi

  ua_init_runtime

  local is_external=0 use_child_stdbuf=0
  type -P "$1" >/dev/null 2>&1 && is_external=1
  if [ "${_ua_has_stdbuf:-0}" -eq 1 ] && [ "$is_external" -eq 1 ]; then
    case "$1" in sudo|*/sudo) ;; *) use_child_stdbuf=1 ;; esac
  fi

  declare -a cmd_argv=()
  if [ -n "$limit" ] && [ "${_ua_has_timeout:-0}" -eq 1 ] && [ "$is_external" -eq 1 ]; then
    if [ "${_ua_has_timeout_k:-0}" -eq 1 ]; then
      cmd_argv=(timeout -k 10s "$limit")
    else
      cmd_argv=(timeout "$limit")
    fi
  fi
  [ "$use_child_stdbuf" -eq 1 ] && cmd_argv+=(stdbuf -oL -eL)
  cmd_argv+=("$@")

  _ua_fifo_seq=$(( _ua_fifo_seq + 1 ))
  local stem="$_ua_tmp_dir/cmd.${BASHPID:-$$}.${_ua_fifo_seq}"
  local raw_fifo="${stem}.raw.fifo" out_fifo="${stem}.out.fifo" cap_file=""

  if [ -n "$capture_var" ]; then
    cap_file="${stem}.cap"
    : > "$cap_file"
    chmod 600 "$cap_file"
  fi

  if ! mkfifo -m 600 "$raw_fifo" "$out_fifo" 2>/dev/null; then
    rm -f -- "$raw_fifo" "$out_fifo" 2>/dev/null || true
    _ua_exec_fallback "$capture_var" "$cap_file" "$quiet" "$secret_key" "${cmd_argv[@]}"
    return $?
  fi

  local monitor_was_on=0
  case "$-" in *m*) monitor_was_on=1; set +m ;; esac

  _ua_strip_nul_stream < "$raw_fifo" > "$out_fifo" &
  local filter_pid=$!
  _ua_active_filter_pid="$filter_pid"

  local cmd_pid=""
  if [ -n "$secret_key" ]; then
    "${cmd_argv[@]}" < <(secret get "$secret_key" 2>/dev/null) > "$raw_fifo" 2>&1 &
  else
    "${cmd_argv[@]}" </dev/null > "$raw_fifo" 2>&1 &
  fi
  cmd_pid=$!
  _ua_active_cmd_pid="$cmd_pid"
  [ "$monitor_was_on" -eq 1 ] && set -m

  exec 3< "$out_fifo"
  _ua_watcher_tick "$label" 1

  local line="" pending="" read_rc=0 dead_ticks=0 is_bash4=0
  [ "${BASH_VERSINFO[0]:-3}" -ge 4 ] && is_bash4=1

  while true; do
    line=""
    read_rc=0
    if [ "$is_bash4" -eq 1 ]; then
      IFS= read -r -t 0.08 line <&3 || read_rc=$?
    else
      IFS= read -r -t 1 line <&3 || read_rc=$?
    fi

    if [ "$read_rc" -eq 0 ]; then
      dead_ticks=0
      if [ -n "$pending" ]; then line="${pending}${line}"; pending=""; fi
      _ua_emit_watched_line "$line" "$cap_file" "$quiet"
      _ua_watcher_tick "$label" 0
      continue
    fi

    if [ "$is_bash4" -eq 1 ] && [ "$read_rc" -le 128 ]; then
      line="${pending}${line}"
      [ -n "$line" ] && _ua_emit_watched_line "$line" "$cap_file" "$quiet"
      break
    fi

    if [ -n "$line" ]; then
      pending="${pending}${line}"
      [[ "$pending" == *$'\r'* ]] && _ua_normalize_cr_into pending "$pending"
    fi
    _ua_watcher_tick "$label" 0

    if [ "$is_bash4" -eq 1 ]; then
      if ! kill -0 "$cmd_pid" 2>/dev/null; then
        dead_ticks=$(( dead_ticks + 1 ))
        if [ "$dead_ticks" -ge 3 ]; then
          [ -n "$pending" ] && _ua_emit_watched_line "$pending" "$cap_file" "$quiet"
          break
        fi
      fi
    else
      if ! kill -0 "$filter_pid" 2>/dev/null; then
        [ -n "$pending" ] && _ua_emit_watched_line "$pending" "$cap_file" "$quiet"
        break
      fi
      if ! kill -0 "$cmd_pid" 2>/dev/null; then
        dead_ticks=$(( dead_ticks + 1 ))
        if [ "$dead_ticks" -ge 2 ]; then
          [ -n "$pending" ] && _ua_emit_watched_line "$pending" "$cap_file" "$quiet"
          break
        fi
      fi
    fi
  done

  exec 3<&-

  local cmd_rc=0
  wait "$cmd_pid" 2>/dev/null || cmd_rc=$?
  _ua_active_cmd_pid=""

  if kill -0 "$filter_pid" 2>/dev/null; then
    _ua_reap_pid "$filter_pid"
  else
    wait "$filter_pid" 2>/dev/null || true
  fi
  _ua_active_filter_pid=""
  rm -f -- "$raw_fifo" "$out_fifo" 2>/dev/null || true

  if [ -n "$capture_var" ]; then
    local captured=""
    if [ -f "$cap_file" ]; then
      captured="$(< "$cap_file")"
      rm -f -- "$cap_file"
    fi
    printf -v "$capture_var" '%s' "$captured"
  fi
  return "$cmd_rc"
}

# ---------------------------------------------------------------------------
# 4. Runner Wrappers
# ---------------------------------------------------------------------------
show_cmd() { printf '%b$%b' "${C_CMD:-}" "${C_RESET:-}"; printf ' %q' "$@"; printf '\n'; }

run_bounded() {
  local limit="$1"; shift
  if [ "${UPDATE_ALL_DRY_RUN:-0}" = 1 ]; then show_cmd "$@"; return 0; fi
  ua_exec_watched --timeout "$limit" -- "$@"
}

run_cmd() { ua_exec_watched --timeout "${UPDATE_ALL_STEP_TIMEOUT:-600s}" -- "$@"; }

run_cmd_capture() {
  local __var="$1"; shift
  ua_exec_watched --capture "$__var" --timeout "${UPDATE_ALL_STEP_TIMEOUT:-600s}" -- "$@"
}

run_cmd_capture_quiet() {
  local __var="$1"; shift
  ua_exec_watched --capture "$__var" --quiet --timeout "${UPDATE_ALL_PROBE_TIMEOUT:-15s}" -- "$@"
}

run_shell() {
  ua_exec_watched --timeout "${UPDATE_ALL_STEP_TIMEOUT:-600s}" -- \
    env -u BASH_ENV -u ENV bash --noprofile --norc -c "$1"
}

run_shell_capture() {
  ua_exec_watched --capture "$1" --timeout "${UPDATE_ALL_STEP_TIMEOUT:-600s}" -- \
    env -u BASH_ENV -u ENV bash --noprofile --norc -c "$2"
}

run_probe_bounded() {
  local limit="$1"; shift
  [ "${_ua_tools_probed:-0}" -eq 0 ] && _ua_probe_runner_tools
  if [ "${_ua_has_timeout:-0}" -eq 1 ]; then
    if [ "${_ua_has_timeout_k:-0}" -eq 1 ]; then
      timeout -k 3s "$limit" "$@" </dev/null 2>/dev/null
    else
      timeout "$limit" "$@" </dev/null 2>/dev/null
    fi
  else
    "$@" </dev/null 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# 5. Rock-Solid Sudo Engine & Keepalive
# ---------------------------------------------------------------------------
sudo_secret_available() {
  [ -n "${UPDATE_ALL_SUDO_SECRET_KEY:-}" ] || return 1
  command -v secret >/dev/null 2>&1 || return 1
  secret has "$UPDATE_ALL_SUDO_SECRET_KEY" 2>/dev/null
}

_ua_sudo_exec() {
  local capture_var="$1"; shift
  if [ "${UPDATE_ALL_DRY_RUN:-0}" = 1 ]; then
    show_cmd sudo "$@"
    [ -n "$capture_var" ] && printf -v "$capture_var" '%s' ''
    return 0
  fi

  declare -a watch_args=(--timeout "${UPDATE_ALL_STEP_TIMEOUT:-600s}")
  [ -n "$capture_var" ] && watch_args+=(--capture "$capture_var")

  if ! command -v sudo >/dev/null 2>&1; then
    ua_exec_watched "${watch_args[@]}" -- "$@"
    return $?
  fi
  if sudo_secret_available; then
    ua_exec_watched "${watch_args[@]}" --stdin-secret "$UPDATE_ALL_SUDO_SECRET_KEY" -- sudo -S -p '' "$@"
    return $?
  fi
  if sudo -n true 2>/dev/null; then
    ua_exec_watched "${watch_args[@]}" -- sudo -n "$@"
    return $?
  fi

  if [ -t 0 ] && [ -t 1 ] && [ "${UPDATE_ALL_NONINTERACTIVE:-0}" != 1 ]; then
    declare -F tui_pause_for_tty >/dev/null 2>&1 && tui_pause_for_tty
    printf '\n%bSudo session expired — please re-authenticate:%b\n' "${C_WARN:-}" "${C_RESET:-}" >&2
    local auth_rc=0
    sudo -v </dev/tty || auth_rc=$?
    declare -F tui_resume_after_tty >/dev/null 2>&1 && tui_resume_after_tty
    if [ "$auth_rc" -ne 0 ]; then
      [ -n "$capture_var" ] && printf -v "$capture_var" '%s' ''
      return "$auth_rc"
    fi
    ua_exec_watched "${watch_args[@]}" -- sudo -n "$@"
    return $?
  fi

  printf '%bsudo authentication required, but running non-interactively (cannot prompt for password).%b\n' \
    "${C_BAD:-}" "${C_RESET:-}" >&2
  [ -n "$capture_var" ] && printf -v "$capture_var" '%s' ''
  return 1
}

sudo_cmd() { _ua_sudo_exec "" "$@"; }

sudo_cmd_capture() {
  local __var="$1"; shift
  _ua_sudo_exec "$__var" "$@"
}

sudo_noninteractive_apt() {
  sudo_cmd env DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    NEEDRESTART_MODE=l UCF_FORCE_CONFFOLD=1 APT_LISTCHANGES_FRONTEND=none \
    PAGER=cat TERM=dumb "$@"
}

sudo_keepalive_stop() {
  [ "${_ua_sudo_keepalive_stopped:-0}" -eq 0 ] || return 0
  _ua_sudo_keepalive_stopped=1
  if [ -n "${_ua_sudo_keepalive_pid:-}" ]; then
    kill -TERM "$_ua_sudo_keepalive_pid" 2>/dev/null || true
    wait "$_ua_sudo_keepalive_pid" 2>/dev/null || true
    _ua_sudo_keepalive_pid=""
  fi
}

prime_sudo() {
  [ "${UPDATE_ALL_DRY_RUN:-0}" = 0 ] || return 0
  if [ "${_ua_needs_sudo:-0}" != 1 ] && [ -z "${UPDATE_ALL_SUDO_SELFTEST:-}" ]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || return 0
  sudo_secret_available && return 0

  if ! sudo -n true 2>/dev/null; then
    if [ "${UPDATE_ALL_NONINTERACTIVE:-0}" = 1 ] || [ ! -t 0 ] || [ ! -t 1 ]; then
      printf '%bsudo authentication required, but running non-interactively (cannot prompt for password).%b\n' \
        "${C_BAD:-}" "${C_RESET:-}" >&2
      return 1
    fi
    sudo -v </dev/tty || return $?
  fi

  sudo_keepalive_stop
  _ua_sudo_keepalive_stopped=0

  local parent_pid="$$" monitor_was_on=0
  case "$-" in *m*) monitor_was_on=1; set +m ;; esac
  {
    (
      exec </dev/null >/dev/null 2>&1
      while kill -0 "$parent_pid" 2>/dev/null; do
        sleep 30 &
        _sp=$!
        trap 'kill "$_sp" 2>/dev/null || true; exit 0' INT TERM
        wait "$_sp" 2>/dev/null || exit 0
        sudo -n -v >/dev/null 2>&1 || exit 0
      done
    ) &
    _ua_sudo_keepalive_pid=$!
  } 2>/dev/null
  [ "$monitor_was_on" -eq 1 ] && set -m
  return 0
}
