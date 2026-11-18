#!/usr/bin/env bash
# Comprehensive TDD & UX contract test suite for update-all.
# Strictly Bash 3.2+ parse-compatible and ShellCheck-clean; runs in <15s on macOS & Ubuntu.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE_ALL="$ROOT_DIR/bin/update-all"
DIST_BUNDLE="$ROOT_DIR/dist/update-all"

PASS_COUNT=0
FAIL_COUNT=0
START_S="$(date +%s)"

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null; then
    pass
  else
    fail "$msg (missing: $needle)"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null; then
    fail "$msg (unexpected: $needle)"
  else
    pass
  fi
}

assert_regex() {
  local haystack="$1" pattern="$2" msg="$3"
  if printf '%s\n' "$haystack" | grep -E -- "$pattern" >/dev/null; then
    pass
  else
    fail "$msg (pattern not matched: $pattern)"
  fi
}

assert_not_regex() {
  local haystack="$1" pattern="$2" msg="$3"
  if printf '%s\n' "$haystack" | grep -E -- "$pattern" >/dev/null; then
    fail "$msg (unexpected pattern: $pattern)"
  else
    pass
  fi
}

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  if [ "$actual" = "$expected" ]; then
    pass
  else
    fail "$msg (expected '$expected', got '$actual')"
  fi
}

assert_file_not_exists() {
  local target="$1" msg="$2"
  if [ -e "$target" ]; then
    fail "$msg (unexpected file exists: $target)"
  else
    pass
  fi
}

assert_file_contains() {
  local target="$1" needle="$2" msg="$3"
  if [ -r "$target" ] && grep -F -- "$needle" "$target" >/dev/null; then
    pass
  else
    fail "$msg (missing '$needle' in $target)"
  fi
}

# Portable PTY runner (works identically on macOS BSD and Ubuntu Linux).
run_in_pty() {
  local pty_input="$1" pty_cmd="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$pty_input" "$pty_cmd" <<'PY'
import os, pty, select, subprocess, sys, time

inp = sys.argv[1].encode("utf-8")
cmd = sys.argv[2]
master, slave = pty.openpty()
proc = subprocess.Popen(
    ["/bin/bash", "-c", cmd],
    stdin=slave,
    stdout=slave,
    stderr=slave,
    close_fds=True,
)
os.close(slave)

sent = False
out = bytearray()
deadline = time.time() + 12.0
while time.time() < deadline:
    if inp and not sent and len(out) > 0:
        try:
            os.write(master, inp)
            sent = True
        except OSError:
            pass
    r, _, _ = select.select([master], [], [], 0.08)
    if r:
        try:
            chunk = os.read(master, 4096)
            if not chunk:
                break
            out.extend(chunk)
        except OSError:
            break
    elif proc.poll() is not None:
        break

if inp and not sent:
    try:
        os.write(master, inp)
    except OSError:
        pass
    time.sleep(0.1)
    while True:
        r, _, _ = select.select([master], [], [], 0.05)
        if not r:
            break
        try:
            chunk = os.read(master, 4096)
            if not chunk:
                break
            out.extend(chunk)
        except OSError:
            break

try:
    proc.wait(timeout=3)
except Exception:
    proc.kill()
os.close(master)
sys.stdout.buffer.write(out)
PY
    return $?
  fi

  if [ "$(uname -s)" = "Linux" ]; then
    printf '%s' "$pty_input" | timeout 12s script --quiet --flush --return --command "$pty_cmd" /dev/null || true
  else
    printf '%s' "$pty_input" | script -q /dev/null bash -c "$pty_cmd" || true
  fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf -- "$tmpdir"' EXIT

fake_home="$tmpdir/home"
posix_bin="$tmpdir/posix-bin"
mkdir -p -- "$fake_home" "$posix_bin"

# Minimal POSIX/coreutils PATH so host package managers (e.g. /usr/bin/apt-get
# on Ubuntu CI or /opt/homebrew/bin/brew on macOS) never leak into mocked tests.
for _u in \
  bash sh env awk sed grep tr cut cat head tail wc sort uniq fold \
  mktemp mkdir rm mv cp chmod date uname id readlink dirname basename \
  sleep kill mkfifo stty tput timeout stdbuf du df find python3 script \
  true false printf test '[' ls stat touch which; do
  _p="$(command -v "$_u" 2>/dev/null || true)"
  if [ -n "$_p" ] && [ -x "$_p" ]; then
    ln -sf "$_p" "$posix_bin/$_u"
  fi
done

make_mock() {
  local dir="$1" name="$2"
  mkdir -p -- "$dir"
  cat > "$dir/$name"
  chmod +x "$dir/$name"
}

# ===========================================================================
# Setup Mocked Toolchains (Ubuntu full, apt live, fwupd exit-2, multi-distro)
# ===========================================================================

# 1. Full mocked Ubuntu PATH for dry-run UX + safety + brew tap trust
ubuntu_bin="$tmpdir/ubuntu-bin"
ubuntu_sentinel="$tmpdir/update-node-ran.sentinel"
mkdir -p -- "$ubuntu_bin"

for _cmd in \
  dpkg apt-get apt snap flatpak fwupdmgr node npm corepack pnpm yarn bun \
  claude codex brew uv pipx rustup cargo gh code codium sudo update-node journalctl; do
  make_mock "$ubuntu_bin" "$_cmd" <<'EOF'
#!/usr/bin/env bash
case "$(basename "$0")" in
  dpkg) echo "Debian dpkg package management program version 1.22.0 (amd64)." ;;
  apt-get) echo "apt 2.7.14 (amd64)" ;;
  apt) echo "Listing..." ;;
  snap) echo "snap    2.63" ;;
  flatpak) echo "Flatpak 1.14.6" ;;
  fwupdmgr) echo "runtime org.freedesktop.fwupd 1.9.16" ;;
  node) echo "v22.11.0" ;;
  npm)
    case "${1:-}" in
      --version) echo "10.9.0" ;;
      prefix) echo "/tmp/mock-npm-prefix" ;;
      *) exit 0 ;;
    esac
    ;;
  corepack) echo "0.29.4" ;;
  pnpm) echo "9.12.0" ;;
  yarn)
    if [ "${COREPACK_ENABLE_DOWNLOAD_PROMPT:-}" != "0" ]; then
      printf 'missing COREPACK_ENABLE_DOWNLOAD_PROMPT=0\n' >&2
      exit 42
    fi
    case "${1:-}" in
      --version) printf '99.0.0-test\n' ;;
      *) exit 0 ;;
    esac
    ;;
  bun) echo "1.1.30" ;;
  claude) echo "2.1.0 (Claude Code)" ;;
  codex) echo "codex-cli 0.42.0" ;;
  brew)
    case "${1:-}" in
      --version) printf 'Homebrew 6.0.0\n' ;;
      --prefix) printf '/home/linuxbrew/.linuxbrew\n' ;;
      tap) printf 'example/tap\n' ;;
      tap-info)
        cat <<'INFO'
example/tap: Installed
Untrusted
From: https://github.com/example/homebrew-tap
==> Formulae
mcporter
poltergeist
INFO
        ;;
      list|outdated) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  uv) echo "uv 0.5.0" ;;
  pipx) echo "1.7.1" ;;
  rustup) echo "rustup 1.27.1" ;;
  cargo) echo "cargo 1.82.0" ;;
  gh) echo "gh version 2.60.0" ;;
  code) echo "1.95.0" ;;
  codium) echo "1.95.0" ;;
  update-node)
    touch "${UPDATE_ALL_TEST_NODE_SENTINEL:-/tmp/update-node-sentinel-unset}"
    exit 0
    ;;
  sudo)
    if [ "${1:-}" = "-n" ]; then
      shift
      [ "${1:-}" = "true" ] && exit 0
      "$@"
      exit $?
    fi
    "$@"
    exit $?
    ;;
  *) exit 0 ;;
esac
EOF
done

# 2. Live non-interactive apt-get + dpkg mock
apt_live_bin="$tmpdir/apt-live-bin"
apt_live_log="$tmpdir/apt-live.log"
mkdir -p -- "$apt_live_bin"

make_mock "$apt_live_bin" sudo <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-n" ]; then
  shift
  [ "${1:-}" = "true" ] && exit 0
  "$@"
  exit $?
fi
"$@"
EOF

make_mock "$apt_live_bin" dpkg <<'EOF'
#!/usr/bin/env bash
printf 'CMD=dpkg ARGS=%s DF=%s DNS=%s NR=%s UCF=%s ALC=%s\n' \
  "$*" "${DEBIAN_FRONTEND:-}" "${DEBCONF_NONINTERACTIVE_SEEN:-}" \
  "${NEEDRESTART_MODE:-}" "${UCF_FORCE_CONFFOLD:-}" "${APT_LISTCHANGES_FRONTEND:-}" \
  >> "$UPDATE_ALL_APT_LIVE_LOG"
case "${1:-}" in
  --version) echo "Debian dpkg 1.22.0" ;;
  --audit) echo "broken-mock-pkg: half-configured" ;;
  --configure) echo "Setting up broken-mock-pkg (1.0.0) ..." ;;
esac
exit 0
EOF

make_mock "$apt_live_bin" apt-get <<'EOF'
#!/usr/bin/env bash
printf 'CMD=apt-get ARGS=%s DF=%s DNS=%s NR=%s UCF=%s ALC=%s\n' \
  "$*" "${DEBIAN_FRONTEND:-}" "${DEBCONF_NONINTERACTIVE_SEEN:-}" \
  "${NEEDRESTART_MODE:-}" "${UCF_FORCE_CONFFOLD:-}" "${APT_LISTCHANGES_FRONTEND:-}" \
  >> "$UPDATE_ALL_APT_LIVE_LOG"
