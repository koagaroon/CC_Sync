#!/usr/bin/env bash
# module-manager.sh — Third-party module manager for Claude Code
# Manages skills/plugins/MCP servers in ~/.claude/skills/
# Usage: module-manager.sh <command> [options]
#
# Commands:
#   list                        List all tracked modules + detect unmanaged
#   check [name|--all]          Check for upstream updates
#   update [name|--all]         Pull updates from upstream
#   install <source> [--name X] Install a new module
#   remove <name>               Remove a module
#   adopt <name> <source>       Track an existing directory in the manifest
#   adopt --bulk <owner/repo>   Bulk-adopt matching directories
#   restore                     Download all modules from manifest (new device)
#   prune [--all|--confirm N..] List/delete untracked directories

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# --- Config ---
# normalize_path converts Git Bash paths (/c/Users/...) to Windows paths (C:/Users/...)
# so Python (native Windows) can resolve them correctly.
SKILLS_DIR=$(normalize_path "${HOME}/.claude/skills")
MANIFEST="${SKILLS_DIR}/modules.toml"
TODAY=$(date -u +%Y-%m-%d)  # UTC — avoids cross-timezone diff noise in synced modules.toml

detect_gh || exit 1
MODULE_HELPER=$(normalize_path "$SCRIPT_DIR/lib/module_helper.py")

