# CC_Sync

Multi-repo sync, cross-device handoff, and module management for Claude Code.

## File Map

| File | Role |
|------|------|
| `sync.sh` | Main entry point: repo discovery, config sync, pull/commit/push, handoff, dotfiles push |
| `module-manager.sh` | Install/update/remove/restore third-party skills from GitHub |
| `lib/common.sh` | Shared bash helpers: `get_machine_name`, `compute_cc_hash`, `normalize_path`, `detect_gh`, `file_mtime`, `safe_mktemp` |
| `lib/handoff.py` | HANDOFF.md parser/writer (called by sync.sh and preflight.py) |
| `lib/module_helper.py` | Python helper for module-manager.sh |
| `HANDOFF.md` | Cross-device task relay (registry comment + device sections) |
| `.claude/skills/sync/SKILL.md` | /sync skill definition: instructs Claude how to run and interpret sync.sh |
| `.claude/skills/module-manager/SKILL.md` | /module-manager skill definition |
| `.claude/hooks/preflight.py` | Session startup hook: checks .machine-name, pending handoff tasks |

## Key Concepts

- **dotfiles repo**: User-owned git repo storing Claude Code config. Mapped via `CONFIG_MAP`. Subdirectory: `claude-code-config/`.
- **`.env`**: Machine-local config (gitignored). Created by first-run wizard. Keys: `DOTFILES_PATH` (required), `ENABLE_REPO_SYNC`, `WORKSPACE_ROOTS` (semicolon-separated), `TOPIC`.
- **`HANDOFF.md`**: Registry comment (`<!-- registry: ... -->`) defines valid device sections. `(none)` = no pending tasks. Only registered device names are section boundaries.
- **`CONFIG_MAP`**: Declarative array mapping dotfiles paths to local paths. Format: `"repo_relative|local_absolute|display_name"`.

## Prerequisites

- Python 3.10+ (for `tomllib` in module_helper.py)
- `gh` CLI (authenticated via `gh auth login`)
- `git`

## First Run

When `.env` does not exist:
- **Interactive terminal**: The first-run wizard launches automatically. It prompts for the dotfiles repo path, whether to enable repo sync, and workspace root directories.
- **Non-interactive** (Claude Code Bash tool): The wizard needs a TTY for its prompts, so sync.sh exits with an error. Run `bash sync.sh` once in an interactive terminal (e.g. Git Bash, PowerShell) to create `.env`; afterward `/sync` works normally from Claude Code.

Example `.env` (created by wizard — values are single-quoted via Python `shlex.quote`):
```
DOTFILES_PATH='/c/Claude_code_cli/dotfiles'
ENABLE_REPO_SYNC='true'
WORKSPACE_ROOTS='/c/Claude_code_cli'
```

The wizard always writes single-quoted form. Older unquoted/double-quoted `.env` files are auto-migrated to this canonical form on every sync run by `_migrate_legacy_env` (with stderr warnings if the old value contained `$` / backtick / multi-token whitespace).

## Commands

```bash
bash sync.sh                        # Full sync (6 steps)
bash sync.sh device list             # List registered devices
bash sync.sh device add <name>       # Register device in HANDOFF.md
bash sync.sh device remove <name>    # Unregister device
bash sync.sh repo-sync enable        # Enable project repo sync
bash sync.sh repo-sync unignore <n>  # Restore ignored repo
bash module-manager.sh restore       # Restore all skill modules from manifest
bash module-manager.sh list          # List tracked modules
```

## Code Constraints

### Functions and Scope

- A function defined inside an `if` block does not exist when that branch is skipped, and Step 3 callers then fail with `command not found` — define all helper functions at module level (top of script, outside conditionals).
- The `local` keyword is only valid inside functions. In the main execution body (while loops, etc.), use plain variable assignment.

### .env File Safety

