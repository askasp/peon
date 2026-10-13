import { useState } from "react";
import { ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { Button, ErrorLine, Group, Loading, SectionLabel, Segmented, Tap, Toggle } from "../ui";
import { templateName } from "@/lib/folders";
import { useWide } from "@/lib/useWide";
import { FileView } from "./FilesTab";
import { SourceSettings } from "./SourceSettings";
import { confirm } from "@/lib/confirm";
import { useLoad } from "@/lib/useLoad";
import { ago } from "@/lib/time";
import { color, font } from "@/lib/theme";
import type { ProjectCtx } from "./types";

type Settings = {
  directory: string;
  skills: { name: string; path: string }[];
  settings: { scope: string; always_worktree: boolean; protect_default_branch: boolean };
  github: { repo: string | null; hint: string | null } | null;
  secrets: { name: string; hint: string | null; set_by: string | null; updated_at: string }[];
  can_edit: boolean;
  admin: boolean;
};

/**
 * The template it came from, its instructions and skills, who sees it,
 * worktrees and branch protection, GitHub access, API calls.
 */
export function SettingsTab({
  ctx,
  onSection,
  onApi,
}: {
  ctx: ProjectCtx;
  onSection: (s: "skills" | "schedules") => void;
  /** Opens the API calls tab. */
  onApi?: () => void;
}) {
  const [version, setVersion] = useState(0);
  const wide = useWide();
  const [picked, setPicked] = useState("AGENTS.md");
  const [token, setToken] = useState("");
  const [secretName, setSecretName] = useState("");
  const [secretValue, setSecretValue] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const { data, error: loadError } = useLoad(() => ctx.call<Settings>("settings", {}, 30000), [version]);

  async function act(name: string, fn: () => Promise<unknown>) {
    setBusy(name);
    setError(null);
    setNote(null);
    try {
      await fn();
      setVersion((v) => v + 1);
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(null);
  }

  const save = (params: object) =>
    act("settings", async () => {
      const r = await ctx.call<{ message: string; reverted: boolean }>("save_settings", { params }, 30000);
      if (r.reverted) setError(r.message);
      else setNote(r.message);
    });

  if (!data) return loadError ? <ErrorLine message={loadError} /> : <Loading />;
  const s = data.settings;
  const p = ctx.project;
  const edit = data.can_edit;

  const settings = (
    <ScrollView style={wide ? st.leftWide : null} contentContainerStyle={st.body}>
      {note ? <Text style={st.note}>{note}</Text> : null}
      <ErrorLine message={error} />

      <View style={st.card}>
        <Text style={st.cardTitle}>{p.kind === "home" ? "Home" : `${templateName[p.kind]} template`}</Text>
        <Text style={st.hint}>
          {p.kind === "home"
            ? "Your private Project. General chats and what they make live here."
            : `Set up from the ${templateName[p.kind]} template. After that it works like any other Project.`}
        </Text>
      </View>

      {p.kind === "dataset" ? <SourceSettings ctx={ctx} /> : null}

      <Text style={st.heading}>Instructions</Text>
      <View style={st.group}>
        {[
          { name: "AGENTS.md", path: "AGENTS.md", sub: "What the agent should know here" },
          ...data.skills.map((k) => ({ name: `/${k.name}`, path: k.path, sub: "Skill" })),
        ].map((x) => (
          <Tap
            key={x.path}
            kb="row"
            onPress={() =>
              wide
                ? setPicked(x.path)
                : router.push({ pathname: "/view" as any, params: { project: String(p.id), path: x.path } })
            }
            style={[st.item, st.itemLine, wide && picked === x.path && { backgroundColor: color.raised }]}
          >
            <View style={st.glyph}>
              <Text style={st.glyphText}>¶</Text>
            </View>
            <View style={{ flex: 1, gap: 1 }}>
              <Text style={st.itemMono}>{x.name}</Text>
              <Text style={st.itemSub}>{x.sub}</Text>
            </View>
            <Text style={st.chev}>›</Text>
          </Tap>
        ))}
        <Tap kb="row" testID="settings-new-skill" onPress={() => onSection("skills")} style={st.item}>
          <Text style={[st.itemTitle, { color: color.accentText }]}>+ New skill</Text>
        </Tap>
      </View>

      <Text style={st.heading}>Who can see it</Text>
      <Segmented
        options={[
          { value: "private", label: "Only you" },
          { value: "team", label: "Team" },
        ]}
        value={s.scope === "private" ? "private" : "team"}
        onChange={(v) => edit && p.kind !== "home" && save({ scope: v })}
      />

      {p.kind === "code" ? (
        <Group>
          <Row label="New worktree for each chat">
            <Toggle
              label="New worktree for each chat"
              value={s.always_worktree}
              onChange={(v) => edit && save({ always_worktree: String(v) })}
            />
          </Row>
          <Row label="Protect the default branch" detail="Chats can't push to it; they push branches." top>
            <Toggle
              label="Protect the default branch"
              value={s.protect_default_branch}
              onChange={(v) => edit && save({ protect_default_branch: String(v) })}
            />
          </Row>
        </Group>
      ) : null}

      {p.kind !== "routine" ? (
        <View style={st.group}>
          <Tap kb="row" testID="settings-schedules" onPress={() => onSection("schedules")} style={st.item}>
            <View style={{ flex: 1, gap: 1 }}>
              <Text style={st.itemTitle}>Schedules</Text>
              <Text style={st.itemSub}>{p.schedule ?? "None"}</Text>
            </View>
            <Text style={st.chev}>›</Text>
          </Tap>
        </View>
      ) : null}
      <Text style={st.path} selectable>
        {data.directory}
      </Text>
      {!edit ? <Text style={st.hint}>Only the owner or an admin can change these.</Text> : null}

      {data.github ? (
        <>
          <SectionLabel style={st.section}>GitHub</SectionLabel>
          <Group style={{ padding: 14, gap: 10 }}>
            <Text style={st.label}>{data.github.repo ?? "No GitHub repo detected"}</Text>
            <Text style={st.hint}>
              {data.github.hint
                ? `Token saved (${data.github.hint}). Sessions can push and open PRs.`
                : "Add a fine-grained token with contents and pull-request access, so sessions can push and open PRs."}
            </Text>
            {edit ? (
              <View style={{ flexDirection: "row", gap: 8 }}>
                <TextInput
                  value={token}
                  onChangeText={setToken}
                  placeholder="github_pat_…"
                  placeholderTextColor={color.faint}
                  secureTextEntry
                  autoCapitalize="none"
                  style={st.input}
                />
                <Button
                  label="Save"
                  height={40}
                  busy={busy === "github"}
                  disabled={!token.trim()}
                  onPress={() =>
                    act("github", async () => {
                      await ctx.call("github_save", { token: token.trim() }, 60000);
                      setToken("");
                      setNote("Token saved.");
                    })
                  }
                />
                {data.github.hint ? (
                  <Button
                    label="Remove"
                    kind="danger"
                    height={40}
                    busy={busy === "github-remove"}
                    onPress={() => act("github-remove", () => ctx.call("github_remove", {}, 30000))}
                  />
                ) : null}
              </View>
            ) : null}
          </Group>
        </>
      ) : null}

      <SectionLabel style={st.section}>Secrets</SectionLabel>
      <Text style={st.hint}>
        {"Keys for this Project's API calls and sources. Other Projects never see them."}
      </Text>
      {data.secrets.length ? (
        <View style={st.group}>
          {data.secrets.map((x, i) => (
            <View key={x.name} style={[st.row, i > 0 && st.top]} testID={`secret-${x.name}`}>
              <View style={{ flex: 1, gap: 1 }}>
                <Text style={st.itemMono}>{x.name}</Text>
                <Text style={st.itemSub}>
                  {[x.hint, x.set_by, ago(x.updated_at, true)].filter(Boolean).join(" · ")}
                </Text>
              </View>
              {edit ? (
                <>
                  <Button
                    label="Replace"
                    kind="secondary"
                    height={30}
                    onPress={() => setSecretName(x.name)}
                  />
                  <Button
                    label="Delete"
                    kind="danger"
                    height={30}
                    busy={busy === `secret-del-${x.name}`}
                    onPress={async () => {
                      if (await confirm(`Delete ${x.name}?`, "What uses it here stops working.", "Delete"))
                        act(`secret-del-${x.name}`, () => ctx.call("secret_delete", { name: x.name }, 30000));
                    }}
                  />
                </>
              ) : null}
            </View>
          ))}
        </View>
      ) : null}
      {edit ? (
        <Group style={{ padding: 14, gap: 10 }}>
          <TextInput
            testID="secret-name"
            value={secretName}
            onChangeText={(v) => setSecretName(v.toUpperCase())}
            placeholder="STRIPE_KEY"
            placeholderTextColor={color.faint}
            autoCapitalize="characters"
            autoCorrect={false}
            style={[st.input, { flex: 0, fontFamily: font.mono }]}
          />
          <View style={{ flexDirection: "row", gap: 8 }}>
            <TextInput
              testID="secret-value"
              value={secretValue}
              onChangeText={setSecretValue}
              placeholder="Value"
              placeholderTextColor={color.faint}
              secureTextEntry
              autoCapitalize="none"
              style={st.input}
            />
            <Button
              label="Save"
              height={40}
              busy={busy === "secret"}
              disabled={!secretName.trim() || !secretValue}
              onPress={() =>
                act("secret", async () => {
                  await ctx.call("secret_save", { name: secretName.trim(), value: secretValue }, 30000);
                  setNote(`${secretName.trim()} saved in this Project.`);
                  setSecretName("");
                  setSecretValue("");
                })
              }
            />
          </View>
        </Group>
      ) : null}

      {onApi && p.kind !== "home" ? (
        <View style={st.group}>
          <Tap kb="row" testID="settings-api-calls" onPress={onApi} style={st.item}>
            <View style={{ flex: 1, gap: 1 }}>
              <Text style={st.itemTitle}>API calls</Text>
              <Text style={st.itemSub}>.peon/api/</Text>
            </View>
            <Text style={st.chev}>›</Text>
          </Tap>
        </View>
      ) : null}

      {data.admin && p.kind !== "system" ? (
        <View style={{ paddingTop: 18, gap: 6 }}>
          <Button
            label="Remove project"
            kind="danger"
            height={44}
            onPress={async () => {
              if (
                !(await confirm(
                  `Remove ${p.name}?`,
                  "It leaves Peon. The folder stays on the server.",
                  "Remove",
                ))
              )
                return;
              act("remove", async () => {
                await ctx.call("remove");
                router.replace("/");
              });
            }}
          />
          <Text style={st.hint}>Removes it from Peon. The folder is still on the server.</Text>
        </View>
      ) : null}
    </ScrollView>
  );

  // Web: the settings beside the instruction file that's picked.
  if (!wide) return settings;
  return (
    <View style={st.split}>
      {settings}
      <View style={{ flex: 1, minWidth: 0 }}>
        <FileView key={picked} call={ctx.call} path={picked} />
      </View>
    </View>
  );
}

function Row({
  label,
  detail,
  top,
  children,
}: {
  label: string;
  detail?: string;
  top?: boolean;
  children: React.ReactNode;
}) {
  return (
    <View style={[st.row, top && st.top]}>
      <View style={{ flex: 1, gap: 2 }}>
        <Text style={st.label}>{label}</Text>
        {detail ? <Text style={st.hint}>{detail}</Text> : null}
      </View>
      {children}
    </View>
  );
}

const st = StyleSheet.create({
  split: { flex: 1, minHeight: 0, flexDirection: "row" },
  leftWide: { width: 440, flexGrow: 0, borderRightWidth: 1, borderRightColor: color.hairline },
  card: { padding: 14, borderRadius: 14, backgroundColor: color.card, gap: 4 },
  cardTitle: { fontSize: 15, color: color.text },
  heading: { fontSize: 13, color: color.muted, marginTop: 4 },
  group: { borderRadius: 14, backgroundColor: color.card, overflow: "hidden" },
  item: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    minHeight: 52,
    paddingHorizontal: 14,
    paddingVertical: 8,
  },
  itemLine: { borderBottomWidth: 1, borderBottomColor: color.divider },
  glyph: {
    width: 30,
    height: 30,
    borderRadius: 7,
    backgroundColor: color.divider,
    alignItems: "center",
    justifyContent: "center",
  },
  glyphText: { fontSize: 12, color: color.textDim },
  itemTitle: { fontSize: 15, color: color.text },
  itemMono: { fontSize: 14, fontFamily: font.mono, color: color.text },
  itemSub: { fontSize: 12, color: color.muted },
  chev: { fontSize: 18, color: "#5d5d66" },
  path: { fontSize: 12, fontFamily: font.mono, color: color.faint },
  body: { paddingHorizontal: 18, paddingTop: 8, paddingBottom: 40, gap: 12, maxWidth: 760, width: "100%" },
  section: { paddingTop: 12, paddingLeft: 4 },
  row: { flexDirection: "row", alignItems: "center", gap: 12, paddingHorizontal: 14, paddingVertical: 10 },
  top: { borderTopWidth: 1, borderTopColor: color.divider },
  label: { fontSize: 15, color: color.text },
  hint: { fontSize: 12.5, color: color.muted, lineHeight: 17 },
  note: { fontSize: 13, color: color.teal },
  input: {
    flex: 1,
    height: 40,
    borderRadius: 10,
    backgroundColor: color.field,
    paddingHorizontal: 12,
    color: color.text,
    fontSize: 14,
  },
});
