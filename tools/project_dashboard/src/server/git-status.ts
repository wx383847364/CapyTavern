import { execFile } from "node:child_process";
import type { GitFile } from "../shared/types.js";

/** 路径归岗，口径取 TEAM.md §2。越具体的前缀越优先。 */
const OWNER_RULES: { prefix: string; owner: string }[] = [
  { prefix: "client/assets/art/", owner: "酒馆表现" },
  { prefix: "client/assets/ui/", owner: "酒馆表现" },
  { prefix: "export/", owner: "酒馆表现" },
  { prefix: "client/", owner: "酒馆程序" },
  { prefix: "tools/project_dashboard/", owner: "酒馆程序" },
  { prefix: "design/", owner: "酒馆策划" },
  { prefix: "server/", owner: "酒馆服务器" },
  { prefix: "protocol/", owner: "酒馆服务器" },
  { prefix: "doc/", owner: "酒馆制作人" },
  { prefix: "tools/doc_maintenance/", owner: "酒馆制作人" },
  { prefix: "tools/repo_maintenance/", owner: "酒馆制作人" },
  { prefix: ".githooks/", owner: "酒馆制作人" },
  { prefix: "TEAM.md", owner: "酒馆制作人" },
  { prefix: ".gitignore", owner: "酒馆制作人" },
  { prefix: "locks.md", owner: "酒馆大肥鱼" },
  { prefix: "dispatch.md", owner: "酒馆大肥鱼" },
];

export const UNOWNED = "未归岗";

/** 按最具体的所有权路径确定岗位，未知路径不猜归属。 */
export function ownerOfPath(filePath: string): string {
  const hits = OWNER_RULES.filter(/* 筛选条目中符合统计或展示条件的记录。 */ rule => filePath.startsWith(rule.prefix));
  if (hits.length === 0) return UNOWNED;
  return hits.sort(/* 按稳定顺序排列当前条目。 */ (a, b) => b.prefix.length - a.prefix.length)[0].owner;
}

/** 解析 `git status --porcelain=v1 -z` 输出 */
export function parsePorcelainZ(output: string): GitFile[] {
  const parts = output.split("\0").filter(/* 筛选条目中符合统计或展示条件的记录。 */ part => part.length > 0);
  const files: GitFile[] = [];
  for (let i = 0; i < parts.length; i += 1) {
    const entry = parts[i];
    if (entry.length < 4) continue;
    const status = entry.slice(0, 2);
    const filePath = entry.slice(3);
    // 重命名/复制后面紧跟一个「原路径」条目，跳过
    if (status[0] === "R" || status[0] === "C") i += 1;
    files.push({ status: status.trim() || "?", path: filePath, owner: ownerOfPath(filePath) });
  }
  return files;
}

/** 通过固定 git 命令获取未提交文件，失败时明确标记不可用。 */
export async function readGitStatus(projectRoot: string): Promise<{ available: boolean; files: GitFile[] }> {
  return new Promise(/* 响应当前操作并更新对应数据或页面选择。 */ resolve => {
    execFile(
      "git",
      ["-c", "core.quotepath=false", "status", "--porcelain=v1", "-z", "-uall"],
      { cwd: projectRoot, maxBuffer: 16 * 1024 * 1024 },
      /* 响应当前操作并更新对应数据或页面选择。 */ (error, stdout) => {
        if (error) return resolve({ available: false, files: [] });
        return resolve({ available: true, files: parsePorcelainZ(stdout) });
      },
    );
  });
}

/** 按岗位汇总未提交文件数。 */
export function countByOwner(files: GitFile[]): Record<string, number> {
  const result: Record<string, number> = {};
  for (const file of files) result[file.owner] = (result[file.owner] ?? 0) + 1;
  return result;
}
