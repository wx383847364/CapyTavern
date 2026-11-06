import ELK from "elkjs/lib/elk.bundled.js";

const elk = new ELK();

export interface LayoutNode {
  id: string;
  width: number;
  height: number;
}

export interface LayoutEdge {
  id: string;
  source: string;
  target: string;
}

export type LayoutPositions = Map<string, { x: number; y: number }>;

/** 用 ELK 分层布局算节点坐标；ELK 出错时退回横向等距排布，页面照常能看 */
export async function layoutGraph(
  nodes: LayoutNode[],
  edges: LayoutEdge[],
  options: { direction: "RIGHT" | "DOWN"; spacing?: number; layerSpacing?: number },
): Promise<LayoutPositions> {
  const positions: LayoutPositions = new Map();
  try {
    const result = await elk.layout({
      id: "root",
      layoutOptions: {
        "elk.algorithm": "layered",
        "elk.direction": options.direction,
        "elk.spacing.nodeNode": String(options.spacing ?? 36),
        "elk.layered.spacing.nodeNodeBetweenLayers": String(options.layerSpacing ?? 72),
        "elk.layered.cycleBreaking.strategy": "GREEDY",
        "elk.layered.nodePlacement.strategy": "NETWORK_SIMPLEX",
      },
      children: nodes.map(/* 构造图节点的展示数据。 */ node => ({ id: node.id, width: node.width, height: node.height })),
      edges: edges.map(/* 构造引用边的展示数据。 */ edge => ({ id: edge.id, sources: [edge.source], targets: [edge.target] })),
    });
    for (const child of result.children ?? []) positions.set(child.id, { x: child.x ?? 0, y: child.y ?? 0 });
  } catch {
    let cursor = 0;
    for (const node of nodes) {
      positions.set(node.id, { x: cursor, y: 0 });
      cursor += node.width + 60;
    }
  }
  return positions;
}

/**
 * 深度优先找回边（指向祖先的边）。导流图里「回酒馆」会成环，
 * 排版时去掉回边，节点才能按玩家流程从左到右排开；回边仍然照常画出来。
 */
export function dropBackEdges(nodes: LayoutNode[], edges: LayoutEdge[]): LayoutEdge[] {
  const out = new Map<string, LayoutEdge[]>();
  for (const edge of edges) out.set(edge.source, [...(out.get(edge.source) ?? []), edge]);
  const state = new Map<string, "visiting" | "done">();
  const back = new Set<string>();
  const visit = (id: string): void => {
    state.set(id, "visiting");
    for (const edge of out.get(id) ?? []) {
      const status = state.get(edge.target);
      if (status === "visiting") back.add(edge.id);
      else if (!status) visit(edge.target);
    }
    state.set(id, "done");
  };
  for (const node of nodes) if (!state.has(node.id)) visit(node.id);
  return edges.filter(edge => !back.has(edge.id));
}
