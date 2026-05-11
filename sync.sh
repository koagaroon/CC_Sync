#!/bin/bash
# sync.sh — Claude Code 工作区自动同步脚本
# 发现所有 claude-code-workspace 仓库，pull + 检测改动 + commit + push
# 冲突和错误会输出到 stderr，交给 Claude 处理

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

ENV_FILE="${SCRIPT_DIR}/.env"

# 非交互模式检测：stdin 不是终端时启用（如通过 Claude Code Bash 工具运行）
if [ -t 0 ]; then
    INTERACTIVE=true
else
    INTERACTIVE=false
fi

# --- CLI flags ---
# --show-diff: 让 CONFLICT 块包含 DIFF 正文（默认仅元数据）。审计点出问题：
# 非交互模式下 sync.sh 的输出会进入 Claude 会话 transcript 和日志；如果配置文件
# 含密钥/token，diff 也会把那几行带进去。默认只输出文件大小、行数和时间戳，
# 用户在 AskUserQuestion 阶段如需看具体改动，AI 可重跑 sync.sh --show-diff。
SHOW_DIFF=false
_REMAINING_ARGS=()
for _arg in "$@"; do
    case "$_arg" in
        --show-diff) SHOW_DIFF=true ;;
        *) _REMAINING_ARGS+=("$_arg") ;;
    esac
done
set -- "${_REMAINING_ARGS[@]}"
unset _arg _REMAINING_ARGS

# 哪些 dotfiles → ~/.claude 复制需要用户确认（即使本地一开始没有这个文件）：
# 攻击者若拿到 dotfiles GitHub auth，能把 settings.json 的 hooks 字段改成
# 恶意命令，下一次新设备首次 sync 会把这套 hooks 直接落到 ~/.claude/。这些
# 文件直接影响 Claude 的行为，repo→local 一侧导入也走 confirm 流程更稳。
# basename 匹配；本机→远端方向不受此 list 约束（本地内容默认可信）。
SENSITIVE_REPO_TO_LOCAL_BASENAMES=("settings.json" "keybindings.json" "statusline.sh" "CLAUDE.md")
_is_sensitive_basename() {
    local _bn
    _bn=$(basename "$1")
    local _s
    for _s in "${SENSITIVE_REPO_TO_LOCAL_BASENAMES[@]}"; do
        [ "$_bn" = "$_s" ] && return 0
    done
    return 1
}

# --- 首次配置向导 ---
run_first_run_wizard() {
    detect_gh || true  # best-effort: 向导内可能需要 $GH 执行 gh repo create
    echo ""
    echo "========================================"
    echo " CC_Sync 首次配置"
    echo "========================================"
    echo ""

    # 【第 1 步】DOTFILES_PATH
    echo "【第 1 步】请指定 dotfiles 仓库的存放路径"
    echo ""
    echo "  CC_Sync 需要一个 git 仓库来存放你的 Claude Code 配置文件"
    echo "  （settings、skills、hooks、keybindings 等），以便在多台设备间"
    echo "  保持一致的工作环境。这个仓库叫做 dotfiles 仓库。"
    echo ""
    echo "  请输入你希望存放该仓库的路径，例如："
    echo "    C:/dotfiles"
    echo "    E:/config/my-dotfiles"
    echo "  Windows 路径不区分大小写（C:/Dotfiles 和 c:/dotfiles 等效）"
    echo ""

    local dotfiles_path=""
    while true; do
        read -p "路径：" dotfiles_path
        dotfiles_path=$(echo "$dotfiles_path" | tr -d '\r\n')

        # Reject empty
        if [ -z "$dotfiles_path" ]; then
            echo "路径不能为空，请重新输入。"
            continue
        fi

        # 拒绝会破坏 marker 契约的字符：'|' 是 CONFLICT/UNTRACKED 块的字段分隔符；
        # 制表符在 SKILL.md 解析剥 8-空格缩进时位置不稳定。shlex.quote 已经保护
        # source .env 安全，这里挡的是 marker payload 这条下游路径。
        if [[ "$dotfiles_path" == *"|"* ]] || [[ "$dotfiles_path" == *$'\t'* ]]; then
            echo "路径不能包含 '|' 或制表符。请重新输入。"
            continue
        fi

        # Check parent dir exists
        local parent_dir
        parent_dir=$(dirname "$dotfiles_path")
        # Fix drive-letter edge: dirname "C:/foo" → "C:" → "C:/"
        [[ "$parent_dir" =~ ^[A-Za-z]:$ ]] && parent_dir="${parent_dir}/"
        if [ ! -d "$parent_dir" ]; then
            echo ""
            echo "路径无效——父目录不存在，请检查是否拼写有误。"
            echo "  示例：C:/dotfiles、E:/config/my-dotfiles"
            echo ""
            continue
        fi

        # If path exists and has content
        if [ -d "$dotfiles_path" ]; then
            if [ -d "$dotfiles_path/claude-code-config" ] || [ -d "$dotfiles_path/claude" ]; then
                echo ""
                echo "检测到该路径下已有 dotfiles 仓库。"
                read -p "是否使用这个仓库？(y/n) " reuse_choice
                if [[ "$reuse_choice" =~ ^[Yy] ]]; then
                    break
                else
                    echo "请输入其他路径。"
                    echo ""
                    continue
                fi
            fi
            # Path exists but empty or no dotfiles structure — treat as valid
            break
        fi

        # Path doesn't exist: confirm creation
        echo ""
        echo "该路径不存在，将为你创建："
        echo "  - git init $dotfiles_path"
        echo "  - mkdir -p $dotfiles_path/claude"
        echo "  - 尝试在 GitHub 上创建同名仓库"
        echo ""
        read -p "确认创建？(y/n) " create_choice
        if [[ "$create_choice" =~ ^[Yy] ]]; then
            git init "$dotfiles_path"
            mkdir -p "$dotfiles_path/claude"
            # Attempt gh repo create (best-effort)
            local repo_name
            repo_name=$(basename "$dotfiles_path")
            if [ -n "${GH:-}" ] && ([ -x "$GH" ] || command -v "$GH" >/dev/null 2>&1); then
                echo "尝试在 GitHub 创建仓库 $repo_name..."
                "$GH" repo create "$repo_name" --private --source "$dotfiles_path" 2>&1 || echo -e "${YELLOW}GitHub 仓库创建失败，请稍后手动创建。${NC}"
            fi
            break
        else
            echo "请输入其他路径。"
            echo ""
            continue
        fi
    done

    # 【第 2 步】ENABLE_REPO_SYNC
    echo ""
    echo "【第 2 步】是否启用项目仓库批量同步？"
    echo ""
    echo "  除了配置同步，CC_Sync 还可以帮你一键同步所有 GitHub 项目仓库。"
    echo "  如果你的项目已经通过 GitHub 管理，不需要批量同步，可以选择不启用。"
    echo "  以后随时可以开启。"
    echo ""

    local enable_repo="false"
    local ws_roots=""
    local topic=""
    read -p "是否启用？(y/n)：" enable_choice
    if [[ "$enable_choice" =~ ^[Yy] ]]; then
        enable_repo="true"

        # 【第 2a 步】WORKSPACE_ROOTS
        echo ""
        echo "【第 2a 步】你的项目仓库存放在电脑上的哪个文件夹？"
        echo ""
        echo "  例如："
        echo "    D:/Projects"
        echo "    E:/Work;F:/Personal（多个文件夹用英文分号 ; 隔开）"
        echo "  Windows 路径不区分大小写（C:/Dotfiles 和 c:/dotfiles 等效）"
        echo ""
        read -p "请输入路径：" ws_roots
        ws_roots=$(echo "$ws_roots" | tr -d '\r\n')
        # 同 dotfiles_path：'|' 会污染 marker 输出；制表符破坏 8 空格缩进契约
        if [[ "$ws_roots" == *"|"* ]] || [[ "$ws_roots" == *$'\t'* ]]; then
            echo -e "${YELLOW}警告：检测到 '|' 或制表符；这些字符会破坏 sync 输出契约，已剔除。${NC}"
            ws_roots=$(echo "$ws_roots" | tr -d '|\t')
        fi
        # strip 后可能整串为空（用户只输入了 '|'），需要再 fail-fast，否则 .env 写入空 WORKSPACE_ROOTS
        # 而 ENABLE_REPO_SYNC=true，下次 sync 会静默 fall back 到 WORKSPACE_ROOT 默认值
        if [ -z "$ws_roots" ]; then
            echo "剔除非法字符后路径为空，项目仓库同步未启用。如需启用请重新运行向导。"
            enable_repo="false"
        fi

        # 仓库同步真的启用时才追问 TOPIC（被强制关闭后还问 topic 读起来像自相矛盾）
        if [ "$enable_repo" = "true" ]; then
            # 【第 2b 步】TOPIC
            echo ""
            echo "【第 2b 步】你给 GitHub 仓库贴的标签（topic）叫什么？"
            echo ""
            echo "  sync 通过这个标签来发现你想同步的仓库。"
            echo "  如果你还没贴过标签，建议用默认值，直接回车即可。"
            echo ""
            read -p "请输入标签名（回车使用默认值 claude-code-workspace）：" topic
            topic="${topic:-claude-code-workspace}"
        fi
    fi

    # Write .env via Python (UTF-8 safe)
    # 用 shlex.quote 生成 shell-safe 的 single-quoted 形式，防止 source 时
    # $, `, \ 等 shell 元字符被解释执行（例如 DOTFILES_PATH=/tmp$(whoami) 注入）
    python -c "
import shlex, sys
path = sys.argv[1]
with open(path, 'w', encoding='utf-8', newline='\n') as f:
    f.write('# .env — CC_Sync local config (auto-generated, do not commit)\n')
    for i in range(2, len(sys.argv), 2):
        f.write(sys.argv[i] + '=' + shlex.quote(sys.argv[i+1]) + '\n')
" "$(normalize_path "$ENV_FILE")" \
    "DOTFILES_PATH" "$dotfiles_path" \
    "ENABLE_REPO_SYNC" "$enable_repo" \
    "WORKSPACE_ROOTS" "${ws_roots:-}" \
    "TOPIC" "${topic:-claude-code-workspace}"

    echo ""
    echo "========================================"
    echo " 配置已保存到 .env"
    echo "========================================"
    echo ""
    echo "CC_Sync 会同步 settings.json 中的 MCP Server 配置（server 地址、"
    echo "启动参数等），但 MCP Server 本身的运行环境（代码、依赖、运行时）"
    echo "需要你在每台设备上自行安装和管理。"
    echo ""

    # Set runtime variables
    DOTFILES_PATH="$dotfiles_path"
    DOTFILES_DIR="$dotfiles_path"
    DOTFILES_REPO=$(basename "$dotfiles_path")
    ENABLE_REPO_SYNC="$enable_repo"
    WORKSPACE_ROOTS="${ws_roots:-}"
    TOPIC="${topic:-claude-code-workspace}"
}

# --- 启动清理：SIGKILL/断电等非正常退出遗留的 .env 锁目录 ---
# mkdir lock 正常退出会在 trap 中 rmdir；异常死亡则遗留，需手动清理
# 这里在启动时检查：若 lock 目录存在且 mtime 超过 10 分钟，判定为过期孤儿锁，自动清理
_ENV_LOCK_DIR="${ENV_FILE}.lock"
if [ -d "$_ENV_LOCK_DIR" ]; then
    # find 在 Git Bash 下可用；-mmin +10 = 修改时间早于 10 分钟前
    if find "$_ENV_LOCK_DIR" -maxdepth 0 -mmin +10 2>/dev/null | grep -q .; then
        rmdir "$_ENV_LOCK_DIR" 2>/dev/null && \
            echo -e "${YELLOW}[启动] 已清理过期 .env 锁目录（超过 10 分钟未释放，疑似前次非正常退出遗留）${NC}" >&2
    fi
fi
unset _ENV_LOCK_DIR

# --- 启动时：如检测到旧格式 .env（双引号或含 shell 展开字符），就地迁移为 shlex.quote 格式 ---
# 消除 `source .env` 对 $var / backtick / $(...) 的意外展开。原子替换（mkstemp + os.replace）
# 避免半写入；多 token 情况发出 multi= 警告；Python 错误直接经 stderr 暴露（不静默）
_migrate_legacy_env() {
    [ ! -f "$ENV_FILE" ] || python -c "
import os, shlex, sys, re, tempfile
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    lines = f.readlines()
new_lines = []
changed = []
warns = []
multi = []
pat = re.compile(r'^([A-Z_][A-Z0-9_]*)=(.*?)\s*\$')
for line in lines:
    m = pat.match(line.rstrip('\n'))
    if not m:
        new_lines.append(line)
        continue
    key, raw = m.group(1), m.group(2)
    # shlex.split 可解析单引号 / 双引号 / 无引号三种形式
    try:
        tokens = shlex.split(raw) if raw else ['']
    except ValueError:
        # 解析失败（例如未闭合引号）—— 原样保留，不盲目重写
        new_lines.append(line)
        continue
    # 遗留多 token（KEY=a b c 无引号）—— 取首 token 会丢数据，改为保留原行 + 警告
    if len(tokens) > 1:
        multi.append(key)
        new_lines.append(line)
        continue
    value = tokens[0] if tokens else ''
    canonical = key + '=' + shlex.quote(value) + '\n'
    if canonical != line:
        new_lines.append(canonical)
        changed.append(key)
        # 值里含 shell 展开字符，值得额外提示
        if any(c in value for c in ('\$', '\`')):
            warns.append(key)
    else:
        new_lines.append(line)
if changed:
    # 原子替换：先写到同目录临时文件，再 os.replace 覆盖目标 —— 避免半写入
    dirpath = os.path.dirname(os.path.abspath(path)) or '.'
    fd, tmp_path = tempfile.mkstemp(prefix='.env.migrate.', dir=dirpath)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as f:
            f.writelines(new_lines)
        os.replace(tmp_path, path)
    except Exception:
        # 写失败 —— 清理 tempfile，保持原 .env 不变
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
    print('migrated=' + ','.join(changed))
    if warns:
        print('warn=' + ','.join(warns))
if multi:
    # 即使没有重写，仍输出多 token 警告（原行保留，需要用户手动处理）
    print('multi=' + ','.join(multi))
" "$(normalize_path "$ENV_FILE")"
}
if [ -f "$ENV_FILE" ]; then
    _mig_out=$(_migrate_legacy_env)
    if [ -n "$_mig_out" ]; then
        while IFS= read -r _line; do
            case "$_line" in
                migrated=*)
                    echo -e "${YELLOW}[.env 迁移] 已将以下键重写为 shlex.quote 格式：${_line#migrated=}${NC}" >&2
                    ;;
                warn=*)
                    echo -e "${YELLOW}[.env 迁移] 警告：${_line#warn=} 的值含 \$ 或 backtick，原先可能被 source 时展开；现已改为字面量。若你确实需要展开，请手动恢复该行。${NC}" >&2
                    ;;
                multi=*)
                    echo -e "${YELLOW}[.env 迁移] 警告：${_line#multi=} 的原值含多个 token（形如 KEY=a b c），迁移会丢失后续 token，已保留原行。请手动加引号后重新 source。${NC}" >&2
                    ;;
            esac
        done <<< "$_mig_out"
    fi
    unset _mig_out _line
