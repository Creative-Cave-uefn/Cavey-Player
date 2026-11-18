import { releaseChannels, type Choice, type ReleaseRecord } from "./choices.js";
import { formatDuration, relativeTime } from "./transcript.js";

// Guided flows as plain data. main.tsx owns the side effects (git, gh, engine);
// this module only decides what each step asks and what it would do.

export type Branch = { name: string; date: string; sha: string; author: string };
export type SavedRun = { id: string; source: string; channel: string; status: string; updatedUtc?: string; version?: string };
export type ConfirmCommand = "build" | "clean" | "rollback" | "rollforward" | "resume" | "cache";

export type Wizard =
  | { kind: "releases-home" }
  | { kind: "branch"; branches: Branch[]; releases: ReleaseRecord[]; target?: string }
  | { kind: "mode"; branch: Branch; releases: ReleaseRecord[] }
  | { kind: "channel"; branch: Branch; releases: ReleaseRecord[] }
  | { kind: "manager-channel"; releases: ReleaseRecord[] }
  | { kind: "manager-action"; channel: string; releases: ReleaseRecord[] }
  | { kind: "manager-versions"; channel: string; releases: ReleaseRecord[] }
  | { kind: "recover"; runs: SavedRun[] }
  | { kind: "name"; branch: Branch; releases: ReleaseRecord[] }
  | { kind: "note"; confirm: Confirm }
  | Confirm;

export type Confirm = {
  kind: "confirm"; command: ConfirmCommand; args: string[]; question: string;
  plan: [string, string][]; options: Choice[];
};

export type Dialog = {
  id: string;
  question: string;
  plan?: [string, string][];
  options: Choice[];
  /** Long lists accept typed filters; short ones pick on a digit key. */
  filterable: boolean;
  /** Free text step: Enter submits what was typed (or the placeholder default when empty). */
  input?: { placeholder: string };
};

export const KEEP_PER_CHANNEL = 3;

export function slug(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

/** Parse `git for-each-ref --format=%(refname)|%(committerdate:iso-strict)|%(objectname:short)|%(authorname)`. */
export function parseBranches(text: string): Branch[] {
  const prefix = "refs/remotes/origin/";
  const result: Branch[] = [];
  for (const row of text.split(/\r?\n/)) {
    const [ref, date, sha, ...author] = row.trim().split("|");
    if (!ref || !ref.startsWith(prefix) || ref.length <= prefix.length) continue;
    const name = ref.slice(prefix.length);
    if (name === "HEAD" || !sha || !/^[0-9a-f]{4,64}$/i.test(sha)) continue;
    result.push({ name, date: date ?? "", sha, author: author.join("|") });
  }
  return result;
}

/** DevKit owns channels named devkit/…; test-<branch> channels belong to CI, which replaces them on every push. */
export function isDevKitChannel(channel: string): boolean {
  return slug(channel).startsWith("devkit-");
}

/** Version from the tag as numbers; drafting resets publishedAt, so order follows the build number. */
export function buildNumber(tag: string): number[] {
  const match = /-v(\d+(?:\.\d+)+)$/.exec(tag);
  return match ? match[1]!.split(".").map(Number) : [];
}

export function newestFirst(a: ReleaseRecord, b: ReleaseRecord): number {
  const x = buildNumber(a.tagName), y = buildNumber(b.tagName);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (y[i] ?? 0) - (x[i] ?? 0);
    if (d) return d;
  }
  return (b.publishedAt ?? "").localeCompare(a.publishedAt ?? "");
}

function inChannel(r: ReleaseRecord, channel: string): boolean {
  return r.isPrerelease && r.tagName.startsWith("test-" + slug(channel) + "-v");
}

export function channelReleases(releases: readonly ReleaseRecord[], channel: string): ReleaseRecord[] {
  return releases.filter(r => inChannel(r, channel) && !r.isDraft).sort(newestFirst);
}

/** Releases hidden as drafts by a rollback. */
export function hiddenReleases(releases: readonly ReleaseRecord[], channel: string): ReleaseRecord[] {
  return releases.filter(r => inChannel(r, channel) && r.isDraft).sort(newestFirst);
}

/** DevKit channel that already carries builds of this branch. */
export function channelForBranch(releases: readonly ReleaseRecord[], branch: string): string | undefined {
  const own = "devkit-" + slug(branch);
  return releaseChannels(releases).find(c => {
    const id = slug(c.value);
    return id === own || id.startsWith(own + "-");
  })?.value;
}

