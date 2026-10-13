import { useEffect, useRef, useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { useKeyboardHeight } from "@/lib/useKeyboard";
import { useWide } from "@/lib/useWide";
import { router, useLocalSearchParams } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Icon } from "@/components/Icon";
import { Letter } from "@/components/desktop/Sidebar";
import { ErrorLine, Tap } from "@/components/ui";
import { getCurrent } from "@/lib/current";
import { newFolderName, templates } from "@/lib/folders";
import { ask, usePeon } from "@/lib/peon";
import { useDictation, useVoiceSettings } from "@/lib/voice";
import { color } from "@/lib/theme";
import type { Project } from "@/lib/types";

const folderName = (p: Project) => (p.kind === "home" ? "Home" : p.name);

// Templates you can start a chat in straight away: the chat makes the Project.
const fresh = templates.filter((t) => ["design", "document", "dataset"].includes(t.kind));

/** `@folder` picks a Project, `/skill` a skill; the rest is the task. */
function parse(text: string, projects: Project[]) {
  const at = /@([\w-]+)/.exec(text)?.[1]?.toLowerCase();
  const mentioned = at
    ? projects.find((p) => p.name.startsWith(at) || (p.kind === "home" && "home".startsWith(at)))
    : undefined;
  const skill = /(?:^|\s)\/([\w-]+)/.exec(text)?.[1] ?? null;
  const task = text
    .replace(/@[\w-]*/g, " ")
    .replace(/(?:^|\s)\/[\w-]*/g, " ")
    .replace(/\s{2,}/g, " ")
    .trim();
  return { mentioned, skill, task };
}

