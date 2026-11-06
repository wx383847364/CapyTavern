import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import type { Overview, Registry, Snapshot, SourceInfo } from "../shared/types.js";
import { derive } from "./derive.js";
import { countByOwner, readGitStatus } from "./git-status.js";
import { scanClient } from "./godot-scan.js";
import {
  parseDecisions,
  parseDispatchBlockers,
  parseDispatchRows,
  parseIterationBlocker,
  parseLocks,
  parsePlanAcceptance,
  validateRegistry,
} from "./parsers.js";

/** 数据源相对路径。登记表和计划只读，台账只读。 */
export const SOURCE_PATHS = {
  registry: "doc/方案与数据/控制台登记.json",
  plan: "doc/方案与数据/Godot程序开发计划 v0.1.md",
  dispatch: "dispatch.md",
  locks: "locks.md",
  iteration: "doc/迭代记录/迭代记录索引.md",
  decisions: "doc/裁决.md",
} as const;

interface ReadResult {
  text: string | null;
  info: SourceInfo;
}

/** 只读指定来源，失败时返回来源错误供页面展示。 */
function readSource(projectRoot: string, name: string, relativePath: string, now: Date): ReadResult {
  try {
    const text = fs.readFileSync(path.join(projectRoot, relativePath), "utf8");
    return { text, info: { name, path: relativePath, readAt: now.toISOString(), ok: true } };
  } catch (error) {
    return {
      text: null,
      info: { name, path: relativePath, readAt: now.toISOString(), ok: false, note: (error as NodeJS.ErrnoException).code ?? "读取失败" },
    };
  }
}

export interface CollectOptions {
  now?: Date;
}

/** 汇总固定数据源并推导快照，不运行工程或测试。 */
export async function collectSnapshot(projectRoot: string, options: CollectOptions = {}): Promise<Snapshot> {
  const now = options.now ?? new Date();
  const warnings: string[] = [];
  const sources: SourceInfo[] = [];

  const registryRead = readSource(projectRoot, "控制台登记", SOURCE_PATHS.registry, now);
  sources.push(registryRead.info);
  let registry: Registry | null = null;
  if (registryRead.text !== null) {
    try {
      const parsed = validateRegistry(JSON.parse(registryRead.text));
      registry = parsed.registry;
      for (const error of parsed.errors) warnings.push(`登记表：${error}`);
    } catch (error) {
      warnings.push(`登记表不是合法 JSON：${(error as Error).message}`);
    }
  } else {
    warnings.push(`登记表读不到：${SOURCE_PATHS.registry}`);
  }
  if (!registry) {
    registry = { version: "?", updated: "", owner: "", milestones: [], flow: [], layers: [] };
    registryRead.info.ok = false;
  }

  const dispatchRead = readSource(projectRoot, "派发台账", SOURCE_PATHS.dispatch, now);
  const locksRead = readSource(projectRoot, "写锁台账", SOURCE_PATHS.locks, now);
  const planRead = readSource(projectRoot, "程序开发计划", SOURCE_PATHS.plan, now);
  const iterationRead = readSource(projectRoot, "迭代记录索引", SOURCE_PATHS.iteration, now);
  const decisionsRead = readSource(projectRoot, "裁决", SOURCE_PATHS.decisions, now);
  sources.push(dispatchRead.info, locksRead.info, planRead.info, iterationRead.info, decisionsRead.info);

  const dispatchRows = dispatchRead.text !== null ? parseDispatchRows(dispatchRead.text) : null;
  const blockers = dispatchRead.text !== null ? parseDispatchBlockers(dispatchRead.text) : [];
  const locks = locksRead.text !== null ? parseLocks(locksRead.text, now.getTime()) : [];
  const planAcceptance = planRead.text !== null ? parsePlanAcceptance(planRead.text) : {};
  const decisions = decisionsRead.text !== null ? parseDecisions(decisionsRead.text) : { count: 0, latest: null };
  const iterationBlocker = iterationRead.text !== null ? parseIterationBlocker(iterationRead.text) : null;

  const derived = derive({
    registry,
    dispatchRows,
    locks,
    planAcceptance,
    fileExists: /* 响应当前操作并更新对应数据或页面选择。 */ relativePath => {
      // 只认仓库内的相对路径，不让登记表读到仓库之外
      const resolved = path.resolve(projectRoot, relativePath);
      if (!resolved.startsWith(path.resolve(projectRoot) + path.sep)) return false;
      return fs.existsSync(resolved);
    },
  });

  const architecture = scanClient(projectRoot, registry.layers);
  const git = await readGitStatus(projectRoot);
  sources.push({ name: "git status", path: "git status --porcelain", readAt: now.toISOString(), ok: git.available });
  sources.push({
    name: "client 脚本与场景",
    path: "client/**/*.gd, *.tscn",
    readAt: now.toISOString(),
    ok: architecture.clientExists,
    note: architecture.clientExists ? `${architecture.nodes.length} 个文件` : "client/ 不存在",
  });

  const current = derived.milestones.find(/* 按标识或状态定位对应的里程碑。 */ milestone => milestone.id === derived.currentMilestoneId) ?? null;
  const activeBlockers = blockers.filter(/* 筛选写锁中符合统计或展示条件的记录。 */ blocker => !blocker.resolved);
  const overview: Overview = {
    currentMilestoneId: current?.id ?? null,
    currentMilestoneName: current?.name ?? null,
    overallPct: derived.overallPct,
    currentPct: current?.progressPct ?? 0,
    milestoneDone: derived.milestones.filter(/* 筛选里程碑中符合统计或展示条件的记录。 */ milestone => milestone.status === "PASS").length,
    milestoneTotal: derived.milestones.length,
    reviewItems: derived.milestones.reduce(/* 累计里程碑统计值。 */ (sum, milestone) => sum + milestone.reviewCount, 0),
    blockerCount: activeBlockers.length,
    lockCount: locks.filter(/* 筛选写锁中符合统计或展示条件的记录。 */ lock => lock.active).length,
    uncommittedCount: git.files.length,
    next: derived.next,
    recentEvidence: (dispatchRows ?? [])
      .filter(/* 筛选台账条目中符合统计或展示条件的记录。 */ row => row.evidence.trim().length > 0)
      .slice(-5)
      .reverse()
      .map(/* 构造台账条目的展示数据。 */ row => ({ title: row.title, status: row.status, evidence: row.evidence })),
  };

  return {
    scanId: randomUUID(),
    scannedAt: now.toISOString(),
    projectRoot,
    registryVersion: registry.version,
    overview,
    milestones: derived.milestones,
    flow: derived.flow,
    architecture,
    dispatchRows: dispatchRows ?? [],
    blockers,
    iterationBlocker,
    locks,
    decisions,
    git: { available: git.available, total: git.files.length, byOwner: countByOwner(git.files), files: git.files },
    sources,
    warnings,
  };
}
