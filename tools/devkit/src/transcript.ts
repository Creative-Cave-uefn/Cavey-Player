import type { BuildResult, StageRecord } from "./build-events.js";
import type { Tone } from "./theme.js";

// Transcript entries, rendered Claude Code style:
//   > /build                         (input)
//   ⏺ Branch  feat/x                 (step)
//   ⏺ /status                        (run)
//     ⎿  output … +N lines (ctrl+o to expand)
export type RunStatus = "running" | "success" | "error" | "cancelled";
export type Entry =
  | { id: string; kind: "welcome" }
  | { id: string; kind: "input"; text: string }
  | { id: string; kind: "step"; title: string; detail?: string; tone?: Tone }
  | { id: string; kind: "note"; text: string; tone?: Tone }
  | {
      id: string; kind: "run"; title: string; output: string; status: RunStatus;
      exitCode?: number; durationMs?: number; stages?: StageRecord[]; result?: BuildResult;
      /** Expanded by clicking its "… +N lines" line; Ctrl+O expands every entry. */
      expanded?: boolean;
    };

export type LineKind = "error" | "warning" | "success" | "normal";

const ERROR = /(^|\W)(error|failed|failure|fatal|exception|ошибка|не удалось)(\W|$)|^✗|DevKit engine error/i;
const WARNING = /(^|\W)(warning|warn|deprecated)(\W|$)|^!\s/i;
const SUCCESS = /^\s*✓/;

export function classifyLine(line: string): LineKind {
  if (ERROR.test(line)) return "error";
  if (WARNING.test(line)) return "warning";
  if (SUCCESS.test(line)) return "success";
  return "normal";
}

export type OutputView = {
  /** Lines to draw; null marks the "… +N lines" gap. */
  lines: ({ text: string; kind: LineKind } | null)[];
  hidden: number;
  total: number;
};

/**
 * Collapsed view keeps the tail, and always keeps the first error lines so a
 * failure is never hidden behind "+N lines".
 */
export function summarizeOutput(output: string, expanded: boolean, tail = 6, maxErrors = 4): OutputView {
  const all = output.replace(/\s+$/, "").split(/\r?\n/).filter((l, i, a) => l.trim() || (i > 0 && a[i - 1]!.trim()));
  const tagged = all.map(text => ({ text, kind: classifyLine(text) }));
  if (expanded || tagged.length <= tail + 1) return { lines: tagged, hidden: 0, total: tagged.length };
  const keep = new Set<number>();
  for (let i = Math.max(0, tagged.length - tail); i < tagged.length; i++) keep.add(i);
  let errors = 0;
  for (let i = 0; i < tagged.length && errors < maxErrors; i++) {
    if (tagged[i]!.kind === "error" && !keep.has(i)) { keep.add(i); errors++; }
  }
  const indexes = [...keep].sort((a, b) => a - b);
  const lines: OutputView["lines"] = [];
  let previous = -1;
  for (const i of indexes) {
    if (i !== previous + 1) lines.push(null);
    lines.push(tagged[i]!);
    previous = i;
  }
  return { lines, hidden: tagged.length - indexes.length, total: tagged.length };
}

export function formatDuration(ms: number): string {
  const seconds = Math.max(0, Math.round(ms / 1000));
  if (seconds < 60) return seconds + "s";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return minutes + "m " + String(seconds % 60).padStart(2, "0") + "s";
  return Math.floor(minutes / 60) + "h " + String(minutes % 60).padStart(2, "0") + "m";
}

export function relativeTime(iso: string | null | undefined, now = Date.now()): string {
  if (!iso) return "";
  const at = Date.parse(iso);
  if (Number.isNaN(at)) return iso;
  const minutes = Math.round((now - at) / 60000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return minutes + "m ago";
  const hours = Math.round(minutes / 60);
  if (hours < 48) return hours + "h ago";
  return Math.round(hours / 24) + "d ago";
}

/** Average duration of recent successful builds, used for the ETA. */
export function estimateBuildMs(history: { status?: string; seconds?: number }[], sample = 5): number | null {
  const done = history.filter(h => (h.status === "built" || h.status === "published") &&
    typeof h.seconds === "number" && h.seconds > 30).slice(-sample);
  if (!done.length) return null;
  return Math.round(done.reduce((sum, h) => sum + h.seconds!, 0) / done.length * 1000);
}

/** Entry without an id (distributes over the union so each kind keeps its fields). */
export type NewEntry = Entry extends infer E ? E extends Entry ? Omit<E, "id"> & { id?: string } : never : never;

export function formatSize(bytes: number): string {
  if (bytes >= 1024 * 1024) return (bytes / 1024 / 1024).toFixed(1) + " MB";
  if (bytes >= 1024) return Math.round(bytes / 1024) + " KB";
  return bytes + " B";
}
