// A Project's API calls: one file per service, `.peon/api/<service>.json`,
// with its calls as `"name": [method, path, permission, description]` (or the
// long form with a body), and in a Dataset the `tables` its read calls fill.

export type Permission = "allow" | "ask" | "deny";

/** An action's level in a Dataset: a write call's permission, said the way the Outbox says it. */
export type Level = "direct" | "confirm" | "off";
export const levelOf: Record<Permission, Level> = { allow: "direct", ask: "confirm", deny: "off" };
export const levels: { value: Level; label: string }[] = [
  { value: "direct", label: "Direct" },
  { value: "confirm", label: "Ask first" },
  { value: "off", label: "Off" },
];

export type ApiCall = {
  name: string;
  method: string;
  path: string;
  permission: Permission;
  description: string | null;
  /** The `{placeholders}` in its path. */
  params: string[];
  /** "write" calls are a Dataset's actions. */
  kind?: "read" | "write";
};

/** A table a read call fills (Datasets only), with how its last sync went. */
export type ApiTable = {
  name: string;
  call: string;
  columns: string[];
  every_minutes: number;
  rows: number | null;
  synced_at: string | null;
  error: string | null;
};

/** The Project's stored token for a service: never the value, only its last characters. */
export type ApiToken = { name: string; hint: string | null; set_by: string | null; updated_at: string };

export type ApiService = {
  name: string;
  /** "project": its own file; "shared": an older setup/connectors file listed for it. */
  source: "project" | "shared";
  path: string;
  error: string | null;
  base_url: string | null;
  auth: { type?: string; secret?: string; header?: string; param?: string } | null;
  secret: string | null;
  ready: boolean;
  token?: ApiToken | null;
  graphql?: boolean;
  tables?: ApiTable[];
  raw: string;
  calls: ApiCall[];
};

export type TryResult = { status: number; body: string; ms: number; url: string };

export const methods = ["GET", "POST", "PUT", "PATCH", "DELETE"];
export const permissions: Permission[] = ["allow", "ask", "deny"];

/** How a procedure step names it. */
export const reference = (service: string, call: string) => `${service}.${call}`;

/**
 * The service file with one call changed: `from` is its name before (null
 * for a new one), `call` its new value (null removes it). Throws when the
 * file isn't JSON.
 */
export function withCall(raw: string, from: string | null, call: ApiCall | null): string {
  const json = JSON.parse(raw || "{}");
  const spec = (c: ApiCall) => {
    const out = [c.method, c.path, c.permission];
    if (c.description?.trim()) out.push(c.description.trim());
    return out;
  };
  // Same order as before: a renamed call keeps its place, a new one goes last.
  const tools: Record<string, unknown> = {};
  for (const [name, value] of Object.entries(json.tools ?? {})) {
    if (name !== from) tools[name] = value;
    else if (call) tools[call.name] = spec(call);
  }
  if (call && !(call.name in tools)) tools[call.name] = spec(call);
  return format({ ...json, tools });
}

/** JSON with two-space indents, but each call on one line, as people write it. */
function format(json: Record<string, unknown>): string {
  const inline = (v: unknown) =>
    Array.isArray(v) ? `[${v.map((x) => JSON.stringify(x)).join(", ")}]` : JSON.stringify(v);
  const value = (key: string, v: unknown) => {
    if (key === "tools" && v && typeof v === "object") {
      const rows = Object.entries(v).map(([n, s]) => `    ${JSON.stringify(n)}: ${inline(s)}`);
      return rows.length ? `{\n${rows.join(",\n")}\n  }` : "{}";
    }
    const one = JSON.stringify(v, null, 1).replace(/\n\s*/g, " ");
    return one.length <= 72 ? one : JSON.stringify(v, null, 2).replace(/\n/g, "\n  ");
  };
  const rows = Object.entries(json).map(([k, v]) => `  ${JSON.stringify(k)}: ${value(k, v)}`);
  return `{\n${rows.join(",\n")}\n}\n`;
}

/** A response body for reading: JSON indented, anything else as it came. */
export function pretty(body: string): string {
  try {
    return JSON.stringify(JSON.parse(body), null, 2);
  } catch {
    return body;
  }
}

/** Colour family for a method badge. */
export const methodTint: Record<string, { bg: string; fg: string }> = {
  GET: { bg: "#14262a", fg: "#7dcece" },
  POST: { bg: "#1b2414", fg: "#adc992" },
  PUT: { bg: "#241f30", fg: "#b8b7f0" },
  PATCH: { bg: "#241f30", fg: "#b8b7f0" },
  DELETE: { bg: "#2a1716", fg: "#f07f77" },
};
