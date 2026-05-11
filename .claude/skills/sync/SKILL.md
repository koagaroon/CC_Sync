---
name: sync
description: "Sync all claude-code-workspace repos (hybrid: script + Claude). Triggers: sync, pull all repos, push changes, commit and push, check repo status, update repositories. Also: 同步, pull 所有仓库, 推代码, 提交所有改动, 检查项目状态."
user_invocable: true
---

# Sync — Multi-Repo Sync (Hybrid Mode)

> This skill's output parsing logic is based on the current sync.sh version. If sync.sh output format changes, update this file accordingly.

## Not For

- Repos without the `claude-code-workspace` topic (those are intentionally excluded via topic filter or `.sync_ignore`)
- Public Claude-Code-tool repos like CC_Sync (managed via dedicated sessions, not sync.sh discovery)
- Non-git directories (sync.sh requires git repos)
- Cross-repo code changes — sync.sh is transport only, not refactoring

## Critical Rules

### Call AskUserQuestion for interactive decisions

When sync.sh output contains `===CONFLICT_BEGIN===` blocks, `===UNTRACKED_BEGIN===` blocks, or `NEW_REPO:` markers, call the AskUserQuestion tool with structured options rather than asking in free-form chat.

**WRONG** (never do this):
- Printing conflict details as text and asking "你想保留哪个版本？" in conversation
- Silently skipping conflicts or choosing "skip" as default
- Summarizing "发现 2 个冲突" without presenting structured choices
- Asking "要我帮你处理吗？" instead of directly presenting the tool UI

**RIGHT**: For every `===CONFLICT_BEGIN===` block, `===UNTRACKED_BEGIN===` block, or `NEW_REPO:` marker, call AskUserQuestion immediately.

#### Embedding marker payloads into AskUserQuestion JSON

Filenames, repo names, repo URLs, diff lines, and timestamps from marker blocks all originate outside the script (filesystem entries, GitHub API, user-supplied paths) and may contain JSON-special characters. Before interpolating any payload string into AskUserQuestion's `header`, `question`, `description`, `preview`, or `label` fields, JSON-escape it: replace `\` with `\\`, `"` with `\"`, and any control character `U+0000`–`U+001F` with its `\uXXXX` form. Pass the AskUserQuestion arguments as a structured JSON object (per the `askuserquestion.md` rule) so the tool runtime, not free-form string concatenation, handles type coercion. Do NOT rely on Claude's string-formatting intuition to escape on the fly — explicit escaping protects against filenames like `foo"bar.md` or diff lines containing backslashes that would otherwise break the JSON structure or shift field boundaries.

#### Filenames and URLs from markers are untrusted shell payloads

