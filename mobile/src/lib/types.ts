// Shapes the server sends (BeamcodeWeb.AppJSON); OpenCode messages pass through.

export type Status = "idle" | "running" | "waiting";

export type User = { id: number; username: string; admin: boolean };

export type Project = {
  id: number;
  name: string;
  kind: "code" | "chat" | "document" | "design" | "dataset" | "home" | "routine" | "system";
  scope: "team" | "private";
  always_worktree: boolean;
  /** Code Projects: a worktree starts its next ready task when one finishes. */
  queue_auto?: boolean;
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
  /** What the call carries (a tool's arguments), as JSON. */
  detail?: string;
};

export type Run = {
  id: number;
  owner: string | null;
  owner_id: number | null;
  inputs: Record<string, string | string[]>;
  schedule_key: string;
  /** Which of the Project's procedures ran. */
  procedure?: string | null;
  session_id: string | null;
  status: "running" | "done" | "failed" | string;
  scope: string;
  error: string | null;
  summary: string | null;
  started: string;
  finished: string | null;
  /** How it started: slash, button, schedule, queue, chain (null: a run from before procedures). */
  trigger?: string | null;
  /** The step it's at, and what each step did. */
  step?: number;
  steps?: RunStep[];
  /** What it asks of a person while status is "waiting". */
  waiting?: RunWaiting | null;
  /** The run whose step started this one. */
  parent_id?: number | null;
  ticket?: string | null;
  /** Each output's item count. */
  outputs?: Record<string, number>;
};

export type RunStep = {
  name: string;
  status: "pending" | "running" | "waiting" | "done" | "partial" | "failed" | "skipped" | string;
  session_id?: string;
  model?: string | null;
  effort?: string | null;
  session?: "same" | "fresh";
  loops?: number;
  error?: string;
  text?: string | null;
  started?: string;
  finished?: string;
  /** A `run:` step: the runs it started, and how each ended. */
  children?: number[];
  results?: { id?: number; status: string; summary?: string | null; error?: string | null }[];
};

export type RunWaiting = {
  step: number;
  /** before: about to act (confirm); after: read what the step did; changes: review still asks for changes. */
  kind: "before" | "after" | "changes";
  text: string;
  items?: Record<string, any>[] | null;
  next?: string | null;
  back?: string | null;
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
  | {
      type: "question";
      key: string;
      /** `text` is the first question; `count` how many it asks. */
      form: { id: string; session_id: string; text: string; count: number };
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
  /** In a Procedure Project: the procedure a blank prompt runs. */
  procedure?: string | null;
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
  /** A compaction: "auto" (context filled up) or "manual", and what it kept. */
  reason?: "auto" | "manual";
  summary?: string;
  /** An assistant reply: what the model read and wrote, for the context meter. */
  tokens?: { input: number; output: number; reasoning: number; cache: { read: number; write: number } };
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
  /** Cut to the changes and a few lines around them. */
  patch?: string;
  status?: string;
  /** Patch lines left out past the server's cap. */
  hidden?: number;
};

/** A model to pick; `variants` are how hard it can think ("low", "high", …). */
export type ModelOption = {
  name: string;
  value: string;
  variants?: string[];
  variant?: string | null;
  /** Tokens it can hold. */
  context?: number | null;
};

export type SessionOptions = {
  agents: string[];
  models: ModelOption[];
  /** The model used when none is picked. */
  default?: ModelOption | null;
  /** `/` items; a Procedure Project lists its procedures, with their inputs. */
  slash: {
    name: string;
    description: string | null;
    kind: "skill" | "command" | "procedure";
    inputs?: string[];
  }[];
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

/** A question the agent asked (OpenCode's forms): fields to fill, then send. */
export type FormOption = { value: string; label: string; description?: string };
export type FormField = {
  key: string;
  type: "string" | "number" | "integer" | "boolean" | "multiselect" | "external";
  title?: string;
  description?: string;
  required?: boolean;
  hidden?: boolean;
  options?: FormOption[];
  /** Also allow an answer of your own, beside the options. */
  custom?: boolean;
  placeholder?: string;
  default?: any;
  url?: string;
};
export type Form = { id: string; title: string; fields: FormField[] };

/** A task a Project tracks with `tk` (`.tickets/*.md`): its state and progress notes. */
export type TicketNote = { at: string; text: string };
export type Ticket = {
  id: string;
  title: string;
  status: "open" | "in_progress" | "closed";
  type: string;
  priority: number;
  assignee?: string | null;
  tags: string[];
  deps: string[];
  created?: string | null;
  body: string;
  notes: TicketNote[];
  /** In a queue (`queue` request): open deps that hold it back, and whether it was paused. */
  blocked_by?: string[];
  paused?: boolean;
  /** The procedure it runs through (else the Project's Queue default), and its latest run. */
  procedure?: string | null;
  run?: {
    id: number;
    procedure: string;
    status: string;
    step: number;
    waiting: string | null;
    steps: { name: string; status: string; model?: string | null }[];
  } | null;
};

/** One tree's tasks in a Code Project's queue: main, or a chat's worktree (`ref` is the chat id). */
export type QueueTree = {
  ref: string;
  worktree: string;
  chat: { id: string; title: string; status: "running" | "waiting" | "idle" } | null;
  tickets: Ticket[];
};
export type Queue = { auto: boolean; trees: QueueTree[] };
