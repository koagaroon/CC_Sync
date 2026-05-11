#!/usr/bin/env python
"""module_helper.py — CLI helper for module-manager.sh

Extracts all embedded Python code blocks from module-manager.sh into a single
dispatched CLI tool.  Called by module-manager.sh via:

    python lib/module_helper.py <subcommand> [args...]

All arguments are passed via sys.argv (no bash string interpolation).
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import tomllib
import urllib.request
from urllib.parse import quote, urlparse

# ── encoding safety (Windows defaults to GBK) ──────────────────────
# newline="\n" is load-bearing: bash callers that read multi-line stdout via
# `$(...)` + `read -r` (e.g. cmd_prune --all) preserve any embedded \r and
# fail downstream regex validation on every line except the last.
sys.stdout.reconfigure(encoding="utf-8", newline="\n")
sys.stderr.reconfigure(encoding="utf-8", newline="\n")

DEFAULT_REF = "main"
MODULE_TYPE = "skill"
_REPO_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$")


def _validate_repo(repo):
    """Reject repo strings that could manipulate the gh api URL (e.g. '../x/y')."""
    if not _REPO_RE.match(repo):
        raise ValueError(f"无效的仓库格式：{repo!r}")
    owner, name = repo.split("/", 1)
    if owner in (".", "..") or name in (".", ".."):
        raise ValueError(f"仓库名不能为 . 或 ..：{repo!r}")


def _read_json_stdin():
    """Read+parse JSON from stdin with a clean Chinese error on corruption."""
    try:
        return json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"错误：stdin JSON 解析失败 ({e})", file=sys.stderr)
        sys.exit(1)


def _safe_download(url, out, timeout=30, max_bytes=10 * 1024 * 1024):
    """Download file via gh api (authenticated) with timeout and size limit.
    Falls back to urllib if gh is unavailable. Both paths stream with a
    running byte count so an oversized response is aborted mid-read, not
    after fully buffering into memory."""
    # Try gh api first (authenticated, handles private repos)
    gh_cmd = os.environ.get("GH_CMD", "gh")
    # Extract owner/repo/ref/path from raw.githubusercontent.com URL
    # Format: https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{path}
    m = re.match(r"https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.*)", url)
    if m:
        repo = f"{m.group(1)}/{m.group(2)}"
        try:
            _validate_repo(repo)
        except ValueError:
            pass  # fall through to urllib fallback (SSRF guard catches it)
        else:
            ref, path = m.group(3), m.group(4)
            api_url = f"repos/{repo}/contents/{quote(path, safe='/')}?ref={quote(ref, safe='')}"
            try:
                # stderr=DEVNULL: we don't consume it, so piping it would risk blocking
                # gh once the pipe buffer fills (64 KB typical). Falls through to urllib
                # on nonzero exit anyway, so stderr content isn't actionable here.
                proc = subprocess.Popen(
                    [gh_cmd, "api", api_url, "--header", "Accept: application/vnd.github.raw+json"],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                )
                # Watchdog: proc.stdout.read blocks indefinitely if gh stalls mid-stream
                # (network hang). proc.wait(timeout=…) only fires after read returns,
                # so we need an independent timer to kill a stalled process.
                watchdog = threading.Timer(timeout, proc.kill)
                watchdog.daemon = True
                watchdog.start()
                try:
                    total = 0
                    with open(out, "wb") as f:
                        while True:
                            chunk = proc.stdout.read(8192)
                            if not chunk:
                                break
                            total += len(chunk)
                            if total > max_bytes:
                                proc.kill()
                                try:
                                    f.close()
                                    os.unlink(out)
                                except OSError:
                                    pass
                                raise ValueError(f"Download exceeds {max_bytes // (1024*1024)}MB limit")
                            f.write(chunk)
                    try:
                        proc.wait(timeout=timeout)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        raise
                    if proc.returncode == 0 and total > 0:
                        return
                    # gh failed; fall through to urllib
                finally:
                    watchdog.cancel()
                    if proc.poll() is None:
                        proc.kill()
            except FileNotFoundError:
                pass  # gh not installed, fall back to urllib

    # Fallback: direct urllib download (unauthenticated)
    # Only allow HTTPS from trusted GitHub domains (prevent SSRF via crafted API responses)
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.netloc.endswith(
        (".githubusercontent.com", ".github.com")
    ):
        raise ValueError(f"Untrusted download URL: {url}")
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        total = 0
        with open(out, "wb") as f:
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                total += len(chunk)
                if total > max_bytes:
                    try:
                        f.close()
                        os.unlink(out)
                    except OSError:
                        pass
                    raise ValueError(f"Download exceeds {max_bytes // (1024*1024)}MB limit")
                f.write(chunk)


# ── TOML helpers ────────────────────────────────────────────────────

def _toml_escape(s):
    """Escape a string for TOML double-quoted values.
    Handles \\ " and all ASCII control chars (TOML 1.0 forbids raw \\x00-\\x1f)."""
    s = str(s)
    s = s.replace("\\", "\\\\")
    s = s.replace('"', '\\"')
    out = []
    for ch in s:
        code = ord(ch)
        if ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif code < 0x20 or code == 0x7F:
            out.append(f"\\u{code:04x}")
        elif 0xD800 <= code <= 0xDFFF:
            # Lone surrogates can't survive UTF-8 encoding on write — replace
            # rather than crash the atomic write with UnicodeEncodeError.
            out.append("\\uFFFD")
        else:
            out.append(ch)
    return "".join(out)


