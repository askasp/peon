// The command palette's state: closed, or open in a mode ("all" commands and
// places, "switch" to a place, "new" session in a project).

import { useSyncExternalStore } from "react";

export type PaletteMode = "all" | "switch" | "new";

let mode: PaletteMode | null = null;
const listeners = new Set<() => void>();
const set = (v: PaletteMode | null) => {
  mode = v;
  listeners.forEach((l) => l());
};

export const openPalette = (m: PaletteMode = "all") => set(m);
export const closePalette = () => set(null);

export function usePalette(): PaletteMode | null {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => mode,
  );
}
