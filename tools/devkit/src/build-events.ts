export const stageOrder = ["source", "prepare", "checks", "compile", "package", "verify", "publish"] as const;
export type StageName = (typeof stageOrder)[number];
export type StageState = "waiting" | "running" | "done" | "failed" | "skipped";
export type StageRecord = { name: StageName; state: StageState; label: string; updatedAt: number; startedAt?: number; durationMs?: number };
const stageSet = new Set<string>(stageOrder);
const states = new Set<string>(["waiting", "running", "done", "failed", "skipped"]);

export type BuildResult = {
  id: string; status: string; folder: string; version: string; channel: string; tag: string;
  local: boolean; source: string; url: string; artifacts: { name: string; size: number }[];
  platform: "windows" | "android";
};

function parseResult(json: string): BuildResult | null {
  try {
    const v = JSON.parse(json) as Partial<BuildResult>;
    if (typeof v.id !== "string" || typeof v.status !== "string" || typeof v.folder !== "string") return null;
    return {
      id: v.id, status: v.status, folder: v.folder, version: String(v.version ?? ""), channel: String(v.channel ?? ""),
      tag: String(v.tag ?? ""), local: Boolean(v.local), source: String(v.source ?? ""), url: String(v.url ?? ""),
      artifacts: Array.isArray(v.artifacts)
        ? v.artifacts.filter(a => a && typeof a.name === "string").map(a => ({ name: a.name, size: Number(a.size) || 0 }))
        : [],
      platform: v.platform === "android" ? "android" : "windows",
    };
  } catch { return null; }
}

export function parseWorkflowLine(line: string):
  | { kind: "stage"; stage: StageName; state: StageState; label: string }
  | { kind: "restart" }
  | { kind: "result"; result: BuildResult }
  | null {
  const clean = line.trim();
  if (clean === "@@CAVEY_RESTART|updated") return { kind: "restart" };
  if (clean.startsWith("@@CAVEY_RESULT|")) {
    const result = parseResult(clean.slice("@@CAVEY_RESULT|".length));
    return result ? { kind: "result", result } : null;
  }
  if (!clean.startsWith("@@CAVEY_STAGE|")) return null;
  const parts = clean.split("|");
  if (parts.length < 4 || !stageSet.has(parts[1]!) || !states.has(parts[2]!)) return null;
  return {
    kind: "stage",
    stage: parts[1] as StageName,
    state: parts[2] as StageState,
    label: parts.slice(3).join("|").slice(0, 120),
  };
}

export function stripWorkflowMarkers(text: string): string {
  return text.split(/\r?\n/).filter(l => !parseWorkflowLine(l)).join("\n");
}

export function createWorkflowStream(onEvent: (event: NonNullable<ReturnType<typeof parseWorkflowLine>>) => void) {
  let carry = "";
  return {
    push(chunk: string): string {
      carry += chunk;
      const lines = carry.split("\n");
      carry = lines.pop() ?? "";
      let output = "";
      for (const raw of lines) {
        const line = raw.replace(/\r$/, "");
        const event = parseWorkflowLine(line);
        if (event) onEvent(event);
        else output += raw + "\n";
      }
      return output;
    },
    finish(): string {
      const tail = carry;
      carry = "";
      const event = parseWorkflowLine(tail);
      if (event) { onEvent(event); return ""; }
      return tail;
    },
  };
}
