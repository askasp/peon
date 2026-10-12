// Shapes the server sends (BeamcodeWeb.AppJSON); OpenCode messages pass through.

export type Status = "idle" | "running" | "waiting";

export type User = { id: number; username: string; admin: boolean };

export type Project = {
  id: number;
  name: string;
  kind: "code" | "chat" | "document" | "design" | "dataset" | "home" | "routine" | "system";
  scope: "team" | "private";
  always_worktree: boolean;
  default_branch: string | null;
  schedule: string | null;
  sessions?: number | null;
  updated?: number | null;
};

export type SessionSummary = {
  id: string;
  title: string;
  updated: number | null;
  created: number | null;
  directory: string | null;
  branch: string | null;
  agent: string | null;
  model: any;
  status: Status;
  scope: string | null;
  /** Started by a schedule. */
  scheduled?: boolean;
  started_by: string | null;
  project: Project | null;
  /** The worktree folder, when the session isn't in the project's own folder. */
  worktree?: string | null;
};

export type RunningSession = { id: string; title: string; project: Project; status: Status };

export type Perm = {
  id: string;
  session_id: string;
  action: string;
  resources: string[];
  title: string;
};

export type Run = {
  id: number;
  owner: string | null;
  owner_id: number | null;
  inputs: Record<string, string | string[]>;
  schedule_key: string;
  session_id: string | null;
  status: "running" | "done" | "failed" | string;
  scope: string;
  error: string | null;
  summary: string | null;
  started: string;
  finished: string | null;
};

export type InboxItem =
  | {
      type: "permission";
      key: string;
      perm: Perm;
      session: { id: string; title: string };
      project: Project;
      mine: boolean;
    }
  | { type: "run"; key: string; run: Run; project: Project; mine: boolean };

export type Schedule = {
  key: string;
  project: Project;
  cron: string;
  when: string;
  scope: "team" | "me";
  owner: string | null;
  prompt: string;
  paused: boolean;
  next: string | null;
  last: Run | null;
};

export type Part =
  | { type: "text"; text: string; streaming?: boolean }
  | { type: "reasoning"; text: string }
  | {
      type: "tool";
      name: string;
      state?: { status?: string; input?: any; error?: { message?: string } };
    };

export type Message = {
  id: string;
  type: string;
  time?: { created?: number; completed?: number | null };
  text?: string;
  content?: Part[];
  error?: { message?: string };
  files?: { mime: string; name: string | null; data?: string | null }[];
  skills?: { name: string }[];
  command?: string;
  outcome?: string;
  model?: any;
  agent?: string;
  name?: string;
};

export type PlanRow = [string, string];

export type ComposeResult =
  | { kind: "navigate"; session_id: string; spoken: string }
  | {
      kind: "answer";
      text: string;
      /** The session's last reply ("" when there is none). */
      reply: string;
      spoken: string;
      open: string | null;
      items: { id: string; title: string; status: Status; updated: number; project: string }[];
    }
  | { kind: "done"; message: string; spoken: string };

export type DiffFile = {
  file: string;
  additions: number;
  deletions: number;
  patch?: string;
  status?: string;
};

export type SessionOptions = {
  agents: string[];
  models: { name: string; value: string }[];
  /** The model used when none is picked. */
  default?: { name: string; value: string } | null;
  slash: { name: string; description: string | null; kind: "skill" | "command" }[];
};

export type Keys = {
  prefs: {
    keymap: "tmux" | "standard";
    prefix: "ctrl+b" | "ctrl+space" | "ctrl+a";
    which_key_delay: number;
    status_line: boolean;
    keycast: boolean;
  };
  binds: Record<string, string>;
  actions: { action: string; default: string; desc: string }[];
  globals: { id: string; name: string; key: string; path: string }[];
  help: { title: string; rows: { keys: string[]; label: string }[] }[];
};
