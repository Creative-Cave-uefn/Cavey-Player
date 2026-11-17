import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AlternateScreen, Box, Text, render, useApp } from "@claude-code-kit/ink-renderer";
import { MessageList, SearchOverlay, StatusLine, Spinner, useTerminalSize, type Message, type StatusLineSegment, type VirtualListHandle } from "@claude-code-kit/ui";
import { CommandPrompt, matchCommands } from "./CommandPrompt.js";
import { releaseChannels, type ChoiceMenu, type ReleaseRecord } from "./choices.js";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  changeDirectory, commandRequest, engineCommands, gitBranchRequest, gitBranchesRequest,
  initialDirectory, launchTerminal, prettyDirectory, projectLabel, repositoryRoot,
  runCommand, shellRequest, splitArgs, type RunRequest,
} from "./runner.js";

const ACCENT = "#DA7756";
const DATA_HOME = process.env.LOCALAPPDATA
  ? join(process.env.LOCALAPPDATA, "CaveyDevKit")
  : join(homedir(), ".cavey-devkit");
const HISTORY_FILE = join(DATA_HOME, "terminal-history.json");
const LIMIT = 100;

function loadHistory(): string[] {
  try {
    const saved = JSON.parse(readFileSync(HISTORY_FILE, "utf8"));
    if (Array.isArray(saved)) return saved.filter((s): s is string => typeof s === "string").slice(0, 200);
  } catch { /* first launch */ }
  return [];
}

const catalog = [
  { name: "build", description: "Мастер сборок / параметры ветки" },
  { name: "branches", description: "Ветки GitHub" },
  { name: "terminal", description: "Открыть настоящий PowerShell" },
  { name: "agent", description: "Открыть установленный Claude Code" },
  { name: "project", description: "Папка исходников проекта" },
  { name: "status", description: "Git и последние сборки" },
  { name: "releases", description: "Тестовые релизы" },
  { name: "clean", description: "Очистить старые тестовые релизы" },
  { name: "history", description: "История сборок" },
  { name: "logs", description: "Просмотреть журнал сборки" },
  { name: "run", description: "Запустить последнюю сборку" },
  { name: "doctor", description: "Диагностика инструментов" },
  { name: "clear", description: "Очистить историю на экране" },
  { name: "help", description: "Все доступные команды" },
  { name: "quit", description: "Выйти из DevKit" },
];

const helpText = [
  "CAVEY DEVKIT  ·  Commands",
  "",
  "/build                           Интерактивный мастер сборки",
  "/build --branch latest --local    Локальная сборка (с подтверждением)",
  "/build --branch <name>            Тестовый релиз (с подтверждением)",
  "/branches   /status   /releases   /history   /logs",
  "/clean --dry-run                  Просмотр без удаления",
  "/run        /doctor   /project [path]   /terminal",
  "/agent      /clear    /quit",
  "",
  "Commands without / run in PowerShell. cd persists between commands.",
  "For interactive processes, use /terminal.",
  "Tab: autocomplete · ↑↓: history · PgUp/PgDn: scroll",
  "Ctrl+F: search · Ctrl+C: cancel · Ctrl+J: terminal",
].join("\n");

type Wizard =
  | { kind: "branch"; branches: string[] }
  | { kind: "mode"; branch: string }
  | { kind: "channel"; branch: string; channels: { value: string; label: string; detail?: string }[] }
  | { kind: "confirm"; command: "build" | "clean"; args: string[]; summary: string };

function formatMessage(m: Message): React.ReactNode {
  const body = typeof m.content === "string" ? m.content :
    m.content.map(part => "text" in part ? part.text : JSON.stringify(part)).join("\n");
  return (
    <Box flexDirection="row" gap={2} paddingX={1} marginBottom={1}>
      <Text color={m.role === "user" ? "#A6A4AD" : ACCENT} bold>
        {m.role === "user" ? "›" : "✳"}
      </Text>
      <Box flexGrow={1}>
        <Text color={m.role === "user" ? "#E0DCE1" : "#D5D1D7"} wrap="wrap">{body}</Text>
      </Box>
    </Box>
  );
}