case "${1:-}" in
  --version) echo "apt 2.7.14 (amd64)" ;;
  *) echo "Unpacking mock-pkg (1.2.0) over (1.1.0) ..." ;;
esac
exit 0
EOF

make_mock "$apt_live_bin" apt <<'EOF'
#!/usr/bin/env bash
echo "Listing..."
exit 0
EOF

# 3. Live fwupdmgr exit-code-2 mock
fwupd_live_bin="$tmpdir/fwupd-live-bin"
mkdir -p -- "$fwupd_live_bin"
make_mock "$fwupd_live_bin" sudo <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-n" ]; then
  shift
  [ "${1:-}" = "true" ] && exit 0
  "$@"
  exit $?
fi
"$@"
EOF
make_mock "$fwupd_live_bin" fwupdmgr <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "runtime org.freedesktop.fwupd 1.9.16" ;;
  refresh) exit 0 ;;
  get-updates)
    echo "Devices with no available firmware updates: System Firmware"
    exit 2
    ;;
  *) exit 0 ;;
esac
EOF

# 4. Multi-distro simulated PATHs (Fedora dnf, Immutable rpm-ostree+dnf, Arch pacman, Alpine apk, brew-only)
fedora_bin="$tmpdir/fedora-bin"
ostree_bin="$tmpdir/ostree-bin"
arch_bin="$tmpdir/arch-bin"
alpine_bin="$tmpdir/alpine-bin"
brew_only_bin="$tmpdir/brew-only-bin"

make_mock "$fedora_bin" dnf <<'EOF'
#!/usr/bin/env bash
echo "dnf 4.21.0"
EOF
make_mock "$fedora_bin" sudo <<'EOF'
#!/usr/bin/env bash
"$@"
EOF

make_mock "$ostree_bin" rpm-ostree <<'EOF'
#!/usr/bin/env bash
printf 'rpm-ostree:\n Version: '\''2026.1'\''\n'
EOF
make_mock "$ostree_bin" dnf <<'EOF'
#!/usr/bin/env bash
echo "dnf 4.21.0"
EOF
make_mock "$ostree_bin" sudo <<'EOF'
#!/usr/bin/env bash
"$@"
EOF

make_mock "$arch_bin" pacman <<'EOF'
#!/usr/bin/env bash
echo "Pacman v6.1.0"
EOF
make_mock "$arch_bin" sudo <<'EOF'
#!/usr/bin/env bash
"$@"
EOF

make_mock "$alpine_bin" apk <<'EOF'
#!/usr/bin/env bash
echo "apk-tools 2.14.4"
EOF
make_mock "$alpine_bin" sudo <<'EOF'
#!/usr/bin/env bash
"$@"
EOF

void_bin="$tmpdir/void-bin"
make_mock "$void_bin" xbps-install <<'EOF'
#!/usr/bin/env bash
echo "XBPS: 0.59.2"
EOF
make_mock "$void_bin" xbps-remove <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
make_mock "$void_bin" sudo <<'EOF'
#!/usr/bin/env bash
"$@"
EOF

make_mock "$brew_only_bin" brew <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "Homebrew 6.0.0" ;;
  --prefix) echo "/home/linuxbrew/.linuxbrew" ;;
  *) exit 0 ;;
esac
EOF

# ===========================================================================
# Launch slow dry-run / live-mock jobs in parallel for <15s total runtime
# ===========================================================================
bg_pids=""
run_bg() {
  local name="$1"; shift
  (
    "$@" > "$tmpdir/out-${name}.txt" 2>&1
    printf '%s\n' "$?" > "$tmpdir/rc-${name}.txt"
  ) &
  bg_pids="$bg_pids $!"
}

run_bg ubuntu-dry env HOME="$fake_home" PATH="$ubuntu_bin:$posix_bin" \
  UPDATE_ALL_TEST_NODE_SENTINEL="$ubuntu_sentinel" \
  "$UPDATE_ALL" --dry-run --no-anim --no-color

run_bg apt-live env HOME="$fake_home" PATH="$apt_live_bin:$posix_bin" \
  UPDATE_ALL_APT_LIVE_LOG="$apt_live_log" \
  "$UPDATE_ALL" --non-interactive --no-security-scan --no-anim --no-color

run_bg fwupd-live env HOME="$fake_home" PATH="$fwupd_live_bin:$posix_bin" \
  "$UPDATE_ALL" --firmware --non-interactive --no-security-scan --no-anim --no-color

run_bg fedora-dry env HOME="$fake_home" PATH="$fedora_bin:$posix_bin" \
  "$UPDATE_ALL" --dry-run --no-anim --no-color

run_bg ostree-dry env HOME="$fake_home" PATH="$ostree_bin:$posix_bin" \
  "$UPDATE_ALL" --dry-run --no-anim --no-color

run_bg arch-dry env HOME="$fake_home" PATH="$arch_bin:$posix_bin" \
  "$UPDATE_ALL" --dry-run --no-anim --no-color

run_bg alpine-dry env HOME="$fake_home" PATH="$alpine_bin:$posix_bin" \
  "$UPDATE_ALL" --dry-run --no-anim --no-color

run_bg void-dry env HOME="$fake_home" PATH="$void_bin:$posix_bin" \
  "$UPDATE_ALL" --dry-run --no-anim --no-color

run_bg brew-only-dry env HOME="$fake_home" PATH="$brew_only_bin:$posix_bin" \
  "$UPDATE_ALL" --dry-run --no-anim --no-color

run_bg receipt-visual env HOME="$fake_home" PATH="$posix_bin" \
  UPDATE_ALL_RECEIPT_SELFTEST=visual "$UPDATE_ALL" --no-anim --no-color

run_bg visual-preview env HOME="$fake_home" PATH="$posix_bin" \
  UPDATE_ALL_VISUAL_PREVIEW=1 "$UPDATE_ALL" --no-anim --no-color

if [ -x "$DIST_BUNDLE" ]; then
  run_bg dist-visual env HOME="$fake_home" PATH="$posix_bin" \
    UPDATE_ALL_RECEIPT_SELFTEST=visual "$DIST_BUNDLE" --no-anim --no-color
fi

# ===========================================================================
# Foreground Fast Unit & Selftest Suites (run concurrently with bg jobs)
# ===========================================================================

# --- Suite 4: Stdin isolation across ALL 6 runners ---
stdin_bin="$tmpdir/stdin-bin"
make_mock "$stdin_bin" sudo <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-n" ]; then
  shift
  [ "${1:-}" = "true" ] && exit 0
  "$@"
  exit $?
fi
"$@"
EOF

stdin_runner_output="$(
  printf '%s\n' keyboard keyboard keyboard keyboard keyboard keyboard \
    | PATH="$stdin_bin:$posix_bin" UPDATE_ALL_STDIN_SELFTEST=1 UPDATE_ALL_STDIN_INCLUDE_SUDO=1 \
      "$UPDATE_ALL" --no-anim --no-color
)"
assert_contains "$stdin_runner_output" "run-cmd-closed" "run_cmd must close stdin"
assert_contains "$stdin_runner_output" "run-capture-closed" "run_cmd_capture must close stdin"
assert_contains "$stdin_runner_output" "run-bounded-closed" "run_bounded must close stdin"
assert_contains "$stdin_runner_output" "run-shell-closed" "run_shell must close stdin"
assert_contains "$stdin_runner_output" "run-shell-capture-closed" "run_shell_capture must close stdin"
assert_contains "$stdin_runner_output" "sudo-cmd-closed" "sudo_cmd must close stdin"
assert_not_contains "$stdin_runner_output" "-open" "no runner may read from update-all stdin"

# --- Suite 5: Secret redaction (all 7 shapes + NUL byte stripping) ---
openai_token="sk-$(printf 'a%.0s' {1..24})"
github_token="ghp_$(printf 'b%.0s' {1..24})"
github_pat="github_pat_$(printf 'c%.0s' {1..24})"
slack_token="xoxb-$(printf 'd%.0s' {1..24})"
aws_prefix="AK"
aws_token="${aws_prefix}IA$(printf '9%.0s' {1..16})"
pem_hdr="-----BEGIN RSA ""PRIVATE"" KEY-----"
generic_val="fakeSecretValue987654"

redacted_all="$(
  printf 'OPENAI=%s\nGH=%s\nPAT=%s\nSLACK=%s\nAWS=%s\n%s\nMY_API_TOKEN=%s\n' \
    "$openai_token" "$github_token" "$github_pat" "$slack_token" "$aws_token" "$pem_hdr" "$generic_val" \
    | UPDATE_ALL_REDACTION_SELFTEST=1 "$UPDATE_ALL" --no-anim --no-color
)"
assert_contains "$redacted_all" "[REDACTED_OPENAI_KEY]" "expected OpenAI key redaction"
assert_contains "$redacted_all" "[REDACTED_GITHUB_TOKEN]" "expected GitHub token redaction"
assert_contains "$redacted_all" "[REDACTED_SLACK_TOKEN]" "expected Slack token redaction"
assert_contains "$redacted_all" "[REDACTED_AWS_ACCESS_KEY]" "expected AWS access key redaction"
assert_contains "$redacted_all" "[REDACTED_PRIVATE_KEY_BEGIN]" "expected private key header redaction"
assert_contains "$redacted_all" "MY_API_TOKEN=[REDACTED]" "expected generic key=value secret redaction"
assert_not_contains "$redacted_all" "$openai_token" "OpenAI test token must not leak"
assert_not_contains "$redacted_all" "$github_token" "GitHub test token must not leak"
assert_not_contains "$redacted_all" "$github_pat" "GitHub fine-grained PAT must not leak"
assert_not_contains "$redacted_all" "$slack_token" "Slack test token must not leak"
assert_not_contains "$redacted_all" "$aws_token" "AWS access key must not leak"
assert_not_contains "$redacted_all" "$pem_hdr" "PEM private key header must not leak"
assert_not_contains "$redacted_all" "$generic_val" "Generic secret value must not leak"

