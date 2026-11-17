import assert from "node:assert/strict";
import { test } from "node:test";
import { filterChoices, visibleChoices, releaseChannels } from "./choices.js";

const branches = ["feat/foo", "main", "fix/bug", "dj-engine"].map(x => ({ value:x, label:x }));
test("menu contains all branches and filters by query", () => {
  assert.equal(filterChoices(branches, "").length, 4);
  assert.deepEqual(filterChoices(branches, "dj").map(x => x.value), ["dj-engine"]);
  assert.deepEqual(filterChoices(branches, "MAIN").map(x => x.value), ["main"]);
  assert.deepEqual(filterChoices(branches, "2").map(x => x.value), ["main"]);
});
test("long menus keep the selected row visible within the viewport", () => {
  const list = Array.from({length:60},(_,i)=>({value:String(i),label:String(i)}));
  for (const pos of [0,1,13,30,59]) {
    const page = visibleChoices(list,pos,7);
    assert.ok(page.rows.length<=7);
    assert.ok(pos>=page.start && pos<page.start+page.rows.length);
  }
});
test("publication channels are unique and stable releases are excluded", () => {
  const channels = releaseChannels([
    {tagName:"v1.0.0",name:"Stable",isPrerelease:false,publishedAt:"2026-11-17"},
    {tagName:"test-dj-v0.4.0.3",name:"Тест: DJ · 0.4.0.3",isPrerelease:true,publishedAt:"2026-11-17"},
    {tagName:"test-dj-v0.4.0.2",name:"Тест: DJ · 0.4.0.2",isPrerelease:true,publishedAt:"2026-11-16"},
    {tagName:"test-wave-v0.4.0.1",name:"Тест: wave · 0.4.0.1",isPrerelease:true,publishedAt:"2026-11-15"},
  ]);
  assert.deepEqual(channels.map(x => x.value),["DJ","wave"]);
});
