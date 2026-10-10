import { useState } from "react";
import { Linking, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
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
  Segmented,
  Tap,
  Toggle,
} from "@/components/ui";
import { confirm } from "@/lib/confirm";
import { useChannel } from "@/lib/useChannel";
import { useLoad } from "@/lib/useLoad";
import { useWide } from "@/lib/useWide";
import { color } from "@/lib/theme";

type Field = {
  key: string;
  type: string;
  label?: string;
  default?: any;
  hidden?: boolean;
  options?: { label: string; value: string }[];
  when?: { key: string; op: string; value: any }[];
};
type Method = { id: string; type: "key" | "oauth" | string; label: string | null; fields: Field[] };
type Integration = {
  id: string;
  name: string;
  connections: { id: string; type: string; label: string; problem: string | null }[];
  methods: Method[];
};
type Data = {
  integrations: Integration[];
  featured: string[];
  models: Record<string, string[]>;
  default: string | null;
};
type Attempt = { url: string | null; instructions: string | null; mode: string | null };

// Same rule as the server: hidden fields aren't asked; `when` shows a field for some answers.
const shown = (f: Field, answers: Record<string, any>) =>
  !f.hidden &&
  (f.when ?? []).every((w) => {
    const v = String(answers[w.key] ?? "");
    return w.op === "eq" ? v === String(w.value) : w.op === "neq" ? v !== String(w.value) : true;
  });

