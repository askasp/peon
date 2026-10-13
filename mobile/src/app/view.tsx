import { useMemo, useState } from "react";
import { Linking, StyleSheet, Text, TextInput, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { AppView, Canvas, Code, Doc, Img, size, Table, type Opened } from "@/components/views";
import { DiffView } from "@/components/session/DiffView";
import { treeCall } from "@/components/project/FilesTab";
import { ErrorLine, Loading, Tap } from "@/components/ui";
import { serverUrl, usePeon } from "@/lib/peon";
import { useChannel } from "@/lib/useChannel";
import { useLoad } from "@/lib/useLoad";
import { singleChat, viewFor, viewInfo, type ViewKind } from "@/lib/folders";
import { attachToChat } from "@/lib/attach";
import { getViewDiff } from "@/lib/viewStore";
import { color, font } from "@/lib/theme";

// A file (or a chat's diff) full screen: the phone's View. `from=files` adds
// "Chat about this file"; `tree` is a chat id to read that chat's worktree.
export default function ViewScreen() {
  const {
    project,
    path = "",
    from,
    diff,
    tree = "main",
  } = useLocalSearchParams<{
    project: string;
    path?: string;
    from?: string;
    diff?: string;
    tree?: string;
  }>();
  const insets = useSafeAreaInsets();
  const ch = useChannel(`project:${project}`);
  const call = useMemo(() => treeCall(ch.call, tree), [ch.call, tree]);
  const folder = usePeon((s) => s.projects.find((p) => String(p.id) === project));
  // A Code Project's main changes through chats.
  const readOnly = folder?.kind === "code" && tree === "main";
  const kind: ViewKind = diff ? "diff" : viewFor(path);
  const [editing, setEditing] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [version, setVersion] = useState(0);
  const [error, setError] = useState<string | null>(null);

  const slash = path.lastIndexOf("/");
  const name = diff ? diff : path.slice(slash + 1);
  const folderName = folder?.kind === "home" ? "Home" : (folder?.name ?? "");
  const where = [
    folderName,
    tree !== "main" ? "chat's worktree" : null,
    !diff && slash > 0 ? path.slice(0, slash) : null,
  ]
    .filter(Boolean)
    .join(" / ");

  const { data: file, error: loadError } = useLoad<Opened | null>(
    () => (ch.joined && kind !== "diff" ? call<Opened>("open_file", { path }) : Promise.resolve(null)),
    [ch.joined, path, version, call],
  );

  async function save() {
    if (editing == null) return;
    setSaving(true);
    setError(null);
    try {
      // AGENTS.md and skills go through save_file, which has OpenCode reload them.
      const event = path === "AGENTS.md" || path.endsWith("SKILL.md") ? "save_file" : "write_file";
      await call(event, { path, content: editing });
      setEditing(null);
      setVersion((v) => v + 1);
    } catch (e: any) {
      setError(e.message);
    }
    setSaving(false);
  }

  let body;
  if (kind === "diff") body = <DiffView files={getViewDiff()} />;
  else if (loadError) body = <ErrorLine message={loadError} />;
  else if (!file) body = <Loading />;
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
  else if (kind === "doc" && file.text != null) body = <Doc text={file.text} />;
  else if (kind === "canvas") body = <Canvas url={serverUrl(file.url)} version={version} />;
  else if (kind === "app") body = <AppView url={serverUrl(file.url)} />;
  else if (kind === "table") body = <Table call={call} path={path} text={file.text} />;
  else if (kind === "image") body = <Img url={serverUrl(file.url)} file={file} />;
  else if (file.text != null) body = <Code text={file.text} />;
  else
    body = (
      <View style={st.center}>
        <Text style={st.faint}>{size(file.size)}</Text>
        <Tap onPress={() => Linking.openURL(serverUrl(file.url))} style={st.outline}>
          <Text style={st.outlineText}>Open</Text>
        </Tap>
      </View>
    );

  return (
    <View style={[st.screen, { paddingTop: insets.top }]}>
      <View style={st.head}>
        <View style={{ flex: 1, gap: 2 }}>
          <Text style={st.name} numberOfLines={1}>
            {name}
          </Text>
          <Text style={st.where} numberOfLines={1}>
            {viewInfo[kind][0]} · {where}
          </Text>
        </View>
        {kind === "doc" && file?.text != null && editing == null && !readOnly ? (
          <Tap onPress={() => setEditing(file.text)} style={st.outline}>
            <Text style={st.outlineText}>Edit</Text>
          </Tap>
        ) : null}
        {editing != null ? (
          <Tap onPress={save} disabled={saving} style={st.solid}>
            <Text style={st.solidText}>{saving ? "Saving…" : "Save"}</Text>
          </Tap>
        ) : null}
        <Tap onPress={() => (router.canGoBack() ? router.back() : router.replace("/"))} hitSlop={10}>
          <Text style={st.done}>Done</Text>
        </Tap>
      </View>
      <ErrorLine message={error} />
      <View style={{ flex: 1, minHeight: 0 }}>{body}</View>
      {from === "files" && !diff ? (
        <View style={[st.ask, { paddingBottom: Math.max(insets.bottom, 12) + 10 }]}>
          <Tap
            onPress={() => {
              // A single-chat Project: back to its chat, the file in the composer.
              if (folder && singleChat(folder.kind)) {
                attachToChat(project, { path, view: null });
                router.back();
              } else
                router.replace({
                  pathname: "/compose",
                  params: { folder: project, text: `About ${path}: ` },
                });
            }}
            style={st.askButton}
            testID="chat-about-this"
          >
            <Text style={st.askText}>Chat about this</Text>
          </Tap>
        </View>
      ) : null}
    </View>
  );
}

const st = StyleSheet.create({
  screen: { flex: 1, backgroundColor: "#0f0f12" },
  head: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingHorizontal: 16,
    paddingTop: 6,
    paddingBottom: 12,
    borderBottomWidth: 1,
    borderBottomColor: "#222228",
  },
  name: { fontSize: 16, fontWeight: "600", color: color.text },
  where: { fontSize: 12, color: color.muted },
  outline: {
    height: 34,
    paddingHorizontal: 12,
    borderRadius: 9,
    borderWidth: 1,
    borderColor: color.outline,
    justifyContent: "center",
  },
  outlineText: { fontSize: 14, color: color.text },
  solid: {
    height: 34,
    paddingHorizontal: 14,
    borderRadius: 9,
    backgroundColor: color.textStrong,
    justifyContent: "center",
  },
  solidText: { fontSize: 14, fontWeight: "600", color: color.bg },
  done: { fontSize: 16, fontWeight: "600", color: color.accentText, paddingLeft: 6 },
  editor: {
    flex: 1,
    padding: 18,
    color: color.text,
    fontSize: 14,
    lineHeight: 22,
    fontFamily: font.mono,
    outlineStyle: "none",
  } as any,
  center: { flex: 1, alignItems: "center", justifyContent: "center", gap: 14 },
  faint: { fontSize: 13, color: color.muted },
  ask: { paddingHorizontal: 16, paddingTop: 10, borderTopWidth: 1, borderTopColor: "#222228" },
  askButton: {
    height: 48,
    borderRadius: 12,
    backgroundColor: color.accentWash,
    alignItems: "center",
    justifyContent: "center",
  },
  askText: { fontSize: 15, fontWeight: "600", color: color.accentText },
});
