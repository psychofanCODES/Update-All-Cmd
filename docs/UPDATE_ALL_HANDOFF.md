# Update All Handoff

Last updated: 2026-11-18 UTC

## Project

`update-all` is a modular, local-first Bash CLI for universal Linux developer workstation updates.
Clone it anywhere, run `./install.sh` to place `update-all` on `~/.local/bin`, or run
`./scripts/build-standalone.sh` to build a single portable `dist/update-all` file.

## Modular Architecture

The program is split into focused, Bash 3.2+ parse-compatible modules (macOS Bash 3.2.57 and
Linux Bash 5.x, with runtime `BASH_VERSINFO[0]` guards for Bash 4+/5+ features):

- `bin/update-all` — CLI entrypoint, option parser, selftest dispatcher, and main orchestration. Sources `lib/*.sh` unless `_UA_BUNDLED=1`.
- `lib/colors_and_glyphs.sh` — 256-color/8-color/0-color palette, monochrome Unicode glyphs (`↗ ✓ = ✗ · ▲ ◆ → │ ▌`), ASCII fallback (`UPDATE_ALL_ASCII=1`), banners, and tool cards.
- `lib/tui.sh` — DECSTBM 2-row persistent progress dock (`--bar=bottom|top|off`), kinetic watcher (`--watcher=hybrid|braille|anthropic`), EWMA self-calibrating ETA store (`timings.tsv`), `SIGWINCH` dynamic resize, and compact min-size handling.
- `lib/runner.sh` — zero-stall FIFO-backed concurrent watcher loop (`stdbuf -oL -eL`, `timeout -k`), fast-path secret redactor, closed-stdin (`</dev/null`) execution, `sudo` keepalive, and non-interactive apt wrapper.
- `lib/discover.sh` — `/etc/os-release` host/distro discovery, safe `PATH` augmentation, bounded version probes, `COVERAGE PREFLIGHT`, and upfront optional choice collection.
- `lib/updaters.sh` — universal Linux package-manager and dev-tool updaters with before/after tracking and per-package delta capture for the receipt table.
- `lib/cleanup.sh` — distro-aware system package cleanup (`apt`/`dnf`/`pacman`/`zypper`/`apk`/`xbps`) and safe bounded workstation cache cleanup with reclaimed disk space tracking.
- `lib/safety_coach.sh` — cached Homebrew tap trust inspection, OSV.dev batch advisory/malicious-package audit (`MAL-*`, Critical/High CVEs/GHSAs with CVSS v3.0/v3.1 base-score evaluation), read-only open-port & firewall check, and guided post-receipt remediation walkthrough.
- `lib/receipt.sh` — upgraded `RECEIPT` summary + reclaimed disk space, dramatic Unicode `WHAT CHANGED` table (`PROGRAM / PACKAGE | BEFORE → AFTER | VIA`), `NEEDS YOUR ATTENTION`, compact `NO ACTION NEEDED`, `RUN DETAILS`, `CLEANUP NEXT STEPS`, and `AFTER-RUN CHECK-IN`.
- `scripts/build-standalone.sh` — embeds `lib/*.sh` modules inline at `# __UA_BUNDLE_MODULES_HERE__` inside `bin/update-all` (replacing the module loader with `_UA_BUNDLED=1`) to produce standalone `dist/update-all` (`0755`).

## Current Product Direction

- Keep it local-first, universal across Linux distros, and transparent.
- Never replace package managers; call first-party/package-manager commands cleanly.
- Guarantee zero mid-run hangs or surprise Enter prompts.
- Favor explicit upfront choices and guided end-of-run remediation over silent deletion.
- Keep the public repo free of real user home paths, private IPs, secrets, and tokens.

## Current UX Contract

- Signature amber `UPDATE ALL` intro art with dark-teal two-line binary divider (`update` / centered `all`).
- Refined monochrome Unicode glyphs (`↗ ✓ = ✗ · ▲ ◆ → │ ▌ ⣾ ⣽ ⣻ ✽`) — never chunky color emojis — with ASCII fallback (`UPDATE_ALL_ASCII=1`).
- Anchored 2-row bottom TUI dock (`--bar=bottom` default, `--bar=top`, `--bar=off`):
  - Row 1: `━━ [████████████░░░░░░░░] 62% · ~38s left · Step 8/13 · TOOLS · ↗3 ✓4 =1 ·0 ✗0 ━━`
  - Row 2: `✽ Upgrading Homebrew formulae…   ⣾⣽⣻   00:18 · ● live`
  - Persists per-step EWMA durations in `${XDG_CACHE_HOME:-~/.cache}/update-all/timings.tsv` for calibrated ETAs.
  - Handles `SIGWINCH` resize dynamically and adapts gracefully on small terminals (`<60x14` compact mode, `<50x12` inline fallback).
