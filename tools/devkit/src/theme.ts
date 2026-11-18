// The whole DevKit palette. Components must not use other colors:
// one accent for focus and the cursor, three status colors, two greys.
export const theme = {
  text: "#E6E3E8",
  dim: "#8E8A93",
  border: "#4A464E",
  accent: "#E08A68",
  success: "#8CC49B",
  error: "#E07A76",
  warning: "#E0B36F",
} as const;

export type Tone = "normal" | "dim" | "success" | "error" | "warning" | "accent";

export function toneColor(tone: Tone): string {
  switch (tone) {
    case "success": return theme.success;
    case "error": return theme.error;
    case "warning": return theme.warning;
    case "accent": return theme.accent;
    case "dim": return theme.dim;
    default: return theme.text;
  }
}

// Claude Code style spinner glyphs.
export const spinnerFrames = ["·", "✢", "✳", "✶", "✻", "✽", "✽", "✻", "✶", "✳", "✢", "·"];
