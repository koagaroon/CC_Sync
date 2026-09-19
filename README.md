[English](./README_EN.md)

# CC_Sync

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE) [![GitHub release](https://img.shields.io/github/v/release/koagaroon/CC_Sync)](https://github.com/koagaroon/CC_Sync/releases) ![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-blue)

**让多台电脑上的 Claude Code 项目、配置和待办任务保持同步。** CC_Sync 结合 Bash 脚本、Python 辅助程序和 Claude Code 技能，统一处理 Git 仓库同步、跨设备任务传递，以及按已批准版本安装第三方技能。

[快速开始](#快速开始) · [日常使用](#日常使用在-claude-code-中) · [命令行参考](#命令行参考高级用户) · [项目结构](#项目结构) · [许可证](#许可证)

## 工作方式

| 同步对象 | 存放位置 | CC_Sync 的作用 |
| --- | --- | --- |
| 项目代码 | 你选择的 GitHub 仓库 | 按 topic 发现仓库，然后拉取、提交已跟踪文件的改动并推送 |
| Claude Code 配置 | 单独的**私有 dotfiles 仓库** | 同步设置和技能、记录文件状态，并提示冲突或删除 |
| 设备名称和待办任务 | **你自己的私有 CC_Sync 工作仓库**中的 `HANDOFF.md` | 记录发给其他设备的任务，由 `/sync` 技能询问如何处理 |

本公开仓库用于分发工具。注册设备和传递任务时，请使用下方步骤创建的私有工作副本。Bash 和 Python 负责文件与 Git 操作，Claude Code 技能负责引导冲突处理、配置导入和任务决策。

## 功能特性

- **多仓库批量同步**——通过 GitHub topic 自动发现仓库，一键 pull/commit/push
- **跨设备配置同步**——settings.json、skills、hooks、keybindings 等通过 dotfiles 仓库同步
- **跨设备任务传递**——通过 HANDOFF.md 在设备间传递待办任务
- **第三方模块管理**——从 GitHub 安装/更新/删除/恢复技能
- **首次引导向导**——交互式 .env 配置，小白也能完成
- **多 workspace 路径支持**——仓库分散在不同目录也能统一管理
- **删除防复活**——本机账本记录每个配置文件的同步历史，在一台设备上删除的配置不会被其他设备悄悄推回来
- **模块按版本锁定**——模块更新走“检查 → 批准 → 安装”流程，升级前先看变更，不会自动跟随上游最新代码
- **引导式决策**——技能会询问敏感配置导入、跨设备任务和新技能的处理方式；常规完整同步会自动提交并推送已跟踪的项目改动

## 前提条件

### 1. Git 和 Bash 4+

脚本需要 **Bash 4 或更高版本**。Windows 用户请使用 Git for Windows 附带的 **Git Bash**。macOS 用户请通过 Homebrew 安装较新的 Bash，并确认 `bash --version` 调用的是该版本。

- **Windows**：打开 **PowerShell**，运行：
  ```powershell
  winget install --id Git.Git -e
  ```
- **macOS**：打开终端（**Terminal**），运行：`brew install git bash`
- **Linux（Debian/Ubuntu）**：打开终端（**Terminal**），运行：`sudo apt install git bash`

### 2. Python 3.11+

Python 辅助程序使用标准库中的 [`tomllib`](https://docs.python.org/3/library/tomllib.html)，因此需要 Python 3.11 或更高版本。脚本直接调用 **`python`**，请确保这个命令在运行 CC_Sync 的 Bash 环境中可用。

- **Windows**：继续在 **PowerShell** 中运行：
  ```powershell
  winget install --id Python.Python.3.13 -e
  ```
  安装后重新打开终端，在 **Git Bash** 中输入 `python --version`，确认版本号 >= 3.11。
- **macOS**：继续在 **Terminal** 中运行 `brew install python`，然后让当前终端会话使用 Homebrew 的 Bash 和[无版本号 Python 命令](https://docs.brew.sh/Homebrew-and-Python)：
  ```bash
  export PATH="$(brew --prefix)/bin:$(brew --prefix python)/libexec/bin:$PATH"
  ```
  新终端会话中需重新执行；如果希望长期生效，可以加入自己的 shell 启动配置。
- **Linux（Debian/Ubuntu）**：继续在 **Terminal** 中运行：`sudo apt install python3 python-is-python3`，并确认发行版提供的是 Python 3.11 或更高版本。

继续之前，请在准备用来运行 CC_Sync 的同一个终端中执行 `bash --version` 和 `python --version`。脚本调用的是 `python` 命令；如果系统里只有 `python3` 而没有 `python`，还不能运行。

### 3. GitHub CLI (gh)

- **Windows**：继续在 **PowerShell** 中运行：
  ```powershell
  winget install --id GitHub.cli -e
  ```
- **macOS**：继续在 **Terminal** 中运行：`brew install gh`
- **Linux**：参考 [GitHub CLI 官方文档](https://cli.github.com/)

安装完成后，继续在同一个 **PowerShell**（或 **Terminal**）中运行：

```bash
gh auth login
```

按提示选择：GitHub.com → HTTPS → Login with a web browser，然后在浏览器中完成授权。

### 4. Claude Code

需要已安装并可正常使用的 Claude Code CLI。如果还没安装，请参考 [Claude Code 官方文档](https://docs.anthropic.com/en/docs/claude-code)。

## 快速开始

### 第 1 步：创建自己的私有工作仓库

选择一个存放项目的父文件夹，在其中打开终端（Windows 用 **Git Bash**，macOS/Linux 用已配置 Bash 4+ 的 **Terminal**）。以下命令会下载公开源代码、**在你的 GitHub 账户中创建新的私有仓库**，并推送初始副本。如果已有名为 `cc-sync-workspace` 的仓库，请改用其他名称。

```bash
git clone https://github.com/koagaroon/CC_Sync.git cc-sync-workspace
cd cc-sync-workspace
git remote rename origin upstream
gh repo create cc-sync-workspace --private --source . --remote origin
git push --set-upstream origin main
```

此时 `origin` 指向你的私有仓库，`upstream` 保留为公开源仓库。注册设备和处理任务会在此工作副本中提交并推送 `HANDOFF.md`，因此应使用你拥有写入权限的私有仓库。它与第 3 步配置的私有 dotfiles 仓库是两个独立仓库。

本地文件夹名必须与 GitHub 仓库名一致，因为发现逻辑会查找 `<workspace-root>/<repo-name>`。如果选用其他名称，请在所有步骤中统一替换。

### 第 2 步：给你的 GitHub 仓库添加标签

给**刚创建的私有 `cc-sync-workspace` 仓库**以及每个需要同步的项目仓库添加标签。请先替换命令中的占位符：

```bash
gh repo edit "<your-username>/cc-sync-workspace" --add-topic claude-code-workspace
gh repo edit "<your-username>/<project-repo>" --add-topic claude-code-workspace
```

> 不知道用户名？继续在同一个终端中运行 `gh api user -q .login` 查看。

### 第 3 步：准备私有 dotfiles 仓库

同步要求 dotfiles 仓库已有初始提交，且本地分支已关联远程分支。首次设置时，以下命令会创建另一个私有仓库，包含初始 README，并将它克隆到工作副本旁。如果已有名为 `cc-dotfiles` 的仓库，请改用其他名称：

```bash
cd ..
gh repo create cc-dotfiles --private --add-readme --clone
cd cc-sync-workspace
```

如果已有私有 dotfiles 仓库，请改为将它克隆到单独的文件夹。本地克隆的文件夹名应与 GitHub 仓库名一致。

### 第 4 步：首次配置

> ⚠️ **这一步必须在交互式终端中运行**（不是在 Claude Code 里）。Windows 用户请打开 **Git Bash**，macOS/Linux 用户用 **Terminal**。

留在第 1 步的 `cc-sync-workspace` 目录中。**向导结束后会立即执行完整同步：**同步配置，并在启用仓库同步时拉取选中的仓库、提交已跟踪文件的改动并推送。请在确定要提交并推送这些改动时再运行；如果只想查看状态，请在相应仓库中运行 `git status`。

```bash
bash sync.sh
```

首次运行会启动配置向导，依次询问：

**问题 1：dotfiles 仓库路径**

填写第 3 步准备好的私有 dotfiles 克隆的完整本地路径。使用现有克隆，可确保首次拉取时已有对应的远程分支。

> dotfiles 仓库应保持**私有**。如果 GitHub 返回公开状态，CC_Sync 会中止同步；如果可见性查询失败，脚本会警告后继续，因此请在同步个人配置前自行确认仓库的可见性。

**问题 2：是否启用仓库同步？**

输入 `y` 启用。启用后会继续询问：

- **仓库存放路径**：填写各个仓库所在的父文件夹，包含第 1 步的 `cc-sync-workspace` 工作副本所在目录；多个路径用 `;` 分隔。
- **GitHub topic 标签**：直接按回车使用默认值 `claude-code-workspace`

配置完成后，脚本会立即执行一次完整同步。

要在设备间传递任务，请保持仓库同步开启，并确保私有工作仓库带有配置中指定的 topic 标签，并位于配置的工作区目录内。这样才能先拉取它的 `HANDOFF.md` 更新，再检测待办任务。

## 日常使用（在 Claude Code 中）

配置完成后，可在 **Claude Code** 中使用附带技能进行引导式操作，也可以按[命令行参考](#命令行参考高级用户)直接运行命令。

### 启动方式

1. 打开 Claude Code
2. 进入自己的私有 `cc-sync-workspace` 目录（需要时用 `cd` 切换）

### 同步仓库

直接对 Claude 说：

- “同步”
- “同步已配置的仓库和 Claude 配置”

或者输入：`/sync`

这些请求会执行**完整同步**，包括提交并推送已跟踪的项目改动。“查看仓库状态”或“只拉取”属于单独的操作，不应调用 `/sync`。

Claude 会自动执行同步脚本，然后：

- 展示同步结果汇总（哪些成功、哪些失败、哪些无变化）
- 如果有配置文件冲突，会用选择题问你“保留哪个版本”（默认只展示时间、行数等元信息，你选“查看完整差异”后才展示具体改动）
- 如果是首次从 dotfiles 导入 `settings.json`、`keybindings.json`、`statusline.sh`、`CLAUDE.md` 这类影响 Claude 行为的敏感配置，会先征求你的同意
- 如果 dotfiles 里出现了新的技能目录，会问你要不要导入本机
- 如果发现某个配置文件曾在别的设备上被删除，会问你是删除本机副本、保留在本机、还是推回仓库（防止删掉的配置“复活”）
- 如果项目仓库里有未跟踪的新文件，会逐个问你要不要提交（不会一股脑全部提交）
- 如果有新仓库，会问你“克隆到哪个目录”
- 如果有跨设备任务（HANDOFF），会逐条向你确认后再处理（见下文）
- 如果某个仓库 pull 冲突，会分析差异并建议解决方案

请检查同步汇总，并对技能提出的选项作出决定。

### 设备管理

对 Claude 说：

- “查看设备列表”
- “注册新设备 MyLaptop”（名称你自己取，必须唯一）
- “移除设备 OldPC”

### 模块管理

对 Claude 说：

- “查看已安装的模块”
- “检查更新”
- “更新所有模块”
- “安装 anthropics/skills 里的 pdf 技能”
- “删除 xxx 模块”
- “纳管 xxx 目录”（把手动放进去的已有目录登记到清单里）
- “清理未纳管的目录”
- “新设备恢复所有模块”

模块更新走“检查 → 批准 → 安装”三步：“检查更新”列出每个模块上游的新提交（附 GitHub 变更对比链接），你点头后 Claude 才把新版本标记为“已批准”，最后按已批准的版本安装。模块不会自动跟随上游最新代码——每次升级都以你看过变更为前提。

### 跨设备任务（HANDOFF）

HANDOFF 是 CC_Sync 的跨设备任务传递机制。当你在 A 设备上需要 B 设备做某件事时，可以通过它留言。

**前提：每台设备需要先注册一个唯一名称。** 在 **Claude Code** 中说：

- “注册新设备 HomeMac”
- “注册新设备 OfficePC”

> 设备名可以是任何英文名称，但必须唯一。建议用能让你一眼认出是哪台电脑的名字，比如 `HomeMac`、`OfficePC`、`MyLaptop`。

**留任务：** 在 A 设备的 **Claude Code** 中说：

- “给 OfficePC 留个任务：把 xxx 项目的配置文件复制过来”
- “给 HomeMac 留个任务：运行 pip install requests”
- “所有设备都要做：更新 gh CLI”（写入 ANY 区段，所有设备都会看到）

**接收任务：** 在 B 设备的 **Claude Code** 中运行 /sync 时，Claude 会自动：

1. 检测到待办任务
2. 向你报告任务内容
3. 逐条问你怎么处理：直接执行 / 本次跳过 / 不执行但标记完成 / 拒绝并隔离（内容可疑时）
4. 处理完毕后清除任务并推送

> 任务内容来自 Git 同步的文本。`/sync` 技能要求 Claude 将其视为不可信输入、报告可疑的隐藏任务，并在执行任务指令前询问你的决定。请在提示时检查任务内容和拟执行的操作。

不需要手动编辑任何文件，全部通过自然语言完成。

## 命令行参考（高级用户）

如果你喜欢直接在终端中操作，以下是完整命令参考。在终端（**Git Bash** 或 **Terminal**）中运行：

| 命令 | 说明 |
|------|------|
| `bash sync.sh` | 完整配置与仓库同步，包括提交并推送已跟踪的项目改动 |
| `bash sync.sh --show-diff` | 完整同步（冲突提示附带完整 diff，默认只有元信息） |
| `bash sync.sh device list` | 查看设备 |
| `bash sync.sh device add <名称>` | 注册设备 |
| `bash sync.sh device remove <名称>` | 移除设备 |
| `bash sync.sh repo-sync enable` | 开启仓库同步 |
| `bash sync.sh repo-sync unignore <名称>` | 恢复忽略的仓库 |
| `bash module-manager.sh list` | 查看模块 |
| `bash module-manager.sh check --all` | 检查更新 |
| `bash module-manager.sh bump <名称\|--all> [--to <sha>\|--latest]` | 批准新版本（只记录、不下载） |
| `bash module-manager.sh update --all` | 安装已批准的版本 |
| `bash module-manager.sh install <source>` | 安装模块 |
| `bash module-manager.sh remove <名称>` | 删除模块 |
| `bash module-manager.sh adopt <名称> <source>` | 纳管已有目录 |
| `bash module-manager.sh adopt --bulk [--dry-run] <owner/repo>` | 批量纳管 |
| `bash module-manager.sh prune [--all \| --confirm <名称>...]` | 清理未纳管的目录 |
| `bash module-manager.sh restore` | 新设备恢复 |

> `module-manager.sh check` 通过退出码区分检查结果：`0` = 全部最新，`10` = 有可用更新，`1` = 查询出错。写脚本调用时不要把 `10` 当作失败。
>
> 另有 `sync.sh prune-apply` 和 `sync.sh skill-import` 两个供 `/sync` 技能调用的底层子命令，会在你确认后执行，一般不需要手动使用。
>
> 想验证脚本本身是否完好，可运行 `bash tests/bounce_simulation.sh`——它在隔离的测试模式下执行，不会碰你的真实仓库和配置。

## 配置说明

首次运行后会在项目根目录生成 `.env` 文件（已加入 .gitignore，不会被提交）：

| 字段 | 说明 | 示例 |
|------|------|------|
| `DOTFILES_PATH` | dotfiles 仓库路径（必填） | `C:/dotfiles` |
| `ENABLE_REPO_SYNC` | 是否启用仓库同步 | `true` 或 `false` |
| `WORKSPACE_ROOTS` | 仓库存放路径（多个用 `;` 分隔） | `D:/Projects;E:/Work` |
| `TOPIC` | GitHub topic 标签 | `claude-code-workspace` |

运行过程中还会在项目根目录生成以下本机状态文件（除 `.sync_ignore` 外都已加入 .gitignore，不会被提交）：

| 文件 | 用途 |
|------|------|
| `.machine-name` | 本机的设备名（HANDOFF 用） |
| `.sync_state.json` | 同步状态账本——记录每个配置文件最后同步时的指纹，用于识别被删除过的文件、防止“复活” |
| `.sync_ignore` | 永久忽略的仓库列表（按需生成；可提交到私有工作仓库，在多台设备间共享） |
| `.skill_import_ignore` | 拒绝导入过的技能目录，之后不再询问 |
| `.repo_sync_hint_count` | 内部提示计数器 |

模块管理另外在 `~/.claude/skills/` 下维护两个文件：`modules.toml`（模块清单，随 dotfiles 同步，新设备恢复的依据）和 `.check_state.json`（“检查更新”的本机缓存，24 小时时效，不同步）。

## 项目结构

```
cc-sync-workspace/
├── sync.sh                  # 主脚本
├── module-manager.sh        # 模块管理
├── lib/
│   ├── common.sh            # 共享 bash 工具
│   ├── handoff.py           # HANDOFF.md 解析/写入
│   └── module_helper.py     # 模块管理 Python 辅助程序
├── tests/
│   └── bounce_simulation.sh # 自检测试（隔离测试模式，不碰真实仓库）
├── HANDOFF.md               # 跨设备任务传递
├── CLAUDE.md                # Claude Code 项目级指令
├── .env                     # 本机配置（自动生成，不提交）
├── .sync_state.json         # 同步状态账本（自动生成，不提交）
├── .sync_ignore             # 永久忽略的仓库列表（按需生成）
└── .claude/
    ├── skills/              # 技能定义（/sync、/module-manager）
    └── hooks/               # 会话启动检查
```

## 常见问题

### sync.sh 报错“请在终端中运行”

`.env` 不存在。请在交互式终端（**Git Bash** 或 **Terminal**）中运行 `bash sync.sh` 完成首次配置。Claude Code 的 bash 工具是非交互的，无法运行向导。

### gh CLI 连接超时

先检查网络连接和 `gh auth status`。如果网络需要代理，而 `gh` 未使用它，可在当前 **Git Bash** 或 **Terminal** 会话中设置代理地址；请将占位符替换为实际代理 URL：

```bash
export HTTPS_PROXY="<your-proxy-url>"
```

### git diff 显示大量改动但内容没变

Windows 上 CRLF 与 LF 行尾符的变化可能让相同文本显示为已修改。请对比 `git diff` 和 `git diff --ignore-space-at-eol` 的结果，检查仍然存在的差异，再决定是否提交或丢弃改动。

### 为什么第一次同步会问我要不要导入 settings.json？

`settings.json`、`keybindings.json`、`statusline.sh`、`CLAUDE.md` 这几个文件会直接影响 Claude 的行为，从 dotfiles 首次导入到本机时（包括新设备的第一次同步）需要你确认，防止来路不明的配置静默生效。其他配置文件照常自动同步。

### 删除过的配置文件为什么会问我怎么处理？

CC_Sync 在本机维护一份同步账本（`.sync_state.json`），记录每个配置文件最后同步时的状态。当发现某个文件在别的设备上被删除、但本机还留有副本时，会问你：删除本机副本（跟随删除）、保留在本机（以后不再询问、也不推回）、还是推回仓库（撤销删除）。这样就不会出现“在 A 设备上删掉的配置又被 B 设备推了回来”的情况。

### dotfiles 仓库可以是公开的吗？

应保持私有，因为其中存放个人配置。GitHub 返回 dotfiles 仓库为公开状态时会中止同步，但查询失败只会产生警告；出现此警告时，请自行确认可见性。CC_Sync 工作仓库也应保持私有，因为其中会存放设备名称和任务文本。

### 仓库是用 SSH 克隆的也能同步吗？

可以。比较远程地址时会做归一化处理，同一个仓库的 SSH 和 HTTPS 地址视为一致。

### 新设备怎么恢复

1. 安装并检查[前提条件](#前提条件)，然后登录拥有私有仓库的 GitHub 账户。
2. 在 Windows 的 **Git Bash** 或 macOS/Linux 的 **Terminal** 中，将**之前创建的同一个私有工作仓库**克隆到配置的工作区目录内：`gh repo clone "<your-username>/cc-sync-workspace"`。
3. 用 `gh repo clone "<your-username>/<dotfiles-repo>"` 将**现有的私有 dotfiles 仓库**克隆到单独的文件夹，并在向导中填写这个本地路径。填写新的空路径会启动仓库创建流程，不会克隆已有配置。
4. 运行 `cd cc-sync-workspace` 进入工作副本，再执行 `bash sync.sh`。填写已克隆的 dotfiles 路径、开启仓库同步，并包含此工作副本所在的父文件夹。向导会接着执行完整同步。
5. 在 `cc-sync-workspace` 目录打开 **Claude Code**，注册唯一的设备名，之后通过 `/sync` 同步。敏感配置的首次导入和任务处理按技能的确认流程进行。
6. 继续在 **Claude Code** 中说“恢复所有模块”（按清单中锁定的版本恢复）

## 作者

VRPSPshinOvO

## 许可证

[MIT License](./LICENSE)

CC_Sync 按 MIT 许可证分发。Git、Bash、Python、GitHub CLI 和 Claude Code 需要单独安装，遵循各自的许可证或使用条款。模块管理器安装的第三方技能保留其上游许可证，本项目的 MIT 许可证不会改变这些模块的授权方式。
