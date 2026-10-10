// Colours and type from the "Peon iOS Green" design: dark, orc green accent,
// teal for success so it doesn't read as the brand colour.

export const color = {
  bg: "#131317",
  bgDeep: "#0a0a0c",
  bar: "#111114",
  card: "#1a1a1f",
  field: "#1f1f25",
  raised: "#26262d",
  pill: "#34343c",
  border: "#2a2a31",
  hairline: "#1f1f25",
  divider: "#24242a",
  outline: "#34343c",
  text: "#e6e6ea",
  textStrong: "#f2f2f4",
  textSoft: "#c4c4cc",
  textDim: "#a3a3ac",
  muted: "#8b8b94",
  faint: "#6c6c76",
  ghost: "#3a3a42",
  accent: "#8bbd50",
  accentText: "#aedc7f",
  accentInk: "#121a0c",
  accentWash: "#1b2414",
  accentCard: "#171d13",
  accentBorder: "#2e3b22",
  teal: "#57c5c5",
  red: "#f07f77",
  danger: "#e64343",
  cream: "#f2efe8",
  // Amber: anything that needs you (approvals, questions, permissions).
  needs: "#eba66d",
  needsWash: "#2a1f16",
  needsCard: "#1f1812",
  needsBorder: "#4a3424",
  switchOn: "#54bf5c",
};

export const font = {
  brand: "BricolageGrotesque_700Bold",
  mono: "monospace",
};

// Letter tiles: each project gets a quiet tint of its own, picked from its name.
const TILES = [
  { bg: "#1e2a3a", fg: "#92c4ee" },
  { bg: "#2a1f16", fg: "#e5b28a" },
  { bg: "#261c2c", fg: "#d5adde" },
  { bg: "#14262a", fg: "#7dcece" },
  { bg: "#241f30", fg: "#b8b7f0" },
  { bg: "#1b2414", fg: "#adc992" },
];

export function tileColors(name: string, system = false): { bg: string; fg: string } {
  if (system) return { bg: color.divider, fg: color.textDim };
  let h = 0;
  for (const ch of name) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return TILES[h % TILES.length];
}

export const radius = { card: 16, row: 14, button: 10, field: 12, pill: 22 };
