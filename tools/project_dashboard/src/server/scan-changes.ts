import type { NodeChange, ScanChanges, Snapshot } from "../shared/types.js";

/** 建立里程碑和子项的状态索引供前后扫描比较。 */
function nodeStatuses(snapshot: Snapshot): Map<string, { name: string; status: NodeChange["to"] }> {
  const map = new Map<string, { name: string; status: NodeChange["to"] }>();
  for (const milestone of snapshot.milestones) {
    map.set(milestone.id, { name: milestone.name, status: milestone.status });
    for (const item of milestone.items) map.set(item.id, { name: item.name, status: item.status });
  }
  return map;
}

/** 本次和上次比：哪些里程碑 / 子项状态变了，NEXT 有没有移动，未提交数变化 */
export function diffSnapshots(previous: Snapshot | null, current: Snapshot): ScanChanges {
  if (!previous) {
    return {
      hasPrevious: false,
      changed: [],
      nextFrom: null,
      nextTo: current.overview.next?.itemId ?? null,
      uncommittedDelta: 0,
      summary: "首次扫描，没有可比较的上一次",
    };
  }
  const before = nodeStatuses(previous);
  const after = nodeStatuses(current);
  const changed: NodeChange[] = [];
  for (const [id, now] of after) {
    const old = before.get(id);
    if (!old) changed.push({ id, name: now.name, from: null, to: now.status });
    else if (old.status !== now.status) changed.push({ id, name: now.name, from: old.status, to: now.status });
  }
  const nextFrom = previous.overview.next?.itemId ?? null;
  const nextTo = current.overview.next?.itemId ?? null;
  const uncommittedDelta = current.overview.uncommittedCount - previous.overview.uncommittedCount;

  const parts: string[] = [];
  if (changed.length > 0) parts.push(`${changed.length} 个节点状态变化`);
  if (nextFrom !== nextTo) parts.push(`NEXT：${nextFrom ?? "无"} → ${nextTo ?? "无"}`);
  if (uncommittedDelta !== 0) parts.push(`未提交文件 ${uncommittedDelta > 0 ? "+" : ""}${uncommittedDelta}`);
  return {
    hasPrevious: true,
    changed,
    nextFrom,
    nextTo,
    uncommittedDelta,
    summary: parts.length > 0 ? parts.join("；") : "和上次相比没有变化",
  };
}
