#!/usr/bin/env python
"""HANDOFF.md parser/modifier for cross-machine task handoff system.

Used two ways:
- CLI: `python lib/handoff.py <command> <file> [args...]` (called from sync.sh)
- Import: `from handoff import section_exists, ...` (called from preflight.py)
"""
import re
import sys


def _ensure_utf8():
    if hasattr(sys.stdout, "reconfigure") and sys.stdout.encoding \
            and sys.stdout.encoding.lower() not in ("utf-8", "utf8"):
        sys.stdout.reconfigure(encoding="utf-8")


# 模块级编码保护，防止 Windows cp936 环境下中文输出乱码（import 模式也生效）
_ensure_utf8()


# Unicode line-terminator chars beyond \n / \r that Python regex `^` / `$` in
# MULTILINE mode also recognize. A device name containing any of these would
# slip past a naive \n / \r-only guard and corrupt section-boundary parsing.
_LINE_TERMINATORS = re.compile(r"[\n\r\x0b\x0c\x1c-\x1e\x85  ]")


def _validate_section_name(name):
    """Reject device names that break section parsing or registry round-trip."""
    if not name:
        # `## ` (empty header) writes a degenerate boundary; an empty registry entry
        # also produces an alternation `(?:...|)` whose empty branch matches every `## `
        # prefix as zero-width, breaking section termination.
        raise ValueError("设备名不能为空")
    if _LINE_TERMINATORS.search(name):
        raise ValueError("设备名不能包含换行类字符（\\n / \\r / U+2028 等）")
    if "-->" in name or "<!--" in name:
        raise ValueError("设备名不能包含 '<!--' 或 '-->'（会破坏 registry 注释）")
    if "," in name:
        # ',' is the registry list separator; embedding it splits the name on round-trip
        # and the resulting fragments wouldn't match the actual `## Name,...` header.
        raise ValueError("设备名不能包含 ','（registry 用逗号分隔，会破坏解析）")
    if name != name.strip():
        # Leading/trailing whitespace would silently survive in the registry list
        # (after split-and-strip) but mismatch the on-disk `## <name>` line, breaking
        # downstream lookups that compare normalized name vs raw header text.
        raise ValueError("设备名不能以空格开头或结尾")


def _iter_top_level_lines(lines):
    """Yield (index, line) for each line OUTSIDE fenced code blocks.

    Tracks fence opener char AND length so a 3-backtick line cannot prematurely
    close a 4+-backtick fence (CommonMark §4.5). 4+ space-indented backtick lines
    are NOT fences (CommonMark §4.4) — handled in `_fence_marker`. A line with an
    info string (`"```python"`) is a valid opener but NOT a valid closer — also
    handled by `_fence_marker` returning has_info_string=True.

    Fence-marker lines themselves are never yielded (container markers, not
    content). Unclosed (orphan) fence behaves CommonMark-style: runs to EOF.
    """
    fence_open = None  # (char, length, has_info) when inside a fence, else None
    for i, line in enumerate(lines):
        marker = _fence_marker(line)
        if marker is not None:
            if fence_open is None:
                fence_open = marker
            elif (marker[0] == fence_open[0]
                  and marker[1] >= fence_open[1]
                  and not marker[2]):  # info-string lines cannot close
                fence_open = None
            continue
        if fence_open is None:
            yield i, line


def _iter_top_level_header_names(text):
    """Yield ## header names from top-level (outside fenced code blocks).

    Returns the captured name without trimming whitespace — `_validate_section_name`
    rejects leading/trailing whitespace, so a name harvested here is already either
    well-formed (passes validation) or malformed (caller drops via validator). Not
    stripping preserves round-trip: harvested name matches the on-disk `## <name>`
    line exactly so downstream comparisons (e.g., section_exists, registry round-trip)
    don't desync with reality.
    """
    for _, line in _iter_top_level_lines(text.split("\n")):
        m = re.match(r"^## (.+?)\s*$", line)
        if m:
            yield m.group(1)


def _extract_all_headers(text):
    """Return all valid top-level ## header names (fence-aware, validator-filtered).

    Fenced `## ` lines are skipped. Names failing `_validate_section_name` are
    silently dropped — a crafted HANDOFF.md from a compromised remote could
    otherwise inject names containing '<!--' / '-->' / ',' / line terminators
    that bypass the validator applied on the registry-comment path.
    """
    out = []
    for name in _iter_top_level_header_names(text):
        try:
            _validate_section_name(name)
        except ValueError:
            continue
        out.append(name)
    return out