# ── Shared: fetch latest SHAs from GitHub ───────────────────────────

def _fetch_latest_shas(modules, target, gh):
    """Filter by target -> group by repo@ref -> gh API query -> compare SHAs.

    Returns (updates, up_to_date, errors):
      updates:    [(name, stored_sha, latest_sha, mod_dict), ...]
      up_to_date: [name, ...]
      errors:     [(name, error_msg), ...]

    Returns (None, None, None) when *target* is not '--all' and the name
    is missing from *modules* (caller should treat as "not found").
    """
    if target != "--all":
        if target not in modules:
            return None, None, None  # signal "not found"
        modules = {target: modules[target]}

    # Group by (repo, ref, path) tuple for path-specific SHA queries
    repos = {}
    for name, mod in modules.items():
        src = mod.get("source", {})
        repo = src.get("repo", "")
        ref = src.get("ref", DEFAULT_REF)
        kind = src.get("kind", "")
        # Only use path for github-subdir modules (github-repo may have stale path values)
        path = src.get("path", "") if kind == "github-subdir" else ""
        if repo:
            key = (repo, ref, path)
            repos.setdefault(key, []).append((name, mod))

    updates, up_to_date, errors = [], [], []

    for (repo, ref, path), mods in repos.items():
        try:
            # Re-validate repo at use-site — modules.toml is user-controlled but could
            # also be corrupted, and '../x/y' in repo would retarget the gh api URL.
            try:
                _validate_repo(repo)
            except ValueError as ve:
                for name, _ in mods:
                    errors.append((name, str(ve)))
                continue
            if path:
                # Path-specific query: latest commit touching this subdirectory
                cmd = [gh, "api",
                       f"repos/{repo}/commits?sha={quote(ref, safe='')}&path={quote(path, safe='/')}&per_page=1",
                       "-q", ".[0].sha"]
            else:
                # Whole-repo query (github-repo kind or no path)
                cmd = [gh, "api",
                       f"repos/{repo}/commits/{quote(ref, safe='')}", "-q", ".sha"]
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                encoding="utf-8",
                timeout=15,
            )
            if result.returncode != 0:
                for name, _ in mods:
                    errors.append((name, result.stderr.strip()))
                continue
            latest = result.stdout.strip()
            # Validate SHA format (must be 40-char hex; reject null/empty/error)
            if not re.fullmatch(r"[0-9a-f]{40}", latest):
                for name, _ in mods:
                    errors.append((name, f"Invalid SHA from API: {latest!r}"))
                continue
            for name, mod in mods:
                stored = mod.get("commit_sha", "")
                if stored != latest:
                    updates.append((name, stored, latest, mod))
                else:
                    up_to_date.append(name)
        except Exception as e:
            for name, _ in mods:
                errors.append((name, str(e)))

    return updates, up_to_date, errors


