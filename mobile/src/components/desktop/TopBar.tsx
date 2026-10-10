import { useEffect, useRef, useState } from "react";
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router, usePathname } from "expo-router";
import { Icon } from "../Icon";
import { Button, Dot, ErrorLine } from "../ui";
import { ComposerOutput } from "../ComposerOutput";
import { openPalette } from "@/lib/palette";
import { useCommand } from "@/lib/commands";
import { usePeon } from "@/lib/peon";
import { useComposer } from "@/lib/useComposer";
import { setVoiceSettings, useDictation, useVoiceSettings } from "@/lib/voice";
import { color, font } from "@/lib/theme";

// The global composer, inline: type (or talk), see how it reads, Enter to go.
function InlineComposer() {
  const [text, setText] = useState("");
  const [focused, setFocused] = useState(false);
  const input = useRef<TextInput>(null);
  const voice = useVoiceSettings();
  // Talking adds to the line; Enter (or the button) starts it.
  const join = (a: string, b: string) => (a.trim() && b ? `${a.trimEnd()} ${b}` : a + b);
  const dictation = useDictation((spoken) => {
    setText((t) => join(t, spoken));
    input.current?.focus();
  });
  const line = dictation.listening ? join(text, dictation.transcript) : text;
  const opener = useRef<(id: string) => void>(() => {});
  const open = (id: string) => opener.current(id);
  const c = useComposer(line, open);
  useCommand("composer:focus", () => input.current?.focus());
  useCommand("composer:talk", () => (dictation.listening ? dictation.stop() : dictation.start()));
  useEffect(() => {
    opener.current = (id) => {
      setText("");
      c.reset();
      input.current?.blur();
      router.navigate(`/session/${id}`);
    };
  });

  const showPanel =
    (focused && line.trim() !== "") || c.busy || c.answer || c.note || c.error || c.plan || dictation.error;

  return (
    <View style={st.composerWrap}>
      <View style={[st.composer, (focused || dictation.listening) && { borderColor: color.accent }]}>
        <TextInput
          ref={input}
          testID="top-composer"
          value={line}
          onChangeText={(v) => {
            setText(v);
            c.edited();
          }}
          onFocus={() => setFocused(true)}
          onBlur={() => setTimeout(() => setFocused(false), 150)}
          onKeyPress={(e: any) => {
            if (e.nativeEvent.key === "Escape") {
              setText("");
              c.reset();
              input.current?.blur();
            }
          }}
          onSubmitEditing={() => c.submit(line)}
          placeholder="Start anything: “new session in … use /skill, then …”"
          placeholderTextColor={color.faint}
          style={st.composerInput}
        />
        <Pressable
          onPress={() => setVoiceSettings({ reply: !voice.reply })}
          style={(s: any) => [st.chip, s.hovered && { backgroundColor: color.raised }]}
        >
          <Icon name="speaker" size={12} color={voice.reply ? color.accentText : color.muted} />
          <Text style={[st.chipText, { color: voice.reply ? color.accentText : color.muted }]}>
            {voice.reply ? "Voice" : "Text"}
          </Text>
        </Pressable>
        <Pressable
          testID="top-mic"
          onPress={() => (dictation.listening ? dictation.stop() : dictation.start())}
          style={(s: any) => [
            st.mic,
            dictation.listening && { backgroundColor: color.accent },
            s.hovered && !dictation.listening && { backgroundColor: color.raised },
          ]}
        >
          <Icon name="mic" size={14} color={dictation.listening ? color.accentInk : color.text} />
        </Pressable>
      </View>
      {showPanel ? (
        <View style={st.panel}>
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
          {line.trim() ? (
            <View style={{ flexDirection: "row", justifyContent: "flex-end", gap: 8 }}>
              <Text style={st.hint}>Enter</Text>
              <Button label={c.button} height={34} busy={c.busy} onPress={() => c.submit(line)} />
            </View>
          ) : null}
        </View>
      ) : null}
    </View>
  );
}

