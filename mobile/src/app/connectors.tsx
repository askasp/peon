import { useState } from "react";
import { ScrollView, StyleSheet, Text, View } from "react-native";
import {
  BackHeader,
  Button,
  Card,
  ErrorLine,
  LargeTitle,
  Loading,
  Screen,
  SectionLabel,
  Tap,
} from "@/components/ui";
import { useChannel } from "@/lib/useChannel";
import { useLoad } from "@/lib/useLoad";
import { useWide } from "@/lib/useWide";
import { color, font } from "@/lib/theme";

type Tool = { name: string; method: string; path: string; permission: string; description: string | null };
type Connector = {
  name: string;
  file: string;
  error: string | null;
  base_url: string | null;
  secret: string | null;
  projects: string[];
  tools: Tool[];
};
type Data = { connectors: Connector[] };

// Shared API calls (admins): the older shared API calls each Project moves in
// from its API calls tab. Secrets live in each Project's settings.
export default function Connectors() {
  const wide = useWide();
  const ch = useChannel("admin");
  const [data, setData] = useState<Data | null>(null);
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
        <LargeTitle>Shared API calls</LargeTitle>
        <Text style={st.hint}>
          Secrets belong to each Project: set them in its Settings or API calls tab.
        </Text>
        <ErrorLine message={ch.error ?? error} />
        {note ? <Text style={st.note}>{note}</Text> : null}
        {shown == null ? <Loading /> : null}

        {shown && !shown.connectors.length ? <Text style={st.hint}>None left.</Text> : null}
        {shown?.connectors.length ? (
          <SectionLabel>Each Project moves these in from its API calls tab</SectionLabel>
        ) : null}
        {(shown?.connectors ?? []).map((c) => (
          <Card key={c.name}>
            <Tap onPress={() => setOpen(open === c.name ? null : c.name)} style={st.head}>
              <Text style={st.name}>{c.name}</Text>
              <Text style={[st.meta, { color: c.error ? color.red : color.muted }]}>
                {c.error ? "invalid" : c.secret ? `each Project sets ${c.secret}` : "no key"}
              </Text>
            </Tap>
            <Text style={st.meta}>
              {c.tools.length} calls · {c.projects.length ? c.projects.join(", ") : "no projects left"}
            </Text>
            {c.error ? <Text style={[st.meta, { color: color.red }]}>{c.error}</Text> : null}
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
});
