import assert from "node:assert/strict";
import { test } from "node:test";
import { createWorkflowStream, parseWorkflowLine, stripWorkflowMarkers, stageOrder } from "./build-events.js";

test("stage events are parsed without exposing control markers", () => {
  const evt = parseWorkflowLine("@@CAVEY_STAGE|compile|running|Flutter Windows");
  assert.deepEqual(evt, {kind:"stage",stage:"compile",state:"running",label:"Flutter Windows"});
  assert.equal(parseWorkflowLine("@@CAVEY_STAGE|unknown|running|not valid"), null);
  assert.equal(stageOrder.length, 7);
  assert.equal(stageOrder[5], "verify");
  assert.equal(stripWorkflowMarkers("text\n@@CAVEY_STAGE|compile|done|done\nnext"), "text\nnext");
});

test("chunked output retains ordinary logs and emits every stage", () => {
  const events: unknown[] = [];
  const stream = createWorkflowStream(event => events.push(event));
  const text = stream.push("Fetching...\n@@CAVEY_STA") +
    stream.push("GE|source|done|Ready\nBuilding") +
    stream.push("...\n@@CAVEY_RESTART|updated\n") + stream.finish();
  assert.equal(text, "Fetching...\nBuilding...\n");
  assert.deepEqual(events, [
    {kind:"stage",stage:"source",state:"done",label:"Ready"},
    {kind:"restart"},
  ]);
});

test("published logs are preserved after removing markers", () => {
  assert.equal(stripWorkflowMarkers("before\n@@CAVEY_RESTART|updated\nafter"), "before\nafter");
});

test("build result marker is parsed and hidden", () => {
  const line = '@@CAVEY_RESULT|{"id":"r1","status":"published","folder":"C:\\\\b\\\\r1","version":"0.4.0.5","channel":"devkit/dj",' +
    '"tag":"test-devkit-dj-v0.4.0.5","local":false,"source":"dj","url":"https://x/t","artifacts":[{"name":"a.exe","size":10}]}';
  const evt = parseWorkflowLine(line);
  assert.equal(evt?.kind, "result");
  if (evt?.kind === "result") {
    assert.equal(evt.result.folder, "C:\\b\\r1");
    assert.deepEqual(evt.result.artifacts, [{ name: "a.exe", size: 10 }]);
  }
  assert.equal(stripWorkflowMarkers("x\n" + line + "\ny"), "x\ny");
  assert.equal(parseWorkflowLine("@@CAVEY_RESULT|{broken"), null);
});