# ── Subcommands ─────────────────────────────────────────────────────

def cmd_manifest_read():
    """Read TOML manifest -> JSON to stdout."""
    manifest = sys.argv[2]
    try:
        with open(manifest, "rb") as f:
            data = tomllib.load(f)
        json.dump(data, sys.stdout, ensure_ascii=False)
    except FileNotFoundError:
        json.dump({"version": 1, "modules": {}}, sys.stdout)
    except Exception as e:
        print(f"错误：读取 manifest 失败 ({e})", file=sys.stderr)
        sys.exit(1)


def cmd_manifest_write():
    """Read JSON from stdin -> write TOML to file."""
    manifest = sys.argv[2]
    data = _read_json_stdin()
    lines = [
        "# Module Manager manifest — auto-generated",
        f'version = {data.get("version", 1)}',
        "",
    ]

    for name in sorted(data.get("modules", {})):
        mod = data["modules"][name]
        escaped_name = _toml_escape(name)
        lines.append(f'[modules."{escaped_name}"]')
        for key in ["type", "install_path", "commit_sha", "installed_at", "last_updated"]:
            val = mod.get(key, "")
            if val:
                lines.append(f'{key} = "{_toml_escape(val)}"')
        lines.append("")
        src = mod.get("source", {})
        if src:
            lines.append(f'[modules."{escaped_name}".source]')
            for key in ["kind", "repo", "path", "ref", "url"]:
                val = src.get(key, "")
                if val:
                    lines.append(f'{key} = "{_toml_escape(val)}"')
            lines.append("")

    dirname = os.path.dirname(manifest) or "."
    os.makedirs(dirname, exist_ok=True)
    # Atomic write: write to temp file, then replace (prevents truncation on crash)
    fd, tmp_path = tempfile.mkstemp(dir=dirname, suffix=".toml.tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines))
        os.replace(tmp_path, manifest)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def cmd_tab_vars():
    """Output module fields separated by ASCII US (\\x1f, Unit Separator) in fixed order.
    Reads JSON from stdin (piped from bash via: echo "$json" | py_helper tab-vars).
    Fields: name, kind, repo, path, ref, install_path, latest_sha

    The delimiter is \\x1f (Unit Separator), not \\t. Bash treats whitespace
    delimiters specially in `IFS`: runs of whitespace collapse into a single
    separator and empty fields between them are dropped. With \\t, a record
    like `name\\tgithub-repo\\towner/repo\\t\\tmain\\tname\\tsha` (path field
    intentionally empty for github-repo modules) re-binds to
    path=main, ref=name, install_path=sha — silently corrupting updates.
    \\x1f is non-whitespace, so consecutive delimiters preserve empty fields.
    The dispatch key stays `tab-vars` for backwards compatibility with any
    out-of-tree caller, but the on-wire format is US-separated."""
    try:
        obj = json.loads(sys.stdin.readline())
    except json.JSONDecodeError as e:
        print(f"错误：tab-vars 输入 JSON 解析失败 ({e})", file=sys.stderr)
        sys.exit(1)
    fields = ["name", "kind", "repo", "path", "ref", "install_path", "latest_sha"]
    print("\x1f".join(str(obj.get(f, "")) for f in fields))


def cmd_module_exists():
    """Check whether a module name exists in manifest JSON (stdin). Prints 'yes'/'no'."""
    data = _read_json_stdin()
    name = sys.argv[2]
    print("yes" if name in data.get("modules", {}) else "no")


def cmd_manifest_add_module():
    """Add/overwrite a module entry. Reads JSON from stdin, prints updated JSON."""
    if len(sys.argv) < 9:
        print("错误：manifest-add-module 参数不足（需要 name sha today kind repo path ref）", file=sys.stderr)
        sys.exit(1)
    name, sha, today = sys.argv[2], sys.argv[3], sys.argv[4]
    kind, repo, path, ref = sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8]
    data = _read_json_stdin()
    source = {"kind": kind, "ref": ref}
    if repo:
        source["repo"] = repo
    if path:
        source["path"] = path
    data.setdefault("modules", {})[name] = {
        "type": MODULE_TYPE,
        "install_path": name,
        "commit_sha": sha,
        "installed_at": today,
        "last_updated": today,
        "source": source,
    }
    json.dump(data, sys.stdout, ensure_ascii=False)