- Live streamed logs render behind a subtle vertical `│` gutter (`C_FRAME`) with dimmed normal chatter and semantic coloring for errors, warnings, upgrades, and apt repository/progress lines.
- Prominent package/tool cards (`▌ UNIT TITLE`, `package`, `version before`, quieter `path`, `purpose`, `result`, `note`, `version after`).
- `FIRMWARE REVIEW` cards summarize device, release, version arrow, urgency, meaning, and next action without dumping raw GUIDs/checksums. Firmware updates remain strictly opt-in (`--firmware` or interactive prompt), never auto-flashed by `--all`.
- Final `RECEIPT` includes summary counters, reclaimed disk space (`412 MB` etc.), dramatic Unicode `WHAT CHANGED` table (`PROGRAM / PACKAGE | BEFORE → AFTER | VIA` with bright cyan before, bold amber `→`, bright mint after), `NEEDS YOUR ATTENTION`, compact `NO ACTION NEEDED`, `RUN DETAILS`, `CLEANUP NEXT STEPS`, and `AFTER-RUN CHECK-IN`.
- `docs/terminal-preview.svg` and `docs/receipt-and-safety-preview.svg` are sanitized colored vector SVGs generated from real 256-color `lib/*.sh` output; keep both visually faithful when TUI, receipt, or Safety Coach layouts change.

## Zero-Stall & Non-Interactive Architecture

- Unbuffered live streaming: `stdbuf -oL -eL` on external commands plus `stdbuf -i0 -o0 tr -d '\000'` in the FIFO pipeline so output streams immediately without stalling on pipe buffers.
- Non-interactive apt/dpkg: `DEBIAN_FRONTEND=noninteractive`, `DEBCONF_NONINTERACTIVE_SEEN=true`, `NEEDRESTART_MODE=l`, `UCF_FORCE_CONFFOLD=1`, `APT_LISTCHANGES_FRONTEND=none`, `Dpkg::Options::=--force-confdef/--force-confold`, `DPkg::Lock::Timeout=60`, `Acquire::http/https::Timeout=30`, `Acquire::Retries=3`.
- Closed stdin (`</dev/null`) across `run_cmd`, `sudo_cmd`, and probes so commands never block waiting for keyboard input mid-run.
- Background `sudo` keepalive refreshes cached credentials every 30s (cleanly torn down via `EXIT`/`INT`/`TERM` traps); if a session still expires interactively, `tui_pause_for_tty` / `tui_resume_after_tty` cleanly pause and restore the scroll region.
- Bounded timeouts (`timeout -k`) on all tiers: `UPDATE_ALL_PROBE_TIMEOUT=15s`, `UPDATE_ALL_COREPACK_TIMEOUT=90s`, `UPDATE_ALL_NODE_TIMEOUT=300s`, `UPDATE_ALL_STEP_TIMEOUT=600s`, `UPDATE_ALL_BUILD_TIMEOUT=1200s`.

## Universal Coverage Behavior

Auto-discovered and updated when present (missing tools record `SKIP`):

- **Linux system managers:** `dpkg`/`apt`, `rpm-ostree`, `dnf5`/`dnf`/`yum`, `pacman`, `zypper`, `apk`, `xbps` (`xbps-install`).
- **Desktop/firmware:** `snap`, `flatpak`, `fwupdmgr` (opt-in).
- **Developer runtimes & CLIs:** `brew` (Homebrew/Linuxbrew), `node`/`update-node`, `mise`, `volta`, `fnm`, `corepack`, `pnpm`, `yarn`, `bun`, `deno`, `npm` (self + globals), `claude`, `codex`, `uv`, `pipx`, `rustup`, `cargo` (`cargo-install-update`), `gh` extensions, `code`/`codium`/`code-insiders` extensions.

Manual by design:

- Project repositories, active agent runtimes (Hermes/OpenClaw), containers/images, conda environments, AUR PKGBUILDs, large LLM weights, and shell profile edits.

## Cleanup Behavior

Cleanup stays opt-in and split into two explicit choices (auto-approved with `-a`/`--all` or typing `a`/`all` upfront):

