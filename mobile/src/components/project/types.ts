import type { Procedure } from "@/lib/procedures";
import type { Project } from "@/lib/types";

/** What every project tab gets: the project, who may change it, and its channel. */
export type ProjectCtx = {
  project: Project;
  canEdit: boolean;
  admin: boolean;
  /** A Procedure Folder's procedures (else []), and what's wrong with procedures.json. */
  procedures: Procedure[];
  proceduresError: string | null;
  /** Asks the server again (after the chat may have added one). */
  reloadProcedures: () => void;
  /** The tree the Files tab opens on: a chat id for its worktree (from a chat's "Open in Files"). */
  tree?: string;
  /** Bumped when the server says the project's sessions or runs changed. */
  changed: number;
  call: <T = any>(event: string, payload?: object, timeout?: number) => Promise<T>;
};