control_cleaned="$(printf '^@Hit:1 https://example.invalid stable InRelease\n' | UPDATE_ALL_REDACTION_SELFTEST=1 "$UPDATE_ALL" --no-anim --no-color)"
assert_not_contains "$control_cleaned" "^@" "literal NUL marker should be stripped"
assert_contains "$control_cleaned" "Hit:1 https://example.invalid stable InRelease" "text after literal NUL marker should remain"

actual_nul_cleaned="$(printf '\000Hit:1 https://example.invalid stable InRelease\n' | UPDATE_ALL_REDACTION_SELFTEST=1 "$UPDATE_ALL" --no-anim --no-color)"
assert_contains "$actual_nul_cleaned" "Hit:1 https://example.invalid stable InRelease" "actual NUL byte stripping must preserve text"
assert_not_contains "$actual_nul_cleaned" "^@" "actual NUL byte should not render as ^@"

# --- Suite 6: Sudo secret-prime selftest ---
sudo_secret_bin="$tmpdir/sudo-secret-bin"
sudo_log="$tmpdir/sudo-secret.log"
make_mock "$sudo_secret_bin" secret <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  has) [ "${2:-}" = "test-sudo-key" ] ;;
  get)
    [ "${2:-}" = "test-sudo-key" ] || exit 1
    printf 'fake-password\n'
    ;;
  *) exit 1 ;;
esac
EOF
make_mock "$sudo_secret_bin" sudo <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UPDATE_ALL_FAKE_SUDO_LOG"
if [ "${1:-}" = "-n" ]; then exit 1; fi
if [ "${1:-}" = "-S" ]; then
  shift
  [ "${1:-}" = "-p" ] && shift 2
  IFS= read -r _password || true
  if [ "${1:-}" = "-v" ]; then
    printf '^@sudo validation should not run when a sudo secret is available\n'
    exit 0
  fi
  "$@"
  exit $?
fi
if [ "${1:-}" = "-v" ]; then
  printf '^@sudo validation should not run when a sudo secret is available\n'
  exit 0
fi
"$@"
EOF

sudo_output="$(
  PATH="$sudo_secret_bin:$posix_bin" \
  UPDATE_ALL_SUDO_SECRET_KEY=test-sudo-key \
  UPDATE_ALL_FAKE_SUDO_LOG="$sudo_log" \
  UPDATE_ALL_SUDO_SELFTEST=secret-prime \
  "$UPDATE_ALL" --no-anim --no-color
)"
assert_contains "$sudo_output" "sudo command ok" "sudo secret-prime selftest should run command"
assert_not_contains "$sudo_output" "^@" "sudo secret-prime must not leak ^@ control markers"
if [ -r "$sudo_log" ] && grep -F -- "-v" "$sudo_log" >/dev/null; then
  fail "sudo secret-prime should skip sudo -v when secret helper is available"
else
  pass
fi

# --- Suite 6b (C4): Cached sudo -n true with UPDATE_ALL_SUDO_SECRET_KEY skips secret get & keeps stdin closed ---
cached_sudo_bin="$tmpdir/cached-sudo-bin"
secret_get_sentinel="$tmpdir/secret-get-ran.sentinel"
make_mock "$cached_sudo_bin" secret <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  has) [ "${2:-}" = "test-sudo-key" ] ;;
  get)
    touch "${UPDATE_ALL_SECRET_GET_SENTINEL:-/tmp/secret-get-unset}"
    printf 'fake-password\n'
    ;;
  *) exit 1 ;;
esac
EOF
make_mock "$cached_sudo_bin" sudo <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-n" ]; then
  shift
  [ "${1:-}" = "true" ] && exit 0
  "$@"
  exit $?
fi
"$@"
EOF

cached_sudo_out="$(
  printf '%s\n' keyboard keyboard keyboard keyboard keyboard keyboard \
    | PATH="$cached_sudo_bin:$posix_bin" \
      UPDATE_ALL_SUDO_SECRET_KEY=test-sudo-key \
      UPDATE_ALL_SECRET_GET_SENTINEL="$secret_get_sentinel" \
      UPDATE_ALL_STDIN_SELFTEST=1 UPDATE_ALL_STDIN_INCLUDE_SUDO=1 \
      "$UPDATE_ALL" --no-anim --no-color
)"
assert_contains "$cached_sudo_out" "sudo-cmd-closed" "cached sudo -n true must keep child stdin closed"
assert_not_contains "$cached_sudo_out" "sudo-cmd-open" "cached sudo -n true must not expose stdin to child"
assert_file_not_exists "$secret_get_sentinel" "cached sudo -n true must NOT invoke secret get"

# --- Suite 7: Firmware --all vs --firmware, classifiers, firmware summary, interactive PTY 'a' ---
prompt_bin="$tmpdir/prompt-bin"
make_mock "$prompt_bin" fwupdmgr <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
make_mock "$prompt_bin" apt-get <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
make_mock "$prompt_bin" brew <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'Homebrew 6.0.0\n' ;;
  tap) printf 'example/tap\n' ;;
  tap-info)
    cat <<'INFO'
example/tap: Installed
Untrusted
From: https://github.com/example/homebrew-tap
==> Formulae
mcporter
INFO
    ;;
  *) exit 0 ;;
esac
EOF

all_flag_prompt="$(
  HOME="$fake_home" PATH="$prompt_bin:$posix_bin" \
  UPDATE_ALL_PROMPT_SELFTEST=1 "$UPDATE_ALL" --all --no-anim --no-color
)"
assert_contains "$all_flag_prompt" "firmware choice: no" "--all must keep firmware choice as no"
assert_contains "$all_flag_prompt" "apt cleanup choice: yes" "--all must auto-approve apt cleanup"
assert_contains "$all_flag_prompt" "workstation cleanup choice: yes" "--all must auto-approve workstation cleanup"

fw_flag_prompt="$(
  HOME="$fake_home" PATH="$prompt_bin:$posix_bin" \
  UPDATE_ALL_PROMPT_SELFTEST=1 "$UPDATE_ALL" --all --firmware --no-anim --no-color
)"
assert_contains "$fw_flag_prompt" "firmware choice: yes" "--firmware must set firmware choice to yes"

all_prompt_output="$(
  run_in_pty $'a\n' "HOME='$fake_home' PATH='$prompt_bin:$posix_bin' UPDATE_ALL_PROMPT_SELFTEST=1 '$UPDATE_ALL' --no-anim --no-color"
)"
all_prompt_clean="$(printf '%s\n' "$all_prompt_output" | tr -d '\r')"
prompt_count="$(printf '%s\n' "$all_prompt_clean" | grep -c '^? ' || true)"
assert_eq "$prompt_count" "1" "typing 'a' should answer every optional prompt after one question"
assert_contains "$all_prompt_clean" "all mode: yes to every remaining optional question" "interactive 'a' mode should explain behavior"
assert_contains "$all_prompt_clean" "firmware choice: yes" "interactive 'a' mode should save yes for firmware"
assert_contains "$all_prompt_clean" "brew untap example/tap: yes" "interactive 'a' mode should save yes for untap"
assert_contains "$all_prompt_clean" "apt cleanup choice: yes" "interactive 'a' mode should save yes for apt cleanup"
assert_contains "$all_prompt_clean" "workstation cleanup choice: yes" "interactive 'a' mode should save yes for workstation cleanup"

# Classifier selftests (preserved)
if printf 'Update State:       Failed\nUpdate Error:       failed to write data to efivarsfs\n' \
  | UPDATE_ALL_CLASSIFY_SELFTEST=fwupd-manual "$UPDATE_ALL" --no-anim --no-color; then pass
else fail "expected fwupd efivars failure to classify as manual firmware attention"; fi

if printf 'npm warn allow-scripts   @anthropic-ai/claude-code@2.1.195 (postinstall: node install.cjs)\n' \
  | UPDATE_ALL_CLASSIFY_SELFTEST=npm-claude-script "$UPDATE_ALL" --no-anim --no-color; then pass
else fail "expected npm Claude Code allow-scripts warning to trigger trusted script retry"; fi

# shellcheck disable=SC2016 # Fixture intentionally contains literal backticks from uv output.
if printf 'warning: The package `typer==0.26.8` does not have an extra named `all`\n' \
  | UPDATE_ALL_CLASSIFY_SELFTEST=uv-stale-extra "$UPDATE_ALL" --no-anim --no-color; then pass
else fail "expected uv stale optional-extra warning to be recognized"; fi

if printf '==> Upgraded 3 outdated packages\n' \
  | UPDATE_ALL_CLASSIFY_SELFTEST=updated-output "$UPDATE_ALL" --no-anim --no-color; then pass
else fail "expected plural Homebrew upgraded output to imply update"; fi

if printf '==> Upgraded 1 outdated package\n' \
  | UPDATE_ALL_CLASSIFY_SELFTEST=updated-output "$UPDATE_ALL" --no-anim --no-color; then pass
else fail "expected singular Homebrew upgraded output to imply update"; fi

if printf 'changed 2 packages in 5s\n' \
  | UPDATE_ALL_CLASSIFY_SELFTEST=updated-output "$UPDATE_ALL" --no-anim --no-color; then pass
else fail "expected npm changed package output to imply update"; fi

if printf 'Already up-to-date.\n' \
  | UPDATE_ALL_CLASSIFY_SELFTEST=updated-output "$UPDATE_ALL" --no-anim --no-color; then
  fail "already-up-to-date output should not count as an updated step"
else pass; fi