fi

# --- .env 加载或首次引导 ---
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    DOTFILES_DIR="$DOTFILES_PATH"
    DOTFILES_REPO=$(basename "$DOTFILES_PATH")
else
    if [ "$INTERACTIVE" = false ]; then
        echo -e "${RED}错误：.env 配置文件不存在。请在终端中运行 bash sync.sh 完成首次配置。${NC}" >&2
        exit 1
    fi
    run_first_run_wizard
fi

# Fallback: 未通过 .env 配置时使用旧的硬编码值
if [ -z "${DOTFILES_DIR:-}" ]; then
    DOTFILES_REPO="dotfiles"
    DOTFILES_DIR="${WORKSPACE_ROOT}/${DOTFILES_REPO}"
    if [ ! -d "$DOTFILES_DIR" ]; then
        echo -e "${YELLOW}警告：DOTFILES_DIR 未配置且默认路径 ${DOTFILES_DIR} 不存在。请运行 bash sync.sh 重新配置。${NC}" >&2
    fi
fi

CC_HOME="${HOME}/.claude"

# CONFIG_MAP: declarative config file mappings — "repo_subpath|local_path|label"
# 配置文件映射：dotfiles 子路径 | 本地目标 | 显示名
CONFIG_MAP=(
    "claude/CLAUDE.md|${CC_HOME}/CLAUDE.md|CLAUDE.md"
    "claude/settings.json|${CC_HOME}/settings.json|settings.json"
    "claude/modules.toml|${CC_HOME}/skills/modules.toml|modules.toml"
    "claude/keybindings.json|${CC_HOME}/keybindings.json|keybindings.json"
    "claude/statusline.sh|${CC_HOME}/statusline.sh|statusline.sh"
)

# 多路径解析：拆分 ";"，过滤空条目（尾部分号 / 连续分号产生的空串）和重复条目
declare -a WS_ROOTS=()
if [ -n "${WORKSPACE_ROOTS:-}" ]; then
    declare -a _raw_ws=()
    IFS=';' read -ra _raw_ws <<< "$WORKSPACE_ROOTS"
    declare -A _seen_ws=()
    for _r in "${_raw_ws[@]}"; do
        [ -z "$_r" ] && continue
        [ -n "${_seen_ws[$_r]+_}" ] && continue
        _seen_ws["$_r"]=1
        WS_ROOTS+=("$_r")
    done
    unset _raw_ws _seen_ws _r
fi
if [ ${#WS_ROOTS[@]} -eq 0 ] && [ -n "${WORKSPACE_ROOT:-}" ]; then
    WS_ROOTS=("$WORKSPACE_ROOT")
fi

detect_gh || exit 1
detect_github_user || exit 1

HANDOFF_FILE="${SCRIPT_DIR}/HANDOFF.md"
HANDOFF_PY=$(normalize_path "${SCRIPT_DIR}/lib/handoff.py")
HANDOFF_FILE_PY=$(normalize_path "$HANDOFF_FILE")

# --- HANDOFF.md 辅助函数（委托给 lib/handoff.py）---

_handoff() { PYTHONIOENCODING=utf-8 python "$HANDOFF_PY" "$1" "$HANDOFF_FILE_PY" "${@:2}"; }
handoff_section_exists() { _handoff section_exists "$1"; }
handoff_add_section()    { _handoff add_section "$1"; }
handoff_remove_section() { _handoff remove_section "$1"; }
handoff_list_devices()   { _handoff list_devices; }
handoff_get_pending()    { _handoff get_pending "$@"; }
handoff_detect_hidden()  { _handoff detect_hidden; }

# 注册新设备到 HANDOFF.md 并提交推送
register_handoff_device() {
    local device_name="$1"
    if ! handoff_add_section "$device_name"; then
        echo -e "${RED}[register] handoff_add_section 失败，未修改 HANDOFF.md${NC}" >&2
        return 1
    fi
    local _git_output
    if ! _git_output=$(cd "$SCRIPT_DIR" && git add HANDOFF.md && git commit -m "HANDOFF: 新增设备 $device_name" && git push 2>&1); then
        echo -e "${RED}[register] 注册设备 $device_name 时 git 操作失败:${NC}" >&2
        echo "$_git_output" >&2
        return 1
    fi
    echo -e "${GREEN}设备 $device_name 已注册到 HANDOFF.md${NC}"
}

# 从 HANDOFF.md 移除设备并提交推送
unregister_handoff_device() {
    local device_name="$1"
    if ! handoff_remove_section "$device_name"; then
        echo -e "${RED}[unregister] handoff_remove_section 失败，未修改 HANDOFF.md${NC}" >&2
        return 1
    fi
    local _git_output
    if ! _git_output=$(cd "$SCRIPT_DIR" && git add HANDOFF.md && git commit -m "HANDOFF: 移除设备 $device_name" && git push 2>&1); then
        echo -e "${RED}[unregister] 移除设备 $device_name 时 git 操作失败:${NC}" >&2
        echo "$_git_output" >&2
        return 1
    fi
    echo -e "${GREEN}设备 $device_name 已从 HANDOFF.md 移除${NC}"
}

# --- device 子命令 ---
if [ "${1:-}" = "device" ]; then
    subcmd="${2:-}"
    name="${3:-}"

    if [ ! -f "$HANDOFF_FILE" ]; then
        echo -e "${RED}HANDOFF.md 不存在${NC}" >&2
        exit 1
    fi

    require_device_arg() {
        if [ -z "${1:-}" ]; then
            echo "用法: sync.sh device $2 <name>" >&2
            exit 1
        fi
    }

    case "$subcmd" in
        list)
            echo "已注册的设备："
            handoff_list_devices | while read -r dev; do
                if get_machine_name && [ "$MACHINE_NAME" = "$dev" ]; then
                    echo "  $dev  ← 本机"
                else
                    echo "  $dev"
                fi
            done
            ;;
        add)
            require_device_arg "$name" "add"
            if [ "$(handoff_section_exists "$name")" = "yes" ]; then
                echo "设备 $name 已存在于 HANDOFF.md" >&2
                exit 1
            fi
            register_handoff_device "$name" || exit 1
            ;;
        remove)
            require_device_arg "$name" "remove"
            if [ "$(handoff_section_exists "$name")" = "no" ]; then
                echo "设备 $name 不在 HANDOFF.md 中" >&2
                exit 1
            fi
            PENDING=$(handoff_get_pending "$name")
            if [ -n "$PENDING" ]; then
                echo -e "${YELLOW}警告：设备 $name 有未完成的 handoff 任务：${NC}"
                echo "$PENDING"
                read -p "确认移除？(y/n) " CONFIRM
                if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
                    echo "已取消。"
                    exit 0
                fi
            fi
            unregister_handoff_device "$name" || exit 1
            ;;
        *)
            echo "用法: sync.sh device <list|add|remove> [name]"
            exit 1
            ;;
    esac
    exit 0
fi

# --- repo-sync 子命令 ---
if [ "${1:-}" = "repo-sync" ]; then
    subcmd="${2:-}"
    name="${3:-}"

    IGNORE_FILE="${SCRIPT_DIR}/.sync_ignore"

    case "$subcmd" in
        unignore)
            if [ -z "$name" ]; then
                echo "用法: sync.sh repo-sync unignore <repo-name>" >&2
                exit 1
            fi
            if [ ! -f "$IGNORE_FILE" ]; then
                echo ".sync_ignore 文件不存在，没有被忽略的仓库" >&2
                exit 1
            fi
            if ! grep -Fqx "$name" "$IGNORE_FILE" 2>/dev/null; then
                echo "仓库 $name 不在 .sync_ignore 中" >&2
                exit 1
            fi
            # 非原子写：grep > tmp 后 mv 替换。.sync_ignore 不是安全敏感文件
            # （读时 [A-Za-z0-9_.-]+ 正则过滤），且本子命令是手动单次运行，
            # 不在并发关键路径上 —— 引入 mkstemp+os.replace 的复杂度不值
            # grep exit codes: 0=有匹配 / 1=无匹配（这里 = 文件被全部过滤空，合法）/ 2=I/O 错误。
            # sync.sh 没开 set -e，所以 grep 返 rc=1 不会让脚本中断；直接捕获 $? 即可。
            # 不要用 `|| true` + PIPESTATUS：PIPESTATUS 在 `|| true` 后反映的是 true 的 rc=0，
            # 区分 1 vs 2 失效。
            grep -Fvx "$name" "$IGNORE_FILE" > "${IGNORE_FILE}.tmp"
            _grep_rc=$?
            if [ "$_grep_rc" -gt 1 ]; then
                rm -f "${IGNORE_FILE}.tmp"
                echo -e "${RED}写入临时文件失败${NC}" >&2
                exit 1
            fi
            if ! mv "${IGNORE_FILE}.tmp" "$IGNORE_FILE"; then
                rm -f "${IGNORE_FILE}.tmp"
                echo -e "${RED}替换 .sync_ignore 失败${NC}" >&2
                exit 1
            fi
            echo -e "${GREEN}已从 .sync_ignore 中移除 $name${NC}"
            ;;
        enable)
            if [ ! -f "$ENV_FILE" ]; then
                echo ".env 文件不存在，请先运行 bash sync.sh 完成首次配置" >&2
                exit 1
            fi
            # .env 已在脚本启动早期 source（line ~290），变量已就绪
            if [ "${ENABLE_REPO_SYNC:-false}" = "true" ]; then
                echo "项目仓库同步已启用，无需操作"
                exit 0
            fi
            echo ""
            echo "启用项目仓库批量同步"
            echo ""
            read -p "$(printf '你的项目仓库存放在电脑上的哪个文件夹？\n\n  例如：\n    D:/Projects\n    E:/Work;F:/Personal（多个文件夹用英文分号 ; 隔开）\n\n请输入路径：')" ws_roots
            ws_roots=$(echo "$ws_roots" | tr -d '\r\n')
            if [ -z "$ws_roots" ]; then
                echo "路径不能为空" >&2
                exit 1
            fi
            # marker 契约保护：见 wizard 同款注释
            if [[ "$ws_roots" == *"|"* ]] || [[ "$ws_roots" == *$'\t'* ]]; then
                echo -e "${YELLOW}警告：检测到 '|' 或制表符；这些字符会破坏 sync 输出契约，已剔除。${NC}" >&2
                ws_roots=$(echo "$ws_roots" | tr -d '|\t')
            fi
            # strip 后再 fail-fast：用户只输入 '|' 等非法字符时不能写空 WORKSPACE_ROOTS
            if [ -z "$ws_roots" ]; then
                echo -e "${RED}剔除非法字符后路径为空${NC}" >&2
                exit 1
            fi
            read -p "$(printf '你给 GitHub 仓库贴的标签（topic）叫什么？\n（回车使用默认值 claude-code-workspace）：')" topic
            topic="${topic:-claude-code-workspace}"
            # Update .env via Python (with mkdir-based lock)
            _lockdir="${ENV_FILE}.lock"
            if ! mkdir "$_lockdir" 2>/dev/null; then
                echo -e "${RED}另一个 sync.sh 正在修改 .env，请稍后再试${NC}" >&2
                echo -e "${YELLOW}（若确认无其他进程，手动清理残留锁目录：rmdir \"${ENV_FILE}.lock\"）${NC}" >&2
                exit 1
            fi
            trap 'rmdir "'"$_lockdir"'" 2>/dev/null' EXIT INT TERM
            python -c "
import os, shlex, sys, tempfile
env_path = sys.argv[1]
ws = sys.argv[2]
tp = sys.argv[3]
with open(env_path, 'r', encoding='utf-8') as f:
    lines = f.readlines()
enable_found = False
ws_found = False
tp_found = False
out_lines = []
# shlex.quote 生成 single-quoted 形式，禁止 source .env 时展开 \$/backtick/\\
for line in lines:
    if line.startswith('ENABLE_REPO_SYNC='):
        out_lines.append('ENABLE_REPO_SYNC=' + shlex.quote('true') + '\n')
        enable_found = True
    elif line.startswith('WORKSPACE_ROOTS='):
        out_lines.append('WORKSPACE_ROOTS=' + shlex.quote(ws) + '\n')
        ws_found = True
    elif line.startswith('TOPIC='):
        out_lines.append('TOPIC=' + shlex.quote(tp) + '\n')
        tp_found = True
    else:
        out_lines.append(line)
