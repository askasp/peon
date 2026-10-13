// A Project's API calls: one block per service (its file in .peon/api/) with
// a row per call. Describe calls at the top and the chat writes them; a row
// opens the call to edit it and send it by hand.

import { useState } from "react";
import { ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { Icon } from "../Icon";
import { Button, ErrorLine, Loading, Tap } from "../ui";
import { ApiCallDetail, MethodBadge, PermissionChip } from "./ApiCallDetail";
import { confirm } from "@/lib/confirm";
import { singleChat } from "@/lib/folders";
import { useLoad } from "@/lib/useLoad";
import { useWide } from "@/lib/useWide";
import { color, font } from "@/lib/theme";
import type { ApiService } from "@/lib/apiCalls";
import type { ProjectCtx } from "./types";

type Open = { service: string; call: string | null } | { json: string };

export function ApiCallsTab({ ctx, onRan }: { ctx: ProjectCtx; onRan?: () => void }) {
  const wide = useWide();
  const [open, setOpen] = useState<Open | null>(null);
  const [error, setError] = useState<string | null>(null);
  const { data, error: loadError } = useLoad(
    () => ctx.call<{ services: ApiService[] }>("api_calls", {}, 30000).then((r) => r.services),
    [ctx.project.id, ctx.changed],
  );
  // What an edit replied with, until the next load replaces it.
  const [fresh, setFresh] = useState<{ base: ApiService[] | null; list: ApiService[] } | null>(null);
  const services = fresh && fresh.base === data ? fresh.list : data;

  /** Sends an edit; the reply is the new list. Throws so forms can show it. */
  async function edit(event: string, payload: object) {
    const r = await ctx.call<{ services: ApiService[] }>(event, payload, 60000);
    setFresh({ base: data, list: r.services });
    return r.services;
  }

  async function generate(description: string) {
    const r = await ctx.call<{ session_id: string }>("api_generate", { description }, 60000);
    if (singleChat(ctx.project.kind)) onRan?.();
    else router.push(`/session/${r.session_id}`);
  }

  const shownService = open && "service" in open ? services?.find((s) => s.name === open.service) : null;
  if (open && "service" in open && shownService)
    return (
      <ApiCallDetail
        key={`${shownService.name}.${open.call ?? ""}`}
        ctx={ctx}
        service={shownService}
        callName={open.call}
        onBack={() => setOpen(null)}
        onSaved={(name) => setOpen({ service: shownService.name, call: name })}
        save={(content) => edit("api_save", { service: shownService.name, content })}
      />
    );

  const jsonService = open && "json" in open ? services?.find((s) => s.name === open.json) : null;
  if (jsonService)
    return (
      <JsonEditor
        service={jsonService}
        wide={wide}
        onBack={() => setOpen(null)}
        save={async (content) => {
          await edit("api_save", { service: jsonService.name, content });
          setOpen(null);
        }}
        remove={async () => {
          await edit("api_delete", { service: jsonService.name });
          setOpen(null);
        }}
      />
    );

  return (
    <ScrollView
      contentContainerStyle={[st.body, wide && { paddingHorizontal: 28 }]}
      keyboardShouldPersistTaps="handled"
    >
      {ctx.canEdit ? <GenerateBox onGenerate={generate} empty={services?.length === 0} /> : null}
      <ErrorLine message={loadError ?? error} />
      {services == null ? <Loading /> : null}
      {services?.length === 0 ? <Text style={st.empty}>No API calls yet.</Text> : null}

      {(services ?? []).map((s) => (
        <View key={s.name} style={st.service} testID={`api-service-${s.name}`}>
          <View style={st.serviceHead}>
            <Text style={st.serviceName}>{s.name}</Text>
            {s.base_url ? (
              <Text style={st.base} numberOfLines={1}>
                {s.base_url}
              </Text>
            ) : null}
            <View style={{ flex: 1 }} />
            <StatusChip service={s} />
            {ctx.canEdit && s.source === "project" ? (
              <Tap onPress={() => setOpen({ json: s.name })} hitSlop={8} testID={`api-json-${s.name}`}>
                <Text style={st.link}>Edit file</Text>
              </Tap>
            ) : null}
            {ctx.canEdit && s.source === "shared" ? (
              <Tap
                hitSlop={8}
                testID={`api-move-${s.name}`}
                onPress={async () => {
                  setError(null);
                  try {
                    await edit("api_move", { service: s.name });
                  } catch (e: any) {
                    setError(e.message);
                  }
                }}
              >
                <Text style={st.link}>Move into this Project</Text>
              </Tap>
            ) : null}
          </View>
          {s.error ? <Text style={st.bad}>{s.error}</Text> : null}
          {!s.ready && !s.error && s.secret && ctx.canEdit ? (
            <SecretRow name={s.secret} save={(value) => edit("api_secret", { name: s.secret, value })} />
          ) : null}
          {s.calls.map((c) => (
            <Tap
              key={c.name}
              kb="row"
              onPress={() => setOpen({ service: s.name, call: c.name })}
              style={st.row}
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
              <PermissionChip permission={c.permission} />
            </Tap>
          ))}
          {ctx.canEdit && s.source === "project" ? (
            <Tap
              onPress={() => setOpen({ service: s.name, call: null })}
              style={st.addRow}
              testID={`api-add-${s.name}`}
            >
              <Text style={st.addText}>+ Call</Text>
            </Tap>
          ) : null}
        </View>
      ))}
    </ScrollView>
  );
}

/** Describe what to call; the chat reads the docs and writes the file. */
function GenerateBox({ onGenerate, empty }: { onGenerate: (text: string) => Promise<void>; empty: boolean }) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function go() {
    setBusy(true);
    setError(null);
    try {
      await onGenerate(text.trim());
      setText("");
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(false);
  }
  return (
    <View style={[st.generate, empty && st.generateEmpty]}>
      <View style={st.generateRow}>
        <Icon name="compose" size={16} color={color.accentText} />
        <TextInput
          value={text}
          onChangeText={setText}
          placeholder="Stripe: look up a charge, refund it"
          returnKeyType="go"
          placeholderTextColor={color.faint}
          style={st.generateInput}
          onSubmitEditing={() => text.trim() && go()}
          testID="api-generate-text"
        />
        <Button
          label="Generate"
          kind="accent"
          height={34}
          busy={busy}
          disabled={!text.trim()}
          onPress={go}
          testID="api-generate"
        />
      </View>
      <ErrorLine message={error} />
    </View>
  );
}

function SecretRow({ name, save }: { name: string; save: (value: string) => Promise<unknown> }) {
  const [value, setValue] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <View style={{ gap: 6 }}>
      <View style={st.secret}>
        <Text style={st.secretName}>{name}</Text>
        <TextInput
          value={value}
          onChangeText={setValue}
          placeholder="Paste the key"
          placeholderTextColor={color.faint}
          secureTextEntry
          style={st.secretInput}
          testID={`api-secret-${name}`}
        />
        <Button
          label="Save"
          height={30}
          busy={busy}
          disabled={!value}
          onPress={async () => {
            setBusy(true);
            setError(null);
            try {
              await save(value);
              setValue("");
            } catch (e: any) {
              setError(e.message);
            }
            setBusy(false);
          }}
        />
      </View>
      <ErrorLine message={error} />
    </View>
  );
}