firmware_fixture='Razer Blade
│
├─KEK CA:
│ │   Device ID:          b7a1d3d90faa1f6275d9a98da4fb3be7118e61c7
│ │   Current version:    2011
│ │   GUIDs:              814e950f-1449-566a-a190-42c9d3a3a2df
│ └─Secure Boot KEK Configuration Update:
│       New version:      2023
│       Summary:          UEFI Secure Boot Key Exchange Key
│       Urgency:          High
│       Checksum:         103ebd21a803540296daff93fa7e1595bf323b4db78fbc6287aed945ab5965fb
└─UEFI dbx:
  │   Current version:    20230501
  └─Secure Boot dbx Configuration Update:
        New version:      20260402
        Summary:          UEFI Secure Boot Forbidden Signature Database
        Urgency:          High
        Issue:            CVE-2026-8863
'
firmware_summary="$(printf '%s\n' "$firmware_fixture" | UPDATE_ALL_FIRMWARE_SELFTEST=summary "$UPDATE_ALL" --no-anim --no-color)"
assert_contains "$firmware_summary" "FIRMWARE REVIEW" "expected firmware review heading"
assert_contains "$firmware_summary" "Plain English:" "expected plain English firmware explanation"
assert_contains "$firmware_summary" "KEK CA" "expected KEK CA device name"
assert_contains "$firmware_summary" "2011 -> 2023" "expected KEK CA version arrow"
assert_contains "$firmware_summary" "UEFI dbx" "expected UEFI dbx device name"
assert_contains "$firmware_summary" "20230501 -> 20260402" "expected UEFI dbx version arrow"
assert_contains "$firmware_summary" "action:" "expected firmware action row"
assert_not_regex "$firmware_summary" "Device ID|GUID|Checksum" "firmware summary should hide raw IDs"

late_prompt_calls="$(grep -nE 'elif confirm_step|if confirm_step' "$UPDATE_ALL" "$ROOT_DIR"/lib/*.sh || true)"
assert_eq "$late_prompt_calls" "" "optional y/N prompts must be collected upfront, not mid-run"

# --- Suite 8: Watcher selftests, EWMA timings, invalid flags, NO_COLOR ---
frames_utf8="$(LC_ALL=en_US.UTF-8 UPDATE_ALL_WATCHER_SELFTEST=frames "$UPDATE_ALL" --no-anim --no-color)"
assert_contains "$frames_utf8" "style=hybrid frame0=·" "UTF-8 hybrid frame0 glyph"
assert_contains "$frames_utf8" "style=braille frame0=⣾" "UTF-8 braille frame0 glyph"
assert_contains "$frames_utf8" "style=anthropic frame0=·" "UTF-8 anthropic frame0 glyph"

frames_ascii="$(LC_ALL=C UPDATE_ALL_WATCHER_SELFTEST=frames "$UPDATE_ALL" --no-anim --no-color)"
assert_contains "$frames_ascii" "style=hybrid frame0=|" "LC_ALL=C ASCII fallback for hybrid"
assert_contains "$frames_ascii" "style=braille frame0=|" "LC_ALL=C ASCII fallback for braille"
assert_contains "$frames_ascii" "style=anthropic frame0=|" "LC_ALL=C ASCII fallback for anthropic"

stream_cap_out="$(UPDATE_ALL_WATCHER_SELFTEST=stream-capture "$UPDATE_ALL" --no-anim --no-color)"
assert_contains "$stream_cap_out" "CAPTURE_RC=7" "stream-capture must preserve exit code 7"
assert_contains "$stream_cap_out" "CAPTURE_VAL=line-one" "stream-capture must preserve captured output"
assert_contains "$stream_cap_out" "token=[REDACTED_OPENAI_KEY]" "stream-capture must redact OpenAI token"
_raw_sk_frag="sk-""1234567890"
assert_not_contains "$stream_cap_out" "$_raw_sk_frag" "stream-capture must not leak raw secret prefix"

leaked_t0="$(date +%s)"
leaked_out="$(UPDATE_ALL_WATCHER_SELFTEST=leaked-fd "$UPDATE_ALL" --no-anim --no-color)"
leaked_rc=$?
leaked_t1="$(date +%s)"
leaked_elapsed=$((leaked_t1 - leaked_t0))
assert_eq "$leaked_rc" "0" "leaked-fd selftest should exit 0"
assert_contains "$leaked_out" "parent-done" "leaked-fd selftest should capture parent output"
if [ "$leaked_elapsed" -lt 4 ]; then
  pass
else
  fail "leaked-fd selftest hung on background sleep 5 (elapsed=${leaked_elapsed}s, expected <4s)"
fi

timings_file="$tmpdir/timings.tsv"
timings_out1="$(UPDATE_ALL_TIMINGS_FILE="$timings_file" UPDATE_ALL_WATCHER_SELFTEST=timings "$UPDATE_ALL" --no-anim --no-color)"
assert_contains "$timings_out1" "EST_APT=30" "first timings run should record 30s"
assert_file_contains "$timings_file" "apt-upgrade	30" "timings file should persist apt-upgrade=30"

printf 'apt-upgrade\t100\n' > "$timings_file"
timings_out2="$(UPDATE_ALL_TIMINGS_FILE="$timings_file" UPDATE_ALL_WATCHER_SELFTEST=timings "$UPDATE_ALL" --no-anim --no-color)"
assert_contains "$timings_out2" "EST_APT=72" "EWMA of prev=100 and actual=30 should be 72"
assert_file_contains "$timings_file" "apt-upgrade	72" "timings file should persist EWMA value 72"

bad_watcher_rc=0
"$UPDATE_ALL" --watcher=bad >/dev/null 2>&1 || bad_watcher_rc=$?
assert_eq "$bad_watcher_rc" "2" "invalid --watcher=bad must exit with code 2"

bad_bar_rc=0
"$UPDATE_ALL" --bar=bad >/dev/null 2>&1 || bad_bar_rc=$?
assert_eq "$bad_bar_rc" "2" "invalid --bar=bad must exit with code 2"

no_color_pty_out="$(
  run_in_pty "" "HOME='$fake_home' PATH='$posix_bin' NO_COLOR=1 TERM=xterm-256color UPDATE_ALL_WATCHER_SELFTEST=frames '$UPDATE_ALL' --no-anim"
)"
if printf '%s' "$no_color_pty_out" | LC_ALL=C grep -q $'\033'; then
  fail "NO_COLOR=1 emitted ANSI escape sequences in PTY output"
else
  pass
fi

# --- Suite 8b (C1): Live PTY dock (--bar=bottom) and inline watcher (--bar=off) ---
pty_bar_out="$(
  run_in_pty "" "HOME='$fake_home' PATH='$posix_bin' TERM=xterm-256color UPDATE_ALL_WATCHER_SELFTEST=pty-bar '$UPDATE_ALL' --bar=bottom"
)"
assert_contains "$pty_bar_out" "tick-start" "pty-bar (--bar=bottom) must stream tick-start"
assert_contains "$pty_bar_out" "tick-end" "pty-bar (--bar=bottom) must stream tick-end cleanly"

pty_bar_off_out="$(
  run_in_pty "" "HOME='$fake_home' PATH='$posix_bin' TERM=xterm-256color UPDATE_ALL_WATCHER_SELFTEST=pty-bar '$UPDATE_ALL' --bar=off"
)"
assert_contains "$pty_bar_off_out" "tick-start" "pty-bar (--bar=off) inline watcher must stream tick-start"
assert_contains "$pty_bar_off_out" "tick-end" "pty-bar (--bar=off) inline watcher must stream tick-end cleanly"

# --- Suite 11: Safety Coach (OSV malicious package + exposed ports) ---
safety_bin="$tmpdir/safety-bin"
npm_uninstall_sentinel="$tmpdir/npm-uninstall-ran.sentinel"
make_mock "$safety_bin" npm <<'EOF'
#!/usr/bin/env bash
touch "${UPDATE_ALL_TEST_NPM_SENTINEL:-/tmp/npm-sentinel-unset}"
exit 0
EOF

osv_mock="$tmpdir/osv-mock.json"
cat > "$osv_mock" <<'EOF'
{
  "results": [
    {
      "vulns": [
        {
          "id": "MAL-2026-0001",
          "summary": "Malicious npm package exfiltrates environment variables",
          "affected": [
            {
              "package": {
                "name": "evil-demo-cli",
                "ecosystem": "npm"
              }
            }
          ]
        }
      ]
    }
  ]
}
EOF

osv_out="$(
  HOME="$fake_home" PATH="$safety_bin:$posix_bin" \
  UPDATE_ALL_TEST_NPM_SENTINEL="$npm_uninstall_sentinel" \
  UPDATE_ALL_SAFETY_SELFTEST=osv \
  UPDATE_ALL_OSV_MOCK_FILE="$osv_mock" \
  "$UPDATE_ALL" --non-interactive --no-anim --no-color
)"
assert_contains "$osv_out" "CRITICAL · MALICIOUS" "OSV selftest must flag CRITICAL · MALICIOUS"
assert_contains "$osv_out" "MAL-2026-0001" "OSV selftest must include advisory ID"
assert_contains "$osv_out" "npm uninstall -g evil-demo-cli" "OSV selftest must show exact npm uninstall remedy"
assert_contains "$osv_out" "Non-interactive / preview mode: no remediation commands were executed." "non-interactive Safety Coach must state no commands ran"
assert_file_not_exists "$npm_uninstall_sentinel" "non-interactive Safety Coach must NEVER auto-delete malicious packages"

ports_mock="$tmpdir/ports-mock.txt"
cat > "$ports_mock" <<'EOF'
tcp LISTEN 0 128 127.0.0.1:5432 0.0.0.0:* users:(("postgres",pid=101,fd=5))
tcp LISTEN 0 511 0.0.0.0:3000 0.0.0.0:* users:(("node",pid=202,fd=18))
EOF

