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
import { Completions, useCompletions } from "../Completions";
import { Tap } from "../ui";
import { useCommand } from "@/lib/commands";
import { bindingMatches } from "@/lib/keys";
import { getState } from "@/lib/peon";
import { fileToAttachment, pickImage, type Attachment } from "@/lib/images";
import { attachedText, type Attached } from "@/lib/attach";
import { viewFor, viewInfo } from "@/lib/folders";
import { useDictation, useVoiceSettings } from "@/lib/voice";
import { useWide } from "@/lib/useWide";
import { color, font } from "@/lib/theme";
import type { SessionOptions } from "@/lib/types";

type Props = {
  busy: boolean;
  /** A routine run is working: what you send waits for it. */
  queued?: boolean;
  options: SessionOptions | null;
  agent: string | null;
  model: string | null;
  /** How hard the model thinks; null is the model's default. */
  variant: string | null;
  bottomPad: number;
  send: (text: string, files: Attachment[]) => Promise<unknown>;
  findFiles: (query: string) => Promise<{ items: { path: string; type?: string }[] }>;
  setAgent: (agent: string) => Promise<unknown>;
  setModel: (model: string, variant?: string | null) => Promise<unknown>;
  onError: (message: string | null) => void;
  /** "Chat about this": a file shown as a chip, sent as an @mention with the message. */
  attached?: Attached | null;
  onDetach?: () => void;
  /** The chip is what's in view, so it stays after a send. */
  keepAttached?: boolean;
};

/** The reply box: text, `/` and `@` completion, images, agent and model, voice. */
const withCurrent = (list: string[], current: string) => (list.includes(current) ? list : [current, ...list]);

