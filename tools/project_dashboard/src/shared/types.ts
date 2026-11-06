// 控制台前后端共用类型。状态只由服务端从仓库推出，前端只读展示。

export type ItemStatus = "PASS" | "REVIEW" | "IMPLEMENTING" | "DISPATCHED" | "BLOCKED" | "OPEN" | "UNKNOWN";

export const STATUS_LABEL: Record<ItemStatus, string> = {
  PASS: "已验收",
  REVIEW: "待验收",
  IMPLEMENTING: "进行中",
  DISPATCHED: "已派出",
  BLOCKED: "阻塞",
  OPEN: "未开始",
  UNKNOWN: "未知",
};

// ── 登记表（doc/方案与数据/控制台登记.json，制作人维护，只读）──

export interface RegistryItem {
  id: string;
  name: string;
  owner?: string;
  dispatchKey?: string;
  evidence?: string[];
  acceptance?: string;
}

export interface RegistryMilestone {
  id: string;
  name: string;
  owner: string;
  dependsOn: string[];
  parallel?: boolean;
  dispatchKey?: string;
  items: RegistryItem[];
}

export interface RegistryFlowNode {
  id: string;
  name: string;
  item: string;
  next: string[];
}

export interface RegistryLayer {
  id: string;
  name: string;
  paths: string[];
}

export interface Registry {
  version: string;
  updated: string;
  owner: string;
  milestones: RegistryMilestone[];
  flow: RegistryFlowNode[];
  layers: RegistryLayer[];
}

// ── 台账解析结果 ──

export interface DispatchRow {
  title: string;
  owner: string;
  status: string;
  evidence: string;
}

export interface DispatchBlocker {
  date: string;
  title: string;
  impact: string;
  release: string;
  /** 影响列以「已解除」开头视为已解除 */
  resolved: boolean;
}

export interface LockRow {
  who: string;
  where: string;
  start: string;
  end: string;
  /** 止为空 */
  active: boolean;
  /** 从「起」解析出的毫秒时间戳；解析不出为 null */
  startedAtMs: number | null;
  /** 持锁小时数，仅 active 且能解析时有值 */
  heldHours: number | null;
  /** 持锁超过 2 小时 */
  stale: boolean;
}

export interface GitFile {
  status: string;
  path: string;
  owner: string;
}

// ── 派生结果 ──

export interface ItemView {
  id: string;
  name: string;
  milestoneId: string;
  owner: string;
  status: ItemStatus;
  /** 状态是由哪条规则推出来的，给抽屉显示 */
  reason: string;
  evidence: { path: string; exists: boolean }[];
  acceptance: string | null;
  dispatchKey: string | null;
  dispatchRow: DispatchRow | null;
  isNext: boolean;
  heldBy: LockRow[];
}

export interface MilestoneView {
  id: string;
  name: string;
  owner: string;
  dependsOn: string[];
  parallel: boolean;
  status: ItemStatus;
  passCount: number;
  reviewCount: number;
  total: number;
  progressPct: number;
  /** 依赖是否全部 PASS */
  depsMet: boolean;
  isNext: boolean;
  dispatchKey: string | null;
  planAcceptance: string[];
  items: ItemView[];
}

export interface NextInfo {
  milestoneId: string;
  milestoneName: string;
  itemId: string;
  itemName: string;
  owner: string;
  status: ItemStatus;
  unlocks: string;
}

export interface FlowNodeView {
  id: string;
  name: string;
  itemId: string;
  status: ItemStatus;
  isNext: boolean;
  next: string[];
}

export interface ScriptNode {
  id: string;
  path: string;
  kind: "script" | "scene";
  layerId: string;
  extra?: string;
}

export interface ScriptEdge {
  from: string;
  to: string;
  kind: "extends" | "preload" | "load" | "ext_resource";
  violation: boolean;
}

export interface LayerView {
  id: string;
  name: string;
  paths: string[];
  nodeIds: string[];
  started: boolean;
}

export interface ArchitectureView {
  layers: LayerView[];
  nodes: ScriptNode[];
  edges: ScriptEdge[];
  clientExists: boolean;
}

export interface SourceInfo {
  name: string;
  path: string;
  readAt: string;
  ok: boolean;
  note?: string;
}

export interface DecisionInfo {
  count: number;
  latest: string | null;
}

export interface Overview {
  currentMilestoneId: string | null;
  currentMilestoneName: string | null;
  overallPct: number;
  currentPct: number;
  milestoneDone: number;
  milestoneTotal: number;
  reviewItems: number;
  blockerCount: number;
  lockCount: number;
  uncommittedCount: number;
  next: NextInfo | null;
  recentEvidence: { title: string; status: string; evidence: string }[];
}

export interface Snapshot {
  scanId: string;
  scannedAt: string;
  projectRoot: string;
  registryVersion: string;
  overview: Overview;
  milestones: MilestoneView[];
  flow: FlowNodeView[];
  architecture: ArchitectureView;
  dispatchRows: DispatchRow[];
  blockers: DispatchBlocker[];
  iterationBlocker: string | null;
  locks: LockRow[];
  decisions: DecisionInfo;
  git: { available: boolean; total: number; byOwner: Record<string, number>; files: GitFile[] };
  sources: SourceInfo[];
  warnings: string[];
}

// ── 扫描差异与历史 ──

export interface NodeChange {
  id: string;
  name: string;
  from: ItemStatus | null;
  to: ItemStatus;
}

export interface ScanChanges {
  hasPrevious: boolean;
  changed: NodeChange[];
  nextFrom: string | null;
  nextTo: string | null;
  uncommittedDelta: number;
  summary: string;
}

export interface ScanSummary {
  scanId: string;
  scannedAt: string;
  overallPct: number;
  currentMilestoneId: string | null;
  nextItemId: string | null;
  uncommittedCount: number;
  changedCount: number;
}

export interface ScanResult {
  snapshot: Snapshot;
  changes: ScanChanges;
}
