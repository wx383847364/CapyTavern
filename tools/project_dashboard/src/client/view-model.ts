import type { ArchitectureView, FlowNodeView, ItemStatus, MilestoneView } from "../shared/types.js";

export type PageId = "overview" | "milestones" | "architecture" | "flow" | "risk";

export const PAGES: { id: PageId; no: string; title: string; hint: string }[] = [
  { id: "overview", no: "01", title: "项目总览", hint: "OVERVIEW" },
  { id: "milestones", no: "02", title: "里程碑导航图", hint: "MILESTONE MAP" },
  { id: "architecture", no: "03", title: "项目架构图", hint: "ARCHITECTURE" },
  { id: "flow", no: "04", title: "功能导流图", hint: "PLAYER FLOW" },
  { id: "risk", no: "05", title: "进度与风险", hint: "DELIVERY & RISK" },
];

/** 将地址片段映射为已登记页面，未知地址返回总览。 */
export function pageFromHash(hash: string): PageId {
  const id = hash.replace(/^#\/?/, "") as PageId;
  return PAGES.some(/* 判断是否存在符合条件的条目。 */ page => page.id === id) ? id : "overview";
}

export type Selection =
  | { type: "item"; id: string }
  | { type: "milestone"; id: string }
  | { type: "flow"; id: string }
  | { type: "script"; id: string };

/** 把业务状态映射为统一配色类。 */
export function statusClass(status: ItemStatus): string {
  return `st-${status.toLowerCase()}`;
}

/** 显示本地扫描时间，无效日期保留原文。 */
export function formatTime(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  const pad = /* 将时分秒补齐两位供扫描时间展示。 */ (value: number): string => String(value).padStart(2, "0");
  return `${date.getMonth() + 1}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

// ── 里程碑导航图 ──

export const MILESTONE_NODE_WIDTH = 304;
const MILESTONE_HEADER_HEIGHT = 139;
const MILESTONE_ITEM_HEIGHT = 40;
const MILESTONE_FOOTER = 14;

/** 按展开子项数量计算图节点高度，给布局预留完整空间。 */
export function milestoneNodeHeight(itemCount: number, expanded: boolean): number {
  return MILESTONE_HEADER_HEIGHT + (expanded ? itemCount * MILESTONE_ITEM_HEIGHT + MILESTONE_FOOTER : 0);
}

export interface GraphEdgeSpec {
  id: string;
  source: string;
  target: string;
  dashed: boolean;
  label?: string;
  kind: "chain" | "parallel" | "flow";
}

/** 依赖边：源里程碑未 PASS 时画虚线；并行支线加「不挡玩法」标签 */
export function milestoneEdges(milestones: MilestoneView[]): GraphEdgeSpec[] {
  const byId = new Map(milestones.map(/* 提取里程碑的展示数据。 */ milestone => [milestone.id, milestone]));
  const edges: GraphEdgeSpec[] = [];
  for (const milestone of milestones) {
    for (const dep of milestone.dependsOn) {
      const source = byId.get(dep);
      edges.push({
        id: `${dep}->${milestone.id}`,
        source: dep,
        target: milestone.id,
        dashed: source ? source.status !== "PASS" : true,
        label: milestone.parallel ? "并行支线，不挡玩法" : undefined,
        kind: milestone.parallel ? "parallel" : "chain",
      });
    }
  }
  return edges;
}

/** 默认展开 NEXT 所属里程碑，便于直接看到下一步。 */
export function defaultExpanded(milestones: MilestoneView[]): Record<string, boolean> {
  const result: Record<string, boolean> = {};
  for (const milestone of milestones) result[milestone.id] = milestone.isNext;
  return result;
}

// ── 功能导流图 ──

export const FLOW_NODE_WIDTH = 168;
export const FLOW_NODE_HEIGHT = 74;

/** 按登记表生成玩家流程边，未验收路径显示虚线。 */
export function flowEdges(flow: FlowNodeView[]): GraphEdgeSpec[] {
  const byId = new Map(flow.map(/* 提取条目的展示数据。 */ node => [node.id, node]));
  const edges: GraphEdgeSpec[] = [];
  for (const node of flow) {
    for (const target of node.next) {
      const to = byId.get(target);
      edges.push({
        id: `${node.id}->${target}`,
        source: node.id,
        target,
        // 起点还没 PASS 的路径，玩家现在走不过去
        dashed: node.status !== "PASS" || !to,
        kind: "flow",
      });
    }
  }
  return edges;
}

/** 玩家现在能走到哪：从第一个节点沿 next 走，遇到非 PASS 的节点就停在它那里 */
export function reachableFlowIds(flow: FlowNodeView[]): Set<string> {
  const byId = new Map(flow.map(/* 提取条目的展示数据。 */ node => [node.id, node]));
  const reached = new Set<string>();
  if (flow.length === 0) return reached;
  const queue = [flow[0].id];
  while (queue.length > 0) {
    const id = queue.shift()!;
    if (reached.has(id)) continue;
    const node = byId.get(id);
    if (!node) continue;
    reached.add(id);
    if (node.status === "PASS") queue.push(...node.next);
  }
  return reached;
}

// ── 项目架构图（泳道，自己排版，确定性）──

export const ARCH_NODE_WIDTH = 210;
export const ARCH_NODE_HEIGHT = 52;
const ARCH_GAP_X = 24;
const ARCH_GAP_Y = 18;
const ARCH_LANE_PAD = 20;
const ARCH_LANE_HEADER = 44;
const ARCH_LANE_GAP = 16;
const ARCH_MIN_LANE_HEIGHT = 104;
const ARCH_COLUMNS = 4;
export const ARCH_LANE_LEFT = 150;

export interface ArchLaneLayout {
  id: string;
  name: string;
  started: boolean;
  y: number;
  height: number;
  width: number;
}

export interface ArchNodeLayout {
  id: string;
  laneId: string;
  x: number;
  y: number;
}

/** 按登记层固定排列泳道，保留空层并为文件计算位置。 */
export function layoutArchitecture(arch: ArchitectureView): { lanes: ArchLaneLayout[]; nodes: ArchNodeLayout[]; width: number } {
  const width = ARCH_LANE_LEFT + ARCH_LANE_PAD * 2 + ARCH_COLUMNS * ARCH_NODE_WIDTH + (ARCH_COLUMNS - 1) * ARCH_GAP_X;
  const lanes: ArchLaneLayout[] = [];
  const nodes: ArchNodeLayout[] = [];
  let cursor = 0;
  for (const layer of arch.layers) {
    const rows = Math.max(1, Math.ceil(layer.nodeIds.length / ARCH_COLUMNS));
    const contentHeight = rows * ARCH_NODE_HEIGHT + (rows - 1) * ARCH_GAP_Y;
    const height = Math.max(ARCH_MIN_LANE_HEIGHT, ARCH_LANE_HEADER + contentHeight + ARCH_LANE_PAD);
    lanes.push({ id: layer.id, name: layer.name, started: layer.started, y: cursor, height, width });
    layer.nodeIds.forEach(/* 为当前条目补齐派生展示数据。 */ (nodeId, index) => {
      const column = index % ARCH_COLUMNS;
      const row = Math.floor(index / ARCH_COLUMNS);
      nodes.push({
        id: nodeId,
        laneId: layer.id,
        x: ARCH_LANE_LEFT + ARCH_LANE_PAD + column * (ARCH_NODE_WIDTH + ARCH_GAP_X),
        y: cursor + ARCH_LANE_HEADER + row * (ARCH_NODE_HEIGHT + ARCH_GAP_Y),
      });
    });
    cursor += height + ARCH_LANE_GAP;
  }
  return { lanes, nodes, width };
}
