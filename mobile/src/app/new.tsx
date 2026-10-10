import { useState } from "react";
import { ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { BackHeader, Button, ErrorLine, Screen, Segmented, SectionLabel, Tap, Toggle } from "@/components/ui";
import { notify } from "@/lib/notice";
import { ask } from "@/lib/peon";
import { useLoad } from "@/lib/useLoad";
import { color, font } from "@/lib/theme";

type Kind = "code" | "routine" | "chat";
type Options = {
  known_repos: string[];
  known_routines: string[];
  connectors: { name: string; tools: number; ready: boolean }[];
};

const kinds: { kind: Kind; label: string; detail: string }[] = [
  { kind: "code", label: "Code", detail: "Clone a repository, or start an empty one. Sessions code in it." },
  { kind: "routine", label: "Routine", detail: "A folder with instructions and skills. Does one job." },
  { kind: "chat", label: "Chat", detail: "General chat. Files it makes are artifacts." },
];

const slug = (s: string) =>
  s
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/^-+|-+$/g, "");
const validName = (s: string) => /^[a-z0-9][a-z0-9-]*$/.test(s);
const isGithub = (s: string) => /github\.com[/:][^/\s]+\/[^/\s]+/.test(s);

// New project: code (clone or new repo), routine (one job, drafted by a session) or chat.
/** What creating the project makes, like the web shows it. */
function willCreate(kind: Kind, name: string, source: string, token: string, importing: boolean): string {
  if (kind === "routine") {
    if (importing) return `routines/${name}/   existing folder, files kept as they are`;
    const skill = name.split("-").pop();
    return [
      `routines/${name}/`,
      "  AGENTS.md                   drafted from your description",
      `  .opencode/skill/${skill}/SKILL.md`,
      "  opencode.json               gateway connectors · permissions",
      "  schedules.json",
    ].join("\n");
  }
  if (kind === "code") {
    if (source.startsWith("/")) return `${source}   (existing folder)`;
    if (source && token && /github\.com/.test(source))
      return `code/${name}/   git clone ${source}  (with your token)`;
    if (source) return `code/${name}/   git clone ${source}`;
    return `code/${name}/   new git repo`;
  }
  return `${name}/\n  AGENTS.md\n  artifacts/`;
}

