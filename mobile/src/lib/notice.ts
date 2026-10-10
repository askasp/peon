// A note that outlives the screen that made it ("Created, but X needs its
// secret"), shown at the bottom until dismissed. See components/Notice.tsx.

import { useSyncExternalStore } from "react";

let current: string | null = null;
const listeners = new Set<() => void>();

function set(next: string | null) {
  current = next;
  listeners.forEach((l) => l());
}

export const notify = (text: string) => set(text);
export const dismissNotice = () => set(null);

export const useNotice = () =>
  useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => current,
  );