export function TopBar() {
  const path = usePathname();
  const live = usePeon((s) => s.running);
  const viewing = usePeon((s) => s.viewing);
  // The session on screen stays a tab while it's idle, like the web.
  const running =
    viewing && !live.some((r) => r.id === viewing.id)
      ? [...live, { ...viewing, status: "idle" as const, project: null }]
      : live;
  const inbox = usePeon((s) => s.inbox.length);
  const user = usePeon((s) => s.user);

  return (
    <View style={st.bar}>
      <Pressable
        testID="open-palette"
        onPress={() => openPalette()}
        style={(s: any) => [st.search, s.hovered && { borderColor: color.outline }]}
      >
        <Text style={st.searchText}>Search or run a command</Text>
        <Text style={st.kbd}>Ctrl+K</Text>
      </Pressable>
      <InlineComposer />
      <ScrollView
        horizontal
        style={{ flex: 1 }}
        contentContainerStyle={st.tabs}
        showsHorizontalScrollIndicator={false}
      >
        {running.map((r) => {
          const active = path === `/session/${r.id}`;
          return (
            <Pressable
              key={r.id}
              onPress={() => router.navigate(`/session/${r.id}`)}
              style={(s: any) => [
                st.tab,
                active && st.tabActive,
                s.hovered && !active && { backgroundColor: color.card },
              ]}
            >
              {r.status === "idle" ? null : (
                <Dot size={6} tint={r.status === "waiting" ? color.cream : color.accent} />
              )}
              <Text style={st.tabText} numberOfLines={1}>
                {r.title}
              </Text>
            </Pressable>
          );
        })}
      </ScrollView>
      <Pressable
        onPress={() => router.navigate("/")}
        style={(s: any) => [st.right, s.hovered && { opacity: 0.75 }]}
      >
        <Text style={st.rightText}>Inbox{inbox ? ` · ${inbox}` : ""}</Text>
      </Pressable>
      <Pressable
        onPress={() => router.navigate("/settings")}
        style={(s: any) => [st.right, s.hovered && { opacity: 0.75 }]}
      >
        <Text style={st.rightText}>{user?.username}</Text>
      </Pressable>
    </View>
  );
}

const st = StyleSheet.create({
  bar: {
    height: 48,
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingHorizontal: 10,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
    backgroundColor: color.bar,
    zIndex: 10,
  },
  search: {
    width: 230,
    height: 32,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: color.border,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 10,
  },
  searchText: { fontSize: 13, color: color.muted },
  kbd: {
    fontSize: 11,
    fontFamily: font.mono,
    color: color.textDim,
    borderWidth: 1,
    borderColor: color.outline,
    borderRadius: 4,
    paddingHorizontal: 5,
  },
  composerWrap: { width: 520, position: "relative" },
  composer: {
    height: 32,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: color.bg,
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    paddingLeft: 10,
    paddingRight: 4,
  },
  composerInput: { flex: 1, height: 30, fontSize: 13, color: color.text, outlineStyle: "none" } as any,
  chip: {
    flexDirection: "row",
    alignItems: "center",
    gap: 4,
    paddingHorizontal: 6,
    height: 24,
    borderRadius: 6,
  },
  chipText: { fontSize: 12 },
  mic: { width: 26, height: 24, borderRadius: 6, alignItems: "center", justifyContent: "center" },
  panel: {
    position: "absolute",
    top: 38,
    left: 0,
    right: 0,
    padding: 14,
    gap: 12,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: color.card,
    shadowColor: "#000",
    shadowOpacity: 0.5,
    shadowRadius: 24,
    shadowOffset: { width: 0, height: 12 },
  },
  hint: { alignSelf: "center", fontSize: 12, color: color.faint },
  tabs: { alignItems: "center", gap: 6, paddingHorizontal: 4 },
  tab: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    height: 28,
    paddingHorizontal: 10,
    borderRadius: 7,
    maxWidth: 220,
  },
  tabActive: { backgroundColor: color.raised },
  tabText: { fontSize: 12, color: color.textSoft },
  right: { paddingHorizontal: 6 },
  rightText: { fontSize: 13, color: color.textDim },
});
