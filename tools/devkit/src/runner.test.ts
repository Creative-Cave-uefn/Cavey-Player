import assert from "node:assert/strict";
import { test } from "node:test";
import { existsSync } from "node:fs";
import {
  changeDirectory, commandRequest, engineCommands, initialDirectory,
  repositoryRoot, shellRequest, splitArgs,
} from "./runner.js";

test("parse quoted arguments without invoking a shell", () => {
  assert.deepEqual(splitArgs('--branch "feat/my test" --local --yes'),
    ["--branch", "feat/my test", "--local", "--yes"]);
  assert.deepEqual(splitArgs("--channel 'My Test'"), ["--channel", "My Test"]);
});

test("PowerShell execution is parameterized", () => {
  const request = commandRequest("build", ["--branch", "feat/example", "--yes"], repositoryRoot);
  assert.equal(request.program, "powershell.exe");
  assert.equal(request.args[request.args.length - 1], "--yes");
  assert.equal(request.args.includes("-File"), true);
  assert.equal(request.args.some(arg => arg.includes("Invoke-Expression")), false);
});

test("shell commands execute in explicit workspace directory", () => {
  const command = shellRequest("Get-ChildItem", repositoryRoot);
  assert.equal(command.cwd, repositoryRoot);
  assert.equal(command.args.at(-1), "Get-ChildItem");
});

test("directory changes reject unknown folders", () => {
  assert.equal(changeDirectory(repositoryRoot, "cd ."), repositoryRoot);
  assert.equal(changeDirectory(repositoryRoot, "Get-ChildItem"), null);
  assert.throws(() => changeDirectory(repositoryRoot, "cd __missing_devkit_dir__"));
});

test("current checkout and engine exist", () => {
  assert.ok(existsSync(repositoryRoot));
  assert.ok(engineCommands.has("build"));
  assert.equal(typeof initialDirectory(), "string");
});
