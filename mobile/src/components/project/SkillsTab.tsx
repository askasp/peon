import { useEffect, useState } from "react";
import { ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { Button, ErrorLine, Loading, Tap } from "../ui";
import { useLoad } from "@/lib/useLoad";
import { useWide } from "@/lib/useWide";
import { color, font } from "@/lib/theme";
import type { ProjectCtx } from "./types";

type File = { name: string; path: string };

/** AGENTS.md and the project's skills, each editable as text. */
export function SkillsTab({ ctx }: { ctx: ProjectCtx }) {
  const wide = useWide();
  const [path, setPath] = useState("AGENTS.md");
  const [content, setContent] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);
  const [newName, setNewName] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [version, setVersion] = useState(0);
  const { data: files } = useLoad(
    () => ctx.call<{ files: File[] }>("skills").then((r) => r.files),
    [version],
  );

  useEffect(() => {
    let live = true;
    ctx
      .call<{ content: string }>("read_file", { path })
      .then((r) => {
        if (!live) return;
        setContent(r.content);
        setSaved(r.content);
      })
      .catch((e) => live && setError(e.message));
    return () => {
      live = false;
    };
  }, [path, ctx]);

  const open = (p: string) => {
    setContent(null);
    setNote(null);
    setError(null);
    setPath(p);
  };

  async function save() {
    setBusy(true);
    setError(null);
    try {
      await ctx.call("save_file", { path, content: content ?? "" });
      setSaved(content);
      setNote(`Saved ${path}.`);
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(false);
  }

  async function create() {
    setBusy(true);
    setError(null);
    try {
      const r = await ctx.call<{ path: string }>("create_skill", { name: newName ?? "" });
      setNewName(null);
      setVersion((v) => v + 1);
      open(r.path);
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(false);
  }

  const dirty = content != null && content !== saved;

  return (
    <View style={[st.wrap, wide && { flexDirection: "row" }]}>
      <ScrollView
        horizontal={!wide}
        style={wide ? st.listWide : st.list}
        contentContainerStyle={
          wide ? { gap: 2, padding: 8 } : { gap: 6, paddingHorizontal: 18, paddingBottom: 8 }
        }
        showsHorizontalScrollIndicator={false}
      >
        {(files ?? []).map((f) => (
          <Tap key={f.path} onPress={() => open(f.path)} style={[st.file, f.path === path && st.fileOn]}>
            <Text style={[st.fileText, f.path === path && { color: color.textStrong }]} numberOfLines={1}>
              {f.path === "AGENTS.md" ? "AGENTS.md" : `/${f.name}`}
            </Text>
          </Tap>
        ))}
        {newName == null ? (
          <Tap onPress={() => setNewName("")} style={st.file}>
            <Text style={[st.fileText, { color: color.accentText }]}>+ New skill</Text>
          </Tap>
        ) : (
          <View style={st.newRow}>
            <TextInput
              value={newName}
              onChangeText={setNewName}
              placeholder="skill-name"
              placeholderTextColor={color.faint}
              autoFocus
              autoCapitalize="none"
              onSubmitEditing={create}
              style={st.newInput}
            />
            <Button label="Create" height={32} busy={busy} onPress={create} />
          </View>
        )}
      </ScrollView>

      <View style={st.editor}>
        <View style={st.editorHead}>
          <Text style={st.path} numberOfLines={1}>
            {path}
          </Text>
          <Button label={dirty ? "Save" : "Saved"} height={32} disabled={!dirty} busy={busy} onPress={save} />
        </View>
        <ErrorLine message={error} />
        {note && !dirty ? <Text style={st.note}>{note}</Text> : null}
        {content == null ? (
          <Loading />
        ) : (
          <TextInput
            testID="file-editor"
            value={content}
            onChangeText={setContent}
            multiline
            autoCapitalize="none"
            autoCorrect={false}
            spellCheck={false}
            textAlignVertical="top"
            style={st.text}
          />
        )}
        {files == null ? <Loading /> : null}
      </View>
    </View>
  );
}

const st = StyleSheet.create({
  wrap: { flex: 1, minHeight: 0 },
  list: { flexGrow: 0 },
  listWide: { width: 220, flexGrow: 0, borderRightWidth: 1, borderRightColor: color.hairline },
  file: { paddingHorizontal: 10, paddingVertical: 7, borderRadius: 8, backgroundColor: color.card },
  fileOn: { backgroundColor: color.raised },
  fileText: { fontSize: 13, color: color.textSoft, fontFamily: font.mono },
  newRow: { flexDirection: "row", gap: 6, alignItems: "center" },
  newInput: {
    minWidth: 120,
    height: 32,
    borderRadius: 8,
    backgroundColor: color.field,
    paddingHorizontal: 10,
    color: color.text,
    fontSize: 13,
    fontFamily: font.mono,
  },
  editor: { flex: 1, padding: 14, gap: 8, minHeight: 0 },
  editorHead: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", gap: 10 },
  path: { flex: 1, fontSize: 13, color: color.textDim, fontFamily: font.mono },
  note: { fontSize: 13, color: color.teal },
  text: {
    flex: 1,
    minHeight: 320,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: color.bgDeep,
    padding: 12,
    color: color.text,
    fontSize: 13,
    lineHeight: 19,
    fontFamily: font.mono,
    outlineStyle: "none",
  } as any,
});
