#!/usr/bin/env bash

set -euo pipefail

# 把仓库内的 .githooks 设为当前仓库的 hooksPath，
# 让 hook 随仓库维护，而不是散落在每个人本地的 .git/hooks 里。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/.githooks/_common"

if ! resolve_python_command; then
  echo "[error] 未找到 Python 3.8+。Git hooks 需要 Python 校验提交规范。" >&2
  echo "[hint] Windows 安装 Python 后确保 python 或 py 在 PATH 中；macOS/Linux 安装 python3。" >&2
  exit 1
fi

chmod +x "${REPO_ROOT}/.githooks/_common" 2>/dev/null || true
chmod +x "${REPO_ROOT}/.githooks/commit-msg" 2>/dev/null || true
chmod +x "${REPO_ROOT}/.githooks/pre-commit" 2>/dev/null || true
chmod +x "${REPO_ROOT}/tools/doc_maintenance/next_commit_id.py" 2>/dev/null || true
chmod +x "${REPO_ROOT}/tools/doc_maintenance/check_commit_message.py" 2>/dev/null || true
chmod +x "${REPO_ROOT}/tools/repo_maintenance/install_git_hooks.sh" 2>/dev/null || true

git -C "${REPO_ROOT}" config core.hooksPath .githooks

echo "[ok] core.hooksPath 已设置为 .githooks"
echo "[ok] 提交时会校验八位编号，并拦截运行态与生成物"
echo "[ok] Python: ${PYTHON_CMD[*]}"
