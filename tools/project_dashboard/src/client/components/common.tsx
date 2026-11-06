import type { ItemStatus } from "../../shared/types.js";
import { STATUS_LABEL } from "../../shared/types.js";
import { statusClass } from "../view-model";

/** 用统一标签显示验收状态。 */
export function StatusBadge({ status }: { status: ItemStatus }) {
  return <span className={`badge ${statusClass(status)}`}>{STATUS_LABEL[status]}</span>;
}

/** 显示已验收比例，并向辅助技术提供百分比。 */
export function ProgressBar({ pct, status }: { pct: number; status?: ItemStatus }) {
  return (
    <div className="progress" role="progressbar" aria-valuenow={pct} aria-valuemin={0} aria-valuemax={100}>
      <div className={`progress-fill ${status ? statusClass(status) : ""}`} style={{ width: `${pct}%` }} />
    </div>
  );
}

/** 用圆环显示整体通过比例，待验收不算已完成。 */
export function ProgressRing({ pct, size = 150, label }: { pct: number; size?: number; label: string }) {
  const stroke = 10;
  const radius = (size - stroke) / 2;
  const circumference = 2 * Math.PI * radius;
  return (
    <div className="ring" style={{ width: size, height: size }}>
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
        <circle cx={size / 2} cy={size / 2} r={radius} className="ring-track" strokeWidth={stroke} fill="none" />
        <circle
          cx={size / 2}
          cy={size / 2}
          r={radius}
          className="ring-value"
          strokeWidth={stroke}
          fill="none"
          strokeDasharray={`${(circumference * pct) / 100} ${circumference}`}
          strokeLinecap="round"
          transform={`rotate(-90 ${size / 2} ${size / 2})`}
        />
      </svg>
      <div className="ring-text">
        <strong>{pct}%</strong>
        <span>{label}</span>
      </div>
    </div>
  );
}

/** 说明状态颜色和 NEXT 光环含义。 */
export function Legend() {
  return (
    <div className="sidebar-legend">
      <span><i className="legend-dot legend-pass" />已验收</span>
      <span><i className="legend-dot legend-review" />待验收（有产物）</span>
      <span><i className="legend-dot legend-work" />进行中 / 已派出</span>
      <span><i className="legend-dot legend-fail" />阻塞</span>
      <span><i className="legend-dot legend-open" />未开始</span>
      <span><i className="legend-dot legend-unknown" />未知</span>
      <span><i className="legend-ring legend-next" />NEXT 下一步</span>
    </div>
  );
}
