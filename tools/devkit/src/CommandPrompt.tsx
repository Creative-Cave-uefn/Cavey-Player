import React, { useCallback, useEffect, useRef, useState } from "react";
import { Box, Text, useInput } from "@claude-code-kit/ink-renderer";
import { useTerminalSize } from "@claude-code-kit/ui";
import { filterChoices, visibleChoices } from "./choices.js";
import { paletteCommands, shortcuts } from "./commands.js";
import { theme } from "./theme.js";
import type { Dialog } from "./wizard.js";

type Props = {
  value: string;
  onChange: (value: string) => void;
  onSubmit: (value: string) => void | Promise<void>;
  history: string[];
  dialog?: Dialog;
  maxDialogRows: number;
  onPick: (value: string) => void | Promise<void>;
  onBack: () => void;
  running: boolean;
  searchOpen: boolean;
  footerRight: string;
  footerNote: string | null;
  showKeys: boolean;
  setShowKeys: (update: boolean | ((current: boolean) => boolean)) => void;
  onEscapeIdle: () => void;
  onInterrupt: () => void;
  onCtrlC: () => void;
  onTerminal: () => void;
  onSearch: () => void;
  onClear: () => void;
  onToggleExpand: () => void;
  onScroll: (delta: number) => void;
  onWheel: (delta: number) => void;
};

