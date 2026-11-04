# Git 提交与确认规则

本页固定 CapyTavern 的提交标题、八位编号、取号方式、确认口径和 hook 约束。所有人提交前按本页执行。

参考：GatebreakerArena `Client/doc/长期主文档/协作与执行/Git 提交建议与确认规则.md`。差异见文末。

## 1. 标题格式

```text
[TMMSSSSS] 类型：摘要
```

- `TMM`：三位模块编号，取自第 2 节。
- `SSSSS`：五位流水号，每个模块各自从 `00001` 递增。
- `类型`：只能取第 3 节的固定词表。
- `摘要`：一句话说清做了什么，不超过 50 字，结尾不加句号。
- 示例：`[23000001] 流程：建立文档体系与提交规范`

约束：

- 一个提交只做一件事；跨模块的改动拆成多个提交。
- 标题与正文都用中文，专有名词、路径、命令保留原文。
- 不写「优化」「调整一下」「杂项」这类无法验收的摘要。

## 2. 模块编号

| 编号 | 范围 |
|---|---|
| `210` | 项目总览、主文档索引、研发入口 |
| `220` | 架构与边界、工程骨架、目录结构 |
| `230` | 协作与执行、提交规则、文档与仓库工具 |
| `240` | 方案与玩法设计（长期主文档稳定区） |
| `250` | 数值、配表、数据方案 |
| `260` | 迭代记录 |
| `270` | 客户端工程与逻辑：`client/**`（场景、脚本、存档、本地 Mock） |
| `280` | 表现与资源：`client/assets/art/**`、`client/assets/ui/**`、`export/**`、Spine、UI、特效、适配 |
| `290` | 服务端与协议：`server/**`、`protocol/**` |
| `610` | 通用工程初始化、跨模块改动、无法稳定归类 |

选择规则：

- 按「改动主要落在哪」选，不按提交人岗位选。
- 文档与代码混合、确实无法拆分时用 `610`，并在正文说明为什么跨模块。
- 新增模块必须先改本页，再使用；不要在提交里临时发明编号。

## 3. 类型词表

| 类型 | 用于 |
|---|---|
| `架构` | 工程初始化、分层、目录、边界、引擎接入 |
| `文档` | 长期主文档、索引、说明、模板 |
| `流程` | 协作规则、提交规则、hook、仓库工具 |
| `玩法` | 玩法、规则、系统方案落地 |
| `配置` | 配表、数值、数据文件 |
| `客户端` | 客户端逻辑、场景、存档、本地 Mock |
| `表现` | UI、美术、Spine、特效、适配 |
| `服务端` | 服务端、协议、数据契约 |
| `测试` | 测试、回归、验收脚本与证据 |
| `修复` | 修 bug、回滚错误改动 |
| `构建` | 构建、导出、打包、流水线 |
| `合并` | merge commit |
| `提交` | 兜底，无法归入以上类型时使用 |

## 4. 取号

提交前用脚本取号，不要手猜：

```bash
python3 tools/doc_maintenance/next_commit_id.py --module 230
# 输出示例：[23000007]
```

规则：

- 取号依据：`git log --all` 中同模块出现过的最大流水号 + 1。
- 取号后没能提交成功：该号可以复用。
- 一旦提交，不复用、不回退、不为了凑整跳号。
- 两个人同时准备提交时，后提交的人重新取号。
- 脚本只给编号；类型和摘要由提交人写。

## 5. 提交前检查

1. 看差异，确认没有夹带别人的改动、生成物或导出物：

```bash
git status --short
git diff --stat
```

2. 确认 hook 已安装：

```bash
git config --get core.hooksPath
# 期望输出：.githooks
```

没有就执行：

```bash
bash tools/repo_maintenance/install_git_hooks.sh
```

3. 补文档：
   - 工程级改动：补一份迭代记录并更新 `doc/迭代记录/迭代记录索引.md`。
   - 稳定结论变化：更新 `项目总览.md` 和 `主文档索引.md`。
   - 新增长期文档：补进主文档索引的「文档分区」。

4. 只 prepare，不提交：

```bash
git add -N <本轮文件>
git status --short
git diff --stat
```

把文件清单、差异摘要和验证结果交给人，等确认。

## 6. 确认口径（硬规则）

- 默认只 prepare，不 `git commit`、不 `git push`。
- 只有下面这些说法算授权：
  - 「提交」「只提交」：只 commit。
  - 「提交并推送」「提交推送」「推送」：commit + push。
  - 选项 `1`：提交并推送；选项 `2`：只提交。
- 「继续」「可以」「完成」「看起来没问题」都不算提交授权。
- 没有明确说推送，就不 push。
- 提交前发现验证失败、合并冲突、他人未提交改动：先报告，不硬提交。
- 禁止 `git commit --no-verify`。human 明确要求跳过的，事后在迭代记录里补记原因。
- 禁止 `git push --force`。确需强推只用 `--force-with-lease`，并先取得明确同意。
- 远端认证失败：报告失败原因和本地提交状态，不改写历史，不改用 HTTPS 凭据重试。

## 7. 提交信息正文

标题之外写正文，至少说清三件事：

```text
[23000001] 流程：建立文档体系与提交规范

- 建立 doc/ 长期主文档、方案与数据、迭代记录三分区
- 固定 [TMMSSSSS] 标题格式、模块表、类型表和确认口径
- 接入 commit-msg 校验与 next_commit_id.py 取号脚本
- 验证：正例通过、反例被拒；git config core.hooksPath 为 .githooks
```

合并提交也走同一格式，类型写 `合并`：

```text
[61000002] 合并：feature/xxx 合入 main
```

## 8. 远端与凭据

- 本项目统一使用 SSH，`origin` 必须是：

```text
git@github.com:wx383847364/CapyTavern.git
```

- 检查：

```bash
git remote -v
ssh -T git@github.com
```

- 如果 remote 还是 `https://github.com/...`，先切回 SSH 再 `fetch` / `pull` / `push`：

```bash
git remote set-url origin git@github.com:wx383847364/CapyTavern.git
```

- 不使用 HTTPS 用户名、密码、Token 或系统 keychain 里的 HTTPS 凭据。

## 9. Hook 约束

- `core.hooksPath` 必须指向 `.githooks`。
- `commit-msg` 校验：八位编号、模块编号在表内、类型在词表内、摘要非空。
- `fixup!`、`squash!`、`amend!` 开头的交互式 rebase 消息放行。
- 不校验流水号是否连续；取号靠脚本，不靠 hook 猜。
- `pre-commit` 拦截 `locks.md`、`dispatch.md` 和引擎生成物、导出物被误加入暂存区。
- 安装：

```bash
bash tools/repo_maintenance/install_git_hooks.sh
```

## 10. 首次提交建议

工程骨架落地、human 明确说「提交」后使用：

```text
[61000001] 架构：初始化 CapyTavern 单仓骨架
```

正文：

```text
- 建立 doc/ 长期主文档、方案与数据、迭代记录三分区
- 固定 [TMMSSSSS] 提交格式、模块表与确认口径
- 接入 commit-msg / pre-commit hook 与取号脚本
- origin 统一使用 SSH
```

## 11. 与 Gatebreaker 参考规则的差异

- 不做 post-commit 自动改号或 amend 登记；按 `git log` 取号，少一层自动改写历史的 hook。
- merge commit 不强制固定正文条目，统一套用 `[TMMSSSSS] 合并：摘要`。
- 模块表按 CapyTavern 的目录扩展了 `270` / `280` / `290`，不是直接照搬。
- 提交确认比参考文档更严：CapyTavern 默认只 prepare，human 明确说「提交」才 commit。
