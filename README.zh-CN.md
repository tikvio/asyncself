# AsyncSelf

> **你的后台编程员工**
>
> 你写需求。AsyncSelf 写代码。你审核并决定是否合并。

[English](README.md) · [安装配置](docs/SETUP.md) · [完整流程](docs/WORKFLOW.md)

## 不要再守着 Agent 排队

普通的 Agent 工作流虽然加快了写代码，却仍然要求程序员不断重复：交一个任务、等待、
检查、再交下一个任务。代码写得更快了，任务队列仍靠人工推动，专注力也持续被打断。

AsyncSelf 就是为“可以放心去摸鱼”设计的个人自动化：你先把需求写清楚并审核任务 DAG，
它再把可执行任务送入 Linear，让多个隔离的 Codex worker 按依赖并发实现。你只在真正需要
判断时回来——回答问题、审核 PR/MR、决定是否合并。

> **写好计划，离开电脑，回来审核 PR。**
>
> **程序员回来是为了做决定和 Code Review，不是为了维持任务队列运转。**

核心闭环是：

1. 用仓库内的 `spec-planner` 把需求整理成依赖图，先预览，确认后再创建 Linear issues。
2. AsyncSelf 只领取已经满足依赖、人工 gate 和 required label 的任务。
3. 多个任务在独立 workspace 中并发写代码并创建 PR/MR。
4. `In Review -> Merging` 必须由人操作；也可以直接在 GitHub 或 Linear Diffs 中合并。
5. GitHub 显示真实 merged 状态后才显示 `PR merged`，`Waiting Gatekeeper` 不等于已经合并。
6. Issue 到达 `Done` 后，Gatekeeper 更新后继任务的 `dep:` gate，并自动释放下一批任务。
7. `Needs Info` 必须由人在 issue 描述中勾选相应 `human:` gate；仅发表评论不会解锁。

GitHub 是功能最完整的 profile。GitLab profile 支持兼容的 HTTPS GitLab host、MR watcher、
状态闭环与人工授权合并，但 Dashboard 中的 PR/MR 检查和展示功能少于 GitHub。

## 内置 Codex Skills

仓库在 `.codex/skills/` 中提供了覆盖计划和交付流程的 Skills：

| Skill | 用途 |
|---|---|
| [`spec-planner`](.codex/skills/spec-planner/SKILL.md) | 把一个需求整理成经过人工审核的任务 DAG，并写出可直接执行的 Linear issues。 |
| `linear` | 读取和更新当前 Linear issue。 |
| `commit` / `pull` / `push` | 提交代码、同步目标分支、推送分支并创建或更新 PR。 |
| `debug` | 根据 issue、session 和日志定位卡住或失败的任务。 |
| `land` | 在人工批准后处理检查、冲突和 PR 合并。 |
| `release` | 检查许可、测试、版本并发布 AsyncSelf 源码版本。 |

其中 `spec-planner` 是 AsyncSelf 的需求入口。你可以给它一个粗略想法、讨论记录、项目说明
或已有 Markdown spec，它会先澄清产品与架构问题，再决定独立分支或集成分支策略，把需求
拆成无环依赖图，并为每个节点写出完整、可独立执行的 Linear issue。

`spec-planner` 不只是向 Linear 写数据。每次 preview 都会先在本地生成一套可审核产物：
`dag-preview.md`、`preview-graph.md`、`dag-plan.json`，以及 `specs/` 下每个任务各自的 spec。
因此应在安装 Skill 或初始化项目时一次性设置产物位置；一个 Codex 管理多个 AsyncSelf 实例
或业务项目时尤其要配置清楚。之后每次规划都会自动按该规则归档，不再重复询问。

每个 issue 会包含上下文、范围、验收标准、验证方式、labels、分支与 PR/MR 行为以及 Start
Gates。依赖会写成由 Gatekeeper 维护的 `dep:` gate；仍需人决定的内容会写成 `human:` gate，
并只让相关 issue 从 `Needs Info` 开始。其余任务根据依赖分别进入 `Waiting` 或 `Todo`，因此
AsyncSelf 能按依赖顺序推进，并在允许的地方并发写代码。

### 配置 `spec-planner`

AsyncSelf 的运行 profile 和 `spec-planner` 配置有关联，但不是同一套配置。先按下方“最短
启动流程”配置 AsyncSelf，再在安装或项目初始化时一次性设置以下内容：

- Skill 直接从本仓库运行时会自动找到内置 pipeline；如果把 Skill 复制到用户级 Codex
  Skills 目录，则必须把 `ASYNCSELF_HOME` 设为 AsyncSelf 仓库的绝对路径。
- 默认集中归档结构为
  `~/.local/state/asyncself/specs/<实例>/<项目>/<时间>-<需求>/`。一个 Codex 管理多个实例或
  项目时，应设置 `ASYNCSELF_SPEC_INSTANCE` 和 `ASYNCSELF_SPEC_PROJECT`。
- 设置 `ASYNCSELF_SPEC_STORE_ROOT` 可以移动整个集中归档目录，同时保留实例/项目分层。
  设置 `ASYNCSELF_SPEC_OUTPUT_MODE=adjacent` 则会把产物放到业务项目旁的
  `<项目>.asyncself-specs/`。默认不会写进 AsyncSelf 仓库或业务 Git 仓库内部。
- 兼容变量 `ASYNCSELF_SPEC_OUTPUT_ROOT` 表示当前项目的精确产物根目录；`--out` 的优先级
  更高，只指定某一次 preview 的完整输出目录。