ports_out="$(
  HOME="$fake_home" PATH="$posix_bin" \
  UPDATE_ALL_SAFETY_SELFTEST=ports \
  UPDATE_ALL_PORTS_MOCK_FILE="$ports_mock" \
  "$UPDATE_ALL" --non-interactive --no-anim --no-color
)"
assert_contains "$ports_out" "WARN · EXPOSED PORT" "ports selftest must flag exposed non-loopback listener"
assert_contains "$ports_out" "node (tcp/3000 on all interfaces (0.0.0.0))" "ports selftest must report exposed port 3000"
assert_contains "$ports_out" "sudo ufw deny 3000/tcp" "ports selftest must provide ufw deny guidance"
assert_not_contains "$ports_out" "5432" "ports selftest must exclude loopback 127.0.0.1:5432"
assert_not_contains "$ports_out" "postgres" "ports selftest must exclude loopback process postgres"

# --- Suite 11b (C3): Compact OSV querybatch index alignment, PYSEC/RUSTSEC hydration, parser guard ---
osv_tuples_mock="$tmpdir/osv-tuples.txt"
cat > "$osv_tuples_mock" <<'EOF'
npm|npm|clean-alpha|1.0.0
PyPI|uv|clean-beta|2.0.0
npm|npm|bad-gamma|0.9.1
EOF

osv_compact_mock="$tmpdir/osv-compact.json"
printf '%s\n' '{"results":[{},{},{"vulns":[{"id":"MAL-2026-9999","modified":"2026-07-01T00:00:00Z"}]}]}' > "$osv_compact_mock"

osv_compact_out="$(
  HOME="$fake_home" PATH="$posix_bin" \
  UPDATE_ALL_SAFETY_SELFTEST=osv \
  UPDATE_ALL_OSV_MOCK_FILE="$osv_compact_mock" \
  UPDATE_ALL_OSV_TUPLES_MOCK_FILE="$osv_tuples_mock" \
  "$UPDATE_ALL" --non-interactive --no-anim --no-color
)"
assert_contains "$osv_compact_out" "CRITICAL · MALICIOUS" "compact querybatch must flag MAL-* as CRITICAL · MALICIOUS"
assert_contains "$osv_compact_out" "bad-gamma@0.9.1 (npm)" "compact querybatch must attribute finding to index-2 package"
assert_contains "$osv_compact_out" "MAL-2026-9999" "compact querybatch must preserve MAL-2026-9999 ID"
assert_contains "$osv_compact_out" "npm uninstall -g bad-gamma" "compact querybatch must generate uninstall command for index-2 package"
assert_not_contains "$osv_compact_out" "clean-alpha" "compact querybatch must NOT misattribute index-2 finding to index-0 package"
assert_not_contains "$osv_compact_out" "clean-beta" "compact querybatch must NOT misattribute index-2 finding to index-1 package"

osv_adv_tuples="$tmpdir/osv-adv-tuples.txt"
cat > "$osv_adv_tuples" <<'EOF'
PyPI|uv|py-high-pkg|1.2.0
crates.io|cargo|rust-unrated-pkg|0.3.0
PyPI|pipx|py-low-pkg|4.0.0
EOF

osv_adv_batch="$tmpdir/osv-adv-batch.json"
printf '%s\n' '{"results":[{"vulns":[{"id":"PYSEC-2026-1001","modified":"2026-07-01T00:00:00Z"}]},{"vulns":[{"id":"RUSTSEC-2026-2002","modified":"2026-07-01T00:00:00Z"}]},{"vulns":[{"id":"PYSEC-2026-1003","modified":"2026-07-01T00:00:00Z"}]}]}' > "$osv_adv_batch"

osv_vuln_dir="$tmpdir/osv-vulns"
mkdir -p -- "$osv_vuln_dir"
printf '%s\n' '{"id":"PYSEC-2026-1001","summary":"Arbitrary code execution in py-high-pkg","database_specific":{"severity":"HIGH"}}' > "$osv_vuln_dir/PYSEC-2026-1001.json"
printf '%s\n' '{"id":"RUSTSEC-2026-2002","summary":"Memory safety issue in rust-unrated-pkg"}' > "$osv_vuln_dir/RUSTSEC-2026-2002.json"
printf '%s\n' '{"id":"PYSEC-2026-1003","summary":"Minor low-impact issue","database_specific":{"severity":"LOW"}}' > "$osv_vuln_dir/PYSEC-2026-1003.json"

osv_adv_out="$(
  HOME="$fake_home" PATH="$posix_bin" \
  UPDATE_ALL_SAFETY_SELFTEST=osv \
  UPDATE_ALL_OSV_MOCK_FILE="$osv_adv_batch" \
  UPDATE_ALL_OSV_TUPLES_MOCK_FILE="$osv_adv_tuples" \
  UPDATE_ALL_OSV_VULN_MOCK_DIR="$osv_vuln_dir" \
  "$UPDATE_ALL" --non-interactive --no-anim --no-color
)"
assert_contains "$osv_adv_out" "HIGH · ADVISORY" "hydrated PYSEC HIGH advisory must render HIGH · ADVISORY"
assert_contains "$osv_adv_out" "PYSEC-2026-1001" "hydrated PYSEC advisory must include ID"
assert_contains "$osv_adv_out" "Arbitrary code execution in py-high-pkg" "hydrated PYSEC advisory must show hydrated summary"
assert_contains "$osv_adv_out" "WARN · ADVISORY" "unrated RUSTSEC advisory must render WARN · ADVISORY (not dropped or promoted to HIGH)"
assert_contains "$osv_adv_out" "RUSTSEC-2026-2002" "unrated RUSTSEC advisory must include ID"
assert_not_contains "$osv_adv_out" "PYSEC-2026-1003" "LOW-severity PYSEC advisory must be filtered out"
assert_not_contains "$osv_adv_out" "py-low-pkg" "LOW-severity package must not appear in findings"

# Missing both python3 and jq must emit clean SKIP instead of broken awk fallback
no_parser_bin="$tmpdir/no-parser-bin"
mkdir -p -- "$no_parser_bin"
for _u in bash sh env awk sed grep tr cut cat head tail wc sort uniq fold mktemp mkdir rm mv cp chmod date uname id readlink dirname basename sleep kill true false printf test '[' ls stat touch which; do
  if [ -e "$posix_bin/$_u" ]; then
    ln -sf "$posix_bin/$_u" "$no_parser_bin/$_u"
  fi
done
no_parser_out="$(
  HOME="$fake_home" PATH="$no_parser_bin" \
  UPDATE_ALL_SAFETY_SELFTEST=osv \
  UPDATE_ALL_OSV_MOCK_FILE="$osv_compact_mock" \
  UPDATE_ALL_OSV_TUPLES_MOCK_FILE="$osv_tuples_mock" \
  "$UPDATE_ALL" --non-interactive --no-anim --no-color
)"
assert_contains "$no_parser_out" "OSV response parser requires python3 or jq" "missing python3 and jq must emit clean SKIP note"

# --- Suite 11c (M7): Leading-dash package token rejection & firewalld remedy ---
evil_tuples_mock="$tmpdir/evil-tuples.txt"
printf '%s\n' 'npm|npm|--evil|1.0.0' > "$evil_tuples_mock"
evil_osv_mock="$tmpdir/evil-osv.json"
printf '%s\n' '{"results":[{"vulns":[{"id":"MAL-2026-8888","summary":"Option-injection package name test"}]}]}' > "$evil_osv_mock"

evil_osv_out="$(
  HOME="$fake_home" PATH="$posix_bin" \
  UPDATE_ALL_SAFETY_SELFTEST=osv \
  UPDATE_ALL_OSV_MOCK_FILE="$evil_osv_mock" \
  UPDATE_ALL_OSV_TUPLES_MOCK_FILE="$evil_tuples_mock" \
  "$UPDATE_ALL" --non-interactive --no-anim --no-color
)"
assert_contains "$evil_osv_out" "MAL-2026-8888" "leading-dash package must still be reported as a finding"
assert_not_contains "$evil_osv_out" "npm uninstall -g --evil" "leading-dash package name must NEVER generate a remedy command"

fw_bin="$tmpdir/fw-bin"
make_mock "$fw_bin" firewall-cmd <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --state) printf 'running\n' ;;
  *) exit 0 ;;
esac
EOF
fw_ports_out="$(
  HOME="$fake_home" PATH="$fw_bin:$posix_bin" \
  UPDATE_ALL_SAFETY_SELFTEST=ports \
  UPDATE_ALL_PORTS_MOCK_FILE="$ports_mock" \
  "$UPDATE_ALL" --non-interactive --no-anim --no-color
)"
assert_contains "$fw_ports_out" "sudo firewall-cmd --permanent --remove-port=3000/tcp && sudo firewall-cmd --reload" "firewalld host without ufw must show firewall-cmd remedy"
assert_contains "$fw_ports_out" "firewalld (running)" "firewalld host must report firewalld posture"

# --- Suite 11d (Gate B): CVSS v3.1 vector scoring (python3 + jq) & Homebrew excluded from OSV tuples ---
cvss_tuples_mock="$tmpdir/cvss-tuples.txt"
cat > "$cvss_tuples_mock" <<'EOF'
npm|npm|exec-vector-pkg|1.0.0
npm|npm|xss-medium-pkg|2.0.0
EOF

