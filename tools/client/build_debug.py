#!/usr/bin/env python3
"""构建本机试玩用 Mac App 和 Web 包，或启动 Web 预览。"""

import argparse
import ctypes
import fcntl
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit


class PreviewHandler(SimpleHTTPRequestHandler):
    """从固定的 Web 路径提供试玩资源，每次请求读取当前导出。"""

    def end_headers(self):
        """阻止浏览器为下一次试玩复用旧的引擎脚本或资源包。"""
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def send_head(self):
        """把旧首页引到 Web 入口，仅提供网页导出目录内的文件。"""
        path = urlsplit(self.path).path
        if path in {"/", "/index.html", "/web"}:
            self.send_response(302)
            self.send_header("Location", "/web/")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None
        if not path.startswith("/web/"):
            self.send_error(404)
            return None
        self.path = self.path[len("/web"):]
        # 旧预览的条件请求也要读取现有文件，避免时间戳相同导致缓存命中。
        del self.headers["If-Modified-Since"]
        return super().send_head()


def run_godot(project, *options):
    """执行一个导入或导出步骤，检查 Godot 打印的错误及退出状态。"""
    result = subprocess.run(
        ["godot", "--headless", "--path", str(project), *options],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
    )
    if result.returncode or any("ERROR:" in line for line in result.stdout.splitlines()):
        print(result.stdout, file=sys.stderr, end="")
        raise RuntimeError(f"Godot 步骤失败 {options[0]}")


def publish(candidate, destination):
    """用 macOS 的目录交换一次更新两种产物，现有目录在交换前仍可读取。"""
    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        raise RuntimeError(f"构建目标必须是目录 {destination}")
    if not destination.exists():
        candidate.rename(destination)
        return

    swap = ctypes.CDLL(None, use_errno=True).renamex_np
    swap.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    swap.restype = ctypes.c_int
    rename_swap = 0x00000002  # macOS <sys/stdio.h> 中的 RENAME_SWAP。
    if swap(os.fsencode(candidate), os.fsencode(destination), rename_swap) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def build_debug(repo, build):
    """从同一快照导出两种产物，全部验证通过后替换上一次试玩包。"""
    build.mkdir(exist_ok=True)
    lock_fd = os.open(build, os.O_RDONLY)
    try:
        # 以构建目录作进程锁，串行发布，同时避免在目录里留下锁文件。
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        with tempfile.TemporaryDirectory(prefix=".debug-", dir=build) as directory:
            staging = Path(directory)
            project = staging / "client"
            shutil.copytree(repo / "client", project, ignore=shutil.ignore_patterns(".godot", ".DS_Store"))
            candidate = staging / "next"
            web = candidate / "web"
            web.mkdir(parents=True)

            print("导入 Godot 工程", flush=True)
            run_godot(project, "--import")
            app = candidate / "CapyTavern.app"
            print("导出 Mac App 和 Web", flush=True)
            run_godot(project, "--export-release", "macOS", str(app))
            run_godot(project, "--export-release", "Web", str(web / "index.html"))
            shutil.copy2(project / "data/fonts/NotoSansSC-OFL.txt", web)

            # 导出可能成功退出却缺少文件，发布前核对可执行文件和网页启动资源。
            if not (app / "Contents/Info.plist").is_file() or not any(
                path.is_file() and os.access(path, os.X_OK) for path in (app / "Contents/MacOS").glob("*")
            ):
                raise RuntimeError("Mac App 缺少入口文件")
            for name in ("index.html", "index.js", "index.wasm", "index.pck"):
                path = web / name
                if not path.is_file() or path.stat().st_size == 0:
                    raise RuntimeError(f"Web 导出缺少 {name}")
            publish(candidate, build / "debug")
    finally:
        os.close(lock_fd)


def main():
    """构建试玩包，或在本机 8765 端口预览上一次完整产物。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve", action="store_true", help="启动本地 Web 预览")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    build = repo / "build"

    try:
        if args.serve:
            web = build / "debug/web"
            if not (web / "index.html").is_file():
                raise RuntimeError("请先构建试玩包")
            factory = partial(PreviewHandler, directory=str(web))
            with ThreadingHTTPServer(("127.0.0.1", 8765), factory) as server:
                print("http://127.0.0.1:8765/web/", flush=True)
                server.serve_forever()
        else:
            build_debug(repo, build)
            print(f"试玩包已更新 {build / 'debug'}")
    except KeyboardInterrupt:
        return 130
    except (OSError, RuntimeError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
