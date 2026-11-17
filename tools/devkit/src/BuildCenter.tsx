import React from "react";
import { Box, Text } from "@claude-code-kit/ink-renderer";
import { stageOrder, type StageRecord, type StageName } from "./build-events.js";

const titles: Record<StageName, string> = {
  source: "Source",
  prepare: "Prepare",
  checks: "Checks",
  compile: "Compile",
  package: "Package",
  publish: "Publish",
};

export function BuildCenter({ stages, running, compact }: {
  stages: StageRecord[];
  running: boolean;
  compact: boolean;
}) {
  if (!stages.length) return null;
  const current = stages.find(stage => stage.state === "running");
  const done = stages.filter(stage => stage.state === "done" || stage.state === "skipped").length;
  const error = stages.find(stage => stage.state === "failed");
  const byName = new Map<StageName, StageRecord>(stages.map(stage => [stage.name, stage]));
  const status = error ? "FAILED" : running ? "BUILDING" : "COMPLETE";
  return (
    <Box flexDirection="column" paddingX={3} paddingBottom={1} flexShrink={0}>
      <Box justifyContent="space-between">
        <Text color="#C5B5B9" bold>BUILD CENTER <Text dimColor>{status}</Text></Text>
        <Text dimColor>{done}/{stageOrder.length} stages · /logs details</Text>
      </Box>
      <Box flexDirection="row" gap={compact ? 1 : 2}>
        {stageOrder.map(name => {
          const stage = byName.get(name);
          const state = stage?.state ?? "waiting";
          const color = state === "failed" ? "#DE7775"
            : state === "done" ? "#99C6A8"
            : state === "running" ? "#E7A27F"
            : "#77727C";
          const indicator = state === "done" ? "✓" : state === "failed" ? "×"
            : state === "skipped" ? "–" : state === "running" ? "◆" : "·";
          return (
            <Box key={name} gap={1} flexShrink={0}>
              <Text color={color}>{indicator}</Text>
              <Text color={color}>{compact ? titles[name].slice(0, 3) : titles[name] +
                (stage?.durationMs !== undefined ? " " + (stage.durationMs / 1000).toFixed(1) + "s" : "")}</Text>
            </Box>
          );
        })}
      </Box>
      {(current || error) && !compact && (
        <Text color={error ? "#DE7775" : "#9A959D"} wrap="truncate-end">
          {error?.label ?? current?.label}
        </Text>
      )}
    </Box>
  );
}
