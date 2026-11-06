import { useMemo } from "react";
import { Handle, Position, type NodeProps, type NodeTypes } from "@xyflow/react";
import type { FlowNodeView, Snapshot } from "../../shared/types.js";
import { STATUS_LABEL } from "../../shared/types.js";
import {
  FLOW_NODE_HEIGHT,
  FLOW_NODE_WIDTH,
  flowEdges,
  reachableFlowIds,
  statusClass,
  type Selection,
} from "../view-model";
import { GraphCanvas, type SizedNode } from "./GraphCanvas";

interface FlowNodeData extends Record<string, unknown> {
  node: FlowNodeView;
  reached: boolean;
  frontier: boolean;
  onSelect: (selection: Selection) => void;
}

/** 展示玩家流程状态，未验收的可达边界加提示。 */
function FlowNode({ data }: NodeProps) {
  const { node, reached, frontier, onSelect } = data as FlowNodeData;
  return (
    <button
      className={`flow-node ${statusClass(node.status)} ${node.isNext ? "is-next" : ""} ${reached ? "" : "unreached"} ${frontier ? "frontier" : ""}`}
      data-testid={`flow-${node.id}`}
      data-status={node.status}
      data-reached={reached ? "true" : "false"}
      onClick={/* 打开选中对象的详情抽屉。 */ () => onSelect({ type: "flow", id: node.id })}
    >
      <Handle type="target" position={Position.Left} />
      <Handle type="target" id="return-in" position={Position.Top} style={{ left: "60%" }} />
      <Handle type="source" id="return-out" position={Position.Top} style={{ left: "40%" }} />
      <b>{node.name}</b>
      <span>{node.itemId} · {STATUS_LABEL[node.status]}</span>
      {frontier && <em>玩家现在走到这</em>}
      <Handle type="source" position={Position.Right} />
    </button>
  );
}

const nodeTypes: NodeTypes = { flow: FlowNode };

interface Props {
  snapshot: Snapshot;
  onSelect: (selection: Selection) => void;
}

/** 展示玩家流程与验收边界，节点状态跟随关联子项。 */
export function FlowPage({ snapshot, onSelect }: Props) {
  const reached = useMemo(/* 从当前快照计算展示数据，避免重复计算。 */ () => reachableFlowIds(snapshot.flow), [snapshot.flow]);
  const nodes = useMemo<SizedNode[]>(
    /* 从当前快照计算展示数据，避免重复计算。 */ () =>
      snapshot.flow.map(/* 打开选中对象的详情抽屉。 */ node => ({
        id: node.id,
        type: "flow",
        width: FLOW_NODE_WIDTH,
        height: FLOW_NODE_HEIGHT,
        data: {
          node,
          reached: reached.has(node.id),
          frontier: reached.has(node.id) && node.status !== "PASS",
          onSelect,
        } satisfies FlowNodeData,
      })),
    [snapshot.flow, reached, onSelect],
  );
  const edges = useMemo(/* 从当前快照计算展示数据，避免重复计算。 */ () => flowEdges(snapshot.flow), [snapshot.flow]);
  const frontier = snapshot.flow.filter(/* 筛选条目中符合统计或展示条件的记录。 */ node => reached.has(node.id) && node.status !== "PASS");

  return (
    <section className="page page-graph" data-testid="page-flow">
      <header className="page-heading">
        <div>
          <p className="eyebrow">04 · PLAYER FLOW</p>
          <h1>功能导流图</h1>
        </div>
        <div className="graph-tools">
          <span className="muted">
            {snapshot.flow.length === 0
              ? "登记表没有导流节点"
              : frontier.length === 0
                ? "整条玩家流程都已通过"
                : `玩家现在能走到：${frontier.map(/* 提取条目的展示数据。 */ node => node.name).join("、")}（还没通过，后面灰掉）`}
          </span>
        </div>
      </header>
      <GraphCanvas nodes={nodes} edges={edges} nodeTypes={nodeTypes} direction="RIGHT" testId="graph-flow" spacing={44} layerSpacing={70} />
    </section>
  );
}
