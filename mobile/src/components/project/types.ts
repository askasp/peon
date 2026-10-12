import type { Project } from "@/lib/types";

export type RoutineInput = { name: string; default: string | string[]; options: string[]; multi: boolean };

/** What every project tab gets: the project, who may change it, and its channel. */
export type ProjectCtx = {
  project: Project;
  canEdit: boolean;
  admin: boolean;
  inputs: RoutineInput[];
  /** A routine's run prompt (and what's wrong with routine.json, if anything). */
  routine: { run: string; error: string | null } | null;
  /** The tree the Files tab opens on: a chat id for its worktree (from a chat's "Open in Files"). */
  tree?: string;
  /** Bumped when the server says the project's sessions or runs changed. */
  changed: number;
  call: <T = any>(event: string, payload?: object, timeout?: number) => Promise<T>;
};
