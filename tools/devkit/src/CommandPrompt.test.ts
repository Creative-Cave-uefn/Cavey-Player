import assert from "node:assert/strict";
import { test } from "node:test";
import { matchCommands } from "./CommandPrompt.js";

const options = [
  { name: "build", description: "Build project" },
  { name: "branches", description: "GitHub branches" },
  { name: "terminal", description: "PowerShell terminal" },
];

test("slash opens ordered suggestions", () => {
  assert.deepEqual(matchCommands("/", options).map(c => c.name), ["build", "branches", "terminal"]);
});

test("typing filters palette without requiring a click", () => {
  assert.deepEqual(matchCommands("/BR", options).map(c => c.name), ["branches"]);
  assert.deepEqual(matchCommands("/term", options).map(c => c.name), ["terminal"]);
});

test("commands with parameters don't show autocomplete over the input", () => {
  assert.deepEqual(matchCommands("/build --local", options), []);
  assert.deepEqual(matchCommands("git status", options), []);
});

test("only seven matching items fit in the keyboard/mouse palette", () => {
  const many = Array.from({ length: 15 }, (_, i) => ({ name: "build" + i, description: "" }));
  assert.equal(matchCommands("/build", many).length, 7);
});
