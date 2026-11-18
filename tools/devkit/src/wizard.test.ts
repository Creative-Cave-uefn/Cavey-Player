import assert from "node:assert/strict";
import { test } from "node:test";
import type { ReleaseRecord } from "./choices.js";
import { parseGitStatus } from "./runner.js";
import {
  buildConfirm, channelForBranch, channelReleases, dialogFor, prunedByUpdate, simpleConfirm, type Branch,
} from "./wizard.js";

const releases: ReleaseRecord[] = [
  { tagName: "test-devkit-dj-v0.4.0.4", name: "Test: devkit/dj · 0.4.0.4", isPrerelease: true, publishedAt: "2026-11-18T09:00:00Z" },
  { tagName: "test-devkit-dj-v0.4.0.3", name: "Test: devkit/dj · 0.4.0.3", isPrerelease: true, publishedAt: "2026-11-17T09:00:00Z" },
  { tagName: "test-devkit-dj-v0.4.0.2", name: "Test: devkit/dj · 0.4.0.2", isPrerelease: true, publishedAt: "2026-11-16T09:00:00Z" },
  { tagName: "test-devkit-dj-v0.4.0.1", name: "Test: devkit/dj · 0.4.0.1", isPrerelease: true, isDraft: true, publishedAt: "2026-11-15T09:00:00Z" },
  { tagName: "test-claude-wave-fix-v0.4.0.9", name: "Test: claude/wave-fix · 0.4.0.9", isPrerelease: true, publishedAt: "2026-11-14T09:00:00Z" },
  { tagName: "test-devkit-claude-wave-fix-20261118-ab12-v0.4.0.20", name: "Test: devkit/claude/wave-fix/20261118-ab12 · 0.4.0.20", isPrerelease: true, publishedAt: "2026-11-18T07:00:00Z" },
  { tagName: "v0.4.0", isPrerelease: false, publishedAt: "2026-11-13T09:00:00Z" },
];
const branch: Branch = { name: "claude/wave-fix", date: "2026-11-18T08:00:00Z", sha: "a1b2c3d", author: "Keivi" };

test("a branch is linked to its DevKit channel, never to the CI one", () => {
  assert.equal(channelForBranch(releases, "claude/wave-fix"), "devkit/claude/wave-fix/20261118-ab12");
  assert.equal(channelForBranch(releases, "main"), undefined);
});

test("only DevKit channels can be updated; CI channels are view-only", () => {
  const channel = dialogFor({ kind: "channel", branch, releases });
  assert.deepEqual(channel.options.map(o => o.value), ["devkit/claude/wave-fix/20261118-ab12", "devkit/dj"]);
  const ci = dialogFor({ kind: "manager-action", channel: "claude/wave-fix", releases });
  assert.deepEqual(ci.options.map(o => o.value), ["history"]);
  assert.match(new Map(ci.plan).get("Owner")!, /GitHub Actions/);
});

test("rollback drafts: ordered by build number, offered for undo and pruned by the next update", () => {
  const drafted: ReleaseRecord[] = [
    { tagName: "test-devkit-dj-v0.4.0.104", isPrerelease: true, isDraft: true },
    { tagName: "test-devkit-dj-v0.4.0.103", isPrerelease: true, isDraft: true },
    { tagName: "test-devkit-dj-v0.4.0.99", isPrerelease: true, publishedAt: "2026-11-18T12:00:00Z" },
    { tagName: "test-devkit-dj-v0.4.0.102", isPrerelease: true, publishedAt: "2026-11-10T12:00:00Z" },
    { tagName: "test-devkit-dj-v0.4.0.101", isPrerelease: true, publishedAt: "2026-11-09T12:00:00Z" },
  ];
  assert.deepEqual(channelReleases(drafted, "devkit/dj").map(r => r.tagName),
    ["test-devkit-dj-v0.4.0.102", "test-devkit-dj-v0.4.0.101", "test-devkit-dj-v0.4.0.99"]);
  const action = dialogFor({ kind: "manager-action", channel: "devkit/dj", releases: drafted });
  assert.equal(action.options.at(-1)!.value, "rollforward");
  assert.equal(action.options.at(-1)!.detail, "2 hidden");
  assert.deepEqual(prunedByUpdate(drafted, "devkit/dj"),
    ["test-devkit-dj-v0.4.0.99", "test-devkit-dj-v0.4.0.104", "test-devkit-dj-v0.4.0.103"]);
});

