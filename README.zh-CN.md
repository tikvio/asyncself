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
mkdir -p "$HOME/.config/asyncself"
cp local-config/secrets.env.example "$HOME/.config/asyncself/secrets.env"
chmod 600 "$HOME/.config/asyncself/secrets.env"

# 填写 profile 与仓库外的 secrets.env 后：
./start_asyncself.sh --profile github --check
./start_asyncself.sh --profile github
```

GitLab 用户将 `github` 替换为 `gitlab`。新配置使用 `ASYNCSELF_*`；旧的
`start_symphony.sh` 和 `SYMPHONY_*` 作为兼容入口继续可用。详细的 Linear 状态、集成、
安全边界和排错方法请阅读英文主 README 链接的文档。

## 当前边界

这是基于 OpenAI Symphony 改造的实验性个人项目，不是托管服务，也不会替人判断代码是否
应该合并。首个公开快照会执行单元测试、语法检查、配置检查和密钥模式扫描，但按当前发布
计划，不把“用全新公开账号在全新机器上重新跑完整闭环”作为首次上传的阻塞项。

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
