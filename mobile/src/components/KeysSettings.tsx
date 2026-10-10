import { useState } from "react";
import { StyleSheet, Text, TextInput, View } from "react-native";
import { Button, ErrorLine, Group, SectionLabel, Segmented, Toggle } from "./ui";
import { saveKeys, usePeon } from "@/lib/peon";
import { color, font } from "@/lib/theme";

/** Desktop: the keymap (tmux or standard, prefix, status line) and in-session shortcuts. */
export function KeysSettings() {
  const keys = usePeon((s) => s.keys);
  const [binds, setBinds] = useState<Record<string, string> | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  if (!keys) return null;
  const shown = binds ?? keys.binds;

  async function save(change: Parameters<typeof saveKeys>[0], message: string) {
    setError(null);
    setNote(null);
    try {
      await saveKeys(change);
      setBinds(null);
      setNote(message);
    } catch (e: any) {
      setError(e.message);
    }
  }

  return (
    <>
      <SectionLabel style={st.section}>Keyboard</SectionLabel>
      <Group style={{ padding: 14, gap: 12 }}>
        <Text style={st.label}>Keymap</Text>
        <Segmented
          options={[
            { value: "tmux", label: "tmux (prefix, then a key)" },
            { value: "standard", label: "Standard (alt+1–9, g …)" },
          ]}
          value={keys.prefs.keymap}
          onChange={(keymap) => save({ prefs: { keymap } }, "Keymap saved.")}
        />
        {keys.prefs.keymap === "tmux" ? (
          <>
            <Text style={st.label}>Prefix</Text>
            <Segmented
              options={[
                { value: "ctrl+b", label: "Ctrl+B" },
                { value: "ctrl+space", label: "Ctrl+Space" },
                { value: "ctrl+a", label: "Ctrl+A" },
              ]}
              value={keys.prefs.prefix}
              onChange={(prefix) => save({ prefs: { prefix } }, "Prefix saved.")}
            />
          </>
        ) : null}
        {keys.prefs.keymap === "tmux" ? (
          <>
            <Text style={st.label}>Show what the prefix can do after</Text>
            <Segmented
              options={[
                { value: "0", label: "At once" },
                { value: "300", label: "0.3 s" },
                { value: "600", label: "0.6 s" },
                { value: "1000", label: "1 s" },
              ]}
              value={String(keys.prefs.which_key_delay)}
              onChange={(v) => save({ prefs: { which_key_delay: Number(v) } }, "Saved.")}
            />
          </>
        ) : null}
        <View style={st.row}>
          <Text style={[st.label, { flex: 1 }]}>Show pressed keys (keycast)</Text>
          <Toggle value={keys.prefs.keycast} onChange={(keycast) => save({ prefs: { keycast } }, "Saved.")} />
        </View>
        <View style={st.row}>
          <Text style={[st.label, { flex: 1 }]}>Status line</Text>
          <Toggle
            value={keys.prefs.status_line}
            onChange={(status_line) => save({ prefs: { status_line } }, "Saved.")}
          />
        </View>
      </Group>

      <SectionLabel style={st.section}>In a session</SectionLabel>
      <Group style={{ padding: 14, gap: 8 }}>
        <Text style={st.hint}>
          OpenCode syntax: ctrl+g, shift+return, &lt;leader&gt;m (the prefix, then m), alternatives separated
          by commas, none to turn off.
        </Text>
        {keys.actions.map((a) => (
          <View key={a.action} style={st.row}>
            <View style={{ flex: 1 }}>
              <Text style={st.label}>{a.desc}</Text>
              <Text style={st.hint}>default {a.default}</Text>
            </View>
            <TextInput
              value={shown[a.action] ?? ""}
              onChangeText={(v) => setBinds({ ...shown, [a.action]: v })}
              autoCapitalize="none"
              style={st.input}
            />
          </View>
        ))}
        <ErrorLine message={error} />
        {note ? <Text style={st.note}>{note}</Text> : null}
        <View style={{ flexDirection: "row", gap: 8 }}>
          <Button
            label="Save shortcuts"
            height={38}
            disabled={!binds}
            onPress={() => save({ binds: shown }, "Shortcuts saved.")}
          />
          <Button
            label="Reset to defaults"
            kind="secondary"
            height={38}
            onPress={() => save({ binds: {} }, "Shortcuts reset.")}
          />
        </View>
      </Group>
    </>
  );
}

const st = StyleSheet.create({
  section: { paddingTop: 10, paddingLeft: 4 },
  label: { fontSize: 14, color: color.text },
  hint: { fontSize: 12, color: color.muted, lineHeight: 17 },
  note: { fontSize: 13, color: color.teal },
  row: { flexDirection: "row", alignItems: "center", gap: 12 },
  input: {
    width: 220,
    height: 34,
    borderRadius: 8,
    backgroundColor: color.field,
    paddingHorizontal: 10,
    color: color.text,
    fontSize: 13,
    fontFamily: font.mono,
  },
});
