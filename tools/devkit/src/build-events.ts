export const stageOrder = ["source", "prepare", "checks", "compile", "package", "publish"] as const;
export type StageName = (typeof stageOrder)[number];
export type StageState = "waiting" | "running" | "done" | "failed" | "skipped";
export type StageRecord = { name: StageName; state: StageState; label: string; updatedAt: number; startedAt?: number; durationMs?: number };
const stageSet = new Set<string>(stageOrder);
const states = new Set<string>(["waiting", "running", "done", "failed", "skipped"]);

export function parseWorkflowLine(line: string):
  | { kind: "stage"; stage: StageName; state: StageState; label: string }
  | { kind: "restart" }
  | null {
  const clean = line.trim();
  if (clean === "@@CAVEY_RESTART|updated") return { kind: "restart" };
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
