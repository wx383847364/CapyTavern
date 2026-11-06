// @vitest-environment node
import { afterEach, describe, expect, it } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { derive, deriveItemStatus, deriveMilestoneStatus, percent, pickNextItem } from "../src/server/derive";
import { parseDispatchRows, parseLocks } from "../src/server/parsers";
import { parseGdReferences, parseTscnReferences, scanClient } from "../src/server/godot-scan";
import { collectSnapshot, SOURCE_PATHS } from "../src/server/collector";
import { ScanManager } from "../src/server/scan-manager";
import { createApiApp } from "../src/server/app";
import { parsePorcelainZ } from "../src/server/git-status";
import type { Registry } from "../src/shared/types";

const temporary: string[] = [];
/** 为每个用例清理仓外夹具，保留真实项目不变。 */
afterEach(() => { for (const dir of temporary.splice(0)) fs.rmSync(dir, { recursive: true, force: true }); });
/** 建立最小登记表，覆盖主链、空证据及并行支线。 */
function registry(): Registry {
  return { version: "test", updated: "", owner: "制作人", layers: [], flow: [], milestones: [
    { id: "P0", name: "工程", owner: "程序", dispatchKey: "P0 工程", dependsOn: [], items: [
      { id: "P0-1", name: "窗口", evidence: ["client/project.godot"] },
      { id: "P0-2", name: "输入", evidence: ["client/project.godot"] },
      { id: "P0-3", name: "运行包", evidence: ["build/p0.zip"] },
      { id: "P0-4", name: "回显", evidence: [] },
    ] },
    { id: "P1", name: "战斗", owner: "程序", dependsOn: ["P0"], items: [{ id: "P1-1", name: "出场", evidence: [] }] },
    { id: "P5", name: "Spine", owner: "表现", dependsOn: [], parallel: true, items: [{ id: "P5-1", name: "资源" }] },
  ] };
}
/** 生成台账文本，供副本重扫而非修改真实台账。 */
function dispatch(status: string): string { return `| 任务单 | 岗位 | 状态 | 证据 |\n|---|---|---|---|\n| P0 工程能导出 | 程序 | ${status} | 已有工程 |`; }
/** 建立临时项目，仅补齐状态推导所需的证据。 */
function fixture(): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "capy-dashboard-")); temporary.push(root);
  fs.mkdirSync(path.join(root, "doc/方案与数据"), { recursive: true });
  fs.mkdirSync(path.join(root, "client")); fs.mkdirSync(path.join(root, "build"));
  fs.writeFileSync(path.join(root, SOURCE_PATHS.registry), JSON.stringify(registry()));
  fs.writeFileSync(path.join(root, "client/project.godot"), ""); fs.writeFileSync(path.join(root, "build/p0.zip"), "");
  fs.writeFileSync(path.join(root, "dispatch.md"), dispatch("待验收"));
  return root;
}
/** 检查状态优先级、取整和 NEXT 选择的业务规则。 */
describe("状态推导", () => {
  /** 当前产物不能代替验收，空证据不能虚增完成率。 */
  it("三个产物 REVIEW，回显 OPEN 且 NEXT，整体完成率为零", () => {
    const result = derive({ registry: registry(), dispatchRows: parseDispatchRows(dispatch("待验收")), locks: [], planAcceptance: {}, fileExists: /* 模拟所有登记证据均已存在。 */ () => true });
    expect(result.milestones[0].items.map(/* 提取状态供规则断言比较。 */ item => item.status)).toEqual(["REVIEW", "REVIEW", "REVIEW", "OPEN"]);
    expect(result.milestones.map(/* 提取状态供规则断言比较。 */ item => item.status)).toEqual(["IMPLEMENTING", "OPEN", "OPEN"]);
    expect(result.next?.itemId).toBe("P0-4"); expect(result.overallPct).toBe(0);
  });
  /** 子项任务单必须优先于所属里程碑及证据。 */
  it("按子项、里程碑、证据顺序取状态", () => {
    const milestone = registry().milestones[0];
    const input = { dispatchRows: [...parseDispatchRows(dispatch("已验收")), { title: "子项", owner: "", status: "阻塞", evidence: "" }], fileExists: /* 模拟所有登记证据均已存在。 */ () => true };
    expect(deriveItemStatus({ id: "x", name: "x", dispatchKey: "子项" }, milestone, input).status).toBe("BLOCKED");
    expect(deriveItemStatus(milestone.items[3], milestone, input).status).toBe("PASS");
    expect(deriveItemStatus(milestone.items[3], milestone, { ...input, dispatchRows: null }).status).toBe("UNKNOWN");
    expect(deriveMilestoneStatus(["PASS", "BLOCKED"])).toBe("BLOCKED");
    expect(deriveMilestoneStatus(["PASS", "PASS"])).toBe("PASS");
  });
  /** REVIEW 不计入完成，整数百分比采用四舍五入。 */
  it("取整、缺证据、待验收回退以及并行不抢 NEXT", () => {
    expect(percent(2, 3)).toBe(67); expect(percent(0, 0)).toBe(0);
    expect(pickNextItem([{ id: "review", status: "REVIEW" }, { id: "open", status: "OPEN" }])).toBe("open");
    expect(pickNextItem([{ id: "review", status: "REVIEW" }])).toBe("review");
    const input = { registry: registry(), dispatchRows: parseDispatchRows(dispatch("已验收")), locks: [], planAcceptance: {}, fileExists: /* 模拟证据缺失。 */ () => false };
    const result = derive(input); expect(result.next?.itemId).toBe("P1-1"); expect(result.overallPct).toBe(67);
    expect(deriveItemStatus(input.registry.milestones[0].items[0], { ...input.registry.milestones[0], dispatchKey: undefined }, input).status).toBe("OPEN");
  });
});
/** 检查 Godot 资源引用和空泳道，避免把缺层隐藏掉。 */
describe("Godot 扫描", () => {
  /** 两种文本格式均应提取真实 res 引用并跳过行注释。 */
  it("解析 gd 的 extends/preload/load 及 tscn 的 ext_resource", () => {
    expect(parseGdReferences('# preload("res://fake.gd")\nextends "res://base.gd"\nvar a = preload("res://a.tscn")\nvar b = load("res://b.gd")').map(/* 提取引用目标验证路径映射。 */ ref => ref.target)).toEqual(["client/base.gd", "client/a.tscn", "client/b.gd"]);
    expect(parseTscnReferences('[ext_resource type="Script" path="res://main.gd" id="1"]')).toEqual([{ kind: "ext_resource", target: "client/main.gd" }]);
  });
  /** 表现直调玩法必须标红，未归层和未开工均保留。 */
  it("标记违规边并保留空层", () => {
    const root = fixture();
    fs.writeFileSync(path.join(root, "client/view.gd"), 'extends "res://rules.gd"');
    fs.writeFileSync(path.join(root, "client/rules.gd"), 'extends Node');
    fs.writeFileSync(path.join(root, "client/main.tscn"), '[ext_resource path="res://view.gd" id="1"]');
    const result = scanClient(root, [{ id: "presentation", name: "表现", paths: ["client/view.gd"] }, { id: "gameplay", name: "玩法", paths: ["client/rules.gd"] }, { id: "data", name: "数据", paths: ["client/data/"] }]);
    expect(result.edges.find(/* 定位表现脚本的依赖。 */ edge => edge.from.endsWith("view.gd"))?.violation).toBe(true);
    expect(result.layers.find(/* 定位空数据层。 */ layer => layer.id === "data")?.started).toBe(false);
    expect(result.layers.find(/* 定位未归层结果。 */ layer => layer.id === "unassigned")?.nodeIds).toContain("client/main.tscn");
  });
});
/** 检查副本重扫、扫描历史、只读 API 和台账解析。 */
describe("采集与接口", () => {
  /** 真实采集副本，验收后 NEXT 从 P0-4 移到 P1-1。 */
  it("修改副本台账再重扫，报告 NEXT 变化且不写数据源", async () => {
    const root = fixture(); const manager = new ScanManager(root, null); await manager.initialize();
    expect(manager.getSnapshot()?.overview.next?.itemId).toBe("P0-4");
    const text = dispatch("已验收"); fs.writeFileSync(path.join(root, "dispatch.md"), text);
    const result = await manager.scan();
    expect(result.changes.nextFrom).toBe("P0-4"); expect(result.changes.nextTo).toBe("P1-1");
    expect(result.snapshot.milestones[0].status).toBe("PASS"); expect(manager.getHistory()).toHaveLength(2);
    expect(fs.readFileSync(path.join(root, "dispatch.md"), "utf8")).toBe(text);
    expect(fs.existsSync(path.join(root, ".cache"))).toBe(false);
  });
  /** API 只暴露约定三个入口，外站不能触发扫描。 */
  it("三个 API 可用，拒绝外站 Origin 和未知写入接口", async () => {
    const manager = new ScanManager(fixture(), null); await manager.initialize();
    const server = createApiApp(manager).listen(0, "127.0.0.1");
    await new Promise<void>(/* 就绪后请求 API，监听失败直接报告。 */ (resolve, reject) => { server.once("listening", resolve); server.once("error", reject); });
    const address = server.address(); if (!address || typeof address === "string") throw Error("端口不可用");
    const url = `http://127.0.0.1:${address.port}`;
    try {
      expect((await fetch(`${url}/api/snapshot`)).status).toBe(200);
      expect((await fetch(`${url}/api/scans`, { method: "POST" })).status).toBe(200);
      expect((await (await fetch(`${url}/api/scans/history`)).json()).length).toBe(2);
      expect((await fetch(`${url}/api/scans`, { method: "POST", headers: { Origin: "https://external.example" } })).status).toBe(403);
      expect((await fetch(`${url}/api/write`, { method: "POST" })).status).toBe(404);
    } finally { await new Promise<void>(/* 释放测试监听端口。 */ (resolve, reject) => server.close(/* 把关闭结果传回用例。 */ error => error ? reject(error) : resolve())); }
  });
  /** 缺数据源时保留来源失败状态，不能伪造 PASS。 */
  it("缺失台账显示 UNKNOWN，锁按两小时阈值标黄", async () => {
    const root = fixture(); fs.unlinkSync(path.join(root, "dispatch.md"));
    const result = await collectSnapshot(root); expect(result.milestones[0].items[3].status).toBe("UNKNOWN");
    expect(result.sources.find(/* 定位缺失台账的来源状态。 */ source => source.name === "派发台账")?.ok).toBe(false);
    const locks = parseLocks('| 谁 | 改哪 | 起 | 止 |\n|---|---|---|---|\n| 程序 | client/ | 2026-11-06 10:00 | |', new Date(2026, 10, 6, 13).getTime());
    expect(locks[0].stale).toBe(true);
    expect(parsePorcelainZ('?? client/中文.gd\0R  doc/new.md\0doc/old.md\0')).toEqual([{ status: "??", path: "client/中文.gd", owner: "酒馆程序" }, { status: "R", path: "doc/new.md", owner: "酒馆制作人" }]);
  });
});