function Header({ directory, branch, activity, loading, compact }: {
  directory: string; branch: string; activity: string; loading: boolean; compact: boolean;
}) {
  const stateColor = loading ? "#DBAC72" : activity === "error" ? "#DB817C" : "#A4B8A5";
  return (
    <Box flexDirection="column" paddingX={3} paddingTop={1} flexShrink={0}>
      <Box flexDirection="row" justifyContent="space-between" alignItems="center">
        <Box gap={1}>
          <Text color="#DF9472" bold>✳</Text>
          <Text bold color="#E9E3E5">Cavey DevKit</Text>
          <Text color="#77737C">v1.3</Text>
        </Box>
        <Text color={stateColor}>{loading ? "● " + activity : activity === "error" ? "● error" : "● ready"}</Text>
      </Box>
      <Box flexDirection="row" gap={1}>
        <Text color="#817D87" wrap="truncate-end">{prettyDirectory(directory)}</Text>
        {!compact && <Text color="#6E6B74" wrap="truncate-end">·  {branch}</Text>}
      </Box>
    </Box>
  );
}

function App() {
  const { exit } = useApp();
  const [directory, setDirectory] = useState(initialDirectory);
  const [branch, setBranch] = useState("loading");
  const [messages, setMessages] = useState<Message[]>([]);
  const [history, setHistory] = useState(loadHistory);
  const [loading, setLoading] = useState(false);
  const [streaming, setStreaming] = useState<string | null>(null);
  const [activity, setActivity] = useState("ready");
  const [wizard, setWizard] = useState<Wizard | null>(null);
  const [inputValue, setInputValue] = useState("");
  const [searchOpen, setSearchOpen] = useState(false);
  const terminal = useTerminalSize();
  const compact = terminal.rows < 29 || terminal.columns < 110;
  const historyRef = useRef<VirtualListHandle>(null);
  const nextId = useRef(0);
  const active = useRef<AbortController | null>(null);

  const append = useCallback((role: Message["role"], content: string) => {
    const id = String(++nextId.current);
    setMessages(old => [...old.slice(-(LIMIT - 1)), { id, role, content, timestamp: Date.now() }]);
  }, []);

  const remember = useCallback((entry: string) => {
    if (!entry.trim()) return;
    setHistory(previous => {
      const updated = [entry, ...previous.filter(item => item !== entry)].slice(0, 200);
      try {
        mkdirSync(DATA_HOME, { recursive: true });
        writeFileSync(HISTORY_FILE, JSON.stringify(updated), "utf8");
      } catch { /* read-only disk: session history still works */ }
      return updated;
    });
  }, []);

  const refreshBranch = useCallback(async (cwd: string) => {
    try {
      const state = await runCommand(gitBranchRequest(cwd));
      setBranch(state.code === 0 ? (state.output || "(detached)") : "no git");
    } catch { setBranch("no git"); }
  }, []);

  useEffect(() => {
    void refreshBranch(directory);
  }, [directory, refreshBranch]);

  const execute = useCallback(async (label: string, req: RunRequest, echo = true) => {
    if (active.current) { append("system", "A command is already running. Press Ctrl+C to cancel."); return; }
    if (echo) { append("user", label); remember(label); }
    const controller = new AbortController();
    active.current = controller;
    setLoading(true);
    setActivity("running");
    setStreaming("");
    let raw = "";
    let pendingFlush: ReturnType<typeof setTimeout> | null = null;
    const flush = () => {
      pendingFlush = null;
      setStreaming(raw.slice(-11000));
    };
    try {
      const result = await runCommand(req, controller.signal, chunk => {
        raw = (raw + chunk).slice(-60000);
        if (!pendingFlush) pendingFlush = setTimeout(flush, 65);
      });
      if (pendingFlush) clearTimeout(pendingFlush);
      setStreaming(null);
      const text = result.output.slice(-25000);
      append("assistant", (result.cancelled ? "Cancelled by user.\n" : "") +
        (text || (result.cancelled ? "" : "Command finished without output.")) +
        "\n\n" + (result.cancelled ? "cancelled" : result.code === 0 ? "✓ success" : "✗ exit " + result.code) +
        "  ·  " + (result.durationMs / 1000).toFixed(1) + "s");
      setActivity(result.cancelled ? "cancelled" : result.code === 0 ? "ready" : "error");
      if (req.label.startsWith("/project") && result.code === 0) {
        const updated = initialDirectory();
        if (updated !== directory) setDirectory(updated);
      }
    } catch (error) {
      if (pendingFlush) clearTimeout(pendingFlush);
      setStreaming(null);
      append("assistant", "✗ " + String(error));
      setActivity("error");
    } finally {
      if (active.current === controller) active.current = null;
      setLoading(false);
      void refreshBranch(directory);
    }
  }, [append, directory, refreshBranch, remember]);

  const runEngine = useCallback(async (command: string, args: string[], echo = true) => {
    const label = "/" + command + (args.length ? " " + args.join(" ") : "");
    try {
      await execute(label, commandRequest(command, args, directory), echo);
    } catch (error) { append("assistant", String(error)); }
  }, [append, directory, execute]);

  const buildWizard = useCallback(async () => {
    if (active.current || loading) return;
    setLoading(true);
    setActivity("fetching branches");
    try {
      const fetched = await runCommand({
        program: "git", args: ["fetch", "origin", "--prune"],
        cwd: directory, label: "git fetch origin",
      });
      if (fetched.code !== 0) {
        append("assistant", "Could not refresh branches: " + fetched.output);
      }
      const result = await runCommand(gitBranchesRequest(directory));
      const branches = result.output.split(/\r?\n/).map(x => x.trim())
        .filter(x => x.startsWith("origin/") && x !== "origin/HEAD")
        .map(x => x.slice(7)).slice(0, 60);
      if (result.code !== 0 || branches.length === 0) {
        append("assistant", "No branches found. Check git fetch origin and /doctor.");
        return;
      }
      setWizard({ kind: "branch", branches });
      append("assistant", "Select a source branch from the menu above the prompt.");
    } catch (error) { append("assistant", "Could not read branches: " + String(error)); }
    finally { setLoading(false); setActivity("ready"); }
  }, [append, directory, loading]);

  const wizardInput = useCallback(async (value: string) => {
    if (!wizard) return;
    const answer = value.trim();
    append("user", answer);
    remember(answer);
    if (wizard.kind === "branch") {
      const index = Number(answer) - 1;
      const chosen = Number.isInteger(index) && index >= 0 && index < wizard.branches.length
        ? wizard.branches[index] : wizard.branches.find(x => x === answer);
      if (!chosen) {
        append("assistant", "Choose a branch with your mouse or arrow keys, or enter its name.");
        return;
      }
      setWizard({ kind: "mode", branch: chosen });
      append("assistant", "Source: " + chosen + "\nChoose local build, new test release, or update a channel.");
      return;
    }
    if (wizard.kind === "mode") {
      const value = answer === "1" ? "local" : answer === "2" ? "new" : answer === "3" ? "update" : answer;
      if (!["local", "new", "update"].includes(value)) {
        append("assistant", "Select an option from the menu.");
        return;
      }
      if (value === "update") {
        setLoading(true);
        setActivity("fetching releases");
        try {
          const result = await runCommand({
            program: "gh",
            args: ["release", "list", "--repo", "Creative-Cave-uefn/cave-player-releases",
              "--limit", "500", "--json", "tagName,name,isPrerelease,publishedAt"],
            cwd: directory, label: "gh release list",
          });
          if (result.code !== 0) {
            append("assistant", "Could not load release channels: " + result.output +
              "\nCheck gh auth status.");
            return;
          }
          const channels = releaseChannels(JSON.parse(result.output) as ReleaseRecord[]);
          if (!channels.length) {
            append("assistant", "No existing test-release channels were found.");
            return;
          }
          setWizard({ kind: "channel", branch: wizard.branch, channels });
          append("assistant", "Select an existing test channel. Older releases are removed only after the new release is published.");
        } catch (error) {
          append("assistant", "Could not load release channels: " + String(error));
        } finally {
          setLoading(false);
          setActivity("ready");
        }
        return;
      }
      const local = value === "local";
      const args = ["--branch", wizard.branch, "--mode", "new", ...(local ? ["--local"] : [])];
      const summary = (local ? "Local build" : "New test release") + "\nBranch: " + wizard.branch;
      setWizard({ kind: "confirm", command: "build", args, summary });
      append("assistant", summary + "\nConfirm to start.");
      return;
    }
    if (wizard.kind === "channel") {
      const index = Number(answer) - 1;
      const channel = Number.isInteger(index) && index >= 0 && index < wizard.channels.length
        ? wizard.channels[index]?.value : wizard.channels.find(c => c.value === answer)?.value;
      if (!channel) {
        append("assistant", "Select a channel from the menu.");
        return;
      }
      const args = ["--branch", wizard.branch, "--mode", "update", "--channel", channel];
      const summary = "Update test release\nBranch: " + wizard.branch + "\nChannel: " + channel;
      setWizard({ kind: "confirm", command: "build", args, summary });
      append("assistant", summary + "\nConfirm to start.");
      return;
    }
    if (/^(да|yes|y|confirm)$/i.test(answer)) {
      const { command, args } = wizard;
      setWizard(null);
      await runEngine(command, [...args, "--yes"], false);
    } else if (/^(нет|no|n|cancel)$/i.test(answer)) {
      setWizard(null);
      append("assistant", "Action cancelled.");
    } else {
      append("assistant", "Select Confirm or Cancel.");
    }
  }, [append, remember, runEngine, wizard, directory]);

  const menu: ChoiceMenu | undefined = useMemo(() => {
    if (!wizard) return undefined;
    if (wizard.kind === "branch") return {
      id: "branches", title: "SELECT BRANCH", subtitle: "Search · ↑↓ · PgUp/PgDn · Hover · Click",
      choices: wizard.branches.map((name, i) => ({
        value: name, label: name, detail: String(i + 1),
      })),
    };
    if (wizard.kind === "mode") return {
      id: "mode:" + wizard.branch, title: "BUILD TYPE", subtitle: "Source: " + wizard.branch,
      choices: [
        { value: "local", label: "Local build", detail: "Без публикации" },
        { value: "new", label: "New test release", detail: "Создать отдельный канал" },
        { value: "update", label: "Update channel", detail: "Выбрать существующий тестовый релиз" },
      ],
    };
    if (wizard.kind === "channel") return {
      id: "channel:" + wizard.branch, title: "RELEASE CHANNEL",
      subtitle: "Update an existing test release",
      choices: wizard.channels,
    };
    return {
      id: "confirm:" + wizard.summary, title: "CONFIRM ACTION",
      subtitle: wizard.summary.replace(/\n/g, "  ·  "),
      choices: [
        { value: "yes", label: "Confirm", detail: "Run action" },
        { value: "no", label: "Cancel", detail: "Return to DevKit" },
      ],
    };
  }, [wizard]);

  const handleCommand = useCallback(async (name: string, text = "") => {
    const args = splitArgs(text);
    const label = "/" + name + (text.trim() ? " " + text.trim() : "");
    if (name === "quit") { exit(); return; }
    if (name === "clear") {
      setMessages([]); setWizard(null); setActivity("ready"); setStreaming(null); return;
    }
    if (name === "help") { append("assistant", helpText); remember(label); return; }
    if (name === "terminal" || name === "agent") {
      append("user", label); remember(label);
      try { append("assistant", await launchTerminal(directory, name === "agent")); }
      catch (error) { append("assistant", "✗ " + String(error)); }
      return;
    }
    if (name === "build") {
      append("user", label); remember(label);
      if (args.length === 0) { await buildWizard(); return; }
      if (!args.includes("--yes")) {
        setWizard({ kind: "confirm", command: "build", args,
          summary: "Build with options: " + args.join(" ") });
        append("assistant", "Build: " + args.join(" ") +
          "\nType yes to confirm or no to cancel.");
        return;
      }
    }
    if (name === "clean" && !args.includes("--dry-run") && !args.includes("--yes")) {
      append("user", label); remember(label);
      setWizard({ kind: "confirm", command: "clean", args,
        summary: "Clean test releases" });
      append("assistant", "Remove outdated test releases? Select Confirm or Cancel.");
      return;
    }
    if (engineCommands.has(name)) {
      await runEngine(name, args, name !== "build");
      return;
    }
    append("assistant", "Unknown command: /" + name + ". Use /help.");
  }, [append, buildWizard, directory, exit, remember, runEngine]);

  const handleSubmit = useCallback(async (text: string) => {
    const trimmed = text.trim();
    if (!trimmed) return;
    if (wizard && /^\/(?:cancel|назад)$/i.test(trimmed)) {
      setWizard(null); append("assistant", "Wizard cancelled."); return;
    }
    if (wizard && !/^\/(?:help|quit|clear|build|terminal)$/i.test(trimmed)) {
      await wizardInput(trimmed); return;
    }
    if (trimmed.startsWith("/")) {
      const tokens = splitArgs(trimmed.slice(1));
      await handleCommand((tokens.shift() || "").toLowerCase(), tokens.join(" "));
      return;
    }
    if (trimmed === "exit" || trimmed === "quit") { exit(); return; }
    try {
      const next = changeDirectory(directory, trimmed);
      if (next) {
        append("user", trimmed); remember(trimmed); setDirectory(next);
        append("assistant", "Working directory: " + next);
        return;
      }
    } catch (error) { append("assistant", "✗ " + String(error)); return; }
    await execute(trimmed, shellRequest(trimmed, directory));
  }, [append, directory, execute, exit, handleCommand, remember, wizard, wizardInput]);

  const cancel = useCallback(() => {
    if (active.current) active.current.abort();
    else if (wizard) { setWizard(null); setInputValue(""); append("assistant", "Wizard cancelled."); }
  }, [append, wizard]);

  const statusSegments: StatusLineSegment[] = useMemo(() => [
    { content: "LOCAL", color: "#8C8991" },
    { content: compact ? "git:" + (branch.length > 26 ? "…" + branch.slice(-25) : branch) : "PowerShell", color: "#A6A0A9" },
    { content: compact ? "PowerShell" : "/help", color: "#8C8991" },
    { content: loading ? "● " + activity : activity, color: loading ? "#D8B17B" : "#8A868E" },
  ], [activity, loading, compact, branch]);

  const searchMatches = useCallback((query: string) => {
    if (!query.trim()) return [];
    const found: { index: number; offset: number; length: number }[] = [];
    messages.forEach((message, index) => {
      const content = typeof message.content === "string" ? message.content : JSON.stringify(message.content);
      const offset = content.toLowerCase().indexOf(query.toLowerCase());
      if (offset >= 0) found.push({ index, offset, length: query.length });
    });
    return found;
  }, [messages]);

  const matched = menu ? [] : matchCommands(inputValue, catalog);
  const headerRows = 3;
  const maxMenuRows = Math.max(2, Math.min(7, terminal.rows - 20));
  const menuCount = menu && !loading && !searchOpen ? Math.min(maxMenuRows, menu.choices.length) + (menu.subtitle ? 5 : 4) : 0;
  const paletteRows = menuCount || (matched.length > 0 && !loading && !searchOpen ? matched.length + 3 : 0);
  const promptRows = paletteRows + (paletteRows ? 4 : 5);
  const historyHeight = Math.max(2, terminal.rows - headerRows - promptRows - (searchOpen ? 2 : 0) - 3);
  const displayedMessages: Message[] = streaming && loading
    ? [...messages, { id: "__cavey_stream", role: "assistant", content: streaming }]
    : messages;

  return (
    <AlternateScreen mouseTracking>
      <Box flexDirection="column" width="100%" flexGrow={1}>
        <Header directory={directory} branch={branch} activity={activity} loading={loading} compact={compact} />
        <Box flexDirection="column" flexGrow={1} paddingX={2} paddingTop={compact ? 0 : 1}>
          {messages.length === 0 && !streaming && (
            <Box flexDirection="column" marginLeft={1}>
              <Text dimColor>Start with <Text color="#E69C7D">/build</Text> or enter a PowerShell command.</Text>

            </Box>
          )}
          <MessageList
            ref={historyRef}
            viewportHeight={historyHeight}
            messages={displayedMessages}
            renderMessage={formatMessage}
          />
          {loading && !streaming && (
            <Box marginLeft={2}><Spinner label={activity} /></Box>
          )}
        </Box>
        {searchOpen && (
          <SearchOverlay
            isOpen={searchOpen}
            onClose={() => setSearchOpen(false)}
            onSearch={searchMatches}
            onNavigate={match => historyRef.current?.scrollTo(match.index)}
          />
        )}
        <CommandPrompt
          value={inputValue}
          onChange={setInputValue}
          onSubmit={handleSubmit}
          history={history}
          commands={catalog}
          menu={menu}
          maxMenuRows={maxMenuRows}
          onMenuPick={wizardInput}
          onMenuCancel={() => { setWizard(null); setInputValue(""); append("assistant", "Wizard cancelled."); }}
          disabled={loading}
          searchOpen={searchOpen}
          onCancel={cancel}
          onTerminal={() => { void handleCommand("terminal"); }}
          onSearch={() => setSearchOpen(true)}
          onClear={() => { void handleCommand("clear"); setInputValue(""); }}
          onScroll={delta => historyRef.current?.scrollBy(delta)}
        />
        <Box paddingX={2} paddingBottom={0}>
          <StatusLine segments={statusSegments} paddingX={1} />
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