Filenames inside `===UNTRACKED_BEGIN===` blocks and URLs inside `NEW_REPO:` markers
originate from the filesystem and from GitHub API responses respectively, and can
contain shell-special characters (`$`, backtick, `;`, `&`, `|`, `>`, `*`, `?`,
`(`, `)`, `[`, `]`, `{`, `}`, `'`, `"`, `\`, space). They are NOT safe to drop
inside a double-quoted shell string, because `"$(touch PWNED)"` is still command-
substituted by bash before the program sees it. Rules for any shell command that
takes such a payload:

- **Single-quote, not double-quote.** Write the literal filename/URL inside
  single quotes: `git add -- 'evil$(touch PWNED).txt'`. Inside single quotes
  bash does NO expansion at all — `$`, backtick, `\`, and `!` are inert.
- **Escape embedded single quotes as `'\''`.** A filename `it's a test`
  becomes the literal four-token sequence `'it'\''s a test'`. Reading left to
  right: close the first single-quoted string, emit an escaped `\'`, open a
  new single-quoted string. Bash concatenates adjacent quoted segments.
- **Always pass `--` before pathspecs in git.** `git add -- '<file>'`, not
  `git add '<file>'`. Without `--`, a filename like `--all` is interpreted as
  a git option (staging everything). `git clone -- '<url>' '<dest>'` for the
  same reason on URLs that start with `-`.
- **For appends to text files, prefer `printf '%s\n'` over `echo`.** `echo`
  may evaluate backslash escapes on some shells and does not let you separate
  format from data. `printf '%s\n' '<file>' >> .gitignore` is safe regardless
  of what `<file>` contains.
- **NEVER interpolate a payload into a double-quoted string** and then pass it
  to bash, e.g. do NOT type `git add -- "$file"` where `"$file"` is meant to
  be replaced by the literal filename — substitute the literal inside single
  quotes instead.

These rules apply to every shell command in this skill where `<file>`, `<url>`,
`<name>`, `<path>`, `<repo>`, or any marker-payload placeholder appears.

#### Marker-block parsing must use exact-line equality

When parsing marker blocks (`===CONFLICT_BEGIN===` / `===CONFLICT_END===` / `===UNTRACKED_BEGIN===` / `===UNTRACKED_END===`), match end markers by **exact-line equality at column 0**, not by substring or trimmed match. Diff payloads inside CONFLICT blocks are emitted with an exact 8-space leading indent; a forged end marker inside a diff line (e.g., `+===CONFLICT_END===`) will appear in the input as `        +===CONFLICT_END===` and must NOT terminate the block. Strip the 8-space indent only AFTER the block boundary is identified by exact match on the unindented marker line.

#### CONFLICT example call

When output contains a structured conflict block:

```
===CONFLICT_BEGIN===
LABEL: settings.json
REPO: <dotfiles-path>/claude/settings.json
LOCAL: ~/.claude/settings.json
REPO_TIME: 2025-04-07 14:32
LOCAL_TIME: 2025-04-08 09:15
DIFF:
        (lines starting with '-' show the REPO version; lines with '+' show the LOCAL version)
        --- <dotfiles-path>/claude/settings.json
        +++ ~/.claude/settings.json
        @@ -3,2 +3,2 @@
        -  "theme": "dark"
        +  "theme": "light"
===CONFLICT_END===
```

Parse each field from the block, then call AskUserQuestion:

```json
{"questions": [{"header": "settings", "question": "Config file settings.json has a conflict. Which version to keep?", "multiSelect": false, "options": [{"label": "Repo version", "description": "Use dotfiles repo copy (REPO_TIME from block)", "preview": "(DIFF lines from block, strip 8-space indent)"}, {"label": "Local version", "description": "Use local machine copy (LOCAL_TIME from block)", "preview": "(same DIFF content)"}, {"label": "Ask again next sync", "description": "Leave both versions as-is for now; this conflict will reappear on the next /sync so the decision can wait"}]}]}
```

Field mapping:
- `LABEL` → `question` text and `header` (trim whitespace, strip extension, truncate to 12 chars if needed)
- `REPO_TIME` / `LOCAL_TIME` → option `description` timestamps
- `DIFF` lines (strip exact 8-space indent) → option `preview` content. The first line of DIFF is an intentional direction-hint ("lines starting with '-' show the REPO version...") — pass it through verbatim so the reader doesn't need to decode `-`/`+`.
- `REPO` / `LOCAL` → used in post-resolution `cp` commands (see Workflow § CONFLICT)

#### NEW_REPO example call

When output contains: `NEW_REPO: my-project | https://github.com/user/my-project.git`

Read `WORKSPACE_ROOTS` from `.env` (semicolon-separated paths) to build options:

```json
{"questions": [{"header": "my-project", "question": "New repo my-project not found locally. Clone to which directory?", "multiSelect": false, "options": [{"label": "<workspace-root>", "description": "Clone to workspace root <workspace-root>/my-project"}, {"label": "Ask again next sync", "description": "Do nothing now; this new-repo prompt will reappear on the next /sync"}, {"label": "Ignore permanently", "description": "Add to .sync_ignore, never ask again"}]}]}
```

Adapt options count to actual WORKSPACE_ROOTS entries (max 4 options total including Skip/Ignore).

#### UNTRACKED example call

When a project repo has uncommitted changes, sync.sh does NOT call `git add -A` anymore — it emits an UNTRACKED block listing every untracked file so each one can be decided individually. Example:

```
===UNTRACKED_BEGIN===
REPO: my-project
REPO_PATH: /c/workspace/my-project
FILES:
        .tmp_review/round1.md
        docs/new_feature.md
===UNTRACKED_END===
```

Parse each FILE line (strip 8-space indent). Call AskUserQuestion with one question per file (max 4 per call; batch across repos if more files):

```json
{"questions": [{"header": "round1.md", "question": "my-project has untracked file .tmp_review/round1.md — include in commit?", "multiSelect": false, "options": [{"label": "Include", "description": "Add this file to the sync auto-commit"}, {"label": "Ask again next sync", "description": "Skip this run; file stays untracked, will reappear on next /sync"}, {"label": "Never ask again", "description": "Append exact path to .gitignore in a separate auto-commit (mechanical message: sync: auto-append .gitignore from <hostname>)"}]}]}
```

Use the file's basename as `header` (truncate to 12 chars if needed); full relative path in `question` text.

Field mapping:
- `REPO` → identifies the repo (matches its entry in the main summary)
- `REPO_PATH` → absolute path used as `cd` target for post-resolution commands
- Each `FILE` line (strip 8-space indent) → one AskUserQuestion question

After ALL UNTRACKED questions resolved (across all repos), `cd "$REPO_PATH"` for each repo (quote — paths may contain spaces), then:

0. **Capture `.gitignore`'s pre-existing dirty state BEFORE any appends** (the order matters: doing this after step 1 always reads "dirty" because step 1 just modified the file). Mirror sync.sh's two-stage check — `git diff --quiet HEAD` alone misses untracked-but-present `.gitignore` (a manually-created file never `git add`-ed) because git only diffs tracked changes:
   ```bash
   GITIGNORE_WAS_DIRTY=0
   if [ -f .gitignore ]; then
       if git ls-files --error-unmatch .gitignore >/dev/null 2>&1; then
           # tracked: HEAD comparison catches unstaged AND staged-but-not-committed
           git diff --quiet HEAD -- .gitignore 2>/dev/null || GITIGNORE_WAS_DIRTY=1
       else
           # untracked but present — treat as dirty so the auto-commit doesn't sweep user content
           GITIGNORE_WAS_DIRTY=1
       fi
   fi
   ```
1. Track a per-repo flag `NEVER_AGAIN=0`. Apply each file's choice (see Critical Rules § Filenames and URLs for the single-quote-with-`'\''`-escape pattern used below):
   - **Include**: `git add -- '<file>'`
   - **Ask again next sync**: no action (file stays untracked)
   - **Never ask again**: ensure `.gitignore` ends with a newline before appending, then append the exact path, then set `NEVER_AGAIN=1`:
     ```bash
     if [ -f .gitignore ] && [ -n "$(tail -c 1 .gitignore 2>/dev/null)" ]; then printf '\n' >> .gitignore; fi
     printf '%s\n' '<file>' >> .gitignore
     ```
     Before appending, check the filename for gitignore footguns — see Gotchas.
2. Stage tracked modifications (excluding `.gitignore`): `git add -u -- ':!.gitignore'`
3. If anything is staged (`git diff --cached --quiet` returns non-zero): commit with mechanical message `sync: auto commit from <hostname>` and push.
4. If `NEVER_AGAIN=1` for this repo, branch on the `GITIGNORE_WAS_DIRTY` value captured in step 0:
   - **Clean-before** (`GITIGNORE_WAS_DIRTY=0`): run `git add .gitignore && git commit -m "sync: auto-append .gitignore from <hostname>" && git push` as a separate second commit.
   - **Dirty-before** (`GITIGNORE_WAS_DIRTY≠0`): the never-again entries are already on disk from step 1; SKIP the auto-commit and warn the user to commit the combined diff manually, so pre-existing edits don't get misattributed to sync.

   **Do NOT** re-run `git diff --quiet HEAD -- .gitignore` here — at this point .gitignore has been modified by step 1 and the diff would always be non-zero, falsely flagging dirty-before. **Do NOT** use `git diff --quiet .gitignore` (without `HEAD`) — that compares worktree to index and misses staged-but-not-committed changes. **Do NOT** gate only on the dirty-check without the `NEVER_AGAIN` flag — that would fire the commit whenever the file is dirty (including purely user-made edits) and misattribute them.

If nothing is staged after step 2 and `NEVER_AGAIN=0` (user chose "Ask again" for everything and no tracked modifications existed), no commit is made — this is correct, not an error.

### Commit message rule

Script-automated commits use mechanical messages. Claude-intervened commits (conflict resolution, handoff) use descriptive Chinese messages.

## Workflow

### Step 0: Check .env Exists (First Run Only)

Before running sync.sh, check if `.env` exists in the project root:

```bash
test -f .env && echo "exists" || echo "missing"
```

**If .env is missing:**
- sync.sh in non-interactive mode (CC Bash tool) exits with an error
- Tell the user to run `bash sync.sh` in an **interactive terminal** (e.g., Git Bash) to complete setup
- The wizard guides through dotfiles path, repo sync toggle, etc.
- After setup, /sync works normally in CC
- First-run setup requires an interactive terminal; the CC Bash tool cannot drive the wizard

**If .env exists, proceed to Step 1.**

### Step 1: Run Sync Script

```bash
bash sync.sh
```

Handles: discover repos → sync dotfiles config → pull → commit (fixed message: `sync: auto commit from <hostname>`) → push.

### Step 2: Check Script Results

**If script succeeded (exit code 0):**
- Display everything after the `[4/6]` summary marker verbatim — do not reformat, wrap in code blocks, or build a new table
- If output contains the line `检测到未安装的插件：` (sync.sh emits this exact Chinese header before listing missing plugins; the install commands appear under a `运行以下命令安装：` header that follows), show the listed plugins and the install commands verbatim, and prompt the user to run them inside Claude Code
- If output contains **===CONFLICT_BEGIN===** blocks, enter conflict resolution flow (below)
- If output contains **===UNTRACKED_BEGIN===** blocks, enter untracked-file resolution flow (below) — these repos are PENDING user input, NOT complete
- If output contains **NEW_REPO:** markers, enter new repo handling flow (below)
- If a repo's status line is **`gitignore 条目已落盘待手动提交（.gitignore 预先有未提交修改）`** (in 待决定 group) or **`主提交已推送，gitignore 条目已落盘待手动提交`** (in 已同步 group), the `.gitignore` append landed on disk but was NOT committed (`.gitignore` had pre-existing uncommitted edits). Tell the user to manually commit + push for that repo: `cd <repo-path> && git add .gitignore && git commit -m "sync: auto-append .gitignore (manual)" && git push`. Do NOT treat /sync as complete on this signal alone — the gitignore state lives on disk locally and won't propagate to other devices until committed.
- If output contains **HANDOFF: Pending tasks detected**, proceed to Step 3
- Otherwise, task complete

**===CONFLICT_BEGIN=== blocks** → Follow Critical Rules § CONFLICT example. Call AskUserQuestion (max 4 questions per call; batch if more). Then execute (single-quote the literal paths from REPO/LOCAL fields, with `'\''` escape for embedded `'` — see Critical Rules § Filenames and URLs):
- Repo chosen: `cp -- '<LOCAL>' '<LOCAL>.bak'` then `cp -- '<REPO>' '<LOCAL>'`
- Local chosen: `cp -- '<REPO>' '<REPO>.bak'` then `cp -- '<LOCAL>' '<REPO>'`, then commit + push in dotfiles repo
- Ask again next sync: no action (the same conflict will reappear on the next /sync)
- Continue to HANDOFF and other steps after all resolved

**NEW_REPO: markers** → Follow Critical Rules § NEW_REPO example. Call AskUserQuestion. Then execute (single-quote, with `'\''` escape — see Critical Rules § Filenames and URLs):
- Path chosen: `git clone -- '<url>' '<path>/<name>'` — `--` blocks the leading-`-` URL/path from being parsed as a git option; single quotes block `$()` / backtick expansion in URLs and paths
- Ask again next sync: no action (the new-repo prompt reappears on the next /sync)
- Ignore permanently: ensure `.sync_ignore` ends with a newline before appending, then append the name:
  ```bash
  if [ -f .sync_ignore ] && [ -n "$(tail -c 1 .sync_ignore 2>/dev/null)" ]; then printf '\n' >> .sync_ignore; fi
  printf '%s\n' '<name>' >> .sync_ignore
  ```
  Without the trailing-newline guard, the new entry concatenates onto the previous last line and the on-read regex `^[A-Za-z0-9_.-]+$` silently drops the merged line — the ignore takes no effect. `printf '%s\n'` (single-quoted format) over `echo` keeps `<name>` literal even if it contains backslash escapes.

**===UNTRACKED_BEGIN=== blocks** → Follow Critical Rules § UNTRACKED example. Call AskUserQuestion per file (max 4 per call; batch across repos if more). Then `cd -- '<REPO_PATH>'` (single-quote the literal path; paths may contain spaces or shell-special characters — see Critical Rules § Filenames and URLs) for each repo, track a per-repo `NEVER_AGAIN=0` flag, and per-file:
- Include: `git add -- '<file>'`
- Ask again next sync: no action
- Never ask again: ensure trailing newline on `.gitignore`, append exact path (see Critical Rules § UNTRACKED for the exact snippet), set `NEVER_AGAIN=1` for this repo

Per repo: BEFORE any `.gitignore` writes, capture pre-existing dirty state with the two-stage check from Critical Rules § UNTRACKED step 0 (the `git ls-files --error-unmatch` + `git diff --quiet HEAD` combination, NOT a single `git diff` — that misses untracked `.gitignore`). Then run the per-file actions, then `git add -u -- ':!.gitignore'`, then commit + push with mechanical message `sync: auto commit from <hostname>` if anything staged. If the per-repo `NEVER_AGAIN=1`, branch on `$GITIGNORE_WAS_DIRTY`: `0` (clean-before) → separate second commit `git add .gitignore && git commit -m "sync: auto-append .gitignore from <hostname>" && git push`; non-zero (dirty-before) → skip the auto-commit and warn the user to commit manually. Do NOT re-run `git diff` after step 1's appends — see Critical Rules § UNTRACKED step 4 for why.

**If script partially failed (exit code 1):**
- Display `[4/6]` summary verbatim first, then explain failures
- Handle each failed repo:
  - **pull failed (merge conflict)**: Read conflicts, analyze both sides, explain and suggest resolution. Commit with descriptive Chinese message, push
  - **commit failed**: Diagnose, fix, recommit with descriptive Chinese message, push
  - **push failed**: `pull --rebase` then push. If rebase conflicts, follow merge flow
  - **clone failed**: Check network/permissions, report to user

**Commit messages**: See Critical Rules § Commit message rule.

### Step 3: Handle Handoff Tasks (Only When Detected)

1. Verify `.machine-name` exists and matches a HANDOFF.md section. If missing, skip and prompt device registration
2. Read `HANDOFF.md` — find tasks in device section and `## ANY` section
3. Report all pending tasks to user
4. Execute each:
   - Shell commands: run directly
   - User-action steps: prompt user
   - On failure: explain rather than skip silently
5. After completion: replace device section with `(none)`. `## ANY`: only clear if ALL tasks done; keep tasks for other devices
6. Commit and push (e.g., `HANDOFF: <device> tasks completed, cleared`)

## Configuration

- **GitHub username**: `gh api user` (auto-detected)
- **Workspace root**: Auto-detected (parent directory of this repo)
- **Topic tag**: `claude-code-workspace`
- **Sync script**: `sync.sh` in project root

## Adding New Repos

```bash
gh repo edit <username>/<repo> --add-topic claude-code-workspace
```

Username via `gh api user -q .login`. Next /sync auto-discovers.

## Gotchas

- **CRLF phantom diffs**: Windows pull/rebase may produce false diffs. Verify with `git diff --stat` before treating as real conflicts.
- **gh CLI ignores Windows system proxy**: gh honors `HTTP_PROXY`/`HTTPS_PROXY` env vars but ignores the Windows system-wide (WinHTTP) proxy setting — in restricted networks, set the env vars explicitly in the shell where sync runs.
- **Output format dependency**: Step 2 relies on `[4/6]` marker. Update this file if sync.sh format changes.
- **Handoff trigger**: Step 3 triggered by `HANDOFF: Pending tasks detected`. Device checks done by sync.sh step [5/6].
- **Plugin detection**: After syncing settings.json, script compares `enabledPlugins` vs `installed_plugins.json`. Claude cannot run `claude plugin` from bash — prompt user.
- **UNTRACKED marker deferral**: When `===UNTRACKED_BEGIN===` blocks appear in the output, sync.sh has NOT committed or pushed that repo — it's waiting for SKILL.md to resolve via AskUserQuestion and execute the commit. The repo's summary line will read `未跟踪文件待决定` and appear under the yellow "待决定" group; this is pending user input, not an error. Complete the UNTRACKED flow before treating /sync as done.
- **gitignore dirty-before partial commit**: When a repo's pre-existing `.gitignore` had uncommitted modifications at sync start AND the user picked "Never ask again" for some untracked file, sync.sh appends the never-again entries to `.gitignore` on disk but skips the auto-commit (committing would misattribute the user's pre-existing edits to the mechanical `sync: auto-append` message). Two status strings surface this state: `主提交已推送，gitignore 条目已落盘待手动提交` (in 已同步 group when there were also tracked changes that DID commit) and `gitignore 条目已落盘待手动提交（.gitignore 预先有未提交修改）` (in 待决定 group when only `.gitignore` was touched). The fix is the same in both cases: tell the user to inspect their `.gitignore` diff, then `git add .gitignore && git commit -m "sync: auto-append .gitignore (manual)" && git push` for that repo (matching the message used in Step 2). The state will not self-resolve on the next /sync — the dirty-before check fires every time.
- **Marker payload indent is an interface contract**: CONFLICT's DIFF content (including the direction-hint line), UNTRACKED's FILES list, and any other future indented payload all use exact 8-space leading indent. Parsers strip exactly 8 spaces per line. Changing the indent width in sync.sh is a breaking change — update both sides in one commit.
- **.gitignore append footguns**: When executing "Never ask again", the filename is written verbatim to `.gitignore`. Filenames starting with `!` act as gitignore NEGATION rules (matching a prior ignore pattern) — if the user really wants such a file ignored, prefix the line with `\`. Filenames starting with `#` are interpreted as gitignore COMMENTS — the rule silently fails to match anything; prefix with `\` (e.g., `\#backup`) if the user truly wants this file ignored. Filenames with trailing whitespace won't self-match (gitignore treats trailing whitespace as significant unless escaped) — warn or reject. Filenames containing newlines are unwritable safely — reject. Surface these to the user before append.
- **Ctrl+C during sync atomicity**: If the user interrupts sync.sh between `git add` and `git commit`, the repo is left with staged changes and no commit. The next /sync will re-surface the same untracked files, and `git add`-ed files will appear as tracked modifications. There is also a second vulnerable window in the two-commit path: between the first commit (`sync: auto commit from <host>`) and the optional second commit (`sync: auto-append .gitignore ...`). Interrupting there leaves `.gitignore` with orphaned unstaged modifications that the next sync's `git add .gitignore` would sweep into a later commit. Recovery is manual (`git reset HEAD` to unstage, `git checkout .gitignore` to discard). Bash scripts can't atomically wrap these operations; document but don't attempt auto-rollback.
- **No "un-never-again" affordance**: Once a file is appended to `.gitignore` via the Never-ask-again option, sync has no command to reverse it. To re-include the file, the user must manually delete the line from `.gitignore` and run /sync again.
- **Legacy .env auto-migration**: `sync.sh` runs `_migrate_legacy_env` before `source .env` (startup). It detects legacy `KEY="value"` / unquoted lines, rewrites them with `shlex.quote` via atomic `mkstemp + os.replace`, and logs migrated keys to stderr. Extra warnings fire when a value contains `$` or backtick (previously expanded by `source`, now literal) or contains multiple whitespace-separated tokens (original line kept; needs manual quoting). If a user relied on shell expansion intentionally, they must restore the expansion manually after seeing the warning.

## Experience Log

Before execution, check `references/experience.md` if it exists.

After completion, if a non-obvious solution was found, append to `references/experience.md`:

```
### [Short Title]  (YYYY-MM-DD)
[1-2 sentences: what happened, how resolved, how to avoid next time]
```

Experience is hints, not facts — update or delete if following one fails.