cvss_batch_mock="$tmpdir/cvss-batch.json"
cat > "$cvss_batch_mock" <<'EOF'
{
  "results": [
    {
      "vulns": [
        {
          "id": "GHSA-cvss-9800-critical",
          "summary": "Remote code execution scored only via CVSS 3.1 vector",
          "severity": [
            {
              "type": "CVSS_V3",
              "score": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"
            }
          ]
        }
      ]
    },
    {
      "vulns": [
        {
          "id": "GHSA-cvss-6100-medium",
          "summary": "Medium XSS scored only via CVSS 3.1 vector",
          "severity": [
            {
              "type": "CVSS_V3",
              "score": "CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:L/I:L/A:N"
            }
          ]
        }
      ]
    }
  ]
}
EOF

cvss_out="$(
  HOME="$fake_home" PATH="$posix_bin" \
  UPDATE_ALL_SAFETY_SELFTEST=osv \
  UPDATE_ALL_OSV_MOCK_FILE="$cvss_batch_mock" \
  UPDATE_ALL_OSV_TUPLES_MOCK_FILE="$cvss_tuples_mock" \
  "$UPDATE_ALL" --non-interactive --no-anim --no-color
)"
assert_contains "$cvss_out" "CRITICAL · ADVISORY" "CVSS:3.1 9.8 vector without database_specific.severity must classify as CRITICAL"
assert_contains "$cvss_out" "GHSA-cvss-9800-critical" "CVSS:3.1 CRITICAL advisory ID must be reported"
assert_contains "$cvss_out" "exec-vector-pkg@1.0.0 (npm)" "CVSS:3.1 CRITICAL advisory must attribute to exec-vector-pkg"
assert_not_contains "$cvss_out" "GHSA-cvss-6100-medium" "CVSS:3.1 MEDIUM (6.1) vector must be filtered out"
assert_not_contains "$cvss_out" "xss-medium-pkg" "CVSS:3.1 MEDIUM package must not appear in findings"

if command -v jq >/dev/null 2>&1; then
  jq_only_bin="$tmpdir/jq-only-bin"
  mkdir -p -- "$jq_only_bin"
  for _u in bash sh env awk sed grep tr cut cat head tail wc sort uniq fold mktemp mkdir rm mv cp chmod date uname id readlink dirname basename sleep kill true false printf test '[' ls stat touch which; do
    if [ -e "$posix_bin/$_u" ]; then
      ln -sf "$posix_bin/$_u" "$jq_only_bin/$_u"
    fi
  done
  ln -sf "$(command -v jq)" "$jq_only_bin/jq"

  jq_batch_parsed="$(
    # shellcheck disable=SC2016 # Positional parameters are intentionally expanded inside the inner bash -c shell.
    PATH="$jq_only_bin" bash --noprofile --norc -c '
      source "$1"
      _safety_parse_osv_batch "$(cat "$2")"
    ' _ "$ROOT_DIR/lib/safety_coach.sh" "$cvss_batch_mock"
  )"
  assert_contains "$jq_batch_parsed" "0|GHSA-cvss-9800-critical|CRITICAL|0|" "jq fallback batch parser must score CVSS:3.1 9.8 vector as CRITICAL"
  assert_contains "$jq_batch_parsed" "1|GHSA-cvss-6100-medium|MEDIUM|0|" "jq fallback batch parser must score CVSS:3.1 6.1 vector as MEDIUM"

  cvss_vuln_mock="$tmpdir/cvss-vuln.json"
  printf '%s\n' '{"id":"GHSA-cvss-9800-critical","summary":"Hydrated CVSS 3.1 vector","severity":[{"type":"CVSS_V3","score":"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"}]}' > "$cvss_vuln_mock"
  jq_vuln_parsed="$(
    # shellcheck disable=SC2016 # Positional parameters are intentionally expanded inside the inner bash -c shell.
    PATH="$jq_only_bin" bash --noprofile --norc -c '
      source "$1"
      _safety_parse_osv_vuln "$(cat "$2")"
    ' _ "$ROOT_DIR/lib/safety_coach.sh" "$cvss_vuln_mock"
  )"
  assert_contains "$jq_vuln_parsed" "CRITICAL|||" "jq fallback vuln parser must score CVSS:3.1 9.8 vector as CRITICAL"
fi

osv_no_brew_bin="$tmpdir/osv-no-brew-bin"
make_mock "$osv_no_brew_bin" brew <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "list" ]; then
  printf 'formula-only 1.2.3\n'