def cmd_download_github_subdir():
    """Recursively download a subdirectory from GitHub via API."""
    gh = sys.argv[2]
    repo = sys.argv[3]
    subpath = sys.argv[4]
    ref = sys.argv[5]
    dest = sys.argv[6]

    def download_dir(repo, path, ref, dest):
        os.makedirs(dest, exist_ok=True)
        result = subprocess.run(
            [gh, "api", f"repos/{repo}/contents/{quote(path, safe='/')}?ref={quote(ref, safe='')}", "-q", "."],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=30,
        )
        if result.returncode != 0:
            print(f"  {path} 的 API 调用失败：{result.stderr.strip()}", file=sys.stderr)
            return False

        items = json.loads(result.stdout)
        if isinstance(items, dict):
            items = [items]

        ok = True
        resolved_dest = os.path.realpath(dest)
        for item in items:
            # Defensive: GitHub API could return malformed entries (schema drift,
            # partial truncation, forked API). .get() + skip-on-missing instead of
            # raw subscript that KeyErrors and aborts the entire download batch.
            raw_name = item.get("name") if isinstance(item, dict) else None
            item_type = item.get("type") if isinstance(item, dict) else None
            if not raw_name or not item_type:
                print(f"  跳过（条目残缺，缺少 name/type）：{item!r}", file=sys.stderr)
                continue
            # Sanitize filename to prevent path traversal from API responses.
            # os.path.basename is cross-platform: on POSIX it strips up to last "/",
            # on Windows (ntpath) it strips up to last "\" OR "/" — both are safe
            # against "foo/bar" or "..\\x" style injection. The (".", "..") guard
            # covers the remaining dot-entries that basename alone lets through.
            name = os.path.basename(raw_name)
            if not name or name in (".", ".."):
                continue
            target = os.path.realpath(os.path.join(dest, name))
            if not target.startswith(resolved_dest + os.sep):
                print(f"  跳过（检测到路径穿越）：{raw_name}", file=sys.stderr)
                continue
            if item_type == "dir":
                if not download_dir(repo, item.get("path", ""), ref, os.path.join(dest, name)):
                    ok = False
            elif item_type == "file":
                url = item.get("download_url", "")
                if not url:
                    continue
                out = os.path.join(dest, name)
                try:
                    _safe_download(url, out)
                except Exception as e:
                    print(f"  下载失败：{name} ({e})", file=sys.stderr)
                    ok = False
        return ok

    sys.exit(0 if download_dir(repo, subpath, ref, dest) else 1)


def _format_source_str(src):
    """Format a module source dict into a display string."""
    kind = src.get("kind", "?")
    if kind == "github-subdir":
        return f'{src.get("repo", "")}:{src.get("path", "")}'
    elif kind == "github-repo":
        return src.get("repo", "")
    return src.get("url", "")[:40]


def _list_unmanaged(modules, skills_dir):
    """Return sorted list of subdirs of skills_dir that aren't tracked in modules."""
    tracked_paths = {mod.get("install_path", name) for name, mod in modules.items()}
    if not os.path.isdir(skills_dir):
        return []
    return [
        d for d in sorted(os.listdir(skills_dir))
        if os.path.isdir(os.path.join(skills_dir, d))
        and d not in tracked_paths
        and not d.startswith(".")
    ]


