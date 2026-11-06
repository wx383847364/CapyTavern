import type {
  DispatchRow,
  FlowNodeView,
  ItemStatus,
  ItemView,
  LockRow,
  MilestoneView,
  NextInfo,
  Registry,
  RegistryItem,
  RegistryMilestone,
} from "../shared/types.js";

export interface DeriveInput {
  registry: Registry;
  /** dispatch.md 主表；null 表示读不到 */
  dispatchRows: DispatchRow[] | null;
  locks: LockRow[];
  planAcceptance: Record<string, string[]>;
  fileExists: (relativePath: string) => boolean;
}

export interface DeriveResult {
  milestones: MilestoneView[];
  flow: FlowNodeView[];
  next: NextInfo | null;
  currentMilestoneId: string | null;
  overallPct: number;
}

const DISPATCH_STATUS: { prefix: string; status: ItemStatus }[] = [
  { prefix: "阻塞", status: "BLOCKED" },
  { prefix: "已验收", status: "PASS" },
  { prefix: "待验收", status: "REVIEW" },
  { prefix: "进行中", status: "IMPLEMENTING" },
  { prefix: "已派出", status: "DISPATCHED" },
];

/** 四舍五入到整数；分母为 0 时为 0 */
export function percent(done: number, total: number): number {
  if (total <= 0) return 0;
  return Math.round((done / total) * 100);
}

