import React, { useCallback, useEffect, useRef, useState } from "react";
import { Box, Text, useInput } from "@claude-code-kit/ink-renderer";
import { filterChoices, visibleChoices, type ChoiceMenu } from "./choices.js";

export type CommandOption = { name: string; description: string };

export function matchCommands(value: string, options: CommandOption[]): CommandOption[] {
  if (!value.startsWith("/") || /\s/.test(value)) return [];
  const prefix = value.slice(1).toLocaleLowerCase();
  return options.filter(option => option.name.toLocaleLowerCase().startsWith(prefix)).slice(0, 7);
}

export function CommandPrompt({
  value, onChange, onSubmit, history, commands, menu, onMenuPick, onMenuCancel, maxMenuRows = 7,
  disabled = false, searchOpen = false,
  onCancel, onTerminal, onSearch, onClear, onScroll,
}: {
  value: string;
  onChange: (value: string) => void;
  onSubmit: (value: string) => void | Promise<void>;
  history: string[];
  commands: CommandOption[];
  menu?: ChoiceMenu;
  onMenuPick?: (value: string) => void | Promise<void>;
  onMenuCancel?: () => void;
  maxMenuRows?: number;
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

  useEffect(() => { updateCursor(c => Math.min(c, value.length)); }, [value.length, updateCursor]);
  useEffect(() => { setSelected(0); setHovered(null); setDismissed(false); }, [menu?.id]);
  const menuActive = Boolean(menu && !searchOpen && !disabled);
  const menuMatches = menuActive ? filterChoices(menu!.choices, value) : [];
  const suggestions = menuActive || dismissed || searchOpen || disabled ? [] : matchCommands(value, commands);
  const total = menuActive ? menuMatches.length : suggestions.length;
  const focused = Math.min(hovered ?? selected, Math.max(0, total - 1));
  const showPalette = !menuActive && suggestions.length > 0;
  const page = menuActive ? visibleChoices(menuMatches, focused, maxMenuRows) : null;

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

  const clearInput = useCallback(() => {
    valueRef.current = "";
    onChange("");
    updateCursor(0);
    setSelected(0);
    setHovered(null);
    setDismissed(false);
    setHistoryIndex(-1);
  }, [onChange, updateCursor]);
  const pickMenu = useCallback((choice: string) => {
    if (disabled || !onMenuPick) return;
    clearInput();
    void onMenuPick(choice);
  }, [clearInput, disabled, onMenuPick]);
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
    if (key.pageUp || key.pageDown || key.wheelUp || key.wheelDown) {
      event.stopImmediatePropagation();
      if (menuActive) {
        const delta = key.pageUp ? -maxMenuRows : key.pageDown ? maxMenuRows : key.wheelUp ? -1 : 1;
        setHovered(null);
        if (menuMatches.length) setSelected(i => Math.max(0, Math.min(menuMatches.length - 1, i + delta)));
      } else {
        onScroll(key.pageUp || key.wheelUp ? -12 : 12);
      }
      return;
    }
    if (disabled) return;
    const current = valueRef.current;
    const activeCursor = Math.min(cursorRef.current, current.length);
    if (key.escape) {
      if (menuActive) { clearInput(); onMenuCancel?.(); }
      else if (showPalette) setDismissed(true);
      else edit("", 0);
      return;
    }
    if (key.return) {
      if (menuActive && menuMatches[focused]) { pickMenu(menuMatches[focused]!.value); return; }
      if (showPalette && suggestions[focused]) { choose(suggestions[focused]!.name, true); return; }
      if (current.trim()) {
        clearInput();
        void onSubmit(current);
      }
      return;
    }
    if (key.tab) {
      if (menuActive && menuMatches[focused]) { pickMenu(menuMatches[focused]!.value); return; }
      if (showPalette && suggestions[focused]) choose(suggestions[focused]!.name, false);
      return;
    }
    if (key.upArrow || key.downArrow) {
      if (menuActive || showPalette) {
        setHovered(null);
        if (total) setSelected(i => (i + total + (key.upArrow ? -1 : 1)) % total);
      } else if (history.length > 0) {
        if (key.upArrow) {
          if (historyIndex === -1) setDraft(current);
          const index = Math.min(historyIndex + 1, history.length - 1);
          setHistoryIndex(index);
          const entry = history[index]!;
          valueRef.current = entry;
          onChange(entry);
          updateCursor(entry.length);
        } else if (historyIndex >= 0) {
          const index = historyIndex - 1;
          const entry = index < 0 ? draft : history[index]!;
          setHistoryIndex(index);
          valueRef.current = entry;
          onChange(entry);
          updateCursor(entry.length);
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
      {(showPalette || menuActive) && (
        <Box flexDirection="column" borderStyle="single" borderColor="#39383D" paddingX={1} flexShrink={0}>
          <Box justifyContent="space-between">
            <Text color="#E2A083" bold>{menuActive ? menu!.title : "COMMANDS"}</Text>
            <Text dimColor>{menuActive ? String(menuMatches.length) + "/" + String(menu!.choices.length) : String(suggestions.length) + " available"}</Text>
          </Box>
          {menuActive && menu!.subtitle && <Text dimColor wrap="truncate-end">{menu!.subtitle}</Text>}
          {menuActive && menuMatches.length === 0 && <Text dimColor>No matches · Esc to go back</Text>}
          {menuActive
            ? page!.rows.map((option, row) => {
                const index = page!.start + row;
                const active = index === focused;
                return (
                  <Box key={option.value} flexDirection="row" width="100%" paddingX={1} flexShrink={0}
                    backgroundColor={active ? "#373338" : undefined}
                    onMouseEnter={() => { setHovered(index); setSelected(index); }}
                    onMouseLeave={() => setHovered(null)}
                    onClick={event => { event.stopImmediatePropagation(); pickMenu(option.value); }}
                  >
                    <Text color={active ? "#E7A287" : "#7B7981"}>{active ? "❯ " : "  "}</Text>
                    <Box width="55%" flexShrink={1}>
                      <Text bold={active} color={active ? "#F0AB8E" : "#DAD7DD"} wrap="truncate-end">{option.label}</Text>
                    </Box>
                    <Box flexGrow={1}>
                      <Text color={active ? "#E1DEE4" : "#98969F"} wrap="truncate-end">{option.detail || ""}</Text>
                    </Box>
                  </Box>
                );
              })
            : suggestions.map((option, index) => {
                const active = focused === index;
                return (
                  <Box key={option.name} paddingX={1} flexDirection="row" width="100%"
                    backgroundColor={active ? "#444049" : undefined}
                    onMouseEnter={() => { setHovered(index); setSelected(index); }}
                    onMouseLeave={() => setHovered(null)}
                    onClick={event => { event.stopImmediatePropagation(); choose(option.name, true); }}
                  >
                    <Box width={17}>
                      <Text bold={active} color={active ? "#F0AB8E" : "#DAD7DD"}>{active ? "❯ " : "  "}/{option.name}</Text>
                    </Box>
                    <Text color={active ? "#E1DEE4" : "#98969F"}>{option.description}</Text>
                  </Box>
                );
              })}
          {menuActive && page!.count > page!.rows.length && (
            <Box justifyContent="space-between">
              <Text dimColor>{page!.start > 0 ? "↑ above" : ""}</Text>
              <Text dimColor>↑↓ · PgUp/PgDn · Wheel</Text>
              <Text dimColor>{page!.start + page!.rows.length < page!.count ? "below ↓" : ""}</Text>
            </Box>
          )}
        </Box>
      )}
      <Box marginTop={showPalette || menuActive ? 0 : 1} borderStyle="single" borderColor={disabled ? "#444048" : "#6B6268"}
        paddingX={1} flexDirection="column">
        <Box gap={1}>
          <Text color="#E8A080" bold>❯</Text>
          {disabled ? (
            <Text dimColor>Running… Ctrl+C to stop</Text>
          ) : value ? (
            <Text>{value.slice(0, cursor)}<Text inverse>{value[cursor] || " "}</Text>{value.slice(cursor + 1)}</Text>
          ) : (
            <Text><Text inverse> </Text><Text dimColor>{menuActive ? "Search options or use arrow keys…" : "Type a command or / for actions…"}</Text></Text>
          )}
        </Box>
      </Box>
      <Box paddingX={1}>
        <Text dimColor>
          {menuActive ? "↑↓ navigate · Enter select · Esc back · Click to choose" :
            showPalette ? "↑↓ navigate · Enter run · Tab complete · Click to choose" :
            "Enter run · / commands · Ctrl+J terminal · Ctrl+F search"}
        </Text>
      </Box>
    </Box>
  );
}
