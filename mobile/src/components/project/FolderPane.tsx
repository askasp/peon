import { useEffect, useState } from "react";
import { StyleSheet, Text, View } from "react-native";
import { PickSheet } from "../Sheet";
import { Loading } from "../ui";
import { FileView } from "./FilesTab";
import { viewPattern, viewFor, viewInfo } from "@/lib/folders";
import { useLoad } from "@/lib/useLoad";
import { color } from "@/lib/theme";
import type { HomeView } from "@/lib/types";
import type { ProjectCtx } from "./types";

type Entry = { name: string; path: string; type: "directory" | "file" };

// Kept out of the picker: the agent's own files (under Settings) and build output.
const hidden = new Set(["AGENTS.md", "opencode.json", "node_modules"]);

/** Every file in the Project, a few levels down, paths sorted. */
async function allFiles(call: ProjectCtx["call"], dir = ".", depth = 0): Promise<string[]> {
  const { entries } = await call<{ entries: Entry[] }>("list_files", { path: dir });
  const shown = entries.filter((e) => !hidden.has(e.name));
  const nested = await Promise.all(
    shown
      .filter((e) => e.type === "directory" && depth < 3)
      .map((e) => allFiles(call, e.path, depth + 1).catch(() => [])),
  );
  return [...shown.filter((e) => e.type === "file").map((e) => e.path), ...nested.flat()].sort();
}

// The file a Project opens on: its template's own folder first, then anything with a View.
const home: Record<string, RegExp> = {
  design: /^designs\/.*\.html?$/,
  document: /^docs\/.*\.md$/,
  dataset: /^(app\/.*\.html|data\.sqlite)$/,
};

export function firstFile(kind: string, files: string[], view?: string | null) {
  const pinned = view ? viewPattern[view as HomeView] : null;
  return (
    files.find((f) => pinned?.test(f)) ??
    files.find((f) => home[kind]?.test(f)) ??
    files.find((f) => /(^|\/)readme\.md$/i.test(f)) ??
    files.find((f) => viewFor(f) !== "code") ??
    files[0] ??
    null
  );
}

/**
 * A single-chat Project's files beside its chat (desktop): one file in its View,
 * the path a picker for the rest. A file the agent writes opens here (`file`),
 * and what is shown goes along with each message (`onShown`).
 */
export function FolderPane({
  ctx,
  file,
  view,
  onFile,
  onShown,
}: {
  ctx: Pick<ProjectCtx, "call" | "changed" | "project">;
  file: string | null;
  /** Which View tab this is, to pick the file it pins (see `firstFile`). */
  view?: string | null;
  onFile: (path: string) => void;
  /** The file in view and the device its canvas shows, for the composer. */
  onShown: (path: string, view: string | null) => void;
}) {
  const [picking, setPicking] = useState(false);
  const { data: files, error } = useLoad(() => allFiles(ctx.call), [ctx.changed, ctx.call]);
  const shown = file ?? (files ? firstFile(ctx.project.kind, files, view) : null);

  // Keep the shown file once there is one, so new files don't move it.
  useEffect(() => {
    if (!file && shown) onFile(shown);
  }, [file, shown, onFile]);

  if (!files && !error) return <Loading />;
  if (!shown)
    return (
      <View style={st.empty}>
        <Text style={st.emptyTitle}>No files yet</Text>
        <Text style={st.emptyText}>What the agent makes here opens beside the chat.</Text>
      </View>
    );
  return (
    <>
      <FileView
        key={shown}
        call={ctx.call}
        path={shown}
        version={ctx.changed}
        onPick={() => setPicking(true)}
        count={files?.length}
        onView={(view) => onShown(shown, view)}
      />
      <PickSheet
        visible={picking}
        title="Show a file"
        onClose={() => setPicking(false)}
        items={(files ?? []).map((f) => ({
          key: f,
          label: f,
          detail: viewInfo[viewFor(f)][0],
          active: f === shown,
        }))}
        onPick={(f) => {
          setPicking(false);
          onFile(f);
        }}
      />
    </>
  );
}

const st = StyleSheet.create({
  empty: { flex: 1, alignItems: "center", justifyContent: "center", gap: 6, backgroundColor: "#0f0f12" },
  emptyTitle: { fontSize: 15, color: color.textSoft },
  emptyText: { fontSize: 13, color: color.faint },
});
