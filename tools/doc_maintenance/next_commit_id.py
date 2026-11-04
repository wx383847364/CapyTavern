#!/usr/bin/env python3
"""按模块从 git log 计算下一个八位提交编号。"""

import argparse
import re
import subprocess
import sys

MODULES = {
    "210": "项目总览、主文档索引、研发入口",
    "220": "架构与边界、工程骨架、目录结构",
    "230": "协作与执行、提交规则、文档与仓库工具",
    "240": "方案与玩法设计（长期主文档稳定区）",
    "250": "数值、配表、数据方案",
    "260": "迭代记录",
    "270": "客户端工程与逻辑",
    "280": "表现与资源",
    "290": "服务端与协议",
    "610": "通用工程初始化、跨模块、无法归类",
}

TITLE_RE = re.compile(r"^\[(\d{8})\]")


def repo_root():
    try:
        output = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.PIPE,
            text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as error:
        print(f"[next-id] 不在 git 仓库内，或 git 不可用：{error}", file=sys.stderr)
        raise SystemExit(1)
    return output.strip()


def read_subjects(root):
    try:
        output = subprocess.check_output(
            ["git", "-C", root, "log", "--all", "--format=%s"],
            stderr=subprocess.PIPE,
            text=True,
        )
    except subprocess.CalledProcessError:
        return []
    return [line.strip() for line in output.splitlines() if line.strip()]


def next_sequence(subjects, module):
    highest = 0
    for subject in subjects:
        match = TITLE_RE.match(subject)
        if not match:
            continue
        commit_id = match.group(1)
        if commit_id[:3] != module:
            continue
        highest = max(highest, int(commit_id[3:]))
    return highest + 1


def main():
    parser = argparse.ArgumentParser(description="按模块计算下一个八位提交编号")
    parser.add_argument("--module", required=True, help="三位模块编号，例如 230")
    args = parser.parse_args()

    if args.module not in MODULES:
        print(
            f"[next-id] 未知模块 {args.module}。可用模块：{', '.join(sorted(MODULES))}",
            file=sys.stderr,
        )
        return 1

    sequence = next_sequence(read_subjects(repo_root()), args.module)
    if sequence > 99999:
        print("[next-id] 该模块流水号已用完（99999）。", file=sys.stderr)
        return 1

    print(f"[{args.module}{sequence:05d}]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
