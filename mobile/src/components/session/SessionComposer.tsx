import { useEffect, useRef, useState } from "react";
import {
  ActivityIndicator,
  Image,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import { Icon } from "../Icon";
import { PickSheet } from "../Sheet";
import { Tap } from "../ui";
import { useCommand } from "@/lib/commands";
import { bindingMatches } from "@/lib/keys";
import { getState } from "@/lib/peon";
import { fileToAttachment, pickImage, type Attachment } from "@/lib/images";
import { setVoiceSettings, useDictation, useVoiceSettings } from "@/lib/voice";
import { color, font } from "@/lib/theme";
import type { SessionOptions } from "@/lib/types";

type Completion = { key: string; label: string; detail?: string | null; insert: string };

type Props = {
  busy: boolean;
  /** A routine run is working: what you send waits for it. */
  queued?: boolean;
  options: SessionOptions | null;
  agent: string | null;
  model: string | null;
  bottomPad: number;
  send: (text: string, files: Attachment[]) => Promise<unknown>;
  findFiles: (query: string) => Promise<{ items: { path: string; type?: string }[] }>;
  setAgent: (agent: string) => Promise<unknown>;
  setModel: (model: string) => Promise<unknown>;
  onError: (message: string | null) => void;
};

// What the cursor is completing: "/name" at the start, or the "@path" being typed.
function completing(draft: string): { kind: "slash" | "file"; query: string } | null {
  const slash = /^\/([\w.-]*)$/.exec(draft);
  if (slash) return { kind: "slash", query: slash[1] };
  const at = /(^|\s)@([^\s]*)$/.exec(draft);
  if (at) return { kind: "file", query: at[2] };
  return null;
}

/** The reply box: text, `/` and `@` completion, images, agent and model, voice. */
const withCurrent = (list: string[], current: string) => (list.includes(current) ? list : [current, ...list]);

export function SessionComposer(p: Props) {
  const voice = useVoiceSettings();
  const [draft, setDraft] = useState("");
  const [files, setFiles] = useState<Attachment[]>([]);
  const [sending, setSending] = useState(false);
  const [found, setFound] = useState<Completion[]>([]);
  const [pick, setPick] = useState(0);
  const [picker, setPicker] = useState<"agent" | "model" | null>(null);
  const input = useRef<TextInput>(null);

  // <leader>m / <leader>a open the pickers from the keyboard.
  useCommand("session:model", () => setPicker("model"));
  useCommand("session:agent", () => setPicker("agent"));

  // Talking adds to what is typed; you look it over and send it yourself.
  const join = (a: string, b: string) => (a.trim() && b ? `${a.trimEnd()} ${b}` : a + b);
  const dictation = useDictation((text) => setDraft((d) => join(d, text)));
  const shown = dictation.listening ? join(draft, dictation.transcript) : draft;
  useCommand("session:send", () => send(draft));
  useCommand("session:talk", () => (dictation.listening ? dictation.stop() : dictation.start()));
  const what = dictation.listening ? null : completing(draft);

  // `/` completes from the session's skills and commands, `@` from its folder.
  const slash: Completion[] =
    what?.kind === "slash"
      ? (p.options?.slash ?? [])
          .filter((i) => i.name.toLowerCase().startsWith(what.query.toLowerCase()))
          .slice(0, 8)
          .map((i) => ({
            key: i.name,
            label: `/${i.name}`,
            detail: i.description ?? i.kind,
            insert: `/${i.name} `,
          }))
      : [];
  const fileQuery = what?.kind === "file" ? what.query : null;
  useEffect(() => {
    if (fileQuery == null) return;
    const t = setTimeout(() => {
      p.findFiles(fileQuery)
        .then((r) =>
          setFound(
            r.items.slice(0, 8).map((i) => ({
              key: i.path,
              label: i.path,
              detail: i.type === "directory" ? "folder" : null,
              insert: `@${i.path}${i.type === "directory" ? "/" : " "}`,
            })),
          ),
        )
        .catch(() => setFound([]));
    }, 150);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fileQuery]);
  const items = what?.kind === "slash" ? slash : what?.kind === "file" ? found : [];

  function complete(c: Completion) {
    setDraft(what?.kind === "file" ? draft.replace(/@[^\s]*$/, c.insert) : c.insert);
    setPick(0);
    input.current?.focus();
  }

  async function send(text: string) {
    const t = text.trim();
    if (!t && files.length === 0) return;
    setSending(true);
    p.onError(null);
    try {
      await p.send(t, files);
      setDraft("");
      setFiles([]);
    } catch (e: any) {
      p.onError(e.message);
      setDraft(t);
    }
    setSending(false);
  }
  // Web: paste or drop images onto the page.
  useEffect(() => {
    if (Platform.OS !== "web") return;
    const add = async (list: FileList | null | undefined) => {
      const images = Array.from(list ?? []).filter((f) => f.type.startsWith("image/"));
      if (!images.length) return false;
      const added = await Promise.all(images.map(fileToAttachment));
      setFiles((fs) => [...fs, ...added].slice(0, 6));
      return true;
    };
    const onPaste = (e: ClipboardEvent) => {
      if (e.clipboardData?.files?.length) {
        e.preventDefault();
        add(e.clipboardData.files);
      }
    };
    const onDragOver = (e: DragEvent) => e.preventDefault();
    const onDrop = (e: DragEvent) => {
      e.preventDefault();
      add(e.dataTransfer?.files);
    };
    document.addEventListener("paste", onPaste);
    document.addEventListener("dragover", onDragOver);
    document.addEventListener("drop", onDrop);
    return () => {
      document.removeEventListener("paste", onPaste);
      document.removeEventListener("dragover", onDragOver);
      document.removeEventListener("drop", onDrop);
    };
  }, []);

  async function attach() {
    try {
      const a = await pickImage();
      if (a) setFiles((fs) => [...fs, a].slice(0, 6));
    } catch (e: any) {
      p.onError(e.message);
    }
  }

  const canSend = (draft.trim() !== "" || files.length > 0) && !dictation.listening;
  const modelName =
    p.options?.models.find((m) => m.value === p.model)?.name ??
    (p.model ? p.model.split("/").pop() : "default model");

  return (
    <View style={[st.wrap, { paddingBottom: p.bottomPad }]}>
      {items.length ? (
        <View style={st.popover}>
          {items.map((c, i) => (
            <Pressable
              key={c.key}
              onPress={() => complete(c)}
              style={(s: any) => [st.option, (i === pick || s.hovered) && { backgroundColor: color.raised }]}
            >
              <Text style={st.optionLabel} numberOfLines={1}>
                {c.label}
              </Text>
              {c.detail ? (
                <Text style={st.optionDetail} numberOfLines={1}>
                  {c.detail}
                </Text>
              ) : null}
            </Pressable>
          ))}
        </View>
      ) : null}

      {files.length ? (
        <View style={st.files}>
          {files.map((f, i) => (
            <View key={i} style={st.thumbWrap}>
              <Image source={{ uri: f.uri }} style={st.thumb} />
              <Pressable
                style={st.remove}
                onPress={() => setFiles((fs) => fs.filter((_, j) => j !== i))}
                hitSlop={6}
              >
                <Icon name="close" size={10} color="#fff" />
              </Pressable>
            </View>
          ))}
        </View>
      ) : null}

      <View style={st.row}>
        <Tap style={[st.round, { backgroundColor: color.field }]} onPress={attach} testID="attach">
          <Text style={st.plus}>+</Text>
        </Tap>
        <TextInput
          ref={input}
          testID="reply"
          value={shown}
          onChangeText={(v) => {
            setDraft(v);
            setPick(0);
          }}
          editable={!dictation.listening}
          placeholder={
            dictation.listening
              ? "Listening…"
              : p.queued
                ? "Queue a follow-up…"
                : p.busy
                  ? "Follow up"
                  : "Reply, or / for commands and skills"
          }
          placeholderTextColor={dictation.listening ? color.accentText : color.faint}
          multiline
          onKeyPress={(e: any) => {
            const k = e.nativeEvent.key;
            if (items.length && (k === "ArrowDown" || k === "ArrowUp")) {
              e.preventDefault?.();
              setPick((i) => (i + (k === "ArrowDown" ? 1 : items.length - 1)) % items.length);
            } else if (items.length && (k === "Tab" || (k === "Enter" && !e.nativeEvent.shiftKey))) {
              e.preventDefault?.();
              complete(items[pick] ?? items[0]);
            } else if (Platform.OS === "web") {
              // Desktop: the composer keys from Settings (OpenCode's input_* and agent_cycle).
              const binds = getState().keys?.binds ?? {};
              const ev = e.nativeEvent;
              const is = (action: string, fallback: string) => bindingMatches(ev, binds[action] ?? fallback);
              if (is("input_newline", "shift+return,alt+return,ctrl+j")) {
                e.preventDefault?.();
                setDraft((d) => d + "\n");
              } else if (is("input_submit", "return")) {
                e.preventDefault?.();
                send(draft);
              } else if (
                is("input_clear", "ctrl+c") &&
                // Native has no window.getSelection.
                !(Platform.OS === "web" && window.getSelection()?.toString())
              ) {
                e.preventDefault?.();
                setDraft("");
              } else if (is("agent_cycle", "tab") || is("agent_cycle_reverse", "shift+tab")) {
                const agents = p.options?.agents ?? [];
                if (agents.length) {
                  e.preventDefault?.();
                  const step = is("agent_cycle_reverse", "shift+tab") ? -1 : 1;
                  const i = Math.max(0, agents.indexOf(p.agent ?? "build"));
                  p.setAgent(agents[(i + step + agents.length) % agents.length]).catch((err) =>
                    p.onError(err.message),
                  );
                }
              }
            }
          }}
          style={[st.input, dictation.listening && { borderColor: color.accent, borderWidth: 1 }]}
        />
        <Tap
          hitSlop={6}
          onPress={() => setVoiceSettings({ reply: !voice.reply })}
          style={[st.round, { backgroundColor: voice.reply ? color.accentWash : color.field }]}
          testID="voice-reply"
        >
          <Icon name="speaker" size={16} color={voice.reply ? color.accentText : color.muted} />
        </Tap>
        {canSend ? (
          <Tap haptic style={[st.round, st.go]} onPress={() => send(draft)} disabled={sending} testID="send">
            {sending ? (
              <ActivityIndicator color={color.accentInk} />
            ) : (
              <Icon name="send" size={18} color={color.accentInk} />
            )}
          </Tap>
        ) : (
          <Tap
            haptic
            testID="mic"
            style={[st.round, st.go, dictation.listening && { backgroundColor: color.textStrong }]}
            onPress={() => (dictation.listening ? dictation.stop() : dictation.start())}
          >
            <Icon
              name={dictation.listening ? "stop" : "mic"}
              size={dictation.listening ? 14 : 18}
              color={color.accentInk}
            />
          </Tap>
        )}
      </View>

      <View style={st.chips}>
        <Pressable
          testID="agent-chip"
          onPress={() => setPicker("agent")}
          style={(s: any) => [st.chip, s.hovered && { backgroundColor: color.raised }]}
        >
          <Text style={st.chipText}>{p.agent ?? "build"} ⇅</Text>
        </Pressable>
        <Pressable
          testID="model-chip"
          onPress={() => setPicker("model")}
          style={(s: any) => [st.chip, s.hovered && { backgroundColor: color.raised }]}
        >
          <Text style={st.chipText} numberOfLines={1}>
            {modelName} ⇅
          </Text>
        </Pressable>
        {dictation.error ? <Text style={[st.chipText, { color: color.red }]}>{dictation.error}</Text> : null}
      </View>

      <PickSheet
        visible={picker === "agent"}
        title="Agent"
        // The current agent is listed even when it isn't one of the options (like the web).
        items={withCurrent(p.options?.agents ?? [], p.agent ?? "build").map((a) => ({
          key: a,
          label: a,
          active: a === (p.agent ?? "build"),
        }))}
        onClose={() => setPicker(null)}
        onPick={(a) => {
          setPicker(null);
          p.setAgent(a).catch((e) => p.onError(e.message));
        }}
      />
      <PickSheet
        visible={picker === "model"}
        title="Model"
        items={(p.model && !(p.options?.models ?? []).some((m) => m.value === p.model)
          ? [{ value: p.model, name: p.model }, ...(p.options?.models ?? [])]
          : (p.options?.models ?? [])
        ).map((m) => ({
          key: m.value,
          label: m.name,
          detail: m.value,
          active: m.value === p.model,
        }))}
        onClose={() => setPicker(null)}
        onPick={(m) => {
          setPicker(null);
          p.setModel(m).catch((e) => p.onError(e.message));
        }}
      />
    </View>
  );
}

const st = StyleSheet.create({
  wrap: {
    paddingHorizontal: 14,
    paddingTop: 10,
    gap: 6,
    borderTopWidth: 1,
    borderTopColor: color.hairline,
    position: "relative",
  },
  row: { flexDirection: "row", alignItems: "flex-end", gap: 8 },
  input: {
    flex: 1,
    minHeight: 44,
    maxHeight: 160,
    borderRadius: 22,
    backgroundColor: color.field,
    paddingHorizontal: 16,
    paddingTop: 12,
    paddingBottom: 12,
    color: color.text,
    fontSize: 15,
    outlineStyle: "none",
  } as any,
  round: { width: 44, height: 44, borderRadius: 22, alignItems: "center", justifyContent: "center" },
  go: { backgroundColor: color.accent },
  plus: { fontSize: 22, color: color.textDim, marginTop: -2 },
  chips: { flexDirection: "row", gap: 6, paddingLeft: 52, alignItems: "center" },
  chip: { paddingHorizontal: 8, height: 24, borderRadius: 6, justifyContent: "center", maxWidth: 220 },
  chipText: { fontSize: 12, color: color.muted },
  files: { flexDirection: "row", gap: 8, paddingLeft: 52 },
  thumbWrap: { position: "relative" },
  thumb: { width: 56, height: 56, borderRadius: 8, backgroundColor: color.field },
  remove: {
    position: "absolute",
    top: -6,
    right: -6,
    width: 18,
    height: 18,
    borderRadius: 9,
    backgroundColor: color.ghost,
    alignItems: "center",
    justifyContent: "center",
  },
  popover: {
    position: "absolute",
    bottom: "100%",
    left: 66,
    right: 14,
    marginBottom: 6,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: color.card,
    padding: 4,
    zIndex: 20,
  },
  option: {
    flexDirection: "row",
    gap: 10,
    alignItems: "center",
    paddingHorizontal: 10,
    paddingVertical: 8,
    borderRadius: 8,
  },
  optionLabel: { fontSize: 13.5, color: color.text, fontFamily: font.mono, flexShrink: 1 },
  optionDetail: { fontSize: 12, color: color.muted, flex: 1 },
});
