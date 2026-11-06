import fs from "node:fs";
import path from "node:path";
import type { ArchitectureView, RegistryLayer, ScriptEdge, ScriptNode } from "../shared/types.js";

export const UNASSIGNED_LAYER = "unassigned";
const SKIP_DIRS = new Set([".godot", ".import", "node_modules", ".git"]);

export interface RawReference {
  kind: ScriptEdge["kind"];
  /** 引用到的路径，已规范成相对仓库根；外部（非 res://）引用为 null */
  target: string | null;
}

/** 将 Godot res 路径映射到仓库 client 目录。 */
function resToRepoPath(resPath: string): string {
  return `client/${resPath.replace(/^res:\/\//, "")}`;
}

/** 解析 .gd：extends "res://…"、preload("res://…")、load("res://…")，忽略注释行 */
export function parseGdReferences(source: string): RawReference[] {
  const refs: RawReference[] = [];
  for (const rawLine of source.split(/\r?\n/)) {
    const line = rawLine.replace(/^\s+/, "");
    if (line.startsWith("#")) continue;
    const extendsMatch = line.match(/^extends\s+"(res:\/\/[^"]+)"/);
    if (extendsMatch) refs.push({ kind: "extends", target: resToRepoPath(extendsMatch[1]) });
    for (const match of line.matchAll(/\b(preload|load)\(\s*"(res:\/\/[^"]+)"\s*\)/g)) {
      refs.push({ kind: match[1] === "preload" ? "preload" : "load", target: resToRepoPath(match[2]) });
    }
  }
  return refs;
}

/** 解析 .tscn：[ext_resource … path="res://…" …] */
export function parseTscnReferences(source: string): RawReference[] {
  const refs: RawReference[] = [];
  for (const line of source.split(/\r?\n/)) {
    if (!line.startsWith("[ext_resource")) continue;
    const match = line.match(/path="(res:\/\/[^"]+)"/);
    if (match) refs.push({ kind: "ext_resource", target: resToRepoPath(match[1]) });
  }
  return refs;
}

/** 使用最长路径前缀归层，没有匹配时返回未归层。 */
export function assignLayer(relativePath: string, layers: RegistryLayer[]): string {
  let best: { id: string; length: number } | null = null;
  for (const layer of layers) {
    for (const prefix of layer.paths) {
      if (relativePath.startsWith(prefix) && (!best || prefix.length > best.length)) {
        best = { id: layer.id, length: prefix.length };
      }
    }
  }
  return best?.id ?? UNASSIGNED_LAYER;
}

/** 只枚举 Godot 脚本及场景，跳过引擎缓存目录。 */
function walk(dir: string, out: string[]): void {
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries.sort(/* 按稳定顺序排列当前条目。 */ (a, b) => a.name.localeCompare(b.name))) {
    if (entry.isDirectory()) {
      if (!SKIP_DIRS.has(entry.name)) walk(path.join(dir, entry.name), out);
    } else if (/\.(gd|tscn)$/.test(entry.name)) {
      out.push(path.join(dir, entry.name));
    }
  }
}

/** 某层是否违反「表现只订阅」：表现层 → 玩法层 */
export function isViolation(fromLayer: string, toLayer: string): boolean {
  return fromLayer === "presentation" && toLayer === "gameplay";
}

/** 静态扫描脚本场景与引用，保留空层并标记表现直调玩法。 */
export function scanClient(projectRoot: string, layers: RegistryLayer[]): ArchitectureView {
  const clientDir = path.join(projectRoot, "client");
  const clientExists = fs.existsSync(clientDir);
  const files: string[] = [];
  if (clientExists) walk(clientDir, files);

  const nodes: ScriptNode[] = files.map(/* 提取文件的展示数据。 */ file => {
    const relative = path.relative(projectRoot, file).split(path.sep).join("/");
    return {
      id: relative,
      path: relative,
      kind: relative.endsWith(".tscn") ? "scene" : "script",
      layerId: assignLayer(relative, layers),
    };
  });
  const known = new Map(nodes.map(/* 提取图节点的展示数据。 */ node => [node.id, node]));

  const edges: ScriptEdge[] = [];
  const seen = new Set<string>();
  for (const node of nodes) {
    let source = "";
    try {
      source = fs.readFileSync(path.join(projectRoot, node.path), "utf8");
    } catch {
      continue;
    }
    const refs = node.kind === "scene" ? parseTscnReferences(source) : parseGdReferences(source);
    for (const ref of refs) {
      if (!ref.target) continue;
      const target = known.get(ref.target);
      if (!target) continue;
      const key = `${node.id}->${target.id}:${ref.kind}`;
      if (seen.has(key)) continue;
      seen.add(key);
      edges.push({ from: node.id, to: target.id, kind: ref.kind, violation: isViolation(node.layerId, target.layerId) });
    }
  }

  const layerViews = layers.map(/* 提取架构层的展示数据。 */ layer => {
    const nodeIds = nodes.filter(/* 筛选图节点中符合统计或展示条件的记录。 */ node => node.layerId === layer.id).map(/* 提取架构层的展示数据。 */ node => node.id);
    return { id: layer.id, name: layer.name, paths: layer.paths, nodeIds, started: nodeIds.length > 0 };
  });
  const unassigned = nodes.filter(/* 筛选图节点中符合统计或展示条件的记录。 */ node => node.layerId === UNASSIGNED_LAYER).map(/* 提取架构层的展示数据。 */ node => node.id);
  if (unassigned.length > 0) {
    layerViews.push({ id: UNASSIGNED_LAYER, name: "未归层", paths: [], nodeIds: unassigned, started: true });
  }

  return { layers: layerViews, nodes, edges, clientExists };
}
