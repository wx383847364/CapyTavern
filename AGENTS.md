# CapyTavern 项目指令

## 需求和修复交付

每次完成需求或 Bug 修复后，都要从本次修改后的同一份工程构建 macOS App、Web 测试端和可供 Git 检出的试玩版本。

1. 在仓库根目录运行 `python3 tools/client/build_debug.py`，更新 `build/debug/CapyTavern.app` 与 `build/debug/web/`。
2. 启动新版 App 和 Web 测试端，确认能进入本次涉及的场景或功能。Web 使用 `python3 tools/client/build_debug.py --serve` 提供本地预览。
3. 核对本次源码与素材、相关测试和两套 `build/debug/` 产物一同列入 Git 提交候选。Mac 可执行文件沿用 Git LFS。提交和推送按[现有 Git 规则](doc/长期主文档/协作与执行/Git%20提交与确认规则.md)执行。
4. 交付时给出 App 路径、Web 地址或入口、验证结果和 Git 状态。任何一端构建或启动失败时，说明实际失败步骤与产物状态。
