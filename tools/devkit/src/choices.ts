// Shared selection logic for branch, release-channel and confirmation pickers.
export type Choice = { value: string; label: string; detail?: string };
export type ChoiceMenu = { id: string; title: string; subtitle?: string; choices: Choice[] };

export function filterChoices(choices: readonly Choice[], query: string): Choice[] {
  const needle = query.trim().toLocaleLowerCase();
  if (!needle) return [...choices];
  return choices.filter((c, i) =>
    String(i + 1) === needle ||
    c.value.toLocaleLowerCase().includes(needle) ||
    c.label.toLocaleLowerCase().includes(needle) ||
    (c.detail ?? "").toLocaleLowerCase().includes(needle)
  );
}

export function visibleChoices<T>(choices: readonly T[], selected: number, limit: number) {
  const max = Math.max(1, Math.floor(limit));
  const index = Math.min(Math.max(selected, 0), Math.max(choices.length - 1, 0));
  const start = Math.max(0, Math.min(index - Math.floor(max / 2), choices.length - max));
  return { start, rows: choices.slice(start, start + max), count: choices.length };
}

export type ReleaseRecord = {
  tagName: string; name?: string; isPrerelease: boolean; publishedAt?: string;
};
export function releaseChannels(records: readonly ReleaseRecord[]): Choice[] {
  const matching = records.filter(r => r.isPrerelease &&
    /^test-[a-z0-9-]+-v\d+(\.\d+)+$/.test(r.tagName))
    .sort((a, b) => (b.publishedAt ?? "").localeCompare(a.publishedAt ?? ""));
  const seen = new Set<string>();
  const result: Choice[] = [];
  for (const release of matching) {
    const fromTitle = /^(?:Тест|Test):\s*(.+?)\s*·/.exec(release.name ?? "")?.[1];
    const fromTag = /^test-(.+)-v\d+(\.\d+)+$/.exec(release.tagName)?.[1];
    const channel = fromTitle || fromTag;
    if (!channel) continue;
    const id = channel.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
    if (seen.has(id)) continue;
    seen.add(id);
    result.push({ value: channel, label: channel, detail: release.tagName });
  }
  return result;
}
