// A Project and the template it was made from.

import type { Project } from "./types";

type Kind = Project["kind"];

/** Short labels, for sidebar rows and filter chips. */
export const kindLabel: Record<Kind, string> = {
  code: "code",
  chat: "chat",
  document: "doc",
  design: "design",
  dataset: "data",
  home: "you",
  routine: "ops",
  system: "system",
};

/** Long names, for headers ("Code template"). */
export const templateName: Record<Kind, string> = {
  code: "Code",
  chat: "Chat",
  document: "Document",
  design: "Design",
  dataset: "Dataset",
  home: "Home",
  routine: "Operations",
  system: "System",
};

/** The templates a new Project can start from. */
export const templates: { kind: Kind; label: string; detail: string; opens: string }[] = [
  { kind: "code", label: "Code", detail: "git clone or init, worktrees on", opens: "Chats" },
  { kind: "document", label: "Document", detail: "docs/ and a writing skill", opens: "Chat" },
  { kind: "design", label: "Design", detail: "designs/ and an HTML design skill", opens: "Chat" },
  { kind: "dataset", label: "Dataset", detail: "data.sqlite, a schema skill and app/", opens: "Chat" },
  { kind: "routine", label: "Operations", detail: "procedures and API calls, no repo", opens: "Chat" },
];

/** A Project name from free text: lowercase words joined by dashes. */
export const slugName = (s: string) =>
  s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48);

const filler = new Set(
  "a an the and or for with of to in on at by me my our new make create build write design draft page about some please can you".split(
    " ",
  ),
);

/** A name for a Project made straight from a chat: a few words of the task, not taken yet. */
export function newFolderName(task: string, kind: Kind, projects: Project[]) {
  const words = task
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((w) => w.length > 1 && !filler.has(w));
  const base = slugName(words.slice(0, 3).join(" ")) || kind;
  const taken = new Set(projects.map((p) => p.name));
  let name = base;
  for (let i = 2; taken.has(name); i++) name = `${base}-${i}`;
  return name;
}

/** Filter chips: which kinds each one shows. */
export const filters: { key: string; label: string; kinds: Kind[] | null }[] = [
  { key: "all", label: "All", kinds: null },
  { key: "code", label: "Code", kinds: ["code"] },
  { key: "design", label: "Design", kinds: ["design"] },
  { key: "doc", label: "Doc", kinds: ["document"] },
  { key: "data", label: "Data", kinds: ["dataset"] },
  { key: "routine", label: "Operations", kinds: ["routine"] },
];

/** The user's Home (private, so only ever their own), and every other Project (system last), filtered by a chip. */
export function sortFolders(projects: Project[], filter = "all") {
  const kinds = filters.find((f) => f.key === filter)?.kinds ?? null;
  const home = projects.find((p) => p.kind === "home") ?? null;
  const rest = projects
    .filter((p) => p.kind !== "home" && (kinds ? kinds.includes(p.kind) : true))
    .sort(
      (a, b) => Number(a.kind === "system") - Number(b.kind === "system") || a.name.localeCompare(b.name),
    );
  return { home, folders: rest };
}

export const folderHref = (p: Pick<Project, "id" | "kind">) =>
  p.kind === "routine" ? `/routine/${p.id}` : `/project/${p.id}`;

/**
 * Projects with one working copy of their files, so one continuous chat beside
 * them (Code chats each get a worktree; Chat and Home hold unrelated talks).
 * An Operations Project's chat is where its procedures run.
 */
export const singleChat = (kind: Kind) =>
  kind === "document" || kind === "design" || kind === "dataset" || kind === "routine";

/** Where a Project opens first. */
export const firstTab = (kind: Kind) => (singleChat(kind) ? "chat" : "chats");

export type ViewKind = "doc" | "canvas" | "app" | "table" | "image" | "code" | "diff";

/** How a file is shown, from its path (like the web: designs/ open in the canvas). */
export function viewFor(path: string): ViewKind {
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  if (ext === "md") return "doc";
  if (ext === "html" && path.startsWith("app/")) return "app";
  if (ext === "html" || ext === "htm") return "canvas";
  if (ext === "sqlite" || ext === "db" || ext === "csv") return "table";
  if (["png", "jpg", "jpeg", "gif", "webp", "svg"].includes(ext)) return "image";
  return "code";
}

/** The View's name and the glyph its file rows and cards show. */
export const viewInfo: Record<ViewKind, [string, string]> = {
  doc: ["Document", "¶"],
  canvas: ["Canvas", "▣"],
  app: ["App", "◧"],
  table: ["Table", "▦"],
  image: ["Image", "◐"],
  code: ["Code", "‹›"],
  diff: ["Diff", "±"],
};