export function SessionComposer(p: Props) {
  const [draft, setDraft] = useState("");
  const [files, setFiles] = useState<Attachment[]>([]);
  const [sending, setSending] = useState(false);
  const [picker, setPicker] = useState<"agent" | "model" | "thinking" | null>(null);
  const input = useRef<TextInput>(null);

  // <leader>m / <leader>a open the pickers from the keyboard.
  useCommand("session:model", () => setPicker("model"));
  useCommand("session:agent", () => setPicker("agent"));

  // Talking adds to what is typed; you look it over and send it yourself.
  const join = (a: string, b: string) => (a.trim() && b ? `${a.trimEnd()} ${b}` : a + b);
  const voice = useVoiceSettings();
  const dictation = useDictation((text) => setDraft((d) => join(d, text)));
  const shown = dictation.listening ? join(draft, dictation.transcript) : draft;
  useCommand("session:send", () => send(draft));
  useCommand("session:talk", () => (dictation.listening ? dictation.stop() : dictation.start()));
  // `/` completes from the session's skills and commands, `@` from its folder.
  const { items, pick, setPick, complete, onKey } = useCompletions({
    draft,
    setDraft,
    slash: p.options?.slash,
    findFiles: p.findFiles,
    input,
    off: dictation.listening,
  });

  // A file attached from Files: type about it straight away.
  useEffect(() => {
    if (p.attached && !p.keepAttached) input.current?.focus();
  }, [p.attached, p.keepAttached]);

  async function send(text: string) {
    const t = text.trim();
    if (!t && files.length === 0) return;
    setSending(true);
    p.onError(null);
    try {
      await p.send(p.attached ? attachedText(p.attached, t) : t, files);
      setDraft("");
      setFiles([]);
      if (!p.keepAttached) p.onDetach?.();
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
  const current = p.model
    ? p.options?.models.find((m) => m.value === p.model)
    : (p.options?.models.find((m) => m.value === p.options?.default?.value) ?? p.options?.default);
  const modelName =
    current?.name ?? (p.model ? p.model.split("/").pop() : (p.options?.default?.name ?? "default model"));
  // Only models that can think harder or less get the Thinking chip.
  const levels = current?.variants ?? [];
  const thinking = p.variant ?? current?.variant ?? null;
  const modelValue = p.model ?? current?.value ?? null;

  const wide = useWide();

  const field = (
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
              : "Message"
      }
      placeholderTextColor={dictation.listening ? color.accentText : color.faint}
      multiline
      onKeyPress={(e: any) => {
        if (onKey(e)) return;
        if (Platform.OS === "web") {
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
      style={st.input}
    />
  );

  const mic = voice.dictation ? (
    <Tap
      hitSlop={6}
      testID="mic"
      style={[st.mic, dictation.listening && { backgroundColor: color.accentWash }]}
      onPress={() => (dictation.listening ? dictation.stop() : dictation.start())}
    >
      <Icon
        name={dictation.listening ? "stop" : "mic"}
        size={dictation.listening ? 12 : 16}
        color={dictation.listening ? color.accentText : color.muted}
      />
    </Tap>
  ) : null;

  // The + sits inside the box, on both the web and the phone.
  const addButton = (
    <Tap style={st.side} onPress={attach} testID="attach" aria-label="Add a file">
      <Text style={st.sidePlus}>+</Text>
    </Tap>
  );

  // Only the phone shows a send button; the web sends on Enter.
  const sendButton = (
    <Tap
      haptic
      style={[st.side, canSend ? st.sideGo : { backgroundColor: color.raised }]}
      onPress={() => send(draft)}
      disabled={sending || !canSend}
      testID="send"
      aria-label="Send"
    >
      {sending ? (
        <ActivityIndicator size="small" color={color.textDim} />
      ) : (
        <Icon name="send" size={16} color={canSend ? color.accentInk : color.faint} />
      )}
    </Tap>
  );

  return (
    <View style={[st.wrap, { paddingBottom: p.bottomPad }]}>
      <Completions items={items} pick={pick} onPick={complete} style={st.popover} />

      {p.attached ? (
        <View style={[st.attachedRow, !wide && st.rowIn]}>
          <View style={st.attached} testID="attached">
            <View style={st.attachedGlyph}>
              <Text style={st.attachedGlyphText}>{viewInfo[viewFor(p.attached.path)][1]}</Text>
            </View>
            <Text style={st.attachedPath} numberOfLines={1}>
              {p.attached.path}
            </Text>
            {p.attached.view ? <Text style={st.attachedView}>· {p.attached.view}</Text> : null}
            <Tap onPress={p.onDetach} hitSlop={8} aria-label="Remove the file">
              <Icon name="close" size={11} color={color.faint} />
            </Tap>
          </View>
        </View>
      ) : null}

      {files.length ? (
        <View style={[st.files, !wide && st.rowIn]}>
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
        <View style={[st.pill, st.pillFull]}>
          {addButton}
          {field}
          {mic}
          {wide ? null : sendButton}
        </View>
      </View>

      <View style={[st.chips, !wide && st.rowIn]}>
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
        {levels.length && modelValue ? (
          <Pressable
            testID="thinking-chip"
            onPress={() => setPicker("thinking")}
            style={(s: any) => [st.chip, s.hovered && { backgroundColor: color.raised }]}
          >
            <Text style={st.chipText} numberOfLines={1}>
              Thinking: {thinking ?? "default"} ⇅
            </Text>
          </Pressable>
        ) : null}
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
        )
          .map((m) => ({
            key: m.value,
            label: m.name,
            detail: m.value === p.options?.default?.value ? `${m.value} · default` : m.value,
            active: p.model ? m.value === p.model : m.value === p.options?.default?.value,
          }))
          // The one in use first.
          .sort((a, b) => Number(b.active) - Number(a.active))}
        onClose={() => setPicker(null)}
        onPick={(m) => {
          setPicker(null);
          // Keep the thinking level when the new model has it too.
          const next = p.options?.models.find((o) => o.value === m);
          const keep = p.variant && next?.variants?.includes(p.variant) ? p.variant : null;
          p.setModel(m, keep).catch((e) => p.onError(e.message));
        }}
      />
      <PickSheet
        visible={picker === "thinking"}
        title="Thinking"
        items={[
          { key: "", label: "Default", detail: "What the model picks", active: p.variant == null },
          ...levels.map((v) => ({ key: v, label: v, active: v === p.variant })),
        ]}
        onClose={() => setPicker(null)}
        onPick={(v) => {
          setPicker(null);
          if (modelValue) p.setModel(modelValue, v || null).catch((e) => p.onError(e.message));
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
  pill: {
    flex: 1,
    flexDirection: "row",
    alignItems: "flex-end",
    minHeight: 44,
    borderRadius: 22,
    backgroundColor: color.field,
    paddingRight: 5,
  },
  mic: {
    width: 34,
    height: 34,
    borderRadius: 17,
    marginBottom: 5,
    alignItems: "center",
    justifyContent: "center",
  },
  input: {
    flex: 1,
    minHeight: 44,
    maxHeight: 160,
    paddingHorizontal: 16,
    paddingTop: 12,
    paddingBottom: 12,
    color: color.text,
    fontSize: 15,
    outlineStyle: "none",
  } as any,
  // The + and send live inside the box, small, so it fills the width.
  pillFull: { paddingLeft: 5 },
  side: {
    width: 32,
    height: 32,
    borderRadius: 16,
    marginBottom: 6,
    alignItems: "center",
    justifyContent: "center",
  },
  sidePlus: { fontSize: 20, color: color.textDim, marginTop: -1 },
  sideGo: { backgroundColor: color.accent },
  chips: { flexDirection: "row", gap: 6, paddingLeft: 52, alignItems: "center" },
  chip: { paddingHorizontal: 8, height: 24, borderRadius: 6, justifyContent: "center", maxWidth: 220 },
  chipText: { fontSize: 12, color: color.muted },
  files: { flexDirection: "row", gap: 8, paddingLeft: 52 },
  attachedRow: { flexDirection: "row", paddingLeft: 52 },
  attached: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    maxWidth: "100%",
    paddingVertical: 5,
    paddingLeft: 6,
    paddingRight: 8,
    borderRadius: 8,
    backgroundColor: "#24242a",
  },
  attachedGlyph: {
    width: 22,
    height: 22,
    borderRadius: 5,
    backgroundColor: color.cream,
    alignItems: "center",
    justifyContent: "center",
  },
  attachedGlyphText: { fontSize: 10, fontWeight: "700", color: "#24493a" },
  attachedPath: { flexShrink: 1, fontSize: 12, fontFamily: font.mono, color: color.text },
  attachedView: { fontSize: 12, color: color.muted },
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
  rowIn: { paddingLeft: 8 },
  popover: { bottom: "100%", left: 66, right: 14, marginBottom: 6 },
});
