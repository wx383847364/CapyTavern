import type { DispatchBlocker, DispatchRow, LockRow, Registry } from "../shared/types.js";

/** 把 Markdown 表格的一行拆成单元格；转义的 \| 保留为 | */
export function splitTableRow(line: string): string[] | null {
  const trimmed = line.trim();
  if (!trimmed.startsWith("|")) return null;
  const body = trimmed.replace(/^\|/, "").replace(/\|$/, "");
  const cells: string[] = [];
  let current = "";
  let inCode = false;
  for (let i = 0; i < body.length; i += 1) {
    const ch = body[i];
    if (ch === "`") inCode = !inCode;
    if (ch === "\\" && body[i + 1] === "|") {
      current += "|";
      i += 1;
      continue;
    }
    if (ch === "|" && !inCode) {
      cells.push(current.trim());
      current = "";
      continue;
    }
    current += ch;
  }
  cells.push(current.trim());
  return cells;
}

/** 识别 Markdown 表格分隔行，防止把它当作数据。 */
function isSeparator(cells: string[]): boolean {
  return cells.every(/* 确认集合内全部条目满足当前条件。 */ cell => /^:?-{2,}:?$/.test(cell));
}

/** 找到表头满足 predicate 的第一张表，返回它的数据行（不含表头和分隔行） */
export function readTable(markdown: string, headerMatches: (header: string[]) => boolean): string[][] {
  const lines = markdown.split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    const header = splitTableRow(lines[i]);
    if (!header || !headerMatches(header)) continue;
    const rows: string[][] = [];
    for (let j = i + 1; j < lines.length; j += 1) {
      const cells = splitTableRow(lines[j]);
      if (!cells) {
        if (rows.length > 0 || j > i + 1) break;
        continue;
      }
      if (isSeparator(cells)) continue;
      rows.push(cells);
    }
    return rows;
  }
  return [];
}

/** 从派发表主表读取状态及证据，保持台账顺序。 */
export function parseDispatchRows(markdown: string): DispatchRow[] {
  return readTable(markdown, /* 响应当前操作并更新对应数据或页面选择。 */ header => header[0] === "任务单" && header.length >= 4)
    .filter(/* 筛选条目中符合统计或展示条件的记录。 */ cells => cells.length >= 4)
    .map(/* 构造条目的展示数据。 */ cells => ({ title: cells[0], owner: cells[1], status: cells[2], evidence: cells[3] }));
}

