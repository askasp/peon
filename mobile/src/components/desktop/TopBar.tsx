import { useEffect, useRef, useState } from "react";
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { Icon, Mark } from "../Icon";
import { Button, ErrorLine } from "../ui";
import { ComposerOutput } from "../ComposerOutput";
import { usePaletteItems, type Item } from "./Palette";
import { useCommand } from "@/lib/commands";
import { isMac } from "@/lib/keys";
import { usePeon } from "@/lib/peon";
import { useComposer } from "@/lib/useComposer";
import { setVoiceSettings, useDictation, useVoiceSettings } from "@/lib/voice";
import { color, font } from "@/lib/theme";

// One bar for everything: type (or talk) a task and Enter starts it; start with
// ">" for commands; empty, it lists what's running. Below it, how Peon reads the line.
function CommandBar() {
  const [text, setText] = useState("");
  const [focused, setFocused] = useState(false);
  const [index, setIndex] = useState(0);
  const input = useRef<TextInput>(null);
  const voice = useVoiceSettings();
  // Talking adds to the line; Enter (or the button) starts it.
  const join = (a: string, b: string) => (a.trim() && b ? `${a.trimEnd()} ${b}` : a + b);
  const dictation = useDictation((spoken) => {
    setText((t) => join(t, spoken));
    input.current?.focus();
  });
  const line = dictation.listening ? join(text, dictation.transcript) : text;
  const command = line.startsWith(">");
  const task = !command && line.trim() !== "";

  const opener = useRef<(id: string) => void>(() => {});
  const open = (id: string) => opener.current(id);
  // Only a task goes to the composer; "> …" is filtered here.
  const c = useComposer(task ? line : "", open);

  const all = usePaletteItems("all");
  const places = usePaletteItems("switch");
  const filter = line.slice(1).trim().toLowerCase();
  const prefix = line.trim().toLowerCase();
  const [title, list]: [string, Item[]] = command
    ? [
        "Commands",
        all.filter(
          (i) => !filter || `${i.group} ${i.label} ${i.detail ?? ""}`.toLowerCase().includes(filter),
        ),
      ]
    : task
      ? [
          "Or jump to",
          prefix.length >= 2
            ? places.filter((i) => i.label.toLowerCase().startsWith(prefix)).slice(0, 3)
            : [],
        ]
      : [
          "Recent",
          [...all.filter((i) => i.group === "Running").slice(0, 4), ...all.filter((i) => i.key === "inbox")],
        ];
  // A task is picked first (index -1); arrows move into the list below it.
  const first = task ? -1 : 0;
  const at = Math.min(Math.max(index, first), list.length - 1);

  function clear() {
    setText("");
    setIndex(0);
    c.reset();
    input.current?.blur();
  }

  useCommand("composer:focus", () => {
    setText("");
    input.current?.focus();
  });
  useCommand("composer:commands", () => {
    setText(">");
    setIndex(0);
    input.current?.focus();
  });
  useCommand("composer:talk", () => (dictation.listening ? dictation.stop() : dictation.start()));
  useEffect(() => {
    opener.current = (id) => {
      clear();
      router.navigate(`/session/${id}`);
    };
  });

  function pick(item: Item | undefined) {
    if (!item) return;
    clear();
    item.run();
  }

  const result = c.busy || c.answer || c.note || c.error || c.plan;
  const open_ = focused || (task && result) || !!dictation.error;
  const voiceLabel = voice.reply ? "Voice reply" : "Text reply";

  return (
    <View style={st.barWrap}>
      <View style={[st.bar, (focused || dictation.listening) && { borderColor: color.accent }]}>
        <Text style={[st.mode, command ? st.modeCommand : st.modeTask]}>{command ? ">" : "Task"}</Text>
        <TextInput
          ref={input}
          testID="top-composer"
          value={line}
          onChangeText={(v) => {
            setText(v);
            setIndex(0);
            c.edited();
          }}
          onFocus={() => setFocused(true)}
          onBlur={() => setTimeout(() => setFocused(false), 150)}
          onKeyPress={(e: any) => {
            const k = e.nativeEvent.key;
            if (k === "Escape") {
              e.preventDefault?.();
              clear();
            } else if (k === "ArrowDown" || k === "ArrowUp") {
              e.preventDefault?.();
              setIndex(Math.min(list.length - 1, Math.max(first, at + (k === "ArrowDown" ? 1 : -1))));
            } else if (k === "Enter") {
              e.preventDefault?.();
              if (task && at === -1) c.submit(line);
              else pick(list[at]);
            }
          }}
          placeholder="Start a task, or type > for commands"
          placeholderTextColor={color.faint}
          style={st.input}
        />
        <Text style={st.kbd}>{isMac ? "⌘K" : "Ctrl+K"}</Text>
        <Pressable
          testID="top-voice-reply"
          onPress={() => setVoiceSettings({ reply: !voice.reply })}
          style={(s: any) => [
            st.chip,
            voice.reply && { backgroundColor: color.accentWash },
            s.hovered && !voice.reply && { backgroundColor: color.raised },
          ]}
        >
          <Icon name="speaker" size={13} color={voice.reply ? color.accentText : color.muted} />
          <Text style={[st.chipText, { color: voice.reply ? color.accentText : color.muted }]}>
            {voiceLabel}
          </Text>
        </Pressable>
        <Pressable
          testID="top-mic"
          accessibilityLabel="Talk"
          onPress={() => (dictation.listening ? dictation.stop() : dictation.start())}
          style={(s: any) => [
            st.mic,
            dictation.listening && { backgroundColor: color.cream },
            s.hovered && { opacity: 0.85 },
          ]}
        >
          <Icon name={dictation.listening ? "stop" : "mic"} size={14} color={color.accentInk} />
        </Pressable>
      </View>

      {open_ ? (
        // Clicks inside the panel shouldn't blur the bar first.
        <View style={st.panel} {...({ onMouseDown: (e: any) => e.preventDefault() } as object)}>
          {task || dictation.error ? (
            <View style={[st.task, list.length > 0 && st.taskDivider]}>
              {c.busy && !c.rows.length ? <ActivityIndicator color={color.muted} /> : null}
              <ComposerOutput
                plan={c.plan}
                rows={c.rows}
                answer={c.answer}
                note={c.note}
                unsure={c.unsure}
                busy={c.busy}
                open={open}
              />
              <ErrorLine message={c.error ?? dictation.error} />
              {task ? (
                <View style={st.taskFoot}>
                  <Text style={st.hint}>
                    @ project · / skill · {voice.reply ? "voice reply on" : "text reply"}
                  </Text>
                  <Button
                    label={`${c.button}  ↵`}
                    height={30}
                    busy={c.busy}
                    onPress={() => c.submit(line)}
                    testID="top-start"
                  />
                </View>
              ) : null}
            </View>
          ) : null}
          {list.length ? (
            <ScrollView style={{ maxHeight: 380 }} contentContainerStyle={{ padding: 6 }}>
              <Text style={st.listTitle}>{title}</Text>
              {list.map((item, i) => (
                <Pressable
                  key={item.key}
                  onPress={() => pick(item)}
                  onHoverIn={() => setIndex(i)}
                  style={[st.row, i === at && st.rowOn]}
                >
                  <Text style={st.kind} numberOfLines={1}>
                    {item.group}
                  </Text>
                  <Text style={st.label} numberOfLines={1}>
                    {item.label}
                  </Text>
                  <Text style={st.detail} numberOfLines={1}>
                    {item.detail ?? "↵"}
                  </Text>
                </Pressable>
              ))}
            </ScrollView>
          ) : command ? (
            <Text style={[st.hint, { padding: 16 }]}>No command matches.</Text>
          ) : null}
        </View>
      ) : null}
    </View>
  );
}

