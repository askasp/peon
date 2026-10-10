import { useState } from "react";
import { ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { Button, ErrorLine, Group, Loading, SectionLabel, Toggle } from "../ui";
import { confirm } from "@/lib/confirm";
import { useLoad } from "@/lib/useLoad";
import { color } from "@/lib/theme";
import type { ProjectCtx } from "./types";

type Settings = {
  settings: { scope: string; always_worktree: boolean; protect_default_branch: boolean };
  github: { repo: string | null; hint: string | null } | null;
  connectors: { name: string; tools: number; ready: boolean; granted: boolean }[];
  can_edit: boolean;
  admin: boolean;
};

/** Who sees the project, worktrees and branch protection, GitHub access, connectors. */
export function SettingsTab({ ctx }: { ctx: ProjectCtx }) {
  const [version, setVersion] = useState(0);
  const [token, setToken] = useState("");
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

  return (
    <ScrollView contentContainerStyle={st.body}>
      {note ? <Text style={st.note}>{note}</Text> : null}
      <ErrorLine message={error} />

      <Group>
        <Row label="Only me" detail="Hide this project from the team.">
          <Toggle
            label="Only me"
            value={s.scope === "private"}
            onChange={(v) => edit && save({ scope: v ? "private" : "team" })}
          />
        </Row>
        {p.kind === "code" ? (
          <>
            <Row label="New sessions in a worktree" detail="Each session gets its own git worktree." top>
              <Toggle
                label="New sessions in a worktree"
                value={s.always_worktree}
                onChange={(v) => edit && save({ always_worktree: String(v) })}
              />
            </Row>
            <Row
              label="Protect the default branch"
              detail="Sessions can't push to it; they push branches."
              top
            >
              <Toggle
                label="Protect the default branch"
                value={s.protect_default_branch}
                onChange={(v) => edit && save({ protect_default_branch: String(v) })}
              />
            </Row>
          </>
        ) : null}
      </Group>
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

      {data.connectors.length ? (
        <>
          <SectionLabel style={st.section}>Connectors</SectionLabel>
          <Group>
            {data.connectors.map((c, i) => (
              <Row
                key={c.name}
                label={c.name}
                detail={`${c.tools} tools${c.ready ? "" : " · secret not set"}`}
                top={i > 0}
              >
                {data.admin ? (
                  <Toggle
                    value={c.granted}
                    onChange={(v) =>
                      act(`grant-${c.name}`, () =>
                        ctx.call("grant", { connector: c.name, granted: v }, 30000),
                      )
                    }
                  />
                ) : (
                  <Text style={st.hint}>{c.granted ? "granted" : "—"}</Text>
                )}
              </Row>
            ))}
          </Group>
        </>
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
  body: { paddingHorizontal: 18, paddingTop: 8, paddingBottom: 40, gap: 8 },
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