def cmd_list():
    """Print formatted table of tracked modules + detect unmanaged dirs."""
    data = json.loads(sys.argv[2])
    modules = data.get("modules", {})
    skills_dir = sys.argv[3]

    # List tracked modules
    if modules:
        print(f"Tracked modules ({len(modules)}):")
        print(f'  {"Name":<25} {"Type":<8} {"Source":<35} {"Updated"}')
        print(f'  {"-"*25} {"-"*8} {"-"*35} {"-"*10}')
        for name in sorted(modules):
            mod = modules[name]
            src = mod.get("source", {})
            source_str = _format_source_str(src)[:35]
            updated = mod.get("last_updated", "?")
            mtype = mod.get("type", "?")
            print(f"  {name:<25} {mtype:<8} {source_str:<35} {updated}")
        print()
    else:
        print("No tracked modules.")
        print()

    # Detect unmanaged directories
    unmanaged = _list_unmanaged(modules, skills_dir)

    if unmanaged:
        print(f"Unmanaged directories ({len(unmanaged)}):")
        for d in unmanaged:
            print(f"  {d}/")
        print()
        print('Use "adopt" to track them, or they will be ignored.')


def _prepare_check():
    """Shared init for check / update-check subcommands."""
    data = json.loads(sys.argv[2])
    target = sys.argv[3]
    modules = data.get("modules", {})
    gh = os.environ.get("GH_CMD", "gh")
    return data, target, modules, gh


def cmd_check():
    """Check for upstream updates.  Exit codes: 0=up-to-date, 1=errors, 10=updates."""
    data, target, modules, gh = _prepare_check()

    if not modules:
        print("No modules tracked.")
        sys.exit(0)

    updates, up_to_date, errors = _fetch_latest_shas(modules, target, gh)

    if updates is None:
        # target not found
        print(f'manifest 中未找到模块 "{target}"。')
        sys.exit(1)

    if updates:
        print(f"Updates available ({len(updates)}):")
        for name, old, new, _mod in updates:
            print(f"  {name}: {old[:8]} -> {new[:8]}")
        print()

    if up_to_date:
        print(f"Up to date ({len(up_to_date)}):")
        for name in up_to_date:
            print(f"  {name}")
        print()

    if errors:
        print(f"Check failed ({len(errors)}):")
        for name, err in errors:
            print(f"  {name}: {err}")
        print()

    # Exit code: 10 = updates available, 0 = all up to date, 1 = errors
    if errors and not updates:
        sys.exit(1)
    elif updates:
        sys.exit(10)
    else:
        sys.exit(0)


def cmd_update_check():
    """Emit one JSON line per module needing update (for bash to consume)."""
    data, target, modules, gh = _prepare_check()

    if target != "--all":
        if target not in modules:
            sys.exit(1)
        modules = {target: modules[target]}

    updates, _up_to_date, errors = _fetch_latest_shas(modules, target, gh)

    if updates is None:
        sys.exit(1)

    # Print warnings for errors
    for name, err in errors:
        print(f"Warning: skipped {name}: {err}", file=sys.stderr)

    # Emit JSON lines for modules needing update
    for name, _stored, latest, mod in updates:
        src = mod.get("source", {})
        print(
            json.dumps(
                {
                    "name": name,
                    "latest_sha": latest,
                    "kind": src.get("kind", ""),
                    "repo": src.get("repo", ""),
                    "path": src.get("path", ""),
                    "ref": src.get("ref", DEFAULT_REF),
                    "install_path": mod.get("install_path", name),
                }
            )
        )