if not enable_found:
    out_lines.append('ENABLE_REPO_SYNC=' + shlex.quote('true') + '\n')
if not ws_found:
    out_lines.append('WORKSPACE_ROOTS=' + shlex.quote(ws) + '\n')
if not tp_found:
    out_lines.append('TOPIC=' + shlex.quote(tp) + '\n')
# 原子替换：先写 tempfile 再 os.replace，避免半写入（与 _migrate_legacy_env / _append_workspace_root 一致）
dirpath = os.path.dirname(os.path.abspath(env_path)) or '.'
fd, tmp_path = tempfile.mkstemp(prefix='.env.enable.', dir=dirpath)
try:
    with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as f:
        f.writelines(out_lines)
    os.replace(tmp_path, env_path)
except Exception:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise
" "$(normalize_path "$ENV_FILE")" "$ws_roots" "$topic"
            _py_rc=$?
            if [ $_py_rc -ne 0 ]; then
                rmdir "$_lockdir" 2>/dev/null
                trap - EXIT INT TERM
                echo -e "${RED}写入 .env 失败 (python rc=$_py_rc)${NC}" >&2
                exit 1
            fi
            rmdir "$_lockdir" 2>/dev/null
            trap - EXIT INT TERM
            # Reset hint counter
            rm -f "${SCRIPT_DIR}/.repo_sync_hint_count"
            echo -e "${GREEN}已启用项目仓库同步！下次运行 sync 时将自动发现并同步仓库。${NC}"
            ;;
        *)
            echo "用法:"
            echo "  sync.sh repo-sync enable                     启用项目仓库批量同步（交互向导）"
            echo "  sync.sh repo-sync unignore <repo-name>       从 .sync_ignore 移除指定仓库"
            exit 1
            ;;
    esac
    exit 0
fi

# 在多个 workspace root 中查找仓库目录（step 2 memory 同步 + step 3 均需要）
_find_repo_dir() {
    local repo_name="$1"
    local root
    for root in "${WS_ROOTS[@]}"; do
        if [ -d "${root}/${repo_name}" ]; then
            echo "${root}/${repo_name}"
            return 0
        fi
    done
    return 1
}

# 结果记录
declare -a RESULTS
HAS_ERROR=0

# 并行处理用的临时目录
SYNC_TMPDIR=$(safe_mktemp)
# safe_mktemp 静默 fallback 后仍可能返回空串；空串下 rm -rf "" 在 GNU 是 no-op，
# 在 BSD/macOS 行为不一致，先 fail-fast 比留 EXIT 陷阱兜底更稳妥
if [ -z "$SYNC_TMPDIR" ] || [ ! -d "$SYNC_TMPDIR" ]; then
    echo -e "${RED}错误：无法创建临时目录${NC}" >&2
    exit 1
fi
trap 'rm -rf "$SYNC_TMPDIR"' EXIT

echo "========================================="
echo " Claude Code Workspace Sync"
echo "========================================="

# --- 第 1 步：发现仓库 ---
echo ""
echo "[1/6] 发现仓库..."

declare -A KNOWN_REPOS
declare -A REPO_URLS

if [ "${ENABLE_REPO_SYNC:-false}" != "true" ]; then
    # Config-only mode: only find dotfiles repo
    if ! REPOS_JSON=$("$GH" repo list "$GITHUB_USER" --json name,url --limit 1000 2>/dev/null); then
        echo -e "${RED}错误：无法获取仓库列表。${NC}" >&2
        exit 1
    fi
    REPOS=$(python -c "
import json, sys
name = sys.argv[1]
data = json.loads(sys.stdin.read())
for repo in data:
    if repo['name'] == name:
        print(repo['name'] + '|' + repo['url'])
        break
" "$DOTFILES_REPO" <<< "$REPOS_JSON" | tr -d '\r')

    if [ -z "$REPOS" ]; then
        echo -e "${YELLOW}未找到 dotfiles 仓库 ($DOTFILES_REPO)。${NC}"
    else
        echo "已定位 dotfiles 仓库"
    fi
    while IFS='|' read -r name url; do
        [ -z "$name" ] && continue
        KNOWN_REPOS["$name"]=1
        REPO_URLS["$name"]="$url"
    done <<< "$REPOS"
else
    # Full mode: discover all repos with topic
    if ! REPOS_JSON=$("$GH" repo list "$GITHUB_USER" --json name,url,repositoryTopics --limit 1000 2>/dev/null); then
        echo -e "${RED}错误：无法获取仓库列表。请检查 gh auth 状态。${NC}" >&2
        exit 1
    fi

    # 读取 .sync_ignore（永久忽略的仓库列表）
    IGNORE_FILE="${SCRIPT_DIR}/.sync_ignore"
    IGNORED_LIST=""
    N_IGNORED=0
    if [ -f "$IGNORE_FILE" ]; then
        # 第三轮过滤：只保留符合 GitHub repo 名规范的行（字母/数字/下划线/连字符/点）。
        # 防御一个被篡改的 .sync_ignore（如远端被攻击）混入控制字符或路径分隔符
        IGNORED_LIST=$(grep -v '^[[:space:]]*#' "$IGNORE_FILE" | grep -v '^[[:space:]]*$' \
            | tr -d '\r' | grep -E '^[A-Za-z0-9_.-]+$' || true)
        if [ -n "$IGNORED_LIST" ]; then
            N_IGNORED=$(echo "$IGNORED_LIST" | wc -l | tr -d ' ')
        fi
    fi

    # 筛选带有指定 topic 的仓库（用 python 解析 JSON，因为 Git Bash 没有 jq）
    REPOS=$(TOPIC="$TOPIC" IGNORED_REPOS="$IGNORED_LIST" python -c "
import json, os, sys
topic = os.environ['TOPIC']
ignored = set(line for line in os.environ.get('IGNORED_REPOS', '').split('\n') if line)
data = json.loads(sys.stdin.read())
for repo in data:
    if repo['name'] in ignored:
        continue
    topics = [t['name'] for t in (repo.get('repositoryTopics') or [])]
    if topic in topics:
        print(repo['name'] + '|' + repo['url'])
" <<< "$REPOS_JSON" | tr -d '\r')

    if [ "$N_IGNORED" -gt 0 ]; then
        echo "  （已跳过 ${N_IGNORED} 个被忽略的仓库，见 .sync_ignore）"
    fi

    if [ -z "$REPOS" ]; then
        echo -e "${YELLOW}未发现任何带有 ${TOPIC} topic 的仓库。${NC}"
        echo -e "${YELLOW}→ 若 dotfiles 仓库缺 topic：gh repo edit ${GITHUB_USER}/${DOTFILES_REPO} --add-topic ${TOPIC}${NC}"
        echo "（仍将继续执行 [2/6] 配置同步，[3/6] 项目同步会因无可同步仓库自动跳过）"
        REPO_COUNT=0
    else
        REPO_COUNT=$(echo "$REPOS" | wc -l)
        echo "发现 ${REPO_COUNT} 个仓库"

        # --- 孤儿目录检测：找出本地存在但未纳入 GitHub 同步的目录 ---
        while IFS='|' read -r name url; do
            [ -z "$name" ] && continue
            KNOWN_REPOS["$name"]=1
            REPO_URLS["$name"]="$url"
        done <<< "$REPOS"
    fi

    # 当 dotfiles 仓库未出现在 topic 结果里（例如用户没给它打 topic），
    # 按仓库名精确匹配做一次兜底，保证 [2/6] 配置同步仍能运行（即使 full 模式下也适用）
    # 用 function 隔离局部变量，避免 _dotfiles_lookup/_dn/_du 泄漏到脚本顶层作用域
    _fallback_dotfiles_lookup() {
        local lookup dn du
        if [ -n "${KNOWN_REPOS[$DOTFILES_REPO]+_}" ]; then
            return 0  # 已发现，无需兜底
        fi
        lookup=$(python -c "
import json, sys
name = sys.argv[1]
data = json.loads(sys.stdin.read())
for repo in data:
    if repo['name'] == name:
        print(repo['name'] + '|' + repo['url'])
        break
" "$DOTFILES_REPO" <<< "$REPOS_JSON" 2>/dev/null | tr -d '\r' || true)
        if [ -n "$lookup" ]; then
            IFS='|' read -r dn du <<< "$lookup"
            KNOWN_REPOS["$dn"]=1
            REPO_URLS["$dn"]="$du"
            echo "（按名称兜底定位到 dotfiles 仓库 ${dn}）"
        fi
    }
    _fallback_dotfiles_lookup

    # 孤儿目录检测：有远端仓库列表时才做（没有的话没对比基准）
    if [ -n "$REPOS" ]; then
        ORPHAN_FOUND=0
        for ws_root in "${WS_ROOTS[@]}"; do
            for DIR in "${ws_root}"/*/; do
                [ ! -d "$DIR" ] && continue
                DIR_NAME=$(basename "$DIR")
                [[ "$DIR_NAME" == .* ]] && continue
                [ "${KNOWN_REPOS[$DIR_NAME]+_}" ] && continue

                if [ $ORPHAN_FOUND -eq 0 ]; then
                    echo ""
                    echo -e "${YELLOW}⚠ 检测到未纳入同步的本地目录：${NC}"
                    ORPHAN_FOUND=1
                fi

                if [ -d "$DIR/.git" ]; then
                    echo -e "${YELLOW}  - ${DIR_NAME}/ （在 ${ws_root}，是 git 仓库，但 GitHub 仓库缺少 ${TOPIC} topic）${NC}"
                    echo -e "${YELLOW}    → gh repo edit ${GITHUB_USER}/${DIR_NAME} --add-topic ${TOPIC}${NC}"
                else
                    echo -e "${YELLOW}  - ${DIR_NAME}/ （在 ${ws_root}，不是 git 仓库）${NC}"
                    echo -e "${YELLOW}    → 需要 git init + 创建 GitHub 仓库 + 添加 ${TOPIC} topic${NC}"
                fi
            done
        done

        if [ $ORPHAN_FOUND -eq 1 ]; then
            echo ""
        fi
    fi
fi

# --- add + commit + push 统一函数 ---
# 用法: sync_commit_push <label>
# 前提: 当前目录已是目标仓库
# 注意: HAS_ERROR 赋值仅在主进程中生效，子进程中请用 touch .error 文件
sync_commit_push() {
    local label="$1"
    git add -A -- ':!**/*.bak'
    if ! git commit -m "sync: auto commit from $(hostname)"; then
        echo -e "${RED}${label} commit 失败${NC}" >&2
        HAS_ERROR=1
        return 1
    fi
    if ! git push 2>&1; then
        echo -e "${RED}${label} push 失败${NC}" >&2
        HAS_ERROR=1
        return 1
    fi
    return 0
}

# --- 单向同步辅助函数 ---
# 返回非零表示复制失败，调用方应避免再 CFG_SYNCED++
_sync_one_way() {
    local src="$1" dst="$2" label="$3" arrow="$4"
    if ! mkdir -p "$(dirname "$dst")" 2>/dev/null; then
        echo -e "  ${RED}✗${NC} ${label}: 无法创建目录 $(dirname "$dst")"
        return 1
    fi
    if ! cp "$src" "$dst" 2>/dev/null; then
        echo -e "  ${RED}✗${NC} ${label}: cp 失败 $src → $dst"
        return 1
    fi
    echo -e "  ${arrow} ${label}"
    return 0
}

# --- 归一化等价比较：用于 memory 文件忽略 CC harness 自动写入的 originSessionId ---
# Usage: _files_equivalent <file_a> <file_b> [norm_mode]
#   norm_mode 为空 → 字节级比较（等价于 cmp -s）
#   norm_mode = "memory" → 剥离 originSessionId 行 + frontmatter 闭合 --- 后的那一空行再比较，
#       消除 CC 升级后 harness 自动写入 provenance 字段引发的 spurious 冲突。
# 返回 0 表示等价（跳过同步），非 0 表示真差异（进入冲突流程）。
_files_equivalent() {
    local A="$1" B="$2" NORM="${3:-}"
    if [ -z "$NORM" ]; then
        cmp -s "$A" "$B"
        return
    fi
    local A_PY B_PY
    A_PY=$(normalize_path "$A")
    B_PY=$(normalize_path "$B")
    # -I (isolated mode): drops CWD from sys.path so an attacker-placed
    # re.py / sys.py in the dotfiles repo (CWD here is $DOTFILES_DIR via
    # the pushd in step 2) cannot shadow stdlib imports.
    python -I -c "
import sys, re
def load(p):
    with open(p, 'r', encoding='utf-8') as f:
        return f.read()
def norm_memory(t):
    t = re.sub(r'^originSessionId:[^\n]*\n?', '', t, flags=re.MULTILINE)
    t = re.sub(r'^(---\n.*?\n---\n)\n', r'\1', t, count=1, flags=re.DOTALL)
    return t
a, b = load(sys.argv[1]), load(sys.argv[2])
if sys.argv[3] == 'memory':
    a, b = norm_memory(a), norm_memory(b)
sys.exit(0 if a == b else 1)
" "$A_PY" "$B_PY" "$NORM"
}

# --- Smart sync function: compare content + resolve direction ---
# Usage: sync_config_file <repo_file> <local_file> <label> [norm_mode]
#   norm_mode (optional) forwarded to _files_equivalent — currently only "memory"
#   is recognized; other callers omit it for byte-level comparison.
#
# Branch logic:
#   1. Neither exists        → skip
#   2. Only local exists     → copy local → repo
#   3. Only repo exists      → copy repo → local
#   4. Both exist, same      → skip (no diff)
#   5. Both exist, different → CONFLICT
#      - Interactive:     show diff + timestamps, prompt r/l/s
#      - Non-interactive: emit ===CONFLICT_BEGIN/END=== block, default skip
#                         (format consumed by .claude/skills/sync/SKILL.md)
sync_config_file() {
    local REPO_FILE="$1"
    local LOCAL_FILE="$2"
    local LABEL="$3"
    local NORM="${4:-}"

    # 只有一边存在：复制到另一边
    if [ ! -f "$REPO_FILE" ] && [ ! -f "$LOCAL_FILE" ]; then return; fi
    if [ ! -f "$REPO_FILE" ] && [ -f "$LOCAL_FILE" ]; then
        if _sync_one_way "$LOCAL_FILE" "$REPO_FILE" "$LABEL: 本地新增，同步到仓库" "${GREEN}→${NC}"; then
            CFG_SYNCED=$((CFG_SYNCED+1))
        else
            # 文件系统/权限错误不是内容冲突，走 CFG_FAIL 桶而非 CFG_CONFLICT
            CFG_FAIL=$((CFG_FAIL+1))
            HAS_ERROR=1
        fi
        return
    fi
    if [ -f "$REPO_FILE" ] && [ ! -f "$LOCAL_FILE" ]; then
        # 敏感文件（settings.json / keybindings.json / statusline.sh / CLAUDE.md）
        # 的 repo→local 一侧导入需要用户显式同意：被篡改的 dotfiles 可借此把
        # 恶意 hooks/keybinding/statusline 落到新设备 ~/.claude/。其它配置文件
        # 维持自动复制不变以保证新机首次 sync 体验。
        if _is_sensitive_basename "$LOCAL_FILE"; then
            local REPO_LINES REPO_TIME
            REPO_LINES=$(wc -l < "$REPO_FILE" 2>/dev/null | tr -d ' ' || echo "?")
            REPO_TIME=$(date -r "$REPO_FILE" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
            if [ "$INTERACTIVE" = true ]; then
                echo -e "  ${YELLOW}!${NC} $LABEL: 本地不存在，dotfiles 中有该文件（${REPO_LINES} 行，${REPO_TIME}）"
                echo "    本文件控制 Claude 行为，新设备首次导入也需要你确认。"
                read -p "    导入到 ${LOCAL_FILE}？(y/N): " _IMP
                case "$_IMP" in
                    y|Y)
                        if _sync_one_way "$REPO_FILE" "$LOCAL_FILE" "$LABEL: 已导入" "${GREEN}←${NC}"; then
                            CFG_SYNCED=$((CFG_SYNCED+1))
                        else
                            CFG_FAIL=$((CFG_FAIL+1)); HAS_ERROR=1
                        fi
                        ;;
                    *)
                        echo "    已跳过，本地保持空缺。"
                        CFG_CONFLICT=$((CFG_CONFLICT+1))
                        ;;
                esac
            else
                # 非交互：emit IMPORT 块，由 SKILL.md 调 AskUserQuestion 决策
                echo "===IMPORT_BEGIN==="
                echo "LABEL: $LABEL"
                echo "REPO: $REPO_FILE"
                echo "LOCAL: $LOCAL_FILE"
                echo "REPO_TIME: $REPO_TIME"
                echo "REPO_LINES: $REPO_LINES"
                echo "REASON: sensitive (controls Claude behavior — confirm before importing)"
                echo "===IMPORT_END==="
                CFG_CONFLICT=$((CFG_CONFLICT+1))
            fi
            return
        fi
        if _sync_one_way "$REPO_FILE" "$LOCAL_FILE" "$LABEL: 仓库新增，同步到本地" "${GREEN}←${NC}"; then
            CFG_SYNCED=$((CFG_SYNCED+1))
        else
            CFG_FAIL=$((CFG_FAIL+1))
            HAS_ERROR=1
        fi
        return
    fi

    # 两边都存在：比较内容（memory 模式会忽略 originSessionId 元数据差异）
    if _files_equivalent "$REPO_FILE" "$LOCAL_FILE" "$NORM"; then
        echo "  = $LABEL: 无差异"
        CFG_SKIPPED=$((CFG_SKIPPED+1))
        return
    fi

    # Content differs — compute shared metadata, then branch by mode
    local REPO_TIME LOCAL_TIME DIFF_OUTPUT
    # date -r: works on macOS/BSD and Git Bash; falls back to "unknown" on minimal Linux
    REPO_TIME=$(date -r "$REPO_FILE" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
    LOCAL_TIME=$(date -r "$LOCAL_FILE" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
    # 让 diff 自己判定是否是二进制（对真正的二进制文件，diff 输出 "Binary files X
    # and Y differ"，单行且安全）。此前的 NUL-byte 启发式误判 UTF-16 文本为二进制，
    # 已在 experience.md entry 1 记录；改用 diff 原生检测消除该类误报。
    # 用 timeout 10s 为病态输入（如单行几十 MB 的压缩 JSON）设上限，防 OOM
    # head -50：足够大的预览，多数 conflict 都能完整显示；超出时 SKILL.md 端会
    # 看到截断的 hunk，可接受 —— 增加上限基本免费，UX 提升明显
    DIFF_OUTPUT=$(timeout 10s diff --unified=1 "$REPO_FILE" "$LOCAL_FILE" 2>/dev/null | head -50 || true)

    if [ "$INTERACTIVE" = true ]; then
        # Interactive mode: human-readable output + prompt
        echo -e "  ${YELLOW}!${NC} $LABEL: repo 和本地内容不同"
        echo "    （diff 中 '-' 开头的行为 repo 版本，'+' 开头的行为 local 版本）"
        echo "$DIFF_OUTPUT"
        echo ""
        echo "    Repo:  $REPO_TIME"
        echo "    Local: $LOCAL_TIME"
        echo ""
        read -p "    选择: (r)epo 优先 / (l)ocal 优先 / (s)kip 下次再问 [s]: " CHOICE
    else
        # Non-interactive mode (Claude Code): structured conflict block
        # Format consumed by SKILL.md → AskUserQuestion flow
        # Do not change field names or delimiters without updating SKILL.md
        # DIFF payload is suppressed by default — the audit flagged that the
        # full diff goes into Claude's conversation transcript and any logs
        # the CLI captures, which would expose any token/password that happened
        # to appear in or near the diffed lines. Default emits only metadata
        # (line counts, timestamps). When the user explicitly asks to see the
        # diff, AI re-runs `bash sync.sh --show-diff` to populate the DIFF
        # section for that session.
        local REPO_LINES LOCAL_LINES
        REPO_LINES=$(wc -l < "$REPO_FILE" 2>/dev/null | tr -d ' ' || echo "?")
        LOCAL_LINES=$(wc -l < "$LOCAL_FILE" 2>/dev/null | tr -d ' ' || echo "?")
        echo "===CONFLICT_BEGIN==="
        echo "LABEL: $LABEL"
        echo "REPO: $REPO_FILE"
        echo "LOCAL: $LOCAL_FILE"
        echo "REPO_TIME: $REPO_TIME"
        echo "LOCAL_TIME: $LOCAL_TIME"
        echo "REPO_LINES: $REPO_LINES"
        echo "LOCAL_LINES: $LOCAL_LINES"
        if [ "$SHOW_DIFF" = true ]; then
            echo "DIFF:"
            echo "        (lines starting with '-' show the REPO version; lines with '+' show the LOCAL version)"
            echo "$DIFF_OUTPUT" | sed 's/^/        /'
        else
            echo "DIFF_SUPPRESSED: true  # re-run with --show-diff to populate DIFF section"
        fi
        echo "===CONFLICT_END==="
        CHOICE="s"  # Default skip; AI resolves via AskUserQuestion
    fi
    case "$CHOICE" in
        r|R)
            cp "$LOCAL_FILE" "${LOCAL_FILE}.bak"
            cp "$REPO_FILE" "$LOCAL_FILE"
            echo -e "  ${GREEN}←${NC} $LABEL: 使用 repo 版本 (本地已备份 .bak)"
            CFG_SYNCED=$((CFG_SYNCED+1))
            ;;
        l|L)
            cp "$REPO_FILE" "${REPO_FILE}.bak"
            cp "$LOCAL_FILE" "$REPO_FILE"
            echo -e "  ${GREEN}→${NC} $LABEL: 使用本地版本 (repo 已备份 .bak)"
            CFG_SYNCED=$((CFG_SYNCED+1))
            ;;
        *)
            echo -e "  ${NC}  $LABEL: 已跳过 (无修改)"
            CFG_CONFLICT=$((CFG_CONFLICT+1))
            ;;
    esac
}