- `sync.sh` loads `.env` via `source`, so any value the shell can interpret runs as code. **Single-quote** all values (`KEY='value'`) — single quotes inhibit `$`, backtick, `\`, and `!` expansion entirely. Double quotes (`KEY="value"`) are NOT safe: a value like `KEY="$(touch PWNED)"` is command-substituted at source-time. Embedded single quotes use the shell idiom `'\''` (close, escape, reopen).
- Always emit values via `shlex.quote()` — never hand-build the quoted form. The wizard, `_append_workspace_root`, and `_migrate_legacy_env` all do this.
- Unconditionally appending a key after a replacement loop creates duplicate entries — use in-loop elif replacement with a found-flag append instead.
- Older `.env` files (unquoted or double-quoted) are auto-rewritten to single-quoted form by `_migrate_legacy_env` on every run; warnings fire when a value originally contained `$` or backtick (previously expanded, now literal) or multiple whitespace-separated tokens (kept as-is, requires manual quoting).

### Python File I/O

- Windows defaults to CRLF line endings, which produce git phantom diffs on synced files — pass `newline="\n"` to `open(..., "w")`.
- Windows defaults to GBK/cp936 for text I/O, which fails on files created elsewhere — pass `encoding="utf-8"` explicitly.

### Clone Return Codes

`_interactive_clone_menu` return code contract:
- `0` = cloned successfully
- `1` = user skipped / invalid input
- `2` = added to .sync_ignore
- `3` = git clone execution failed (caller must create `.error` file)

New return codes must be added to both the function and the caller dispatch.

### Path Handling (Windows / Git Bash)

- `dirname "C:/foo"` returns `"C:"` rather than `"C:/"`, which breaks later path concatenation — fix after dirname: `[[ "$parent_dir" =~ ^[A-Za-z]:$ ]] && parent_dir="${parent_dir}/"`.
- Native Windows Python cannot resolve Git Bash-style `/c/Users/...` paths — pass paths from bash to Python via `normalize_path` (lib/common.sh).
- MSYS2 auto-converts leading-slash arguments like `/f` and `/v` into path translations before the Windows-native command sees them — wrap such commands in `cmd.exe //c "..."`.

### Multi-Root Repo Lookup

- `_find_repo_dir` returns the first directory name match across `WS_ROOTS`, so a same-named directory in another root could be auto-pushed to the wrong remote — the Step 3 caller must verify `remote.origin.url` matches the expected GitHub URL before processing.

### Sync Step Dependencies

- `KNOWN_REPOS` is built in Step 1 and immediately available. `REPO_ORDER` is built inside Step 3's while loop. Step 2 code can only reference `KNOWN_REPOS`.
- `WS_ROOTS` is parsed from `.env` at load time. `_find_repo_dir` depends on it.

## Verification

`bash sync.sh` is **not** a verification command — when `.env` exists it
performs a real sync (commits + pushes the dotfiles repo, commits +
pushes every project repo). Do not invoke it just to "check things still
work." Use these read-only / side-effect-free checks instead:

```bash
bash -n sync.sh                # Syntax check (parses, does not execute)
shellcheck sync.sh             # Static analysis (if installed)
bash sync.sh device list       # Read-only: prints registered devices
bash module-manager.sh list    # Read-only: prints tracked modules
```

Only run a real `bash sync.sh` when the user has explicitly asked to
sync.

## Pitfalls to Avoid

- `source`-ing a `.env` with unquoted (or double-quoted) values is unsafe — see `.env File Safety` above. Always single-quote, always via `shlex.quote()`.
- Under `set -e`, `((var++))` evaluates to falsy when `var` is 0 and exits the script — use `var=$((var + 1))`.
- Function definitions inside conditional blocks disappear when the branch is skipped (see Functions and Scope above).
- Writing files without `newline="\n"` on Windows produces CRLF and git phantom diffs.
- In multi-root setups, a repo directory's remote is not guaranteed to match the expected URL — verify `remote.origin.url` before pushing.
