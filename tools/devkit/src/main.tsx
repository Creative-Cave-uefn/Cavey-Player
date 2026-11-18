import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  AlternateScreen, Box, Text, render, useApp, useSelection, useTabStatus, useTerminalFocus, useTerminalTitle,
} from "@claude-code-kit/ink-renderer";
import { SearchOverlay, VirtualList, useTerminalSize, type VirtualListHandle } from "@claude-code-kit/ui";
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { CommandPrompt } from "./CommandPrompt.js";
import { helpText, resolveCommand } from "./commands.js";
import { createWorkflowStream, stageOrder, stripWorkflowMarkers, type StageRecord } from "./build-events.js";
import { releaseChannels, type ReleaseRecord } from "./choices.js";
import {
  changeDirectory, commandRequest, engineCommands, gitBranchesRequest, gitStatusRequest, initialDirectory,
  launchTerminal, parseGitStatus, prettyDirectory, projectLabel, releaseListRequest, repositoryRoot,
  runCommand, shellRequest, splitArgs, type GitState, type RunRequest,
} from "./runner.js";
import { spinnerFrames, theme, toneColor } from "./theme.js";
import {
  estimateBuildMs, formatDuration, summarizeOutput, type Entry, type NewEntry, type RunStatus,
} from "./transcript.js";
import {
  buildConfirm, channelReleases, dialogFor, isDevKitChannel, parseBranches, pickSummary, runTitle, simpleConfirm,
  type Branch, type ConfirmCommand, type SavedRun, type Wizard,
} from "./wizard.js";

const DATA_HOME = process.env.LOCALAPPDATA
  ? join(process.env.LOCALAPPDATA, "CaveyDevKit")
  : join(homedir(), ".cavey-devkit");
const HISTORY_FILE = join(DATA_HOME, "terminal-history.json");
const LIMIT = 150;
const VERSION = (() => {
  try { return String(JSON.parse(readFileSync(join(repositoryRoot, "tools", "devkit", "package.json"), "utf8")).version); }
  catch { return ""; }
})();

const stageVerbs: Record<string, string> = {
  source: "Preparing source", prepare: "Preparing project", checks: "Running checks",
  compile: "Compiling", package: "Packaging", publish: "Publishing",
};
const stageTitles: Record<string, string> = {
  source: "Source", prepare: "Prepare", checks: "Checks", compile: "Compile", package: "Package", publish: "Publish",
};

function loadHistory(): string[] {
  try {
    const saved = JSON.parse(readFileSync(HISTORY_FILE, "utf8"));
    if (Array.isArray(saved)) return saved.filter((s): s is string => typeof s === "string").slice(0, 200);
  } catch { /* first launch */ }
  return [];
}

function loadBuildHistory(): { status?: string; seconds?: number }[] {
  try {
    return readFileSync(join(DATA_HOME, "history.jsonl"), "utf8").split(/\r?\n/).filter(Boolean)
      .map(line => { try { return JSON.parse(line); } catch { return null; } }).filter(Boolean);
  } catch { return []; }
}

function loadRecoverableRuns(): SavedRun[] {
  const root = join(DATA_HOME, "builds");
  try {
    return readdirSync(root, { withFileTypes: true }).filter(d => d.isDirectory())
      .map(d => { try { return JSON.parse(readFileSync(join(root, d.name, "run.json"), "utf8")) as SavedRun; } catch { return null; } })
      .filter((v): v is SavedRun => v !== null && ["built", "publish_failed"].includes(v.status))
      .sort((a, b) => (b.updatedUtc ?? "").localeCompare(a.updatedUtc ?? ""));
  } catch { return []; }
}

function entryText(e: Entry): string {
  switch (e.kind) {
    case "welcome": return "";
    case "input": return e.text;
    case "step": return e.title + " " + (e.detail ?? "");
    case "note": return e.text;
    case "run": return e.title + "\n" + e.output;
  }
}

// ── Transcript rendering ─────────────────────────────────────────────

