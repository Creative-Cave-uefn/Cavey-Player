import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AlternateScreen, Box, Text, render, useApp } from "@claude-code-kit/ink-renderer";
import { MessageList, SearchOverlay, StatusLine, Spinner, useTerminalSize, type Message, type StatusLineSegment, type VirtualListHandle } from "@claude-code-kit/ui";
import { CommandPrompt, matchCommands } from "./CommandPrompt.js";
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
  "/build --branch latest --local    Локальная сборка (затем подтвердить)",
  "/build --branch <name>            Тестовый релиз (затем подтвердить)",
  "/branches   /status   /releases   /history   /logs",
  "/clean --dry-run                  Посмотреть план очистки",
  "/run        /doctor   /project [path]   /terminal",
  "/agent      /clear    /quit",
  "",
  "Команды без / исполняются в PowerShell. cd работает между командами.",
  "Команды, запрашивающие ввод, выполняйте через /terminal.",
  "Tab: дополнить  ·  ↑↓: история  ·  PgUp/PgDn: вывод",
  "Ctrl+F: поиск  ·  Ctrl+C: отмена  ·  Ctrl+J: терминал",
].join("\n");

type Wizard =
  | { kind: "branch"; branches: string[] }
  | { kind: "mode"; branch: string }
  | { kind: "confirm"; command: "build" | "clean"; args: string[]; summary: string };

function formatMessage(m: Message): React.ReactNode {
  const body = typeof m.content === "string" ? m.content :
    m.content.map(part => "text" in part ? part.text : JSON.stringify(part)).join("\n");
  return (
    <Box flexDirection="column" marginBottom={1} paddingX={1}>
      <Text color={m.role === "user" ? "#B8BED0" : ACCENT} bold>
        {m.role === "user" ? "❯" : "◆ CAVEY"}
      </Text>
      <Box marginLeft={2}>
        <Text color={m.role === "user" ? "white" : undefined} wrap="wrap">{body}</Text>
      </Box>
    </Box>
  );
}