# --- Memory 目录同步：CC hash 路径 ↔ dotfiles/claude/projects/<仓库名>/memory/ ---
sync_memory_dir() {
    local REPO_DIR="$1"
    local REPO_NAME="$2"

    local CC_HASH
    CC_HASH=$(compute_cc_hash "$REPO_DIR")

    local CC_PROJECT_DIR="${HOME}/.claude/projects/${CC_HASH}"
    [ ! -d "$CC_PROJECT_DIR" ] && return 1

    local DOTFILES_MEMORY="${DOTFILES_DIR}/claude/projects/${REPO_NAME}/memory"
    local CC_MEMORY="${CC_PROJECT_DIR}/memory"

    # find 对不存在的目录直接跳过，无需预检查
    local ALL_FILES
    ALL_FILES=$(
        find "$DOTFILES_MEMORY" "$CC_MEMORY" -maxdepth 1 -name "*.md" -exec basename {} \; 2>/dev/null
    )
    ALL_FILES=$(echo "$ALL_FILES" | sort -u)

    [ -z "$ALL_FILES" ] && return 1

    mkdir -p "$DOTFILES_MEMORY" "$CC_MEMORY"
    echo "  ${REPO_NAME}:"

    while IFS= read -r filename; do
        [ -z "$filename" ] && continue
        sync_config_file "${DOTFILES_MEMORY}/${filename}" "${CC_MEMORY}/${filename}" "    ${filename}" "memory"
    done <<< "$ALL_FILES"
    return 0
}

# --- 全局 rules 同步：~/.claude/rules/ ↔ dotfiles ---
sync_rules_dir() {
    local DOTFILES_RULES="${DOTFILES_DIR}/claude/rules"
    local CC_RULES="${HOME}/.claude/rules"

    local ALL_FILES
    ALL_FILES=$(
        find "$DOTFILES_RULES" "$CC_RULES" -maxdepth 1 -name "*.md" -exec basename {} \; 2>/dev/null
    )
    ALL_FILES=$(echo "$ALL_FILES" | sort -u)

    [ -z "$ALL_FILES" ] && return 1

    mkdir -p "$DOTFILES_RULES" "$CC_RULES"

    while IFS= read -r filename; do
        [ -z "$filename" ] && continue
        sync_config_file "${DOTFILES_RULES}/${filename}" "${CC_RULES}/${filename}" "  ${filename}"
    done <<< "$ALL_FILES"
    return 0
}