/** 读取阻塞段，并将明确已解除的条目标记为解决。 */
export function parseDispatchBlockers(markdown: string): DispatchBlocker[] {
  return readTable(markdown, /* 响应当前操作并更新对应数据或页面选择。 */ header => header[0] === "日期" && header[1] === "阻塞")
    .filter(/* 筛选条目中符合统计或展示条件的记录。 */ cells => cells.length >= 4)
    .map(/* 构造条目的展示数据。 */ cells => ({
      date: cells[0],
      title: cells[1],
      impact: cells[2],
      release: cells[3],
      resolved: /^已解除/.test(cells[2].replace(/^[\s*`]+/, "")),
    }));
}

/** 「2026-11-05 16:58」或「2026-11-04（补记）」→ 毫秒；没有时间只取当天 00:00 */
export function parseLockTime(text: string): number | null {
  const match = text.match(/(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{1,2}):(\d{2}))?/);
  if (!match) return null;
  const [, year, month, day, hour, minute] = match;
  return new Date(Number(year), Number(month) - 1, Number(day), hour ? Number(hour) : 0, minute ? Number(minute) : 0).getTime();
}

export const STALE_LOCK_HOURS = 2;

/** 解析写锁及持续时间，只有止为空的行算持锁。 */
export function parseLocks(markdown: string, nowMs: number): LockRow[] {
  return readTable(markdown, /* 响应当前操作并更新对应数据或页面选择。 */ header => header[0] === "谁" && header[1] === "改哪")
    .filter(/* 筛选条目中符合统计或展示条件的记录。 */ cells => cells.length >= 4)
    .map(/* 提取条目的展示数据。 */ cells => {
      const [who, where, start, end] = cells;
      const active = end.trim() === "";
      const startedAtMs = parseLockTime(start);
      const heldHours = active && startedAtMs !== null ? Math.max(0, (nowMs - startedAtMs) / 3_600_000) : null;
      return {
        who,
        where,
        start,
        end,
        active,
        startedAtMs,
        heldHours,
        stale: heldHours !== null && heldHours > STALE_LOCK_HOURS,
      };
    });
}

/** 迭代记录索引里「## 最新阻塞」下第一条列表项 */
export function parseIterationBlocker(markdown: string): string | null {
  const lines = markdown.split(/\r?\n/);
  const start = lines.findIndex(/* 响应当前操作并更新对应数据或页面选择。 */ line => /^##\s*最新阻塞/.test(line));
  if (start < 0) return null;
  const items: string[] = [];
  for (let i = start + 1; i < lines.length; i += 1) {
    if (/^##\s/.test(lines[i])) break;
    const match = lines[i].match(/^[-*]\s+(.*)$/);
    if (match) items.push(match[1].trim());
  }
  const joined = items.filter(/* 筛选子项中符合统计或展示条件的记录。 */ item => !/^无[。.]?$/.test(item));
  return joined.length > 0 ? joined.join("；") : null;
}

/** 裁决.md：以「- 日期 | 类别 | …」开头的行 */
export function parseDecisions(markdown: string): { count: number; latest: string | null } {
  const lines = markdown.split(/\r?\n/).filter(/* 筛选条目中符合统计或展示条件的记录。 */ line => /^-\s+\d{4}-\d{2}-\d{2}\s*\|/.test(line));
  return { count: lines.length, latest: lines.length > 0 ? lines[lines.length - 1].replace(/^-\s+/, "") : null };
}

/** Godot 计划里「### P0 工程能导出」小节下的列表项，用来给抽屉显示本里程碑的验收要点 */
export function parsePlanAcceptance(markdown: string): Record<string, string[]> {
  const result: Record<string, string[]> = {};
  const lines = markdown.split(/\r?\n/);
  let current: string | null = null;
  for (const line of lines) {
    const heading = line.match(/^###\s+(P\d)\b/);
    if (heading) {
      current = heading[1];
      result[current] = [];
      continue;
    }
    if (/^#{1,3}\s/.test(line)) {
      current = null;
      continue;
    }
    if (current) {
      const item = line.match(/^[-*]\s+(.*)$/);
      if (item) result[current].push(item[1].trim());
    }
  }
  return result;
}

/** 核对登记表标识及关联，缺省可选集合补为空数组。 */
export function validateRegistry(raw: unknown): { registry: Registry | null; errors: string[] } {
  const errors: string[] = [];
  if (!raw || typeof raw !== "object") return { registry: null, errors: ["登记表不是对象"] };
  const value = raw as Partial<Registry>;
  if (!Array.isArray(value.milestones)) errors.push("缺少 milestones");
  if (errors.length > 0) return { registry: null, errors };

  const milestones = value.milestones!;
  const ids = new Set<string>();
  const itemIds = new Set<string>();
  for (const milestone of milestones) {
    if (!milestone.id || !milestone.name || !Array.isArray(milestone.items)) {
      errors.push(`里程碑缺字段：${JSON.stringify(milestone?.id ?? milestone)}`);
      continue;
    }
    if (ids.has(milestone.id)) errors.push(`里程碑 id 重复：${milestone.id}`);
    ids.add(milestone.id);
    for (const item of milestone.items) {
      if (!item.id || !item.name) errors.push(`子项缺字段：${milestone.id}`);
      else if (itemIds.has(item.id)) errors.push(`子项 id 重复：${item.id}`);
      else itemIds.add(item.id);
    }
  }
  for (const milestone of milestones) {
    for (const dep of milestone.dependsOn ?? []) {
      if (!ids.has(dep)) errors.push(`${milestone.id} 依赖了不存在的里程碑 ${dep}`);
    }
  }
  const flow = value.flow ?? [];
  const flowIds = new Set(flow.map(/* 提取条目的展示数据。 */ node => node.id));
  for (const node of flow) {
    if (!itemIds.has(node.item)) errors.push(`导流节点 ${node.id} 指向不存在的子项 ${node.item}`);
    for (const target of node.next ?? []) {
      if (!flowIds.has(target)) errors.push(`导流节点 ${node.id} 指向不存在的节点 ${target}`);
    }
  }
  if (errors.length > 0) return { registry: null, errors };

  return {
    errors,
    registry: {
      version: value.version ?? "?",
      updated: value.updated ?? "",
      owner: value.owner ?? "",
      milestones: milestones.map(/* 构造里程碑的展示数据。 */ milestone => ({
        ...milestone,
        dependsOn: milestone.dependsOn ?? [],
        items: milestone.items.map(/* 构造里程碑的展示数据。 */ item => ({ ...item, evidence: item.evidence ?? [] })),
      })),
      flow: flow.map(/* 构造条目的展示数据。 */ node => ({ ...node, next: node.next ?? [] })),
      layers: value.layers ?? [],
    },
  };
}
