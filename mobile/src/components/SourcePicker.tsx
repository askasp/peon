import { useEffect, useState } from "react";
import { ActivityIndicator, StyleSheet, Text, TextInput, View } from "react-native";
import { SourceBadge } from "./Outbox";
import { ErrorLine, Tap } from "./ui";
import { ask } from "@/lib/peon";
import { color } from "@/lib/theme";

export type Connector = {
  id: string;
  name: string;
  short: string;
  secret: string;
  connected: boolean;
};
type Choice = { id: string; label: string; detail: string };
// `pending` while a service is open but nothing in it is chosen yet.
export type Picked = { connector: string; choice: string; label: string; pending?: boolean } | null;

const tokenHint: Record<string, string> = {
  "github.projects": "A GitHub token with the project scope (and repo, to comment on private issues)",
  front: "A Front API token (Settings → Developers → API tokens)",
};

// Connectors whose pick can be typed by hand, and the shape to type. GitHub
// only lists your own projects and the orgs you belong to, so a project the
// token can still read (an org you're just a collaborator on, or one past the
// first page) has to be named.
const manualHint: Record<string, string> = {
  "github.projects": "owner/12",
};

/**
 * Where a Dataset's rows come from: None (they live only here) or a connected
 * service, then which project or inbox. A service that isn't connected yet
 * takes a token right here (admins).
 */
export function SourcePicker({
  value,
  onChange,
  allowNone = true,
}: {
  value: Picked;
  onChange: (p: Picked) => void;
  allowNone?: boolean;
}) {
  // Opening a service clears the pick until a project or inbox is chosen.
  const [connectors, setConnectors] = useState<Connector[] | null>(null);
  const [open, setOpen] = useState<string | null>(value?.connector ?? null);
  const [choices, setChoices] = useState<Record<string, { account: string; choices: Choice[] }>>({});
  const [loading, setLoading] = useState<string | null>(null);
  const [token, setToken] = useState("");
  const [manual, setManual] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    ask<{ connectors: Connector[] }>("source_connectors")
      .then((r) => setConnectors(r.connectors))
      .catch((e) => setError(e.message));
  }, []);

  async function load(id: string) {
    setLoading(id);
    setError(null);
    try {
      const r = await ask<{ account: string; choices: Choice[] }>("source_choices", { connector: id }, 60000);
      setChoices((m) => ({ ...m, [id]: r }));
    } catch (e: any) {
      setError(e.message);
    }
    setLoading(null);
  }

  async function connect(c: Connector) {
    setLoading(c.id);
    setError(null);
    try {
      await ask("source_connect", { connector: c.id, token: token.trim() }, 60000);
      setToken("");
      setConnectors((cs) => cs?.map((x) => (x.id === c.id ? { ...x, connected: true } : x)) ?? null);
      setLoading(null);
      await load(c.id);
    } catch (e: any) {
      setError(e.message);
      setLoading(null);
    }
  }

  function pick(c: Connector) {
    setOpen(c.id);
    setError(null);
    // Keep a typed project if this service is already the pick; otherwise start blank.
    setManual(value?.connector === c.id && !value.pending ? value.choice : "");
    if (value?.connector !== c.id) onChange({ connector: c.id, choice: "", label: "", pending: true });
    if (c.connected && !choices[c.id]) load(c.id);
  }

  // A project or inbox named instead of listed (GitHub: owner/12).
  function takeManual(c: Connector) {
    const choice = manual.trim();
    if (choice) onChange({ connector: c.id, choice, label: choice });
  }

  return (
    <View style={{ gap: 8 }}>
      <View style={st.group}>
        {allowNone ? (
          <Tap
            testID="source-none"
            onPress={() => {
              setOpen(null);
              onChange(null);
            }}
            style={[st.row, st.line, !open && st.on]}
          >
            <View style={st.none}>
              <Text style={st.noneText}>—</Text>
            </View>
            <View style={{ flex: 1 }}>
              <Text style={st.title}>None</Text>
              <Text style={st.sub}>rows live only here</Text>
            </View>
            <Radio on={!open} />
          </Tap>
        ) : null}
        {(connectors ?? []).map((c, i) => {
          const isOpen = open === c.id;
          const got = choices[c.id];
          return (
            <View key={c.id} style={[i < (connectors?.length ?? 0) - 1 && st.line]}>
              <Tap testID={`source-${c.id}`} onPress={() => pick(c)} style={[st.row, isOpen && st.on]}>
                <SourceBadge short={c.short} size={28} />
                <View style={{ flex: 1 }}>
                  <Text style={st.title}>{c.name}</Text>
                  <Text style={st.sub}>
                    {got ? `connected as ${got.account}` : c.connected ? "connected" : "not connected"}
                  </Text>
                </View>
                {loading === c.id ? <ActivityIndicator color={color.muted} /> : <Radio on={isOpen} />}
              </Tap>
              {isOpen && !c.connected ? (
                <View style={st.inner}>
                  <Text style={st.sub}>{tokenHint[c.id] ?? `Token for ${c.name}`}</Text>
                  <View style={{ flexDirection: "row", gap: 8 }}>
                    <TextInput
                      testID="source-token"
                      value={token}
                      onChangeText={setToken}
                      placeholder={c.secret}
                      placeholderTextColor={color.faint}
                      secureTextEntry
                      autoCapitalize="none"
                      style={st.input}
                    />
                    <Tap
                      testID="source-connect"
                      haptic
                      disabled={!token.trim() || loading != null}
                      onPress={() => connect(c)}
                      style={st.connect}
                    >
                      <Text style={st.connectText}>Connect</Text>
                    </Tap>
                  </View>
                </View>
              ) : null}
              {isOpen && got ? (
                <View style={st.inner}>
                  {got.choices.length === 0 && !manualHint[c.id] ? (
                    <Text style={st.sub}>Nothing to sync here yet.</Text>
                  ) : (
                    got.choices.map((x) => {
                      const on = value?.connector === c.id && !value.pending && value.choice === x.id;
                      return (
                        <Tap
                          key={x.id || "all"}
                          testID={`choice-${x.id || "all"}`}
                          onPress={() => {
                            setManual("");
                            onChange({ connector: c.id, choice: x.id, label: x.label });
                          }}
                          style={[st.choice, on && st.choiceOn]}
                        >
                          <View style={{ flex: 1 }}>
                            <Text style={st.title} numberOfLines={1}>
                              {x.label}
                            </Text>
                            <Text style={st.sub} numberOfLines={1}>
                              {x.detail}
                            </Text>
                          </View>
                          {on ? <Text style={st.check}>✓</Text> : null}
                        </Tap>
                      );
                    })
                  )}
                </View>
              ) : null}
              {isOpen && c.connected && manualHint[c.id] ? (
                <View style={st.inner}>
                  <Text style={st.sub}>
                    {got && got.choices.length
                      ? "Don't see it? "
                      : "None listed — the token may not cover it. "}
                    Type the project as {manualHint[c.id]}.
                  </Text>
                  <View style={{ flexDirection: "row", gap: 8 }}>
                    <TextInput
                      testID="source-manual"
                      value={manual}
                      onChangeText={setManual}
                      placeholder={manualHint[c.id]}
                      placeholderTextColor={color.faint}
                      autoCapitalize="none"
                      autoCorrect={false}
                      onSubmitEditing={() => takeManual(c)}
                      style={st.input}
                    />
                    <Tap
                      testID="source-manual-use"
                      haptic
                      disabled={!manual.trim()}
                      onPress={() => takeManual(c)}
                      style={[st.connect, !manual.trim() && { opacity: 0.4 }]}
                    >
                      <Text style={st.connectText}>Use</Text>
                    </Tap>
                  </View>
                </View>
              ) : null}
            </View>
          );
        })}
      </View>
      <ErrorLine message={error} />
    </View>
  );
}