/** Input box, slash palette, shortcut sheet and Claude Code style dialogs. */
export function CommandPrompt(p: Props) {
  const { value, onChange, dialog, running, history, showKeys, setShowKeys } = p;
  const { columns } = useTerminalSize();
  const [cursor, setCursorState] = useState(0);
  const cursorRef = useRef(0);
  const setCursor = useCallback((next: number | ((c: number) => number)) => {
    cursorRef.current = typeof next === "function" ? next(cursorRef.current) : next;
    setCursorState(cursorRef.current);
  }, []);
  const [selected, setSelected] = useState(0);
  const [hovered, setHovered] = useState<number | null>(null);
  const [historyIndex, setHistoryIndex] = useState(-1);
  const [draft, setDraft] = useState("");
  const [dismissed, setDismissed] = useState(false);
  const valueRef = useRef(value);
  const pointerInRows = useRef(false);
  valueRef.current = value;

  useEffect(() => { setCursor(c => Math.min(c, value.length)); }, [value.length, setCursor]);
  useEffect(() => {
    pointerInRows.current = false; setSelected(0); setHovered(null); setDismissed(false);
  }, [dialog?.id]);

  const dialogActive = Boolean(dialog && !p.searchOpen);
  const options = dialogActive ? (dialog!.filterable ? filterChoices(dialog!.options, value) : dialog!.options) : [];
  const palette = dialogActive || dismissed || p.searchOpen ? [] : paletteCommands(value);
  const total = dialogActive ? options.length : palette.length;
  const focused = Math.min(hovered ?? selected, Math.max(0, total - 1));
  const page = dialogActive ? visibleChoices(options, focused, p.maxDialogRows) : null;

  const edit = useCallback((next: string, position: number) => {
    valueRef.current = next;
    onChange(next);
    setCursor(position);
    setSelected(0); setHovered(null); setHistoryIndex(-1); setDismissed(false); setShowKeys(false);
  }, [onChange, setCursor, setShowKeys]);
  const clear = useCallback(() => edit("", 0), [edit]);

  const pick = useCallback((choice: string) => {
    clear();
    void p.onPick(choice);
  }, [clear, p]);

  const runCommand = useCallback((name: string, execute: boolean) => {
    setDismissed(true);
    if (execute) { clear(); void p.onSubmit("/" + name); }
    else edit("/" + name + " ", name.length + 2);
  }, [clear, edit, p]);

  useInput((input, key, event) => {
    if (key.ctrl && input === "c") { event.stopImmediatePropagation(); p.onCtrlC(); return; }
    if (p.searchOpen) return;
    if (key.ctrl && input === "j") { event.stopImmediatePropagation(); p.onTerminal(); return; }
    if (key.ctrl && input === "f") { event.stopImmediatePropagation(); p.onSearch(); return; }
    if (key.ctrl && input === "l") { event.stopImmediatePropagation(); p.onClear(); return; }
    if (key.ctrl && input === "o") { event.stopImmediatePropagation(); p.onToggleExpand(); return; }
    if (key.pageUp || key.pageDown || key.wheelUp || key.wheelDown) {
      event.stopImmediatePropagation();
      const wheel = key.wheelUp || key.wheelDown;
      if (dialogActive && (!wheel || pointerInRows.current)) {
        const delta = key.pageUp ? -p.maxDialogRows : key.pageDown ? p.maxDialogRows : key.wheelUp ? -1 : 1;
        setHovered(null);
        if (options.length) setSelected(i => Math.max(0, Math.min(options.length - 1, i + delta)));
      } else if (wheel) p.onWheel(key.wheelUp ? -3 : 3);
      else p.onScroll(key.pageUp ? -12 : 12);
      return;
    }
    const current = valueRef.current;
    const at = Math.min(cursorRef.current, current.length);
    if (key.escape) {
      if (dialogActive) { if (current) clear(); else p.onBack(); }
      else if (running) p.onInterrupt();
      else if (showKeys) setShowKeys(false);
      else if (palette.length) clear();
      else if (current) clear();
      else p.onEscapeIdle();
      return;
    }
    const textDialog = dialogActive && Boolean(dialog!.input);
    if (textDialog && key.return) { clear(); void p.onPick(current); return; }
    if (dialogActive && !textDialog && !dialog!.filterable && /^[1-9]$/.test(input) && !key.ctrl) {
      const choice = options[Number(input) - 1];
      if (choice) pick(choice.value);
      return;
    }
    if (key.return) {
      if (dialogActive) { if (options[focused]) pick(options[focused]!.value); return; }
      if (palette[focused]) { runCommand(palette[focused]!.name, true); return; }
      if (current.trim()) { clear(); void p.onSubmit(current); }
      return;
    }
    if (key.tab) {
      if (dialogActive && options[focused]) pick(options[focused]!.value);
      else if (palette[focused]) runCommand(palette[focused]!.name, false);
      return;
    }
    if (key.upArrow || key.downArrow) {
      if (total) {
        setHovered(null);
        setSelected(i => (i + total + (key.upArrow ? -1 : 1)) % total);
      } else if (history.length > 0 && !dialogActive) {
        const index = key.upArrow ? Math.min(historyIndex + 1, history.length - 1) : historyIndex - 1;
        if (key.downArrow && historyIndex < 0) return;
        if (key.upArrow && historyIndex === -1) setDraft(current);
        const entry = index < 0 ? draft : history[index]!;
        setHistoryIndex(index);
        valueRef.current = entry; onChange(entry); setCursor(entry.length);
      }
      return;
    }
    if (!dialogActive && !current && input === "?") { setShowKeys(s => !s); return; }
    if (key.leftArrow) { setCursor(c => Math.max(0, c - 1)); return; }
    if (key.rightArrow) { setCursor(c => Math.min(current.length, c + 1)); return; }
    if (key.home || (key.ctrl && input === "a")) { setCursor(0); return; }
    if (key.end || (key.ctrl && input === "e")) { setCursor(current.length); return; }
    if (key.backspace) {
      if (at > 0) edit(current.slice(0, at - 1) + current.slice(at), at - 1);
      else if (dialogActive && !current) p.onBack();
      return;
    }
    if (key.delete) { if (at < current.length) edit(current.slice(0, at) + current.slice(at + 1), at); return; }
    if (key.ctrl && input === "u") { edit(current.slice(at), 0); return; }
    if (key.ctrl && input === "w") {
      let start = at;
      while (start > 0 && /\s/.test(current[start - 1]!)) start--;
      while (start > 0 && !/\s/.test(current[start - 1]!)) start--;
      edit(current.slice(0, start) + current.slice(at), start);
      return;
    }
    if (dialogActive && !dialog!.filterable && !textDialog) return;
    if (key.ctrl || key.meta || !input || input.startsWith("\u001b")) return;
    edit(current.slice(0, at) + input + current.slice(at), at + input.length);
  }, { isActive: true, captureCtrlC: true });

  const field = (placeholder: string) => value
    ? <Text color={theme.text}>{value.slice(0, cursor)}<Text inverse>{value[cursor] || " "}</Text>{value.slice(cursor + 1)}</Text>
    : <Text><Text inverse> </Text><Text color={theme.dim}>{placeholder}</Text></Text>;

  if (dialogActive) {
    const d = dialog!;
    const keyWidth = Math.max(0, ...(d.plan ?? []).map(([k]) => k.length)) + 3;
    const labelWidth = Math.min(Math.max(8, ...options.map(o => o.label.length + (d.filterable ? 0 : 3))) + 2,
      Math.max(16, Math.floor((columns - 12) * 0.55)));
    const fit = (text: string, width: number) => text.length > width - 2 ? text.slice(0, width - 2) + "… " : text.padEnd(width);
    return (
      <Box flexDirection="column" paddingX={2} flexShrink={0}>
        <Box flexDirection="column" borderStyle="round" borderColor={theme.border} paddingX={1}
          onMouseLeave={() => { pointerInRows.current = false; setHovered(null); }}>
          <Text bold color={theme.text}>{d.question}</Text>
          {d.plan && d.plan.length > 0 && (
            <Box flexDirection="column" marginTop={1}>
              {d.plan.map(([k, v]) => (
                <Box key={k} paddingLeft={2}>
                  <Box width={keyWidth} flexShrink={0}><Text color={theme.dim}>{k}</Text></Box>
                  <Text color={theme.text} wrap="wrap">{v}</Text>
                </Box>
              ))}
            </Box>
          )}
          {d.filterable && (
            <Box marginTop={1}><Text color={theme.dim}>Search </Text>{field("type to filter")}</Box>
          )}
          {d.input && (
            <Box marginTop={1}><Text color={theme.accent}>{"> "}</Text>{field(d.input.placeholder)}</Box>
          )}
          {!d.input && <Box flexDirection="column" marginTop={1}>
            {options.length === 0 && <Text color={theme.dim}>  No matches</Text>}
            {page!.start > 0 && <Text color={theme.dim}>  ↑ {page!.start} more</Text>}
            {page!.rows.map((option, row) => {
              const index = page!.start + row;
              const active = index === focused;
              return (
                <Box key={option.value} flexDirection="row" flexShrink={0}
                  onMouseEnter={() => { pointerInRows.current = true; setHovered(index); setSelected(index); }}
                  onMouseLeave={() => { pointerInRows.current = false; setHovered(null); }}
                  onClick={event => { event.stopImmediatePropagation(); pick(option.value); }}>
                  <Text wrap="truncate-end">
                    <Text color={active ? theme.accent : theme.dim}>{active ? "❯ " : "  "}</Text>
                    <Text color={active ? theme.accent : theme.text}>
                      {option.detail
                        ? fit((d.filterable ? "" : String(index + 1) + ". ") + option.label, labelWidth)
                        : (d.filterable ? "" : String(index + 1) + ". ") + option.label}
                    </Text>
                    {option.detail ? <Text color={theme.dim}>{option.detail}</Text> : null}
                  </Text>
                </Box>
              );
            })}
            {page!.start + page!.rows.length < page!.count && (
              <Text color={theme.dim}>  ↓ {page!.count - page!.start - page!.rows.length} more</Text>
            )}
          </Box>}
          {p.footerNote && <Box marginTop={1}><Text color={theme.warning} wrap="wrap">{p.footerNote}</Text></Box>}
          <Box marginTop={1}>
            <Text color={theme.dim}>
              {d.input ? "Enter to continue · Esc to go back"
                : (d.filterable ? "Type to filter · " : "Press a number or ") + "Enter to select · Esc to go back"}
            </Text>
          </Box>
        </Box>
      </Box>
    );
  }

  const keyWidth = Math.max(...shortcuts.map(([k]) => k.length)) + 2;
  const nameWidth = Math.max(0, ...palette.map(c => c.name.length)) + 4;
  return (
    <Box flexDirection="column" paddingX={2} flexShrink={0}>
      {palette.length > 0 ? (
        <Box flexDirection="column" paddingX={2}>
          {palette.map((option, index) => {
            const active = focused === index;
            return (
              <Box key={option.name} flexDirection="row"
                onMouseEnter={() => { setHovered(index); setSelected(index); }}
                onMouseLeave={() => setHovered(null)}
                onClick={event => { event.stopImmediatePropagation(); runCommand(option.name, true); }}>
                <Box width={nameWidth} flexShrink={0}>
                  {(() => {
                    const typed = value.startsWith("/") ? value.slice(1).split(/\s/)[0]!.toLowerCase() : "";
                    const n = option.name.toLowerCase().startsWith(typed) ? typed.length : 0;
                    return (
                      <Text color={active ? theme.accent : theme.text}>
                        /<Text bold>{option.name.slice(0, n)}</Text>{option.name.slice(n)}
                      </Text>
                    );
                  })()}
                </Box>
                <Text color={active ? theme.text : theme.dim} wrap="truncate-end">{option.description}</Text>
              </Box>
            );
          })}
        </Box>
      ) : showKeys ? (
        <Box flexDirection="column" paddingX={2}>
          {shortcuts.map(([k, action]) => (
            <Box key={k}><Box width={keyWidth} flexShrink={0}><Text color={theme.text}>{k}</Text></Box>
              <Text color={theme.dim}>{action}</Text></Box>
          ))}
        </Box>
      ) : null}
      <Box borderStyle="round" borderColor={theme.border} paddingX={1}>
        <Text color={running ? theme.dim : theme.text}>{"> "}</Text>
        {field("Type a command, / for actions, ? for shortcuts")}
      </Box>
      <Box paddingX={2} justifyContent="space-between">
        <Text color={p.footerNote ? theme.text : theme.dim} wrap="truncate-end">
          {p.footerNote ?? "? for shortcuts"}
        </Text>
        <Text color={theme.dim} wrap="truncate-start">{p.footerRight}</Text>
      </Box>
    </Box>
  );
}
