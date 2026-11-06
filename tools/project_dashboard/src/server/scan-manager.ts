import fs from "node:fs";
import path from "node:path";
import type { ScanChanges, ScanResult, ScanSummary, Snapshot } from "../shared/types.js";
import { collectSnapshot } from "./collector.js";
import { diffSnapshots } from "./scan-changes.js";

const HISTORY_LIMIT = 20;

interface CacheFile {
  latest: Snapshot | null;
  history: ScanSummary[];
}

export class ScanBusyError extends Error {
  /** 初始化扫描管理器依赖或扫描繁忙错误信息。 */
  constructor() {
    super("正在扫描，请稍后再试");
  }
}

/**
 * 扫描只读仓库；唯一的写入是 `.cache/` 里的扫描缓存。
 * cacheDir 为 null 时不落盘（测试用）。
 */
export class ScanManager {
  private latest: Snapshot | null = null;
  private lastChanges: ScanChanges | null = null;
  private history: ScanSummary[] = [];
  private running = false;

  /** 初始化扫描管理器依赖或扫描繁忙错误信息。 */
  constructor(
    private readonly projectRoot: string,
    private readonly cacheDir: string | null,
    private readonly collect: (root: string) => Promise<Snapshot> = collectSnapshot,
  ) {}

  /** 读取本地历史后立即重扫，避免把缓存当作当前状态。 */
  async initialize(): Promise<void> {
    const cached = this.readCache();
    if (cached) {
      this.history = cached.history;
      this.latest = cached.latest;
    }
    await this.scan();
  }

  /** 返回最近成功采集的快照。 */
  getSnapshot(): Snapshot | null {
    return this.latest;
  }

  /** 返回最近两次成功扫描之间的差异。 */
  getLastChanges(): ScanChanges | null {
    return this.lastChanges;
  }

  /** 返回受数量限制的扫描摘要。 */
  getHistory(): ScanSummary[] {
    return this.history;
  }

  /** 串行采集快照并更新历史，失败时释放扫描锁以便重试。 */
  async scan(): Promise<ScanResult> {
    if (this.running) throw new ScanBusyError();
    this.running = true;
    try {
      const previous = this.latest;
      const snapshot = await this.collect(this.projectRoot);
      const changes = diffSnapshots(previous, snapshot);
      this.latest = snapshot;
      this.lastChanges = changes;
      this.history = [
        ...this.history,
        {
          scanId: snapshot.scanId,
          scannedAt: snapshot.scannedAt,
          overallPct: snapshot.overview.overallPct,
          currentMilestoneId: snapshot.overview.currentMilestoneId,
          nextItemId: snapshot.overview.next?.itemId ?? null,
          uncommittedCount: snapshot.overview.uncommittedCount,
          changedCount: changes.changed.length,
        },
      ].slice(-HISTORY_LIMIT);
      this.writeCache();
      return { snapshot, changes };
    } finally {
      this.running = false;
    }
  }

  /** 确定缓存文件位置，测试禁用缓存时返回空值。 */
  private cachePath(): string | null {
    return this.cacheDir ? path.join(this.cacheDir, "scans.json") : null;
  }

  /** 读取可用扫描历史，损坏缓存不影响新扫描。 */
  private readCache(): CacheFile | null {
    const file = this.cachePath();
    if (!file) return null;
    try {
      const parsed = JSON.parse(fs.readFileSync(file, "utf8")) as CacheFile;
      if (!Array.isArray(parsed.history) || !Array.isArray(parsed.latest?.milestones) || !parsed.latest?.overview) return null;
      parsed.history = parsed.history.slice(-HISTORY_LIMIT);
      return parsed;
    } catch {
      return null;
    }
  }

  /** 只在控制台缓存目录保存结果，落盘失败不阻止页面使用。 */
  private writeCache(): void {
    const file = this.cachePath();
    if (!file) return;
    try {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      const payload: CacheFile = { latest: this.latest, history: this.history };
      fs.writeFileSync(file, JSON.stringify(payload));
    } catch {
      // 缓存写失败不影响控制台使用
    }
  }
}