function Welcome({ directory }: { directory: string }) {
  return (
    <Box flexDirection="column" borderStyle="round" borderColor={theme.accent} paddingX={1} alignSelf="flex-start">
      <Text><Text color={theme.accent}>✻ </Text><Text bold color={theme.text}>Cavey DevKit</Text>
        {VERSION ? <Text color={theme.dim}> v{VERSION}</Text> : null}</Text>
      <Text> </Text>
      <Text color={theme.dim}>  /build to start · /help for all commands · ? for shortcuts</Text>
      <Text color={theme.dim}>  {prettyDirectory(directory)}</Text>
    </Box>
  );
}

function StageLine({ stages }: { stages: StageRecord[] }) {
  const byName = new Map(stages.map(s => [s.name, s]));
  return (
    <Box flexDirection="row" flexWrap="wrap" columnGap={2}>
      {stageOrder.map(name => {
        const stage = byName.get(name);
        const state = stage?.state ?? "waiting";
        const mark = state === "done" ? "✓" : state === "failed" ? "✗" : state === "skipped" ? "–"
          : state === "running" ? "◆" : "·";
        const color = state === "done" ? theme.success : state === "failed" ? theme.error
          : state === "running" ? theme.accent : theme.dim;
        const time = stage?.durationMs !== undefined && state !== "skipped" ? " " + formatDuration(stage.durationMs) : "";
        return <Text key={name} color={color}>{mark} {stageTitles[name]}{time}</Text>;
      })}
    </Box>
  );
}

function Gutter({ first, children }: { first: boolean; children: React.ReactNode }) {
  return (
    <Box flexDirection="row">
      <Box width={5} flexShrink={0}><Text color={theme.dim}>{first ? "  ⎿  " : "     "}</Text></Box>
      <Box flexGrow={1} flexShrink={1}>{children}</Box>
    </Box>
  );
}

function RunView({ entry, expanded }: { entry: Extract<Entry, { kind: "run" }>; expanded: boolean }) {
  const view = summarizeOutput(entry.output, expanded);
  const dot: Record<RunStatus, string> = {
    running: theme.dim, success: theme.success, error: theme.error, cancelled: theme.warning,
  };
  const rows: React.ReactNode[] = [];
  if (entry.stages?.length) rows.push(<StageLine key="stages" stages={entry.stages} />);
  view.lines.forEach((line, i) => {
    rows.push(line === null
      ? <Text key={"gap" + i} color={theme.dim}>… +{view.hidden} lines (ctrl+o to expand)</Text>
      : <Text key={i} wrap="wrap" color={line.kind === "error" ? theme.error : line.kind === "warning" ? theme.warning
        : line.kind === "success" ? theme.success : theme.text}>{line.text}</Text>);
  });
  if (entry.status !== "running") {
    const time = entry.durationMs !== undefined && entry.durationMs >= 3000 ? formatDuration(entry.durationMs) : "";
    if (entry.status === "error") rows.push(<Text key="end" color={theme.error}>Failed · exit {entry.exitCode ?? 1}{time ? " · " + time : ""}</Text>);
    else if (entry.status === "cancelled") rows.push(<Text key="end" color={theme.warning}>Interrupted{time ? " · " + time : ""}</Text>);
    else if (time) rows.push(<Text key="end" color={theme.dim}>Done in {time}</Text>);
    else if (!view.total && !entry.stages?.length) rows.push(<Text key="end" color={theme.dim}>(no output)</Text>);
  }
  return (
    <Box flexDirection="column">
      <Text><Text color={dot[entry.status]}>⏺ </Text><Text bold color={theme.text}>{entry.title}</Text></Text>
      {rows.map((row, i) => <Gutter key={i} first={i === 0}>{row}</Gutter>)}
    </Box>
  );
}

