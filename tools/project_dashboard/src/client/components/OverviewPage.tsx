import type { Snapshot } from "../../shared/types.js";
import { STATUS_LABEL } from "../../shared/types.js";
import type { Selection } from "../view-model";
import { ProgressBar, ProgressRing, StatusBadge } from "./common";

interface Props {
  snapshot: Snapshot;
  onSelect: (selection: Selection) => void;
}

/** 汇总验收进度及下一步，待验收产物不计入完成率。 */
export function OverviewPage({ snapshot, onSelect }: Props) {
  const { overview } = snapshot;
  const next = overview.next;
  const current = snapshot.milestones.find(/* 按标识或状态定位对应的里程碑。 */ milestone => milestone.id === overview.currentMilestoneId) ?? null;
  const cards: { label: string; value: string; tone?: string; hint?: string }[] = [
    { label: "里程碑完成", value: `${overview.milestoneDone} / ${overview.milestoneTotal}` },
    { label: "待验收子项", value: String(overview.reviewItems), tone: overview.reviewItems > 0 ? "warn" : undefined },
    { label: "阻塞", value: String(overview.blockerCount), tone: overview.blockerCount > 0 ? "fail" : undefined },
    { label: "持锁中", value: String(overview.lockCount), tone: overview.lockCount > 0 ? "work" : undefined },
    { label: "未提交文件", value: String(overview.uncommittedCount), tone: overview.uncommittedCount > 0 ? "warn" : undefined },
  ];

  return (
    <section className="page" data-testid="page-overview">
      <header className="page-heading">
        <div>
          <p className="eyebrow">01 · OVERVIEW</p>
          <h1>项目总览</h1>
        </div>
        <span>登记表 v{snapshot.registryVersion} · 只读</span>
      </header>

      <div className="hero-card">
        <div className="hero-main">
          <p className="eyebrow">当前里程碑</p>
          <h1>{current ? `${current.id} ${current.name}` : "—"}</h1>
          {current ? (
            <>
              <p className="muted">
                本里程碑 {current.passCount}/{current.total} 项通过
                {current.reviewCount > 0 ? `，另有 ${current.reviewCount} 项待验收` : ""}。状态：{STATUS_LABEL[current.status]}。
              </p>
              <div className="hero-progress">
                <ProgressBar pct={overview.currentPct} status={current.status} />
                <span>{overview.currentPct}%</span>
              </div>
            </>
          ) : (
            <p className="muted">登记表里没有里程碑。</p>
          )}
        </div>
        <ProgressRing pct={overview.overallPct} label="整体进度（全部子项）" />
      </div>

      <div className="summary-grid">
        {cards.map(/* 渲染条目的展示数据。 */ card => (
          <article key={card.label} className={card.tone ? `tone-${card.tone}` : ""}>
            <span>{card.label}</span>
            <strong>{card.value}</strong>
          </article>
        ))}
      </div>

      <div className="two-col">
        <article className="panel next-card" data-testid="next-card">
          <p className="eyebrow">NEXT · 下一步</p>
          {next ? (
            <>
              <h2>
                <button className="link" onClick={/* 打开选中对象的详情抽屉。 */ () => onSelect({ type: "item", id: next.itemId })}>
                  {next.itemId} {next.itemName}
                </button>
              </h2>
              <dl className="kv">
                <dt>所属</dt>
                <dd>{next.milestoneId} {next.milestoneName}</dd>
                <dt>谁做</dt>
                <dd>{next.owner}</dd>
                <dt>当前状态</dt>
                <dd><StatusBadge status={next.status} /></dd>
                <dt>做完之后</dt>
                <dd>{next.unlocks || "—"}</dd>
              </dl>
            </>
          ) : (
            <p className="muted">没有可推的下一步：所有里程碑已完成，或登记表为空。</p>
          )}
        </article>

        <article className="panel">
          <p className="eyebrow">最近证据（dispatch.md 最近五条）</p>
          {overview.recentEvidence.length === 0 ? (
            <p className="muted">dispatch.md 里没有带证据的任务单。</p>
          ) : (
            <ul className="evidence-list">
              {overview.recentEvidence.map(/* 渲染证据的展示数据。 */ row => (
                <li key={row.title}>
                  <div><b>{row.title}</b><em>{row.status}</em></div>
                  <p>{row.evidence}</p>
                </li>
              ))}
            </ul>
          )}
        </article>
      </div>

      {snapshot.warnings.length > 0 && (
        <article className="panel warn-panel">
          <p className="eyebrow">扫描提醒</p>
          <ul>{snapshot.warnings.map(/* 渲染条目的展示数据。 */ warning => <li key={warning}>{warning}</li>)}</ul>
        </article>
      )}
    </section>
  );
}
