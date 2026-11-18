import assert from "node:assert/strict";
import { test } from "node:test";
import type { ReleaseRecord } from "./choices.js";
import { parseGitStatus } from "./runner.js";
import {
  buildConfirm, channelForBranch, dialogFor, parseBranches, prunedByUpdate, simpleConfirm, type Branch,
} from "./wizard.js";

const releases: ReleaseRecord[] = [
  { tagName: "test-dj-v0.4.0.4", name: "Test: dj · 0.4.0.4", isPrerelease: true, publishedAt: "2026-11-18T09:00:00Z" },
  { tagName: "test-dj-v0.4.0.3", name: "Test: dj · 0.4.0.3", isPrerelease: true, publishedAt: "2026-11-17T09:00:00Z" },
  { tagName: "test-dj-v0.4.0.2", name: "Test: dj · 0.4.0.2", isPrerelease: true, publishedAt: "2026-11-16T09:00:00Z" },
  { tagName: "test-dj-v0.4.0.1", name: "Test: dj · 0.4.0.1", isPrerelease: true, isDraft: true, publishedAt: "2026-11-15T09:00:00Z" },
  { tagName: "test-claude-wave-fix-v0.4.0.9", name: "Test: claude/wave-fix · 0.4.0.9", isPrerelease: true, publishedAt: "2026-11-14T09:00:00Z" },
  { tagName: "v0.4.0", isPrerelease: false, publishedAt: "2026-11-13T09:00:00Z" },
];
const branch: Branch = { name: "claude/wave-fix", date: "2026-11-18T08:00:00Z", sha: "a1b2c3d", author: "Keivi" };

test("branch refs parse with date, sha and author; junk is skipped", () => {
  const parsed = parseBranches([
    "refs/remotes/origin/main|2026-11-18T10:00:00+03:00|abc1234|Keivi",
    "refs/remotes/origin/HEAD|2026-11-18T10:00:00+03:00|abc1234|x",
    "refs/remotes/origin/feat/a|2026-11-17T10:00:00+03:00|def5678|A | B",
    "refs/remotes/upstream/x|2026|abc1234|x",
    "refs/remotes/origin/bad|2026|not-a-sha|x",
    "",
  ].join("\n"));
  assert.deepEqual(parsed.map(b => b.name), ["main", "feat/a"]);
  assert.equal(parsed[1]!.author, "A | B");
});

test("a branch is linked to the channel that already carries its builds", () => {
  assert.equal(channelForBranch(releases, "claude/wave-fix"), "claude/wave-fix");
  assert.equal(channelForBranch(releases, "main"), undefined);
});

test("update preview names the releases that will be pruned (drafts ignored)", () => {
  assert.deepEqual(prunedByUpdate(releases, "dj"), ["test-dj-v0.4.0.2"]);
  const w = buildConfirm(branch, "update", releases, 540000, "dj");
  assert.equal(w.kind, "confirm");
  const plan = new Map(w.kind === "confirm" ? w.plan : []);
  assert.match(plan.get("Keeps")!, /removes test-dj-v0\.4\.0\.2/);
  assert.match(plan.get("Time")!, /~9m 00s/);
  assert.deepEqual(w.kind === "confirm" && w.args, ["--branch", "claude/wave-fix", "--mode", "update", "--channel", "dj"]);
});

test("new release confirmation offers a local fallback and a way back", () => {
  const w = buildConfirm(branch, "new", releases, null);
  const d = dialogFor(w);
  assert.deepEqual(d.options.map(o => o.value), ["yes", "local", "back"]);
  assert.equal(d.filterable, false);
  assert.match(new Map(d.plan).get("Time")!, /unknown/);
});

test("dialogs ask questions and long lists are filterable", () => {
  const branches = dialogFor({ kind: "branch", branches: [branch], releases });
  assert.equal(branches.question, "Build which branch?");
  assert.equal(branches.filterable, true);
  assert.match(branches.options[0]!.detail!, /channel claude\/wave-fix/);
  const target = dialogFor({ kind: "branch", branches: [branch], releases, target: "dj" });
  assert.equal(target.question, "Update “dj” from which branch?");
  const mode = dialogFor({ kind: "mode", branch, releases });
  assert.match(mode.options[2]!.detail!, /suggested: claude\/wave-fix/);
  const channel = dialogFor({ kind: "channel", branch, releases });
  assert.equal(channel.options[0]!.value, "claude/wave-fix");
});

test("rollback confirmation explains what happens", () => {
  const d = dialogFor(simpleConfirm("rollback", ["--channel", "dj", "--to", "test-dj-v0.4.0.3"]));
  assert.equal(d.question, "Roll back channel “dj”?");
  assert.equal(new Map(d.plan).get("Restore"), "test-dj-v0.4.0.3");
});

test("git status line parses branch, dirty state and sync", () => {
  assert.deepEqual(parseGitStatus("## main...origin/main [ahead 2, behind 1]\n M lib/a.dart\n"),
    { branch: "main", dirty: true, ahead: 2, behind: 1 });
  assert.deepEqual(parseGitStatus("## feat/x\n"), { branch: "feat/x", dirty: false, ahead: 0, behind: 0 });
  assert.equal(parseGitStatus("## HEAD (no branch)\n").branch, "(detached)");
});

test("run titles read like actions", async () => {
  const { runTitle } = await import("./wizard.js");
  assert.equal(runTitle("build", ["--branch", "main", "--mode", "new", "--local", "--yes"]), "Build main · local");
  assert.equal(runTitle("build", ["--branch", "x", "--mode", "update", "--channel", "dj", "--yes"]), "Build x → dj");
  assert.equal(runTitle("rollback", ["--channel", "dj", "--to", "t1", "--yes"]), "Roll back dj to t1");
  assert.equal(runTitle("status", []), "/status");
});