# --- 自制全局 skill 同步：modules.toml 外的 skill ↔ dotfiles ---
sync_custom_skills() {
    local DOTFILES_SKILLS="${DOTFILES_DIR}/claude/skills"
    local LOCAL_SKILLS="${HOME}/.claude/skills"
    local MANIFEST="${LOCAL_SKILLS}/modules.toml"
    local MANIFEST_PY
    MANIFEST_PY=$(normalize_path "$MANIFEST")

    # Step A: 从 modules.toml 提取第三方 skill 名列表
    local MANAGED_SKILLS=""
    if [ -f "$MANIFEST" ]; then
        MANAGED_SKILLS=$(python -c "
import sys, re
with open(sys.argv[1], encoding='utf-8') as f:
    text = f.read()
for m in re.findall(r'\[modules\.([^\]]+)\]', text):
    m = m.strip('\"')
    if '.' not in m:
        print(m)
" "$MANIFEST_PY" 2>/dev/null || true)
    fi

    # Step B: 收集双方的自制 skill 名（排除第三方 + modules.toml 文件本身）
    # 用数组先收集，再用换行拼成字符串 —— 避免 printf '%s\n%s' 的初始空字符串
    # 导致前导 \n 的中间脏态（虽然后续 sed '/^$/d' 会清掉，但避免依赖副作用）
    local -a CUSTOM_NAMES=()

    # 本地侧：~/.claude/skills/ 中不在 modules.toml 里的目录
    if [ -d "$LOCAL_SKILLS" ]; then
        for d in "$LOCAL_SKILLS"/*/; do
            [ ! -d "$d" ] && continue
            local name
            name=$(basename "$d")
            if ! echo "$MANAGED_SKILLS" | grep -Fqx "$name"; then
                CUSTOM_NAMES+=("$name")
            fi
        done
    fi

    # dotfiles 侧：dotfiles/claude/skills/ 中的目录（排除 modules.toml 管理的）
    if [ -d "$DOTFILES_SKILLS" ]; then
        for d in "$DOTFILES_SKILLS"/*/; do
            [ ! -d "$d" ] && continue
            local name
            name=$(basename "$d")
            if ! echo "$MANAGED_SKILLS" | grep -Fqx "$name"; then
                CUSTOM_NAMES+=("$name")
            fi
        done
    fi

    # 去重排序（printf 分隔每个元素一行，再 sort -u）
    local ALL_CUSTOM=""
    if [ ${#CUSTOM_NAMES[@]} -gt 0 ]; then
        ALL_CUSTOM=$(printf '%s\n' "${CUSTOM_NAMES[@]}" | sort -u)
    fi

    # 显示已管理 skill 摘要
    local MANAGED_COUNT=0
    if [ -n "$MANAGED_SKILLS" ]; then
        MANAGED_COUNT=$(echo "$MANAGED_SKILLS" | wc -l | tr -d ' ')
    fi
    [ "$MANAGED_COUNT" -gt 0 ] && echo "  (跳过 ${MANAGED_COUNT} 个已管理 skill，由 module-manager 管理)"
    [ -z "$ALL_CUSTOM" ] && return

    mkdir -p "$DOTFILES_SKILLS"

    # Step C: 对每个自制 skill，双向逐文件同步
    while IFS= read -r skill_name; do
        [ -z "$skill_name" ] && continue
        local dotfiles_skill="${DOTFILES_SKILLS}/${skill_name}"
        local local_skill="${LOCAL_SKILLS}/${skill_name}"

        echo "  ${skill_name}/:"

        # 合并两侧文件列表（排除 __pycache__、.pyc）
        local ALL_FILES=""
        if [ -d "$dotfiles_skill" ]; then
            ALL_FILES=$(cd "$dotfiles_skill" && find . -type f \
                ! -path '*/__pycache__/*' ! -name '*.pyc' | sed 's|^\./||')
        fi
        if [ -d "$local_skill" ]; then
            local LOCAL_FILES
            LOCAL_FILES=$(cd "$local_skill" && find . -type f \
                ! -path '*/__pycache__/*' ! -name '*.pyc' | sed 's|^\./||')
            ALL_FILES=$(printf '%s\n%s' "$ALL_FILES" "$LOCAL_FILES")
        fi
        ALL_FILES=$(echo "$ALL_FILES" | sort -u | sed '/^$/d')

        [ -z "$ALL_FILES" ] && continue

        while IFS= read -r rel_path; do
            [ -z "$rel_path" ] && continue
            sync_config_file "${dotfiles_skill}/${rel_path}" "${local_skill}/${rel_path}" "    ${rel_path}"
        done <<< "$ALL_FILES"
    done <<< "$ALL_CUSTOM"
}

# --- Plugin 缺失检测：settings.json enabledPlugins vs installed_plugins.json ---
check_missing_plugins() {
    local SETTINGS_FILE="${HOME}/.claude/settings.json"
    local INSTALLED_FILE="${HOME}/.claude/plugins/installed_plugins.json"
    local SETTINGS_PY INSTALLED_PY
    SETTINGS_PY=$(normalize_path "$SETTINGS_FILE")
    INSTALLED_PY=$(normalize_path "$INSTALLED_FILE")

    [ ! -f "$SETTINGS_FILE" ] && return 0

    local MISSING
    MISSING=$(PYTHONIOENCODING=utf-8 python -c "
import json, sys

settings_path = sys.argv[1]
installed_path = sys.argv[2]

try:
    with open(settings_path, encoding='utf-8') as f:
        settings = json.load(f)
except Exception as e:
    # 解析失败时不静默退出 —— 让用户知道 plugin 检测被跳过了
    print(f'warn: check_missing_plugins skipped — settings.json parse failed: {e}', file=sys.stderr)
    sys.exit(0)

enabled = settings.get('enabledPlugins') or {}
marketplaces = settings.get('extraKnownMarketplaces') or {}
# 类型守卫：CC settings schema 演化后这两键若变成 list/string，下面 .items() / .get() 会崩
# 既然类型不对就当成"什么都没启用"处理，让 plugin 检测安静返回而不是给个 AttributeError
if not isinstance(enabled, dict):
    enabled = {}
if not isinstance(marketplaces, dict):
    marketplaces = {}

try:
    with open(installed_path, encoding='utf-8') as f:
        installed = json.load(f)
    installed_keys = set((installed.get('plugins') or {}).keys())
except Exception:
    installed_keys = set()

missing = []
for plugin_id, is_enabled in enabled.items():
    if not is_enabled:
        continue
    if plugin_id in installed_keys:
        continue
    # plugin_id format: name@marketplace
    parts = plugin_id.split('@', 1)
    if len(parts) != 2:
        continue
    name, mkt = parts
    # 用 `or {}`：JSON 显式 null 时 .get(k, default) 仍返回 None，后续 .get 会抛
    # AttributeError 中断 missing 收集，导致 plugin 检测结果截断（假阴性）
    mkt_info = marketplaces.get(mkt) or {}
    source = mkt_info.get('source') or {}
    repo = source.get('repo') or ''
    missing.append(f'{plugin_id}|{repo}')

for m in missing:
    print(m)
" "$SETTINGS_PY" "$INSTALLED_PY")

    [ -z "$MISSING" ] && return 0

    echo ""
    echo -e "${YELLOW}检测到未安装的插件：${NC}"
    local INSTALL_CMDS=""
    while IFS='|' read -r plugin_id mkt_repo; do
        [ -z "$plugin_id" ] && continue
        local mkt="${plugin_id#*@}"
        if [ -n "$mkt_repo" ]; then
            echo -e "  ${YELLOW}!${NC} ${plugin_id}  (marketplace: ${mkt_repo})"
        else
            echo -e "  ${YELLOW}!${NC} ${plugin_id}"
        fi
        # 收集安装命令
        if [ ! -d "${HOME}/.claude/plugins/marketplaces/${mkt}" ] && [ -n "$mkt_repo" ]; then
            INSTALL_CMDS+="  claude plugin add-marketplace ${mkt} --url ${mkt_repo}"$'\n'
        fi
        INSTALL_CMDS+="  claude plugin install ${plugin_id}"$'\n'
    done <<< "$MISSING"
    echo -e "${YELLOW}运行以下命令安装：${NC}"
    printf '%s' "$INSTALL_CMDS"
    echo ""
}

# --- 第 2 步：先拉取 dotfiles 并同步全局配置（智能双向） ---
echo ""
echo "[2/6] 同步全局配置..."

if [ "${KNOWN_REPOS[$DOTFILES_REPO]+_}" ]; then
    DOTFILES_URL="${REPO_URLS[$DOTFILES_REPO]}"

    # 如果 dotfiles 本地不存在，先克隆
    if [ ! -d "$DOTFILES_DIR" ]; then
        echo "dotfiles 本地不存在，正在克隆..."
        if ! git clone -- "$DOTFILES_URL" "$DOTFILES_DIR" 2>&1; then
            echo -e "${RED}dotfiles 克隆失败${NC}" >&2
            HAS_ERROR=1
        fi
    fi

    if [ -d "$DOTFILES_DIR" ] && pushd "$DOTFILES_DIR" >/dev/null; then
        echo "拉取 dotfiles 远程更新..."
        DOTFILES_PULL_OUTPUT=$(git pull --rebase 2>&1)
        DOTFILES_PULL_EXIT=$?
        echo "$DOTFILES_PULL_OUTPUT"

        if [ $DOTFILES_PULL_EXIT -ne 0 ]; then
            echo -e "${RED}dotfiles pull 失败，跳过配置同步（避免用旧文件覆盖本地）${NC}" >&2
            HAS_ERROR=1
            touch "${SYNC_TMPDIR}/dotfiles_pull_failed"
        else
            # 逐文件智能同步：基于 CONFIG_MAP 声明式映射
            CFG_SYNCED=0; CFG_SKIPPED=0; CFG_CONFLICT=0; CFG_FAIL=0
            for entry in "${CONFIG_MAP[@]}"; do
                IFS='|' read -r _repo_sub _local _label <<< "$entry"
                sync_config_file "${DOTFILES_DIR}/${_repo_sub}" "$_local" "$_label"
            done
            echo ""
            _cfg_line="配置同步：${GREEN}${CFG_SYNCED} 已同步${NC} · ${CFG_SKIPPED} 跳过"
            [ $CFG_CONFLICT -gt 0 ] && _cfg_line+=" · ${YELLOW}${CFG_CONFLICT} 冲突待处理${NC}"
            [ $CFG_FAIL -gt 0 ]     && _cfg_line+=" · ${RED}${CFG_FAIL} 失败${NC}"
            echo -e "$_cfg_line"

            # 全局 rules 同步（~/.claude/rules/ ↔ dotfiles）
            echo ""
            echo "同步 Rules..."
            CFG_SYNCED=0; CFG_SKIPPED=0; CFG_CONFLICT=0; CFG_FAIL=0
            if sync_rules_dir; then
                _cfg_line="  Rules 同步：${GREEN}${CFG_SYNCED} 已同步${NC} · ${CFG_SKIPPED} 跳过"
                [ $CFG_CONFLICT -gt 0 ] && _cfg_line+=" · ${YELLOW}${CFG_CONFLICT} 冲突待处理${NC}"
                [ $CFG_FAIL -gt 0 ]     && _cfg_line+=" · ${RED}${CFG_FAIL} 失败${NC}"
                echo -e "$_cfg_line"
            else
                echo "  (无 rules 文件需要同步)"
            fi

            # 自制全局 skill 同步（modules.toml 外的 skill ↔ dotfiles）
            # 每个子系统各自重置并打印 CFG_* 计数，避免数据被前一段覆盖/吸收不输出
            echo ""
            echo "同步自制 Skills..."
            CFG_SYNCED=0; CFG_SKIPPED=0; CFG_CONFLICT=0; CFG_FAIL=0
            sync_custom_skills
            if [ $((CFG_SYNCED + CFG_SKIPPED + CFG_CONFLICT + CFG_FAIL)) -gt 0 ]; then
                _cfg_line="  自制 Skills：${GREEN}${CFG_SYNCED} 已同步${NC} · ${CFG_SKIPPED} 跳过"
                [ $CFG_CONFLICT -gt 0 ] && _cfg_line+=" · ${YELLOW}${CFG_CONFLICT} 冲突待处理${NC}"
                [ $CFG_FAIL -gt 0 ]     && _cfg_line+=" · ${RED}${CFG_FAIL} 失败${NC}"
                echo -e "$_cfg_line"
            else
                echo "  (无自制 skill 需要同步)"
            fi

            # Plugin 缺失检测（settings.json 的 enabledPlugins vs 本地已安装）
            check_missing_plugins

            # （_find_repo_dir 已在脚本顶部定义，见上方）

            # Memory 文件同步（CC hash 路径 ↔ dotfiles）
            echo ""
            echo "同步 Memory 文件..."
            CFG_SYNCED=0; CFG_SKIPPED=0; CFG_CONFLICT=0; CFG_FAIL=0
            MEM_SYNCED=0
            for name in "${!KNOWN_REPOS[@]}"; do
                MEM_REPO_DIR=$(_find_repo_dir "$name") || continue
                if sync_memory_dir "$MEM_REPO_DIR" "$name"; then
                    MEM_SYNCED=$((MEM_SYNCED + 1))
                fi
            done
            if [ $MEM_SYNCED -eq 0 ]; then
                echo "  (无项目有 memory 需要同步)"
            else
                _cfg_line="  Memory 同步：${GREEN}${CFG_SYNCED} 已同步${NC} · ${CFG_SKIPPED} 跳过"
                [ $CFG_CONFLICT -gt 0 ] && _cfg_line+=" · ${YELLOW}${CFG_CONFLICT} 冲突待处理${NC}"
                [ $CFG_FAIL -gt 0 ]     && _cfg_line+=" · ${RED}${CFG_FAIL} 失败${NC}"
                echo -e "$_cfg_line"
            fi
        fi
        popd >/dev/null 2>&1 || true
    elif [ -d "$DOTFILES_DIR" ]; then
        echo -e "${RED}无法进入 dotfiles 目录${NC}" >&2
        HAS_ERROR=1
    fi
else
    echo "仓库列表中无 dotfiles，跳过"
fi

# --- 第 3 步：并行处理仓库 ---
if [ "${ENABLE_REPO_SYNC:-false}" != "true" ]; then
    echo ""
    echo "[3/6] 项目仓库同步已禁用，跳过"
else
echo ""
echo "[3/6] 处理仓库..."
echo ""

# --- 仓库处理结果辅助函数 ---
# NOTE: On case-insensitive filesystems (Windows/NTFS), repos with case-only-different
# names would collide on temp file paths. GitHub disallows this for same-owner repos.
_repo_fail() {
    local name="$1" msg="$2"
    echo "${name}|${msg}" > "${SYNC_TMPDIR}/${name}.result"
    touch "${SYNC_TMPDIR}/${name}.error"
    echo -e "${RED}${msg}${NC}"
}

# 交互式 clone 菜单：新仓库选择 clone 目标
# 返回值：0=已 clone, 1=跳过, 2=忽略
_interactive_clone_menu() {
    local repo_name="$1"
    local repo_url="$2"

    echo ""
    echo "发现新仓库 ${repo_name}，本地未找到。"
    echo "请选择 clone 到哪个目录："

    local i=1
    for root in "${WS_ROOTS[@]}"; do
        echo "  [$i] $root"
        i=$((i + 1))
    done
    echo "  [n] 输入新路径"
    echo "  [s] 跳过（下次仍会询问）"
    echo "  [i] 忽略（以后不再询问）"
    echo ""
    read -p "> " choice < /dev/tty
    choice=$(echo "$choice" | tr -d '\r\n')

    # Handle numeric choice
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local idx=$((choice - 1))
        if [ $idx -ge 0 ] && [ $idx -lt ${#WS_ROOTS[@]} ]; then
            local target_dir="${WS_ROOTS[$idx]}/${repo_name}"
            echo "正在 clone 到 ${target_dir}..."
            if git clone -- "$repo_url" "$target_dir" 2>&1; then
                echo -e "${GREEN}克隆完成${NC}"
                CLONE_RESULT_DIR="$target_dir"
                return 0
            else
                echo -e "${RED}克隆失败${NC}"
                return 3
            fi
        else
            echo "无效选择，跳过"
            return 1
        fi
    fi

    case "$choice" in
        n|N)
            echo ""
            read -p "$(printf '请输入完整路径（例如 D:/MyProjects 或 C:/Users/你的用户名/Documents/Code）：\n> ')" new_path < /dev/tty
            new_path=$(echo "$new_path" | tr -d '\r\n')
            if [ -z "$new_path" ]; then
                echo "路径为空，跳过"
                return 1
            fi
            if [ ! -d "$new_path" ]; then
                read -p "路径 $new_path 不存在，是否创建？(y/n) " create_confirm < /dev/tty
                if [[ "$create_confirm" =~ ^[Yy] ]]; then
                    mkdir -p "$new_path" || { echo -e "${RED}创建失败${NC}"; return 1; }
                else
                    echo "已跳过"
                    return 1
                fi
            fi
            local target_dir="${new_path}/${repo_name}"
            echo "正在 clone 到 ${target_dir}..."
            if git clone -- "$repo_url" "$target_dir" 2>&1; then
                echo -e "${GREEN}克隆完成${NC}"
                # 自动追加新路径到 .env 的 WORKSPACE_ROOTS；只有 .env 写成功才更新内存数组，
                # 否则下次 /sync 找不到 repo 会一头雾水
                if _append_workspace_root "$new_path"; then
                    WS_ROOTS+=("$new_path")
                else
                    echo -e "${YELLOW}已 clone 但未能写入 .env：下次 /sync 不会自动发现 ${new_path}${NC}" >&2
                fi
                CLONE_RESULT_DIR="$target_dir"
                return 0
            else
                echo -e "${RED}克隆失败${NC}"
                return 3
            fi
            ;;
        s|S)
            echo "已跳过 ${repo_name}"
            return 1
            ;;
        i|I)
            local ignore_file="${SCRIPT_DIR}/.sync_ignore"
            # Ensure trailing newline before appending (handles manually edited files)
            if [ -f "$ignore_file" ] && [ -n "$(tail -c 1 "$ignore_file" 2>/dev/null)" ]; then
                echo "" >> "$ignore_file"
            fi
            echo "$repo_name" >> "$ignore_file"
            echo "已将 ${repo_name} 添加到 .sync_ignore"
            return 2
            ;;
        *)
            echo "无效选择，跳过"
            return 1
            ;;
    esac
}

# 追加新路径到 .env 的 WORKSPACE_ROOTS
# 使用 mkdir-based 锁（与 repo-sync enable 一致），避免并发 sync 同时改 .env 互相覆盖
_append_workspace_root() {
    local new_root="$1"
    # 显式 return 1：caller 用 `if _append_workspace_root ...` 判断成败；
    # 裸 `return` 会返回 last command 的 rc（这里是 [ ! -f ... ] 的 0=true），
    # 让 caller 误以为写成功并把 new_root 加进 WS_ROOTS，与磁盘脱节
    if [ ! -f "$ENV_FILE" ]; then return 1; fi
    local _lockdir="${ENV_FILE}.lock"
    if ! mkdir "$_lockdir" 2>/dev/null; then
        echo -e "${RED}另一个 sync.sh 正在修改 .env，跳过本次 WORKSPACE_ROOTS 追加${NC}" >&2
        echo -e "${YELLOW}（若确认无其他进程，手动清理残留锁目录：rmdir \"$_lockdir\"）${NC}" >&2
        return 1
    fi
    trap 'rmdir "'"$_lockdir"'" 2>/dev/null' RETURN
    python -c "
import os, shlex, sys, tempfile
env_path = sys.argv[1]
new_root = sys.argv[2]
with open(env_path, 'r', encoding='utf-8') as f:
    lines = f.readlines()
found = False
out_lines = []
for line in lines:
    if line.startswith('WORKSPACE_ROOTS='):
        value_part = line.strip().split('=', 1)[1]
        # shlex.split 同时支持 '...' 与 \"...\"，兼容旧 .env 格式
        # 未闭合引号等异常 → 保留原行，避免盲目截断或丢失数据
        try:
            tokens = shlex.split(value_part) if value_part else []
        except ValueError:
            out_lines.append(line)
            found = True
            continue
        old_val = tokens[0] if tokens else ''
        # 拆分、去空、去重（保留顺序），再判断是否需要追加 new_root
        parts = [p for p in old_val.split(';') if p]
        if new_root not in parts:
            parts.append(new_root)
        combined = ';'.join(parts)
        out_lines.append('WORKSPACE_ROOTS=' + shlex.quote(combined) + '\n')
        found = True
    else:
        out_lines.append(line)
if not found:
    out_lines.append('WORKSPACE_ROOTS=' + shlex.quote(new_root) + '\n')
# 原子替换：先写 tempfile，再 os.replace（避免半写入）
dirpath = os.path.dirname(os.path.abspath(env_path)) or '.'
fd, tmp_path = tempfile.mkstemp(prefix='.env.append.', dir=dirpath)
try:
    with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as f:
        f.writelines(out_lines)
    os.replace(tmp_path, env_path)
except Exception:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise
" "$(normalize_path "$ENV_FILE")" "$new_root"
    local _py_rc=$?
    rmdir "$_lockdir" 2>/dev/null
    trap - RETURN
    if [ $_py_rc -ne 0 ]; then
        echo -e "${RED}写入 .env WORKSPACE_ROOTS 失败 (python rc=$_py_rc)${NC}" >&2
        return 1
    fi
}

# 单个仓库的处理函数（在子进程中运行）
# 输出写入 SYNC_TMPDIR/<name>.out，结果写入 .result，错误标记 .error
_process_repo() {
    local REPO_NAME="$1"
    local REPO_URL="$2"
    local REPO_DIR="$3"

    echo "----- ${REPO_NAME} -----"

    # NOTE: 调用方（step 3 主循环）保证 REPO_DIR 已存在且 URL 已校验。
    # 这里不再做 [ ! -d "$REPO_DIR" ] 分支：不存在场景由交互模式的
    # _interactive_clone_menu 或非交互模式的 NEW_REPO: marker 处理。
    if ! cd "$REPO_DIR"; then
        _repo_fail "$REPO_NAME" "无法进入仓库目录 $REPO_DIR"
        echo ""
        return
    fi

    # Pull
    # LC_ALL=C 强制英文输出，后续对 "Already up to date" 的字符串匹配才稳定
    echo "拉取远程更新..."
    local PULL_OUTPUT PULL_EXIT
    PULL_OUTPUT=$(LC_ALL=C git pull --rebase 2>&1)
    PULL_EXIT=$?
    if [ $PULL_EXIT -ne 0 ]; then
        echo "${REPO_NAME}|pull 失败 - 需要 Claude 处理" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
        echo -e "${RED}pull 失败：${PULL_OUTPUT}${NC}"
        touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
        echo ""
        return
    fi

    # 检查改动
    local STATUS
    STATUS=$(git status --porcelain)
    if [ -z "$STATUS" ]; then
        local UNPUSHED=""
        if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
            UNPUSHED=$(git log '@{u}..HEAD' --oneline 2>/dev/null)
        fi
        if [ -n "$UNPUSHED" ]; then
            echo "有未推送的 commit，正在 push..."
            if git push 2>&1; then
                echo "${REPO_NAME}|已推送未同步的 commit" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
                echo -e "${GREEN}push 完成${NC}"
            else
                echo "${REPO_NAME}|push 失败 - 需要 Claude 处理" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
                echo -e "${RED}${REPO_NAME} push 失败${NC}"
                touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
            fi
        else
            if echo "$PULL_OUTPUT" | grep -q "Already up to date"; then
                echo "${REPO_NAME}|无改动" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
                echo "无改动，跳过"
            else
                echo "${REPO_NAME}|已拉取远程更新" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
                echo "已拉取远程更新"
            fi
        fi
        echo ""
        return
    fi

    # 有改动：检测未跟踪文件，避免盲目 git add -A 把 scratch 文件误提交
    echo "检测到改动，正在处理..."

    # 收集未跟踪且未被 .gitignore 忽略的文件
    # 用 -z / null-terminated 读入数组，正确处理含空格/换行/非 ASCII 的文件名
    # （默认 core.quotePath=true 会 C-quote 特殊字符，那种形式传给 git add 无法 unquote）
    # 再硬过滤一层 .bak 做安全网：不同仓库的 .gitignore 未必都忽略 *.bak
    local -a UNTRACKED_LIST=()
    local _f
    while IFS= read -r -d '' _f; do
        [[ "$_f" == *.bak ]] && continue
        UNTRACKED_LIST+=("$_f")
    done < <(git ls-files -z --others --exclude-standard 2>/dev/null)

    # 本次运行是否因 "never again" 追加过 .gitignore —— 第二次提交仅在此 flag=1 时触发
    # 注意：这个 flag 用于"是否要尝试第二次提交"的门控；无法单独阻止 git add .gitignore
    # 把用户预先存在的未暂存 .gitignore 修改一起 stage（见 GITIGNORE_WAS_DIRTY）
    local GITIGNORE_APPENDED=0

    # 在动作前记录 .gitignore 是否已有脏状态（未提交的差异或完全未跟踪且有内容）
    # 用来在出现 never-again 且 .gitignore 预先已脏时，避免 git add .gitignore
    # 把用户未提交的修改误捆进"sync: auto-append"提交
    local GITIGNORE_WAS_DIRTY=0
    if [ -f .gitignore ]; then
        if git ls-files --error-unmatch .gitignore >/dev/null 2>&1; then
            # 已跟踪：检查 HEAD 到工作树是否有差异
            git diff --quiet HEAD -- .gitignore 2>/dev/null || GITIGNORE_WAS_DIRTY=1
        else
            # 未跟踪但文件存在 —— 视为用户已有工作（内容可能来自手动编辑）
            GITIGNORE_WAS_DIRTY=1
        fi
    fi

    if [ ${#UNTRACKED_LIST[@]} -gt 0 ]; then
        if [ "$INTERACTIVE" = false ]; then
            # 非交互模式：emit 标记供 SKILL.md 读取并调用 AskUserQuestion
            # 本轮不提交，由 AI 层决策后在各仓库执行后续 git add/commit/push
            # Format consumed by SKILL.md → UNTRACKED AskUserQuestion flow
            # Do not change field names or delimiters without updating SKILL.md
            #
            # 安全检查：若有文件名内含 marker 字符串或换行/回车，输出会被攻击者
            # 控制的文件名截断或注入伪造块。'===' 是块分隔符；CR/LF 让单个文件名
            # 跨多行物理输出，可注入伪造 marker 行（如 NEW_REPO:、REPO:、FILES:）
            # 即使文件名本身不含 '==='。检测到就退化为安全模式：保留所有文件不变
            # （既不 stage 也不 emit FILES），等用户手动处理
            local _has_marker_collision=0
            for _f in "${UNTRACKED_LIST[@]}"; do
                if [[ "$_f" == *'==='* ]] || [[ "$_f" == *$'\n'* ]] || [[ "$_f" == *$'\r'* ]]; then
                    _has_marker_collision=1
                    break
                fi
            done
            if [ "$_has_marker_collision" = 1 ]; then
                echo "${REPO_NAME}|未跟踪文件含可疑名（'===' 字串或 CR/LF），需手动处理" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
                echo "----- ${REPO_NAME} 安全跳过 -----"
                echo "检测到未跟踪文件名含 '===' 序列或换行/回车字符，可能干扰 marker 解析。请手动处理后重试。"
                touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
                echo ""
                return
            fi
            echo "===UNTRACKED_BEGIN==="
            echo "REPO: $REPO_NAME"
            echo "REPO_PATH: $(pwd)"
            echo "FILES:"
            for _f in "${UNTRACKED_LIST[@]}"; do
                echo "        $_f"
            done
            echo "===UNTRACKED_END==="
            echo "${REPO_NAME}|未跟踪文件待决定" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
            echo ""
            return
        else
            # 交互模式：逐文件询问
            # 提示直写 /dev/tty，避免 2>&1 | tee 把 prompt 捕获进 .out 并在 Step 4 汇总时回放
            echo "  检测到未跟踪文件，请逐个决定：" > /dev/tty
            local untracked_file uc _c
            for untracked_file in "${UNTRACKED_LIST[@]}"; do
                printf "    %s: (i)nclude / (s)kip 下次再问 / (n)ever 再问 [s]: " \
                    "$untracked_file" > /dev/tty
                read -r uc < /dev/tty
                uc=$(echo "$uc" | tr -d '\r\n')
                case "$uc" in
                    i|I)
                        # 用 -- 分隔，防止以 '-' 开头的文件名被当作 git add 选项
                        git add -- "$untracked_file"
                        ;;
                    n|N)
                        # Gitignore footgun 预检：
                        # - 含换行（\n 或 \r）→ 直接 echo >> .gitignore 会把单个文件名拆成多行条目并破坏文件
                        # - 首/尾空白（空格/tab）→ gitignore 对尾部空白敏感；首部 tab 易被视作缩进/格式错误
                        # - 以 '!' 开头 → 反忽略规则（negation），可能取消之前的 ignore
                        # - 以 '#' 开头 → 视为注释行，忽略规则静默失效
                        if [[ "$untracked_file" == *$'\n'* ]] || [[ "$untracked_file" == *$'\r'* ]]; then
                            echo "    ⚠ 文件名含换行字符，无法安全写入 .gitignore。已跳过，请手动处理。" > /dev/tty
                            continue
                        fi
                        if [[ "$untracked_file" =~ [[:space:]]$ ]]; then
                            echo "    ⚠ $untracked_file 以空白结尾，gitignore 不会自匹配。已跳过，请手动处理。" > /dev/tty
                            continue
                        fi
                        if [[ "$untracked_file" =~ ^[[:space:]] ]]; then
                            echo "    ⚠ $untracked_file 以空白开头（含 tab），gitignore 解释异常。已跳过，请手动处理。" > /dev/tty
                            continue
                        fi
                        if [ "${untracked_file:0:1}" = "!" ]; then
                            echo "    ⚠ 以 '!' 开头会成为 gitignore 取消忽略规则（negation）。" > /dev/tty
                            printf "    是否仍要追加？(y 确认 / 其他键跳过) " > /dev/tty
                            read -r _c < /dev/tty
                            if [[ ! "$_c" =~ ^[Yy] ]]; then
                                echo "    已跳过 $untracked_file" > /dev/tty
                                continue
                            fi
                        fi
                        if [ "${untracked_file:0:1}" = "#" ]; then
                            echo "    ⚠ 以 '#' 开头会被 gitignore 解析为注释，不会生效。" > /dev/tty
                            printf "    是否仍要追加？(y 确认 / 其他键跳过) " > /dev/tty
                            read -r _c < /dev/tty
                            if [[ ! "$_c" =~ ^[Yy] ]]; then
                                echo "    已跳过 $untracked_file" > /dev/tty
                                continue
                            fi
                        fi
                        # 保险：确保 .gitignore 以换行结尾，避免新条目拼到上一行
                        if [ -f .gitignore ] && [ -n "$(tail -c 1 .gitignore 2>/dev/null)" ]; then
                            echo "" >> .gitignore
                        fi
                        echo "$untracked_file" >> .gitignore
                        GITIGNORE_APPENDED=1
                        ;;
                    *) : ;;  # skip (default) — 下次 sync 会再问
                esac
            done
        fi
    fi

    # Tracked modifications 始终自动暂存（排除 .gitignore，.gitignore 走第二次提交路径）
    git add -u -- ':!.gitignore'

    local HAS_NON_GITIGNORE_STAGED=0
    if ! git diff --cached --quiet; then
        HAS_NON_GITIGNORE_STAGED=1
    fi

    # 早退出：既无任何暂存内容，也没有 never-again 追加 —— 仅需处理潜在未推送 commit
    if [ "$HAS_NON_GITIGNORE_STAGED" = 0 ] && [ "$GITIGNORE_APPENDED" = 0 ]; then
        local UNPUSHED_REMAINING=""
        if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
            UNPUSHED_REMAINING=$(git log '@{u}..HEAD' --oneline 2>/dev/null)
        fi
        if [ -n "$UNPUSHED_REMAINING" ]; then
            echo "本轮无新内容提交，但有未推送的 commit，正在 push..."
            if git push 2>&1; then
                echo "${REPO_NAME}|已推送未同步的 commit" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
                echo -e "${GREEN}push 完成${NC}"
            else
                echo "${REPO_NAME}|push 失败 - 需要 Claude 处理" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
                echo -e "${RED}${REPO_NAME} push 失败${NC}"
                touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
            fi
        else
            echo "${REPO_NAME}|无改动（用户跳过所有未跟踪文件）" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
            echo "已跳过（无内容可提交）"
        fi
        echo ""
        return
    fi

    # --- 提交阶段 ---
    # 可能产生 0、1 或 2 次 commit：
    #   - COMMIT1：tracked modifications + "include" 类的未跟踪（仅当 HAS_NON_GITIGNORE_STAGED=1）
    #   - COMMIT2：.gitignore 的 never-again 追加（仅当 GITIGNORE_APPENDED=1 且 非 GITIGNORE_WAS_DIRTY）
    # COMMIT2 失败不影响 COMMIT1 的 push —— 修复之前"第二次 commit 失败 → 第一次 commit 被孤儿化"的问题
    local COMMIT1_DONE=0
    local COMMIT2_DONE=0

    if [ "$HAS_NON_GITIGNORE_STAGED" = 1 ]; then
        if ! git commit -m "sync: auto commit from $(hostname)"; then
            echo "${REPO_NAME}|commit 失败 - 需要 Claude 处理" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
            echo -e "${RED}${REPO_NAME} commit 失败${NC}"
            touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
            echo ""
            return
        fi
        COMMIT1_DONE=1
    fi

    # COMMIT2_OUTCOME：none / done / dirty-before / failed —— 最终状态消息要按这分支
    local COMMIT2_OUTCOME="none"
    if [ "$GITIGNORE_APPENDED" = 1 ]; then
        if [ "$GITIGNORE_WAS_DIRTY" = 1 ]; then
            # .gitignore 本轮开始前就有用户未提交的修改 —— 直接 git add .gitignore
            # 会把用户的修改一起打进"sync: auto-append"的机械提交里，属于误归属
            # 安全做法：写入文件让 never-again 条目落盘，但本轮不自动提交
            echo -e "${YELLOW}  ⚠ .gitignore 预先存在未提交修改；never-again 条目已追加到文件，但本轮不自动提交。${NC}"
            echo -e "${YELLOW}    请在 ${REPO_NAME} 手动 commit，或下次 /sync 再处理。${NC}"
            COMMIT2_OUTCOME="dirty-before"
        else
            git add .gitignore
            if ! git commit -m "sync: auto-append .gitignore from $(hostname)"; then
                # COMMIT2 失败：不 return —— 让 COMMIT1（如果成功）继续 push，避免孤儿化
                echo -e "${RED}${REPO_NAME} gitignore commit 失败（不影响主提交的 push）${NC}"
                touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
                COMMIT2_OUTCOME="failed"
            else
                COMMIT2_DONE=1
                COMMIT2_OUTCOME="done"
            fi
        fi
    fi

    # 若本轮产生了任何 commit，执行 push
    if [ "$COMMIT1_DONE" = 1 ] || [ "$COMMIT2_DONE" = 1 ]; then
        if ! git push 2>&1; then
            echo "${REPO_NAME}|push 失败 - 需要 Claude 处理" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
            echo -e "${RED}${REPO_NAME} push 失败${NC}"
            touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
            echo ""
            return
        fi
        # 至少一次提交成功并已 push；按 COMMIT2_OUTCOME 给出准确状态，避免
        # "✗ ... 已提交并推送"这种 .error+成功消息的自相矛盾显示
        case "$COMMIT2_OUTCOME" in
            failed)
                echo "${REPO_NAME}|主提交已推送，但 gitignore commit 失败（需 Claude 处理）" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
                echo -e "${YELLOW}主提交完成；gitignore 条目本轮未提交${NC}"
                ;;
            dirty-before)
                echo "${REPO_NAME}|主提交已推送，gitignore 条目已落盘待手动提交" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
                echo -e "${YELLOW}主提交完成；gitignore 条目落盘但未自动提交${NC}"
                ;;
            *)
                echo "${REPO_NAME}|已提交并推送" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
                echo -e "${GREEN}完成${NC}"
                ;;
        esac
    else
        # 没产生任何 commit。可达路径：HAS_NON_GITIGNORE_STAGED=0 + GITIGNORE_APPENDED=1
        # 且 COMMIT2_OUTCOME 是 dirty-before 或 failed —— 这两种是"已落盘待人工"的不同原因
        case "$COMMIT2_OUTCOME" in
            failed)
                # .error 已 touch，step 4 走 FAIL 分支
                echo "${REPO_NAME}|gitignore commit 失败 - 需要 Claude 处理" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
                ;;
            dirty-before)
                # 不是 error，是用户操作中转态；step 4 走 PENDING
                echo "${REPO_NAME}|gitignore 条目已落盘待手动提交（.gitignore 预先有未提交修改）" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
                ;;
            *)
                # 理论不可达（GITIGNORE_APPENDED=1 必走上面两支之一），保险起见兜底
                echo "${REPO_NAME}|本轮无 commit 落地" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
                touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
                ;;
        esac
        echo -e "${YELLOW}本轮 .gitignore 条目已落盘但未自动提交${NC}"
    fi
    echo ""
}