1. **System package cleanup** (distro-aware):
   - `apt`: `apt-get autoremove --purge -y`, `apt-get autoclean`, `apt-get clean`
   - `dnf`: `dnf autoremove -y`, `dnf clean packages`
   - `pacman`: `pacman -Sc --noconfirm`
   - `zypper`: `zypper --non-interactive clean --all`
   - `apk`: `apk cache clean`
   - `xbps`: `xbps-remove -Ooy`
2. **Bounded workstation cache cleanup** (explicit safe targets only — **no slow full-`$HOME` crawl**):
   - `npm cache clean --force`, `rm -rf -- ~/.npm/_npx`
   - `pip3 cache purge`, `brew cleanup -s`, `timeout 20s uv cache prune`
   - Explicit `~/.cache/{camoufox,ms-playwright,BraveSoftware,electron,node-gyp,node,Homebrew,pip}`
   - `~/.codex/.tmp/plugins` and `~/.codex/.tmp/plugins.sha`
   - Disabled snap revisions and `sudo journalctl --vacuum-size=512M` (when systemd is active)

Before/after disk footprints are measured via bounded `du -sk` and reported as reclaimed space in the receipt. Archives, LLM weights, databases, project data, installed runtimes, and active virtualenvs are never touched.

## Safety Coach (Shipped)

Safety Coach Mode runs after updates (unless `--no-security-scan` or `UPDATE_ALL_SECURITY_SCAN=0`):

- **OSV.dev package audit (`scan_osv_packages`):** Queries `https://api.osv.dev/v1/querybatch` with global `npm`, `PyPI` (`uv`/`pipx`), and `crates.io` (`cargo`) tuples — sending ONLY `(package name, ecosystem, version)` (Homebrew is covered by native `brew tap-info` trust preflight and `brew upgrade`). Flags OpenSSF `MAL-*` malicious packages (`CRITICAL`) and `CRITICAL`/`HIGH` advisories (`GHSA-*`, `CVE-*`, `PYSEC-*`, `RUSTSEC-*`, including CVSS v3.0/v3.1 base-score vectors). Fails open safely (`SKIP`) when offline.
- **Open-port & firewall audit (`scan_public_ports`):** Read-only `ss -tulnpH` / `netstat` inspection plus `ufw`/`firewalld` status check; flags non-loopback listeners (`0.0.0.0`, `::`, LAN) with plain-English bind descriptions.
- **Homebrew tap trust (`inspect_brew_tap_trust` / `show_brew_tap_trust_preflight`):** Cached `brew tap-info` check with plain-English `INSIGHT` panels for `Untrusted` taps.
- **Guided post-receipt walkthrough (`run_safety_coach_remedy`):** Displays `◆ SAFETY COACH — ISSUES FOUND (N)` and offers `[1]` recommended fix, `[2]` alternate/inspect, `[3]` skip, `[q]` exit. Never auto-deletes packages or edits firewall rules — even under `--all`. Rejects shell metacharacters before executing any remedy command.

## Sudo And Secret Boundary

- Zero stored passwords, tokens, API keys, or private machine paths in the repository.
- Optional `UPDATE_ALL_SUDO_SECRET_KEY` passes external `secret` helper output via stdin to `sudo -S -p ''` without echoing it.
- All streamed output passes through `redact_secrets` for OpenAI, GitHub, Slack, AWS, private-key-header, and `TOKEN=`/`PASSWORD=` shapes.
- Internal compound shell commands run via `env -u BASH_ENV -u ENV bash --noprofile --norc -c ...`.

## Verification Commands

Run before committing/pushing:

```bash
bash -n bin/update-all lib/*.sh install.sh scripts/build-standalone.sh
shellcheck bin/update-all lib/*.sh install.sh scripts/build-standalone.sh tests/test-output-format.sh
bash tests/test-output-format.sh
./scripts/build-standalone.sh
./bin/update-all --help
./bin/update-all --dry-run --no-anim --no-color
cspell README.md bin/update-all install.sh scripts/build-standalone.sh lib/*.sh docs/UPDATE_ALL_HANDOFF.md cspell.json tests/test-output-format.sh CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md .github/*.md .github/*.yml .github/**/*.md .github/**/*.yml
git diff --check
```

## Known Limits

- Terminal font size cannot be changed per line from Bash; visual hierarchy comes from bold, uppercase, spacing, monochrome Unicode glyphs, and 256-color contrast.
- Anchored DECSTBM dock and kinetic watcher only activate in live interactive TTY runs on Bash 4+ (`--no-anim`, `--bar=off`, CI, and `--dry-run` disable them cleanly).
- OSV package scanning requires network reachability to `api.osv.dev` and skips safely when offline.