// Brand, the one bar in the middle, you on the right.
export function TopBar() {
  const user = usePeon((s) => s.user);

  return (
    <View style={st.top}>
      <View style={st.side}>
        <Mark size={28} />
        <Text style={st.word}>peon</Text>
      </View>
      <View style={st.center}>
        <CommandBar />
      </View>
      <View style={[st.side, { justifyContent: "flex-end" }]}>
        <Pressable
          testID="top-avatar"
          accessibilityLabel="Settings"
          onPress={() => router.navigate("/settings")}
          style={(s: any) => [st.avatar, s.hovered && { backgroundColor: color.pill }]}
        >
          <Text style={st.avatarText}>{(user?.username ?? "?").slice(0, 1).toUpperCase()}</Text>
        </Pressable>
      </View>
    </View>
  );
}

const st = StyleSheet.create({
  top: {
    height: 56,
    flexDirection: "row",
    alignItems: "center",
    gap: 16,
    paddingHorizontal: 16,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
    backgroundColor: color.bar,
    zIndex: 10,
  },
  side: { width: 208, flexDirection: "row", alignItems: "center", gap: 8, paddingLeft: 4 },
  word: { fontFamily: font.brand, fontSize: 22, letterSpacing: -0.9, color: color.text },
  center: { flex: 1, minWidth: 0, alignItems: "center" },
  barWrap: { width: "100%", maxWidth: 720, position: "relative" },
  bar: {
    height: 38,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: color.card,
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingLeft: 12,
    paddingRight: 5,
  },
  mode: {
    fontFamily: font.mono,
    fontSize: 12,
    fontWeight: "600",
    paddingHorizontal: 6,
    paddingVertical: 1,
    borderRadius: 4,
    overflow: "hidden",
  },
  modeTask: { backgroundColor: color.accentWash, color: color.accentText },
  modeCommand: { backgroundColor: color.raised, color: color.text },
  input: { flex: 1, minWidth: 0, height: 36, fontSize: 14, color: color.text, outlineStyle: "none" } as any,
  kbd: {
    fontSize: 11,
    fontFamily: font.mono,
    color: color.muted,
    borderWidth: 1,
    borderColor: color.outline,
    borderRadius: 4,
    paddingHorizontal: 6,
    paddingVertical: 1,
  },
  chip: {
    flexDirection: "row",
    alignItems: "center",
    gap: 5,
    paddingHorizontal: 8,
    height: 26,
    borderRadius: 6,
  },
  chipText: { fontSize: 12 },
  mic: {
    width: 28,
    height: 28,
    borderRadius: 7,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: color.accent,
  },
  panel: {
    position: "absolute",
    top: 46,
    left: 0,
    right: 0,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "#2c2c34",
    backgroundColor: color.card,
    overflow: "hidden",
    shadowColor: "#000",
    shadowOpacity: 0.55,
    shadowRadius: 25,
    shadowOffset: { width: 0, height: 20 },
  },
  task: { paddingHorizontal: 16, paddingVertical: 14, gap: 12 },
  taskDivider: { borderBottomWidth: 1, borderBottomColor: color.divider },
  taskFoot: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", gap: 12 },
  hint: { fontSize: 12, color: color.muted },
  listTitle: {
    fontSize: 11,
    letterSpacing: 0.7,
    textTransform: "uppercase",
    color: "#62626b",
    paddingHorizontal: 10,
    paddingTop: 6,
    paddingBottom: 4,
  },
  row: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingHorizontal: 10,
    paddingVertical: 8,
    borderRadius: 7,
  },
  rowOn: { backgroundColor: color.raised },
  kind: { width: 70, fontSize: 11, color: color.faint },
  label: { flex: 1, minWidth: 0, fontSize: 14, color: color.text },
  detail: { fontSize: 11, fontFamily: font.mono, color: color.muted, maxWidth: 160 },
  avatar: {
    width: 30,
    height: 30,
    borderRadius: 15,
    backgroundColor: color.raised,
    alignItems: "center",
    justifyContent: "center",
  },
  avatarText: { fontSize: 13, fontWeight: "600", color: color.text },
});
