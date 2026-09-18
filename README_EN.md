[中文](./README.md)

# CC_Sync

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE) [![GitHub release](https://img.shields.io/github/v/release/koagaroon/CC_Sync)](https://github.com/koagaroon/CC_Sync/releases) ![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-blue)

**Keep Claude Code projects, configuration, and pending tasks in sync across computers.** CC_Sync combines Bash scripts, Python helpers, and Claude Code skills to coordinate Git repositories, carry tasks between devices, and install approved versions of third-party skills.

[Quick start](#quick-start) · [Daily use](#daily-use-in-claude-code) · [CLI reference](#cli-reference-advanced) · [Project structure](#project-structure) · [License](#license)

## How It Fits Together

| What you keep in sync | Where it lives | What CC_Sync does |
| --- | --- | --- |
| Project code | Your selected GitHub repositories | Discovers repositories by topic, then pulls, commits tracked edits, and pushes |
| Claude Code configuration | A separate **private dotfiles repository** | Syncs settings and skills, records file state, and surfaces conflicts or deletions |
| Device names and pending tasks | `HANDOFF.md` in **your private CC_Sync working repository** | Records tasks for another device; the `/sync` skill asks how to handle them |

This public repository distributes the tool. Use your own private working copy for device registration and task handoff, as shown below. Bash and Python handle files and Git operations; the Claude Code skills guide decisions about conflicts, imports, and tasks.

## Features

- **Batch repo sync** — Auto-discover GitHub repos by topic, one-command pull/commit/push
- **Cross-device config sync** — settings.json, skills, hooks, keybindings via dotfiles repo
- **Cross-device task handoff** — Relay pending tasks between machines via HANDOFF.md
- **Third-party module management** — Install/update/remove/restore skills from GitHub
- **First-run wizard** — Interactive .env setup, beginner-friendly
- **Multi-workspace support** — Repos spread across different directories? No problem
- **Deletion anti-resurrection** — A local ledger tracks each config file's sync history, so a config deleted on one device won't be quietly pushed back by another
- **Version-pinned modules** — Module updates follow a "check → approve → install" flow; you review changes before upgrading, nothing auto-follows upstream
- **Guided decisions** — The skills ask about sensitive config imports, cross-device tasks, and new skills; normal full sync automatically commits and pushes tracked project edits

## Prerequisites

### 1. Git and Bash 4+

The scripts require **Bash 4 or later**. On Windows, run them in **Git Bash** supplied by Git for Windows. On macOS, install a current Bash with Homebrew and ensure `bash --version` selects it.

- **Windows**: Open **PowerShell** and run:
  ```powershell
  winget install --id Git.Git -e
  ```
- **macOS**: Open **Terminal** and run: `brew install git bash`
- **Linux (Debian/Ubuntu)**: Open **Terminal** and run: `sudo apt install git bash`

### 2. Python 3.11+

The Python helpers use the standard-library [`tomllib`](https://docs.python.org/3/library/tomllib.html) module, which requires Python 3.11 or later. The scripts invoke **`python`**, so that command must work inside the Bash shell used to run CC_Sync.

- **Windows**: Continue in **PowerShell**:
  ```powershell
  winget install --id Python.Python.3.13 -e
  ```
  Restart your terminal, then run `python --version` in **Git Bash** and confirm the version is >= 3.11.
- **macOS**: Continue in **Terminal**: `brew install python`. Then expose Homebrew's Bash and [unversioned Python executables](https://docs.brew.sh/Homebrew-and-Python) in the current terminal session:
  ```bash
  export PATH="$(brew --prefix)/bin:$(brew --prefix python)/libexec/bin:$PATH"
  ```
  Repeat this in new terminal sessions, or add it to your shell startup configuration if you want it to persist.
- **Linux (Debian/Ubuntu)**: Continue in **Terminal**: `sudo apt install python3 python-is-python3`. Confirm your distribution provides Python 3.11 or later.

Before continuing, run `bash --version` and `python --version` in the same shell you will use for CC_Sync. Having only a `python3` command is insufficient for the current scripts.

### 3. GitHub CLI (gh)

- **Windows**: Continue in **PowerShell**:
  ```powershell
  winget install --id GitHub.cli -e
  ```
- **macOS**: Continue in **Terminal**: `brew install gh`
- **Linux**: See [GitHub CLI docs](https://cli.github.com/)

After installing, continue in the same **PowerShell** (or **Terminal**) and run:

```bash
gh auth login
```

Follow prompts: GitHub.com > HTTPS > Login with a web browser, then authorize in your browser.

### 4. Claude Code

You need a working Claude Code CLI. See [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code) if not installed.

## Quick Start

### Step 1: Create Your Private Working Repository

Choose a parent folder for your projects, then open a terminal there (Windows: **Git Bash**; macOS/Linux: **Terminal** with Bash 4+ available). The following commands download the public source, create a **new private GitHub repository in your account**, and push the initial copy to it. Choose another repository name if `cc-sync-workspace` already exists.

```bash
git clone https://github.com/koagaroon/CC_Sync.git cc-sync-workspace
cd cc-sync-workspace
git remote rename origin upstream
gh repo create cc-sync-workspace --private --source . --remote origin
git push --set-upstream origin main
```

Your private repository is now `origin`; `upstream` remains the public source. Device registration and task handling commit and push `HANDOFF.md` in this working copy, so use a repository you own and keep it private. This is separate from the private dotfiles repository configured in step 3.

Keep the local folder name identical to the GitHub repository name: discovery looks for `<workspace-root>/<repo-name>`. If you choose a different name, use it consistently throughout these steps.

### Step 2: Tag Your GitHub Repos

Tag **your new private `cc-sync-workspace` repository** and each project repository you want to sync. Replace the placeholders before running:

```bash
gh repo edit "<your-username>/cc-sync-workspace" --add-topic claude-code-workspace
gh repo edit "<your-username>/<project-repo>" --add-topic claude-code-workspace
```

> Don't know your username? Continue in the same terminal: `gh api user -q .login`

### Step 3: Prepare the Private Dotfiles Repository

Sync expects the dotfiles repository to have an initial commit and a branch that tracks its remote. For a new setup, these commands create a second private repository with a README and clone it beside the working copy. Choose another name if `cc-dotfiles` already exists:

```bash
cd ..
gh repo create cc-dotfiles --private --add-readme --clone
cd cc-sync-workspace
```

If you already have a private dotfiles repository, clone that repository into a separate folder instead. Keep the clone's folder name the same as its GitHub repository name.

### Step 4: First-Time Setup

> **This step MUST run in an interactive terminal** (not inside Claude Code). Windows: open **Git Bash**. macOS/Linux: use **Terminal**.

Stay in the `cc-sync-workspace` directory from step 1. **Setup immediately continues into a full sync:** it syncs configuration and, if repository sync is enabled, pulls selected repositories, commits tracked edits, and pushes them. Use it when you intend to publish those changes. For a status-only check, inspect the relevant repository with `git status` instead.

```bash
bash sync.sh
```

The wizard asks:

**Q1: Dotfiles repo path** — Enter the full local path to the private dotfiles clone prepared in step 3. Use that existing clone so the first pull has a remote branch to track.

> Keep the dotfiles repository **private**. CC_Sync stops if GitHub reports it as public. If the visibility query fails, the script warns and continues; confirm the repository's visibility yourself before syncing personal configuration.

**Q2: Enable repo sync?** — Type `y` to enable. Then:
- **Repo directory**: The parent folders containing your repositories, including the `cc-sync-workspace` working copy from step 1. Separate multiple paths with `;`.
- **GitHub topic**: Press Enter for the default (`claude-code-workspace`)

After setup, the script runs a full sync immediately.

For task handoff between devices, keep repository sync enabled and include the private working repository in both the configured topic and workspace folders. That lets its `HANDOFF.md` updates arrive before the task check.

## Daily Use (In Claude Code)

After setup, use the bundled skills in **Claude Code** for guided operation, or the [CLI reference](#cli-reference-advanced) for direct terminal commands.

### Getting Started

1. Open **Claude Code**
2. Navigate to your private `cc-sync-workspace` directory (use `cd` if needed)

### Syncing

Say to Claude:

- "sync"
- "sync my configured repositories and Claude configuration"

Or type: `/sync`

These requests start a **full sync**, including commits and pushes of tracked project edits. Requests such as "check repo status" or "pull only" are separate operations; they should not invoke `/sync`.

Claude automatically:

- Shows sync summary (which repos succeeded, failed, or unchanged)
- Asks you to resolve config conflicts via multiple-choice (only metadata like timestamps and line counts is shown by default; pick "show full diff" to see the actual changes)
- Asks for your consent before first importing sensitive configs from dotfiles — `settings.json`, `keybindings.json`, `statusline.sh`, `CLAUDE.md` — since these control Claude's behavior
- Asks whether to import new skill directories that appear in dotfiles
- Asks what to do when a config file was deleted on another device — remove the local copy, keep it locally, or push it back (prevents deleted configs from "resurrecting")
- Asks about untracked new files in project repos one by one (no blanket commits)
- Offers clone options for newly discovered repos
- Confirms each cross-device task (HANDOFF) with you before handling it (see below)
- Analyzes and suggests fixes for merge conflicts

Review the sync summary and answer any decisions surfaced by the skill.

### Device Management

Say to Claude:

- "list devices"
- "register new device MyLaptop" (pick a unique name)
- "remove device OldPC"

### Module Management

Say to Claude:

- "list installed modules"
- "check for updates"
- "update all modules"
- "install the pdf skill from anthropics/skills"
- "remove module xxx"
- "adopt the xxx directory" (register an existing directory in the manifest)
- "clean up untracked directories"
- "restore all modules" (new device setup)

Module updates follow a three-step "check → approve → install" flow: "check for updates" lists new upstream commits per module (with GitHub compare links); only after you approve does Claude lock in the new version, then install exactly that approved version. Modules never auto-follow upstream — every upgrade assumes you've seen the changes first.

### Cross-Device Tasks (HANDOFF)

HANDOFF is CC_Sync's mechanism for relaying tasks between devices. When you need device B to do something, you can leave a message from device A.

**Prerequisite: Each device needs a unique registered name.** In **Claude Code**, say:

- "register new device HomeMac"
- "register new device OfficePC"

> Device names can be any English name, but must be unique. Pick something that lets you instantly recognize which machine it is, like `HomeMac`, `OfficePC`, `MyLaptop`.

**Leaving a task:** On device A, in **Claude Code**, say:

- "leave a task for OfficePC: copy the config file from xxx project"
- "leave a task for HomeMac: run pip install requests"
- "task for all devices: update gh CLI" (writes to the ANY section, all devices will see it)

**Receiving tasks:** When you run /sync on device B in **Claude Code**, Claude automatically:

1. Detects pending tasks
2. Reports what needs to be done
3. Asks you how to handle each one: run it / skip this time / mark done without running / refuse and quarantine (for suspicious content)
4. Clears resolved tasks and pushes

> Task content arrives as Git-synced text. The `/sync` skill instructs Claude to treat it as untrusted input, report suspicious hidden tasks, and request your decision before executing task instructions. Review the task and proposed action when prompted.

No need to manually edit any files — everything is done via natural language.

## CLI Reference (Advanced)

For direct terminal use (**Git Bash** or **Terminal**):

| Command | Description |
|---------|-------------|
| `bash sync.sh` | Full config/repo sync, including commits and pushes of tracked project edits |
| `bash sync.sh --show-diff` | Full sync (conflict prompts include the full diff; metadata only by default) |
| `bash sync.sh device list` | List devices |
| `bash sync.sh device add <name>` | Register device |
| `bash sync.sh device remove <name>` | Remove device |
| `bash sync.sh repo-sync enable` | Enable repo sync |
| `bash sync.sh repo-sync unignore <name>` | Restore ignored repo |
| `bash module-manager.sh list` | List modules |
| `bash module-manager.sh check --all` | Check updates |
| `bash module-manager.sh bump <name\|--all> [--to <sha>\|--latest]` | Approve a new version (records only, no download) |
| `bash module-manager.sh update --all` | Install approved versions |
| `bash module-manager.sh install <source>` | Install module |
| `bash module-manager.sh remove <name>` | Remove module |
| `bash module-manager.sh adopt <name> <source>` | Track an existing directory |
| `bash module-manager.sh adopt --bulk [--dry-run] <owner/repo>` | Bulk-adopt directories |
| `bash module-manager.sh prune [--all \| --confirm <name>...]` | Clean up untracked directories |
| `bash module-manager.sh restore` | Restore on new device |

> `module-manager.sh check` exit codes are informational: `0` = all up to date, `10` = updates available, `1` = query errors. When scripting, don't treat `10` as a failure.
>
> Two more subcommands exist — `sync.sh prune-apply` and `sync.sh skill-import` — mechanical executors invoked by the /sync skill after you confirm a decision. You normally never run them by hand.
>
> To verify the scripts themselves are intact, run `bash tests/bounce_simulation.sh` — it executes in an isolated test mode and never touches your real repos or config.

## Configuration

After first run, a `.env` file is created in the project root (gitignored):

| Field | Description | Example |
|-------|-------------|---------|
| `DOTFILES_PATH` | Dotfiles repo path (required) | `C:/dotfiles` |
| `ENABLE_REPO_SYNC` | Enable repo syncing | `true` or `false` |
| `WORKSPACE_ROOTS` | Repo directories (`;` separated) | `D:/Projects;E:/Work` |
| `TOPIC` | GitHub topic tag | `claude-code-workspace` |

The following machine-local state files are also generated in the project root at runtime. All are gitignored except `.sync_ignore`:

| File | Purpose |
|------|---------|
| `.machine-name` | This device's name (used by HANDOFF) |
| `.sync_state.json` | Sync-state ledger — records each config file's fingerprint at last sync, used to recognize deleted files and prevent "resurrection" |
| `.sync_ignore` | Permanently ignored repos (created on demand; you can commit it in your private working repository to share it across devices) |
| `.skill_import_ignore` | Skill directories you declined to import; never asked again |
| `.repo_sync_hint_count` | Internal hint counter |

Module management additionally maintains two files under `~/.claude/skills/`: `modules.toml` (the module manifest, synced via dotfiles, the basis for new-device restore) and `.check_state.json` (machine-local cache for update checks, 24-hour freshness, not synced).

## Project Structure

```
cc-sync-workspace/
├── sync.sh                  # Main script
├── module-manager.sh        # Module management
├── lib/
│   ├── common.sh            # Shared bash utilities
│   ├── handoff.py           # HANDOFF.md parser/writer
│   └── module_helper.py     # Module manager Python helper
├── tests/
│   └── bounce_simulation.sh # Self-check tests (isolated test mode, no real repos touched)
├── HANDOFF.md               # Cross-device task relay
├── CLAUDE.md                # Project instructions for Claude Code
├── .env                     # Local config (auto-generated, not committed)
├── .sync_state.json         # Sync-state ledger (auto-generated, not committed)
├── .sync_ignore             # Permanently ignored repos (created on demand)
└── .claude/
    ├── skills/              # Skill definitions (/sync, /module-manager)
    └── hooks/               # Session startup checks
```

## FAQ

### sync.sh says "please run in terminal"

`.env` doesn't exist. Run `bash sync.sh` once in an interactive terminal (**Git Bash** or **Terminal**) to complete setup. Claude Code's bash tool is non-interactive and cannot run the wizard.

### gh CLI connection timeout

Check your connection and `gh auth status` first. If your network requires a proxy that `gh` has not picked up, set its address in the current **Git Bash** or **Terminal** session. Replace the placeholder with your actual proxy URL:

```bash
export HTTPS_PROXY="<your-proxy-url>"
```

### git diff shows many changes but nothing actually changed

Line-ending changes between CRLF and LF can make unchanged text appear modified on Windows. Compare `git diff` with `git diff --ignore-space-at-eol`; inspect any remaining differences before committing or discarding changes.

### Why does the first sync ask me whether to import settings.json?

`settings.json`, `keybindings.json`, `statusline.sh`, and `CLAUDE.md` directly control Claude's behavior. Their first import from dotfiles to this machine (including a new device's first sync) requires your confirmation, so unfamiliar config never takes effect silently. All other config files sync automatically as usual.

### Why am I asked what to do with a config file that was deleted?

CC_Sync keeps a machine-local ledger (`.sync_state.json`) recording each config file's state at last sync. When a file was deleted on another device but a copy still exists here, it asks you: remove the local copy (follow the deletion), keep it locally (never ask again, never push back), or push it back to the repo (undo the deletion). This prevents "a config deleted on device A gets pushed back by device B."

### Can the dotfiles repo be public?

Keep it private: it holds personal configuration. CC_Sync stops when GitHub reports the dotfiles repository as public, but a failed visibility query only produces a warning. Confirm the visibility yourself if that warning appears. Also keep your CC_Sync working repository private because it stores device names and task text.

### Do repos cloned via SSH work too?

Yes. Remote URLs are normalized before comparison, so the SSH and HTTPS forms of the same repo are treated as identical.

### Setting up a new device

1. Install and verify the [prerequisites](#prerequisites), then sign in to the GitHub account that owns your private repositories.
2. In **Git Bash** on Windows, or **Terminal** on macOS/Linux, clone **the same private working repository created earlier** into a configured workspace folder: `gh repo clone "<your-username>/cc-sync-workspace"`.
3. Clone your **existing private dotfiles repository** into a separate folder with `gh repo clone "<your-username>/<dotfiles-repo>"`. Point the wizard to that local clone; entering a new empty path starts repository creation, not a clone of your existing configuration.
4. Enter the working copy with `cd cc-sync-workspace` and run `bash sync.sh`. Configure the cloned dotfiles path, enable repository sync, and include the folder containing this working copy. Setup performs a full sync.
5. Open **Claude Code** in `cc-sync-workspace`, register a unique device name, then use `/sync` for subsequent synchronization. Sensitive first imports and task handling follow the skill's confirmation flow.
6. Continue in **Claude Code**: say "restore all modules" (restores the exact versions pinned in the manifest)

## Author

VRPSPshinOvO

## License

[MIT License](./LICENSE)

CC_Sync is distributed under the MIT License. Git, Bash, Python, GitHub CLI, and Claude Code are installed separately and retain their own licenses or terms. Third-party skills installed by the module manager retain their upstream licenses; this project's MIT license does not relicense those modules.