function Radio({ on }: { on: boolean }) {
  return <View style={[st.radio, on && st.radioOn]}>{on ? <View style={st.radioDot} /> : null}</View>;
}

const st = StyleSheet.create({
  group: { borderRadius: 14, backgroundColor: color.bg, overflow: "hidden" },
  row: { flexDirection: "row", alignItems: "center", gap: 12, paddingHorizontal: 14, paddingVertical: 11 },
  line: { borderBottomWidth: 1, borderBottomColor: "#222228" },
  on: { backgroundColor: color.accentCard },
  none: {
    width: 28,
    height: 28,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: color.outline,
    borderStyle: "dashed",
    alignItems: "center",
    justifyContent: "center",
  },
  noneText: { color: color.faint },
  title: { fontSize: 15, color: color.text },
  sub: { fontSize: 12.5, color: color.muted },
  inner: {
    paddingHorizontal: 14,
    paddingBottom: 12,
    paddingLeft: 54,
    gap: 6,
    backgroundColor: color.accentCard,
  },
  input: {
    flex: 1,
    height: 38,
    borderRadius: 9,
    backgroundColor: color.field,
    borderWidth: 1,
    borderColor: color.border,
    paddingHorizontal: 12,
    color: color.text,
    fontSize: 14,
    outlineStyle: "none",
  } as any,
  connect: {
    height: 38,
    paddingHorizontal: 14,
    borderRadius: 9,
    backgroundColor: color.textStrong,
    alignItems: "center",
    justifyContent: "center",
  },
  connectText: { fontSize: 14, fontWeight: "600", color: color.bg },
  choice: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: color.card,
  },
  choiceOn: { borderColor: color.accent },
  check: { fontSize: 15, color: color.accentText, fontWeight: "700" },
  radio: {
    width: 20,
    height: 20,
    borderRadius: 10,
    borderWidth: 2,
    borderColor: color.ghost,
    alignItems: "center",
    justifyContent: "center",
  },
  radioOn: { borderColor: color.accent },
  radioDot: { width: 10, height: 10, borderRadius: 5, backgroundColor: color.accent },
});