fi
exit 0
EOF
make_mock "$osv_no_brew_bin" npm <<'EOF'
#!/usr/bin/env bash
printf '/usr/local/lib\n`-- demo-npm-pkg@2.4.0\n'
EOF
osv_tuples_collected="$(
  # shellcheck disable=SC2016 # Positional parameters and arrays are intentionally expanded inside the inner bash -c shell.
  PATH="$osv_no_brew_bin:$posix_bin" bash --noprofile --norc -c '
    source "$1"
    _safety_collect_osv_tuples
    for ((i = 0; i < ${#_ua_osv_pkg[@]}; i++)); do
      printf "%s|%s|%s|%s\n" "${_ua_osv_eco[$i]}" "${_ua_osv_mgr[$i]}" "${_ua_osv_pkg[$i]}" "${_ua_osv_ver[$i]}"
    done
  ' _ "$ROOT_DIR/lib/safety_coach.sh"
)"
assert_contains "$osv_tuples_collected" "npm|npm|demo-npm-pkg|2.4.0" "OSV tuple collector must emit npm packages"
assert_not_contains "$osv_tuples_collected" "Homebrew" "OSV tuple collector must NEVER emit Homebrew ecosystem"
assert_not_contains "$osv_tuples_collected" "formula-only" "OSV tuple collector must NEVER emit brew formulae"

# ===========================================================================
# Wait for all parallel dry-run / live-mock / dist jobs, then assert results
# ===========================================================================
for _pid in $bg_pids; do
  wait "$_pid" || true
done

read_rc() { cat "$tmpdir/rc-${1}.txt" 2>/dev/null || printf '99'; }
read_out() { cat "$tmpdir/out-${1}.txt" 2>/dev/null || true; }

# --- Suite 1, 2a, 3, 10, 11c: Full Mocked Ubuntu Dry-Run ---
output="$(read_out ubuntu-dry)"
assert_eq "$(read_rc ubuntu-dry)" "0" "mocked Ubuntu dry-run must exit 0"
assert_file_not_exists "$ubuntu_sentinel" "dry-run must NEVER execute update-node"

assert_contains "$output" "OPENAI CODEX CLI" "expected prominent uppercase unit title for Codex"
assert_contains "$output" "claude update" "expected Claude Code to use first-party updater"
assert_contains "$output" "codex update" "expected Codex CLI to use first-party updater"
assert_not_contains "$output" "npm install -g @anthropic-ai/claude-code@latest" "Claude Code must not update via npm install"
assert_not_contains "$output" "npm install -g @openai/codex@latest" "Codex CLI must not update via npm install"
assert_contains "$output" "version before" "expected readable version before row"
assert_contains "$output" "after" "expected readable stacked version outcome rows"
assert_contains "$output" "path" "expected executable path rows"
assert_not_contains "$output" "version = " "version rows should not use noisy prefixes"
assert_not_contains "$output" "VERSION BEFORE" "version labels should not be shouty uppercase"
assert_contains "$output" "purpose" "expected purpose label instead of does"
assert_not_regex "$output" '^[[:space:]]+does[[:space:]]+' "legacy does label should not be present"
assert_contains "$output" "FLATPAK APPS" "expected flatpak package card"
assert_contains "$output" "result" "expected result rows"
assert_not_contains "$output" "mode" "intro/dry-run should not contain legacy mode metadata line"
assert_not_regex "$output" '^[[:space:]]*UPDATE ALL$' "old non-ascii UPDATE ALL header must not exist"
assert_not_contains "$output" "callsign" "intro should not contain legacy callsign metadata line"
assert_contains "$output" "01110101  01110000" "expected indented binary divider under title art"
assert_contains "$output" "pending updates" "expected pending updates block"
assert_contains "$output" "COVERAGE PREFLIGHT" "expected coverage preflight"
assert_contains "$output" "Secret safety:" "expected secret safety explanation in coverage preflight"
assert_contains "$output" "BUN RUNTIME" "expected Bun runtime card"
assert_contains "$output" "CARGO-INSTALLED CLIS" "expected cargo-installed CLI coverage"
assert_contains "$output" "VS CODE EXTENSIONS" "expected VS Code extension coverage when code exists"
assert_contains "$output" "VSCODIUM EXTENSIONS" "expected VSCodium extension coverage when codium exists"
assert_contains "$output" "LINUX FIRMWARE UPDATES" "expected firmware update coverage"
assert_contains "$output" "fwupdmgr get-updates" "expected firmware dry-run preview"
assert_contains "$output" "apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 -o APT::Progress-Fancy=0 -o Dpkg::Progress-Fancy=0 update -y" "expected non-PTY apt update flags"
assert_contains "$output" "shell profiles" "expected shell profile boundary in coverage preflight"
assert_contains "$output" "receipt summary" "expected final receipt summary"
assert_contains "$output" "RUN DETAILS" "expected receipt RUN DETAILS section"
assert_contains "$output" "CLEANUP NEXT STEPS" "expected cleanup next-steps section"
assert_contains "$output" "AFTER-RUN CHECK-IN" "expected after-run check-in section"
assert_contains "$output" "What to resolve after this run" "expected plain-English check-in framing"
assert_contains "$output" "Cleanup choices are collected before updates start" "expected upfront cleanup guidance"
assert_contains "$output" "OPTIONAL CHOICES PREFLIGHT" "expected optional choices preflight"
assert_contains "$output" "Dry-run:" "expected dry-run explanation for optional prompt-gated steps"
assert_contains "$output" "before" "receipt should show stacked before version rows"
assert_not_contains "$output" "STEP                          RESULT      BEFORE" "receipt must not use cramped legacy header"
assert_contains "$output" "APT CLEANUP?" "expected large apt cleanup question in upfront choices"
assert_contains "$output" "sudo apt-get autoremove --purge -y" "expected apt autoremove purge preview"
assert_contains "$output" "sudo apt-get autoclean" "expected apt autoclean preview"
assert_contains "$output" "sudo apt-get clean" "expected apt clean preview"
assert_contains "$output" "WORKSTATION CACHE CLEANUP?" "expected workstation cache cleanup prompt"
assert_contains "$output" "npm cache clean --force" "expected npm cache cleanup in dry-run"
assert_contains "$output" "timeout 20s uv cache prune" "expected bounded uv cache prune in dry-run"
assert_contains "$output" "disabled snap revisions" "expected disabled snap revision cleanup in dry-run"
assert_contains "$output" "journalctl --vacuum-size=512M" "expected journal vacuum in dry-run"

# Cleanup redesign: no full-home find ~ or __pycache__ crawl
assert_not_contains "$output" "find ~" "cleanup dry-run must not contain full-home find ~ crawl"
assert_not_contains "$output" "__pycache__" "cleanup dry-run must not contain __pycache__ crawl"

# P0 non-interactive apt-get & dpkg env/flags in dry-run
assert_contains "$output" "DEBIAN_FRONTEND=noninteractive" "apt dry-run must set DEBIAN_FRONTEND=noninteractive"
assert_contains "$output" "DEBCONF_NONINTERACTIVE_SEEN=true" "apt dry-run must set DEBCONF_NONINTERACTIVE_SEEN=true"
assert_contains "$output" "NEEDRESTART_MODE=l" "apt dry-run must set NEEDRESTART_MODE=l"
assert_contains "$output" "UCF_FORCE_CONFFOLD=1" "apt dry-run must set UCF_FORCE_CONFFOLD=1"
assert_contains "$output" "APT_LISTCHANGES_FRONTEND=none" "apt dry-run must set APT_LISTCHANGES_FRONTEND=none"
assert_contains "$output" "--force-confdef" "apt dry-run must pass --force-confdef"
assert_contains "$output" "--force-confold" "apt dry-run must pass --force-confold"
assert_contains "$output" "DPkg::Lock::Timeout=60" "apt dry-run must pass DPkg::Lock::Timeout=60"

# Corepack yarn probe + Brew tap trust preflight (preserved)
assert_contains "$output" "99.0.0-test" "Corepack yarn version probe must run with download prompts disabled"
assert_not_contains "$output" "missing COREPACK_ENABLE_DOWNLOAD_PROMPT=0" "yarn probe must set COREPACK_ENABLE_DOWNLOAD_PROMPT=0"
assert_contains "$output" "brew tap trust preflight" "expected Homebrew tap trust preflight section"
assert_contains "$output" "Plain English:" "expected plain-English explanation for untrusted taps"
assert_contains "$output" "Gold standard:" "expected gold-standard action for untrusted taps"
assert_contains "$output" "INSIGHT" "expected insight panel for untrusted taps"
assert_contains "$output" "A tap is an extra Homebrew package source" "expected tap plain-English explanation"
assert_contains "$output" "not a malware verdict" "expected calm malware-vs-trust clarification"
assert_contains "$output" "Do not panic" "expected explicit panic guidance"
assert_contains "$output" "Untap means" "expected untap plain-English explanation"
assert_contains "$output" "removes this package source from Homebrew" "expected untap effect clarity"
assert_contains "$output" "does not delete your projects" "expected untap safety boundary"
assert_contains "$output" "Homebrew may refuse if installed tools still depend on it" "expected untap dependency caveat"
assert_contains "$output" "Recommended: untap it now" "expected unused untrusted tap recommendation"
assert_contains "$output" "Trust source action" "expected untrusted tap action in final check-in"
assert_contains "$output" "brew untap example/tap" "expected exact untap command in dry-run"
assert_contains "$output" "env -u BASH_ENV -u ENV bash --noprofile --norc -c" "expected compound shell calls to avoid startup files"

# Card version ordering & blank-line section spacing contracts
if awk '
  /▌ NPM SELF-UPDATE/ { in_npm=1 }
  in_npm && /version before/ { before=NR }
  in_npm && /result/ { result=NR }
  in_npm && /^[[:space:]]*after[[:space:]]/ { after=NR; exit }
  END { if (!before || !result || !after || !(before < result && result < after)) exit 1 }
' <<< "$output"; then pass
else fail "expected npm self-update version before < result < after ordering"; fi

if awk '
  /^╾──── / { expecting_card=1; blank_gap=0; next }
  expecting_card {
    if ($0 == "") { blank_gap++; next }
    if ($0 ~ /^   ▌ /) {
      if (blank_gap < 1) exit 1
      expecting_card=0; next
    }
    expecting_card=0
  }
' <<< "$output"; then pass
else fail "expected blank line between section headers and card output"; fi

# --- Suite 2b: Live mocked non-interactive apt-get & dpkg P0 verification ---
assert_eq "$(read_rc apt-live)" "0" "live mocked apt/dpkg run must exit 0"
apt_live_entries="$(cat "$apt_live_log" 2>/dev/null || true)"
assert_contains "$apt_live_entries" "CMD=dpkg ARGS=--configure -a --force-confdef --force-confold DF=noninteractive DNS=true NR=l UCF=1 ALC=none" \
  "live dpkg --configure must receive all non-interactive env vars and confdef/confold flags"
assert_contains "$apt_live_entries" "CMD=apt-get ARGS=-o Dpkg::Use-Pty=0" "live apt-get must run"
assert_contains "$apt_live_entries" "DPkg::Lock::Timeout=60" "live apt-get must pass DPkg::Lock::Timeout=60"
assert_contains "$apt_live_entries" "--force-confdef" "live apt-get upgrade must pass --force-confdef"
assert_contains "$apt_live_entries" "--force-confold" "live apt-get upgrade must pass --force-confold"
assert_contains "$apt_live_entries" "DF=noninteractive DNS=true NR=l UCF=1 ALC=none" "live apt-get must receive all 5 non-interactive env vars"

# --- Suite 7b: Live fwupdmgr exit code 2 -> UNCHANGED (NOT FAIL) ---
fwupd_live_out="$(read_out fwupd-live)"
assert_eq "$(read_rc fwupd-live)" "0" "fwupdmgr get-updates exit 2 must not fail update-all"
assert_contains "$fwupd_live_out" "UNCHANGED" "fwupdmgr exit 2 must be tracked as UNCHANGED"
assert_contains "$fwupd_live_out" "No firmware updates available" "fwupdmgr exit 2 must explain no firmware updates available"
assert_not_contains "$fwupd_live_out" "✗ FAIL" "fwupdmgr exit 2 must NOT produce any FAIL status"

# --- Suite 9: Universal Linux multi-distro discovery ---
fedora_out="$(read_out fedora-dry)"
assert_eq "$(read_rc fedora-dry)" "0" "Fedora (dnf) dry-run must exit 0"
assert_contains "$fedora_out" "pkg manager: dnf" "Fedora dry-run must detect dnf"
assert_contains "$fedora_out" "DNF OS PACKAGES" "Fedora dry-run must show DNF OS PACKAGES card"
assert_contains "$fedora_out" "dnf upgrade -y" "Fedora dry-run must preview dnf upgrade -y"
assert_contains "$fedora_out" "DNF CLEANUP?" "Fedora dry-run must show DNF CLEANUP?"
assert_not_contains "$fedora_out" "$ sudo env DEBIAN_FRONTEND=noninteractive" "Fedora dry-run must never invoke apt-get"

ostree_out="$(read_out ostree-dry)"
assert_eq "$(read_rc ostree-dry)" "0" "Immutable Fedora (rpm-ostree) dry-run must exit 0"
assert_contains "$ostree_out" "pkg manager: rpm-ostree" "rpm-ostree must be prioritized over dnf"
assert_contains "$ostree_out" "IMMUTABLE OS IMAGE" "rpm-ostree dry-run must show IMMUTABLE OS IMAGE card"
assert_contains "$ostree_out" "rpm-ostree upgrade --check" "rpm-ostree dry-run must preview rpm-ostree upgrade --check"
assert_not_contains "$ostree_out" "dnf upgrade -y" "rpm-ostree host must not call dnf upgrade -y"
assert_not_contains "$ostree_out" "$ sudo env DEBIAN_FRONTEND=noninteractive" "rpm-ostree host must never invoke apt-get"

arch_out="$(read_out arch-dry)"
assert_eq "$(read_rc arch-dry)" "0" "Arch (pacman) dry-run must exit 0"
assert_contains "$arch_out" "pkg manager: pacman" "Arch dry-run must detect pacman"
assert_contains "$arch_out" "ARCH OS PACKAGES" "Arch dry-run must show ARCH OS PACKAGES card"
assert_contains "$arch_out" "pacman -Syu --noconfirm" "Arch dry-run must preview pacman -Syu --noconfirm"
assert_contains "$arch_out" "PACMAN CACHE CLEANUP?" "Arch dry-run must show PACMAN CACHE CLEANUP?"
assert_not_contains "$arch_out" "$ sudo env DEBIAN_FRONTEND=noninteractive" "Arch dry-run must never invoke apt-get"

alpine_out="$(read_out alpine-dry)"
assert_eq "$(read_rc alpine-dry)" "0" "Alpine (apk) dry-run must exit 0"
assert_contains "$alpine_out" "pkg manager: apk" "Alpine dry-run must detect apk"
assert_contains "$alpine_out" "ALPINE OS PACKAGES" "Alpine dry-run must show ALPINE OS PACKAGES card"
assert_contains "$alpine_out" "apk update" "Alpine dry-run must preview apk update"
assert_contains "$alpine_out" "apk upgrade" "Alpine dry-run must preview apk upgrade"
assert_contains "$alpine_out" "APK CACHE CLEANUP?" "Alpine dry-run must show APK CACHE CLEANUP?"
assert_not_contains "$alpine_out" "$ sudo env DEBIAN_FRONTEND=noninteractive" "Alpine dry-run must never invoke apt-get"

void_out="$(read_out void-dry)"
assert_eq "$(read_rc void-dry)" "0" "Void (xbps) dry-run must exit 0"
assert_contains "$void_out" "pkg manager: xbps" "Void dry-run must detect xbps"
assert_contains "$void_out" "XBPS CLEANUP?" "Void dry-run must show XBPS CLEANUP?"
assert_contains "$void_out" "sudo xbps-remove -Ooy" "Void cleanup dry-run must use non-interactive xbps-remove -Ooy"
assert_not_contains "$void_out" "xbps-remove -Oo)" "Void cleanup prompt must not omit -y flag on xbps-remove -Ooy"
assert_not_contains "$void_out" "$ sudo env DEBIAN_FRONTEND=noninteractive" "Void dry-run must never invoke apt-get"

# Gate B regression: cleanup_status_for / cleanup_note_for must not mask dnf5/zypper/xbps FAIL as SKIP
for _cl_case in \
  "dnf5 autoremove|dnf5 autoremove failed" \
  "zypper cleanup|zypper clean failed" \
  "xbps cleanup|xbps-remove failed"; do
  _cl_label="${_cl_case%%|*}"
  _cl_note="${_cl_case#*|}"
  _cl_res="$(
    # shellcheck disable=SC2016 # Positional parameters are intentionally expanded inside the inner bash -c shell.
    bash --noprofile --norc -c '
      source "$1"
      _ua_labels=("$2")
      _ua_stats=("FAIL")
      _ua_notes=("$3")
      printf "%s|%s\n" "$(cleanup_status_for "apt autoremove")" "$(cleanup_note_for "apt autoremove")"
    ' _ "$ROOT_DIR/lib/receipt.sh" "$_cl_label" "$_cl_note"
  )"
  assert_eq "$_cl_res" "FAIL|$_cl_note" "cleanup_status_for/note_for must surface FAIL for $_cl_label instead of masking as SKIP"
done

brew_only_out="$(read_out brew-only-dry)"
assert_eq "$(read_rc brew-only-dry)" "0" "brew-only dry-run must exit 0"
assert_contains "$brew_only_out" "pkg manager: none" "brew-only dry-run must detect pkg manager: none"
assert_contains "$brew_only_out" "HOMEBREW FORMULAE" "brew-only dry-run must show HOMEBREW FORMULAE card"
assert_contains "$brew_only_out" "EDITOR EXTENSIONS" "missing editor CLIs must show EDITOR EXTENSIONS skipped card"
assert_not_contains "$brew_only_out" "$ sudo env DEBIAN_FRONTEND=noninteractive" "brew-only dry-run must never invoke apt-get"

# --- Suite 12: Receipt changelog table, visual preview, & standalone bundle ---
receipt_output="$(read_out receipt-visual)"
assert_eq "$(read_rc receipt-visual)" "0" "receipt visual selftest must exit 0"
assert_contains "$receipt_output" "WHAT CHANGED" "receipt must lead with WHAT CHANGED"
assert_contains "$receipt_output" "old -> new" "receipt must explain version arrows"
assert_contains "$receipt_output" "PROGRAM / PACKAGE" "receipt changelog table must show PROGRAM / PACKAGE column"
assert_contains "$receipt_output" "yarn (corepack)" "receipt must include yarn (corepack)"
assert_contains "$receipt_output" "before 1.22.22" "receipt must show yarn before version"
assert_contains "$receipt_output" "after  4.17.0" "receipt must show yarn after version"
assert_contains "$receipt_output" "before libevent 2.1.12_1" "receipt must show Homebrew formula before version"
assert_contains "$receipt_output" "after  2.1.13" "receipt must show Homebrew formula after version"
assert_contains "$receipt_output" "before pillow 12.2.0" "receipt must show uv tool before version"
assert_contains "$receipt_output" "after  12.3.0" "receipt must show uv tool after version"
assert_contains "$receipt_output" "NO ACTION NEEDED" "receipt must group quiet rows under NO ACTION NEEDED"
assert_contains "$receipt_output" "NEEDS YOUR ATTENTION" "receipt must group manual follow-up under NEEDS YOUR ATTENTION"
assert_contains "$receipt_output" "Firmware needs manual attention" "receipt must show manual firmware attention"
assert_contains "$receipt_output" "means:" "attention items must explain means:"
assert_contains "$receipt_output" "action:" "attention items must explain action:"

preview_output="$(read_out visual-preview)"
assert_eq "$(read_rc visual-preview)" "0" "UPDATE_ALL_VISUAL_PREVIEW=1 must exit 0"
assert_contains "$preview_output" "01110101  01110000" "visual preview must show title art binary divider"
assert_contains "$preview_output" "COVERAGE PREFLIGHT" "visual preview must show coverage preflight"
assert_contains "$preview_output" "SAFETY COACH" "visual preview must show Safety Coach preview"
assert_contains "$preview_output" "MAL-2026-0001" "visual preview must show sample OSV finding"
assert_contains "$preview_output" "PORT-TCP-3000" "visual preview must show sample exposed port finding"
assert_contains "$preview_output" "WHAT CHANGED" "visual preview must show receipt changelog table"

if [ -x "$DIST_BUNDLE" ]; then
  if bash -n "$DIST_BUNDLE"; then pass
  else fail "dist/update-all failed bash -n syntax check"; fi

  dist_help="$("$DIST_BUNDLE" --help)"
  assert_contains "$dist_help" "--dry-run" "dist/update-all --help must list --dry-run"
  assert_contains "$dist_help" "--firmware" "dist/update-all --help must list --firmware"
  assert_contains "$dist_help" "--watcher=MODE" "dist/update-all --help must list --watcher=MODE"
  assert_contains "$dist_help" "UPDATE_ALL_PROBE_TIMEOUT=15s" "dist/update-all --help must document UPDATE_ALL_PROBE_TIMEOUT=15s"
  assert_contains "$dist_help" "UPDATE_ALL_BUILD_TIMEOUT=1200s" "dist/update-all --help must document UPDATE_ALL_BUILD_TIMEOUT=1200s"

  # M1: Verify set -uo pipefail and defaults precede inlined modules, and bundle matches builder output
  if awk '
    /^set -uo pipefail$/ && !pipefail_ln { pipefail_ln = NR }
    /UPDATE_ALL_PROBE_TIMEOUT=.*15s/ && !probe_ln { probe_ln = NR }
    /UPDATE_ALL_BUILD_TIMEOUT=.*1200s/ && !build_ln { build_ln = NR }
    /^# ===== MODULE: lib\/colors_and_glyphs\.sh =====$/ && !mod_ln { mod_ln = NR }
    END { if (!pipefail_ln || !probe_ln || !build_ln || !mod_ln || !(pipefail_ln < probe_ln && probe_ln < build_ln && build_ln < mod_ln)) exit 1 }
  ' "$DIST_BUNDLE"; then pass
  else fail "dist/update-all must set pipefail and timeout defaults before inlined modules"; fi

  dist_check="$tmpdir/dist-check"
  if "$ROOT_DIR/scripts/build-standalone.sh" "$dist_check" >/dev/null 2>&1 && cmp -s "$DIST_BUNDLE" "$dist_check"; then
    pass
  else
    fail "dist/update-all does not match scripts/build-standalone.sh output (rebuild needed)"
  fi

  dist_mode="$(stat -c '%a' "$DIST_BUNDLE" 2>/dev/null || stat -f '%Lp' "$DIST_BUNDLE" 2>/dev/null || true)"
  assert_eq "$dist_mode" "755" "dist/update-all must have 0755 permissions (world-readable executable, not 711)"
  dist_ls_perms="$(ls -l "$DIST_BUNDLE" | awk '{print substr($1, 1, 10)}')"
  assert_eq "$dist_ls_perms" "-rwxr-xr-x" "dist/update-all permissions string must be -rwxr-xr-x"

  dist_visual="$(read_out dist-visual)"
  assert_eq "$(read_rc dist-visual)" "0" "dist/update-all visual receipt selftest must exit 0"
  assert_contains "$dist_visual" "WHAT CHANGED" "dist/update-all visual receipt must render WHAT CHANGED"
  assert_contains "$dist_visual" "yarn (corepack)" "dist/update-all visual receipt must render changelog entries"
else
  fail "standalone bundle dist/update-all is missing or not executable (run scripts/build-standalone.sh)"
fi

# Minor 2: LC_ALL=C ASCII receipt alignment check (1-char '>' center arrow & ASCII borders)
ascii_receipt="$(HOME="$fake_home" PATH="$posix_bin" LC_ALL=C UPDATE_ALL_RECEIPT_SELFTEST=visual "$UPDATE_ALL" --no-anim --no-color)"
assert_contains "$ascii_receipt" "+---+" "LC_ALL=C receipt table must use ASCII +---+ center column border"
assert_contains "$ascii_receipt" "| > |" "LC_ALL=C receipt table must use 1-char '>' center arrow"
assert_not_contains "$ascii_receipt" "┌" "LC_ALL=C receipt table must not emit UTF-8 box characters"

END_S="$(date +%s)"
ELAPSED=$((END_S - START_S))
printf 'Test summary: %d passed, %d failed (%ds)\n' "$PASS_COUNT" "$FAIL_COUNT" "$ELAPSED"
[ "$FAIL_COUNT" -eq 0 ]
