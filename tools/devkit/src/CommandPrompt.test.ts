import assert from "node:assert/strict";
import { test } from "node:test";
import { commandSpecs, helpText, paletteCommands, resolveCommand } from "./commands.js";

test("bare slash shows only the core commands", () => {
  const names = paletteCommands("/").map(c => c.name);
  assert.deepEqual(names, commandSpecs.filter(c => c.core).map(c => c.name));
  assert.ok(names.length <= 8);
  assert.ok(!names.includes("cache"));
});

test("typing a prefix reveals secondary commands, core first", () => {
  assert.deepEqual(paletteCommands("/ca").map(c => c.name), ["cache"]);
  assert.deepEqual(paletteCommands("/RE").map(c => c.name).slice(0, 3), ["rebuild", "releases", "recover"]);
  assert.deepEqual(paletteCommands("/manag").map(c => c.name), ["releases"]);
});

test("commands with parameters don't show the palette", () => {
  assert.deepEqual(paletteCommands("/build --local"), []);
  assert.deepEqual(paletteCommands("git status"), []);
});

test("aliases resolve to one canonical command", () => {
  assert.equal(resolveCommand("manager")?.name, "releases");
  assert.equal(resolveCommand("resume")?.name, "recover");
  assert.equal(resolveCommand("retry-publish")?.name, "recover");
  assert.equal(resolveCommand("EXIT")?.name, "quit");
  assert.equal(resolveCommand("nope"), undefined);
});

test("help lists every command exactly once", () => {
  const help = helpText();
  for (const spec of commandSpecs) assert.ok(help.includes("/" + spec.name), spec.name);
});
