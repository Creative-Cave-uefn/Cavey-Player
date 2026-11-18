// Single source of truth for slash commands: palette, /help and aliases.
export type CommandSpec = {
  name: string;
  description: string;
  /** Shown in the empty "/" palette. Secondary commands appear once typed. */
  core: boolean;
  usage?: string[];
  aliases?: string[];
};

export const commandSpecs: CommandSpec[] = [
  { name: "build", core: true, description: "Build a branch locally or publish a test release",
    usage: ["/build", "/build --branch <name> --local --yes", "/build --branch <name> --mode new --yes",
      "/build --branch <name> --mode update --channel <name> --yes", "/build --working-tree --local --yes",
      "/build --android --branch <name> --local --yes",
      "/build ... --fresh   (no source cache)", "/build ... --skip-checks   (no analyze/test)"] },
  { name: "rebuild", core: true, description: "Repeat the last build (a new channel is updated, not recreated)" },
  { name: "releases", core: true, description: "Test channels: versions, update, rollback, cleanup",
    aliases: ["manager"],
    usage: ["/releases", "/releases --channel <name>"] },
  { name: "recover", core: true, description: "Retry publishing a finished build",
    aliases: ["resume", "retry-publish"],
    usage: ["/recover", "/recover --id <run-id> --yes", "/recover --id <run-id> --replace --yes"] },
  { name: "run", core: true, description: "Launch the latest successful build" },
  { name: "logs", core: true, description: "Show the latest build log" },
  { name: "doctor", core: true, description: "Check Git, GitHub CLI, Flutter and Inno Setup (--fix repairs)",
    usage: ["/doctor", "/doctor --fix"] },
  { name: "terminal", core: false, description: "Open a real PowerShell in Windows Terminal (Ctrl+J)" },
  { name: "open", core: false, description: "Open the latest build folder" },
  { name: "help", core: true, description: "All commands and shortcuts" },
  { name: "status", core: false, description: "Repository state and the last build" },
  { name: "branches", core: false, description: "Remote branches by last commit" },
  { name: "history", core: false, description: "Recent local builds" },
  { name: "actions", core: false, description: "What DevKit published, hid or deleted on GitHub",
    usage: ["/actions", "/actions --limit 50"] },
  { name: "rollback", core: false, description: "Restore an older test release",
    usage: ["/rollback --channel <name> --to <tag> --yes"] },
  { name: "try", core: false, description: "Download and start a test build on this computer",
    usage: ["/try --channel <name> --yes"] },
  { name: "rollforward", core: false, description: "Undo a rollback",
    usage: ["/rollforward --channel <name> --yes"] },
  { name: "clean", core: false, description: "Delete outdated test releases",
    usage: ["/clean --dry-run", "/clean --drafts --yes", "/clean --stale 14 --yes"] },
  { name: "cache", core: false, description: "Source build cache", usage: ["/cache", "/cache prune"] },
  { name: "project", core: false, description: "Show or change the project folder", usage: ["/project <path>"] },
  { name: "notify", core: false, description: "Announce published builds in Discord",
    usage: ["/notify <webhook-url>", "/notify test", "/notify off"] },
  { name: "install-apk", core: false, description: "Install the latest Android APK on a USB-connected phone" },
  { name: "android-key", core: false, description: "Android signing key for local APKs",
    usage: ["/android-key <path.jks> [alias]", "/android-key off"] },
  { name: "sign", core: false, description: "Sign builds with a code-signing certificate",
    usage: ["/sign <certificate-thumbprint>", "/sign off"] },
  { name: "update", core: false, description: "Update DevKit itself and restart" },
  { name: "agent", core: false, description: "Open Claude Code in a new tab" },
  { name: "clear", core: false, description: "Clear the transcript" },
  { name: "quit", core: false, description: "Exit DevKit", aliases: ["exit"] },
];

const byName = new Map<string, CommandSpec>();
for (const spec of commandSpecs) {
  byName.set(spec.name, spec);
  for (const alias of spec.aliases ?? []) byName.set(alias, spec);
}

/** Canonical command for a typed name, or undefined. Aliases resolve to their owner. */
export function resolveCommand(name: string): CommandSpec | undefined {
  return byName.get(name.toLowerCase());
}

/** Palette contents: core commands for a bare "/", any match once a prefix is typed. */
export function paletteCommands(value: string, limit = 8): CommandSpec[] {
  if (!value.startsWith("/") || /\s/.test(value)) return [];
  const prefix = value.slice(1).toLowerCase();
  if (!prefix) return commandSpecs.filter(c => c.core).slice(0, limit);
  const starts = commandSpecs.filter(c =>
    c.name.startsWith(prefix) || (c.aliases ?? []).some(a => a.startsWith(prefix)));
  return starts.sort((a, b) => Number(b.core) - Number(a.core)).slice(0, limit);
}

export const shortcuts: [string, string][] = [
  ["/", "commands"],
  ["Enter", "run"],
  ["Tab", "complete command"],
  ["↑ ↓", "history / move in menus"],
  ["1–9", "pick a numbered option"],
  ["Esc", "interrupt · go back · clear"],
  ["Ctrl+C", "copy selection · interrupt · exit (twice)"],
  ["Ctrl+O", "expand / collapse output"],
  ["Ctrl+F", "search transcript"],
  ["Ctrl+J", "PowerShell in a new tab"],
  ["Ctrl+L", "clear transcript"],
  ["PgUp PgDn", "scroll transcript"],
  ["Drag", "select text (copied automatically)"],
];

export function helpText(): string {
  const width = Math.max(...commandSpecs.map(c => c.name.length)) + 4;
  const lines: string[] = [];
  for (const spec of commandSpecs) {
    const alias = spec.aliases?.length ? "  (" + spec.aliases.map(a => "/" + a).join(", ") + ")" : "";
    lines.push(("/" + spec.name).padEnd(width) + spec.description + alias);
  }
  lines.push("", "Examples");
  for (const spec of commandSpecs) for (const u of spec.usage ?? []) if (u.includes(" ")) lines.push("  " + u);
  lines.push("", "Shortcuts");
  for (const [key, action] of shortcuts) lines.push("  " + key.padEnd(12) + action);
  lines.push("", "Anything without / runs in PowerShell; cd persists between commands.");
  return lines.join("\n");
}
