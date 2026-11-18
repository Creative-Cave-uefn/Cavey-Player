import { releaseChannels, type Choice, type ReleaseRecord } from "./choices.js";
import { formatDuration, relativeTime } from "./transcript.js";

// Guided flows as plain data. main.tsx owns the side effects (git, gh, engine);
// this module only decides what each step asks and what it would do.

export type Branch = { name: string; date: string; sha: string; author: string };
export type SavedRun = { id: string; source: string; channel: string; status: string; updatedUtc?: string; version?: string };
export type ConfirmCommand = "build" | "clean" | "rollback" | "resume" | "cache";

export type Wizard =
  | { kind: "releases-home" }
  | { kind: "branch"; branches: Branch[]; releases: ReleaseRecord[]; target?: string }
  | { kind: "mode"; branch: Branch; releases: ReleaseRecord[] }
  | { kind: "channel"; branch: Branch; releases: ReleaseRecord[] }
  | { kind: "manager-channel"; releases: ReleaseRecord[] }
  | { kind: "manager-action"; channel: string; releases: ReleaseRecord[] }
  | { kind: "manager-versions"; channel: string; releases: ReleaseRecord[] }
  | { kind: "recover"; runs: SavedRun[] }
  | {
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

export function channelReleases(releases: readonly ReleaseRecord[], channel: string): ReleaseRecord[] {
  const prefix = "test-" + slug(channel) + "-v";
  return releases.filter(r => r.isPrerelease && !r.isDraft && r.tagName.startsWith(prefix))
    .sort((a, b) => (b.publishedAt ?? "").localeCompare(a.publishedAt ?? ""));
}

/** Channel that already carries builds of this branch (CI channel or DevKit channel). */
export function channelForBranch(releases: readonly ReleaseRecord[], branch: string): string | undefined {
  const own = slug(branch);
  return releaseChannels(releases).find(c => {
    const id = slug(c.value);
    return id === own || id.startsWith("devkit-" + own + "-");
  })?.value;
}

/** Releases a channel update will prune once the new one is published. */
export function prunedByUpdate(releases: readonly ReleaseRecord[], channel: string, keep = KEEP_PER_CHANNEL): string[] {
  return channelReleases(releases, channel).slice(Math.max(0, keep - 1)).map(r => r.tagName);
}

function sourceLine(b: Branch): string {
  return "origin/" + b.name + " · " + b.sha + (b.date ? " · " + relativeTime(b.date) : "");
}

function etaLine(etaMs: number | null): string {
  return etaMs ? "~" + formatDuration(etaMs) + " (average of recent builds)" : "unknown (no previous builds)";
}

export function buildConfirm(
  branch: Branch, mode: "local" | "new" | "update", releases: readonly ReleaseRecord[],
  etaMs: number | null, channel?: string,
): Wizard {
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
      { value: "back", label: "No, go back" },
    ];
  } else if (mode === "new") {
    plan.push(["Channel", "new · devkit/" + branch.name + "/<timestamp>"]);
    plan.push(["Publish", "Cavey-Player-Releases as a prerelease"]);
    args = ["--branch", branch.name, "--mode", "new"];
    question = "Build and publish a new test release?";
    options = [
      { value: "yes", label: "Yes, build and publish" },
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
  plan.push(["Checks", "flutter analyze + flutter test"]);
  plan.push(["Time", etaLine(etaMs)]);
  return { kind: "confirm", command: "build", args, question, plan, options };
}

export function simpleConfirm(command: ConfirmCommand, args: string[]): Wizard {
  const flag = (key: string) => { const i = args.indexOf(key); return i >= 0 ? args[i + 1] ?? "" : ""; };
  const plain = args.filter(a => a !== "--yes").join(" ");
  switch (command) {
    case "rollback":
      return { kind: "confirm", command, args, question: "Roll back channel “" + flag("--channel") + "”?",
        plan: [["Restore", flag("--to")], ["Newer", "hidden as drafts; tags and files are kept"],
          ["Clients", "already-updated installs are not downgraded"]],
        options: [{ value: "yes", label: "Yes, roll back" }, { value: "back", label: "No, go back" }] };
    case "resume":
      return { kind: "confirm", command, args, question: "Publish the saved build?",
        plan: [["Run", flag("--id")], ["Check", "SHA-256 of both files before upload"]],
        options: [{ value: "yes", label: "Yes, publish" }, { value: "back", label: "No, go back" }] };
    case "clean":
      return { kind: "confirm", command, args, question: "Delete outdated test releases?",
        plan: [["Keep", (flag("--keep") || "1") + " per channel"], ["Safe", "stable, beta, Android and iOS are never touched"]],
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
      const options = releaseChannels(w.releases).map(c => describeChannel(w.releases, c.value));
      options.sort((a, b) => Number(b.value === suggested) - Number(a.value === suggested));
      return { id: "channel:" + w.branch.name, question: "Update which channel?", filterable: true, options };
    }
    case "manager-channel":
      return { id: "manager-channel", question: "Which channel?", filterable: true,
        options: releaseChannels(w.releases).map(c => describeChannel(w.releases, c.value)) };
    case "manager-action":
      return { id: "manager-action:" + w.channel, question: "Channel “" + w.channel + "”", filterable: false,
        options: [
          { value: "history", label: "Show versions" },
          { value: "update", label: "Update from a branch" },
          { value: "rollback", label: "Roll back to an older version" },
        ] };
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
  const latest = versions[0];
  return { value: channel, label: channel,
    detail: versions.length + " version" + (versions.length === 1 ? "" : "s") +
      (latest ? " · " + relativeTime(latest.publishedAt) : "") };
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
    case "resume": case "retry-publish": return "Publish saved build " + opt("--id");
    case "clean": return args.includes("--dry-run") ? "Outdated test releases" : "Clean up test releases";
    case "cache": return args.includes("prune") ? "Clear build cache" : "Build cache";
    case "manager": return opt("--channel") ? "Versions of " + opt("--channel") : "Release channels";
    default: return "/" + command + (args.length ? " " + args.filter(a => a !== "--yes").join(" ") : "");
  }
}
