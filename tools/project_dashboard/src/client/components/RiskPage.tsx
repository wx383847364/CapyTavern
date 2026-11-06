import type { ScanSummary, Snapshot } from "../../shared/types.js";
import { STATUS_LABEL } from "../../shared/types.js";
import { formatTime, statusClass, type Selection } from "../view-model";

interface Props {
  snapshot: Snapshot;
  history: ScanSummary[];
  onSelect: (selection: Selection) => void;
}

/** 将任务单中文状态映射为风险页配色。 */
function dispatchStatusTone(status: string): string {
  const word = status.replace(/[*`\s]/g, "");
  if (word.startsWith("阻塞")) return "st-blocked";
  if (word.startsWith("已验收")) return "st-pass";
  if (word.startsWith("待验收")) return "st-review";
  if (word.startsWith("进行中") || word.startsWith("已派出")) return "st-implementing";
  return "st-open";
}

/** 显示交付链、台账、写锁、来源和扫描历史，不修改任何台账。 */
export function RiskPage({ snapshot, history, onSelect }: Props) {
  const activeLocks = snapshot.locks.filter(/* 筛选写锁中符合统计或展示条件的记录。 */ lock => lock.active);
  const activeBlockers = snapshot.blockers.filter(/* 筛选写锁中符合统计或展示条件的记录。 */ blocker => !blocker.resolved);
  const owners = Object.entries(snapshot.git.byOwner).sort(/* 按稳定顺序排列当前条目。 */ (a, b) => b[1] - a[1]);

  return (
    <section className="page" data-testid="page-risk">
      <header className="page-heading">
        <div>
          <p className="eyebrow">05 · DELIVERY &amp; RISK</p>
          <h1>进度与风险</h1>
        </div>
        <span>{snapshot.decisions.count} 条裁决{snapshot.decisions.latest ? " · 最近一条见下方" : ""}</span>
      </header>

      <article className="panel">
        <p className="eyebrow">交付链</p>
        <div className="chain">
          {snapshot.milestones.map(/* 打开选中对象的详情抽屉。 */ milestone => (
            <div key={milestone.id} className={`chain-lane ${milestone.isNext ? "is-next" : ""}`} data-testid={`chain-${milestone.id}`}>
              <div className="chain-name">
                <b>{milestone.id}</b>
                <span>{milestone.name}{milestone.parallel ? "（并行）" : ""}</span>
              </div>
              <div className="chain-cells">
                {milestone.items.map(/* 打开选中对象的详情抽屉。 */ item => (
                  <button
                    key={item.id}
                    className={`cell ${statusClass(item.status)} ${item.isNext ? "is-next" : ""}`}
                    title={`${item.id} ${item.name} · ${STATUS_LABEL[item.status]}`}
                    onClick={/* 打开选中对象的详情抽屉。 */ () => onSelect({ type: "item", id: item.id })}
                  >
                    {item.id.replace(/^P\d-/, "")}
                  </button>
                ))}
              </div>
              <span className="chain-pct">{milestone.progressPct}%</span>
            </div>
          ))}
        </div>
      </article>

      <div className="two-col">
        <article className="panel">
          <p className="eyebrow">阻塞与风险</p>
          {activeBlockers.length === 0 && !snapshot.iterationBlocker && <p className="muted">dispatch.md 没有未解除的阻塞。</p>}
          {activeBlockers.map(/* 渲染写锁的展示数据。 */ blocker => (
            <div key={blocker.title} className="risk-row">
              <b>{blocker.title}</b>
              <p>影响：{blocker.impact}</p>
              <p className="muted">解除条件：{blocker.release}</p>
              <small>{blocker.date}</small>
            </div>
          ))}
          {snapshot.iterationBlocker && (
            <div className="risk-row">
              <b>迭代索引「最新阻塞」</b>
              <p>{snapshot.iterationBlocker}</p>
            </div>
          )}
          {snapshot.blockers.some(/* 判断是否存在符合条件的条目。 */ blocker => blocker.resolved) && (
            <p className="muted small">另有 {snapshot.blockers.filter(/* 筛选写锁中符合统计或展示条件的记录。 */ blocker => blocker.resolved).length} 条已解除。</p>
          )}
        </article>

        <article className="panel">
          <p className="eyebrow">写锁（持锁中 {activeLocks.length}）</p>
          {activeLocks.length === 0 ? (
            <p className="muted">locks.md 里没有人持锁。</p>
          ) : (
            activeLocks.map(/* 渲染写锁的展示数据。 */ lock => (
              <div key={`${lock.who}-${lock.start}`} className={`risk-row ${lock.stale ? "stale" : ""}`}>
                <b>{lock.who}</b>
                <p>{lock.where}</p>
                <small>
                  起 {lock.start}
                  {lock.heldHours !== null ? ` · 已持 ${lock.heldHours.toFixed(1)} 小时` : ""}
                  {lock.stale ? " · 超过 2 小时，请制作人处理" : ""}
                </small>
              </div>
            ))
          )}
          <p className="eyebrow gap-top">未提交文件（{snapshot.git.available ? snapshot.git.total : "git 不可用"}）</p>
          {owners.length === 0 ? (
            <p className="muted">{snapshot.git.available ? "工作区干净。" : "读不到 git status。"}</p>
          ) : (
            <ul className="owner-list">
              {owners.map(/* 渲染条目的展示数据。 */ ([owner, count]) => (
                <li key={owner}><span>{owner}</span><b>{count}</b></li>
              ))}
            </ul>
          )}
        </article>
      </div>

      <article className="panel">
        <p className="eyebrow">任务单（dispatch.md 主表）</p>
        <div className="table-wrap">
          <table>
            <thead>
              <tr><th>任务单</th><th>岗位</th><th>状态</th><th>证据 / 阻塞</th></tr>
            </thead>
            <tbody>
              {snapshot.dispatchRows.map(/* 渲染台账条目的展示数据。 */ row => (
                <tr key={row.title}>
                  <td>{row.title}</td>
                  <td>{row.owner}</td>
                  <td><span className={`badge ${dispatchStatusTone(row.status)}`}>{row.status}</span></td>
                  <td className="evidence-cell">{row.evidence}</td>
                </tr>
              ))}
              {snapshot.dispatchRows.length === 0 && <tr><td colSpan={4} className="muted">读不到 dispatch.md 或主表为空。</td></tr>}
            </tbody>
          </table>
        </div>
      </article>

      <div className="two-col">
        <article className="panel">
          <p className="eyebrow">数据来源</p>
          <table className="compact">
            <tbody>
              {snapshot.sources.map(/* 渲染数据来源的展示数据。 */ source => (
                <tr key={source.name}>
                  <td>{source.name}</td>
                  <td><code>{source.path}</code></td>
                  <td className={source.ok ? "pass-text" : "fail-text"}>{source.ok ? "已读" : `失败 ${source.note ?? ""}`}</td>
                  <td className="muted">{formatTime(source.readAt)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </article>
        <article className="panel">
          <p className="eyebrow">扫描历史（最近 {history.length} 次）</p>
          <table className="compact">
            <thead><tr><th>时间</th><th>整体</th><th>NEXT</th><th>变化</th></tr></thead>
            <tbody>
              {[...history].reverse().slice(0, 8).map(/* 渲染扫描历史的展示数据。 */ entry => (
                <tr key={entry.scanId}>
                  <td>{formatTime(entry.scannedAt)}</td>
                  <td>{entry.overallPct}%</td>
                  <td>{entry.nextItemId ?? "—"}</td>
                  <td>{entry.changedCount}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {snapshot.decisions.latest && (
            <>
              <p className="eyebrow gap-top">最近一条裁决</p>
              <p className="small">{snapshot.decisions.latest}</p>
            </>
          )}
        </article>
      </div>
    </section>
  );
}