def cmd_manifest_update_sha():
    """Update commit_sha and last_updated for a module. JSON stdin -> JSON stdout."""
    name, sha, today = sys.argv[2], sys.argv[3], sys.argv[4]
    data = _read_json_stdin()
    if name not in data.get("modules", {}):
        print(f"错误：manifest 中未找到模块 '{name}'", file=sys.stderr)
        sys.exit(1)
    data["modules"][name]["commit_sha"] = sha
    data["modules"][name]["last_updated"] = today
    json.dump(data, sys.stdout, ensure_ascii=False)


def cmd_module_get_path():
    """Print install_path for a module. JSON stdin."""
    data = _read_json_stdin()
    name = sys.argv[2]
    if name not in data.get("modules", {}):
        print(f"错误：manifest 中未找到模块 '{name}'", file=sys.stderr)
        sys.exit(1)
    print(data["modules"][name].get("install_path", name))


def cmd_manifest_delete_module():
    """Delete a module from manifest JSON. stdin -> stdout."""
    data = _read_json_stdin()
    name = sys.argv[2]
    if name not in data.get("modules", {}):
        print(f"错误：manifest 中未找到模块 '{name}'", file=sys.stderr)
        sys.exit(1)
    del data["modules"][name]
    json.dump(data, sys.stdout, ensure_ascii=False)


def cmd_list_untracked():
    """Print untracked directories in skills_dir, one per line.
    Args: argv[2] = manifest JSON string; argv[3] = skills_dir path.
    Output is the parsing contract for module-manager.sh's `prune` command.
    Names containing CR/LF are skipped: the bash consumer reads with
    `while IFS= read -r name`, which splits on \\n. A directory named
    e.g. `tracked-name\\nunrelated` would split into two candidates and
    the second could escape the tracked-paths check. Such names cannot
    round-trip through line-oriented IPC anyway."""
    data = json.loads(sys.argv[2])
    modules = data.get("modules", {})
    skills_dir = sys.argv[3]
    for d in _list_unmanaged(modules, skills_dir):
        if "\n" in d or "\r" in d:
            print(f"warning: skipping unmanaged dir with CR/LF in name: {d!r}", file=sys.stderr)
            continue
        print(d)


def cmd_restore_count():
    """Print total number of modules in manifest. JSON stdin."""
    data = _read_json_stdin()
    print(len(data.get("modules", {})))


def cmd_restore_list_missing():
    """List modules missing locally. One JSON line per missing module. JSON stdin."""
    data = _read_json_stdin()
    skills_dir = sys.argv[2]

    for name, mod in data.get("modules", {}).items():
        install_path = mod.get("install_path", name)
        dest = os.path.join(skills_dir, install_path)
        if not os.path.isdir(dest):
            src = mod.get("source", {})
            print(
                json.dumps(
                    {
                        "name": name,
                        "kind": src.get("kind", ""),
                        "repo": src.get("repo", ""),
                        "path": src.get("path", ""),
                        "ref": src.get("ref", DEFAULT_REF),
                        "install_path": install_path,
                    }
                )
            )


# ── Dispatch table ──────────────────────────────────────────────────

COMMANDS = {
    "manifest-read": cmd_manifest_read,
    "manifest-write": cmd_manifest_write,
    "tab-vars": cmd_tab_vars,
    "module-exists": cmd_module_exists,
    "manifest-add-module": cmd_manifest_add_module,
    "download-github-subdir": cmd_download_github_subdir,
    "list": cmd_list,
    "check": cmd_check,
    "update-check": cmd_update_check,
    "manifest-update-sha": cmd_manifest_update_sha,
    "module-get-path": cmd_module_get_path,
    "manifest-delete-module": cmd_manifest_delete_module,
    "restore-count": cmd_restore_count,
    "restore-list-missing": cmd_restore_list_missing,
    "list-untracked": cmd_list_untracked,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(f"Usage: {sys.argv[0]} <subcommand> [args...]", file=sys.stderr)
        print(f"Subcommands: {', '.join(sorted(COMMANDS))}", file=sys.stderr)
        sys.exit(1)
    COMMANDS[sys.argv[1]]()


if __name__ == "__main__":
    main()