def read_file(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write_file(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def read_registry(text):
    """Parse <!-- registry: name1, name2, ANY --> comment. Returns list or None.

    Returns None when:
      - the comment is absent, or
      - any entry fails _validate_section_name (a crafted HANDOFF.md from a
        compromised remote injecting line terminators or '<!--'/'-->' sequences).

    Returning None on any malformed entry forces the caller to fall back to
    _extract_all_headers, which scans actual headers in the file body. Without
    this, dropping just one entry would silently shrink the boundary set and
    cause adjacent section bodies to merge — exfiltrating one device's tasks
    into another's.
    """
    m = re.search(r"<!--\s*registry:\s*(.+?)\s*-->", text)
    if not m:
        return None
    names = []
    for raw in m.group(1).split(","):
        n = raw.strip()
        if not n:
            continue
        try:
            _validate_section_name(n)
        except ValueError:
            return None  # untrusted registry; fall back to header-scan path
        names.append(n)
    # ANY is always implicitly included
    if "ANY" not in names:
        names.append("ANY")
    return names


def write_registry(text, devices):
    """Insert or replace the registry comment line after '# Handoff'."""
    # Ensure ANY is included
    if "ANY" not in devices:
        devices = list(devices) + ["ANY"]
    registry_line = f"<!-- registry: {', '.join(devices)} -->"
    # Replace existing registry line
    new_text, count = re.subn(r"<!--\s*registry:\s*.+?\s*-->", registry_line, text)
    if count > 0:
        return new_text
    # Insert after "# Handoff\n" (first h1 header)
    new_text, count = re.subn(
        r"(# Handoff\s*\n)",
        lambda m: m.group(1) + registry_line + "\n",
        text, count=1
    )
    if count > 0:
        return new_text
    # Fallback: prepend
    return registry_line + "\n" + text


def _get_device_names(text):
    """Return device names: from registry if present, else from ## headers.

    For *boundary* detection in extract/remove operations, prefer
    `_get_boundary_headers(text)` instead — see that function's docstring for
    why registry-only is unsafe as a boundary set."""
    registry = read_registry(text)
    if registry is not None:
        return registry
    return _extract_all_headers(text)


def _get_boundary_headers(text):
    """Return the set of `## <Name>` strings that count as section boundaries
    for extract/remove operations.

    Boundaries = registered names ∪ observed top-level headers.

    Why union, not registry-only: a stale or tampered registry that omits a
    real on-disk `## RealDevice` section would, if treated as the sole
    boundary source, cause `extract_section_body` to read PAST that section
    and merge its content into the previous section's body. The previous
    section's body is injected into Claude's preflight banner, so a leaked
    `## RealDevice` body becomes a prompt-injection vector. `remove_section`
    has the symmetric data-loss case: removing one section can delete through
    an omitted real section to the next registered boundary.

    Why union, not on-disk-only: an unregistered top-level heading inside a
    task body (e.g. user types `## Notes` as a heading inside a bullet list)
    would be a false boundary and would truncate the section body.

    The union catches both: both signals contribute boundaries, so neither a
    registry omission nor a body heading can hide adjacent content. When the
    two signals disagree, we WARN to stderr — the AI / user sees the mismatch
    and can fix the file. Truncation (body heading false-positive) is
    recoverable: the user notices missing tasks and either removes the heading
    or registers it. Leakage into a Claude session is not — by the time the
    injection runs the trust boundary is already crossed.
    """
    registry = read_registry(text)
    on_disk = _extract_all_headers(text)
    on_disk_set = set(on_disk)
    if registry is None:
        return {f"## {n}" for n in on_disk}
    registry_set = set(registry)
    if registry_set != on_disk_set:
        on_disk_only = sorted(on_disk_set - registry_set)
        registry_only = sorted(registry_set - on_disk_set)
        msg_parts = []
        if on_disk_only:
            msg_parts.append(f"on-disk-only={on_disk_only}")
        if registry_only:
            msg_parts.append(f"registry-only={registry_only}")
        print(
            "warning: HANDOFF.md registry / top-level headers mismatch — "
            f"{'; '.join(msg_parts)}. Using union as boundaries (truncation > leakage).",
            file=sys.stderr,
        )
    return {f"## {n}" for n in registry_set | on_disk_set}


def section_exists(text, name):
    """Check if a ## section exists at top level (outside fenced code blocks).

    Fence awareness matches the rest of the header API; a `## name` line buried
    in a task body's code fence must not register as a real section, otherwise a
    crafted HANDOFF.md from a compromised remote could block legitimate device
    registration by reserving the name inside a fence.
    """
    pat = re.compile(rf"^## {re.escape(name)}\s*$")
    for _, line in _iter_top_level_lines(text.split("\n")):
        if pat.match(line):
            return True
    return False


def extract_section_body(text, name):
    """Extract the body content of a named section, fence-aware and union-bounded.

    Walks lines through `_iter_top_level_lines` (skips fenced code blocks) instead
    of running a `MULTILINE` regex against the raw text — otherwise a `## DeviceName`
    line buried in a task body's code fence would prematurely terminate the body
    extraction. Section boundaries come from `_get_boundary_headers` — the union
    of registered names and observed on-disk headers, which catches both
    body-heading false boundaries (`## Notes` inside a body, when registered) and
    registry-omitted real sections (which would otherwise leak into the previous
    body and inject into Claude's preflight banner). Returns None if no top-level
    header matches `name`.
    """
    lines = text.split("\n")
    target_header = f"## {name}"
    target_index = None
    next_boundary = None
    boundary_headers = _get_boundary_headers(text)
    for i, line in _iter_top_level_lines(lines):
        stripped = line.rstrip()
        if target_index is None:
            if stripped == target_header:
                target_index = i
        else:
            if stripped in boundary_headers:
                next_boundary = i
                break
    if target_index is None:
        return None
    end = next_boundary if next_boundary is not None else len(lines)
    # Skip the header line itself; collect everything up to (not including) the next boundary
    body = "\n".join(lines[target_index + 1:end])
    return body.strip()


def _modify_registry(text, modify_fn):
    """Read registry, apply modify_fn, write back. No-op if no registry."""
    registry = read_registry(text)
    if registry is not None:
        registry = modify_fn(registry)
        text = write_registry(text, registry)
    return text


def _fence_marker(line):
    """Return (char, run_length, has_info_string) if this line is a fence marker, else None.

    CommonMark rules honored here:
      - Indent of 4+ spaces makes the line an indented code block, NOT a fence.
      - Fence opener is at least 3 of '`' or '~'.
      - Closer must use the same character, be at least as long as the opener,
        AND have NO trailing non-whitespace (info string disqualifies a closer).

    Callers track the active opener tuple and may only close when the new marker
    matches char + length >= opener AND has_info_string is False. Lines like
    "```python" are valid openers (info='python') but not valid closers.
    """
    indent = len(line) - len(line.lstrip(" "))
    if indent >= 4:
        return None  # indented code block, not a fence (CommonMark §4.4)
    stripped = line[indent:]
    for ch in ("`", "~"):
        if stripped.startswith(ch * 3):
            run = 0
            while run < len(stripped) and stripped[run] == ch:
                run += 1
            has_info = bool(stripped[run:].strip())
            return (ch, run, has_info)
    return None


def add_section(text, name):
    """Insert a new (none) section before ## ANY and update registry.

    Uses line-by-line scanning that SKIPS markdown fenced code blocks (``` or ~~~),
    so a literal "## ANY" appearing inside a code example in a task body cannot be
    matched (the older regex approach couldn't tell fence-inside from real header).
    Only the first non-fenced `## ANY` at start-of-line is used.

    Also rejects names containing newlines (sync.sh wraps with `tr -d '\r\n'` but
    direct Python callers need defense-in-depth).
    """
    _validate_section_name(name)
    new_section_lines = [f"## {name}", "", "(none)", ""]
    lines = text.split("\n")
    insert_index = None
    for i, line in _iter_top_level_lines(lines):
        if line.rstrip() == "## ANY":
            insert_index = i
            break
    if insert_index is None:
        raise ValueError("HANDOFF.md 中未找到 '## ANY' 锚点（或仅在代码块内），无法插入新设备节")
    # Insert new-section block + trailing blank line before the ## ANY line
    lines[insert_index:insert_index] = new_section_lines + [""]
    result = "\n".join(lines)
    # Collapse runs of 3+ blank lines that accumulate from repeated add_section calls
    # (the existing blank before `## ANY` plus our trailing blank double up otherwise)
    result = re.sub(r"\n{3,}", "\n\n", result)
    # Update registry
    result = _modify_registry(result, lambda reg: reg if name in reg else reg + [name])
    return result


def remove_section(text, name):
    """Remove a section, normalize whitespace, and update registry.

    Uses line-by-line scanning + code-fence tracking to avoid matching a literal
    ## Name line that appears inside a code fenced block (which would corrupt
    unrelated content). Section boundaries come from `_get_boundary_headers` —
    the union of registered names and observed on-disk headers. The union
    bounds the deletion span at the next real or registered header, so
    removing one section can never delete through a registry-omitted real
    section to the next registered boundary.
    """
    lines = text.split("\n")
    boundary_headers = _get_boundary_headers(text)
    # Collect device-section-header indices (non-fenced, in boundary set)
    boundary_indices = []
    target_index = None
    target_header = f"## {name}"
    for i, line in _iter_top_level_lines(lines):
        stripped = line.rstrip()
        if stripped in boundary_headers:
            boundary_indices.append(i)
            if stripped == target_header and target_index is None:
                target_index = i
    if target_index is None:
        # Fence-aware scan didn't find the section. Two cases:
        # (a) the section was already removed → safe to drop from registry (idempotent)
        # (b) the section EXISTS in the file at top level but the fence-aware scan was
        #     defeated by an unclosed fence earlier in the file (compromised remote, or
        #     user-typo unclosed fence) → touching the registry would deregister the
        #     device while leaving the section body orphaned and unreachable.
        # The fence-blind raw regex distinguishes these: it matches a `## NAME` line
        # regardless of fence state, so it sees case (b)'s real header that fence-aware
        # iteration skips. (Trade-off: if a closed code-fence elsewhere in the file
        # contains `## NAME` as example text, this raw check also matches it and would
        # block a legitimate idempotent registry cleanup. That false-positive is rare
        # and recoverable by manual edit; the unclosed-fence attack is data-loss
        # preventing, so we accept the trade-off in this direction.)
        # Whitespace normalization is always safe.
        result = re.sub(r"\n{3,}", "\n\n", text)
        if re.search(rf"(?m)^## {re.escape(name)}\s*$", result):
            return result  # case (b): keep registry consistent with on-disk content
        return _modify_registry(result, lambda reg: [n for n in reg if n != name])
    # Find the next non-fenced ## header after target_index (section end)
    next_boundaries = [b for b in boundary_indices if b > target_index]
    end_index = next_boundaries[0] if next_boundaries else len(lines)
    del lines[target_index:end_index]
    result = "\n".join(lines)
    result = re.sub(r"\n{3,}", "\n\n", result)
    # Update registry
    result = _modify_registry(result, lambda reg: [n for n in reg if n != name])
    return result


def list_devices(text):
    """Return list of device names (excluding ANY). Uses registry if available."""
    return [n for n in _get_device_names(text) if n != "ANY"]


def migrate_format(text):
    """Add registry comment to legacy HANDOFF.md (idempotent).

    Aborts migration (returns text unchanged) when any top-level `## Name` header
    fails `_validate_section_name`. Reason: writing a partial registry would let
    invalid-name headers pass through unrecognized, while downstream code paths
    that consult `read_registry` would see a truncated trusted set — staying in
    legacy/no-registry mode keeps every `## ` line treated as a real boundary by
    the line-walking extractors.

    Both the raw count and the validated-name extract use the same fence-aware
    iteration (`_iter_top_level_header_names`) — a fenced `## Foo` in a task body
    must NOT be counted as a real header on either side, otherwise an attacker
    could plant a fenced injection that increments both counts equally and slips
    past the equality check.
    """
    if read_registry(text) is not None:
        return text  # Already migrated
    raw_names = list(_iter_top_level_header_names(text))
    devices = _extract_all_headers(text)
    if not devices:
        return text  # Nothing to migrate
    if len(devices) != len(raw_names):
        return text  # Refuse to migrate when any name fails validation
    return write_registry(text, devices)


def get_pending_tasks(text, *targets):
    """Return list of (target, body) tuples for sections with pending tasks."""
    results = []
    for target in targets:
        body = extract_section_body(text, target)
        if body and body != "(none)":
            results.append((target, body))
    return results


# --- CLI interface (called from bash) ---
if __name__ == "__main__":
    # 模块级已处理编码，此处保留作为 CLI 入口的防御性保证
    _ensure_utf8()

    if len(sys.argv) < 2:
        print("Usage: handoff.py <command> <file> [args...]", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "section_exists":
        text = read_file(sys.argv[2])
        print("yes" if section_exists(text, sys.argv[3]) else "no")

    elif cmd == "add_section":
        path = sys.argv[2]
        try:
            text = add_section(read_file(path), sys.argv[3])
        except ValueError as e:
            print(f"错误：{e}", file=sys.stderr)
            sys.exit(1)
        write_file(path, text)

    elif cmd == "remove_section":
        path = sys.argv[2]
        text = remove_section(read_file(path), sys.argv[3])
        write_file(path, text)

    elif cmd == "list_devices":
        for name in list_devices(read_file(sys.argv[2])):
            print(name)

    elif cmd == "get_pending":
        # Output format (display-only, not for parsing): per matching target,
        #   [<target_name>]\n<body_text>\n\n
        # The current sync.sh caller only checks non-emptiness and prints to a
        # banner — body content may itself contain lines starting with '['.
        # If a future caller needs to parse this, switch to a structured format
        # (e.g., JSON) rather than relying on the [name] header.
        for target, body in get_pending_tasks(read_file(sys.argv[2]), *sys.argv[3:]):
            print(f"[{target}]")
            print(body)
            print()

    elif cmd == "migrate":
        path = sys.argv[2]
        text = migrate_format(read_file(path))
        write_file(path, text)
        print("Migration complete.")

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)