function EntryView({ entry, expanded, directory }: { entry: Entry; expanded: boolean; directory: string }) {
  switch (entry.kind) {
    case "welcome": return <Welcome directory={directory} />;
    case "input": return <Text color={theme.dim}>{"> " + entry.text}</Text>;
    case "step":
      return (
        <Text><Text color={toneColor(entry.tone ?? "success")}>⏺ </Text><Text bold color={theme.text}>{entry.title}</Text>
          {entry.detail ? <Text color={theme.text}>  {entry.detail}</Text> : null}</Text>
      );
    case "note":
      return (
        <Box flexDirection="column">
          {entry.text.split("\n").map((line, i) => (
            <Gutter key={i} first={i === 0}><Text wrap="wrap" color={toneColor(entry.tone ?? "dim")}>{line || " "}</Text></Gutter>
          ))}
        </Box>
      );
    case "run": return <RunView entry={entry} expanded={expanded} />;
  }
}

function SpinnerLine({ verb, startedAt, etaMs }: { verb: string; startedAt: number; etaMs: number | null }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => { const id = setInterval(() => setNow(Date.now()), 120); return () => clearInterval(id); }, []);
  const elapsed = now - startedAt;
  const frame = spinnerFrames[Math.floor(elapsed / 120) % spinnerFrames.length];
  const parts = [formatDuration(elapsed)];
  if (etaMs && etaMs > elapsed) parts.push("~" + formatDuration(etaMs - elapsed) + " left");
  parts.push("esc to interrupt");
  return (
    <Box paddingX={2} marginTop={1} flexShrink={0}>
      <Text><Text color={theme.accent}>{frame} {verb}…</Text><Text color={theme.dim}> ({parts.join(" · ")})</Text></Text>
    </Box>
  );
}

// ── App ───────────────────────────────────────────────────────────────

type Busy = { verb: string; startedAt: number; etaMs: number | null };
type RunOptions = { title?: string; echo?: string; etaMs?: number | null };

