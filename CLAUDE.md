# CLAUDE.md — Update-All-Cmd

Universal, local-first Bash workstation updater for Linux developer machines: one `update-all` command
that auto-discovers distro and dev package managers, streams output without stalls or mid-run prompts,
renders a persistent 2-row amber TUI dock with self-calibrating ETAs, tracks reclaimed disk space, prints
a dramatic Unicode changelog receipt, and finishes with an interactive **Safety Coach** security audit.
Personal-workstation tool — **not** fleet/server automation.

## Architecture
- `bin/update-all` — CLI entrypoint, option parser, selftest dispatcher, and main run orchestrator. Sources `lib/*.sh` dynamically (or runs self-contained when `_UA_BUNDLED=1`).
- `lib/colors_and_glyphs.sh` — 256/8/0-color palette, monochrome Unicode glyphs (`↗ ✓ = ✗ · ▲ ◆ → │ ▌`), ASCII fallback, banners, and tool cards.
- `lib/tui.sh` — DECSTBM persistent 2-row TUI progress dock (`--bar=bottom|top|off`), kinetic watcher (`--watcher=hybrid|braille|anthropic`), EWMA ETA store (`timings.tsv`), `SIGWINCH` resize, and min-size compact mode.
- `lib/runner.sh` — zero-stall FIFO watcher loop (`stdbuf -oL -eL`, `timeout -k`), streaming secret redactor, closed-stdin (`</dev/null`) execution, `sudo` keepalive, and non-interactive apt wrapper.
- `lib/discover.sh` — `/etc/os-release` host/distro discovery, safe `PATH` augmentation, bounded version probes, `COVERAGE PREFLIGHT`, and upfront optional choice collection.
- `lib/updaters.sh` — universal Linux updaters (`apt`/`dpkg`, `rpm-ostree`, `dnf5`/`dnf`/`yum`, `pacman`, `zypper`, `apk`, `xbps`, `snap`, `flatpak`, `brew`, `mise`, `volta`, `fnm`, `corepack`, `bun`, `deno`, `npm`, `pnpm`, `yarn`, `claude`, `codex`, `uv`, `pipx`, `rustup`, `cargo`, `gh`, `code`/`codium`/`code-insiders`, `fwupdmgr`) with per-package delta capture.
- `lib/cleanup.sh` — distro-aware system package cleanup + bounded workstation cache cleanup (explicit safe cache dirs, no full-`$HOME` crawl) with reclaimed disk space tracking.
- `lib/safety_coach.sh` — cached Homebrew tap trust inspection, OSV.dev `MAL-*`/CVE package audit, read-only open-port & firewall posture check, and guided end-of-run remediation walkthrough.
- `lib/receipt.sh` — `RECEIPT` summary + reclaimed space, Unicode `WHAT CHANGED` table (`BEFORE → AFTER`), `NEEDS YOUR ATTENTION`, `NO ACTION NEEDED`, `RUN DETAILS`, `CLEANUP NEXT STEPS`, and `AFTER-RUN CHECK-IN`.
- `scripts/build-standalone.sh` — bundles `bin/update-all` + `lib/*.sh` into single-file `dist/update-all`.
- `install.sh` — symlinks `bin/update-all` into `~/.local/bin/update-all`.
- `tests/test-output-format.sh` — automated output, redaction, stdin, watcher, Safety Coach, and receipt tests.
- `docs/` — handoff notes + colored SVG previews (`terminal-preview.svg`, `receipt-and-safety-preview.svg`).

## Commands
- Run: `./bin/update-all --dry-run` then `./bin/update-all` (or `./bin/update-all --all`).
- Key flags: `--dry-run`, `-a`/`--all`, `--firmware`, `--no-anim`, `--no-color`, `--no-security-scan`, `--non-interactive`, `--watcher=hybrid|braille|anthropic`, `--bar=bottom|top|off`, `-h`/`--help`.
- Build standalone bundle: `./scripts/build-standalone.sh` -> `dist/update-all`.
- Install: `./install.sh` (then ensure `~/.local/bin` is on `PATH`).
- Quality gate (mirror CI before committing):
  - `bash -n bin/update-all lib/*.sh install.sh scripts/build-standalone.sh`
  - `shellcheck bin/update-all lib/*.sh install.sh scripts/build-standalone.sh tests/test-output-format.sh`
  - `bash tests/test-output-format.sh`
  - `./bin/update-all --dry-run --no-anim --no-color`
  - `cspell README.md bin/update-all install.sh scripts/build-standalone.sh lib/*.sh docs/UPDATE_ALL_HANDOFF.md cspell.json tests/test-output-format.sh CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md .github/*.md .github/*.yml .github/**/*.md .github/**/*.yml`

## Gotchas
- **Strict Bash 3.2 parse compatibility.** macOS ships Bash 3.2.57 while Linux ships Bash 5.x. Never use `${var,,}`, `declare -A`, `local -n`, `readarray`/`mapfile`, `|&`, or `coproc`; runtime-guard Bash 4+/5+ features (`BASH_VERSINFO[0]`).
- **Public-safe repo.** CI scans for leaked secrets/PII — never commit real `/Users/<name>` or `/home/<name>` paths (only `/home/linuxbrew` is allowlisted), private IPs (`192.168.*`, `100.*`), tokens, keys, or unredacted screenshots.
- **Zero mid-run stalls.** Keep `DEBIAN_FRONTEND=noninteractive`, `NEEDRESTART_MODE=l`, `DPkg::Lock::Timeout=60`, `</dev/null`, and bounded timeouts intact across all command wrappers.
- **Safety invariant.** Missing tools report `SKIP`, never fatal. Firmware (`--firmware`) stays strictly opt-in, cleanup uses explicit bounded targets only, and Safety Coach never auto-deletes packages or alters firewall rules even under `--all`.
