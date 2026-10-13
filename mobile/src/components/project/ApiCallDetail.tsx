// One API call: what it sends (method, path, permission, description), how a
// procedure names it, and Send to try it by hand with path values, a query
// and a body. A new call (callName null) starts empty.

import { useState } from "react";
import { ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { Icon } from "../Icon";
import { Button, ErrorLine, Tap } from "../ui";
import { confirm } from "@/lib/confirm";
import { useWide } from "@/lib/useWide";
import { color, font } from "@/lib/theme";
import {
  methods,
  methodTint,
  permissions,
  pretty,
  reference,
  withCall,
  type ApiCall,
  type ApiService,
  type TryResult,
} from "@/lib/apiCalls";
import type { ProjectCtx } from "./types";

const blank: ApiCall = {
  name: "",
  method: "GET",
  path: "/",
  permission: "allow",
  description: "",
  params: [],
};

export function ApiCallDetail({
  ctx,
  service,
  callName,
  onBack,
  onSaved,
  save,
}: {
  ctx: ProjectCtx;
  service: ApiService;
  callName: string | null;
  onBack: () => void;
  /** After a save, with the call's (maybe new) name. */
  onSaved: (name: string) => void;
  save: (content: string) => Promise<unknown>;
}) {
  const wide = useWide();
  const saved = service.calls.find((c) => c.name === callName) ?? null;
  const editable = ctx.canEdit && service.source === "project";
  const [draft, setDraft] = useState<ApiCall>(saved ?? blank);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const dirty =
    !saved ||
    draft.name !== saved.name ||
    draft.method !== saved.method ||
    draft.path !== saved.path ||
    draft.permission !== saved.permission ||
    (draft.description ?? "") !== (saved.description ?? "");
  const set = (patch: Partial<ApiCall>) => setDraft((d) => ({ ...d, ...patch }));

  async function act(key: string, fn: () => Promise<void>) {
    setBusy(key);
    setError(null);
    try {
      await fn();
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(null);
  }

  const store = () =>
    act("save", async () => {
      const name = draft.name.trim();
      if (!/^[a-z0-9_]+$/.test(name)) throw new Error("Name it in lowercase snake_case.");
      if (name !== callName && service.calls.some((c) => c.name === name))
        throw new Error(`${service.name} already has ${name}.`);
      await save(withCall(service.raw, callName, { ...draft, name }));
      onSaved(name);
    });

  const remove = () =>
    act("delete", async () => {
      if (!callName) return onBack();
      if (!(await confirm(`Delete ${callName}?`, "Procedures that call it stop working.", "Delete"))) return;
      await save(withCall(service.raw, callName, null));
      onBack();
    });

  return (
    <ScrollView
      contentContainerStyle={[st.body, wide && { paddingHorizontal: 28 }]}
      keyboardShouldPersistTaps="handled"
    >
      <View style={st.top}>
        <Tap onPress={onBack} hitSlop={8} style={st.back} testID="api-back">
          <Icon name="back" size={14} color={color.muted} strokeWidth={2.4} />
          <Text style={st.backText}>API calls</Text>
        </Tap>
        <Text style={st.title} numberOfLines={1}>
          {service.name}.{saved?.name ?? "new call"}
        </Text>
        <View style={{ flex: 1 }} />
        {editable ? (
          <Tap onPress={remove} hitSlop={8} testID="api-call-delete">
            <Text style={st.delete}>Delete</Text>
          </Tap>
        ) : null}
      </View>

      {saved ? (
        <View style={st.ref}>
          <Text style={st.refLabel}>In a procedure</Text>
          <Text selectable style={st.refCode}>
            call: {reference(service.name, saved.name)}
          </Text>
        </View>
      ) : null}
      {service.source === "shared" ? (
        <Text style={st.meta}>Shared from the setup Project. Move it into this Project to edit it.</Text>
      ) : null}

      <View style={st.form}>
        <Field label="Name">
          <TextInput
            value={draft.name}
            onChangeText={(v) => set({ name: v })}
            editable={editable}
            autoCapitalize="none"
            autoCorrect={false}
            placeholder="get_charge"
            placeholderTextColor={color.faint}
            style={[st.field, st.mono]}
            testID="api-call-name"
          />
        </Field>
        <Field label="Method">
          <Choices
            options={methods}
            value={draft.method}
            onChange={(m) => set({ method: m })}
            disabled={!editable}
          />
        </Field>
        <Field label="Path">
          <View style={st.pathRow}>
            {service.base_url ? (
              <Text style={st.baseUrl} numberOfLines={1}>
                {service.base_url}
              </Text>
            ) : null}
            <TextInput
              value={draft.path}
              onChangeText={(v) => set({ path: v })}
              editable={editable}
              autoCapitalize="none"
              autoCorrect={false}
              style={[st.field, st.mono]}
              testID="api-call-path"
            />
          </View>
        </Field>
        <Field label="Agents">
          <Choices
            options={permissions}
            labels={{ allow: "run it", ask: "ask first", deny: "never" }}
            value={draft.permission}
            onChange={(p) => set({ permission: p as ApiCall["permission"] })}
            disabled={!editable}
          />
        </Field>
        <Field label="Description" top>
          <TextInput
            value={draft.description ?? ""}
            onChangeText={(v) => set({ description: v })}
            editable={editable}
            multiline
            placeholder="What it does, and what its values look like"
            placeholderTextColor={color.faint}
            style={[st.field, st.area]}
            testID="api-call-description"
          />
        </Field>
      </View>
      {editable && dirty ? (
        <View style={{ flexDirection: "row" }}>
          <Button
            label={saved ? "Save" : "Add call"}
            height={36}
            busy={busy === "save"}
            disabled={!draft.name.trim() || !draft.path.trim()}
            onPress={store}
            testID="api-call-save"
          />
        </View>
      ) : null}
      <ErrorLine message={error} />

      {saved ? <TryIt ctx={ctx} service={service} call={saved} /> : null}
    </ScrollView>
  );
}

/** Send the saved call by hand and read what came back. */
function TryIt({ ctx, service, call }: { ctx: ProjectCtx; service: ApiService; call: ApiCall }) {
  const [values, setValues] = useState<Record<string, string>>({});
  const [query, setQuery] = useState("");
  const [body, setBody] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<TryResult | null>(null);
  const hasBody = call.method !== "GET" && call.method !== "DELETE";
  const canSend = ctx.canEdit && service.ready;

  async function send() {
    setError(null);
    let args: Record<string, unknown>;
    try {
      args = {
        ...values,
        ...(query.trim() ? { query: JSON.parse(query) } : {}),
        ...(hasBody && body.trim() ? { body: JSON.parse(body) } : {}),
      };
    } catch {
      return setError('Query and body are JSON objects, like {"limit": 5}.');
    }
    if (
      call.method !== "GET" &&
      !(await confirm(`Send ${call.method}?`, `${call.method} ${service.base_url ?? ""}${call.path}`, "Send"))
    )
      return;
    setBusy(true);
    try {
      setResult(
        await ctx.call<TryResult>("api_try", { service: service.name, call: call.name, args }, 90000),
      );
    } catch (e: any) {
      setError(e.message);
      setResult(null);
    }
    setBusy(false);
  }

  const ok = result && result.status >= 200 && result.status < 300;
  return (
    <View style={st.try}>
      <View style={st.tryHead}>
        <MethodBadge method={call.method} />
        <Text style={st.tryPath} numberOfLines={1}>
          {call.path}
        </Text>
        <View style={{ flex: 1 }} />
        <Button
          label="Send"
          kind="accent"
          height={32}
          busy={busy}
          disabled={!canSend || call.params.some((p) => !values[p]?.trim())}
          onPress={send}
          testID="api-try-send"
        />
      </View>
      {!service.ready && service.secret ? (
        <Text style={[st.meta, { color: color.needs }]}>Set {service.secret} first.</Text>
      ) : null}
      {call.params.map((p) => (
        <View key={p} style={st.tryRow}>
          <Text style={st.tryLabel}>{p}</Text>
          <TextInput
            value={values[p] ?? ""}
            onChangeText={(v) => setValues((x) => ({ ...x, [p]: v }))}
            autoCapitalize="none"
            autoCorrect={false}
            style={[st.field, st.mono, { flex: 1 }]}
            testID={`api-try-${p}`}
          />
        </View>
      ))}
      <View style={st.tryRow}>
        <Text style={st.tryLabel}>query</Text>
        <TextInput
          value={query}
          onChangeText={setQuery}
          autoCapitalize="none"
          autoCorrect={false}
          placeholder='{"limit": 5}'
          placeholderTextColor={color.faint}
          style={[st.field, st.mono, { flex: 1 }]}
          testID="api-try-query"
        />
      </View>
      {hasBody ? (
        <View style={[st.tryRow, { alignItems: "flex-start" }]}>
          <Text style={[st.tryLabel, { paddingTop: 8 }]}>body</Text>
          <TextInput
            value={body}
            onChangeText={setBody}
            multiline
            autoCapitalize="none"
            autoCorrect={false}
            placeholder="{}"
            placeholderTextColor={color.faint}
            style={[st.field, st.mono, st.area, { flex: 1 }]}
            testID="api-try-body"
          />
        </View>
      ) : null}
      <ErrorLine message={error} />
      {result ? (
        <View style={{ gap: 8 }} testID="api-try-result">
          <View style={st.resultHead}>
            <Text style={[st.statusCode, { color: ok ? color.teal : color.red }]}>{result.status}</Text>
            <Text style={st.meta}>{result.ms} ms</Text>
            <Text selectable style={[st.meta, st.mono, { flex: 1 }]} numberOfLines={1}>
              {result.url}
            </Text>
          </View>
          <ScrollView style={st.response} nestedScrollEnabled>
            <Text selectable style={st.responseText}>
              {pretty(result.body) || "(empty)"}
            </Text>
          </ScrollView>
        </View>
      ) : null}
    </View>
  );
}

export function MethodBadge({ method }: { method: string }) {
  const t = methodTint[method] ?? { bg: color.field, fg: color.textSoft };
  return <Text style={[bs.method, { backgroundColor: t.bg, color: t.fg }]}>{method}</Text>;
}

export function PermissionChip({ permission }: { permission: string }) {
  const tint = permission === "deny" ? color.red : permission === "ask" ? color.needs : color.muted;
  return <Text style={[bs.perm, { color: tint }]}>{permission}</Text>;
}

function Field({ label, top, children }: { label: string; top?: boolean; children: React.ReactNode }) {
  return (
    <View style={[st.fieldRow, top && { alignItems: "flex-start" }]}>
      <Text style={[st.label, top && { paddingTop: 8 }]}>{label}</Text>
      <View style={{ flex: 1, minWidth: 0 }}>{children}</View>
    </View>
  );
}

function Choices({
  options,
  labels,
  value,
  onChange,
  disabled,
}: {
  options: string[];
  labels?: Record<string, string>;
  value: string;
  onChange: (v: string) => void;
  disabled?: boolean;
}) {
  return (
    <View style={st.choices}>
      {options.map((o) => {
        const on = o === value;
        return (
          <Tap
            key={o}
            onPress={() => onChange(o)}
            disabled={disabled}
            style={[st.choice, on && st.choiceOn]}
            testID={`api-choice-${o}`}
          >
            <Text style={[st.choiceText, on && { color: color.textStrong }]}>{labels?.[o] ?? o}</Text>
          </Tap>
        );
      })}
    </View>
  );
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 16, paddingTop: 14, paddingBottom: 40, gap: 16, maxWidth: 900, width: "100%" },
  top: { flexDirection: "row", alignItems: "center", gap: 10 },
  back: { flexDirection: "row", alignItems: "center", gap: 3 },
  backText: { fontSize: 13, color: color.muted },
  title: { fontFamily: font.mono, fontSize: 16, fontWeight: "600", color: color.text, flexShrink: 1 },
  delete: { fontSize: 13, color: color.red },
  meta: { fontSize: 12, lineHeight: 18, color: color.faint },
  mono: { fontFamily: font.mono },
  ref: { flexDirection: "row", alignItems: "center", gap: 10, flexWrap: "wrap" },
  refLabel: { fontSize: 12, color: color.faint },
  refCode: {
    fontFamily: font.mono,
    fontSize: 12,
    color: "#b9a8ec",
    backgroundColor: "#1c1830",
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderRadius: 5,
    overflow: "hidden",
  },
  form: { gap: 10 },
  fieldRow: { flexDirection: "row", alignItems: "center", gap: 8 },
  label: { width: 92, fontSize: 13, color: color.faint },
  field: {
    height: 34,
    borderRadius: 8,
    backgroundColor: color.field,
    borderWidth: 1,
    borderColor: color.border,
    paddingHorizontal: 10,
    color: color.text,
    fontSize: 13,
    outlineStyle: "none",
  } as any,
  area: { height: undefined, minHeight: 64, paddingVertical: 8, textAlignVertical: "top" },
  pathRow: { gap: 4 },
  baseUrl: { fontFamily: font.mono, fontSize: 11.5, color: color.faint },
  choices: { flexDirection: "row", flexWrap: "wrap", gap: 6 },
  choice: { paddingHorizontal: 10, paddingVertical: 5, borderRadius: 7, backgroundColor: color.field },
  choiceOn: { backgroundColor: color.pill },
  choiceText: { fontSize: 12, color: color.textDim },
  try: {
    gap: 10,
    padding: 12,
    borderRadius: 12,
    backgroundColor: "#17171c",
    borderWidth: 1,
    borderColor: color.border,
  },
  tryHead: { flexDirection: "row", alignItems: "center", gap: 10 },
  tryPath: { fontFamily: font.mono, fontSize: 12.5, color: color.textSoft, flexShrink: 1 },
  tryRow: { flexDirection: "row", alignItems: "center", gap: 10 },
  tryLabel: { width: 80, fontFamily: font.mono, fontSize: 12, color: color.muted },
  resultHead: { flexDirection: "row", alignItems: "center", gap: 10 },
  statusCode: { fontFamily: font.mono, fontSize: 14, fontWeight: "700" },
  response: {
    maxHeight: 420,
    borderRadius: 8,
    backgroundColor: color.bgDeep,
    borderWidth: 1,
    borderColor: color.hairline,
    padding: 10,
  },
  responseText: { fontFamily: font.mono, fontSize: 12, lineHeight: 17, color: color.textSoft },
});

const bs = StyleSheet.create({
  method: {
    width: 58,
    textAlign: "center",
    paddingVertical: 2,
    borderRadius: 5,
    overflow: "hidden",
    fontFamily: font.mono,
    fontSize: 11,
    fontWeight: "600",
  },
  perm: { fontSize: 12 },
});
