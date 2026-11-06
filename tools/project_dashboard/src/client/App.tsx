import { useCallback, useEffect, useState } from "react";
import type { ScanChanges as ScanChangesData, ScanSummary, Snapshot } from "../shared/types.js";
import { fetchHistory, fetchSnapshot, runScan } from "./api";
import { ArchitecturePage } from "./components/ArchitecturePage";
import { Drawer } from "./components/Drawer";
import { FlowPage } from "./components/FlowPage";
import { Legend } from "./components/common";
import { MilestonePage } from "./components/MilestonePage";
import { OverviewPage } from "./components/OverviewPage";
import { RiskPage } from "./components/RiskPage";
import { ScanChanges } from "./components/ScanChanges";
import { PAGES, formatTime, pageFromHash, type PageId, type Selection } from "./view-model";

/** 显示五页只读控制台，扫描结果仅保存在页面状态中。 */
export function App() {
  const [page, setPage] = useState<PageId>(/* 响应当前操作并更新对应数据或页面选择。 */ () => pageFromHash(window.location.hash));
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [changes, setChanges] = useState<ScanChangesData | null>(null);
  const [showChanges, setShowChanges] = useState(false);
  const [history, setHistory] = useState<ScanSummary[]>([]);
  const [selection, setSelection] = useState<Selection | null>(null);
  const [scanning, setScanning] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refreshHistory = useCallback(/* 响应当前操作并更新对应数据或页面选择。 */ () => {
    fetchHistory().then(setHistory).catch(/* 保留主流程并处理读取失败。 */ () => undefined);
  }, []);

  useEffect(/* 同步页面副作用，并在卸载时清理监听或异步结果。 */ () => {
    fetchSnapshot()
      .then(/* 接收异步结果并更新当前视图。 */ result => setSnapshot(result.snapshot))
      .catch(/* 保留主流程并处理读取失败。 */ reason => setError((reason as Error).message));
    refreshHistory();
  }, [refreshHistory]);

  useEffect(/* 同步页面副作用，并在卸载时清理监听或异步结果。 */ () => {
    const onHash = /* 跟随浏览器地址切换当前页面。 */ (): void => setPage(pageFromHash(window.location.hash));
    window.addEventListener("hashchange", onHash);
    return /* 卸载时移除地址变化监听。 */ () => window.removeEventListener("hashchange", onHash);
  }, []);

  const goto = /* 切换页面并关闭旧详情，避免保留跨页选择。 */ (next: PageId): void => {
    window.location.hash = `/${next}`;
    setSelection(null);
  };

  const scan = /* 触发只读扫描并更新快照与差异，结束后恢复按钮。 */ async (): Promise<void> => {
    setScanning(true);
    setError(null);
    try {
      const result = await runScan();
      setSnapshot(result.snapshot);
      setChanges(result.changes);
      setShowChanges(true);
      refreshHistory();
    } catch (reason) {
      setError((reason as Error).message);
    } finally {
      setScanning(false);
    }
  };

  const select = useCallback(/* 响应当前操作并更新对应数据或页面选择。 */ (next: Selection) => setSelection(next), []);
  const next = snapshot?.overview.next ?? null;

  return (
    <div className="app-shell">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark">CT</span>
          <div>
            <b>CAPYTAVERN</b>
            <small>卡皮酒馆 · 项目控制台</small>
          </div>
        </div>
        <div className="header-context">
          <span>{snapshot ? `${snapshot.overview.currentMilestoneId ?? "—"} ${snapshot.overview.currentMilestoneName ?? ""}` : "载入中"}</span>
          <small>{snapshot ? `上次扫描 ${formatTime(snapshot.scannedAt)} · 只读` : "只读控制台"}</small>
        </div>
        <div className="scan-actions">
          <button className="primary" onClick={/* 触发只读扫描并展示本次差异。 */ () => void scan()} disabled={scanning}>
            {scanning ? "扫描中…" : "快速扫描"}
          </button>
        </div>
      </header>

      <div className="workspace-shell">
        <aside className="sidebar">
          <div className="sidebar-heading">
            <span>NAVIGATION</span>
            <small>{snapshot ? `${snapshot.overview.overallPct}% · ${snapshot.overview.milestoneDone}/${snapshot.overview.milestoneTotal} 个里程碑` : ""}</small>
          </div>
          <nav>
            {PAGES.map(/* 切换到对应的控制台页面。 */ entry => (
              <button key={entry.id} className={page === entry.id ? "active" : ""} onClick={/* 切换到对应的控制台页面。 */ () => goto(entry.id)} data-testid={`nav-${entry.id}`}>
                <i>{entry.no}</i>
                <span>{entry.title}</span>
                <small>{entry.hint}</small>
              </button>
            ))}
          </nav>
          <Legend />
          <div className="sidebar-footer">
            <b>READ ONLY</b>
            <small>状态只从登记表、dispatch.md、locks.md、git 和 client/ 推出，页面不能手改。</small>
          </div>
        </aside>

        <main className="content-shell">
          {error && (
            <div className="error-banner" role="alert">
              <span>{error}</span>
              <button onClick={/* 关闭当前错误提示。 */ () => setError(null)} aria-label="关闭错误">×</button>
            </div>
          )}
          {showChanges && changes && <ScanChanges changes={changes} onClose={/* 关闭扫描差异提示。 */ () => setShowChanges(false)} />}
          {!snapshot && !error && <p className="loading">正在读取仓库…</p>}
          {snapshot && (
            <>
              {next && page !== "overview" && (
                <button className="next-strip" onClick={/* 响应当前操作并更新对应数据或页面选择。 */ () => select({ type: "item", id: next.itemId })}>
                  <span>NEXT</span> {next.itemId} {next.itemName} · {next.owner}
                </button>
              )}
              {page === "overview" && <OverviewPage snapshot={snapshot} onSelect={select} />}
              {page === "milestones" && <MilestonePage snapshot={snapshot} selected={selection} onSelect={select} />}
              {page === "architecture" && <ArchitecturePage snapshot={snapshot} selected={selection} onSelect={select} />}
              {page === "flow" && <FlowPage snapshot={snapshot} onSelect={select} />}
              {page === "risk" && <RiskPage snapshot={snapshot} history={history} onSelect={select} />}
              <Drawer snapshot={snapshot} selection={selection} onClose={/* 关闭当前详情，保留扫描快照。 */ () => setSelection(null)} />
            </>
          )}
        </main>
      </div>
    </div>
  );
}