# 并行启动所有仓库处理
declare -a REPO_ORDER=()
while IFS='|' read -r REPO_NAME REPO_URL; do
    [ -z "$REPO_NAME" ] && continue
    REPO_ORDER+=("$REPO_NAME")

    # dotfiles 已在第 2 步处理
    if [ "$REPO_NAME" = "$DOTFILES_REPO" ]; then
        if [ -f "${SYNC_TMPDIR}/dotfiles_pull_failed" ]; then
            echo "${REPO_NAME}|pull 失败 - 需要 Claude 处理" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
            { echo "----- ${REPO_NAME} -----"; echo "第 2 步 pull 失败，需要处理"; echo ""; } > "${SYNC_TMPDIR}/${REPO_NAME}.out"
            touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
        else
            echo "${REPO_NAME}|已在第 2 步同步" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
            { echo "----- ${REPO_NAME} -----"; echo "已在第 2 步处理，跳过"; echo ""; } > "${SYNC_TMPDIR}/${REPO_NAME}.out"
        fi
        continue
    fi

    # 在所有 workspace root 中查找
    FOUND_DIR=""
    if FOUND_DIR=$(_find_repo_dir "$REPO_NAME"); then
        # 校验 remote URL 是否匹配（防止多路径下同名仓库误操作）
        _actual_url=$(git -C "$FOUND_DIR" remote get-url origin 2>/dev/null || true)
        _expect_clean="${REPO_URL%.git}"
        _actual_clean="${_actual_url%.git}"
        if [ -z "$_actual_url" ]; then
            # 本地仓库没有 origin —— 无法做 URL 校验也无法 push/pull 同名 repo
            echo "${REPO_NAME}|本地仓库无 origin remote，已跳过" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
            { echo "----- ${REPO_NAME} -----"
              echo "警告：本地 ${FOUND_DIR} 没有 origin remote，无法 push/pull"
              echo "→ cd \"$FOUND_DIR\" && git remote add origin ${REPO_URL}"; } > "${SYNC_TMPDIR}/${REPO_NAME}.out"
            touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
            continue
        fi
        if [ "$_actual_clean" != "$_expect_clean" ]; then
            echo "${REPO_NAME}|remote URL 不匹配，已跳过" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
            { echo "----- ${REPO_NAME} -----"
              echo "警告：本地 ${FOUND_DIR} 的 origin URL 与 GitHub 不匹配"
              echo "  期望: ${REPO_URL}"
              echo "  实际: ${_actual_url}"
              echo "已跳过，请手动检查"; } > "${SYNC_TMPDIR}/${REPO_NAME}.out"
            touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
            continue
        fi
        # 已存在且 URL 匹配：
        # - 非交互模式：后台并行处理，输出写入 .out 文件供 Step 4 汇总读取
        # - 交互模式：串行前台处理（防止多个未跟踪文件 prompt 争抢 /dev/tty），
        #   输出直接到终端；不再写 .out 文件，Step 4 cat 循环因此在交互模式下不会重播
        if [ "$INTERACTIVE" = true ]; then
            _process_repo "$REPO_NAME" "$REPO_URL" "$FOUND_DIR"
        else
            _process_repo "$REPO_NAME" "$REPO_URL" "$FOUND_DIR" > "${SYNC_TMPDIR}/${REPO_NAME}.out" 2>&1 &
        fi
    elif [ "$INTERACTIVE" = true ]; then
        # 新仓库 + 交互模式：前台运行 clone 菜单（不重定向，保持终端交互）
        # 只写 .result（分类用），不写 .out —— 菜单输出已显示在终端，
        # 再写 .out 会在 Step 4 汇总的 cat 循环中重播一次
        CLONE_RESULT_DIR=""
        _interactive_clone_menu "$REPO_NAME" "$REPO_URL"
        menu_rc=$?
        if [ $menu_rc -eq 0 ] && [ -n "$CLONE_RESULT_DIR" ]; then
            echo "${REPO_NAME}|新克隆" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
        elif [ $menu_rc -eq 2 ]; then
            echo "${REPO_NAME}|已忽略" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
        elif [ $menu_rc -eq 3 ]; then
            echo "${REPO_NAME}|克隆失败" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
            touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
        else
            echo "${REPO_NAME}|已跳过" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
        fi
    else
        # 新仓库 + 非交互模式：输出标记
        echo "${REPO_NAME}|新仓库待处理" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
        echo "NEW_REPO: ${REPO_NAME} | ${REPO_URL}" > "${SYNC_TMPDIR}/${REPO_NAME}.out"
    fi
