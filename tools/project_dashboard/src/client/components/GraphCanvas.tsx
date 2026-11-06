import { useEffect, useMemo, useState } from "react";
import {
  Background,
  BackgroundVariant,
  Controls,
  MarkerType,
  ReactFlow,
  ReactFlowProvider,
  useReactFlow,
  type Edge,
  type Node,
  type NodeTypes,
} from "@xyflow/react";
import { dropBackEdges, layoutGraph } from "../layout";
import type { GraphEdgeSpec } from "../view-model";

export interface SizedNode {
  id: string;
  type: string;
  width: number;
  height: number;
  data: Record<string, unknown>;
}

interface Props {
  nodes: SizedNode[];
  edges: GraphEdgeSpec[];
  nodeTypes: NodeTypes;
  direction: "RIGHT" | "DOWN";
  testId: string;
  spacing?: number;
  layerSpacing?: number;
}

const EDGE_COLOR: Record<GraphEdgeSpec["kind"], string> = {
  chain: "#55d9e6",
  parallel: "#c58cff",
  flow: "#62a9ff",
};

/** 把依赖关系转换为图形边，保持未满足依赖的虚线样式。 */
function toFlowEdges(edges: GraphEdgeSpec[], nodes: SizedNode[]): Edge[] {
  const order = new Map(nodes.map(/* 登记顺序决定玩家流程的正向与返回边。 */ (node, index) => [node.id, index]));
  return edges.map(/* 渲染引用边的展示数据。 */ edge => ({
    // 返回路径走节点顶部，避免长回边穿过中间卡片。
    sourceHandle: edge.kind === "flow" && order.get(edge.target)! <= order.get(edge.source)! ? "return-out" : undefined,
    targetHandle: edge.kind === "flow" && order.get(edge.target)! <= order.get(edge.source)! ? "return-in" : undefined,
    id: edge.id,
    source: edge.source,
    target: edge.target,
    type: edge.kind === "flow" && order.get(edge.target)! <= order.get(edge.source)! ? "default" : "smoothstep",
    label: edge.label,
    animated: false,
    markerEnd: { type: MarkerType.ArrowClosed, color: EDGE_COLOR[edge.kind] },
    style: {
      stroke: EDGE_COLOR[edge.kind],
      strokeWidth: 2,
      strokeDasharray: edge.dashed ? "7 6" : undefined,
      opacity: edge.dashed ? 0.7 : 1,
    },
    labelStyle: { fill: "#d9bdff", fontSize: 11 },
    labelBgStyle: { fill: "#0b1828" },
  }));
}

/** 异步计算图布局并适配视口，卸载时丢弃迟到的布局结果。 */
function Inner({ nodes, edges, nodeTypes, direction, testId, spacing, layerSpacing }: Props) {
  const [positioned, setPositioned] = useState<Node[]>([]);
  const flow = useReactFlow();
  const flowEdges = useMemo(/* 从当前快照计算展示数据，避免重复计算。 */ () => toFlowEdges(edges, nodes), [edges, nodes]);
  const signature = useMemo(
    /* 从当前快照计算展示数据，避免重复计算。 */ () => JSON.stringify([nodes.map(/* 提取图节点的展示数据。 */ node => [node.id, node.width, node.height]), edges.map(/* 提取引用边的展示数据。 */ edge => edge.id)]),
    [nodes, edges],
  );

  useEffect(/* 同步页面副作用，并在卸载时清理监听或异步结果。 */ () => {
    let cancelled = false;
    void layoutGraph(
      nodes.map(/* 构造图节点的展示数据。 */ node => ({ id: node.id, width: node.width, height: node.height })),
      // ELK 只接收前向流程边来决定层级；返回边仍全部渲染，避免环路把新档排到末端。
      edges.filter(/* 返回玩家流程不参与正向层级排序。 */ edge => edge.kind !== "flow" || nodes.findIndex(node => node.id === edge.target) > nodes.findIndex(node => node.id === edge.source))
        .map(/* 提供布局依赖端点。 */ edge => ({ id: edge.id, source: edge.source, target: edge.target })),
      { direction, spacing, layerSpacing },
    ).then(/* 接收异步结果并更新当前视图。 */ positions => {
      if (cancelled) return;
      setPositioned(
        nodes.map(/* 构造图节点的展示数据。 */ node => ({
          id: node.id,
          type: node.type,
          position: positions.get(node.id) ?? { x: 0, y: 0 },
          data: node.data,
          width: node.width,
          height: node.height,
          draggable: false,
        })),
      );
    });
    return /* 取消接收已卸载视图的布局结果。 */ () => {
      cancelled = true;
    };
    // 节点数据变化（状态、展开）也要重排，signature 只管尺寸和边
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [nodes, signature, direction, spacing, layerSpacing]);

  useEffect(/* 同步页面副作用，并在卸载时清理监听或异步结果。 */ () => {
    if (positioned.length === 0) return;
    const timer = window.setTimeout(/* 布局完成后适配视口。 */ () => void flow.fitView({ padding: 0.12, duration: 0, maxZoom: 1 }), 300);
    return /* 卸载或重排前清理视口适配定时器。 */ () => window.clearTimeout(timer);
  }, [signature, positioned.length, flow]);

  return (
    <div className="graph-frame" data-testid={testId}>
      <ReactFlow
        nodes={positioned}
        edges={flowEdges}
        nodeTypes={nodeTypes}
        nodesDraggable={false}
        nodesConnectable={false}
        elementsSelectable={false}
        minZoom={0.25}
        maxZoom={1.5}
        proOptions={{ hideAttribution: true }}
        fitView
      >
        <Background variant={BackgroundVariant.Dots} gap={24} size={1} color="#20384f" />
        <Controls showInteractive={false} />
      </ReactFlow>
    </div>
  );
}

/** 为只读节点图提供独立 React Flow 上下文。 */
export function GraphCanvas(props: Props) {
  return (
    <ReactFlowProvider>
      <Inner {...props} />
    </ReactFlowProvider>
  );
}
