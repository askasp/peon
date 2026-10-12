import { useEffect, useState } from "react";
import { Platform, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { Button, ErrorLine, Group, LargeTitle, Screen, SectionLabel, Tap, Toggle } from "@/components/ui";
import { useWide } from "@/lib/useWide";
import { KeysSettings } from "@/components/KeysSettings";
import { changePassword as setNewPassword, signOut, usePeon } from "@/lib/peon";
import { listVoices, say, setVoiceSettings, useVoiceSettings, type SystemVoice } from "@/lib/voice";
import { color, font } from "@/lib/theme";

const speeds = [0.9, 1.0, 1.1, 1.25, 1.5];

// Settings: the server and your Home, where new chats go, voice, password, sign out.
export default function Settings() {
  const server = usePeon((s) => s.server);
  const user = usePeon((s) => s.user);
  const connected = usePeon((s) => s.connected);
  const voice = useVoiceSettings();
  const wide = useWide();
  const [password, setPassword] = useState("");
  const [passwordError, setPasswordError] = useState<string | null>(null);
  const [passwordNote, setPasswordNote] = useState<string | null>(null);

  async function changePassword() {
    setPasswordError(null);
    setPasswordNote(null);
    try {
      await setNewPassword(password);
      setPassword("");
      setPasswordNote("Password changed.");
    } catch (e: any) {
      setPasswordError(e.message);
    }
  }

  const [voices, setVoices] = useState<SystemVoice[]>([]);
  useEffect(() => {
    listVoices().then(setVoices);
  }, []);
  const current = voices.find((v) => v.id === voice.voice) ?? voices[0];

  // Steps through the installed voices, each saying hello.
  const nextVoice = () => {
    if (!voices.length) return;
    const next = voices[((current ? voices.indexOf(current) : -1) + 1) % voices.length];
    setVoiceSettings({ voice: next.id });
    say(`Hi, this is ${next.label.replace(/ \(.*\)$/, "")}. Work work.`, true);
  };

  const nextSpeed = () => {
    const i = speeds.indexOf(voice.rate);
    const rate = speeds[(i + 1) % speeds.length];
    setVoiceSettings({ rate });
    say(`Speaking at ${rate} times.`, true);
  };

  return (
    <Screen>
      <ScrollView contentContainerStyle={st.body}>
        <LargeTitle>Settings</LargeTitle>
        <Group>
          <View style={st.row}>
            <Text style={st.label} numberOfLines={1}>
              {server}
            </Text>
            <Text style={st.value}>{user?.username}</Text>
          </View>
          <View style={[st.row, st.top]}>
            <Text style={st.label}>Home Folder</Text>
            <Text style={[st.value, st.mono]}>home/{user?.username}/</Text>
          </View>
          {!connected ? (
            <View style={[st.row, st.top]}>
              <Text style={st.label}>Connection</Text>
              <Text style={[st.value, { color: color.red }]}>Reconnecting…</Text>
            </View>
          ) : null}
        </Group>

        <SectionLabel style={st.section}>Composer</SectionLabel>
        <Group>
          <View style={st.row}>
            <Text style={st.label}>New chats go to</Text>
            <Text style={st.value}>Current Folder, else Home</Text>
          </View>
        </Group>

        <SectionLabel style={st.section}>Voice</SectionLabel>
        <Group>
          <View style={st.row}>
            <Text style={st.label}>Dictation button</Text>
            <Toggle
              label="Dictation button"
              value={voice.dictation}
              onChange={(dictation) => setVoiceSettings({ dictation })}
            />
          </View>
          <View style={[st.row, st.top]}>
            <Text style={st.label}>Read replies aloud</Text>
            <Toggle
              label="Read replies aloud"
              value={voice.reply}
              onChange={(reply) => setVoiceSettings({ reply })}
            />
          </View>
          {voice.reply ? (
            <>
              <Tap style={[st.row, st.top]} onPress={nextVoice} testID="settings-voice">
                <Text style={st.label}>Voice</Text>
                <Text style={st.value} numberOfLines={1}>
                  {current ? current.label : "System"} ›
                </Text>
              </Tap>
              <Tap style={[st.row, st.top]} onPress={nextSpeed}>
                <Text style={st.label}>Speed</Text>
                <Text style={st.value}>{voice.rate}× ›</Text>
              </Tap>
            </>
          ) : null}
        </Group>
        <Text style={st.note}>Dictation turns speech into text you can edit before sending.</Text>
        {voice.reply && Platform.OS === "ios" && !voices.some((v) => v.label.endsWith("(Premium)")) ? (
          <Text style={st.note}>
            For a natural voice, download a Premium voice in iPhone Settings › Accessibility › Spoken Content
            › Voices.
          </Text>
        ) : null}

        {wide ? <KeysSettings /> : null}

        <SectionLabel style={st.section}>Password</SectionLabel>
        <Group style={{ padding: 14, gap: 10 }}>
          <TextInput
            value={password}
            onChangeText={setPassword}
            placeholder="New password (8 characters or more)"
            placeholderTextColor={color.faint}
            secureTextEntry
            style={st.input}
          />
          <ErrorLine message={passwordError} />
          {passwordNote ? <Text style={st.ok}>{passwordNote}</Text> : null}
          <Button label="Change password" height={40} disabled={!password} onPress={changePassword} />
        </Group>

        {user?.admin && !wide ? (
          <>
            <SectionLabel style={st.section}>Admin</SectionLabel>
            <Group>
              {[
                { href: "/users", label: "Users" },
                { href: "/connectors", label: "Connectors" },
                { href: "/models", label: "Models" },
              ].map((l, i) => (
                <Tap
                  key={l.href}
                  style={[st.row, i > 0 && st.top]}
                  onPress={() => router.push(l.href as any)}
                >
                  <Text style={st.label}>{l.label}</Text>
                  <Text style={st.value}>›</Text>
                </Tap>
              ))}
            </Group>
          </>
        ) : null}

        <Button label="Sign out" kind="danger" height={48} onPress={signOut} style={{ marginTop: 12 }} />
      </ScrollView>
    </Screen>
  );
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 18, paddingTop: 6, paddingBottom: 40, gap: 8 },
  section: { paddingTop: 10, paddingLeft: 4 },
  row: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingHorizontal: 14,
    minHeight: 47,
    gap: 12,
  },
  top: { borderTopWidth: 1, borderTopColor: color.divider },
  label: { fontSize: 15, color: color.text, flexShrink: 1 },
  value: { fontSize: 15, color: color.muted, flexShrink: 1, textAlign: "right" },
  mono: { fontFamily: font.mono, fontSize: 13 },
  ok: { fontSize: 13, color: color.teal },
  input: {
    height: 42,
    borderRadius: 10,
    backgroundColor: color.field,
    paddingHorizontal: 12,
    color: color.text,
    fontSize: 15,
  },
  note: { fontSize: 13, color: color.faint, paddingHorizontal: 4, paddingTop: 4, lineHeight: 18 },
});
