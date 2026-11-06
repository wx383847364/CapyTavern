import type { ScanChanges, ScanResult, ScanSummary, Snapshot } from "../shared/types.js";

/** 解析接口响应；非成功响应优先展示服务端错误信息。 */
async function readJson<T>(response: Response): Promise<T> {
  if (!response.ok) {
    let message = `请求失败（${response.status}）`;
    try {
      const body = (await response.json()) as { error?: string };
      if (body.error) message = body.error;
    } catch {
      // 保留默认文案
    }
    throw new Error(message);
  }
  return (await response.json()) as T;
}

/** 读取服务端最近快照，不在前端自行推导业务状态。 */
export async function fetchSnapshot(): Promise<{ snapshot: Snapshot; changes: ScanChanges | null }> {
  return readJson(await fetch("/api/snapshot"));
}

/** 请求重读固定数据源并返回扫描差异。 */
export async function runScan(): Promise<ScanResult> {
  return readJson(await fetch("/api/scans", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }));
}

/** 读取服务端保留的扫描摘要。 */
export async function fetchHistory(): Promise<ScanSummary[]> {
  return readJson(await fetch("/api/scans/history"));
}
