import { useEffect, useRef, useState } from "react";
import { ActivityIndicator, Keyboard, Pressable, StyleSheet, Text, TextInput, View } from "react-native";
import { useKeyboardHeight } from "@/lib/useKeyboard";
import { router, useLocalSearchParams } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Icon } from "@/components/Icon";
import { Button, ErrorLine, Tap } from "@/components/ui";
import { useComposer } from "@/lib/useComposer";
import { ComposerOutput } from "@/components/ComposerOutput";
import { setVoiceSettings, useDictation, useVoiceSettings } from "@/lib/voice";
import { color } from "@/lib/theme";
import type { PlanRow } from "@/lib/types";

// Words in the line that name a project (@name) or skill (/name) are tinted.
function Highlighted({ text, rows }: { text: string; rows: PlanRow[] }) {
  const names = rows.filter(([k]) => k === "Project" || k === "Skill" || k === "Routine").map(([, v]) => v);
  if (!names.length) return <Text style={st.lineText}>{text}</Text>;
  const re = new RegExp(`(${names.map((n) => n.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})`, "gi");
  return (
    <Text style={st.lineText}>
      {text.split(re).map((part, i) =>
        i % 2 === 1 ? (
          <Text key={i} style={{ color: color.accent }}>
            {part}
          </Text>
        ) : (
          part
        ),
      )}
    </Text>
  );
}

// 02 · Composer: one line, typed or said, that starts anything.
export default function Compose() {
  const { listen } = useLocalSearchParams<{ listen?: string }>();
  const insets = useSafeAreaInsets();
  const voice = useVoiceSettings();
  const [text, setText] = useState("");
  const input = useRef<TextInput>(null);
  const keyboard = useKeyboardHeight();

  // Saying something sends it once you pause.
  const send = useRef<(value: string) => void>(() => {});
  // Talking adds to the line; you check how it reads and press the button.
  const join = (a: string, b: string) => (a.trim() && b ? `${a.trimEnd()} ${b}` : a + b);
  const dictation = useDictation((spoken) => setText((t) => join(t, spoken)));
  const line = dictation.listening ? join(text, dictation.transcript) : text;
  const c = useComposer(line);
  useEffect(() => {
    send.current = (value) => {
      Keyboard.dismiss();
      c.submit(value);
    };
  });

  useEffect(() => {
    if (listen) dictation.start();
    else setTimeout(() => input.current?.focus(), 250);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const { rows, button } = c;

  return (
    <View style={st.backdrop}>
      <Pressable style={{ flex: 1 }} onPress={() => router.back()} />
      <View
        style={[st.sheet, { paddingBottom: keyboard > 0 ? keyboard + 16 : Math.max(insets.bottom, 16) + 20 }]}
      >
        <View style={st.grabber} />
        <View style={st.head}>
          <Text style={st.headTitle}>New</Text>
          <Tap style={st.chip} onPress={() => router.replace("/handsfree")} testID="go-handsfree">
            <Icon name="phone" size={14} color={color.text} strokeWidth={2} />
            <Text style={st.chipText}>Hands-free</Text>
          </Tap>
        </View>

        <View style={[st.line, dictation.listening && { borderColor: color.accentText }]}>
          {dictation.listening ? (
            line ? (
              <Highlighted text={line} rows={rows} />
            ) : (
              <Text style={[st.lineText, { color: color.accentText }]}>Listening…</Text>
            )
          ) : (
            <TextInput
              ref={input}
              testID="compose-input"
              value={text}
              onChangeText={(v) => {
                setText(v);
                c.edited();
              }}
              placeholder="new session in amino-monorepo, find why checkout fails"
              placeholderTextColor={color.faint}
              multiline
              style={[st.lineText, { minHeight: 68, padding: 0 }]}
              onSubmitEditing={() => send.current(text)}
              blurOnSubmit
              returnKeyType="go"
            />
          )}
        </View>

        <ComposerOutput
          plan={c.plan}
          rows={rows}
          answer={c.answer}
          note={c.note}
          unsure={c.unsure}
          busy={c.busy}
        />
        <ErrorLine message={c.error ?? dictation.error} />

        <View style={st.actions}>
          <Tap
            style={[st.voice, !voice.reply && { backgroundColor: color.field }]}
            onPress={() => setVoiceSettings({ reply: !voice.reply })}
          >
            <Icon name="speaker" size={14} color={voice.reply ? color.accentText : color.muted} />
            <Text style={[st.voiceText, !voice.reply && { color: color.muted }]}>Voice reply</Text>
          </Tap>
          <Tap
            haptic
            testID="compose-mic"
            style={[st.mic, dictation.listening && { backgroundColor: color.accent }]}
            onPress={() => (dictation.listening ? dictation.stop() : dictation.start())}
          >
            {dictation.listening ? (
              <ActivityIndicator color={color.accentInk} size="small" />
            ) : (
              <Icon name="mic" size={18} color={color.text} />
            )}
          </Tap>
          <Button
            testID="compose-go"
            label={button}
            height={44}
            style={{ flex: 1 }}
            busy={c.busy}
            disabled={!line.trim()}
            onPress={() => send.current(line)}
          />
        </View>
      </View>
    </View>
  );
}

const st = StyleSheet.create({
  backdrop: { flex: 1, backgroundColor: "rgba(5,5,7,0.72)" },
  sheet: {
    borderTopLeftRadius: 28,
    borderTopRightRadius: 28,
    backgroundColor: color.card,
    paddingHorizontal: 18,
    paddingTop: 10,
    gap: 16,
  },
  grabber: { alignSelf: "center", width: 36, height: 5, borderRadius: 3, backgroundColor: color.ghost },
  head: { flexDirection: "row", justifyContent: "space-between", alignItems: "center" },
  headTitle: { fontSize: 17, fontWeight: "600", color: color.text },
  chip: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 16,
    backgroundColor: color.raised,
  },
  chipText: { fontSize: 13, color: color.text },
  line: {
    minHeight: 96,
    borderRadius: 14,
    backgroundColor: color.bg,
    borderWidth: 1,
    borderColor: color.accent,
    padding: 14,
  },
  lineText: { fontSize: 16, lineHeight: 23, color: color.text },
  actions: { flexDirection: "row", gap: 10, alignItems: "center" },
  voice: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    height: 44,
    paddingHorizontal: 14,
    borderRadius: 12,
    backgroundColor: color.accentWash,
  },
  voiceText: { fontSize: 14, color: color.accentText },
  mic: {
    width: 44,
    height: 44,
    borderRadius: 12,
    backgroundColor: color.raised,
    alignItems: "center",
    justifyContent: "center",
  },
});