export default function NewProject() {
  const params = useLocalSearchParams<{ kind?: string }>();
  const [kind, setKind] = useState<Kind>(
    params.kind === "routine" || params.kind === "chat" ? params.kind : "code",
  );
  const [name, setName] = useState("");
  const [source, setSource] = useState("");
  const [token, setToken] = useState("");
  const [worktree, setWorktree] = useState(false);
  const [scope, setScope] = useState<"team" | "private">("team");
  const [description, setDescription] = useState("");
  const [importing, setImporting] = useState<string | null>(null);
  const [granted, setGranted] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const { data: options } = useLoad(() => ask<Options>("new_project_options", {}, 30000), []);

  const finalName = importing ?? name;
  const nameError = finalName && !validName(finalName) ? "Lowercase letters, digits and dashes." : null;

  async function create() {
    setBusy(true);
    setError(null);
    try {
      const r = await ask<{ project_id: number; session_id?: string; note?: string }>(
        "create_project",
        {
          params: {
            kind,
            name: finalName,
            source: kind === "code" ? source.trim() : undefined,
            github_token: kind === "code" ? token.trim() : undefined,
            always_worktree: String(worktree),
            scope,
            description: kind === "routine" ? description : undefined,
            import: kind === "routine" && importing ? "true" : "false",
            connectors: kind === "routine" ? granted : [],
          },
        },
        180000,
      );
      // Shown on the page we go to next.
      if (r.note) notify(r.note);
      if (r.session_id) router.replace(`/session/${r.session_id}`);
      else router.replace(kind === "routine" ? `/routine/${r.project_id}` : `/project/${r.project_id}`);
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(false);
  }

  return (
    <Screen>
      <BackHeader label="Back" />
      <ScrollView contentContainerStyle={st.body} keyboardShouldPersistTaps="handled">
        <Text style={st.title}>New project</Text>
        <View style={st.kinds}>
          {kinds.map((k) => (
            <Tap
              key={k.kind}
              testID={`kind-${k.kind}`}
              onPress={() => {
                setKind(k.kind);
                setImporting(null);
              }}
              style={[st.kind, kind === k.kind && st.kindOn]}
            >
              <Text style={st.kindLabel}>{k.label}</Text>
              <Text style={st.kindDetail}>{k.detail}</Text>
            </Tap>
          ))}
        </View>

        {kind === "routine" && options?.known_routines.length ? (
          <>
            <SectionLabel>Add an existing routine folder</SectionLabel>
            <View style={st.chips}>
              {options.known_routines.map((r) => (
                <Tap
                  key={r}
                  onPress={() => setImporting(importing === r ? null : r)}
                  style={[st.chip, importing === r && st.chipOn]}
                >
                  <Text style={[st.chipText, importing === r && { color: color.accentInk }]}>{r}</Text>
                </Tap>
              ))}
            </View>
          </>
        ) : null}

        {!importing ? (
          <Field label="Name" error={nameError}>
            <TextInput
              testID="project-name"
              value={name}
              onChangeText={(v) => setName(v.toLowerCase())}
              placeholder={kind === "routine" ? "front-digest" : kind === "chat" ? "ops-notes" : "my-app"}
              placeholderTextColor={color.faint}
              autoCapitalize="none"
              style={st.input}
            />
          </Field>
        ) : null}

        {kind === "code" ? (
          <>
            <Field label="Clone from (optional)">
              <TextInput
                value={source}
                onChangeText={(v) => {
                  setSource(v);
                  if (!name)
                    setName(
                      slug(
                        v
                          .split(/[/:]/)
                          .pop()
                          ?.replace(/\.git$/, "") ?? "",
                      ),
                    );
                }}
                placeholder="https://github.com/org/repo, or empty for a new repo"
                placeholderTextColor={color.faint}
                autoCapitalize="none"
                style={st.input}
              />
            </Field>
            {options?.known_repos.length ? (
              <View style={{ gap: 6 }}>
                <Text style={st.hint}>Or a repo already on the server:</Text>
                <View style={st.chips}>
                  {options.known_repos.map((r) => (
                    <Tap
                      key={r}
                      onPress={() => {
                        setSource(r);
                        if (!name) setName(slug(r.split("/").pop() ?? ""));
                      }}
                      style={[st.chip, source === r && st.chipOn]}
                    >
                      <Text
                        style={[
                          st.chipText,
                          { fontFamily: font.mono },
                          source === r && { color: color.accentInk },
                        ]}
                      >
                        {r}
                      </Text>
                    </Tap>
                  ))}
                </View>
              </View>
            ) : null}
            {isGithub(source) ? (
              <Field label="GitHub token (optional)">
                <TextInput
                  value={token}
                  onChangeText={setToken}
                  placeholder="github_pat_… for private repos, pushing and PRs"
                  placeholderTextColor={color.faint}
                  secureTextEntry
                  autoCapitalize="none"
                  style={st.input}
                />
              </Field>
            ) : null}
            <View style={st.toggleRow}>
              <View style={{ flex: 1 }}>
                <Text style={st.label}>New sessions in a worktree</Text>
                <Text style={st.hint}>Each session gets its own git worktree.</Text>
              </View>
              <Toggle value={worktree} onChange={setWorktree} />
            </View>
          </>
        ) : null}

        {kind === "routine" && !importing ? (
          <>
            <Field label="What does it do?">
              <TextInput
                value={description}
                onChangeText={setDescription}
                multiline
                placeholder="Every morning, summarize new Front conversations and post the digest."
                placeholderTextColor={color.faint}
                style={[st.input, { minHeight: 90, paddingTop: 10, textAlignVertical: "top" }]}
              />
            </Field>
            <Text style={st.hint}>
              A session drafts its instructions and skill from this; you review them there.
            </Text>
            {options?.connectors.length ? (
              <>
                <SectionLabel>Connectors it may use</SectionLabel>
                {options.connectors.map((c) => (
                  <View key={c.name} style={st.toggleRow}>
                    <View style={{ flex: 1 }}>
                      <Text style={st.label}>{c.name}</Text>
                      <Text style={st.hint}>
                        {c.tools} tools{c.ready ? "" : " · secret not set"}
                      </Text>
                    </View>
                    <Toggle
                      value={granted.includes(c.name)}
                      onChange={(v) =>
                        setGranted((g) => (v ? [...g, c.name] : g.filter((n) => n !== c.name)))
                      }
                    />
                  </View>
                ))}
              </>
            ) : null}
          </>
        ) : null}

        <Field label="Who sees it">
          <Segmented
            options={[
              { value: "team", label: "Team" },
              { value: "private", label: "Only me" },
            ]}
            value={scope}
            onChange={setScope}
          />
        </Field>

        {finalName ? (
          <View style={st.willCreate} testID="will-create">
            <Text style={st.willLabel}>Will create</Text>
            <Text style={st.willText} selectable>
              {willCreate(kind, finalName, source.trim(), token.trim(), !!importing)}
            </Text>
          </View>
        ) : null}

        <ErrorLine message={error} />
        <Button
          testID="create-project"
          label={kind === "routine" && importing ? "Add" : busy ? "Creating…" : "Create"}
          height={48}
          busy={busy}
          disabled={!finalName || !!nameError}
          onPress={create}
        />
        {busy && kind === "code" && source ? <Text style={st.hint}>Cloning can take a minute.</Text> : null}
      </ScrollView>
    </Screen>
  );
}

function Field({
  label,
  error,
  children,
}: {
  label: string;
  error?: string | null;
  children: React.ReactNode;
}) {
  return (
    <View style={{ gap: 6 }}>
      <Text style={st.fieldLabel}>{label}</Text>
      {children}
      {error ? <Text style={{ fontSize: 12, color: color.red }}>{error}</Text> : null}
    </View>
  );
}

const st = StyleSheet.create({
  willCreate: { padding: 14, borderRadius: 12, backgroundColor: color.bgDeep, gap: 6 },
  willLabel: { fontSize: 12, color: color.faint },
  willText: { fontSize: 12.5, lineHeight: 19, fontFamily: font.mono, color: color.textSoft },
  body: { paddingHorizontal: 18, paddingTop: 4, paddingBottom: 48, gap: 14, maxWidth: 680, width: "100%" },
  title: { fontSize: 28, fontWeight: "700", letterSpacing: -0.5, color: color.text },
  kinds: { flexDirection: "row", gap: 8, flexWrap: "wrap" },
  kind: {
    flexGrow: 1,
    flexBasis: 180,
    padding: 12,
    gap: 4,
    borderRadius: 12,
    backgroundColor: color.card,
    borderWidth: 1,
    borderColor: color.border,
  },
  kindOn: { borderColor: color.accent, backgroundColor: color.accentCard },
  kindLabel: { fontSize: 15, fontWeight: "600", color: color.text },
  kindDetail: { fontSize: 12.5, color: color.muted, lineHeight: 17 },
  fieldLabel: { fontSize: 13, color: color.muted },
  input: {
    height: 44,
    borderRadius: 10,
    backgroundColor: color.field,
    paddingHorizontal: 12,
    color: color.text,
    fontSize: 15,
  },
  chips: { flexDirection: "row", flexWrap: "wrap", gap: 6 },
  chip: { paddingHorizontal: 10, paddingVertical: 6, borderRadius: 8, backgroundColor: color.field },
  chipOn: { backgroundColor: color.accent },
  chipText: { fontSize: 12.5, color: color.textSoft },
  toggleRow: { flexDirection: "row", alignItems: "center", gap: 12 },
  label: { fontSize: 15, color: color.text },
  hint: { fontSize: 12.5, color: color.muted, lineHeight: 17 },
});