// New chat: a sheet over whatever you were looking at. It goes to the Project
// you're in (or one you pick or @mention), else Home. "+ Design" and the like
// make a new Project from that template first.
export default function Compose() {
  const params = useLocalSearchParams<{ folder?: string; listen?: string; text?: string }>();
  const insets = useSafeAreaInsets();
  const keyboard = useKeyboardHeight();
  const wide = useWide();
  const projects = usePeon((s) => s.projects);
  const [text, setText] = useState(params.text ?? "");
  const [picked, setPicked] = useState<number | null>(params.folder ? Number(params.folder) : null);
  const [kind, setKind] = useState<Project["kind"] | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const input = useRef<TextInput>(null);
  const join = (a: string, b: string) => (a.trim() && b ? `${a.trimEnd()} ${b}` : a + b);
  const voice = useVoiceSettings();
  const dictation = useDictation((spoken) => setText((t) => join(t, spoken)));
  const line = dictation.listening ? join(text, dictation.transcript) : text;

  useEffect(() => {
    if (params.listen) dictation.start();
    else setTimeout(() => input.current?.focus(), 250);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const here = projects.find((p) => p.id === getCurrent().projectId);
  const home = projects.find((p) => p.kind === "home");
  const { mentioned, skill, task } = parse(line, projects);
  const chosen = projects.find((p) => p.id === picked);
  // A new Project from a template, unless an @mention says otherwise.
  const template = mentioned ? null : fresh.find((t) => t.kind === kind);
  const newName = template ? newFolderName(task, template.kind, projects) : null;
  const folder = template ? undefined : (mentioned ?? chosen ?? here ?? home ?? projects[0]);
  const note = mentioned || chosen ? "" : folder === here ? "current" : "default";
  const chips = [here, home, ...projects.filter((p) => p.kind !== "home" && p.kind !== "system")]
    .filter((p, i, all): p is Project => p != null && all.findIndex((q) => q?.id === p.id) === i)
    .slice(0, 6);

  async function start() {
    if ((!folder && !template) || !task) return;
    setBusy(true);
    setError(null);
    try {
      const projectId = template
        ? (
            await ask<{ project_id: number }>(
              "create_project",
              {
                params: {
                  kind: template.kind,
                  name: newName,
                  scope: "private",
                  ...(template.kind === "dataset" ? { description: task } : {}),
                },
              },
              180000,
            )
          ).project_id
        : folder!.id;
      const { session_id } = await ask<{ session_id: string }>(
        "new_session",
        { project_id: projectId, text: skill ? `/${skill} ${task}` : task },
        60000,
      );
      router.replace(`/session/${session_id}`);
    } catch (e: any) {
      setError(e.message);
      setBusy(false);
    }
  }

  return (
    <View style={[st.backdrop, wide && st.backdropWide]}>
      <Pressable style={wide ? StyleSheet.absoluteFill : { flex: 1 }} onPress={() => router.back()} />
      <View
        style={[
          st.sheet,
          wide
            ? st.sheetWide
            : { paddingBottom: keyboard > 0 ? keyboard + 16 : Math.max(insets.bottom, 16) + 20 },
        ]}
      >
        {wide ? null : <View style={st.grabber} />}
        <View style={st.head}>
          <Text style={st.title}>New chat</Text>
          <Tap onPress={() => router.back()} hitSlop={10}>
            <Text style={st.cancel}>Cancel</Text>
          </Tap>
        </View>

        <TextInput
          ref={input}
          testID="compose-input"
          value={line}
          onChangeText={setText}
          editable={!dictation.listening}
          placeholder={dictation.listening ? "Listening…" : "What should the agent do?"}
          placeholderTextColor={dictation.listening ? color.accentText : "#62626b"}
          multiline
          style={[st.box, dictation.listening && { borderColor: color.accent }]}
        />

        <ScrollView
          horizontal
          showsHorizontalScrollIndicator={false}
          style={st.chipsWrap}
          contentContainerStyle={st.chips}
          keyboardShouldPersistTaps="handled"
        >
          {chips.map((p) => {
            const on = p.id === folder?.id;
            return (
              <Tap
                key={p.id}
                onPress={() => {
                  setPicked(p.id);
                  setKind(null);
                }}
                style={[st.chip, on && st.chipOn]}
              >
                <Letter name={folderName(p)} system={p.kind === "home"} size={20} />
                <Text style={st.chipText}>{folderName(p)}</Text>
              </Tap>
            );
          })}
        </ScrollView>
        <ScrollView
          horizontal
          showsHorizontalScrollIndicator={false}
          style={st.chipsWrap}
          contentContainerStyle={st.chips}
          keyboardShouldPersistTaps="handled"
        >
          {fresh.map((t) => (
            <Tap
              key={t.kind}
              testID={`compose-new-${t.kind}`}
              onPress={() => setKind(kind === t.kind ? null : t.kind)}
              style={[st.chip, st.chipNew, template?.kind === t.kind && st.chipOn]}
            >
              <Text style={st.chipText}>+ {t.label}</Text>
            </Tap>
          ))}
        </ScrollView>

        <View style={st.grid}>
          <View style={st.row}>
            <Text style={st.key}>Project</Text>
            {template ? (
              <Text style={st.val}>
                New {template.label} <Text style={st.faint}>{newName}</Text>
              </Text>
            ) : (
              <Text style={st.val}>
                {folder ? folderName(folder) : "—"} {note ? <Text style={st.faint}>{note}</Text> : null}
              </Text>
            )}
          </View>
          <View style={st.row}>
            <Text style={st.key}>Skill</Text>
            <Text style={[st.val, !skill && st.faint]}>{skill ? `/${skill}` : "None · type /"}</Text>
          </View>
          <View style={st.row}>
            <Text style={st.key}>Task</Text>
            <Text style={[st.val, { color: task ? color.textSoft : color.faint }]}>{task || "…"}</Text>
          </View>
        </View>
        <ErrorLine message={error ?? dictation.error} />

        <View style={st.actions}>
          {voice.dictation ? (
            <Tap
              testID="compose-mic"
              style={[st.mic, dictation.listening && { backgroundColor: color.accentWash }]}
              onPress={() => (dictation.listening ? dictation.stop() : dictation.start())}
            >
              <Icon
                name={dictation.listening ? "stop" : "mic"}
                size={dictation.listening ? 14 : 18}
                color={dictation.listening ? color.accentText : color.textDim}
              />
            </Tap>
          ) : null}
          <Tap
            testID="compose-go"
            haptic
            onPress={start}
            disabled={busy || !task || (!folder && !template)}
            style={[st.go, (!task || (!folder && !template)) && { opacity: 0.4 }]}
          >
            <Text style={st.goText}>{busy ? "Starting…" : "Start chat"}</Text>
          </Tap>
        </View>
      </View>
    </View>
  );
}

const st = StyleSheet.create({
  backdrop: { flex: 1, backgroundColor: "rgba(0,0,0,0.55)" },
  // Web: a card in the middle instead of a sheet from the bottom.
  backdropWide: { alignItems: "center", justifyContent: "center" },
  sheetWide: {
    width: 560,
    maxWidth: "92%",
    borderRadius: 16,
    padding: 22,
    borderWidth: 1,
    borderColor: color.border,
  },
  sheet: {
    borderTopLeftRadius: 28,
    borderTopRightRadius: 28,
    backgroundColor: color.card,
    paddingHorizontal: 18,
    paddingTop: 10,
    gap: 14,
  },
  grabber: { alignSelf: "center", width: 36, height: 5, borderRadius: 3, backgroundColor: color.ghost },
  head: { flexDirection: "row", justifyContent: "space-between", alignItems: "center" },
  title: { fontSize: 17, fontWeight: "600", color: color.text },
  cancel: { fontSize: 16, color: color.muted },
  box: {
    minHeight: 104,
    borderRadius: 14,
    backgroundColor: color.bg,
    borderWidth: 1,
    borderColor: color.border,
    padding: 14,
    fontSize: 16,
    lineHeight: 23,
    color: color.text,
    textAlignVertical: "top",
    outlineStyle: "none",
  } as any,
  chipsWrap: { marginHorizontal: -18, flexGrow: 0 },
  chips: { gap: 6, paddingHorizontal: 18 },
  chip: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    height: 34,
    paddingLeft: 6,
    paddingRight: 12,
    borderRadius: 17,
    borderWidth: 1,
    borderColor: color.border,
  },
  chipOn: { backgroundColor: color.accentWash, borderColor: color.accentBorder },
  chipNew: { paddingLeft: 12, borderStyle: "dashed" },
  chipText: { fontSize: 14, color: color.text },
  grid: { gap: 9 },
  row: { flexDirection: "row", gap: 12 },
  key: { width: 64, fontSize: 14, color: color.faint },
  val: { flex: 1, fontSize: 14, color: color.text },
  faint: { color: color.faint },
  actions: { flexDirection: "row", gap: 10, alignItems: "center" },
  mic: {
    width: 44,
    height: 44,
    borderRadius: 12,
    backgroundColor: color.raised,
    alignItems: "center",
    justifyContent: "center",
  },
  go: {
    flex: 1,
    height: 44,
    borderRadius: 12,
    backgroundColor: color.textStrong,
    alignItems: "center",
    justifyContent: "center",
  },
  goText: { fontSize: 15, fontWeight: "600", color: color.bg },
});
