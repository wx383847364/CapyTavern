import type { ScanChanges as ScanChangesData } from "../../shared/types.js";
import { STATUS_LABEL } from "../../shared/types.js";

/** 展示本次扫描相对上次的状态差异。 */
export function ScanChanges({ changes, onClose }: { changes: ScanChangesData; onClose: () => void }) {
  return (
    <div className="scan-changes" data-testid="scan-changes">
      <div>
        <b>本次扫描</b>
        <span>{changes.summary}</span>
        {changes.changed.length > 0 && (
          <ul>
            {changes.changed.slice(0, 8).map(/* 渲染条目的展示数据。 */ change => (
              <li key={change.id}>
                {change.id} {change.name}：{change.from ? STATUS_LABEL[change.from] : "新增"} → {STATUS_LABEL[change.to]}
              </li>
            ))}
          </ul>
        )}
      </div>
      <button onClick={onClose} aria-label="关闭扫描结果">×</button>
    </div>
  );
}
