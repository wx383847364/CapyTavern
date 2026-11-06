import express, { type Express } from "express";
import { ScanBusyError, type ScanManager } from "./scan-manager.js";

/** 只接受本机页面发起的请求；没有 Origin（curl、同源 GET）放行 */
function localOriginOnly(request: express.Request, response: express.Response, next: express.NextFunction): void {
  const origin = request.get("origin");
  if (!origin) return next();
  try {
    const hostname = new URL(origin).hostname;
    if (hostname === "127.0.0.1" || hostname === "localhost" || hostname === "[::1]") return next();
  } catch {
    // 非法 Origin 一并拒绝
  }
  response.status(403).json({ error: "只接受本机控制台页面的请求" });
}

/**
 * 只读控制台接口。不提供任意路径读取、命令执行和状态编辑；
 * POST /api/scans 只是让服务端重读一遍仓库。
 */
export function createApiApp(manager: ScanManager): Express {
  const app = express();
  app.disable("x-powered-by");
  app.use(express.json({ limit: "1kb" }));

  app.get("/api/snapshot", /* 响应当前操作并更新对应数据或页面选择。 */ (_request, response) => {
    const snapshot = manager.getSnapshot();
    if (!snapshot) return response.status(503).json({ error: "还没有扫描结果" });
    return response.json({ snapshot, changes: manager.getLastChanges() });
  });

  app.post("/api/scans", localOriginOnly, /* 响应当前操作并更新对应数据或页面选择。 */ async (_request, response) => {
    try {
      return response.json(await manager.scan());
    } catch (error) {
      if (error instanceof ScanBusyError) return response.status(409).json({ error: error.message });
      throw error;
    }
  });

  app.get("/api/scans/history", /* 响应当前操作并更新对应数据或页面选择。 */ (_request, response) => response.json(manager.getHistory()));

  return app;
}
