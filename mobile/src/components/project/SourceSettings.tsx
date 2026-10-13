import { useState } from "react";
import { StyleSheet, Text, View } from "react-native";
import { SourceBadge } from "../Outbox";
import { SourcePicker, type Picked } from "../SourcePicker";
import { Button, ErrorLine, Loading, Segmented, SectionLabel } from "../ui";
import { confirm } from "@/lib/confirm";
import { useLoad } from "@/lib/useLoad";
import { ago } from "@/lib/time";
import { color, font } from "@/lib/theme";
import type { ProjectCtx } from "./types";

type Level = "direct" | "confirm" | "off";
type Source = {
  name: string;
  table: string;
  connector: string;
  connector_name: string;
  short: string;
  title: string | null;
  url: string | null;
  rows: number | null;
  every_hours: number;
  fetched_at: string | null;
  error: string | null;
  actions: { name: string; label: string; level: Level }[];
  local_columns: string[];
};
type Data = { sources: Source[]; can_edit: boolean };

const levels: { value: Level; label: string }[] = [
  { value: "direct", label: "Direct" },
  { value: "confirm", label: "Ask first" },
  { value: "off", label: "Off" },
];

/**
 * A Dataset's synced sources (sources.json): sync now, what each action may
 * do (for you, views and scheduled runs alike), the local columns, and
 * disconnecting, which keeps the rows as a local table.
 */
