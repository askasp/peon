/** "now", "4m", "2h ago"-style labels from epoch milliseconds or an ISO date. */
export function ago(when: number | string | null | undefined, suffix = false): string {
  if (when == null) return "";
  const t = typeof when === "number" ? when : Date.parse(when.endsWith("Z") ? when : `${when}Z`);
  if (!Number.isFinite(t)) return "";
  const s = Math.max(0, (Date.now() - t) / 1000);
  const tail = suffix ? " ago" : "";
  if (s < 60) return "now";
  if (s < 3600) return `${Math.floor(s / 60)}m${tail}`;
  if (s < 86400) return `${Math.floor(s / 3600)}h${tail}`;
  if (s < 172800) return "yesterday";
  return new Date(t).toLocaleDateString("en-GB", { day: "numeric", month: "short" });
}

/** "1m 04s" between two ISO times (or until now). */
export function duration(from: string, to?: string | null): string {
  const a = Date.parse(from.endsWith("Z") ? from : `${from}Z`);
  const b = to ? Date.parse(to.endsWith("Z") ? to : `${to}Z`) : Date.now();
  const s = Math.max(0, Math.round((b - a) / 1000));
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, "0")}s`;
}