function Header({ directory, branch, activity, loading, compact }: {
  directory: string; branch: string; activity: string; loading: boolean; compact: boolean;
}) {
  const color = loading ? "#E6BE69" : activity === "error" ? "#E98579" : "#8AC7A4";
  return (
    <Box flexDirection="column" paddingX={2} paddingTop={compact ? 0 : 1}>
      <Box borderStyle="round" borderColor="#525058" paddingX={2} flexDirection="column">
        <Box justifyContent="space-between">
          <Text bold color="#E89A78">◆ CAVEY <Text color="#E4E1E6">DEVKIT</Text> <Text dimColor>v1.1</Text></Text>
          <Text color={color}>{loading ? "● " + activity : "● READY"}</Text>
        </Box>
        {!compact && (
          <Text dimColor>  DEVELOPMENT WORKSPACE     ·     LOCAL BUILDS     ·     GITHUB</Text>
        )}
        <Box gap={1}>
          <Text color="#9A95A1">⌁</Text>
          <Text color="#D8D4DA">{prettyDirectory(directory)}</Text>
        </Box>
        {!compact && (
          <Text dimColor>  /build  сборка    /branches  ветки    /terminal  PowerShell    /help  команды</Text>
        )}
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
    if (active.current) { append("system", "Уже выполняется команда. Ctrl+C для отмены."); return; }
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
      append("assistant", (result.cancelled ? "Остановлено пользователем.\n" : "") +
        (text || (result.cancelled ? "" : "Команда выполнена без вывода.")) +
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
    if (active.current) return;
    setLoading(true);
    setActivity("fetching branches");
    try {
      const result = await runCommand(gitBranchesRequest(directory));
      const branches = result.output.split(/\r?\n/).map(x => x.trim())
        .filter(x => x.startsWith("origin/") && x !== "origin/HEAD")
        .map(x => x.slice(7)).slice(0, 15);
      if (result.code !== 0 || branches.length === 0) {
        append("assistant", "Ветки не найдены. Проверьте git fetch origin и /doctor.");
        return;
      }
      setWizard({ kind: "branch", branches });
      append("assistant",
        "Выберите ветку для сборки (цифра или имя):\n\n" +
        branches.map((x, i) => "  " + String(i + 1).padStart(2) + ". " + x).join("\n") +
        "\n\n/quit — выход из DevKit, /build для перезапуска мастера.");
    } catch (error) { append("assistant", "Ошибка чтения веток: " + String(error)); }
    finally { setLoading(false); setActivity("ready"); }
  }, [append, directory]);

  const wizardInput = useCallback(async (value: string) => {
    if (!wizard) return;
    append("user", value);
    remember(value);
    const answer = value.trim();
    if (wizard.kind === "branch") {
      const index = Number(answer) - 1;
      const chosen = Number.isInteger(index) && index >= 0 && index < wizard.branches.length
        ? wizard.branches[index] : wizard.branches.find(x => x === answer);
      if (!chosen) { append("assistant", "Укажите номер из списка или точное имя ветки."); return; }
      setWizard({ kind: "mode", branch: chosen });
      append("assistant", "Ветка: " + chosen + "\n\n1. Собрать локально на ПК\n2. Опубликовать тестовый релиз\n\nВыберите 1 или 2.");
      return;
    }
    if (wizard.kind === "mode") {
      if (answer !== "1" && answer !== "2") { append("assistant", "Введите 1 или 2."); return; }
      const local = answer === "1";
      const args = ["--branch", wizard.branch, "--mode", "new", ...(local ? ["--local"] : [])];
      setWizard({ kind: "confirm", command: "build", args, summary: local ? "локальная сборка" : "публикация тестового релиза" });
      append("assistant", "Подтвердите: " + (local ? "локальная сборка" : "публикация тестового релиза") +
        "\nВетка: " + wizard.branch + "\nОтветьте ДА для запуска или нет для отмены.");
      return;
    }
    if (/^(да|yes|y)$/i.test(answer)) {
      const { command, args } = wizard;
      setWizard(null);
      await runEngine(command, [...args, "--yes"], false);
    } else {
      setWizard(null);
      append("assistant", "Действие отменено.");
    }
  }, [append, remember, runEngine, wizard]);

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
          summary: "Сборка с параметрами: " + args.join(" ") });
        append("assistant", "Сборка: " + args.join(" ") +
          "\nДля подтверждения введите ДА, для отмены — нет.");
        return;
      }
    }
    if (name === "clean" && !args.includes("--dry-run") && !args.includes("--yes")) {
      append("user", label); remember(label);
      setWizard({ kind: "confirm", command: "clean", args,
        summary: "Очистка тестовых релизов" });
      append("assistant", "Очистить старые тестовые релизы? Ответьте ДА или нет.");
      return;
    }
    if (engineCommands.has(name)) {
      await runEngine(name, args, name !== "build");
      return;
    }
    append("assistant", "Неизвестная команда: /" + name + ". Введите /help.");
  }, [append, buildWizard, directory, exit, remember, runEngine]);

  const handleSubmit = useCallback(async (text: string) => {
    const trimmed = text.trim();
    if (!trimmed) return;
    if (wizard) { await wizardInput(trimmed); return; }
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
        append("assistant", "Рабочая папка: " + next);
        return;
      }
    } catch (error) { append("assistant", "✗ " + String(error)); return; }
    await execute(trimmed, shellRequest(trimmed, directory));
  }, [append, directory, execute, exit, handleCommand, remember, wizard, wizardInput]);

  const cancel = useCallback(() => {
    if (active.current) active.current.abort();
    else if (wizard) { setWizard(null); append("assistant", "Мастер отменён."); }
  }, [append, wizard]);

  const statusSegments: StatusLineSegment[] = useMemo(() => [
    { content: "◆ CAVEY DEVKIT", color: ACCENT },
    { content: "git:" + (branch.length > 28 ? "…" + branch.slice(-27) : branch), color: "#8EC9A3" },
    { content: projectLabel(directory), color: "#DCD9DE" },
    { content: loading ? "● " + activity : activity, color: loading ? "yellow" : activity === "error" ? "red" : "gray" },
    { content: "PowerShell", color: "gray" },
  ], [activity, branch, directory, loading]);

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

  const matched = matchCommands(inputValue, catalog);
  const compact = terminal.rows < 29 || terminal.columns < 70;
  const headerRows = compact ? 4 : 7;
  const paletteRows = matched.length > 0 && !loading && !searchOpen ? matched.length + 3 : 0;
  const promptRows = paletteRows + 4;
  const historyHeight = Math.max(3, terminal.rows - headerRows - promptRows - (searchOpen ? 2 : 0) - 2);
  const displayedMessages: Message[] = streaming && loading
    ? [...messages, { id: "__cavey_stream", role: "assistant", content: streaming }]
    : messages;

  return (
    <AlternateScreen mouseTracking>
      <Box flexDirection="column" width="100%" flexGrow={1}>
        <Header directory={directory} branch={branch} activity={activity} loading={loading} compact={compact} />
        <Box flexDirection="column" flexGrow={1} paddingX={2} paddingTop={compact ? 0 : 1}>
          {messages.length === 0 && !streaming && (
            <Box flexDirection="column" marginLeft={2}>
              <Text dimColor>Начните с <Text color="#E69C7D">/build</Text> или введите команду PowerShell.</Text>
              {!compact && <Text dimColor>Наведение мыши выделяет команду · клик запускает выбранную команду</Text>}
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
