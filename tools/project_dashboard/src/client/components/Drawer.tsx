import type { ReactElement } from "react";
import type { Snapshot } from "../../shared/types.js";
import { STATUS_LABEL } from "../../shared/types.js";
import type { Selection } from "../view-model";
import { ProgressBar, StatusBadge } from "./common";

interface Props {
  snapshot: Snapshot;
  selection: Selection | null;
  onClose: () => void;
}

/** 展示当前选中对象的状态来源、验收和静态证据。 */
export function Drawer({ snapshot, selection, onClose }: Props) {
  if (!selection) return null;
  const items = snapshot.milestones.flatMap(/* 汇总里程碑关联对象，供详情或违规标记使用。 */ milestone => milestone.items);

  let title = "";
  let body: ReactElement | null = null;

  if (selection.type === "item" || selection.type === "flow") {
    const flowNode = selection.type === "flow" ? snapshot.flow.find(/* 按标识或状态定位对应的条目。 */ node => node.id === selection.id) : null;
    const itemId = selection.type === "item" ? selection.id : flowNode?.itemId;
    const item = items.find(/* 按标识或状态定位对应的子项。 */ entry => entry.id === itemId);
    const milestone = snapshot.milestones.find(/* 按标识或状态定位对应的里程碑。 */ entry => entry.id === item?.milestoneId);
    if (!item || !milestone) return null;
    title = flowNode ? `${flowNode.name} → ${item.id}` : `${item.id} ${item.name}`;
    body = (
      <>
        {flowNode && <p className="muted">导流节点「{flowNode.name}」挂在子项 {item.id}，颜色跟它走。</p>}
        <dl className="kv">
          <dt>子项</dt><dd>{item.id} {item.name}</dd>
          <dt>里程碑</dt><dd>{milestone.id} {milestone.name}</dd>
          <dt>状态</dt><dd><StatusBadge status={item.status} />{item.isNext && <em className="tag-next inline">NEXT</em>}</dd>
          <dt>怎么推出来的</dt><dd>{item.reason}</dd>
          <dt>谁在改</dt>
          <dd>
            {item.owner}
            {item.heldBy.length > 0 ? `；持锁：${item.heldBy.map(/* 提取子项的展示数据。 */ lock => `${lock.who}（起 ${lock.start}）`).join("、")}` : "；当前无人持锁"}
          </dd>
        </dl>
        <h3>验收要点</h3>
        {item.acceptance && <p>{item.acceptance}</p>}
        {milestone.planAcceptance.length > 0 ? (
          <>
            <p className="muted small">本里程碑在程序计划里的原文（登记表暂未给子项单独写验收）：</p>
            <ul className="plain">{milestone.planAcceptance.map(/* 渲染里程碑的展示数据。 */ line => <li key={line}>{line}</li>)}</ul>
          </>
        ) : (
          !item.acceptance && <p className="muted">登记表和计划里都没有写验收要点。</p>
        )}
        <h3>证据</h3>
        {item.evidence.length === 0 ? (
          <p className="muted">还没有证据文件（登记表 evidence 为空，不算存在）。</p>
        ) : (
          <ul className="plain">
            {item.evidence.map(/* 渲染子项的展示数据。 */ entry => (
              <li key={entry.path}>
                <code>{entry.path}</code> <span className={entry.exists ? "pass-text" : "fail-text"}>{entry.exists ? "存在" : "缺失"}</span>
              </li>
            ))}
          </ul>
        )}
        <h3>对应任务单</h3>
        {item.dispatchRow ? (
          <div className="task-box">
            <b>{item.dispatchRow.title}</b>
            <p>{item.dispatchRow.owner} · {item.dispatchRow.status}</p>
            <p className="muted small">{item.dispatchRow.evidence}</p>
          </div>
        ) : (
          <p className="muted">dispatch.md 里没有命中这个子项的任务单。</p>
        )}
      </>
    );
  } else if (selection.type === "milestone") {
    const milestone = snapshot.milestones.find(/* 按标识或状态定位对应的里程碑。 */ entry => entry.id === selection.id);
    if (!milestone) return null;
    title = `${milestone.id} ${milestone.name}`;
    body = (
      <>
        <dl className="kv">
          <dt>状态</dt><dd><StatusBadge status={milestone.status} />{milestone.isNext && <em className="tag-next inline">NEXT</em>}</dd>
          <dt>负责人</dt><dd>{milestone.owner}</dd>
          <dt>依赖</dt>
          <dd>
            {milestone.dependsOn.length === 0
              ? "无"
              : `${milestone.dependsOn.join("、")}（${milestone.depsMet ? "已满足" : "未满足"}）`}
          </dd>
          <dt>进度</dt><dd>{milestone.passCount}/{milestone.total} 通过（{milestone.progressPct}%），待验收 {milestone.reviewCount} 项</dd>
        </dl>
        <ProgressBar pct={milestone.progressPct} status={milestone.status} />
        <h3>子项</h3>
        <ul className="plain">
          {milestone.items.map(/* 渲染里程碑的展示数据。 */ item => (
            <li key={item.id}>{item.id} {item.name} · {STATUS_LABEL[item.status]}</li>
          ))}
        </ul>
        {milestone.planAcceptance.length > 0 && (
          <>
            <h3>计划里的验收口径</h3>
            <ul className="plain">{milestone.planAcceptance.map(/* 渲染里程碑的展示数据。 */ line => <li key={line}>{line}</li>)}</ul>
          </>
        )}
      </>
    );
  } else {
    const node = snapshot.architecture.nodes.find(/* 按标识或状态定位对应的图节点。 */ entry => entry.id === selection.id);
    if (!node) return null;
    const layer = snapshot.architecture.layers.find(/* 按标识或状态定位对应的架构层。 */ entry => entry.id === node.layerId);
    const outgoing = snapshot.architecture.edges.filter(/* 筛选引用边中符合统计或展示条件的记录。 */ edge => edge.from === node.id);
    const incoming = snapshot.architecture.edges.filter(/* 筛选引用边中符合统计或展示条件的记录。 */ edge => edge.to === node.id);
    title = node.path;
    body = (
      <>
        <dl className="kv">
          <dt>类型</dt><dd>{node.kind === "scene" ? "场景 .tscn" : "脚本 .gd"}</dd>
          <dt>所属层</dt><dd>{layer?.name ?? node.layerId}{node.layerId === "unassigned" && "（登记表 layers 的路径前缀没覆盖到它）"}</dd>
        </dl>
        <h3>引用了（{outgoing.length}）</h3>
        <ul className="plain">
          {outgoing.map(/* 渲染条目的展示数据。 */ edge => (
            <li key={`${edge.to}-${edge.kind}`}>
              <code>{edge.to}</code> · {edge.kind}
              {edge.violation && <span className="fail-text"> · 表现层直调玩法层</span>}
            </li>
          ))}
          {outgoing.length === 0 && <li className="muted">无</li>}
        </ul>
        <h3>被引用（{incoming.length}）</h3>
        <ul className="plain">
          {incoming.map(/* 渲染条目的展示数据。 */ edge => <li key={`${edge.from}-${edge.kind}`}><code>{edge.from}</code> · {edge.kind}</li>)}
          {incoming.length === 0 && <li className="muted">无</li>}
        </ul>
      </>
    );
  }

  return (
    <aside className="drawer" data-testid="drawer">
      <header>
        <h2>{title}</h2>
        <button onClick={onClose} aria-label="关闭详情">×</button>
      </header>
      <div className="drawer-body">{body}</div>
    </aside>
  );
}
