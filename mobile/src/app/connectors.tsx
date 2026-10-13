import { useRef, useState } from "react";
import { ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import {
  BackHeader,
  Button,
  Card,
  ErrorLine,
  Group,
  LargeTitle,
  Loading,
  Screen,
  SectionLabel,
  Tap,
} from "@/components/ui";
import { confirm } from "@/lib/confirm";
import { useChannel } from "@/lib/useChannel";
import { useLoad } from "@/lib/useLoad";
import { useWide } from "@/lib/useWide";
import { ago } from "@/lib/time";
import { color, font } from "@/lib/theme";

type Tool = { name: string; method: string; path: string; permission: string; description: string | null };
type Connector = {
  name: string;
  file: string;
  error: string | null;
  base_url: string | null;
  secret: string | null;
  ready: boolean;
  projects: string[];
  tools: Tool[];
};
type Secret = { name: string; hint: string | null; set_by: string | null; updated_at: string };
type Data = { connectors: Connector[]; secrets: Secret[] };

// Secrets (admins): the vault keys API calls authenticate with, and the older
// shared API calls each Project moves in from its API calls tab.
export default function Connectors() {
  const wide = useWide();
  const ch = useChannel("admin");
  const [data, setData] = useState<Data | null>(null);
  const [name, setName] = useState("");
  const valueInput = useRef<TextInput>(null);
  const [value, setValue] = useState("");
  const [open, setOpen] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const { data: loaded } = useLoad(
    () => (ch.joined ? ch.call<Data>("connectors", {}, 60000) : Promise.resolve(null)),
    [ch.joined],
  );
  const shown = data ?? loaded;

  async function act(key: string, fn: () => Promise<Data | void>, message?: string) {
    setBusy(key);
    setError(null);
    setNote(null);
    try {
      const r = await fn();
      if (r) setData(r);
      if (message) setNote(message);
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(null);
  }

  return (
    <Screen>
      {!wide ? <BackHeader label="Settings" /> : null}
      <ScrollView contentContainerStyle={st.body}>
        <LargeTitle>Secrets</LargeTitle>
        <ErrorLine message={ch.error ?? error} />
        {note ? <Text style={st.note}>{note}</Text> : null}
        {shown == null ? <Loading /> : null}

        {shown?.connectors.length ? <SectionLabel>Shared API calls</SectionLabel> : null}
        {shown?.connectors.length ? (
          <Text style={st.hint}>Each Project moves these in from its API calls tab.</Text>
        ) : null}
        {(shown?.connectors ?? []).map((c) => (
          <Card key={c.name}>
            <Tap onPress={() => setOpen(open === c.name ? null : c.name)} style={st.head}>
              <Text style={st.name}>{c.name}</Text>
              <Text style={[st.meta, { color: c.error ? color.red : c.ready ? color.teal : color.cream }]}>
                {c.error ? "invalid" : c.ready ? "ready" : `needs ${c.secret ?? "a secret"}`}
              </Text>
            </Tap>
            <Text style={st.meta}>
              {c.tools.length} calls · {c.projects.length ? c.projects.join(", ") : "no projects left"}
            </Text>
            {c.error ? <Text style={[st.meta, { color: color.red }]}>{c.error}</Text> : null}
            {!c.ready && !c.error && c.secret ? (
              <Tap
                testID={`set-secret-${c.name}`}
                onPress={() => {
                  // Fill in the secret's name below; only its value is left to type.
                  setName(c.secret!);
                  valueInput.current?.focus();
                }}
              >
                <Text style={[st.meta, { color: color.cream }]}>Set {c.secret}</Text>
              </Tap>
            ) : null}
            {open === c.name ? (
              <View style={{ gap: 4 }}>
                {c.base_url ? <Text style={st.mono}>{c.base_url}</Text> : null}
                {c.tools.map((t) => (
                  <Text key={t.name} style={st.mono}>
                    {t.name} · {t.method} {t.path} · {t.permission}
                  </Text>
                ))}
              </View>
            ) : null}
          </Card>
        ))}

        <Group>
          {(shown?.secrets ?? []).map((s, i) => (
            <View key={s.name} style={[st.row, i > 0 && st.top]}>
              <View style={{ flex: 1 }}>
                <Text style={st.mono}>{s.name}</Text>
                <Text style={st.meta}>
                  {s.hint ?? ""} · {s.set_by ?? "?"} · {ago(s.updated_at, true)}
                </Text>
              </View>
              <Button label="Replace" kind="secondary" height={30} onPress={() => setName(s.name)} />
              <Button
                label="Delete"
                kind="danger"
                height={30}
                busy={busy === `del-${s.name}`}
                onPress={async () => {
                  if (await confirm(`Delete ${s.name}?`, "API calls using it stop working.", "Delete"))
                    act(
                      `del-${s.name}`,
                      () => ch.call<Data>("delete_secret", { name: s.name }, 60000),
                      `${s.name} removed.`,
                    );
                }}
              />
            </View>
          ))}
        </Group>
        <Group style={{ padding: 14, gap: 10, marginTop: 8 }}>
          <TextInput
            value={name}
            onChangeText={(v) => setName(v.toUpperCase())}
            placeholder="FRONT_API_TOKEN"
            placeholderTextColor={color.faint}
            autoCapitalize="characters"
            style={[st.input, { fontFamily: font.mono }]}
          />
          <TextInput
            ref={valueInput}
            value={value}
            onChangeText={setValue}
            placeholder="Value"
            placeholderTextColor={color.faint}
            secureTextEntry
            style={st.input}
          />
          <Button
            label="Save secret"
            height={42}
            busy={busy === "save"}
            disabled={!name.trim() || !value}
            onPress={() =>
              act(
                "save",
                async () => {
                  const r = await ch.call<Data>("save_secret", { name: name.trim(), value }, 60000);
                  setName("");
                  setValue("");
                  return r;
                },
                `${name.trim()} saved to the vault.`,
              )
            }
          />
        </Group>
        {shown?.connectors.length ? (
          <Button
            label="Apply to projects"
            kind="secondary"
            height={40}
            busy={busy === "apply"}
            onPress={() => act("apply", () => ch.call<Data>("apply", {}, 60000), "Applied to projects.")}
          />
        ) : null}
      </ScrollView>
    </Screen>
  );
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 18, paddingTop: 6, paddingBottom: 40, gap: 10 },
  head: { flexDirection: "row", justifyContent: "space-between" },
  name: { fontSize: 15, fontWeight: "600", color: color.text },
  meta: { fontSize: 12.5, color: color.muted },
  mono: { fontSize: 12.5, color: color.textSoft, fontFamily: font.mono },
  hint: { fontSize: 13, color: color.muted, lineHeight: 18 },
  note: { fontSize: 13, color: color.teal },
  row: { flexDirection: "row", alignItems: "center", gap: 8, paddingHorizontal: 14, paddingVertical: 10 },
  top: { borderTopWidth: 1, borderTopColor: color.divider },
  input: {
    height: 42,
    borderRadius: 10,
    backgroundColor: color.field,
    paddingHorizontal: 12,
    color: color.text,
    fontSize: 15,
  },
});
