import { useEffect, useMemo, useRef, useState } from "react";
import { Linking, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { Button, Dot, Empty, ErrorLine, Loading, Tap } from "../ui";
import { PickSheet } from "../Sheet";
import { Icon } from "../Icon";
import { AppView, Canvas, Code, Doc, Img, size, Table, type Opened } from "../views";
import { router } from "expo-router";
import { serverUrl } from "@/lib/peon";
import { viewFor, viewInfo } from "@/lib/folders";
import { useLoad } from "@/lib/useLoad";
import { useWide } from "@/lib/useWide";
import { color, font } from "@/lib/theme";
import type { ProjectCtx } from "./types";

type Entry = { name: string; path: string; type: "directory" | "file" };

/** A chat's worktree with changes main doesn't have (Code Folders). */
type Tree = { ref: string; title: string | null; worktree: string; changed: string[] };

/** `call` with every request aimed at one tree: "main" or a chat id. */
export function treeCall(call: ProjectCtx["call"], ref: string): ProjectCtx["call"] {
  return (event, payload = {}, timeout) => call(event, { ...payload, ref }, timeout);
}

/** Which tree the Files tab shows, and what changed in it. */
type Shown = {
  ref: string;
  call: ProjectCtx["call"];
  /** Paths changed in the shown worktree; null on main. */
  changed: Set<string> | null;
  changesOnly: boolean;
  /** A Code Folder's main: chats change it, not the editor. */
  readOnly: boolean;
  bar: React.ReactNode;
};

/**
 * The Folder's files: a tree beside the open file on the web, rows that open
 * the View on the phone. In a Code Folder a picker switches between main and
 * each chat's worktree.
 */
export function FilesTab({ ctx }: { ctx: ProjectCtx }) {
  const wide = useWide();
  const code = ctx.project.kind === "code";
  const [ref, setRef] = useState(ctx.tree ?? "main");
  // A new "Open in Files" link while the tab is open switches the tree.
  const [linked, setLinked] = useState(ctx.tree);
  if (ctx.tree !== linked) {
    setLinked(ctx.tree);
    if (ctx.tree) setRef(ctx.tree);
  }
  const [changesOnly, setChangesOnly] = useState(false);
  const [picking, setPicking] = useState(false);
  const { data: trees } = useLoad(
    () =>
      code || ref !== "main"
        ? ctx.call<{ trees: Tree[] }>("trees", {}, 30000).then((r) => r.trees)
        : Promise.resolve([] as Tree[]),
    [ctx.changed, code],
  );
  const current = (trees ?? []).find((t) => t.ref === ref) ?? null;
  const main = ref === "main";
  const call = useMemo(() => treeCall(ctx.call, ref), [ctx.call, ref]);

  const bar =
    code || !main ? (
      <View style={st.bar}>
        <Tap onPress={() => setPicking(true)} style={st.treeChip} testID="tree-picker">
          <Text style={[st.treeChipText, main && { fontFamily: font.mono }]} numberOfLines={1}>
            {main ? "main" : (current?.title ?? "This chat's worktree")}
          </Text>
          <Text style={st.treeChipCaret}>▾</Text>
        </Tap>
        {!main ? (
          <Tap
            onPress={() => setChangesOnly((v) => !v)}
            style={[st.onlyChip, changesOnly && st.onlyChipOn]}
            testID="changes-only"
          >
            <Text style={[st.onlyText, changesOnly && { color: color.accentText }]}>
              Changes only{current ? ` · ${current.changed.length}` : ""}
            </Text>
          </Tap>
        ) : (trees ?? []).length ? (
          <Text style={st.barNote}>
            {trees!.length} chat{trees!.length === 1 ? "" : "s"} with changes
          </Text>
        ) : null}
        <PickSheet
          visible={picking}
          title="Show files from"
          onClose={() => setPicking(false)}
          items={[
            { key: "main", label: "main", detail: "The Folder's files", active: main },
            ...(trees ?? []).map((t) => ({
              key: t.ref,
              label: t.title || t.worktree,
              detail: `${t.changed.length} changed · ${t.worktree}`,
              active: t.ref === ref,
            })),
            ...(!main && !current ? [{ key: ref, label: "This chat's worktree", active: true }] : []),
          ]}
          onPick={(key) => {
            setPicking(false);
            setRef(key);
            if (key === "main") setChangesOnly(false);
          }}
        />
      </View>
    ) : null;

  const shown: Shown = {
    ref,
    call,
    changed: main ? null : new Set(current?.changed ?? []),
    changesOnly: !main && changesOnly,
    readOnly: code && main,
    bar,
  };
  return wide ? (
    <FilesWide key={ref} ctx={ctx} shown={shown} />
  ) : (
    <FilesPhone key={ref} ctx={ctx} shown={shown} />
  );
}

/** Whether `path` (a file, or a subfolder holding one) changed. */
function marked(changed: Set<string> | null, path: string, dir: boolean) {
  if (!changed) return false;
  if (!dir) return changed.has(path);
  for (const c of changed) if (c.startsWith(`${path}/`)) return true;
  return false;
}

/** The changed files as a flat list ("Changes only"). */
function changedEntries(changed: Set<string> | null): Entry[] {
  return [...(changed ?? [])].sort().map((p) => ({ name: p, path: p, type: "file" }));
}

function FilesPhone({ ctx, shown: t }: { ctx: ProjectCtx; shown: Shown }) {
  const [dir, setDir] = useState(".");
  const { data: listed, error } = useLoad(
    () => t.call<{ entries: Entry[] }>("list_files", { path: dir }).then((r) => r.entries),
    [dir, ctx.changed, t.call],
  );
  const data = t.changesOnly ? changedEntries(t.changed) : listed;
  const go = setDir;

  // Phone: grouped rows; a file opens full screen in the View.
  const parts = dir === "." || t.changesOnly ? [] : dir.split("/");
  const shown = (data ?? []).filter(
    (e) => t.changesOnly || dir !== "." || !["AGENTS.md", "opencode.json"].includes(e.name),
  );
  const open = (e: Entry) =>
    e.type === "directory"
      ? go(e.path)
      : router.push({
          pathname: "/view" as any,
          params: {
            project: String(ctx.project.id),
            path: e.path,
            from: "files",
            ...(t.ref !== "main" ? { tree: t.ref } : {}),
          },
        });
  return (
    <ScrollView contentContainerStyle={st.phoneBody}>
      {t.bar}
      {parts.length ? (
        <Tap onPress={() => go(parts.slice(0, -1).join("/") || ".")} style={st.up}>
          <Icon name="back" size={16} color={color.accentText} strokeWidth={2.4} />
          <Text style={st.upText}>
            {parts.length > 1
              ? parts[parts.length - 2]
              : ctx.project.kind === "home"
                ? "Home"
                : ctx.project.name}
            <Text style={{ color: color.muted }}> / {parts[parts.length - 1]}</Text>
          </Text>
        </Tap>
      ) : null}
      <ErrorLine message={error} />
      {data == null ? (
        error ? null : (
          <Loading />
        )
      ) : shown.length === 0 ? (
        <Empty title={t.changesOnly ? "No changes" : "No files yet"} />
      ) : (
        <View style={st.group}>
          {shown.map((e, i) => {
            const kind = viewFor(e.name);
            return (
              <Tap
                key={e.path}
                kb="row"
                onPress={() => open(e)}
                style={[st.item, i < shown.length - 1 && st.itemLine]}
              >
                {e.type === "directory" ? (
                  <View style={st.glyphPlain}>
                    <Icon name="folder" size={22} color={color.muted} />
                  </View>
                ) : (
                  <View style={st.glyph}>
                    <Text style={st.glyphText}>{viewInfo[kind][1]}</Text>
                  </View>
                )}
                <View style={{ flex: 1, gap: 1 }}>
                  <Text style={st.itemName} numberOfLines={1}>
                    {e.name}
                  </Text>
                  {e.type === "file" ? <Text style={st.itemKind}>{viewInfo[kind][0]}</Text> : null}
                </View>
                {marked(t.changed, e.path, e.type === "directory") ? <Dot size={7} /> : null}
                <Text style={st.chev}>›</Text>
              </Tap>
            );
          })}
        </View>
      )}
      {dir === "." && !t.changesOnly ? (
        <Text style={st.foot}>
          {t.readOnly ? "Chats change these files. " : ""}AGENTS.md and skills are under Settings.
        </Text>
      ) : null}
    </ScrollView>
  );
}

/** Web: a file tree (subfolders load as they open) beside the open file's View. */
function FilesWide({ ctx, shown: t }: { ctx: ProjectCtx; shown: Shown }) {
  const [open, setOpen] = useState<string[]>([]);
  const [kids, setKids] = useState<Record<string, Entry[]>>({});
  const [file, setFile] = useState<string | null>(null);
  const { data: root, error } = useLoad(async () => {
    const r = await t.call<{ entries: Entry[] }>("list_files", { path: "." });
    const entries = r.entries.filter((e) => !["AGENTS.md", "opencode.json"].includes(e.name));
    // Open a README or the first document by default.
    setFile(
      (f) =>
        f ??
        entries.find((e) => /^readme\.md$/i.test(e.name))?.path ??
        entries.find((e) => e.type === "file" && viewFor(e.name) !== "code")?.path ??
        null,
    );
    return entries;
  }, [ctx.changed, t.call]);

  async function toggle(dir: string) {
    if (open.includes(dir)) return setOpen((o) => o.filter((d) => d !== dir));
    setOpen((o) => [...o, dir]);
    if (!kids[dir]) {
      const r = await t
        .call<{ entries: Entry[] }>("list_files", { path: dir })
        .catch(() => ({ entries: [] }));
      setKids((k) => ({ ...k, [dir]: r.entries }));
    }
  }

  const rows: { e: Entry; depth: number }[] = [];
  const walk = (list: Entry[], depth: number) => {
    for (const e of list) {
      rows.push({ e, depth });
      if (e.type === "directory" && open.includes(e.path) && kids[e.path]) walk(kids[e.path], depth + 1);
    }
  };
  if (t.changesOnly) for (const e of changedEntries(t.changed)) rows.push({ e, depth: 0 });
  else walk(root ?? [], 0);
  const files = rows.filter((r) => r.e.type === "file").length;

  return (
    <View style={st.split}>
      <ScrollView style={st.tree} contentContainerStyle={st.treeBody}>
        {t.bar}
        <Text style={st.treeHead}>
          {files} {t.changesOnly ? "changed" : `file${files === 1 ? "" : "s"}`}
        </Text>
        <ErrorLine message={error} />
        {root == null && !error ? <Loading /> : null}
        {rows.map(({ e, depth }) => {
          const dir = e.type === "directory";
          const on = e.path === file;
          return (
            <Tap
              key={e.path}
              kb="row"
              onPress={() => (dir ? toggle(e.path) : setFile(e.path))}
              style={[st.treeRow, { paddingLeft: 10 + depth * 14 }, on && st.rowOn]}
            >
              <Text style={st.treeIcon}>
                {dir ? (open.includes(e.path) ? "▾" : "▸") : viewInfo[viewFor(e.name)][1]}
              </Text>
              <Text style={[st.treeName, on && { color: color.textStrong }]} numberOfLines={1}>
                {e.name}
              </Text>
              {marked(t.changed, e.path, dir) ? <Dot size={6} /> : null}
              {dir ? null : <Text style={st.treeKind}>{shortKind[viewFor(e.name)]}</Text>}
            </Tap>
          );
        })}
        <Text style={st.treeFoot}>AGENTS.md and skills live under Settings.</Text>
      </ScrollView>
      <View style={st.fill}>
        {file ? (
          <FileView
            key={file}
            call={t.call}
            version={ctx.changed}
            path={file}
            readOnly={t.readOnly}
            onAsk={() =>
              router.push({
                pathname: "/compose",
                params: { folder: String(ctx.project.id), text: `About ${file}: ` },
              })
            }
          />
        ) : (
          <View style={st.pick}>
            <Text style={st.pickText}>Pick a file to open its View</Text>
          </View>
        )}
      </View>
    </View>
  );
}

const shortKind: Record<string, string> = {
  doc: "doc",
  canvas: "html",
  app: "app",
  table: "data",
  image: "image",
  code: "code",
  diff: "diff",
};

/**
 * One file in a web pane, shown by its type, under a header with its path and
 * actions. `call` is a project channel's; the file is fetched again whenever
 * `version` changes (the agent edited something).
 */
export function FileView({
  call,
  path,
  version = 0,
  onClose,
  onAsk,
  onView,
  onOpenInFiles,
  onPick,
  count,
  readOnly = false,
}: {
  /** A project channel's, aimed at the file's tree (see `treeCall`). */
  call: ProjectCtx["call"];
  path: string;
  version?: number;
  /** No Edit: a Code Folder's main. */
  readOnly?: boolean;
  onOpenInFiles?: () => void;
  onClose?: () => void;
  /** "Chat about this". */
  onAsk?: (view: string | null) => void;
  /** Told how the file is shown ("Phone"), or null, when it changes. */
  onView?: (view: string | null) => void;
  /** The path is a picker for the Folder's other files (`count` of them). */
  onPick?: () => void;
  count?: number;
}) {
  const [saved, setSaved] = useState(0);
  const { data: f, error } = useLoad(() => call<Opened>("open_file", { path }), [path, version, saved]);
  const [editing, setEditing] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const kind = viewFor(path);
  const told = useRef(onView);
  useEffect(() => {
    told.current = onView;
  });
  useEffect(() => {
    told.current?.(null);
  }, []);
  const slash = path.lastIndexOf("/");
  const url = f ? serverUrl(f.url) : null;

  async function save() {
    if (editing == null) return;
    setSaving(true);
    setSaveError(null);
    try {
      // AGENTS.md and skills go through save_file, which has OpenCode reload them.
      const event = path === "AGENTS.md" || path.endsWith("SKILL.md") ? "save_file" : "write_file";
      await call(event, { path, content: editing });
      setEditing(null);
      setSaved((n) => n + 1);
    } catch (e: any) {
      setSaveError(e.message);
    }
    setSaving(false);
  }

  let body;
  if (error) body = <ErrorLine message={error} />;
  else if (!f || !url) body = <Loading />;
  else if (editing != null)
    body = (
      <TextInput
        value={editing}
        onChangeText={setEditing}
        multiline
        autoFocus
        autoCapitalize="none"
        autoCorrect={false}
        spellCheck={false}
        textAlignVertical="top"
        style={st.editor}
      />
    );
  else if (kind === "doc" && f.text != null) body = <Doc text={f.text} />;
  else if (kind === "canvas") body = <Canvas url={url} version={version + saved} mode="both" />;
  else if (kind === "app") body = <AppView url={url} />;
  else if (kind === "table") body = <Table call={call} path={path} text={f.text} />;
  else if (kind === "image") body = <Img url={url} file={f} />;
  else if (f.text != null) body = <Code text={f.text} />;
  else
    body = (
      <View style={st.binary}>
        <Text style={st.size}>{size(f.size)}</Text>
        <Button label="Open" kind="secondary" height={36} onPress={() => Linking.openURL(url)} />
      </View>
    );

  return (
    <View style={st.view}>
      <View style={st.viewHead}>
        {onPick ? null : (
          <View style={st.kindChip}>
            <Text style={st.kindText}>{viewInfo[kind][0]}</Text>
          </View>
        )}
        <Tap
          disabled={!onPick}
          onPress={onPick}
          style={[{ flexShrink: 1 }, onPick && st.pathPicker]}
          testID="file-picker"
        >
          <Text style={st.viewPath} numberOfLines={1}>
            {slash > 0 ? (
              <Text style={{ color: color.muted }}>{path.slice(0, slash).split("/").join(" / ")} / </Text>
            ) : null}
            {path.slice(slash + 1)}
            {onPick ? <Text style={{ color: color.muted }}> ▾</Text> : null}
          </Text>
        </Tap>
        {count != null ? (
          <Text style={st.count}>
            {count} file{count === 1 ? "" : "s"}
          </Text>
        ) : null}
        <View style={{ flex: 1 }} />
        {kind === "doc" && f?.text != null && editing == null && !readOnly ? (
          <Tap onPress={() => setEditing(f.text)} style={st.headButton}>
            <Text style={st.headButtonText}>Edit</Text>
          </Tap>
        ) : null}
        {editing != null ? (
          <>
            <Tap onPress={() => setEditing(null)} hitSlop={6}>
              <Text style={[st.headButtonText, { color: color.muted }]}>Cancel</Text>
            </Tap>
            <Tap onPress={save} disabled={saving} style={st.headSolid}>
              <Text style={st.headSolidText}>{saving ? "Saving…" : "Save"}</Text>
            </Tap>
          </>
        ) : null}
        {onAsk ? (
          <Tap onPress={() => onAsk(null)} style={st.ask} testID="chat-about-this">
            <Text style={st.askText}>Chat about this</Text>
          </Tap>
        ) : null}
        {onOpenInFiles ? (
          <Tap onPress={onOpenInFiles} style={st.headButton}>
            <Text style={st.headButtonText}>Open in Files</Text>
          </Tap>
        ) : null}
        {onClose ? (
          <Tap onPress={onClose} style={st.close} aria-label="Close the view">
            <Icon name="close" size={14} color={color.muted} />
          </Tap>
        ) : null}
      </View>
      <ErrorLine message={saveError} />
      <View style={{ flex: 1, minHeight: 0 }}>{body}</View>
    </View>
  );
}

const st = StyleSheet.create({
  pathPicker: { paddingHorizontal: 8, paddingVertical: 4, borderRadius: 6, backgroundColor: color.field },
  count: { fontSize: 12, color: color.faint },
  bar: { flexDirection: "row", alignItems: "center", gap: 8, flexWrap: "wrap", paddingBottom: 8 },
  treeChip: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    maxWidth: 260,
    height: 30,
    paddingHorizontal: 10,
    borderRadius: 8,
    backgroundColor: color.field,
  },
  treeChipText: { flexShrink: 1, fontSize: 13, color: color.text },
  treeChipCaret: { fontSize: 11, color: color.muted },
  onlyChip: {
    height: 30,
    paddingHorizontal: 10,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: color.outline,
    justifyContent: "center",
  },
  onlyChipOn: { borderColor: color.accentWash, backgroundColor: color.accentWash },
  onlyText: { fontSize: 12, color: color.textDim },
  barNote: { fontSize: 12, color: color.muted },
  tree: { width: 280, flexGrow: 0, borderRightWidth: 1, borderRightColor: color.hairline },
  treeBody: { paddingHorizontal: 8, paddingVertical: 12, gap: 1 },
  treeHead: { fontSize: 12, color: color.muted, paddingHorizontal: 10, paddingBottom: 10 },
  treeRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    paddingVertical: 6,
    paddingRight: 10,
    borderRadius: 6,
  },
  treeIcon: { width: 16, textAlign: "center", fontSize: 11, color: color.faint, fontFamily: font.mono },
  treeName: { flex: 1, fontSize: 14, color: color.textSoft },
  treeKind: { fontSize: 11, color: "#5d5d66" },
  treeFoot: { fontSize: 12, lineHeight: 18, color: "#5d5d66", paddingHorizontal: 10, paddingTop: 16 },
  pick: { flex: 1, alignItems: "center", justifyContent: "center", backgroundColor: "#0f0f12" },
  pickText: { fontSize: 14, color: "#5d5d66" },
  viewHead: {
    height: 46,
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingLeft: 16,
    paddingRight: 12,
    borderBottomWidth: 1,
    borderBottomColor: "#222228",
  },
  kindChip: { paddingHorizontal: 7, paddingVertical: 2, borderRadius: 5, backgroundColor: color.field },
  kindText: { fontSize: 11, color: color.textDim },
  viewPath: { flexShrink: 1, fontSize: 13, color: color.text },
  headButton: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 6,
    borderWidth: 1,
    borderColor: color.outline,
  },
  headButtonText: { fontSize: 12, color: color.text },
  headSolid: {
    paddingHorizontal: 12,
    paddingVertical: 4,
    borderRadius: 6,
    backgroundColor: color.textStrong,
  },
  headSolidText: { fontSize: 12, fontWeight: "600", color: color.bg },
  ask: { paddingHorizontal: 10, paddingVertical: 5, borderRadius: 7, backgroundColor: color.accentWash },
  askText: { fontSize: 12, fontWeight: "600", color: color.accentText },
  close: { width: 26, height: 26, borderRadius: 6, alignItems: "center", justifyContent: "center" },
  editor: {
    flex: 1,
    padding: 18,
    color: color.text,
    fontSize: 14,
    lineHeight: 22,
    fontFamily: font.mono,
    outlineStyle: "none",
  } as any,
  // Room at the bottom for the New chat button.
  phoneBody: { paddingHorizontal: 18, paddingTop: 4, paddingBottom: 120, gap: 14 },
  up: { flexDirection: "row", alignItems: "center", gap: 4, minHeight: 32 },
  upText: { fontSize: 15, color: color.accentText },
  group: { borderRadius: 14, backgroundColor: color.card, overflow: "hidden" },
  item: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    minHeight: 52,
    paddingHorizontal: 14,
    paddingVertical: 8,
  },
  itemLine: { borderBottomWidth: 1, borderBottomColor: color.divider },
  glyph: {
    width: 30,
    height: 30,
    borderRadius: 7,
    backgroundColor: color.divider,
    alignItems: "center",
    justifyContent: "center",
  },
  glyphPlain: { width: 30, height: 30, alignItems: "center", justifyContent: "center" },
  glyphText: { fontSize: 12, fontFamily: font.mono, color: color.textDim },
  itemName: { fontSize: 16, color: color.text },
  itemKind: { fontSize: 12, color: color.muted },
  chev: { fontSize: 18, color: "#5d5d66" },
  foot: { fontSize: 12, color: "#5d5d66" },
  fill: { flex: 1, minHeight: 0, minWidth: 0 },
  split: { flex: 1, minHeight: 0, flexDirection: "row" },
  rowOn: { backgroundColor: color.raised },
  view: { flex: 1, minHeight: 0, minWidth: 0, backgroundColor: "#0f0f12" },
  binary: { flex: 1, alignItems: "center", justifyContent: "center", gap: 14 },
  size: { fontSize: 13, color: color.muted },
});