- 每份计划都需要 Linear project slug 和 labels、workflow 路径、业务源码路径、workspace
  根目录、GitHub/GitLab 项目、目标分支、分支策略以及禁止访问的路径。Skill 会从当前项目
  读取已知值，并询问无法可靠推断的重要配置。
- preview 和 dry-run 不需要 Token。只有明确批准后的 `apply --execute` 需要当前进程中存在
  `LINEAR_API_KEY`；planner 不会自动读取 secrets 文件。

示例：

```bash
# 仅当 spec-planner 安装在本仓库之外时需要：
export ASYNCSELF_HOME="/absolute/path/to/asyncself"

# 一个 Codex 管理多个实例或项目时建议明确设置：
export ASYNCSELF_SPEC_INSTANCE="personal"
export ASYNCSELF_SPEC_PROJECT="example-app"

# 可选：移动统一归档根目录，但仍保留实例/项目分层：
export ASYNCSELF_SPEC_STORE_ROOT="$HOME/Documents/asyncself-specs"

# 或者放到业务项目旁边：
# export ASYNCSELF_SPEC_OUTPUT_MODE="adjacent"

# 只在准备执行已批准的 live apply 时，将仓库外密钥加载到当前 shell：
set -a
source "$HOME/.config/asyncself/secrets.env"
set +a
test -n "${LINEAR_API_KEY:-}"  # 只检查是否存在，不打印 Token
```

不要把 Token 写进源 spec、生成的计划、仓库 profile 或命令行。上述项目字段不是密钥，
它们会显示在预览中，供人确认任务究竟会在哪个项目、分支和 workspace 中执行。

在 Codex 中可以这样开始：

> 使用 `$spec-planner` 把这个需求整理成 AsyncSelf DAG，并写出需要的 Linear issues。
> 创建前先给我看完整 DAG、分支方案、labels 和每个 issue 的正文。

`spec-planner` 永远先生成预览和 dry-run；只有你明确批准当前方案后，才会按拓扑顺序真正
创建 Linear issues。详细命令、配置和审批边界见
[`spec-planner/SKILL.md`](.codex/skills/spec-planner/SKILL.md)。

## 运行环境

- Linux：主要目标环境。
- WSL2：Windows 用户的推荐环境，已经运行验证；源码和 workspace 建议放在 `~/code` 等
  Linux 文件系统路径，不要放在 `/mnt/c`。
- macOS：GitLab profile 已运行过。
- 原生 Windows：不推荐，建议安装 WSL2，可获得更一致的 Bash、权限、进程监管和并发
  workspace 行为。

## 最短启动流程

```bash
cd asyncself/elixir
mise trust
mise install
mise exec -- mix setup
cd ..

cp local-config/profiles/github.env.example local-config/profiles/github.env
mkdir -p "$HOME/.config/asyncself/workflows"
cp elixir/WORKFLOW.github.md "$HOME/.config/asyncself/workflows/github.md"
cp local-config/secrets.env.example "$HOME/.config/asyncself/secrets.env"
chmod 600 "$HOME/.config/asyncself/secrets.env" \
  "$HOME/.config/asyncself/workflows/"*.md

# 填写 profile、仓库外 workflow 与 secrets.env 后：
./start_asyncself.sh --profile github --check
./start_asyncself.sh --profile github
```

GitLab 用户改为复制 `local-config/profiles/gitlab.env.example` 和 `elixir/WORKFLOW.md`，
并把外置 workflow 保存为 `$HOME/.config/asyncself/workflows/gitlab.md`。profile 与 workflow
中的 Linear project、required label 和非 `main` 目标分支必须一致；workflow 里所有
`example-*` 值都要替换。

workflow 示例已开启只读 Project Issues 聚合。GitHub Dashboard 写 Linear 默认仍关闭；
只有在 `--check` 通过、并且确实希望从 Dashboard 执行 `In Review -> Merging` 时，才把外置
GitHub workflow 的 `dashboard.linear_actions_enabled` 改为 `true`。

新配置使用 `ASYNCSELF_*`；旧的
`start_symphony.sh` 和 `SYMPHONY_*` 作为兼容入口继续可用。详细的 Linear 状态、集成、
安全边界和排错方法请阅读英文主 README 链接的文档。

## 当前边界

这是基于 OpenAI Symphony 改造的实验性个人项目，不是托管服务，也不会替人判断代码是否
应该合并。GitHub profile 已在 WSL 中通过真实端到端验证，包括 `Needs Info`、依赖释放、
隔离 workspace、PR 创建、Gatekeeper 合并、Linear Diffs 合并以及 `Done` 对账。该结果不是
使用全新公开账号和全新机器完成的认证；GitLab profile 也没有在同一次验证中重跑完整闭环。

上游来源和基线见 [SHOWCASE_BASELINE.md](SHOWCASE_BASELINE.md)，许可证边界见
[LICENSING.md](LICENSING.md)。AsyncSelf 是独立项目，不代表 OpenAI 官方产品，也未获得
OpenAI 背书。

## 许可证

AsyncSelf 采用混合许可，是 **source-available（源码可见）** 项目：

- Symphony 派生核心、对其源码的直接修改、启动器、公开配置和文档使用 Apache License
  2.0，并保留上游声明；
- `local-tools/` 与 `.codex/skills/spec-planner/` 是独立新增组件，使用 PolyForm
  Noncommercial 1.0.0；
- 商业使用上述 PolyForm 覆盖的组件，需要通过 **mynewhao@foxmail.com** 单独取得授权。

准确的目录边界以及未来继续修改 Symphony 源码时的规则，以
[LICENSING.md](LICENSING.md) 为准；提交代码前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。
