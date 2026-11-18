import assert from "node:assert/strict";
import { test } from "node:test";
import { classifyLine, estimateBuildMs, formatDuration, relativeTime, summarizeOutput } from "./transcript.js";

const log = Array.from({ length: 40 }, (_, i) => "line " + i);

test("collapsed output keeps the tail and reports hidden lines", () => {
  const view = summarizeOutput(log.join("\n"), false);
  const shown = view.lines.filter(Boolean).map(l => l!.text);
  assert.deepEqual(shown, log.slice(-6));
  assert.equal(view.hidden, 34);
  assert.equal(view.lines[0], null);
});

test("errors are never hidden behind the collapsed gap", () => {
  const withError = [...log];
  withError[3] = "ERROR: flutter analyze found 2 issues";
  const view = summarizeOutput(withError.join("\n"), false);
  const shown = view.lines.filter(Boolean).map(l => l!.text);
  assert.ok(shown.includes(withError[3]!));
  assert.equal(view.lines.filter(l => l === null).length, 2);
});

test("expanded or short output is shown in full", () => {
  assert.equal(summarizeOutput(log.join("\n"), true).lines.length, 40);
  assert.equal(summarizeOutput("a\nb", false).hidden, 0);
});

test("line classification", () => {
  assert.equal(classifyLine("ОШИБКА: Сборка не удалась"), "error");
  assert.equal(classifyLine("DevKit engine error at x.ps1:1 : boom"), "error");
  assert.equal(classifyLine("! Could not prune test-x"), "warning");
  assert.equal(classifyLine("  ✓ published"), "success");
  assert.equal(classifyLine("Compiling lib/main.dart"), "normal");
  assert.equal(classifyLine("errorBuilder: (context) => null"), "normal");
});

test("durations and relative times", () => {
  assert.equal(formatDuration(4200), "4s");
  assert.equal(formatDuration(303000), "5m 03s");
  assert.equal(formatDuration(3720000), "1h 02m");
  const now = Date.parse("2026-11-18T12:00:00Z");
  assert.equal(relativeTime("2026-11-18T10:00:00Z", now), "2h ago");
  assert.equal(relativeTime("2026-11-15T12:00:00Z", now), "3d ago");
});

test("ETA averages recent successful builds only", () => {
  assert.equal(estimateBuildMs([]), null);
  assert.equal(estimateBuildMs([
    { status: "failed", seconds: 10 }, { status: "built", seconds: 400 }, { status: "published", seconds: 600 },
  ]), 500000);
});
