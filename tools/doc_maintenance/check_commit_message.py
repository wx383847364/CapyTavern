#!/usr/bin/env python3
"""校验 CapyTavern 提交标题是否符合 [TMMSSSSS] 类型：摘要。"""

import argparse
import re
import sys
from pathlib import Path

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

TYPES = {
    "架构": "工程初始化、分层、目录、边界、引擎接入",
    "文档": "长期主文档、索引、说明、模板",
    "流程": "协作规则、提交规则、hook、仓库工具",
    "玩法": "玩法、规则、系统方案落地",
    "配置": "配表、数值、数据文件",
    "客户端": "客户端逻辑、场景、存档、本地 Mock",
    "表现": "UI、美术、Spine、特效、适配",
    "服务端": "服务端、协议、数据契约",
    "测试": "测试、回归、验收脚本与证据",
    "修复": "修 bug、回滚错误改动",
    "构建": "构建、导出、打包、流水线",
    "合并": "merge commit",
    "提交": "兜底，无法归入以上类型时使用",
}

TITLE_RE = re.compile(r"^\[(\d{8})\][ \t]+([^：:\s]+)[：:][ \t]*(\S.*)$")
REBASE_PREFIXES = ("fixup!", "squash!", "amend!")
SUMMARY_LIMIT = 50


def first_content_line(message):
    for raw in message.splitlines():
        line = raw.rstrip()
        if not line.strip():
            continue
        if line.lstrip().startswith("#"):
            continue
        return line.strip()
    return ""


def validate(message):
    errors = []
    warnings = []

    title = first_content_line(message)
    if not title:
        return ["提交信息为空。"], warnings

    if title.startswith(REBASE_PREFIXES):
        return [], warnings

    match = TITLE_RE.match(title)
    if not match:
        errors.append(
            "标题不符合格式。期望：[TMMSSSSS] 类型：摘要，"
            "例如 [23000001] 流程：建立文档体系与提交规范"
        )
        return errors, warnings

    commit_id, commit_type, summary = match.groups()
    module = commit_id[:3]

    if module not in MODULES:
        errors.append(
            f"模块编号 {module} 不在模块表中。可用模块：{', '.join(sorted(MODULES))}"
        )

    if commit_type not in TYPES:
        errors.append(
            f"类型「{commit_type}」不在词表中。可用类型：{', '.join(TYPES)}"
        )

    if not summary.strip():
        errors.append("摘要不能为空。")
    elif len(summary.strip()) > SUMMARY_LIMIT:
        errors.append(
            f"摘要 {len(summary.strip())} 字，超过 {SUMMARY_LIMIT} 字上限；请写短。"
        )

    if summary.strip().endswith("。"):
        warnings.append("摘要结尾不要加句号。")
    if re.search(r"[\u4e00-\u9fff]:", title):
        warnings.append("标题请使用全角冒号「：」。")

    return errors, warnings


def read_message(args):
    if args.message is not None:
        return args.message
    path = Path(args.message_file)
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def main():
    parser = argparse.ArgumentParser(description="校验 CapyTavern 提交标题")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--message-file", help="提交信息文件，例如 .git/COMMIT_EDITMSG")
    group.add_argument("--message", help="直接传入提交信息，便于手工测试")
    args = parser.parse_args()

    errors, warnings = validate(read_message(args))

    for warning in warnings:
        print(f"[commit-msg] 提醒：{warning}", file=sys.stderr)

    if errors:
        print("[commit-msg] 提交被拒绝：", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        print("", file=sys.stderr)
        print("  规则见 doc/长期主文档/协作与执行/Git 提交与确认规则.md", file=sys.stderr)
        print(
            "  取号：python3 tools/doc_maintenance/next_commit_id.py --module 230",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