done <<< "$REPOS"

wait

# 按原始顺序收集输出和结果
for name in "${REPO_ORDER[@]}"; do
    [ -f "${SYNC_TMPDIR}/${name}.out" ] && cat "${SYNC_TMPDIR}/${name}.out"
    [ -f "${SYNC_TMPDIR}/${name}.result" ] && RESULTS+=("$(cat "${SYNC_TMPDIR}/${name}.result")")
    [ -f "${SYNC_TMPDIR}/${name}.error" ] && HAS_ERROR=1
done

fi  # ENABLE_REPO_SYNC gate (step 3)

# --- 第 4 步：汇总 ---
if [ "${ENABLE_REPO_SYNC:-false}" != "true" ]; then
    echo "========================================="
    echo "[4/6] 汇总"
    echo "========================================="
    echo ""
    _cfg_line="配置同步：${GREEN}${CFG_SYNCED:-0} 已同步${NC} · ${CFG_SKIPPED:-0} 跳过"
    [ "${CFG_CONFLICT:-0}" -gt 0 ] && _cfg_line+=" · ${YELLOW}${CFG_CONFLICT} 冲突待处理${NC}"
    [ "${CFG_FAIL:-0}" -gt 0 ]     && _cfg_line+=" · ${RED}${CFG_FAIL} 失败${NC}"
    echo -e "$_cfg_line"
