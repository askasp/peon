// One API in a Project's API calls tab: where it is, its token (stored in this
// Project only), the tables it fills and the actions it can take in a Dataset,
// and its calls. Removing the token stops sync and actions; the rows stay.

import { useState } from "react";
import { StyleSheet, Text, TextInput, View } from "react-native";
import { Icon } from "../Icon";
import { Button, ErrorLine, Segmented, Tap } from "../ui";
import { MethodBadge, PermissionChip } from "./ApiCallDetail";
import { confirm } from "@/lib/confirm";
import { ago } from "@/lib/time";
import { color, font } from "@/lib/theme";
import { levelOf, levels, type ApiService, type Level } from "@/lib/apiCalls";

type Props = {
  service: ApiService;
  /** The Project's name: tokens are stored in it. */
  project: string;
  canEdit: boolean;
  /** A Dataset: write calls are actions with a level, and tables sync. */
  dataset: boolean;
  wide: boolean;
  edit: (event: string, payload: object) => Promise<unknown>;
  onCall: (name: string | null) => void;
  onFile: () => void;
  onMove: () => void;
};

const host = (url: string | null) => (url ? url.replace(/^https?:\/\//, "").replace(/\/.*$/, "") : "");

export function ApiServiceCard({
  service: s,
  project,
  canEdit,
  dataset,
  wide,
  edit,
  onCall,
  onFile,
  onMove,
}: Props) {
  const tables = s.tables ?? [];
  const actions = dataset ? s.calls.filter((c) => c.kind === "write") : [];
  const synced = tables
    .map((t) => t.synced_at)
    .filter(Boolean)
    .sort()
    .pop();
  const summary = [
    tables.length ? `Fills ${tables.map((t) => t.name).join(", ")}` : null,
    actions.length ? `${actions.length} action${actions.length === 1 ? "" : "s"}` : null,
    synced ? `synced ${ago(synced, true)}` : null,
  ].filter(Boolean);

  return (
    <View style={st.card} testID={`api-service-${s.name}`}>
      <View style={st.head}>
        <View style={{ flex: 1, minWidth: 0, gap: 3 }}>
          <View style={st.titleRow}>
            <Text style={st.name}>{s.name}</Text>
            <Text style={st.base} numberOfLines={1}>
              {s.graphql ? "GraphQL" : "REST"}
              {s.base_url ? ` · ${host(s.base_url)}` : ""}
            </Text>
          </View>
          {summary.length ? <Text style={st.sub}>{summary.join(" · ")}</Text> : null}
        </View>
        {s.error ? (
          <Text style={[st.chip, { color: color.red, borderColor: color.red + "55" }]}>invalid</Text>
        ) : null}
        {canEdit && s.source === "project" ? (
          <Tap onPress={onFile} hitSlop={8} testID={`api-json-${s.name}`} style={st.ghostBtn}>
            <Text style={st.ghostText}>Edit calls</Text>
          </Tap>
        ) : null}
        {canEdit && s.source === "shared" ? (
          <Tap hitSlop={8} testID={`api-move-${s.name}`} onPress={onMove} style={st.ghostBtn}>
            <Text style={st.ghostText}>Move into this Project</Text>
          </Tap>
        ) : null}
      </View>
      {s.error ? <Text style={st.bad}>{s.error}</Text> : null}

      {s.secret && s.source === "project" ? (
        <TokenRow name={s.secret} token={s.token ?? null} project={project} canEdit={canEdit} edit={edit} />
      ) : null}

      {tables.length ? (
        <View style={st.section}>
          <Text style={st.label}>Fills tables</Text>
          {tables.map((t) => (
            <View key={t.name} style={st.line} testID={`api-table-${t.name}`}>
              <Text style={st.mono}>{t.name}</Text>
              <View style={{ flex: 1, minWidth: 0, gap: 2 }}>
                <Text style={st.lineText} numberOfLines={wide ? 1 : 2}>
                  from {t.call} · {t.columns.join(", ")}
                </Text>
                {t.error ? <Text style={st.bad}>{t.error}</Text> : null}
              </View>
              <Text style={st.meta}>
                {t.rows != null ? `${t.rows} rows · ` : ""}every {t.every_minutes} min
              </Text>
            </View>
          ))}
        </View>
      ) : null}

      {actions.length ? (
        <View style={st.section}>
          <Text style={st.label}>Actions</Text>
          {actions.map((c) => (
            <ActionRow
              key={c.name}
              name={c.name}
              description={c.description}
              level={levelOf[c.permission]}
              canEdit={canEdit && s.source === "project"}
              set={(level) => edit("api_level", { service: s.name, call: c.name, level })}
            />
          ))}
        </View>
      ) : null}

      <View style={st.section}>
        <Text style={st.label}>Calls</Text>
        {s.calls.map((c) => (
          <Tap
            key={c.name}
            kb="row"
            onPress={() => onCall(c.name)}
            style={st.call}
            testID={`api-call-${s.name}-${c.name}`}
          >
            <MethodBadge method={c.method} />
            <View style={[st.callText, wide && st.callTextWide]}>
              <Text style={st.callName} numberOfLines={1}>
                {c.name}
              </Text>
              <Text style={st.callPath} numberOfLines={1}>
                {c.path}
              </Text>
            </View>
            {dataset && c.kind === "write" ? null : <PermissionChip permission={c.permission} />}
          </Tap>
        ))}
        {canEdit && s.source === "project" ? (
          <Tap onPress={() => onCall(null)} style={st.addRow} testID={`api-add-${s.name}`}>
            <Text style={st.addText}>+ Call</Text>
          </Tap>
        ) : null}
      </View>
    </View>
  );
}

/** The service's token: set (last characters, who added it) with Replace and Remove, or a field to paste it. */
function TokenRow({
  name,
  token,
  project,
  canEdit,
  edit,
}: {
  name: string;
  token: ApiService["token"] | null;
  project: string;
  canEdit: boolean;
  edit: (event: string, payload: object) => Promise<unknown>;
}) {
  const [replacing, setReplacing] = useState(false);
  const [value, setValue] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function run(key: string, fn: () => Promise<unknown>) {
    setBusy(key);
    setError(null);
    try {
      await fn();
      setValue("");
      setReplacing(false);
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(null);
  }

  const asking = !token || replacing;
  return (
    <View style={{ gap: 6 }}>
      <View style={[st.token, !token && st.tokenMissing]} testID={`api-token-${name}`}>
        <View style={[st.lock, !token && { backgroundColor: color.needsWash }]}>
          <Icon name="lock" size={14} color={token ? color.accentText : color.needs} />
        </View>
        <View style={{ flex: 1, minWidth: 0, gap: 2 }}>
          <View style={st.titleRow}>
            <Text style={[st.mono, !token && { color: color.needs }]}>{name}</Text>
            {token?.hint ? <Text style={st.hint}>{token.hint}</Text> : null}
          </View>
          <Text style={st.meta} numberOfLines={2}>
            {token
              ? `Stored in ${project}${token.set_by ? ` · added by ${token.set_by}` : ""} · ${ago(token.updated_at, true)}`
              : `Not set · stored in ${project} only, used by every call below`}
          </Text>
        </View>
        {token && canEdit && !replacing ? (
          <>
            <Tap style={st.ghostBtn} onPress={() => setReplacing(true)} testID={`api-token-replace-${name}`}>
              <Text style={st.ghostText}>Replace</Text>
            </Tap>
            <Tap
              style={st.ghostBtn}
              testID={`api-token-remove-${name}`}
              onPress={async () => {
                if (
                  await confirm(
                    `Remove ${name}?`,
                    "Sync and actions for this API stop. Its tables stay as local rows.",
                    "Remove",
                  )
                )
                  run("remove", () => edit("api_secret_remove", { name }));
              }}
            >
              <Text style={[st.ghostText, { color: color.red }]}>
                {busy === "remove" ? "Removing…" : "Remove"}
              </Text>
            </Tap>
          </>
        ) : null}
      </View>
      {asking && canEdit ? (
        <View style={st.paste}>
          <TextInput
            value={value}
            onChangeText={setValue}
            placeholder={replacing ? "Paste the new token" : "Paste token"}
            placeholderTextColor={color.faint}
            secureTextEntry
            autoCapitalize="none"
            autoCorrect={false}
            style={st.pasteInput}
            testID={`api-secret-${name}`}
          />
          {replacing ? (
            <Button label="Cancel" kind="secondary" height={32} onPress={() => setReplacing(false)} />
          ) : null}
          <Button
            label="Save"
            height={32}
            busy={busy === "save"}
            disabled={!value.trim()}
            onPress={() => run("save", () => edit("api_secret", { name, value }))}
          />
        </View>
      ) : null}
      <ErrorLine message={error} />
    </View>
  );
}

function ActionRow({
  name,
  description,
  level,
  canEdit,
  set,
}: {
  name: string;
  description: string | null;
  level: Level;
  canEdit: boolean;
  set: (level: Level) => Promise<unknown>;
}) {
  const [shown, setShown] = useState(level);
  const [error, setError] = useState<string | null>(null);
  return (
    <View style={{ gap: 4 }}>
      <View style={st.line} testID={`api-action-${name}`}>
        <View style={{ flex: 1, minWidth: 140, gap: 2 }}>
          <Text style={[st.mono, shown === "off" && { color: color.faint }]}>{name}</Text>
          {description ? (
            <Text style={st.meta} numberOfLines={1}>
              {description}
            </Text>
          ) : null}
        </View>
        {canEdit ? (
          <View style={{ width: 236 }}>
            <Segmented
              options={levels}
              value={shown}
              onChange={async (v) => {
                const before = shown;
                setShown(v);
                setError(null);
                try {
                  await set(v);
                } catch (e: any) {
                  setShown(before);
                  setError(e.message);
                }
              }}
            />
          </View>
        ) : (
          <Text style={st.meta}>{levels.find((l) => l.value === shown)?.label}</Text>
        )}
      </View>
      <ErrorLine message={error} />
    </View>
  );
}

const st = StyleSheet.create({
  card: {
    padding: 14,
    gap: 12,
    borderRadius: 14,
    backgroundColor: color.card,
    borderWidth: 1,
    borderColor: color.border,
  },
  head: { flexDirection: "row", alignItems: "center", gap: 10 },
  titleRow: { flexDirection: "row", alignItems: "baseline", gap: 10, flexWrap: "wrap" },
  name: { fontFamily: font.mono, fontSize: 15, fontWeight: "600", color: color.text },
  base: { fontFamily: font.mono, fontSize: 12, color: color.faint, flexShrink: 1 },
  sub: { fontSize: 12.5, color: color.muted },
  chip: {
    fontSize: 11.5,
    paddingHorizontal: 7,
    paddingVertical: 1,
    borderRadius: 5,
    borderWidth: 1,
    overflow: "hidden",
  },
  ghostBtn: {
    paddingHorizontal: 10,
    paddingVertical: 5,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: color.outline,
  },
  ghostText: { fontSize: 12.5, color: color.textSoft },
  bad: { fontSize: 12, color: color.red },
  token: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    padding: 10,
    borderRadius: 10,
    backgroundColor: color.bg,
    borderWidth: 1,
    borderColor: color.border,
  },
  tokenMissing: { backgroundColor: color.needsCard, borderColor: color.needsBorder },
  lock: {
    width: 28,
    height: 28,
    borderRadius: 8,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: color.accentWash,
  },
  hint: { fontFamily: font.mono, fontSize: 12, color: color.faint },
  paste: { flexDirection: "row", alignItems: "center", gap: 8 },
  pasteInput: {
    flex: 1,
    flexBasis: 0,
    minWidth: 0,
    height: 32,
    borderRadius: 8,
    backgroundColor: color.field,
    paddingHorizontal: 10,
    color: color.text,
    fontSize: 13,
    outlineStyle: "none",
  } as any,
  section: { gap: 2 },
  label: {
    fontSize: 11,
    fontWeight: "600",
    letterSpacing: 0.6,
    textTransform: "uppercase",
    color: color.faint,
    paddingBottom: 4,
  },
  line: {
    flexDirection: "row",
    alignItems: "center",
    flexWrap: "wrap",
    gap: 12,
    paddingVertical: 7,
    borderTopWidth: 1,
    borderTopColor: color.hairline,
  },
  lineText: { fontSize: 12.5, color: color.textDim },
  mono: { fontFamily: font.mono, fontSize: 13, color: color.text },
  meta: { fontSize: 12, color: color.muted },
  call: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingVertical: 9,
    borderTopWidth: 1,
    borderTopColor: color.hairline,
  },
  callText: { flex: 1, minWidth: 0, gap: 2 },
  callTextWide: { flexDirection: "row", alignItems: "baseline", gap: 14 },
  callName: { fontFamily: font.mono, fontSize: 13, color: color.text },
  callPath: { fontFamily: font.mono, fontSize: 12, color: color.faint, flexShrink: 1 },
  addRow: { paddingVertical: 8 },
  addText: { fontSize: 13, color: color.muted },
});