function App() {
  const { exit } = useApp();
  const selection = useSelection();
  const focusedTerminal = useTerminalFocus();
  const [directory, setDirectory] = useState(initialDirectory);
  const [git, setGit] = useState<GitState | null>(null);
  const [entries, setEntries] = useState<Entry[]>([{ id: "welcome", kind: "welcome" }]);
  const [history, setHistory] = useState(loadHistory);
  const [busy, setBusy] = useState<Busy | null>(null);
  const [stack, setStack] = useState<Wizard[]>([]);
  const [inputValue, setInputValue] = useState("");
  const [searchOpen, setSearchOpen] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const [showKeys, setShowKeys] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const terminal = useTerminalSize();
  const listRef = useRef<VirtualListHandle>(null);
  const pointerInTranscript = useRef(false);
  const nextId = useRef(0);
  const active = useRef<AbortController | null>(null);
  const lastCtrlC = useRef(0);
  const noteTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const wizard = stack.length ? stack[stack.length - 1]! : null;
  const dialog = wizard ? dialogFor(wizard) : undefined;

  const flash = useCallback((text: string) => {
    setNote(text);
    if (noteTimer.current) clearTimeout(noteTimer.current);
    noteTimer.current = setTimeout(() => setNote(null), 2500);
  }, []);

  const add = useCallback((entry: NewEntry) => {
    const id = entry.id ?? String(++nextId.current);
    setEntries(old => [...old.slice(-(LIMIT - 1)), { ...entry, id } as Entry]);
    return id;
  }, []);
  const patch = useCallback((id: string, update: (e: Extract<Entry, { kind: "run" }>) => Partial<Extract<Entry, { kind: "run" }>>) => {
    setEntries(old => old.map(e => e.id === id && e.kind === "run" ? { ...e, ...update(e) } : e));
  }, []);
  const step = useCallback((title: string, detail?: string) => { add({ kind: "step", title, detail }); }, [add]);
  const fail = useCallback((text: string) => { add({ kind: "note", text: text.replace(/^Error: /, ""), tone: "error" }); }, [add]);

  const remember = useCallback((entry: string) => {
    if (!entry.trim()) return;
    setHistory(previous => {
      const updated = [entry, ...previous.filter(item => item !== entry)].slice(0, 200);
      try { mkdirSync(DATA_HOME, { recursive: true }); writeFileSync(HISTORY_FILE, JSON.stringify(updated), "utf8"); }
      catch { /* read-only disk */ }
      return updated;
    });
  }, []);

  const refreshGit = useCallback(async (cwd: string) => {
    try {
      const state = await runCommand(gitStatusRequest(cwd));
      setGit(state.code === 0 ? parseGitStatus(state.output) : null);
    } catch { setGit(null); }
  }, []);
  useEffect(() => { void refreshGit(directory); }, [directory, refreshGit]);

  // Copy on select, like Claude Code's fullscreen mode.
  useEffect(() => {
    selection.setSelectionBgColor("#3D3A44");
    let dragging = false;
    return selection.subscribe(() => {
      const state = selection.getState();
      const nowDragging = Boolean(state?.isDragging);
      if (dragging && !nowDragging && selection.hasSelection()) {
        const text = selection.copySelectionNoClear();
        if (text) flash("Copied " + text.length + " characters");
      }
      dragging = nowDragging;
    });
  }, [selection, flash]);

  // Terminal chrome: title, tab dot and Windows Terminal taskbar progress.
  const running = busy !== null;
  useTerminalTitle(busy ? busy.verb + " · Cavey DevKit" : "Cavey DevKit");
  useTabStatus(busy ? "busy" : dialog ? "waiting" : "idle");
  useEffect(() => {
    if (!process.env.WT_SESSION) return;
    try { process.stdout.write(running ? "\x1b]9;4;3;0\x07" : "\x1b]9;4;0;0\x07"); } catch { /* ignore */ }
  }, [running]);

  const execute = useCallback(async (req: RunRequest, options: RunOptions = {}) => {
    if (active.current) { flash("A command is already running · Esc to interrupt"); return; }
    if (options.echo) { add({ kind: "input", text: options.echo }); remember(options.echo); }
    const controller = new AbortController();
    active.current = controller;
    const startedAt = Date.now();
    const isBuild = /^\/(?:build|rollback|rollforward|resume|retry-publish|recover)(?:\s|$)/.test(req.label);
    const id = add({ kind: "run", title: options.title ?? req.label, output: "", status: "running",
      stages: isBuild ? [] : undefined });
    setBusy({ verb: isBuild ? "Starting" : "Running", startedAt, etaMs: options.etaMs ?? null });
    let restart = false;
    const stream = createWorkflowStream(event => {
      if (event.kind === "restart") { restart = true; return; }
      const now = Date.now();
      patch(id, e => {
        const stages = e.stages ?? [];
        const old = stages.find(x => x.name === event.stage);
        const begun = old?.startedAt ?? now;
        return { stages: [...stages.filter(x => x.name !== event.stage), {
          name: event.stage, state: event.state, label: event.label, startedAt: begun, updatedAt: now,
          durationMs: ["done", "failed", "skipped"].includes(event.state) ? now - begun : undefined,
        }] };
      });
      if (event.state === "running") setBusy(b => b && { ...b, verb: stageVerbs[event.stage] ?? "Running" });
    });
    let raw = "";
    let pending: ReturnType<typeof setTimeout> | null = null;
    const flush = () => { pending = null; const text = raw.slice(-40000); patch(id, () => ({ output: text })); };
    try {
      const result = await runCommand(req, controller.signal, chunk => {
        raw = (raw + stream.push(chunk)).slice(-80000);
        if (!pending) pending = setTimeout(flush, 80);
      });
      raw += stream.finish();
      if (pending) clearTimeout(pending);
      const status: RunStatus = result.cancelled ? "cancelled" : result.code === 0 ? "success" : "error";
      patch(id, e => ({
        output: stripWorkflowMarkers(result.output).slice(-40000), status, exitCode: result.code,
        durationMs: result.durationMs,
        stages: e.stages?.map(s => s.state === "running" && status !== "success"
          ? { ...s, state: "failed" as const, label: "Interrupted or failed" } : s),
      }));
      if (result.durationMs > 60000 && !focusedTerminal) { try { process.stdout.write("\x07"); } catch { /* ignore */ } }
      if (req.label.startsWith("/project") && result.code === 0) {
        const updated = initialDirectory();
        if (updated !== directory) setDirectory(updated);
      }
      if (restart && result.code === 0) { process.exitCode = 42; exit(); }
    } catch (error) {
      if (pending) clearTimeout(pending);
      patch(id, () => ({ output: raw + "\n" + String(error), status: "error", durationMs: Date.now() - startedAt }));
    } finally {
      if (active.current === controller) active.current = null;
      setBusy(null);
      void refreshGit(directory);
    }
  }, [add, directory, exit, flash, focusedTerminal, patch, refreshGit, remember]);

  const runEngine = useCallback(async (command: string, args: string[], options: RunOptions = {}) => {
    try { await execute(commandRequest(command, args, directory), { title: runTitle(command, args), ...options }); }
    catch (error) { fail(String(error)); }
  }, [directory, execute, fail]);

  /** Background fetch shown on the spinner line, not in the transcript. */
  const fetching = useCallback(async <T,>(verb: string, work: () => Promise<T>): Promise<T | null> => {
    if (active.current || busy) { flash("A command is already running · Esc to interrupt"); return null; }
    setBusy({ verb, startedAt: Date.now(), etaMs: null });
    try { return await work(); }
    catch (error) { fail(String(error)); return null; }
    finally { setBusy(null); }
  }, [busy, fail, flash]);

  const loadBranches = useCallback(async (): Promise<Branch[]> => {
    const fetched = await runCommand({ program: "git", args: ["fetch", "origin", "--prune"], cwd: directory, label: "git fetch" });
    if (fetched.code !== 0) add({ kind: "note", text: "Could not refresh from origin; showing cached branches.", tone: "warning" });
    const refs = await runCommand(gitBranchesRequest(directory));
    if (refs.code !== 0) throw new Error("git for-each-ref failed: " + refs.output);
    return parseBranches(refs.output).slice(0, 100);
  }, [add, directory]);

  const loadReleases = useCallback(async (required: boolean): Promise<ReleaseRecord[]> => {
    let result: Awaited<ReturnType<typeof runCommand>>;
    try { result = await runCommand(releaseListRequest(directory)); }
    catch (error) {
      if (required) throw new Error("GitHub CLI (gh) is not available: " + String(error));
      return [];
    }
    if (result.code !== 0) {
      if (required) throw new Error("Could not load releases. Check gh auth status.\n" + result.output);
      return [];
    }
    return JSON.parse(result.output) as ReleaseRecord[];
  }, [directory]);

  const etaMs = useCallback(() => estimateBuildMs(loadBuildHistory()), []);

  // ── Wizard navigation ──
  const push = useCallback((w: Wizard) => setStack(s => [...s, w]), []);
  const closeWizard = useCallback(() => setStack([]), []);
  const back = useCallback(() => {
    // Undo the transcript line written when this step was reached.
    if (stack.length > 1) setEntries(old => old.length && old[old.length - 1]!.kind === "step" ? old.slice(0, -1) : old);
    setStack(s => {
      if (s.length <= 1) { add({ kind: "note", text: "Cancelled" }); return []; }
      return s.slice(0, -1);
    });
  }, [add, stack.length]);

  const openBuild = useCallback(async () => {
    const data = await fetching("Fetching branches", async () =>
      Promise.all([loadBranches(), loadReleases(false)]));
    if (!data) return;
    const [branches, releases] = data;
    if (!branches.length) { fail("No remote branches found. Run /doctor."); return; }
    setStack([{ kind: "branch", branches, releases }]);
  }, [fail, fetching, loadBranches, loadReleases]);

  const openReleases = useCallback(async (start: "home" | "channel") => {
    const releases = await fetching("Loading releases", () => loadReleases(true));
    if (!releases) return;
    const manager: Wizard = { kind: "manager-channel", releases };
    if (!releases.some(r => r.isPrerelease && !r.isDraft && r.tagName.startsWith("test-"))) {
      add({ kind: "note", text: "No test releases yet. Use /build to publish one." });
      return;
    }
    if (start === "channel") setStack([manager]);
    else setStack([{ kind: "releases-home" }]);
  }, [add, fetching, loadReleases]);

  const openRecovery = useCallback(async () => {
    const runs = loadRecoverableRuns();
    if (!runs.length) { await runEngine("recover", [], { title: "Saved builds" }); return; }
    setStack([{ kind: "recover", runs }]);
  }, [runEngine]);

  const pick = useCallback(async (value: string) => {
    if (!wizard) return;
    const summary = pickSummary(wizard, value);
    if (summary) step(summary[0], summary[1] || undefined);
    switch (wizard.kind) {
      case "releases-home": {
        if (value === "list") { closeWizard(); await runEngine("releases", []); return; }
        if (value === "clean") { push(simpleConfirm("clean", ["--keep", "3"])); return; }
        const releases = await fetching("Loading releases", () => loadReleases(true));
        if (releases) push({ kind: "manager-channel", releases });
        return;
      }
      case "branch": {
        const branch = wizard.branches.find(b => b.name === value);
        if (!branch) return;
        if (wizard.target) { push(buildConfirm(branch, "update", wizard.releases, etaMs(), wizard.target)); return; }
        push({ kind: "mode", branch, releases: wizard.releases });
        return;
      }
      case "mode": {
        if (value === "update") {
          const releases = wizard.releases.length ? wizard.releases
            : await fetching("Loading channels", () => loadReleases(true));
          if (!releases) return;
          if (!releaseChannels(releases).some(c => isDevKitChannel(c.value))) {
            fail("No DevKit channels yet. Choose New test release to create one.");
            return;
          }
          push({ kind: "channel", branch: wizard.branch, releases });
          return;
        }
        push(buildConfirm(wizard.branch, value as "local" | "new", wizard.releases, etaMs()));
        return;
      }
      case "channel":
        push(buildConfirm(wizard.branch, "update", wizard.releases, etaMs(), value));
        return;
      case "manager-channel":
        push({ kind: "manager-action", channel: value, releases: wizard.releases });
        return;
      case "manager-action": {
        if (value === "history") {
          closeWizard();
          await runEngine("manager", ["--channel", wizard.channel]);
          return;
        }
        if (value === "rollforward") {
          push(simpleConfirm("rollforward", ["--channel", wizard.channel]));
          return;
        }
        if (value === "rollback") {
          const versions = channelReleases(wizard.releases, wizard.channel);
          if (versions.length < 2) { fail("Rollback needs at least two active versions in this channel."); return; }
          push({ kind: "manager-versions", channel: wizard.channel, releases: versions.slice(1) });
          return;
        }
        const branches = await fetching("Fetching branches", loadBranches);
        if (branches) push({ kind: "branch", branches, releases: wizard.releases, target: wizard.channel });
        return;
      }
      case "manager-versions":
        push(simpleConfirm("rollback", ["--channel", wizard.channel, "--to", value]));
        return;
      case "recover":
        push(simpleConfirm("resume", ["--id", value]));
        return;
      case "confirm": {
        if (value === "back") { back(); return; }
        closeWizard();
        if (value === "dry-run") { await runEngine("clean", [...wizard.args, "--dry-run"]); return; }
        const local = value === "local";
        const args = local ? [...wizard.args, "--local"] : wizard.args;
        await runEngine(wizard.command, [...args, "--yes"], {
          title: runTitle(wizard.command, args), etaMs: wizard.command === "build" ? etaMs() : null,
        });
        return;
      }
    }
  }, [back, closeWizard, etaMs, fail, fetching, loadBranches, loadReleases, push, runEngine, step, wizard]);

  const confirm = useCallback((command: ConfirmCommand, args: string[]) => {
    setStack([command === "build"
      ? { kind: "confirm", command, args, question: "Run this build?", plan: [["Options", args.join(" ")]],
          options: [{ value: "yes", label: "Yes, run it" }, { value: "back", label: "No, cancel" }] }
      : simpleConfirm(command, args)]);
  }, []);

  const handleCommand = useCallback(async (typed: string, text: string) => {
    const args = splitArgs(text);
    const label = "/" + typed + (text.trim() ? " " + text.trim() : "");
    const spec = resolveCommand(typed);
    if (!spec) { add({ kind: "input", text: label }); fail("Unknown command /" + typed + ". Type /help."); return; }
    const echo = () => { add({ kind: "input", text: label }); remember(label); };
    const yes = args.includes("--yes");
    switch (spec.name) {
      case "quit": exit(); return;
      case "clear": setEntries([{ id: "welcome", kind: "welcome" }]); closeWizard(); return;
      case "help": echo(); add({ kind: "note", text: helpText(), tone: "normal" }); return;
      case "terminal": case "agent": {
        echo();
        try { add({ kind: "note", text: await launchTerminal(directory, spec.name === "agent") }); }
        catch (error) { fail(String(error)); }
        return;
      }
      case "releases":
        echo();
        if (!args.length) { await openReleases("home"); return; }
        await runEngine("manager", args);
        return;
      case "rollback": case "rollforward":
        echo();
        if (!args.length) { await openReleases("channel"); return; }
        if (!yes) { confirm(spec.name, args); return; }
        break;
      case "recover":
        echo();
        if (!args.includes("--id")) { await openRecovery(); return; }
        if (!yes) { confirm("resume", args); return; }
        await runEngine("resume", args);
        return;
      case "clean":
        echo();
        if (!yes && !args.includes("--dry-run")) { confirm("clean", args); return; }
        break;
      case "cache":
        echo();
        if (args.includes("prune") && !yes) { confirm("cache", args); return; }
        break;
      case "build":
        echo();
        if (!args.length) { await openBuild(); return; }
        if (!yes) { confirm("build", args); return; }
        await runEngine("build", args, { etaMs: etaMs() });
        return;
      default:
        echo();
    }
    if (engineCommands.has(spec.name)) await runEngine(spec.name, args);
    else fail("/" + spec.name + " is not available here.");
  }, [add, closeWizard, confirm, directory, etaMs, exit, fail, openBuild, openRecovery, openReleases, remember, runEngine]);

  const handleSubmit = useCallback(async (text: string) => {
    const trimmed = text.trim();
    if (!trimmed) return;
    if (busy) { flash("Wait for the current command, or press Esc to interrupt"); return; }
    if (trimmed.startsWith("/")) {
      const tokens = splitArgs(trimmed.slice(1));
      await handleCommand((tokens.shift() || "").toLowerCase(), tokens.join(" "));
      return;
    }
    if (trimmed === "exit" || trimmed === "quit") { exit(); return; }
    try {
      const next = changeDirectory(directory, trimmed);
      if (next) {
        add({ kind: "input", text: trimmed }); remember(trimmed); setDirectory(next);
        step("Directory", next);
        return;
      }
    } catch (error) { add({ kind: "input", text: trimmed }); fail(String(error)); return; }
    await execute(shellRequest(trimmed, directory), { echo: trimmed, title: "PowerShell(" + trimmed + ")" });
  }, [add, busy, directory, execute, exit, fail, flash, handleCommand, remember, step]);

  const interrupt = useCallback(() => { active.current?.abort(); }, []);

  const ctrlC = useCallback(() => {
    if (selection.hasSelection()) {
      const text = selection.copySelection();
      flash("Copied " + text.length + " characters");
      return;
    }
    if (active.current) { active.current.abort(); return; }
    if (wizard) { closeWizard(); setInputValue(""); add({ kind: "note", text: "Cancelled" }); return; }
    if (inputValue) { setInputValue(""); return; }
    const now = Date.now();
    if (now - lastCtrlC.current < 1500) { exit(); return; }
    lastCtrlC.current = now;
    flash("Press Ctrl+C again to exit");
  }, [add, closeWizard, exit, flash, inputValue, selection, wizard]);

  const searchMatches = useCallback((query: string) => {
    if (!query.trim()) return [];
    const found: { index: number; offset: number; length: number }[] = [];
    entries.forEach((entry, index) => {
      const offset = entryText(entry).toLowerCase().indexOf(query.toLowerCase());
      if (offset >= 0) found.push({ index, offset, length: query.length });
    });
    return found;
  }, [entries]);

  // ── Layout ──
  const maxDialogRows = Math.max(3, Math.min(12, terminal.rows - 18 - (dialog?.plan?.length ?? 0)));
  const promptRows = (() => {
    if (dialog && !searchOpen) {
      const shown = Math.min(maxDialogRows, Math.max(1, dialog.options.length));
      const more = dialog.options.length > shown ? 2 : 0;
      return 2 + 1 + (dialog.plan?.length ? 1 + dialog.plan.length : 0) + (dialog.filterable ? 2 : 0) + 1 + shown + more + 2;
    }
    const typed = inputValue.startsWith("/") && !/\s/.test(inputValue);
    return 3 + (showKeys ? 13 : typed ? 8 : 1);
  })();
  const spinnerRows = busy ? 2 : 0;
  const viewport = Math.max(3, terminal.rows - promptRows - spinnerRows - (searchOpen ? 2 : 0) - 2);

  const footerRight = useMemo(() => {
    if (!git) return projectLabel(directory);
    const sync = (git.ahead ? " ↑" + git.ahead : "") + (git.behind ? " ↓" + git.behind : "");
    return projectLabel(directory) + " · " + git.branch + (git.dirty ? " ●" : " ✓") + sync;
  }, [directory, git]);

  return (
    <AlternateScreen mouseTracking>
      <Box flexDirection="column" width="100%" height="100%">
        <Box flexDirection="column" flexGrow={1} paddingX={2} paddingTop={1}
          onMouseEnter={() => { pointerInTranscript.current = true; }}
          onMouseLeave={() => { pointerInTranscript.current = false; }}>
          <VirtualList
            ref={listRef}
            items={entries}
            itemKey={e => e.id}
            viewportHeight={viewport}
            followOutput
            overscan={3}
            renderItem={(entry, index) => (
              <Box flexDirection="column" paddingTop={index > 0 ? 1 : 0}>
                <EntryView entry={entry} expanded={expanded} directory={directory} />
              </Box>
            )}
          />
        </Box>
        {busy && <SpinnerLine verb={busy.verb} startedAt={busy.startedAt} etaMs={busy.etaMs} />}
        {searchOpen && (
          <SearchOverlay isOpen={searchOpen} onClose={() => setSearchOpen(false)} onSearch={searchMatches}
            onNavigate={match => listRef.current?.scrollTo(match.index)} />
        )}
        <Box marginTop={1} flexShrink={0} flexDirection="column">
          <CommandPrompt
            value={inputValue}
            onChange={setInputValue}
            onSubmit={handleSubmit}
            history={history}
            dialog={busy ? undefined : dialog}
            maxDialogRows={maxDialogRows}
            onPick={pick}
            onBack={back}
            running={running}
            searchOpen={searchOpen}
            footerRight={footerRight}
            footerNote={note}
            showKeys={showKeys}
            setShowKeys={setShowKeys}
            onEscapeIdle={() => { /* nothing to cancel */ }}
            onInterrupt={interrupt}
            onCtrlC={ctrlC}
            onTerminal={() => { void handleCommand("terminal", ""); }}
            onSearch={() => setSearchOpen(true)}
            onClear={() => { void handleCommand("clear", ""); setInputValue(""); }}
            onToggleExpand={() => setExpanded(x => !x)}
            onScroll={delta => listRef.current?.scrollBy(delta)}
            onWheel={delta => { if (pointerInTranscript.current) listRef.current?.scrollBy(delta); }}
          />
        </Box>
      </Box>
    </AlternateScreen>
  );
}

if (!process.stdin.isTTY || !process.stdout.isTTY) {
  process.stderr.write("Cavey DevKit requires an interactive terminal. Use Windows Terminal.\n");
  process.exitCode = 1;
} else {
  await render(<App />);
}