else
    echo "========================================="
    echo "[4/6] 汇总"
    echo "========================================="

    # 分类：FAIL / PENDING（待用户决定）/ ACTION（已执行）/ NOOP（无变化）
    # 使用显式 allowlist，未知状态走 PENDING 兜底，避免默认 fall-through 被误当成功
    declare -a FAIL_ITEMS=()
    declare -a PENDING_ITEMS=()
    declare -a ACTION_ITEMS=()
    declare -a NOOP_ITEMS=()

    for RESULT in "${RESULTS[@]}"; do
        IFS='|' read -r NAME REPO_STATUS <<< "$RESULT"
        if [ -f "${SYNC_TMPDIR}/${NAME}.error" ]; then
            FAIL_ITEMS+=("$NAME|$REPO_STATUS")
        elif [ "$REPO_STATUS" = "未跟踪文件待决定" ] \
            || [ "$REPO_STATUS" = "新仓库待处理" ] \
            || [[ "$REPO_STATUS" == "gitignore 条目已落盘待手动提交"* ]]; then
            # UNTRACKED / 非交互新仓库 / dirty-before 的 gitignore 落盘待人工：
            # 等待 SKILL.md / 用户决策。用精确（含 prefix）匹配，防止新增状态串
            # 巧合包含子串被误分类
            PENDING_ITEMS+=("$NAME|$REPO_STATUS")
        elif [ "$REPO_STATUS" = "已在第 2 步同步" ] \
            || [[ "$REPO_STATUS" == "无改动"* ]] \
            || [ "$REPO_STATUS" = "已忽略" ] \
            || [ "$REPO_STATUS" = "已跳过" ]; then
            # 用户主动跳过或忽略都视作"本轮无变化"（已忽略永久 / 已跳过本轮）
            NOOP_ITEMS+=("$NAME|$REPO_STATUS")
        elif [ "$REPO_STATUS" = "已提交并推送" ] \
            || [ "$REPO_STATUS" = "已推送未同步的 commit" ] \
            || [ "$REPO_STATUS" = "已拉取远程更新" ] \
            || [ "$REPO_STATUS" = "新克隆" ] \
            || [[ "$REPO_STATUS" == "主提交已推送"* ]]; then
            # "主提交已推送，gitignore 条目已落盘待手动提交"也是部分成功，归 ACTION
            # （.error 不在此处置位，所以走到这里就是一致的；commit-fail 路径已经
            # 在前面被 .error 分支拦截到 FAIL 桶）
            ACTION_ITEMS+=("$NAME|$REPO_STATUS")
        else
            # 未知状态 —— 保守归入 PENDING 并标注，防止新增状态字符串被默认当成成功
            PENDING_ITEMS+=("$NAME|$REPO_STATUS（未识别状态）")
        fi
    done

    # 显示一组仓库
    print_group() {
        local SYMBOL="$1"
        local COLOR="$2"
        local LABEL="$3"
        shift 3
        local ITEMS=("$@")

        [ ${#ITEMS[@]} -eq 0 ] && return

        echo ""
        echo -e "${COLOR}${LABEL}${NC}"
        for ITEM in "${ITEMS[@]}"; do
            IFS='|' read -r NAME REPO_STATUS <<< "$ITEM"
            REPO_STATUS="${REPO_STATUS% - 需要 Claude 处理}"
            echo -e "  ${COLOR}${SYMBOL}${NC} ${NAME}  ${COLOR}${REPO_STATUS}${NC}"
        done
    }

    # 按优先级输出：失败 → 待决定 → 已同步 → 无变化
    print_group "✗" "$RED"    "失败 (${#FAIL_ITEMS[@]})"      "${FAIL_ITEMS[@]}"
    print_group "?" "$YELLOW" "待决定 (${#PENDING_ITEMS[@]})" "${PENDING_ITEMS[@]}"
    print_group "✓" "$GREEN"  "已同步 (${#ACTION_ITEMS[@]})"  "${ACTION_ITEMS[@]}"
    print_group "·" "$GRAY"   "无变化 (${#NOOP_ITEMS[@]})"    "${NOOP_ITEMS[@]}"

    # 统计摘要
    TOTAL=${#RESULTS[@]}
    N_FAIL=${#FAIL_ITEMS[@]}
    N_PENDING=${#PENDING_ITEMS[@]}
    N_ACTION=${#ACTION_ITEMS[@]}
    N_NOOP=${#NOOP_ITEMS[@]}

    echo ""
    _summary="合计 ${TOTAL} 个仓库："
    _sep=""
    if [ $N_ACTION -gt 0 ]; then
        _summary+="${_sep}${GREEN}${N_ACTION} 已同步${NC}"; _sep=" · "
    fi
    if [ $N_FAIL -gt 0 ]; then
        _summary+="${_sep}${RED}${N_FAIL} 失败${NC}"; _sep=" · "
    fi
    if [ $N_PENDING -gt 0 ]; then
        _summary+="${_sep}${YELLOW}${N_PENDING} 待决定${NC}"; _sep=" · "
    fi
    if [ $N_NOOP -gt 0 ]; then
        _summary+="${_sep}${N_NOOP} 无变化"; _sep=" · "
    fi
    # 若所有计数均为 0（极端：无任何仓库进入汇总），收尾提示
    if [ -z "$_sep" ]; then
        _summary+="（无仓库汇总项）"
    fi
    echo -e "$_summary"
fi

# --- Handoff banner 辅助函数 ---
print_handoff_banner() {
    local title="$1" content="$2"
    echo ""
    echo -e "${YELLOW}=========================================${NC}"
    echo -e "${YELLOW} HANDOFF: ${title}${NC}"
    echo -e "${YELLOW}=========================================${NC}"
    echo "$content"
    echo -e "${YELLOW}=========================================${NC}"
}

# --- 第 5 步：Handoff 检测 ---
echo ""
echo "[5/6] Handoff 检测..."

# Auto-migrate HANDOFF.md to registry format (idempotent)
if [ -f "$HANDOFF_FILE" ]; then
    python "$HANDOFF_PY" migrate "$HANDOFF_FILE_PY" >/dev/null 2>&1 || true
fi

if [ ! -f "$HANDOFF_FILE" ]; then
    echo -e "${RED}警告：HANDOFF.md 不存在（pull 失败或文件损坏？）${NC}"
else
    HANDOFF_READY=0

    if ! get_machine_name; then
        # Case 1: .machine-name 不存在
        if [ "$INTERACTIVE" = false ]; then
            echo "跳过设备注册（非交互模式）"
        else
            echo -e "${YELLOW}未找到 .machine-name，需要设置设备名称。${NC}"

            while true; do
                read -p "请输入本设备的名称（如 Desktop、Laptop），留空跳过：" INPUT_NAME
                INPUT_NAME=$(echo "$INPUT_NAME" | tr -d '\r\n')

                if [ -z "$INPUT_NAME" ]; then
                    echo "已跳过，下次 sync 会再次询问。"
                    break
                fi

                if [ "$(handoff_section_exists "$INPUT_NAME")" = "no" ]; then
                    # Case 1A: 新名字，不存在于 HANDOFF.md
                    read -p "新设备 [$INPUT_NAME]，是否添加到 HANDOFF.md？(y/n) " CONFIRM
                    if [[ "$CONFIRM" =~ ^[Yy] ]]; then
                        echo "$INPUT_NAME" > "${SCRIPT_DIR}/.machine-name"
                        if register_handoff_device "$INPUT_NAME"; then
                            MACHINE_NAME="$INPUT_NAME"
                            HANDOFF_READY=1
                        else
                            rm -f "${SCRIPT_DIR}/.machine-name"
                            echo -e "${YELLOW}设备注册失败，handoff 功能本次跳过${NC}"
                        fi
                    else
                        echo "已跳过，下次 sync 会再次询问。"
                    fi
                    break
                else
                    # Case 1B: 名字已被注册 — 拒绝重复，防止身份冲突
                    echo -e "${RED}✗ [$INPUT_NAME] 已被其他设备注册，请选择其他名称。${NC}"
                    continue
                fi
            done
        fi
    else
        # Case 2: .machine-name 存在
        if [ "$(handoff_section_exists "$MACHINE_NAME")" = "yes" ]; then
            # Case 2A: 正常流程
            HANDOFF_READY=1
        else
            # Case 2B: 文件存在但 section 不在 HANDOFF.md 中
            echo -e "${YELLOW}设备 [$MACHINE_NAME] 未在 HANDOFF.md 中注册。${NC}"
            if [ "$INTERACTIVE" = false ]; then
                echo "跳过设备注册（非交互模式）"
            else
                read -p "是否添加？(y/n) " CONFIRM
                if [[ "$CONFIRM" =~ ^[Yy] ]]; then
                    if register_handoff_device "$MACHINE_NAME"; then
                        HANDOFF_READY=1
                    else
                        echo -e "${YELLOW}设备注册失败，handoff 功能本次跳过${NC}"
                    fi
                else
                    echo -e "${YELLOW}设备 [$MACHINE_NAME] 未在 handoff 设备列表中，handoff 功能不可用。${NC}"
                fi
            fi
        fi
    fi

    # Hidden-section scan: detect_hidden_sections surfaces task content that
    # extract_section_body would have truncated at an unregistered `## ` heading.
    # This pattern (unregistered header inside a registered section) was added
    # by the registry/on-disk union boundary fix — without an explicit scan,
    # an adversary editing HANDOFF.md could plant `## Notes` inside a victim
    # device section to silently hide tasks from /sync and preflight. Adversary-
    # controlled excerpts are surfaced as a warning banner, NOT as executable
    # task content. Run BEFORE get_pending so stderr (mismatch warning) prints
    # alongside the structured banner.
    HIDDEN_REPORT=$(handoff_detect_hidden)
    if [ -n "$HIDDEN_REPORT" ]; then
        echo ""
        echo -e "${RED}⚠ HANDOFF.md 安全警告：检测到隐藏任务${NC}"
        echo -e "${YELLOW}以下内容位于未注册的 ## 标题之后，已被 /sync 的常规任务提取跳过。${NC}"
        echo -e "${YELLOW}请视为可疑——可能是协作设备或被篡改的远程仓库植入的隐藏指令。${NC}"
        echo -e "${YELLOW}不要直接执行；先在编辑器里手动检查 HANDOFF.md 的结构再决定。${NC}"
        echo ""
        printf '%s\n' "$HIDDEN_REPORT"
        echo ""
    fi

    # Check ANY tasks (always, regardless of registration). Stderr is no
    # longer redirected to /dev/null: _get_boundary_headers' mismatch warning
    # needs to reach the user — without it, hiding-via-truncation attacks slip
    # past silently. Real errors (file missing, parse failure) also become
    # visible, which is the correct posture for handoff state.
    ANY_PENDING=$(handoff_get_pending "ANY")
    if [ -n "$ANY_PENDING" ]; then
        print_handoff_banner "全局任务 (ANY)" "$ANY_PENDING"
    fi

    # Check device-specific tasks (only when registered)
    if [ $HANDOFF_READY -eq 1 ]; then
        DEVICE_PENDING=$(handoff_get_pending "$MACHINE_NAME")
        if [ -n "$DEVICE_PENDING" ]; then
            print_handoff_banner "$MACHINE_NAME 专属任务" "$DEVICE_PENDING"
        fi
    fi

    # --- sync skill 触发信号：有待办任务（含隐藏）时输出标准关键词 ---
    if [ -n "$ANY_PENDING" ] || [ -n "${DEVICE_PENDING:-}" ] || [ -n "$HIDDEN_REPORT" ]; then
        echo "HANDOFF: Pending tasks detected"
    fi

    # Summary：只有"设备已注册 + ANY 空 + 设备专属空 + 无隐藏内容"才算真正"无待办"。
    # 设备未注册时设备专属任务未被检查，输出"无待办"会误导。
    # HIDDEN_REPORT 非空意味着 HANDOFF.md 有可疑结构，summary 不能宣称"无待办"
    if [ -z "$ANY_PENDING" ] && [ $HANDOFF_READY -eq 1 ] && [ -z "${DEVICE_PENDING:-}" ] && [ -z "$HIDDEN_REPORT" ]; then
        echo "无待办 handoff 任务。"
    elif [ -z "$ANY_PENDING" ] && [ $HANDOFF_READY -eq 0 ] && [ -z "$HIDDEN_REPORT" ]; then
        echo "无 ANY 任务；设备未注册，专属任务未检查。"
    fi
fi

# --- 第 6 步：提交并推送 dotfiles（如果有改动）---
echo ""
echo "[6/6] 检查 dotfiles 是否需要推送..."

if [ -d "$DOTFILES_DIR" ]; then
    if pushd "$DOTFILES_DIR" >/dev/null; then
        # 排除 conflict-resolve 写下的 .bak 备份：sync_commit_push 会用 pathspec
        # ':!**/*.bak' 跳过它们，但本判断在那之前；不滤掉的话只剩 .bak 时也会进 commit 分支
        # `tr -d '\r'` 防御 Windows CRLF 环境下 porcelain 输出尾部可能残留 \r，导致
        # 末尾锚 `\.bak$` 失配
        DOTFILES_STATUS=$(git status --porcelain | tr -d '\r' | grep -v '^\?\? .*\.bak$')
        if [ -n "$DOTFILES_STATUS" ]; then
            if sync_commit_push "dotfiles"; then
                echo -e "${GREEN}dotfiles 已提交并推送${NC}"
            fi
        else
            echo "dotfiles 无改动"
        fi
        popd >/dev/null 2>&1 || true
    else
        echo -e "${RED}无法进入 dotfiles 目录（step 6）${NC}" >&2
        HAS_ERROR=1
    fi
fi

if [ $HAS_ERROR -ne 0 ]; then
    echo ""
    echo -e "${YELLOW}有仓库处理失败，建议使用 Claude Code /sync 处理。${NC}"
    exit 1
fi

# --- Repo sync disabled hint ---
if [ "${ENABLE_REPO_SYNC:-false}" != "true" ]; then
    HINT_FILE="${SCRIPT_DIR}/.repo_sync_hint_count"
    hint_count=0
    if [ -f "$HINT_FILE" ]; then
        hint_count=$(tr -d '\r\n' < "$HINT_FILE")
        if ! [[ "$hint_count" =~ ^[0-9]+$ ]]; then hint_count=0; fi
    fi
    if [ "$hint_count" -lt 3 ]; then
        echo ""
        echo "[Tip] Project repo sync is disabled. Run 'bash sync.sh repo-sync enable' to turn it on."
        hint_count=$((hint_count + 1))
        echo "$hint_count" > "$HINT_FILE"
    fi
fi

echo ""
echo "全部完成！"
exit 0