test("update preview names the releases that will be pruned, rollback drafts included", () => {
  assert.deepEqual(prunedByUpdate(releases, "devkit/dj"), ["test-devkit-dj-v0.4.0.2", "test-devkit-dj-v0.4.0.1"]);
  const w = buildConfirm(branch, "update", releases, 540000, "devkit/dj");
  assert.equal(w.kind, "confirm");
  const plan = new Map(w.kind === "confirm" ? w.plan : []);
  assert.match(plan.get("Keeps")!, /removes test-devkit-dj-v0\.4\.0\.2, test-devkit-dj-v0\.4\.0\.1/);
  assert.match(plan.get("Time")!, /~9m 00s/);
  assert.deepEqual(w.kind === "confirm" && w.args, ["--branch", "claude/wave-fix", "--mode", "update", "--channel", "devkit/dj"]);
});

test("new release confirmation offers a local fallback and a way back", () => {
  const w = buildConfirm(branch, "new", releases, null);
  const d = dialogFor(w);
  assert.deepEqual(d.options.map(o => o.value), ["yes", "note", "local", "back"]);
  assert.equal(d.filterable, false);
  assert.match(new Map(d.plan).get("Time")!, /unknown/);
});

test("dialogs ask questions and long lists are filterable", () => {
  const branches = dialogFor({ kind: "branch", branches: [branch], releases });
  assert.equal(branches.question, "Build which branch?");
  assert.equal(branches.filterable, true);
  assert.match(branches.options[0]!.detail!, /channel devkit\/claude\/wave-fix/);
  const target = dialogFor({ kind: "branch", branches: [branch], releases, target: "dj" });
  assert.equal(target.question, "Update “dj” from which branch?");
  const mode = dialogFor({ kind: "mode", branch, releases });
  assert.match(mode.options[2]!.detail!, /suggested: devkit\/claude\/wave-fix/);
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

test("new channels get a readable, unique name", async () => {
  const { suggestChannelName, channelNameProblem } = await import("./wizard.js");
  const taken: ReleaseRecord[] = [{ tagName: "test-devkit-alpha-v0.4.0.1", isPrerelease: true }];
  assert.equal(suggestChannelName("feature/beta", taken), "beta");
  assert.equal(suggestChannelName("feature/alpha", taken), "alpha-2");
  assert.equal(channelNameProblem("alpha", taken), "Channel devkit/alpha already exists. Pick another name or update it.");
  assert.equal(channelNameProblem("devkit/mixer-test", taken), "");
  assert.match(channelNameProblem("bad name!", taken), /letters, digits/);
  const named = buildConfirm(branch, "new", taken, null, "mixer");
  assert.deepEqual(named.args, ["--branch", "claude/wave-fix", "--mode", "new", "--channel", "devkit/mixer"]);
  assert.equal(new Map(named.plan).get("Channel"), "devkit/mixer (new)");
});

test("naming and tester-note steps are free-text dialogs", () => {
  const name = dialogFor({ kind: "name", branch, releases });
  assert.equal(name.input?.placeholder, "wave-fix");
  assert.equal(name.options.length, 0);
  const confirm = buildConfirm(branch, "update", releases, null, "devkit/dj");
  const note = dialogFor({ kind: "note", confirm });
  assert.equal(note.question, "Note for testers");
  assert.ok(note.input);
});

test("rebuild repeats local builds and updates a channel the last build created", async () => {
  const { rebuildArgs } = await import("./wizard.js");
  assert.deepEqual(rebuildArgs({ args: ["--branch", "x", "--mode", "new", "--local", "--yes"] }),
    ["--branch", "x", "--mode", "new", "--local"]);
  const result = { id: "r", status: "published", folder: "f", version: "0.4.0.9", channel: "devkit/x", tag: "t",
    local: false, source: "x", url: "u", artifacts: [] };
  assert.deepEqual(rebuildArgs({ args: ["--branch", "x", "--mode", "new", "--channel", "devkit/x", "--message", "hi", "--yes"], result }),
    ["--branch", "x", "--mode", "update", "--channel", "devkit/x"]);
  assert.deepEqual(rebuildArgs({ args: ["--branch", "x", "--mode", "update", "--channel", "devkit/x", "--yes"], result }),
    ["--branch", "x", "--mode", "update", "--channel", "devkit/x"]);
  assert.deepEqual(rebuildArgs({ args: ["--branch", "x", "--mode", "new"], result: { ...result, status: "failed" } }),
    ["--branch", "x", "--mode", "new"]);
});
