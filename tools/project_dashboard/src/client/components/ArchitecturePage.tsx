import { useMemo } from "react";
import {
  Background,
  BackgroundVariant,
  Controls,
  Handle,
  MarkerType,
  Position,
  ReactFlow,
  ReactFlowProvider,
  type Edge,
  type Node,
  type NodeProps,
  type NodeTypes,
} from "@xyflow/react";
import type { ArchitectureView, Snapshot } from "../../shared/types.js";
import { ARCH_LANE_LEFT, ARCH_NODE_HEIGHT, ARCH_NODE_WIDTH, layoutArchitecture, type Selection } from "../view-model";

interface LaneData extends Record<string, unknown> {
  name: string;
  started: boolean;
  count: number;
  paths: string[];
}

/** 显示架构泳道及未开工提示，空层仍占据图中位置。 */
function LaneNode({ data }: NodeProps) {
  const lane = data as LaneData;
  return (
    <div className={`lane ${lane.started ? "" : "lane-empty"}`}>
      <div className="lane-label">
        <b>{lane.name}</b>
        <span>{lane.started ? `${lane.count} 个文件` : "未开工"}</span>
      </div>
      <div className="lane-paths">{lane.paths.length > 0 ? lane.paths.join("  ") : ""}</div>
      {!lane.started && <div className="lane-placeholder">这一层的目录还没有脚本或场景</div>}
    </div>
  );
}

interface ScriptData extends Record<string, unknown> {
  path: string;
  kind: "script" | "scene";
  hasViolation: boolean;
  selected: boolean;
  onSelect: (selection: Selection) => void;
}

/** 显示脚本或场景卡片，点击后查看静态引用。 */
function ScriptNode({ data }: NodeProps) {
  const script = data as ScriptData;
  const name = script.path.split("/").pop() ?? script.path;
  return (
    <button
      className={`script-node ${script.kind} ${script.hasViolation ? "violation" : ""} ${script.selected ? "is-selected" : ""}`}
      data-testid={`script-${script.path}`}
      onClick={/* 打开选中对象的详情抽屉。 */ () => script.onSelect({ type: "script", id: script.path })}
    >
      <Handle type="target" position={Position.Left} />
      <b>{name}</b>
      <span>{script.kind === "scene" ? "场景" : "脚本"} · {script.path.replace(/\/[^/]*$/, "/")}</span>
      <Handle type="source" position={Position.Right} />
    </button>
  );
}

const nodeTypes: NodeTypes = { lane: LaneNode, script: ScriptNode };

/** 将文件与泳道坐标转换为只读图节点，违规引用使用红线。 */
function buildFlow(arch: ArchitectureView, selected: Selection | null, onSelect: (selection: Selection) => void): { nodes: Node[]; edges: Edge[] } {
  const layout = layoutArchitecture(arch);
  const violating = new Set(arch.edges.filter(/* 筛选引用边中符合统计或展示条件的记录。 */ edge => edge.violation).flatMap(/* 汇总引用边关联对象，供详情或违规标记使用。 */ edge => [edge.from, edge.to]));
  const layerById = new Map(arch.layers.map(/* 提取架构层的展示数据。 */ layer => [layer.id, layer]));

  const nodes: Node[] = layout.lanes.map(/* 构造架构层的展示数据。 */ lane => ({
    id: `lane:${lane.id}`,
    type: "lane",
    position: { x: 0, y: lane.y },
    width: lane.width,
    height: lane.height,
    zIndex: -1,
    draggable: false,
    selectable: false,
    data: {
      name: lane.name,
      started: lane.started,
      count: layerById.get(lane.id)?.nodeIds.length ?? 0,
      paths: layerById.get(lane.id)?.paths ?? [],
    } satisfies LaneData,
  }));
  for (const placed of layout.nodes) {
    const script = arch.nodes.find(/* 按标识或状态定位对应的图节点。 */ node => node.id === placed.id);
    if (!script) continue;
    nodes.push({
      id: script.id,
      type: "script",
      position: { x: placed.x, y: placed.y },
      width: ARCH_NODE_WIDTH,
      height: ARCH_NODE_HEIGHT,
      draggable: false,
      data: {
        path: script.path,
        kind: script.kind,
        hasViolation: violating.has(script.id),
        selected: selected?.type === "script" && selected.id === script.id,
        onSelect,
      } satisfies ScriptData,
    });
  }
  const edges: Edge[] = arch.edges.map(/* 构造引用边的展示数据。 */ edge => ({
    id: `${edge.from}->${edge.to}:${edge.kind}`,
    source: edge.from,
    target: edge.to,
    type: "smoothstep",
    label: edge.violation ? "表现直调玩法" : edge.kind,
    markerEnd: { type: MarkerType.ArrowClosed, color: edge.violation ? "#ff5f6d" : "#62a9ff" },
    style: { stroke: edge.violation ? "#ff5f6d" : "#62a9ff", strokeWidth: edge.violation ? 3 : 2 },
    labelStyle: { fill: edge.violation ? "#ff9aa3" : "#8fb6e8", fontSize: 10 },
    labelBgStyle: { fill: "#0b1828" },
  }));
  return { nodes, edges };
}

interface Props {
  snapshot: Snapshot;
  selected: Selection | null;
  onSelect: (selection: Selection) => void;
}

/** 展示四层架构和扫描引用，不执行 Godot 工程。 */
export function ArchitecturePage({ snapshot, selected, onSelect }: Props) {
  const arch = snapshot.architecture;
  const { nodes, edges } = useMemo(/* 从当前快照计算展示数据，避免重复计算。 */ () => buildFlow(arch, selected, onSelect), [arch, selected, onSelect]);
  const violations = arch.edges.filter(/* 筛选引用边中符合统计或展示条件的记录。 */ edge => edge.violation);

  return (
    <section className="page page-graph" data-testid="page-architecture">
      <header className="page-heading">
        <div>
          <p className="eyebrow">03 · ARCHITECTURE</p>
          <h1>项目架构图</h1>
        </div>
        <div className="graph-tools">
          <span className="muted">
            {arch.clientExists ? `${arch.nodes.length} 个脚本/场景 · ${arch.edges.length} 条引用` : "client/ 还不存在"}
          </span>
          <span className={violations.length > 0 ? "fail-text" : "pass-text"} data-testid="violation-count">
            {violations.length > 0 ? `${violations.length} 条表现层直调玩法层（红线）` : "没有表现层直调玩法层的依赖"}
          </span>
        </div>
      </header>
      <div className="graph-frame" data-testid="graph-architecture" data-lane-left={ARCH_LANE_LEFT}>
        <ReactFlowProvider>
          <ReactFlow
            nodes={nodes}
            edges={edges}
            nodeTypes={nodeTypes}
            nodesDraggable={false}
            nodesConnectable={false}
            elementsSelectable={false}
            minZoom={0.3}
            maxZoom={1.4}
            proOptions={{ hideAttribution: true }}
            fitView
            fitViewOptions={{ padding: 0.08, maxZoom: 1 }}
          >
            <Background variant={BackgroundVariant.Dots} gap={24} size={1} color="#20384f" />
            <Controls showInteractive={false} />
          </ReactFlow>
        </ReactFlowProvider>
      </div>
    </section>
  );
}
