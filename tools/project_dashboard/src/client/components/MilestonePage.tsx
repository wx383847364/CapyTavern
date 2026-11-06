import { useMemo, useState } from "react";
import { Handle, Position, type NodeProps, type NodeTypes } from "@xyflow/react";
import type { MilestoneView, Snapshot } from "../../shared/types.js";
import { STATUS_LABEL } from "../../shared/types.js";
import {
  MILESTONE_NODE_WIDTH,
  defaultExpanded,
  milestoneEdges,
  milestoneNodeHeight,
  statusClass,
  type Selection,
} from "../view-model";
import { ProgressBar } from "./common";
import { GraphCanvas, type SizedNode } from "./GraphCanvas";

interface MilestoneNodeData extends Record<string, unknown> {
  milestone: MilestoneView;
  expanded: boolean;
  selected: Selection | null;
  onToggle: (id: string) => void;
  onSelect: (selection: Selection) => void;
}

/** 显示里程碑及可展开子项，NEXT 使用紫色光环。 */
function MilestoneNode({ data }: NodeProps) {
  const { milestone, expanded, selected, onToggle, onSelect } = data as MilestoneNodeData;
  const isSelected = selected?.type === "milestone" && selected.id === milestone.id;
  return (
    <div
      className={`ms-node ${statusClass(milestone.status)} ${milestone.isNext ? "is-next" : ""} ${milestone.parallel ? "is-parallel" : ""} ${isSelected ? "is-selected" : ""}`}
      data-testid={`ms-${milestone.id}`}
      data-status={milestone.status}
      data-next={milestone.isNext ? "true" : "false"}
    >
      <Handle type="target" position={Position.Left} />
      <div className="ms-head nodrag nopan" onClick={/* 打开选中对象的详情抽屉。 */ () => onSelect({ type: "milestone", id: milestone.id })}>
        <div className="ms-title">
          <b>{milestone.id}</b>
          <span>{milestone.name}</span>
          {milestone.parallel && <em className="tag-parallel">并行支线</em>}
          {milestone.isNext && <em className="tag-next">NEXT</em>}
        </div>
        <div className="ms-meta">
          <span className={`badge ${statusClass(milestone.status)}`}>{STATUS_LABEL[milestone.status]}</span>
          <span className="muted">{milestone.owner}</span>
        </div>
        <ProgressBar pct={milestone.progressPct} status={milestone.status} />
        <div className="ms-count">
          <span>{milestone.passCount}/{milestone.total} 通过 · {milestone.progressPct}%</span>
          {milestone.reviewCount > 0 && <span className="warn-text">待验收 {milestone.reviewCount}</span>}
        </div>
      </div>
      <button className="ms-toggle nodrag nopan" onClick={/* 切换里程碑子项的展开状态。 */ () => onToggle(milestone.id)} aria-expanded={expanded}>
        {expanded ? "收起子项 ▲" : `展开 ${milestone.total} 个子项 ▼`}
      </button>
      {expanded && (
        <ul className="ms-items nodrag nopan">
          {milestone.items.map(/* 打开选中对象的详情抽屉。 */ item => {
            const itemSelected = selected?.type === "item" && selected.id === item.id;
            return (
              <li key={item.id}>
                <button
                  className={`ms-item ${statusClass(item.status)} ${item.isNext ? "is-next" : ""} ${itemSelected ? "is-selected" : ""}`}
                  data-testid={`item-${item.id}`}
                  data-status={item.status}
                  data-next={item.isNext ? "true" : "false"}
                  onClick={/* 打开选中对象的详情抽屉。 */ () => onSelect({ type: "item", id: item.id })}
                >
                  <i className="dot" />
                  <span className="ms-item-id">{item.id}</span>
                  <span className="ms-item-name">{item.name}</span>
                  <span className="ms-item-status">{STATUS_LABEL[item.status]}</span>
                </button>
              </li>
            );
          })}
        </ul>
      )}
      <Handle type="source" position={Position.Right} />
    </div>
  );
}

const nodeTypes: NodeTypes = { milestone: MilestoneNode };

interface Props {
  snapshot: Snapshot;
  selected: Selection | null;
  onSelect: (selection: Selection) => void;
}

/** 展示主链和并行支线，展开操作只影响本地视图。 */
export function MilestonePage({ snapshot, selected, onSelect }: Props) {
  const [expandedOverride, setExpandedOverride] = useState<Record<string, boolean>>({});
  const defaults = useMemo(/* 从当前快照计算展示数据，避免重复计算。 */ () => defaultExpanded(snapshot.milestones), [snapshot.milestones]);
  const toggle = /* 切换单个里程碑展开状态，未覆盖时沿用 NEXT 默认值。 */ (id: string): void => setExpandedOverride(/* 响应当前操作并更新对应数据或页面选择。 */ prev => ({ ...prev, [id]: !(prev[id] ?? defaults[id] ?? false) }));
  const setAll = /* 统一展开或收起当前快照中的全部里程碑。 */ (value: boolean): void => setExpandedOverride(Object.fromEntries(snapshot.milestones.map(/* 提取里程碑的展示数据。 */ milestone => [milestone.id, value])));

  const nodes = useMemo<SizedNode[]>(
    /* 从当前快照计算展示数据，避免重复计算。 */ () =>
      snapshot.milestones.map(/* 打开选中对象的详情抽屉。 */ milestone => {
        const expanded = expandedOverride[milestone.id] ?? defaults[milestone.id] ?? false;
        return {
          id: milestone.id,
          type: "milestone",
          width: MILESTONE_NODE_WIDTH,
          height: milestoneNodeHeight(milestone.items.length, expanded),
          data: { milestone, expanded, selected, onToggle: toggle, onSelect } satisfies MilestoneNodeData,
        };
      }),
    // toggle / onSelect 稳定到足够本页使用
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [snapshot.milestones, expandedOverride, defaults, selected, onSelect],
  );
  const edges = useMemo(/* 从当前快照计算展示数据，避免重复计算。 */ () => milestoneEdges(snapshot.milestones), [snapshot.milestones]);

  return (
    <section className="page page-graph" data-testid="page-milestones">
      <header className="page-heading">
        <div>
          <p className="eyebrow">02 · MILESTONE MAP</p>
          <h1>里程碑导航图</h1>
        </div>
        <div className="graph-tools">
          <span className="muted">主链 P0 → P4，P5 Spine 并行不挡玩法；虚线 = 依赖还没满足</span>
          <button onClick={/* 统一调整全部里程碑的展开状态。 */ () => setAll(true)}>全部展开</button>
          <button onClick={/* 统一调整全部里程碑的展开状态。 */ () => setAll(false)}>全部收起</button>
        </div>
      </header>
      <GraphCanvas nodes={nodes} edges={edges} nodeTypes={nodeTypes} direction="RIGHT" testId="graph-milestones" spacing={40} layerSpacing={80} />
    </section>
  );
}