function StatusChip({ service: s }: { service: ApiService }) {
  const [label, tint] = s.error
    ? ["invalid", color.red]
    : s.source === "shared"
      ? ["shared", color.muted]
      : s.ready
        ? ["ready", color.teal]
        : [`needs ${s.secret}`, color.needs];
  return <Text style={[st.status, { color: tint, borderColor: tint + "55" }]}>{label}</Text>;
}

/** The service's whole file: base URL, auth, rate limit, every call. */
function JsonEditor({
  service,
  wide,
  onBack,
  save,
  remove,
}: {
  service: ApiService;
  wide: boolean;
  onBack: () => void;
  save: (content: string) => Promise<void>;
  remove: () => Promise<void>;
}) {
  const [text, setText] = useState(service.raw);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function act(fn: () => Promise<void>) {
    setBusy(true);
    setError(null);
    try {
      await fn();
    } catch (e: any) {
      setError(e.message);
      setBusy(false);
    }
  }
  return (
    <ScrollView contentContainerStyle={[st.body, wide && { paddingHorizontal: 28 }]}>
      <View style={st.top}>
        <Tap onPress={onBack} hitSlop={8} style={st.back} testID="api-back">
          <Icon name="back" size={14} color={color.muted} strokeWidth={2.4} />
          <Text style={st.backText}>API calls</Text>
        </Tap>
        <Text style={st.title} numberOfLines={1}>
          {service.path}
        </Text>
        <View style={{ flex: 1 }} />
        <Tap
          hitSlop={8}
          onPress={async () => {
            if (await confirm(`Delete ${service.name}?`, "Procedures that call it stop working.", "Delete"))
              act(remove);
          }}
        >
          <Text style={[st.link, { color: color.red }]}>Delete</Text>
        </Tap>
      </View>
      <TextInput
        value={text}
        onChangeText={setText}
        multiline
        autoCapitalize="none"
        autoCorrect={false}
        spellCheck={false}
        style={st.code}
        testID="api-json-text"
      />
      <ErrorLine message={error} />
      <View style={{ flexDirection: "row", gap: 10 }}>
        <Button
          label="Save"
          height={38}
          busy={busy}
          disabled={text === service.raw}
          onPress={() => act(() => save(text))}
          testID="api-json-save"
        />
      </View>
    </ScrollView>
  );
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 16, paddingTop: 14, paddingBottom: 40, gap: 18, maxWidth: 900, width: "100%" },
  empty: { fontSize: 13, color: color.muted },
  generate: {
    gap: 8,
    padding: 10,
    borderRadius: 12,
    backgroundColor: color.card,
    borderWidth: 1,
    borderColor: color.border,
  },
  generateEmpty: { borderColor: color.accentBorder, backgroundColor: color.accentCard },
  generateRow: { flexDirection: "row", alignItems: "center", gap: 10 },
  generateInput: {
    flex: 1,
    flexBasis: 0,
    minWidth: 0,
    height: 34,
    color: color.text,
    fontSize: 14,
    outlineStyle: "none",
  } as any,
  service: { gap: 0 },
  serviceHead: {
    flexDirection: "row",
    alignItems: "center",
    flexWrap: "wrap",
    gap: 10,
    paddingBottom: 8,
    borderBottomWidth: 1,
    borderBottomColor: color.divider,
  },
  serviceName: { fontFamily: font.mono, fontSize: 14, fontWeight: "600", color: color.text },
  base: { fontFamily: font.mono, fontSize: 12, color: color.faint, flexShrink: 1 },
  status: {
    fontSize: 11.5,
    paddingHorizontal: 7,
    paddingVertical: 1,
    borderRadius: 5,
    borderWidth: 1,
    overflow: "hidden",
  },
  link: { fontSize: 13, color: color.accentText },
  bad: { fontSize: 12, color: color.red, paddingTop: 8 },
  secret: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    marginTop: 8,
    padding: 8,
    paddingLeft: 12,
    borderRadius: 10,
    backgroundColor: color.needsCard,
    borderWidth: 1,
    borderColor: color.needsBorder,
  },
  secretName: { fontFamily: font.mono, fontSize: 12.5, color: color.needs },
  secretInput: {
    flex: 1,
    flexBasis: 0,
    minWidth: 0,
    height: 30,
    borderRadius: 7,
    backgroundColor: color.field,
    paddingHorizontal: 10,
    color: color.text,
    fontSize: 13,
    outlineStyle: "none",
  } as any,
  row: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingVertical: 10,
    borderBottomWidth: 1,
    borderBottomColor: "#1c1c21",
  },
  callText: { flex: 1, minWidth: 0, gap: 2 },
  callTextWide: { flexDirection: "row", alignItems: "baseline", gap: 14 },
  callName: { fontFamily: font.mono, fontSize: 13, color: color.text },
  callPath: { fontFamily: font.mono, fontSize: 12, color: color.faint, flexShrink: 1 },
  addRow: { paddingVertical: 9 },
  addText: { fontSize: 13, color: color.muted },
  top: { flexDirection: "row", alignItems: "center", gap: 10 },
  back: { flexDirection: "row", alignItems: "center", gap: 3 },
  backText: { fontSize: 13, color: color.muted },
  title: { fontFamily: font.mono, fontSize: 15, fontWeight: "600", color: color.text, flexShrink: 1 },
  code: {
    minHeight: 360,
    borderRadius: 10,
    backgroundColor: "#17171c",
    borderWidth: 1,
    borderColor: color.border,
    padding: 12,
    color: color.text,
    fontFamily: font.mono,
    fontSize: 12.5,
    lineHeight: 18,
    textAlignVertical: "top",
    outlineStyle: "none",
  } as any,
});