/** 从台账状态前缀推导业务状态，忽略 Markdown 装饰。 */
export function statusFromDispatchWord(word: string): ItemStatus | null {
  const normalized = word.replace(/[*`\s]/g, "");
  const hit = DISPATCH_STATUS.find(/* 按标识或状态定位对应的台账条目。 */ entry => normalized.startsWith(entry.prefix));
  return hit ? hit.status : null;
}

/** dispatch.md 主表第一列以 key 开头的第一行 */
export function findDispatchRow(rows: DispatchRow[], key: string): DispatchRow | null {
  return rows.find(/* 按标识或状态定位对应的台账条目。 */ row => row.title.startsWith(key)) ?? null;
}

interface ItemStatusResult {
  status: ItemStatus;
  reason: string;
  row: DispatchRow | null;
}

/** 子项状态：取第一条命中的规则（方案 §4） */
export function deriveItemStatus(
  item: RegistryItem,
  milestone: RegistryMilestone,
  input: Pick<DeriveInput, "dispatchRows" | "fileExists">,
): ItemStatusResult {
  const rows = input.dispatchRows;
  if (rows) {
    if (item.dispatchKey) {
      const row = findDispatchRow(rows, item.dispatchKey);
      const mapped = row ? statusFromDispatchWord(row.status) : null;
      if (row && mapped) return { status: mapped, reason: `规则 1：任务单「${row.status}」命中子项 dispatchKey`, row };
    }
    if (milestone.dispatchKey) {
      const row = findDispatchRow(rows, milestone.dispatchKey);
      const mapped = row ? statusFromDispatchWord(row.status) : null;
      if (row && mapped === "PASS") return { status: "PASS", reason: "规则 2：所属里程碑任务单已验收", row };
      if (row && mapped === "BLOCKED") return { status: "BLOCKED", reason: "规则 2：所属里程碑任务单阻塞", row };
    }
  }
  const evidence = item.evidence ?? [];
  if (evidence.length > 0 && evidence.every(/* 确认集合内全部条目满足当前条件。 */ path => input.fileExists(path))) {
    return { status: "REVIEW", reason: "规则 3：证据文件都在，还没验收", row: null };
  }
  const needsDispatch = Boolean(item.dispatchKey || milestone.dispatchKey);
  if (!rows && needsDispatch) return { status: "UNKNOWN", reason: "dispatch.md 读不到，推不出状态", row: null };
  return {
    status: "OPEN",
    reason: evidence.length > 0 ? "规则 4：证据文件不齐，视为未开始" : "规则 4：无证据、无任务单命中",
    row: null,
  };
}

/** 汇总子项状态，仅全部通过时里程碑才算通过。 */
export function deriveMilestoneStatus(items: ItemStatus[]): ItemStatus {
  if (items.length > 0 && items.every(/* 确认集合内全部条目满足当前条件。 */ status => status === "PASS")) return "PASS";
  if (items.includes("BLOCKED")) return "BLOCKED";
  if (items.some(/* 判断是否存在符合条件的条目。 */ status => status !== "OPEN")) return items.every(/* 确认集合内全部条目满足当前条件。 */ status => status === "UNKNOWN") ? "UNKNOWN" : "IMPLEMENTING";
  return "OPEN";
}

const NEXT_ITEM_ORDER: ItemStatus[] = ["OPEN", "DISPATCHED", "IMPLEMENTING", "BLOCKED"];

/** 里程碑内的 NEXT 子项：先取第一个未完成且不是待验收的，没有再取第一个待验收 */
export function pickNextItem(items: { id: string; status: ItemStatus }[]): string | null {
  const open = items.find(/* 按标识或状态定位对应的子项。 */ item => NEXT_ITEM_ORDER.includes(item.status));
  if (open) return open.id;
  const unknown = items.find(/* 按标识或状态定位对应的子项。 */ item => item.status === "UNKNOWN");
  if (unknown) return unknown.id;
  const review = items.find(/* 按标识或状态定位对应的子项。 */ item => item.status === "REVIEW");
  return review ? review.id : null;
}

/** 根据任务及里程碑关键词关联当前写锁。 */
function lockMentions(lock: LockRow, tokens: string[]): boolean {
  return tokens.some(/* 判断是否存在符合条件的条目。 */ token => token && lock.where.includes(token));
}

/** 按登记顺序推导各子项、里程碑、进度及唯一主链 NEXT。 */
export function derive(input: DeriveInput): DeriveResult {
  const { registry } = input;
  const activeLocks = input.locks.filter(/* 筛选写锁中符合统计或展示条件的记录。 */ lock => lock.active);

  const base = registry.milestones.map(/* 提取里程碑的展示数据。 */ milestone => {
    const items: ItemView[] = milestone.items.map(/* 提取里程碑的展示数据。 */ item => {
      const result = deriveItemStatus(item, milestone, input);
      const tokens = [item.id, milestone.id === item.id ? "" : `${milestone.id} `, milestone.dispatchKey ?? "", item.dispatchKey ?? ""];
      return {
        id: item.id,
        name: item.name,
        milestoneId: milestone.id,
        owner: item.owner ?? milestone.owner,
        status: result.status,
        reason: result.reason,
        evidence: (item.evidence ?? []).map(/* 构造子项的展示数据。 */ path => ({ path, exists: input.fileExists(path) })),
        acceptance: item.acceptance ?? null,
        dispatchKey: item.dispatchKey ?? milestone.dispatchKey ?? null,
        dispatchRow: result.row ?? (input.dispatchRows && milestone.dispatchKey ? findDispatchRow(input.dispatchRows, milestone.dispatchKey) : null),
        isNext: false,
        heldBy: activeLocks.filter(/* 筛选写锁中符合统计或展示条件的记录。 */ lock => lockMentions(lock, tokens)),
      };
    });
    const statuses = items.map(/* 提取子项的展示数据。 */ item => item.status);
    const passCount = statuses.filter(/* 筛选条目中符合统计或展示条件的记录。 */ status => status === "PASS").length;
    return {
      definition: milestone,
      view: {
        id: milestone.id,
        name: milestone.name,
        owner: milestone.owner,
        dependsOn: milestone.dependsOn,
        parallel: Boolean(milestone.parallel),
        status: deriveMilestoneStatus(statuses),
        passCount,
        reviewCount: statuses.filter(/* 筛选条目中符合统计或展示条件的记录。 */ status => status === "REVIEW").length,
        total: items.length,
        progressPct: percent(passCount, items.length),
        depsMet: false,
        isNext: false,
        dispatchKey: milestone.dispatchKey ?? null,
        planAcceptance: input.planAcceptance[milestone.id] ?? [],
        items,
      } as MilestoneView,
    };
  });

  const views = base.map(/* 提取条目的展示数据。 */ entry => entry.view);
  const byId = new Map(views.map(/* 提取条目的展示数据。 */ view => [view.id, view]));
  for (const view of views) {
    view.depsMet = view.dependsOn.every(/* 确认集合内全部条目满足当前条件。 */ dep => byId.get(dep)?.status === "PASS");
  }

  // NEXT：依赖全 PASS、自己未 PASS 的非并行里程碑里排最前的
  const nextMilestone = views.find(/* 按标识或状态定位对应的条目。 */ view => !view.parallel && view.status !== "PASS" && view.depsMet) ?? null;
  let next: NextInfo | null = null;
  if (nextMilestone) {
    nextMilestone.isNext = true;
    const nextItemId = pickNextItem(nextMilestone.items);
    const item = nextMilestone.items.find(/* 按标识或状态定位对应的里程碑。 */ entry => entry.id === nextItemId);
    if (item) {
      item.isNext = true;
      const remaining = nextMilestone.items.filter(/* 筛选里程碑中符合统计或展示条件的记录。 */ entry => entry.status !== "PASS" && entry.id !== item.id);
      const dependents = views.filter(/* 筛选条目中符合统计或展示条件的记录。 */ view => view.dependsOn.includes(nextMilestone.id) && !view.parallel).map(/* 提取里程碑的展示数据。 */ view => `${view.id} ${view.name}`);
      const parallelDependents = views.filter(/* 筛选条目中符合统计或展示条件的记录。 */ view => view.dependsOn.includes(nextMilestone.id) && view.parallel).map(/* 提取里程碑的展示数据。 */ view => `${view.id} ${view.name}`);
      const following = nextMilestone.items.find(/* 按标识或状态定位对应的里程碑。 */ entry => entry.status !== "PASS" && entry.id !== item.id);
      let unlocks: string;
      if (remaining.length === 0) {
        const all = [...dependents, ...parallelDependents];
        unlocks = all.length > 0 ? `做完并验收后可开 ${all.join("、")}` : "做完并验收后本条主链完成";
      } else {
        unlocks = following ? `本项完成后仍需${following.status === "REVIEW" ? "验收" : "完成"} ${following.id} ${following.name}，里程碑全部验收后解锁下阶段` : "";
      }
      next = {
        milestoneId: nextMilestone.id,
        milestoneName: nextMilestone.name,
        itemId: item.id,
        itemName: item.name,
        owner: item.owner,
        status: item.status,
        unlocks,
      };
    }
  }

  const itemById = new Map(views.flatMap(/* 汇总条目关联对象，供详情或违规标记使用。 */ view => view.items).map(/* 提取子项的展示数据。 */ item => [item.id, item]));
  const flow: FlowNodeView[] = registry.flow.map(/* 构造条目的展示数据。 */ node => ({
    id: node.id,
    name: node.name,
    itemId: node.item,
    status: itemById.get(node.item)?.status ?? "UNKNOWN",
    isNext: itemById.get(node.item)?.isNext ?? false,
    next: node.next,
  }));

  const allItems = views.flatMap(/* 汇总条目关联对象，供详情或违规标记使用。 */ view => view.items);
  const overallPct = percent(allItems.filter(/* 筛选子项中符合统计或展示条件的记录。 */ item => item.status === "PASS").length, allItems.length);
  const currentMilestoneId = nextMilestone?.id ?? (views.length > 0 ? views[views.length - 1].id : null);

  return { milestones: views, flow, next, currentMilestoneId, overallPct };
}
