import { spawn } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { StringDecoder } from "node:string_decoder";
import { fileURLToPath } from "node:url";

export const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
export const enginePath = join(repositoryRoot, "tools", "cavey-devkit-engine.ps1");
const dataHome = join(process.env.LOCALAPPDATA || join(homedir(), ".cavey-devkit"), "CaveyDevKit");

export const engineCommands = new Set([
  "status", "doctor", "branches", "releases", "build", "clean",
  "history", "logs", "run", "project",
]);

export function initialDirectory(): string {
  try {
    const cfg = JSON.parse(readFileSync(join(dataHome, "config.json"), "utf8"));
    if (typeof cfg.projectRoot === "string" && existsSync(cfg.projectRoot) &&
        statSync(cfg.projectRoot).isDirectory()) {
      return resolve(cfg.projectRoot);
    }
  } catch { /* no saved project */ }
  return repositoryRoot;
}

export function splitArgs(input: string): string[] {
  const parts: string[] = [];
  const pattern = /"((?:[^"]|"")*)"|'((?:[^']|'')*)'|([^\s"']+)/g;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(input))) {
    parts.push(match[1] !== undefined ? match[1].replace(/""/g, '"')
      : match[2] !== undefined ? match[2].replace(/''/g, "'") : match[3]);
  }
  return parts;
}

export function changeDirectory(current: string, line: string): string | null {
  const match = /^(?:cd|chdir|set-location)(?:\s+(.*))?$/i.exec(line.trim());
  if (!match) return null;
  let target = (match[1] || repositoryRoot).trim().replace(/^["']|["']$/g, "");
  if (target === "~") target = homedir();
  if (target.startsWith("~/") || target.startsWith("~\\")) {
    target = join(homedir(), target.slice(2));
  }
  const candidate = isAbsolute(target) ? resolve(target) : resolve(current, target);
  if (!existsSync(candidate) || !statSync(candidate).isDirectory()) {
    throw new Error("Папка не найдена: " + candidate);
  }
  return candidate;
}

export type RunResult = { output: string; code: number; cancelled: boolean; durationMs: number };
export type RunRequest = { program: string; args: string[]; cwd: string; label: string };
const MAX_LOG = 70000;
const CSI = /\x1b\[[0-?]*[ -/]*[@-~]/g;
const OSC = /\x1b\][^\x07]*(?:\x07|\x1b\\)/g;

function cleanOutput(value: string): string {
  return value.replace(OSC, "").replace(CSI, "")
    .replace(/\r(?!\n)/g, "\n").replace(/\u0000/g, "");
}

export function commandRequest(command: string, args: string[], cwd: string): RunRequest {
  if (!engineCommands.has(command)) throw new Error("Неизвестная команда DevKit: " + command);
  if (!existsSync(enginePath)) throw new Error("Не найден сборочный движок: " + enginePath);
  return {
    program: "powershell.exe",
    args: ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
      "-File", enginePath, "/" + command, ...args],
    cwd, label: "/" + command + (args.length ? " " + args.join(" ") : ""),
  };
}

export function shellRequest(line: string, cwd: string): RunRequest {
  return {
    program: "powershell.exe",
    args: ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
      "-Command", line],
    cwd, label: line,
  };
}

export function gitBranchRequest(cwd: string): RunRequest {
  return { program: "git", args: ["branch", "--show-current"], cwd, label: "git branch" };
}

export function gitBranchesRequest(cwd: string): RunRequest {
  return {
    program: "git",
    args: ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)",
      "refs/remotes/origin"],
    cwd, label: "git branches",
  };
}

export function runCommand(
  request: RunRequest,
  signal?: AbortSignal,
  onChunk?: (chunk: string) => void,
): Promise<RunResult> {
  return new Promise((resolvePromise, reject) => {
    if (signal?.aborted) { reject(new Error("Отменено")); return; }
    const start = Date.now();
    let cancelled = false;
    let output = "";
    let finished = false;
    let processError: Error | null = null;
    const child = spawn(request.program, request.args, {
      cwd: request.cwd,
      env: { ...process.env, PYTHONIOENCODING: "utf-8" },
      windowsHide: true,
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const outDecoder = new StringDecoder("utf8");
    const errDecoder = new StringDecoder("utf8");

    const append = (fragment: string) => {
      const cleaned = cleanOutput(fragment);
      if (!cleaned) return;
      output = (output + cleaned).slice(-MAX_LOG);
      onChunk?.(cleaned);
    };
    child.stdout.on("data", (buf: Buffer) => append(outDecoder.write(buf)));
    child.stderr.on("data", (buf: Buffer) => append(errDecoder.write(buf)));
    child.on("error", err => { processError = err; });
    const abort = () => {
      if (finished) return;
      cancelled = true;
      if (process.platform === "win32" && child.pid) {
        const killer = spawn("taskkill.exe", ["/PID", String(child.pid), "/T", "/F"],
          { stdio: "ignore", windowsHide: true });
        killer.on("error", () => { try { child.kill(); } catch { /* already gone */ } });
      } else {
        try { child.kill("SIGTERM"); } catch { /* already gone */ }
      }
    };
    signal?.addEventListener("abort", abort, { once: true });
    child.on("close", code => {
      finished = true;
      signal?.removeEventListener("abort", abort);
      append(outDecoder.end());
      append(errDecoder.end());
      if (processError && !cancelled) { reject(processError); return; }
      resolvePromise({ output: output.trim(), code: code ?? (cancelled ? 130 : 1),
        cancelled, durationMs: Date.now() - start });
    });
  });
}

export async function launchTerminal(cwd: string, agent = false): Promise<string> {
  if (process.platform !== "win32") throw new Error("Встроенный ярлык предназначен для Windows.");
  const executable = "powershell.exe";
  const command = agent
    ? [executable, "-NoLogo", "-NoProfile", "-NoExit", "-Command", "claude"]
    : [executable, "-NoLogo", "-NoProfile"];
  const wtArgs = ["-w", "0", "new-tab", "-d", cwd,
    "--title", agent ? "Claude Code" : "Cavey Terminal", ...command];
  const spawnDetached = (program: string, args: string[], workingDirectory: string) =>
    new Promise<void>((ok, fail) => {
      const child = spawn(program, args, {
        cwd: workingDirectory, detached: true, windowsHide: false, stdio: "ignore",
      });
      child.once("error", fail);
      child.once("spawn", () => { child.unref(); ok(); });
    });
  try {
    await spawnDetached("wt.exe", wtArgs, cwd);
    return agent ? "Claude Code открыт во вкладке Windows Terminal."
      : "Терминал открыт во вкладке Windows Terminal.";
  } catch {
    // Windows Terminal may be unavailable on older Windows installations.
    await spawnDetached(executable,
      agent ? ["-NoLogo", "-NoProfile", "-NoExit", "-Command", "claude"]
        : ["-NoLogo", "-NoProfile", "-NoExit"], cwd);
    return agent ? "Claude Code открыт в отдельном окне PowerShell."
      : "Интерактивный PowerShell открыт в отдельном окне.";
  }
}

export function prettyDirectory(directory: string): string {
  if (directory.length < 54) return directory;
  return "…" + directory.slice(-52);
}

export function projectLabel(directory: string): string {
  return basename(directory) || directory;
}