export function SourceSettings({ ctx }: { ctx: ProjectCtx }) {
  const [version, setVersion] = useState(0);
  const [data, setData] = useState<Data | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const [picked, setPicked] = useState<Picked>(null);
  const { data: loaded, error: loadError } = useLoad(() => ctx.call<Data>("sources", {}, 30000), [version]);
  const shown = data ?? loaded;

  async function act(key: string, fn: () => Promise<Data | void>) {
    setBusy(key);
    setError(null);
    try {
      const r = await fn();
      if (r) setData(r);
      else setVersion((v) => v + 1);
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(null);
  }

  if (!shown) return loadError ? <ErrorLine message={loadError} /> : <Loading />;
  const edit = shown.can_edit;

  return (
    <View style={{ gap: 10 }} testID="source-settings">
      <SectionLabel style={st.section}>Source</SectionLabel>
      <ErrorLine message={error} />
      {shown.sources.length === 0 && !adding ? (
        <Text style={st.hint}>
          None. The rows live only here. Add a source to sync GitHub Projects or a Front inbox into a table.
        </Text>
      ) : null}

      {shown.sources.map((s) => (
        <View key={s.name} style={st.card}>
          <View style={st.head}>
            <SourceBadge short={s.short} size={32} />
            <View style={{ flex: 1, gap: 2 }}>
              <Text style={st.title}>
                {s.connector_name} · {s.title ?? "not synced yet"}
              </Text>
              <Text style={st.hint}>
                Table {s.table}
                {s.rows != null ? ` · ${s.rows} rows` : ""} · every {Math.round(s.every_hours * 60)} min
                {s.fetched_at ? ` · synced ${ago(s.fetched_at, true)}` : ""}
              </Text>
            </View>
            <Button
              label="Sync now"
              kind="secondary"
              height={34}
              busy={busy === `sync-${s.name}`}
              onPress={() =>
                act(`sync-${s.name}`, async () => {
                  await ctx.call("refresh_source", { name: s.name }, 660000);
                })
              }
            />
          </View>
          {s.error ? <Text style={st.error}>{s.error}</Text> : null}

          <View style={{ gap: 2 }}>
            <Text style={st.label}>Actions</Text>
            <Text style={st.hint}>Applies to you, views and scheduled runs in this Project.</Text>
          </View>
          {s.actions.map((a) => (
            <View key={a.name} style={st.action} testID={`level-${s.name}-${a.name}`}>
              <Text style={[st.actionLabel, a.level === "off" && { color: color.faint }]}>{a.label}</Text>
              <View style={{ width: 230 }}>
                <Segmented
                  options={levels}
                  value={a.level}
                  onChange={(level) =>
                    edit &&
                    act(`level-${s.name}-${a.name}`, () =>
                      ctx.call<Data>("source_level", { name: s.name, action: a.name, level }, 30000),
                    )
                  }
                />
              </View>
            </View>
          ))}

          <Text style={st.label}>Local columns</Text>
          {s.local_columns.length ? (
            <View style={st.chips}>
              {s.local_columns.map((c) => (
                <Text key={c} style={st.chip}>
                  {s.table}.{c}
                </Text>
              ))}
            </View>
          ) : (
            <Text style={st.hint}>
              None yet. Ask for a notes column; it never syncs to {s.connector_name}.
            </Text>
          )}

          {edit ? (
            <View style={st.disconnect}>
              <View style={{ flex: 1, gap: 2 }}>
                <Text style={st.label}>Disconnect source</Text>
                <Text style={st.hint}>
                  Keeps the {s.rows ?? ""} rows as a local table. Views stop posting to {s.connector_name}.
                </Text>
              </View>
              <Button
                label="Disconnect"
                kind="danger"
                height={34}
                busy={busy === `remove-${s.name}`}
                onPress={async () => {
                  if (
                    !(await confirm(
                      `Disconnect ${s.title ?? s.name}?`,
                      `The rows stay as a local table. Nothing more syncs or posts to ${s.connector_name}.`,
                      "Disconnect",
                    ))
                  )
                    return;
                  act(`remove-${s.name}`, () => ctx.call<Data>("source_remove", { name: s.name }, 30000));
                }}
              />
            </View>
          ) : null}
        </View>
      ))}

      {edit ? (
        adding ? (
          <View style={{ gap: 10 }}>
            <SourcePicker value={picked} onChange={setPicked} allowNone={false} call={ctx.call} />
            <View style={{ flexDirection: "row", gap: 8, justifyContent: "flex-end" }}>
              <Button label="Cancel" kind="secondary" height={36} onPress={() => setAdding(false)} />
              <Button
                label="Add and sync"
                height={36}
                disabled={!picked || picked.pending}
                busy={busy === "add"}
                onPress={() =>
                  picked &&
                  act("add", async () => {
                    const r = await ctx.call<Data>(
                      "source_add",
                      { connector: picked.connector, choice: picked.choice },
                      660000,
                    );
                    setAdding(false);
                    setPicked(null);
                    return r;
                  })
                }
              />
            </View>
          </View>
        ) : (
          <Button
            label={shown.sources.length ? "+ Add another source" : "+ Add a source"}
            kind="secondary"
            height={38}
            onPress={() => setAdding(true)}
          />
        )
      ) : null}
    </View>
  );
}

const st = StyleSheet.create({
  section: { paddingLeft: 4 },
  card: { padding: 14, borderRadius: 14, backgroundColor: color.card, gap: 12 },
  head: { flexDirection: "row", alignItems: "center", gap: 12 },
  title: { fontSize: 15, color: color.text },
  label: { fontSize: 14, color: color.text, fontWeight: "500" },
  hint: { fontSize: 12.5, color: color.muted, lineHeight: 17 },
  error: { fontSize: 12.5, color: color.red, lineHeight: 17 },
  action: { flexDirection: "row", alignItems: "center", gap: 12, flexWrap: "wrap" },
  actionLabel: { flex: 1, minWidth: 140, fontSize: 14, color: color.textSoft },
  chips: { flexDirection: "row", flexWrap: "wrap", gap: 6 },
  chip: {
    fontSize: 12,
    fontFamily: font.mono,
    color: color.textSoft,
    backgroundColor: color.raised,
    borderRadius: 6,
    paddingHorizontal: 8,
    paddingVertical: 3,
    overflow: "hidden",
  },
  disconnect: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    borderTopWidth: 1,
    borderTopColor: color.divider,
    paddingTop: 12,
  },
});