/** Releases a channel update will prune once the new one is published (older versions and rollback drafts). */
export function prunedByUpdate(releases: readonly ReleaseRecord[], channel: string, keep = KEEP_PER_CHANNEL): string[] {
  return [...channelReleases(releases, channel).slice(Math.max(0, keep - 1)), ...hiddenReleases(releases, channel)]
    .map(r => r.tagName);
}

function sourceLine(b: Branch): string {
  return "origin/" + b.name + " · " + b.sha + (b.date ? " · " + relativeTime(b.date) : "");
}

function etaLine(etaMs: number | null): string {
  return etaMs ? "~" + formatDuration(etaMs) + " (average of recent builds)" : "unknown (no previous builds)";
}

/** Default name for a new channel: the last part of the branch, made unique. */
export function suggestChannelName(branch: string, releases: readonly ReleaseRecord[]): string {
  const base = slug(branch.split("/").filter(Boolean).pop() ?? branch).slice(0, 32) || "build";
  const taken = new Set(releases.map(r => /^test-(.+)-v\d+(?:\.\d+)+$/.exec(r.tagName)?.[1]).filter(Boolean));
  let name = base;
  for (let n = 2; taken.has(slug("devkit/" + name)); n++) name = base + "-" + n;
  return name;
}

/** Empty string when the name is usable; otherwise why not. */
export function channelNameProblem(name: string, releases: readonly ReleaseRecord[]): string {
  const clean = name.trim().replace(/^devkit\//i, "");
  if (!clean) return "Type a name.";
  if (clean.length > 40) return "Use at most 40 characters.";
  if (!/^[a-z0-9][a-z0-9-]*(?:\/[a-z0-9-]+)*$/i.test(clean)) return "Use letters, digits, - and /.";
  const prefix = "test-" + slug("devkit/" + clean) + "-v";
  if (releases.some(r => r.tagName.startsWith(prefix))) return "Channel devkit/" + clean + " already exists. Pick another name or update it.";
  return "";
}

export function buildConfirm(
  branch: Branch, mode: "local" | "new" | "update", releases: readonly ReleaseRecord[],
  etaMs: number | null, channel?: string,
): Confirm {
  const plan: [string, string][] = [["Source", sourceLine(branch)]];
  let args: string[];
  let question: string;
  let options: Choice[];
  if (mode === "update" && channel) {
    const pruned = prunedByUpdate(releases, channel);
    plan.push(["Channel", channel + " · " + channelReleases(releases, channel).length + " active version(s)"]);
    plan.push(["Keeps", KEEP_PER_CHANNEL + " latest versions" +
      (pruned.length ? " · removes " + pruned.join(", ") : " · nothing removed")]);
    args = ["--branch", branch.name, "--mode", "update", "--channel", channel];
    question = "Build and update channel “" + channel + "”?";
    options = [
      { value: "yes", label: "Yes, build and update the channel" },
      { value: "note", label: "Yes, with a note for testers" },
      { value: "back", label: "No, go back" },
    ];
  } else if (mode === "new") {
    const name = channel ? "devkit/" + channel.replace(/^devkit\//i, "") : "";
    plan.push(["Channel", name ? name + " (new)" : "new · devkit/" + branch.name + "/<timestamp>"]);
    plan.push(["Publish", "Cavey-Player-Releases as a prerelease"]);
    args = ["--branch", branch.name, "--mode", "new", ...(name ? ["--channel", name] : [])];
    question = "Build and publish a new test release?";
    options = [
      { value: "yes", label: "Yes, build and publish" },
      { value: "note", label: "Yes, with a note for testers" },
      { value: "local", label: "Build locally only" },
      { value: "back", label: "No, go back" },
    ];
  } else {
    plan.push(["Publish", "no · files stay on this computer"]);
    args = ["--branch", branch.name, "--mode", "new", "--local"];
    question = "Build locally?";
    options = [
      { value: "yes", label: "Yes, build" },
      { value: "back", label: "No, go back" },
    ];
  }
  plan.push(["Checks", mode === "local" ? "flutter analyze + flutter test" : "analyze + test, then a launch check"]);
  plan.push(["Time", etaLine(etaMs)]);
  return { kind: "confirm", command: "build", args, question, plan, options };
}

export function simpleConfirm(command: ConfirmCommand, args: string[]): Wizard {
  const flag = (key: string) => { const i = args.indexOf(key); return i >= 0 ? args[i + 1] ?? "" : ""; };
  const plain = args.filter(a => a !== "--yes").join(" ");
  switch (command) {
    case "rollforward": {
      return { kind: "confirm", command, args, question: "Undo the rollback of “" + flag("--channel") + "”?",
        plan: [["Effect", "releases hidden by the rollback become active again"]],
        options: [{ value: "yes", label: "Yes, show them again" }, { value: "back", label: "No, go back" }] };
    }
    case "rollback":
      return { kind: "confirm", command, args, question: "Roll back channel “" + flag("--channel") + "”?",
        plan: [["Restore", flag("--to")], ["Newer", "hidden as drafts; tags and files are kept"],
          ["Clients", "already-updated installs are not downgraded"]],
        options: [{ value: "yes", label: "Yes, roll back" }, { value: "back", label: "No, go back" }] };
    case "resume":
      return { kind: "confirm", command, args,
        question: args.includes("--replace") ? "Replace the incomplete release and publish again?" : "Publish the saved build?",
        plan: [["Run", flag("--id")], ["Check", "SHA-256 of both files before upload"],
          ...(args.includes("--replace") ? [["Replace", "deletes the release with the same tag first"] as [string, string]] : [])],
        options: [{ value: "yes", label: "Yes, publish" }, { value: "back", label: "No, go back" }] };
    case "clean":
      return { kind: "confirm", command, args, question: "Delete outdated test releases?",
        plan: [["Keep", flag("--keep") ? flag("--keep") + " per channel" : KEEP_PER_CHANNEL + " per DevKit channel, 1 per CI channel"],
          ["Hidden", args.includes("--drafts") ? "releases hidden by rollback are deleted too" : "releases hidden by rollback are kept"],
          ["Safe", "stable, beta, Android and iOS are never touched"]],
        options: [{ value: "yes", label: "Yes, delete" }, { value: "dry-run", label: "Show the list first" },
          { value: "back", label: "No, go back" }] };
    case "cache":
      return { kind: "confirm", command, args, question: "Remove all cached source worktrees?",
        plan: [["Effect", "the next build of each commit starts from scratch"]],
        options: [{ value: "yes", label: "Yes, remove" }, { value: "back", label: "No, go back" }] };
    default:
      return { kind: "confirm", command, args, question: "Run /" + command + " " + plain + "?", plan: [],
        options: [{ value: "yes", label: "Yes" }, { value: "back", label: "No, go back" }] };
  }
}

export function dialogFor(w: Wizard): Dialog {
  switch (w.kind) {
    case "name": {
      const suggested = suggestChannelName(w.branch.name, w.releases);
      return { id: "name:" + w.branch.name, question: "Name the new channel", filterable: false, options: [],
        plan: [["Testers see", "devkit/<name> in Settings → Updates"], ["Default", "devkit/" + suggested + " (press Enter)"]],
        input: { placeholder: suggested } };
    }
    case "note":
      return { id: "note:" + w.confirm.args.join(" "), question: "Note for testers", filterable: false, options: [],
        plan: [["Shown", "first in the release notes and the Discord post"]],
        input: { placeholder: "What should testers check? (Enter to skip)" } };
    case "releases-home":
      return { id: "releases-home", question: "What do you want to do with test releases?", filterable: false,
        options: [
          { value: "channel", label: "Manage a channel", detail: "versions · update · rollback" },
          { value: "list", label: "List all test releases" },
          { value: "clean", label: "Clean up outdated releases" },
        ] };
    case "branch":
      return { id: "branch:" + (w.target ?? ""), filterable: true,
        question: w.target ? "Update “" + w.target + "” from which branch?" : "Build which branch?",
        options: w.branches.map(b => {
          const channel = channelForBranch(w.releases, b.name);
          return { value: b.name, label: b.name,
            detail: [relativeTime(b.date), b.author, channel ? "channel " + channel : ""].filter(Boolean).join(" · ") };
        }) };
    case "mode": {
      const channel = channelForBranch(w.releases, w.branch.name);
      return { id: "mode:" + w.branch.name, question: "What kind of build?", filterable: false,
        options: [
          { value: "local", label: "Local build", detail: "no publication" },
          { value: "new", label: "New test release", detail: "separate channel" },
          { value: "update", label: "Update a channel", detail: channel ? "suggested: " + channel : "pick an existing one" },
        ] };
    }
    case "channel": {
      const suggested = channelForBranch(w.releases, w.branch.name);
      const options = releaseChannels(w.releases).filter(c => isDevKitChannel(c.value))
        .map(c => describeChannel(w.releases, c.value));
      options.sort((a, b) => Number(b.value === suggested) - Number(a.value === suggested));
      return { id: "channel:" + w.branch.name, question: "Update which channel?", filterable: true, options };
    }
    case "manager-channel":
      return { id: "manager-channel", question: "Which channel?", filterable: true,
        options: releaseChannels(w.releases).map(c => describeChannel(w.releases, c.value)) };
    case "manager-action": {
      if (!isDevKitChannel(w.channel)) {
        return { id: "manager-action:" + w.channel, question: "Channel “" + w.channel + "”", filterable: false,
          plan: [["Owner", "GitHub Actions · replaced on every push to the branch"]],
          options: [{ value: "history", label: "Show versions" }] };
      }
      const hidden = hiddenReleases(w.releases, w.channel).length;
      return { id: "manager-action:" + w.channel, question: "Channel “" + w.channel + "”", filterable: false,
        options: [
          { value: "history", label: "Show versions" },
          { value: "update", label: "Update from a branch" },
          { value: "rollback", label: "Roll back to an older version" },
          ...(hidden ? [{ value: "rollforward", label: "Undo rollback", detail: hidden + " hidden" }] : []),
        ] };
    }
    case "manager-versions":
      return { id: "manager-versions:" + w.channel, question: "Restore which version?", filterable: true,
        options: w.releases.map(r => ({ value: r.tagName, label: r.tagName, detail: relativeTime(r.publishedAt) })) };
    case "recover":
      return { id: "recover", question: "Publish which saved build?", filterable: w.runs.length > 9,
        options: w.runs.map(r => ({ value: r.id, label: r.channel || r.id,
          detail: [r.version, r.status.replace("_", " "), relativeTime(r.updatedUtc)].filter(Boolean).join(" · ") })) };
    case "confirm":
      return { id: "confirm:" + w.command + ":" + w.args.join(" "), question: w.question, plan: w.plan,
        options: w.options, filterable: false };
  }
}

function describeChannel(releases: readonly ReleaseRecord[], channel: string): Choice {
  const versions = channelReleases(releases, channel);
  const hidden = hiddenReleases(releases, channel).length;
  const latest = versions[0];
  return { value: channel, label: channel,
    detail: [isDevKitChannel(channel) ? "" : "CI",
      versions.length + " version" + (versions.length === 1 ? "" : "s"),
      hidden ? hidden + " hidden" : "", latest ? relativeTime(latest.publishedAt) : ""].filter(Boolean).join(" · ") };
}

/** One-line transcript summary of a pick, so the transcript reads like a log of decisions. */
export function pickSummary(w: Wizard, value: string): [string, string] | null {
  switch (w.kind) {
    case "branch": return ["Branch", value];
    case "mode": return [value === "local" ? "Local build" : value === "new" ? "New test release" : "Update a channel", ""];
    case "channel": return ["Channel", value];
    case "manager-channel": return ["Channel", value];
    case "recover": return ["Run", value];
    case "manager-versions": return ["Restore", value];
    case "name": return value.trim() ? ["Channel", "devkit/" + value.trim().replace(/^devkit\//i, "")] : null;
    case "note": return value.trim() ? ["Note", value.trim()] : null;
    default: return null;
  }
}

/** Human title for an engine run, e.g. "Build main → dj". */
export function runTitle(command: string, args: string[]): string {
  const opt = (k: string) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] ?? "" : ""; };
  switch (command) {
    case "build": {
      const branch = opt("--branch") || "latest branch";
      if (args.includes("--local")) return "Build " + branch + " · local";
      if (opt("--mode") === "update") return "Build " + branch + " → " + (opt("--channel") || "channel");
      return "Build " + branch + " → new test release";
    }
    case "rollback": return "Roll back " + opt("--channel") + " to " + opt("--to");
    case "rollforward": return "Undo rollback of " + opt("--channel");
    case "resume": case "retry-publish": case "recover":
      return (args.includes("--replace") ? "Replace and publish " : "Publish saved build ") + opt("--id");
    case "clean": return args.includes("--dry-run") ? "Outdated test releases" : "Clean up test releases";
    case "cache": return args.includes("prune") ? "Clear build cache" : "Build cache";
    case "manager": return opt("--channel") ? "Versions of " + opt("--channel") : "Release channels";
    default: return "/" + command + (args.length ? " " + args.filter(a => a !== "--yes").join(" ") : "");
  }
}
