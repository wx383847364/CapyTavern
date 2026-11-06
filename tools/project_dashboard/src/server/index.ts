import path from "node:path";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";
import express from "express";
import { createServer as createViteServer } from "vite";
import { createApiApp } from "./app.js";
import { ScanManager } from "./scan-manager.js";

const dashboardRoot = path.resolve(fileURLToPath(new URL("../../", import.meta.url)));
const projectRoot = path.resolve(dashboardRoot, "../..");
// 固定监听本机 4318；4317 留给 UB 控制台。
const host = "127.0.0.1";
const port = 4318;

const manager = new ScanManager(projectRoot, path.join(dashboardRoot, ".cache"));
await manager.initialize();
const app = createApiApp(manager);
// Vite 热更新复用本服务，避免与 UB 的默认热更新端口冲突。
const server = createServer(app);

if (process.env.NODE_ENV === "production") {
  const clientRoot = path.join(dashboardRoot, "dist/client");
  app.use(express.static(clientRoot, { index: false, fallthrough: true }));
  app.get("/{*splat}", /* 响应当前操作并更新对应数据或页面选择。 */ (_request, response) => response.sendFile(path.join(clientRoot, "index.html")));
} else {
  const vite = await createViteServer({ root: dashboardRoot, server: { middlewareMode: true, hmr: { server, host } }, appType: "spa" });
  app.use(vite.middlewares);
}

server.listen(port, host, /* 响应当前操作并更新对应数据或页面选择。 */ () => {
  process.stdout.write(`CapyTavern 项目控制台：http://${host}:${port}\n`);
});
server.on("error", /* 响应当前操作并更新对应数据或页面选择。 */ error => {
  process.stderr.write(`控制台启动失败：${(error as Error).message}\n`);
  process.exit(1);
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, /* 响应当前操作并更新对应数据或页面选择。 */ () => {
    server.close();
    process.exit(0);
  });
}
