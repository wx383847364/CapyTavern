// @vitest-environment node
import { describe, expect, it } from "vitest";
import { dropBackEdges } from "../src/client/layout";
import { milestoneEdges, reachableFlowIds, layoutArchitecture } from "../src/client/view-model";
import type { FlowNodeView } from "../src/shared/types";

/** 导流图排版：回边（回酒馆）要从排版里去掉，其余边保留。 */
describe("导流图排版与视图模型", () => {
  it("去掉指向祖先的回边，保留正向边", () => {
    const nodes = ["a", "b", "c"].map(id => ({ id, width: 10, height: 10 }));
    const edges = [
      { id: "a-b", source: "a", target: "b" },
      { id: "b-c", source: "b", target: "c" },
      { id: "c-a", source: "c", target: "a" },
      { id: "b-a", source: "b", target: "a" },
    ];
    expect(dropBackEdges(nodes, edges).map(edge => edge.id)).toEqual(["a-b", "b-c"]);
  });

  it("玩家只能走到第一个未通过的节点，之后的节点够不到", () => {
    const flow: FlowNodeView[] = [
      { id: "new", name: "新档", itemId: "x", status: "PASS", isNext: false, next: ["tavern"] },
      { id: "tavern", name: "酒馆", itemId: "y", status: "OPEN", isNext: true, next: ["depart"] },
      { id: "depart", name: "出征", itemId: "z", status: "OPEN", isNext: false, next: [] },
    ];
    expect([...reachableFlowIds(flow)]).toEqual(["new", "tavern"]);
  });

  it("并行支线的依赖边带「不挡玩法」标签，未通过的依赖画虚线", () => {
    const edges = milestoneEdges([
      { id: "P0", name: "", owner: "", dependsOn: [], parallel: false, status: "REVIEW", passCount: 0, reviewCount: 0, total: 0, progressPct: 0, depsMet: true, isNext: true, dispatchKey: null, planAcceptance: [], items: [] },
      { id: "P5", name: "", owner: "", dependsOn: ["P0"], parallel: true, status: "OPEN", passCount: 0, reviewCount: 0, total: 0, progressPct: 0, depsMet: false, isNext: false, dispatchKey: null, planAcceptance: [], items: [] },
    ]);
    expect(edges).toHaveLength(1);
    expect(edges[0].dashed).toBe(true);
    expect(edges[0].label).toContain("不挡玩法");
  });

  it("空泳道也占位，不被隐藏", () => {
    const layout = layoutArchitecture({
      clientExists: true, nodes: [], edges: [],
      layers: [{ id: "a", name: "表现", paths: [], nodeIds: [], started: false }, { id: "b", name: "输入", paths: [], nodeIds: [], started: false }],
    });
    expect(layout.lanes).toHaveLength(2);
    expect(layout.lanes[1].y).toBeGreaterThan(layout.lanes[0].y);
  });
});
