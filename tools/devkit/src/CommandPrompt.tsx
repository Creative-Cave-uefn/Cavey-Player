import React, { useCallback, useEffect, useRef, useState } from "react";
import { Box, Text, useInput } from "@claude-code-kit/ink-renderer";

export type CommandOption = { name: string; description: string };

export function matchCommands(value: string, options: CommandOption[]): CommandOption[] {
  if (!value.startsWith("/") || /\s/.test(value)) return [];
  const prefix = value.slice(1).toLocaleLowerCase();
  return options.filter(option => option.name.toLocaleLowerCase().startsWith(prefix)).slice(0, 7);
}

export function CommandPrompt({
  value, onChange, onSubmit, history, commands, disabled = false, searchOpen = false,
  onCancel, onTerminal, onSearch, onClear, onScroll,
}: {
  value: string;
  onChange: (value: string) => void;
  onSubmit: (value: string) => void | Promise<void>;
  history: string[];
  commands: CommandOption[];
  disabled?: boolean;
  searchOpen?: boolean;
  onCancel: () => void;
  onTerminal: () => void;
  onSearch: () => void;
  onClear: () => void;
  onScroll: (delta: number) => void;
}) {
  const [cursor, setCursor] = useState(0);
  const cursorRef = useRef(0);
  const updateCursor = useCallback((value: number | ((current: number) => number)) => {
    const next = typeof value === "function" ? value(cursorRef.current) : value;
    cursorRef.current = next;
    setCursor(next);
  }, []);
  const [selected, setSelected] = useState(0);
  const [hovered, setHovered] = useState<number | null>(null);
  const [historyIndex, setHistoryIndex] = useState(-1);
  const [draft, setDraft] = useState("");
  const [dismissed, setDismissed] = useState(false);
  const valueRef = useRef(value);
  valueRef.current = value;

  useEffect(() => { updateCursor(c => Math.min(c, value.length)); }, [value.length]);
  const suggestions = dismissed || searchOpen || disabled ? [] : matchCommands(value, commands);
  const focused = Math.min(hovered ?? selected, Math.max(0, suggestions.length - 1));
  const showPalette = suggestions.length > 0;

  const edit = useCallback((next: string, position: number) => {
    valueRef.current = next;
    onChange(next);
    updateCursor(position);
    setSelected(0);
    setHovered(null);
    setHistoryIndex(-1);
    setDismissed(false);
  }, [onChange]);

  const choose = useCallback((name: string, execute: boolean) => {
    const command = "/" + name;
    setDismissed(true);
    setHovered(null);
    setSelected(0);
    if (execute) {
      valueRef.current = "";
      onChange("");
      updateCursor(0);
      void onSubmit(command);
    } else {
      valueRef.current = command + " ";
      onChange(command + " ");
      updateCursor(command.length + 1);
    }
  }, [onChange, onSubmit]);

  useInput((input, key, event) => {
    if (key.ctrl && input === "c") {
      event.stopImmediatePropagation();
      onCancel();
      return;
    }
    if (searchOpen) return;
    if (key.ctrl && input === "j") {
      event.stopImmediatePropagation();
      onTerminal();
      return;
    }
    if (key.ctrl && input === "f") {
      event.stopImmediatePropagation();
      onSearch();
      return;
    }
    if (key.ctrl && input === "l") {
      event.stopImmediatePropagation();
      onClear();
      return;
    }
    if (key.pageUp || key.pageDown) {
      event.stopImmediatePropagation();
      onScroll(key.pageUp ? -12 : 12);
      return;
    }
    if (disabled) return;
    const current = valueRef.current;
    const activeCursor = Math.min(cursorRef.current, current.length);
    if (key.escape) {
      if (showPalette) setDismissed(true);
      else edit("", 0);
      return;
    }
    if (key.return) {
      if (showPalette && (current === "/" || (current.length > 1 && !commands.some(c => "/" + c.name === current)))) {
        const option = suggestions[focused];
        if (option) { choose(option.name, true); return; }
      }
      if (current.trim()) {
        valueRef.current = "";
        onChange("");
        updateCursor(0);
        setSelected(0);
        setHovered(null);
        setDismissed(false);
        setHistoryIndex(-1);
        void onSubmit(current);
      }
      return;
    }
    if (key.tab) {
      const option = suggestions[focused];
      if (option) { choose(option.name, false); }
      return;
    }
    if (key.upArrow || key.downArrow) {
      if (showPalette) {
        setHovered(null);
        setSelected(i => (i + suggestions.length + (key.upArrow ? -1 : 1)) % suggestions.length);
      } else if (history.length > 0) {
        if (key.upArrow) {
          if (historyIndex === -1) setDraft(current);
          const index = Math.min(historyIndex + 1, history.length - 1);
          setHistoryIndex(index);
          onChange(history[index]);
          valueRef.current = history[index];
          updateCursor(history[index].length);
        } else if (historyIndex >= 0) {
          const index = historyIndex - 1;
          const next = index < 0 ? draft : history[index];
          setHistoryIndex(index);
          onChange(next);
          valueRef.current = next;
          updateCursor(next.length);
        }
      }
      return;
    }
    if (key.leftArrow) { updateCursor(c => Math.max(0, c - 1)); return; }
    if (key.rightArrow) { updateCursor(c => Math.min(current.length, c + 1)); return; }
    if (key.home || (key.ctrl && input === "a")) { updateCursor(0); return; }
    if (key.end || (key.ctrl && input === "e")) { updateCursor(current.length); return; }
    if (key.backspace) {
      if (activeCursor > 0) edit(current.slice(0, activeCursor - 1) + current.slice(activeCursor), activeCursor - 1);
      return;
    }
    if (key.delete) {
      if (activeCursor < current.length) edit(current.slice(0, activeCursor) + current.slice(activeCursor + 1), activeCursor);
      return;
    }
    if (key.ctrl && input === "u") { edit(current.slice(activeCursor), 0); return; }
    if (key.ctrl && input === "w") {
      let at = activeCursor;
      while (at > 0 && /\s/.test(current[at - 1])) at--;
      while (at > 0 && !/\s/.test(current[at - 1])) at--;
      edit(current.slice(0, at) + current.slice(activeCursor), at);
      return;
    }
    if (key.ctrl || key.meta || !input || input.startsWith("\u001b")) return;
    edit(current.slice(0, activeCursor) + input + current.slice(activeCursor), activeCursor + input.length);
  }, { isActive: true, captureCtrlC: true });

  return (
    <Box flexDirection="column" paddingX={2}>
      {showPalette && (
        <Box flexDirection="column" borderStyle="round" borderColor="#48454A" paddingX={1}>
          <Box justifyContent="space-between">
            <Text color="#E2A083" bold>КОМАНДЫ</Text>
            <Text dimColor>↑↓ выбрать · Tab дополнить · Enter запустить · Esc закрыть</Text>
          </Box>
          {suggestions.map((option, index) => {
            const active = focused === index;
            return (
              <Box key={option.name} paddingX={1} flexDirection="row"
                backgroundColor={active ? "#434047" : undefined}
                onMouseEnter={() => { setHovered(index); setSelected(index); }}
                onMouseLeave={() => setHovered(null)}
                onClick={event => { event.stopImmediatePropagation(); choose(option.name, true); }}
              >
                <Box width={17}>
                  <Text bold={active} color={active ? "#F0A787" : "#DDDDE2"}>
                    {active ? "❯ " : "  "}/{option.name}
                  </Text>
                </Box>
                <Text color={active ? "white" : "#9B9AA4"}>{option.description}</Text>
              </Box>
            );
          })}
        </Box>
      )}
      <Box marginTop={showPalette ? 0 : 1} borderStyle="round" borderColor={disabled ? "#535259" : "#D57B5F"}
        paddingX={1} flexDirection="column">
        <Box gap={1}>
          <Text color="#E8A080" bold>❯</Text>
          {disabled ? (
            <Text dimColor>Команда выполняется… Ctrl+C — остановить</Text>
          ) : value ? (
            <Text>{value.slice(0, cursor)}<Text inverse>{value[cursor] || " "}</Text>{value.slice(cursor + 1)}</Text>
          ) : (
            <Text><Text inverse> </Text><Text dimColor>Команда, / для действий…</Text></Text>
          )}
        </Box>
      </Box>
      <Box justifyContent="space-between" paddingX={1}>
        <Text dimColor>{showPalette ? "Наведи мышь для выделения, нажми для запуска" : "Enter выполнить  ·  / команды  ·  Ctrl+J терминал"}</Text>
        <Text dimColor>PgUp/PgDn история · Ctrl+F поиск</Text>
      </Box>
    </Box>
  );
}