# --- 临时目录清理 trap ---
_CLEANUP_DIRS=()
_cleanup_temps() {
    local d
    for d in "${_CLEANUP_DIRS[@]+"${_CLEANUP_DIRS[@]}"}"; do
        [ -d "$d" ] && rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_temps EXIT INT TERM

# --- 仓库格式验证 ---
_validate_repo_format() {
    # owner/repo — alphanumeric + _ . - ; reject . / .. / leading-dash in either component
    # (GitHub rejects these with 404; also closes defense-in-depth gaps)
    if [[ ! "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
        echo -e "${RED}错误：无效的仓库格式 '$1'（应为 owner/repo）${NC}" >&2
        return 1
    fi
    local owner="${1%%/*}" name="${1##*/}"
    if [[ "$owner" == "." || "$owner" == ".." || "$name" == "." || "$name" == ".." ]]; then
        echo -e "${RED}错误：仓库名不能为 . 或 ..（收到 '$1'）${NC}" >&2
        return 1
    fi
}

py_helper() {
    PYTHONIOENCODING=utf-8 python "$MODULE_HELPER" "$@"
}

# ─── TOML ↔ JSON bridge ──────────────────────────────────────────
# Read TOML manifest → JSON to stdout
# Write JSON from stdin → TOML manifest
# This lets bash pipe data between commands while Python handles parsing.

manifest_json() {
    py_helper manifest-read "$MANIFEST"
}

save_manifest() {
    # Reads JSON from stdin, writes TOML to $MANIFEST
    py_helper manifest-write "$MANIFEST"
}

# ─── Shared Python micro-helpers ─────────────────────────────────
# Small Python operations reused across multiple commands.

# Check whether a module name exists in the manifest JSON.
# Prints "yes" or "no".
module_exists() {
    echo "$1" | py_helper module-exists "$2"
}

# Add or overwrite a module entry in the manifest JSON.
# Reads JSON from $1 (data), prints updated JSON to stdout.
# Args: data name sha today kind repo path ref
manifest_add_module() {
    echo "$1" | py_helper manifest-add-module "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

# ─── Validation helpers ───────────────────────────────────────────

# Validate module name: alphanumeric, hyphens, underscores, dots only.
# Rejects path traversal (../), slashes, and shell metacharacters.
_validate_module_name() {
    local name="$1"
    if [[ "$name" == "." || "$name" == ".." ]]; then
        echo -e "${RED}错误：无效的模块名 '$name'${NC}" >&2
        return 1
    fi
    # Require an alphanumeric/underscore lead to keep names from looking like
    # CLI flags downstream (e.g. "-evil" passed where rm/mv won't get a slash prefix).
    if [[ ! "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
        echo -e "${RED}错误：模块名 '$name' 只能包含 A-Z a-z 0-9 _ - .（首字符须为字母/数字/下划线）${NC}" >&2
        return 1
    fi
}

# ─── GitHub helpers ───────────────────────────────────────────────

# URL-encode a string via Python's urllib.parse.quote (matches helper's Python side).
# Bash has no builtin quoting; we shell out to python for correctness.
_url_encode() {
    python -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

get_head_sha() {
    local repo="$1" ref="${2:-main}"
    local sha enc_ref
    enc_ref=$(_url_encode "$ref")
    sha=$("$GH" api "repos/${repo}/commits/${enc_ref}" -q '.sha' 2>/dev/null) || return 1
    # Validate: must be 40-char hex (reject null, empty, error messages)
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
    echo "$sha"
}

# Get the latest commit SHA that touched a specific subdirectory.
# Uses the commits list API with path filter (equivalent to git log -1 -- path).
get_path_sha() {
    local repo="$1" path="$2" ref="${3:-main}"
    local sha enc_ref enc_path
    enc_ref=$(_url_encode "$ref")
    # path: keep forward slashes (they are path separators, not delimiters)
    enc_path=$(python -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe='/'))" "$path")
    sha=$("$GH" api "repos/${repo}/commits?sha=${enc_ref}&path=${enc_path}&per_page=1" -q '.[0].sha' 2>/dev/null) || return 1
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
    echo "$sha"
}

# Download a subdirectory from GitHub via API (no full clone needed)
download_github_subdir() {
    local repo="$1" subpath="$2" ref="$3" dest
    dest=$(normalize_path "$4")
    py_helper download-github-subdir "$GH" "$repo" "$subpath" "$ref" "$dest"
}

# Download a whole GitHub repo via shallow clone
download_github_repo() {
    local repo="$1" ref="$2" dest
    dest=$(normalize_path "$3")
    local tmp_clone
    tmp_clone=$(safe_mktemp)
    _CLEANUP_DIRS+=("$tmp_clone")

    if ! git clone --depth 1 --branch "$ref" --single-branch \
         "https://github.com/${repo}.git" "$tmp_clone" 2>/dev/null; then
        echo -e "${RED}✗ Failed to clone branch '$ref' from https://github.com/${repo}.git${NC}" >&2
        rm -rf "$tmp_clone" 2>/dev/null || true
        return 1
    fi

    mkdir -p "$dest"
    # Copy contents. -maxdepth 1 ! -type l excludes top-level symlinks; cp -a preserves
    # and does NOT dereference nested symlinks (plain cp -r follows them on some platforms,
    # which would let a malicious upstream repo exfiltrate files outside $dest).
    # Any symlinks that survived are then hard-deleted from $dest for defense-in-depth.
    local copy_errors=0
    (set -o pipefail; cd "$tmp_clone" && find . -maxdepth 1 ! -name . ! -name .git ! -type l -print0 \
        | xargs -0 -I '{}' cp -a '{}' "$dest"/) || copy_errors=1
    find "$dest" -type l -delete 2>/dev/null || true
    rm -rf "$tmp_clone" 2>/dev/null || true
    return $copy_errors
}

_download_to_tmp() {
    local kind="$1" repo="$2" path="$3" ref="$4" tmp_dest="$5"
    if [[ "$kind" == "github-subdir" ]]; then
        download_github_subdir "$repo" "$path" "$ref" "$tmp_dest"
    elif [[ "$kind" == "github-repo" ]]; then
        download_github_repo "$repo" "$ref" "$tmp_dest"
    else
        echo -e "  ${YELLOW}⚠${NC} Unsupported source kind: $kind" >&2
        return 1
    fi
}

# ─── Parse source string ─────────────────────────────────────────
# Returns: kind\trepo\tpath\tref  (tab-separated)

parse_source() {
    local src="$1"
    # Reject embedded tabs/newlines: the function emits tab-separated output, so a
    # tab inside src would shift downstream `IFS=$'\t' read` parsing.
    if [[ "$src" == *$'\t'* || "$src" == *$'\n'* ]]; then
        echo -e "${RED}错误：来源字符串不能包含制表符或换行${NC}" >&2
        return 1
    fi
    if [[ "$src" == https://* ]]; then
        printf 'url\t\t\t%s' "$src"
    elif [[ "$src" == *:* ]]; then
        # owner/repo:path/to/skill
        local repo="${src%%:*}"
        local path="${src#*:}"
        printf 'github-subdir\t%s\t%s\tmain' "$repo" "$path"
    else
        # owner/repo (whole repo)
        printf 'github-repo\t%s\t\tmain' "$src"
    fi
}

# ─── Commands ─────────────────────────────────────────────────────

cmd_list() {
    local data
    data=$(manifest_json)

    py_helper list "$data" "$SKILLS_DIR"
}

cmd_check() {
    local target="${1:---all}"
    local data
    data=$(manifest_json)

    GH_CMD="$GH" py_helper check "$data" "$target"
}

cmd_update() {
    local target="${1:---all}"
    local data
    data=$(manifest_json)

    # Get modules that need updating (reuse check logic)
    local needs_update
    local check_tmpdir
    check_tmpdir=$(safe_mktemp)
    _CLEANUP_DIRS+=("$check_tmpdir")
    local check_stderr="${check_tmpdir}/stderr.txt"
    needs_update=$(GH_CMD="$GH" py_helper update-check "$data" "$target" 2>"$check_stderr") || {
        local rc=$?
        if [[ -s "$check_stderr" ]]; then
            echo -e "${RED}✗${NC} Update check failed:" >&2
            cat "$check_stderr" >&2
        fi
        rm -rf "$check_tmpdir" 2>/dev/null || true
        return $rc
    }
    # update-check exits 0 even when some modules failed their lookup (per-module
    # warnings go to stderr). Surface those warnings before proceeding so the user
    # isn't blind to silently skipped modules.
    if [[ -s "$check_stderr" ]]; then
        cat "$check_stderr" >&2
    fi
    rm -rf "$check_tmpdir" 2>/dev/null || true

    if [[ -z "$needs_update" ]]; then
        echo -e "${GREEN}✓${NC} All modules up to date"
        return 0
    fi

    local count=0
    local errors=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name kind repo path ref install_path latest_sha
        # py_helper tab-vars emits US (\x1f), not \t — \t is IFS whitespace
        # in bash so empty fields collapse, mis-binding path/ref/install_path
        # for github-repo modules where `path` is intentionally empty. \x1f
        # is non-whitespace, so consecutive delimiters yield empty fields.
        IFS=$'\x1f' read -r name kind repo path ref install_path latest_sha <<< "$(echo "$line" | py_helper tab-vars)"

        # Validate install_path from manifest (prevent path traversal)
        if ! _validate_module_name "$install_path" 2>/dev/null; then
            echo -e "  ${RED}✗${NC} ${name}: invalid install_path '${install_path}', skipping"
            errors=$((errors + 1))
            continue
        fi

        echo -e "→ Updating ${name}..."
        local dest="${SKILLS_DIR}/${install_path}"

        local ok=true
        local tmp_dest
        tmp_dest=$(safe_mktemp)
        _CLEANUP_DIRS+=("$tmp_dest")

        if ! _download_to_tmp "$kind" "$repo" "$path" "$ref" "$tmp_dest"; then ok=false; fi

        if ! $ok; then
            rm -rf "$tmp_dest" 2>/dev/null || true
            echo -e "  ${RED}✗${NC} ${name} download failed"
            errors=$((errors + 1))
            continue
        fi

        # Swap with backup
        [ -d "$dest" ] && mv "$dest" "${dest}.bak"
        if mv "$tmp_dest" "$dest" 2>/dev/null; then
            rm -rf "${dest}.bak" 2>/dev/null || true
        elif (mkdir -p "$dest" && cp -rf "$tmp_dest"/. "$dest"/); then
            # Commit point: dest holds the new data. tmp_dest cleanup is best-effort —
            # the EXIT trap will catch it if rm fails here, so don't roll back the
            # successful copy just because the temp removal stumbled.
            rm -rf "$tmp_dest" 2>/dev/null || true
            rm -rf "${dest}.bak" 2>/dev/null || true
        else
            rm -rf "$dest" 2>/dev/null || true
            if [ -d "${dest}.bak" ]; then
                if ! mv "${dest}.bak" "$dest"; then
                    echo -e "  ${RED}✗${NC} CRITICAL: backup restore failed for ${name}! Backup at ${dest}.bak" >&2
                fi
            fi
            ok=false
        fi

        if $ok; then
            # Update manifest entry
            data=$(echo "$data" | py_helper manifest-update-sha "$name" "$latest_sha" "$TODAY")
            echo -e "  ${GREEN}✓${NC} ${name} updated"
            count=$((count + 1))
        else
            echo -e "  ${RED}✗${NC} ${name} failed"
            errors=$((errors + 1))
        fi
    done <<< "$needs_update"

    # Save updated manifest only if at least one module was updated
    if [[ $count -gt 0 ]]; then
        echo "$data" | save_manifest
    fi

    echo ""
    echo "Updated: $count, Failed: $errors"
}

cmd_install() {
    local source_str="" name_override=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name_override="$2"; shift 2 ;;
            *)      source_str="$1"; shift ;;
        esac
    done

    [[ -z "$source_str" ]] && { echo "用法：module-manager.sh install <source> [--name <name>]" >&2; exit 1; }

    # Parse source — propagate parse_source's failure (e.g. tab/newline rejection)
    # so empty fields don't slip past as "URL kind requires --name" downstream.
    local parsed
    parsed=$(parse_source "$source_str") || exit 1
    IFS=$'\t' read -r kind repo path ref <<< "$parsed"

    # Validate repo format
    if [[ ("$kind" == "github-subdir" || "$kind" == "github-repo") && -n "$repo" ]]; then
        _validate_repo_format "$repo" || exit 1
    fi

    # Determine install name
    local install_name
    if [[ -n "$name_override" ]]; then
        install_name="$name_override"
    elif [[ "$kind" == "github-subdir" ]]; then
        install_name=$(basename "$path")
    elif [[ "$kind" == "github-repo" ]]; then
        install_name=$(basename "$repo")
    else
        echo -e "${RED}错误：URL 类型的来源必须指定 --name${NC}" >&2
        exit 1
    fi

    # Validate module name (prevent path traversal / shell metacharacters)
    _validate_module_name "$install_name" || exit 1

    local dest="${SKILLS_DIR}/${install_name}"

    # Check for conflict — match any existing entry, not just directories. A bare
    # file at $dest would otherwise sneak past, fail mv, then trip set -e in the
    # mkdir/cp fallback without ever emitting the CONFLICT_INSTALL marker.
    if [[ -e "$dest" || -L "$dest" ]]; then
        echo -e "${RED}错误：路径已存在：$dest${NC}" >&2
        # Marker is the parsing contract with the SKILL.md install-conflict flow.
        # Changing the prefix is a breaking change — update both sides together.
        echo "CONFLICT_INSTALL: $dest" >&2
        exit 2
    fi

    # Get commit SHA (path-specific for subdir modules, repo-level otherwise)
    local sha=""
    if [[ "$kind" != "url" && -n "$repo" ]]; then
        echo -e "→ Getting version info..."
        if [[ "$kind" == "github-subdir" && -n "$path" ]]; then
            sha=$(get_path_sha "$repo" "$path" "${ref:-main}") || {
                echo -e "${RED}错误：无法访问 $repo（路径：$path）${NC}" >&2
                exit 1
            }
        else
            sha=$(get_head_sha "$repo" "${ref:-main}") || {
                echo -e "${RED}错误：无法访问 $repo${NC}" >&2
                exit 1
            }
        fi
    fi

    # Download to temp, then move into place
    echo -e "→ Installing ${install_name}..."
    local tmp_dest
    tmp_dest=$(safe_mktemp)
    _CLEANUP_DIRS+=("$tmp_dest")
    local dl_ok=true
    if [[ "$kind" == "github-subdir" ]]; then
        download_github_subdir "$repo" "$path" "${ref:-main}" "$tmp_dest" || dl_ok=false
    elif [[ "$kind" == "github-repo" ]]; then
        download_github_repo "$repo" "${ref:-main}" "$tmp_dest" || dl_ok=false
    elif [[ "$kind" == "url" ]]; then
        echo -e "${RED}错误：URL 类型的来源尚未实现${NC}" >&2
        rm -rf "$tmp_dest" 2>/dev/null || true
        exit 1
    fi
    if ! $dl_ok; then
        rm -rf "$tmp_dest" 2>/dev/null || true
        exit 1
    fi
    if ! mv "$tmp_dest" "$dest" 2>/dev/null; then
        # Cross-filesystem fallback: explicit error path so a partial cp doesn't leave
        # half-written dest with no manifest entry and no clear signal to the user.
        if ! (mkdir -p "$dest" && cp -rf "$tmp_dest"/. "$dest"/); then
            echo -e "${RED}错误：写入 $dest 失败（mv 与 cp 均未成功）${NC}" >&2
            rm -rf "$dest" 2>/dev/null || true
            rm -rf "$tmp_dest" 2>/dev/null || true
            exit 1
        fi
        rm -rf "$tmp_dest" 2>/dev/null || true
    fi

    # Add to manifest
    local data
    data=$(manifest_json)
    data=$(manifest_add_module "$data" "$install_name" "$sha" "$TODAY" "$kind" "$repo" "$path" "${ref:-main}")
    echo "$data" | save_manifest

    echo -e "${GREEN}✓${NC} Installed: ${install_name}"
    echo "  Source: ${source_str}"
    [[ -n "$sha" ]] && echo "  Commit: ${sha:0:8}"
    echo "  Path:   ${dest}"
}

cmd_remove() {
    local name="${1:-}"
    [[ -z "$name" ]] && { echo "用法：module-manager.sh remove <name>" >&2; exit 1; }

    local data
    data=$(manifest_json)

    # Check if module exists in manifest
    if [[ "$(module_exists "$data" "$name")" != "yes" ]]; then
        echo -e "${RED}错误：manifest 中未找到模块 '$name'${NC}" >&2
        exit 1
    fi

    # Get install path
    local install_path
    install_path=$(echo "$data" | py_helper module-get-path "$name")

    # Validate install_path from manifest before rm -rf — defends against a
    # corrupted/poisoned modules.toml that pushes "../somewhere" into the path.
    _validate_module_name "$install_path" || exit 1

    local dest="${SKILLS_DIR}/${install_path}"

    # Remove from manifest FIRST (so a save failure doesn't orphan the directory)
    data=$(echo "$data" | py_helper manifest-delete-module "$name")
    echo "$data" | save_manifest
    echo -e "${GREEN}✓${NC} Removed ${name} from manifest"

    # Then remove directory
    if [[ -d "$dest" ]]; then
        if rm -rf "$dest" 2>/dev/null; then
            echo -e "${GREEN}✓${NC} Removed directory: ${dest}"
        else
            echo -e "${RED}✗${NC} 删除目录失败：${dest}（manifest 已清除，目录残留）" >&2
            exit 1
        fi
    else
        echo -e "${YELLOW}⚠${NC} Directory not found: ${dest}"
    fi
}

cmd_adopt() {
    local arg1="${1:-}"
    local arg2="${2:-}"

    if [[ "$arg1" == "--bulk" ]]; then
        [[ -z "$arg2" ]] && { echo "用法：module-manager.sh adopt --bulk <owner/repo>" >&2; exit 1; }
        cmd_adopt_bulk "$arg2"
        return
    fi

    # Single adopt: adopt <name> <source>
    local name="$arg1"
    local source_str="$arg2"
    [[ -z "$name" || -z "$source_str" ]] && { echo "用法：module-manager.sh adopt <name> <source>" >&2; exit 1; }

    _validate_module_name "$name" || exit 1

    # Verify directory exists
    local dest="${SKILLS_DIR}/${name}"
    [[ -d "$dest" ]] || { echo -e "${RED}错误：目录不存在：$dest${NC}" >&2; exit 1; }

    # Parse source — propagate parse_source's failure so we don't write a manifest
    # entry with empty kind on tab/newline rejection.
    local parsed
    parsed=$(parse_source "$source_str") || exit 1
    IFS=$'\t' read -r kind repo path ref <<< "$parsed"

    # Reject URL sources (not yet implemented for adopt)
    if [[ "$kind" == "url" ]]; then
        echo -e "${RED}错误：adopt 不支持 URL 来源，请使用 owner/repo 或 owner/repo:path 格式。${NC}" >&2
        exit 1
    fi

    # Validate repo format
    if [[ ("$kind" == "github-subdir" || "$kind" == "github-repo") && -n "$repo" ]]; then
        _validate_repo_format "$repo" || exit 1
    fi

    # Get current commit SHA (path-specific for subdir modules)
    local sha=""
    if [[ -n "$repo" ]]; then
        if [[ "$kind" == "github-subdir" && -n "$path" ]]; then
            sha=$(get_path_sha "$repo" "$path" "${ref:-main}") || {
                echo -e "${YELLOW}⚠${NC} Cannot reach $repo (path: $path), using empty SHA"
            }
        else
            sha=$(get_head_sha "$repo" "${ref:-main}") || {
                echo -e "${YELLOW}⚠${NC} Cannot reach $repo, using empty SHA"
            }
        fi
    fi

    # Add to manifest
    local data
    data=$(manifest_json)
    data=$(manifest_add_module "$data" "$name" "$sha" "$TODAY" "$kind" "$repo" "$path" "${ref:-main}")
    echo "$data" | save_manifest
    echo -e "${GREEN}✓${NC} Adopted: ${name} (${source_str})"
}

cmd_adopt_bulk() {
    local repo="$1"
    _validate_repo_format "$repo" || exit 1

    echo -e "→ Scanning ${repo} for matching skills..."

    # Get the list of skill directories in the remote repo
    local remote_skills
    remote_skills=$("$GH" api "repos/${repo}/contents/skills" -q 'if type == "array" then .[].name else .name end' 2>/dev/null) || {
        echo -e "${RED}错误：无法列出 $repo 中的 skills${NC}" >&2
        exit 1
    }

    # Read current manifest
    local data
    data=$(manifest_json)

    local adopted=0 skipped=0

    while IFS= read -r skill_name; do
        [[ -z "$skill_name" ]] && continue

        # Validate remote skill name (prevent path traversal from API responses)
        if ! _validate_module_name "$skill_name" 2>/dev/null; then
            echo -e "  ${YELLOW}⚠${NC} Skipped invalid name: ${skill_name}"
            continue
        fi

        local local_dir="${SKILLS_DIR}/${skill_name}"

        # Skip if not present locally
        if [[ ! -d "$local_dir" ]]; then
            continue
        fi

        # Skip if already tracked
        if [[ "$(module_exists "$data" "$skill_name")" == "yes" ]]; then
            echo -e "  ${GRAY}skip${NC} ${skill_name} (already tracked)"
            skipped=$((skipped + 1))
            continue
        fi

        # Get path-specific SHA for each skill
        local sha=""
        sha=$(get_path_sha "$repo" "skills/${skill_name}" "main") || {
            echo -e "  ${YELLOW}⚠${NC} Cannot get SHA for skills/${skill_name}, using empty"
        }

        # Add to manifest
        data=$(manifest_add_module "$data" "$skill_name" "$sha" "$TODAY" \
            "github-subdir" "$repo" "skills/${skill_name}" "main")
        echo -e "  ${GREEN}✓${NC} ${skill_name}"
        adopted=$((adopted + 1))
    done <<< "$remote_skills"

    # Save only if at least one module was adopted
    if [[ $adopted -gt 0 ]]; then
        echo "$data" | save_manifest
    fi

    echo ""
    echo "Adopted: $adopted, Skipped: $skipped"
    echo "Manifest: $MANIFEST"
}

cmd_restore() {
    local data
    data=$(manifest_json)

    local total
    total=$(echo "$data" | py_helper restore-count)

    if [[ "$total" == "0" ]]; then
        echo "No modules in manifest."
        exit 0
    fi

    echo -e "→ Restoring $total modules from manifest..."

    # Get list of modules to restore (missing locally)
    local to_restore
    to_restore=$(echo "$data" | py_helper restore-list-missing "$SKILLS_DIR")

    if [[ -z "$to_restore" ]]; then
        echo -e "${GREEN}✓${NC} All modules already present locally"
        return 0
    fi

    local restored=0 failed=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name kind repo path ref install_path latest_sha
        # py_helper tab-vars emits US (\x1f), not \t — \t is IFS whitespace
        # in bash so empty fields collapse, mis-binding path/ref/install_path
        # for github-repo modules where `path` is intentionally empty. \x1f
        # is non-whitespace, so consecutive delimiters yield empty fields.
        IFS=$'\x1f' read -r name kind repo path ref install_path latest_sha <<< "$(echo "$line" | py_helper tab-vars)"

        # Validate install_path from manifest (prevent path traversal)
        if ! _validate_module_name "$install_path" 2>/dev/null; then
            echo -e "  ${RED}✗${NC} ${name}: invalid install_path '${install_path}', skipping"
            failed=$((failed + 1))
            continue
        fi

        local dest="${SKILLS_DIR}/${install_path}"
        echo -e "→ Restoring ${name}..."

        local tmp_dest ok=true
        tmp_dest=$(safe_mktemp)
        _CLEANUP_DIRS+=("$tmp_dest")
        if ! _download_to_tmp "$kind" "$repo" "$path" "$ref" "$tmp_dest"; then ok=false; fi

        if $ok; then
            if ! mv "$tmp_dest" "$dest" 2>/dev/null; then
                mkdir -p "$dest"
                cp -rf "$tmp_dest"/. "$dest"/
                rm -rf "$tmp_dest" 2>/dev/null || true
            fi
            echo -e "  ${GREEN}✓${NC} ${name}"
            restored=$((restored + 1))
        else
            rm -rf "$tmp_dest" 2>/dev/null || true
            echo -e "  ${RED}✗${NC} ${name}"
            failed=$((failed + 1))
        fi
    done <<< "$to_restore"

    echo ""
    echo "Restored: $restored, Failed: $failed, Already present: $((total - restored - failed))"
}

cmd_prune() {
    local mode="list"
    local names=()

    case "${1:-}" in
        --all)
            mode="all"
            if [[ $# -gt 1 ]]; then
                echo "用法：module-manager.sh prune --all（不接受其他参数）" >&2
                exit 1
            fi
            ;;
        --confirm)
            mode="confirm"
            shift
            names=("$@")
            if [[ ${#names[@]} -eq 0 ]]; then
                echo "用法：module-manager.sh prune --confirm <name>..." >&2
                exit 1
            fi
            ;;
        "")
            mode="list"
            ;;
        *)
            echo "用法：module-manager.sh prune [--all | --confirm <name>...]" >&2
            exit 1
            ;;
    esac

    local data
    data=$(manifest_json)

    if [[ "$mode" == "list" ]]; then
        py_helper list-untracked "$data" "$SKILLS_DIR"
        return
    fi

    if [[ "$mode" == "all" ]]; then
        local untracked
        untracked=$(py_helper list-untracked "$data" "$SKILLS_DIR")
        if [[ -z "$untracked" ]]; then
            echo -e "${GREEN}✓${NC} 没有未管理目录，无需清理。"
            return 0
        fi
        local removed=0 errors=0
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            if ! _validate_module_name "$name" 2>/dev/null; then
                echo -e "  ${RED}✗${NC} ${name}: 名称非法，跳过"
                errors=$((errors + 1))
                continue
            fi
            # 防御深度：list-untracked 已按 tracked_paths 过滤，但若任何环节
            # （Python helper 输出格式漂移、CR/LF 拆分、JSON 编码异常）让一个
            # tracked 名字误入此循环，下面的 rm -rf 会删掉受管模块。在删之前
            # 再问一次 manifest，碰到 tracked 名字直接拒绝。
            if [[ "$(module_exists "$data" "$name")" == "yes" ]]; then
                echo -e "  ${RED}✗${NC} ${name}: 仍在 manifest 中——拒绝删除（请用 remove）"
                errors=$((errors + 1))
                continue
            fi
            local dest="${SKILLS_DIR}/${name}"
            if [[ -d "$dest" ]]; then
                if rm -rf "$dest" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已删除 ${name}/"
                    removed=$((removed + 1))
                else
                    echo -e "  ${RED}✗${NC} ${name}: 删除失败"
                    errors=$((errors + 1))
                fi
            else
                echo -e "  ${YELLOW}⚠${NC} ${name}: 目录已不存在，跳过"
            fi
        done <<< "$untracked"
        echo ""
        echo "已清理: $removed, 失败: $errors"
        return 0
    fi

    # mode == "confirm"
    local removed=0 errors=0
    for name in "${names[@]}"; do
        if ! _validate_module_name "$name"; then
            errors=$((errors + 1))
            continue
        fi
        # Refuse to delete a name still tracked in the manifest — caller is confused;
        # the right command for managed modules is `remove`, which also clears the entry.
        if [[ "$(module_exists "$data" "$name")" == "yes" ]]; then
            echo -e "  ${RED}✗${NC} ${name}: 仍在 manifest 中——请使用 remove，而非 prune" >&2
            errors=$((errors + 1))
            continue
        fi
        local dest="${SKILLS_DIR}/${name}"
        if [[ ! -d "$dest" ]]; then
            echo -e "  ${YELLOW}⚠${NC} ${name}: 目录不存在 (${dest})，跳过"
            continue
        fi
        if rm -rf "$dest" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} 已删除 ${name}/"
            removed=$((removed + 1))
        else
            echo -e "  ${RED}✗${NC} ${name}: 删除失败"
            errors=$((errors + 1))
        fi
    done
    echo ""
    echo "已清理: $removed, 失败: $errors"
    [[ $errors -gt 0 ]] && return 1
    return 0
}

# ─── Main ─────────────────────────────────────────────────────────

case "${1:-}" in
    list)     cmd_list ;;
    check)    shift; cmd_check "${1:---all}" ;;
    update)   shift; cmd_update "${1:---all}" ;;
    install)  shift; cmd_install "$@" ;;
    remove)   shift; cmd_remove "$@" ;;
    adopt)    shift; cmd_adopt "$@" ;;
    restore)  cmd_restore ;;
    prune)    shift; cmd_prune "$@" ;;
    *)
        echo "module-manager.sh — Third-party module manager"
        echo ""
        echo "Commands:"
        echo "  list                        List tracked modules"
        echo "  check [name|--all]          Check for updates"
        echo "  update [name|--all]         Update modules"
        echo "  install <source> [--name X] Install new module"
        echo "  remove <name>               Remove a module"
        echo "  adopt <name> <source>       Track existing directory"
        echo "  adopt --bulk <owner/repo>   Bulk-adopt from repo"
        echo "  restore                     Restore from manifest"
        echo "  prune                       List untracked directories"
        echo "  prune --all                 Delete all untracked directories"
        echo "  prune --confirm <name>...   Delete specific untracked directories"
        exit 1
        ;;
esac