// Models (admins): sign the OpenCode server in to model providers, once for everyone.
export default function Models() {
  const wide = useWide();
  const [version, setVersion] = useState(0);
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<string | null>(null);
  const [answers, setAnswers] = useState<Record<string, any>>({});
  const [key, setKey] = useState("");
  const [attempt, setAttempt] = useState<Attempt | null>(null);
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const ch = useChannel("admin", {
    oauth: ({ status, message }) => {
      setAttempt(null);
      if (status === "complete") connected();
      else setError(message);
    },
  });
  const { data } = useLoad(
    () => (ch.joined ? ch.call<Data>("models", {}, 60000) : Promise.resolve(null)),
    [ch.joined, version],
  );

  const integration = data?.integrations.find((i) => i.id === selected) ?? null;

  function connected() {
    setNote(
      `${integration?.name ?? "The provider"} is connected. Its models are in every session's model picker.`,
    );
    setSelected(null);
    setAnswers({});
    setKey("");
    setCode("");
    setVersion((v) => v + 1);
  }

  async function run(fn: () => Promise<unknown>) {
    setBusy(true);
    setError(null);
    try {
      await fn();
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(false);
  }

  const back = () => {
    if (attempt) ch.call("cancel_oauth").catch(() => {});
    setAttempt(null);
    setSelected(null);
    setError(null);
  };

  const signedIn = (data?.integrations ?? []).filter((i) => i.connections.length);
  const q = query.trim().toLowerCase();
  const choices = q
    ? (data?.integrations ?? [])
        .filter((i) => !i.connections.length && `${i.name} ${i.id}`.toLowerCase().includes(q))
        .slice(0, 12)
    : (data?.featured ?? []).map((id) => data!.integrations.find((i) => i.id === id)!).filter(Boolean);

  return (
    <Screen>
      {!wide ? <BackHeader label="Settings" /> : null}
      <ScrollView contentContainerStyle={st.body} keyboardShouldPersistTaps="handled">
        <LargeTitle>Models</LargeTitle>
        <Text style={st.hint}>Sign-ins on the OpenCode server, shared by every user and session.</Text>
        <ErrorLine message={ch.error ?? error} />
        {note ? <Text style={st.note}>{note}</Text> : null}
        {data == null ? <Loading /> : null}

        {integration ? (
          <Card>
            <View style={st.head}>
              <Text style={st.name}>Connect {integration.name}</Text>
              <Tap onPress={back}>
                <Text style={{ color: color.accentText }}>Back</Text>
              </Tap>
            </View>

            {attempt ? (
              <View style={{ gap: 10 }}>
                {attempt.instructions ? <Text style={st.body2}>{attempt.instructions}</Text> : null}
                {attempt.url ? (
                  <Button
                    label="Open the sign-in page"
                    height={40}
                    onPress={() => Linking.openURL(attempt.url!)}
                  />
                ) : null}
                {attempt.mode === "code" ? (
                  <>
                    <TextInput
                      value={code}
                      onChangeText={setCode}
                      placeholder="Paste the code"
                      placeholderTextColor={color.faint}
                      style={st.input}
                      autoCapitalize="none"
                    />
                    <Button
                      label="Finish"
                      height={40}
                      busy={busy}
                      disabled={!code.trim()}
                      onPress={() =>
                        run(async () => {
                          await ch.call("complete_oauth", { code }, 60000);
                          setAttempt(null);
                          connected();
                        })
                      }
                    />
                  </>
                ) : (
                  <>
                    <Text style={st.hint}>
                      Waiting for the sign-in. If your browser ends on an http://127.0.0.1:… page that doesn’t
                      load, paste its address here.
                    </Text>
                    <TextInput
                      value={code}
                      onChangeText={setCode}
                      placeholder="http://127.0.0.1:…"
                      placeholderTextColor={color.faint}
                      style={st.input}
                      autoCapitalize="none"
                    />
                    <Button
                      label="Send address"
                      kind="secondary"
                      height={40}
                      busy={busy}
                      disabled={!code.trim()}
                      onPress={() => run(() => ch.call("paste_callback", { url: code.trim() }, 30000))}
                    />
                  </>
                )}
              </View>
            ) : (
              integration.methods.map((m) => (
                <View key={m.id} style={st.method}>
                  {m.fields
                    .filter((f) => shown(f, answers))
                    .map((f) => (
                      <FieldInput
                        key={f.key}
                        field={f}
                        value={answers[f.key] ?? f.default}
                        onChange={(v) => setAnswers((a) => ({ ...a, [f.key]: v }))}
                      />
                    ))}
                  {m.type === "key" ? (
                    <>
                      <TextInput
                        value={key}
                        onChangeText={setKey}
                        placeholder={m.label ?? "API key"}
                        placeholderTextColor={color.faint}
                        secureTextEntry
                        style={st.input}
                        autoCapitalize="none"
                      />
                      <Button
                        label="Connect"
                        height={40}
                        busy={busy}
                        disabled={!key.trim()}
                        onPress={() =>
                          run(async () => {
                            await ch.call("connect_key", { id: integration.id, key, answers }, 60000);
                            connected();
                          })
                        }
                      />
                    </>
                  ) : (
                    <Button
                      label={m.label ?? "Sign in"}
                      kind="secondary"
                      height={40}
                      busy={busy}
                      onPress={() =>
                        run(async () => {
                          const r = await ch.call<{ attempt?: Attempt; done?: boolean }>(
                            "start_oauth",
                            { id: integration.id, method: m.id, answers },
                            60000,
                          );
                          if (r.done) connected();
                          else if (r.attempt) {
                            setCode("");
                            setAttempt(r.attempt);
                            if (r.attempt.url) Linking.openURL(r.attempt.url);
                          }
                        })
                      }
                    />
                  )}
                </View>
              ))
            )}
          </Card>
        ) : null}

        {!integration && data ? (
          <>
            <SectionLabel>Connected</SectionLabel>
            {signedIn.length === 0 ? <Text style={st.hint}>No providers yet.</Text> : null}
            {signedIn.map((i) => (
              <Card key={i.id}>
                <View style={st.head}>
                  <Text style={st.name}>{i.name}</Text>
                  <Text style={st.meta}>{(data.models[i.id] ?? []).length} models</Text>
                </View>
                {i.connections.map((c) => (
                  <View key={c.id ?? c.label} style={st.head}>
                    <Text style={st.meta}>
                      {c.label}
                      {c.problem ? (
                        <Text style={{ color: color.red }}> · needs sign-in again ({c.problem})</Text>
                      ) : null}
                    </Text>
                    {c.type === "credential" ? (
                      <Tap
                        onPress={async () => {
                          if (
                            await confirm(
                              `Disconnect ${i.name}?`,
                              "Sessions can't use its models after this.",
                              "Disconnect",
                            )
                          )
                            run(async () => {
                              await ch.call("disconnect", { id: c.id }, 30000);
                              setVersion((v) => v + 1);
                            });
                        }}
                      >
                        <Text style={{ color: color.red, fontSize: 13 }}>Disconnect</Text>
                      </Tap>
                    ) : null}
                  </View>
                ))}
                <Text style={st.meta} numberOfLines={2}>
                  {(data.models[i.id] ?? []).slice(0, 8).join(", ")}
                </Text>
              </Card>
            ))}
            {data.default ? <Text style={st.hint}>Default model: {data.default}</Text> : null}

            <SectionLabel style={{ paddingTop: 14 }}>Connect a provider</SectionLabel>
            <TextInput
              value={query}
              onChangeText={setQuery}
              placeholder="Search providers"
              placeholderTextColor={color.faint}
              style={st.input}
              autoCapitalize="none"
            />
            <Group>
              {choices.map((i, n) => (
                <Tap
                  key={i.id}
                  onPress={() => {
                    setSelected(i.id);
                    setNote(null);
                    setError(null);
                  }}
                  style={[st.row, n > 0 && st.top]}
                >
                  <Text style={st.name}>{i.name}</Text>
                  <Text style={st.meta}>
                    {i.methods.map((m) => (m.type === "key" ? "API key" : "sign in")).join(" · ")}
                  </Text>
                </Tap>
              ))}
            </Group>
          </>
        ) : null}
      </ScrollView>
    </Screen>
  );
}

function FieldInput({ field, value, onChange }: { field: Field; value: any; onChange: (v: any) => void }) {
  if (field.type === "boolean")
    return (
      <View style={st.head}>
        <Text style={st.meta}>{field.label ?? field.key}</Text>
        <Toggle value={value === true || value === "true"} onChange={onChange} />
      </View>
    );
  if (field.options?.length)
    return (
      <View style={{ gap: 6 }}>
        <Text style={st.meta}>{field.label ?? field.key}</Text>
        <Segmented
          options={field.options.map((o) => ({ value: String(o.value), label: o.label }))}
          value={String(value ?? "")}
          onChange={onChange}
        />
      </View>
    );
  return (
    <TextInput
      value={value == null ? "" : String(value)}
      onChangeText={onChange}
      placeholder={field.label ?? field.key}
      placeholderTextColor={color.faint}
      autoCapitalize="none"
      style={st.input}
    />
  );
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 18, paddingTop: 6, paddingBottom: 40, gap: 10 },
  head: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", gap: 10 },
  name: { fontSize: 15, fontWeight: "600", color: color.text },
  meta: { fontSize: 12.5, color: color.muted, flexShrink: 1 },
  hint: { fontSize: 13, color: color.muted, lineHeight: 18 },
  note: { fontSize: 13, color: color.teal },
  body2: { fontSize: 14, color: color.text, lineHeight: 20 },
  method: { gap: 8, paddingTop: 4 },
  row: { flexDirection: "row", alignItems: "center", gap: 10, paddingHorizontal: 14, paddingVertical: 12 },
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
