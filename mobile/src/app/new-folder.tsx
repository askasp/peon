import { useState } from "react";
import { Pressable, StyleSheet, Text, TextInput, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Icon } from "@/components/Icon";
import { ErrorLine, Tap } from "@/components/ui";
import { folderHref, slugName, templates } from "@/lib/folders";
import { notify } from "@/lib/notice";
import { ask } from "@/lib/peon";
import { useKeyboardHeight } from "@/lib/useKeyboard";
import { useWide } from "@/lib/useWide";
import { color, font } from "@/lib/theme";
import type { Project } from "@/lib/types";

type Kind = Project["kind"];

// What the second step asks besides the name.
const extra: Partial<Record<Kind, { label: string; placeholder: string; param: string }>> = {
  code: { label: "Repository", placeholder: "github.com/you/repo, or empty for git init", param: "source" },
  dataset: {
    label: "What will you keep track of?",
    placeholder: "e.g. books I lend out and who has them",
    param: "description",
  },
  routine: {
    label: "What should it do?",
    placeholder: "e.g. sum up open PRs and post them in Slack",
    param: "description",
  },
};

const where = (kind: Kind, name: string) =>
  kind === "code" ? `code/${name}/` : kind === "routine" ? `routines/${name}/` : `${name}/`;

// New Folder: pick a template, then name it. The template only sets it up.
export default function NewFolder() {
  const params = useLocalSearchParams<{ kind?: string }>();
  const insets = useSafeAreaInsets();
  const keyboard = useKeyboardHeight();
  const wide = useWide();
  const [kind, setKind] = useState<Kind | null>(
    templates.some((t) => t.kind === params.kind) ? (params.kind as Kind) : null,
  );
  const [name, setName] = useState("");
  const [more, setMore] = useState("");
  const [scope, setScope] = useState<"private" | "team">("private");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const t = templates.find((x) => x.kind === kind);
  const ex = kind ? extra[kind] : undefined;
  const final = slugName(name);

  async function create() {
    if (!kind || !final) return;
    setBusy(true);
    setError(null);
    try {
      const r = await ask<{ project_id: number; session_id?: string; note?: string }>(
        "create_project",
        { params: { kind, name: final, scope, ...(ex && more.trim() ? { [ex.param]: more.trim() } : {}) } },
        180000,
      );
      if (r.note) notify(r.note);
      if (r.session_id) router.replace(`/session/${r.session_id}`);
      else router.replace(folderHref({ id: r.project_id, kind }) as any);
    } catch (e: any) {
      setError(e.message);
      setBusy(false);
    }
  }

  return (
    <View style={[st.backdrop, wide && st.backdropWide]}>
      <Pressable style={wide ? StyleSheet.absoluteFill : { flex: 1 }} onPress={() => router.back()} />
      <View
        style={[
          st.sheet,
          wide
            ? st.sheetWide
            : { paddingBottom: keyboard > 0 ? keyboard + 16 : Math.max(insets.bottom, 16) + 20 },
        ]}
      >
        {wide ? null : <View style={st.grabber} />}
        {!t ? (
          <>
            <View style={st.head}>
              <Text style={st.title}>New Folder</Text>
              <Tap onPress={() => router.back()} hitSlop={10}>
                <Text style={st.cancel}>Cancel</Text>
              </Tap>
            </View>
            <View style={st.group}>
              {templates.map((x, i) => (
                <Tap
                  key={x.kind}
                  testID={`kind-${x.kind}`}
                  onPress={() => setKind(x.kind)}
                  style={[st.row, i < templates.length - 1 && st.rowLine]}
                >
                  <View style={{ flex: 1, gap: 2 }}>
                    <Text style={st.rowTitle}>{x.label}</Text>
                    <Text style={st.rowSub}>{x.detail}</Text>
                  </View>
                  <Text style={st.opens}>{x.opens}</Text>
                  <Text style={st.chev}>›</Text>
                </Tap>
              ))}
            </View>
          </>
        ) : (
          <>
            <View style={st.head}>
              <Tap onPress={() => setKind(null)} style={st.back} hitSlop={8}>
                <Icon name="back" size={18} color={color.accentText} strokeWidth={2.4} />
                <Text style={st.backText}>Templates</Text>
              </Tap>
              <Text style={st.title}>{t.label}</Text>
              <View style={{ width: 84 }} />
            </View>
            <View style={st.field}>
              <Text style={st.label}>Name</Text>
              <TextInput
                testID="project-name"
                value={name}
                onChangeText={setName}
                placeholder="e.g. cabin-bookings"
                placeholderTextColor="#62626b"
                autoCapitalize="none"
                autoCorrect={false}
                autoFocus
                style={[st.input, { borderColor: color.accent }]}
              />
              <Text style={st.path}>{where(t.kind, final || "name")}</Text>
            </View>
            {ex ? (
              <View style={st.field}>
                <Text style={st.label}>{ex.label}</Text>
                <TextInput
                  value={more}
                  onChangeText={setMore}
                  placeholder={ex.placeholder}
                  placeholderTextColor="#62626b"
                  autoCapitalize="none"
                  style={[st.input, { fontSize: 15 }]}
                />
              </View>
            ) : null}
            <View style={st.seg}>
              {(["private", "team"] as const).map((v) => (
                <Tap key={v} onPress={() => setScope(v)} style={[st.segItem, scope === v && st.segOn]}>
                  <Text style={[st.segText, scope === v && { color: color.textStrong }]}>
                    {v === "private" ? "Only you" : "Team"}
                  </Text>
                </Tap>
              ))}
            </View>
            <View style={st.foot}>
              <Text style={[st.rowSub, { flex: 1 }]}>{t.detail}</Text>
              {/* Private repos (a GitHub token), existing routine folders, connectors. */}
              {t.kind === "code" || t.kind === "routine" ? (
                <Tap
                  onPress={() => router.replace({ pathname: "/new", params: { kind: t.kind } })}
                  hitSlop={8}
                >
                  <Text style={st.more}>More options</Text>
                </Tap>
              ) : null}
            </View>
            <ErrorLine message={error} />
            <Tap
              testID="create-project"
              haptic
              onPress={create}
              disabled={busy || !final}
              style={[st.go, !final && { opacity: 0.4 }]}
            >
              <Text style={st.goText}>{busy ? "Creating…" : "Create Folder"}</Text>
            </Tap>
          </>
        )}
      </View>
    </View>
  );
}

const st = StyleSheet.create({
  backdrop: { flex: 1, backgroundColor: "rgba(0,0,0,0.55)" },
  // Web: a card in the middle instead of a sheet from the bottom.
  backdropWide: { alignItems: "center", justifyContent: "center" },
  sheetWide: {
    width: 560,
    maxWidth: "92%",
    borderRadius: 16,
    padding: 22,
    borderWidth: 1,
    borderColor: color.border,
  },
  sheet: {
    borderTopLeftRadius: 28,
    borderTopRightRadius: 28,
    backgroundColor: color.card,
    paddingHorizontal: 18,
    paddingTop: 10,
    gap: 14,
  },
  grabber: { alignSelf: "center", width: 36, height: 5, borderRadius: 3, backgroundColor: color.ghost },
  head: { flexDirection: "row", justifyContent: "space-between", alignItems: "center" },
  title: { fontSize: 17, fontWeight: "600", color: color.text },
  cancel: { fontSize: 16, color: color.muted },
  back: { flexDirection: "row", alignItems: "center", gap: 2, width: 84 },
  backText: { fontSize: 16, color: color.accentText },
  group: { borderRadius: 14, backgroundColor: color.bg, overflow: "hidden" },
  row: { flexDirection: "row", alignItems: "center", gap: 12, paddingHorizontal: 14, paddingVertical: 12 },
  rowLine: { borderBottomWidth: 1, borderBottomColor: "#222228" },
  rowTitle: { fontSize: 16, color: color.text },
  rowSub: { fontSize: 13, color: color.muted },
  opens: { fontSize: 12, color: color.faint },
  chev: { fontSize: 18, color: "#5d5d66" },
  field: { gap: 6 },
  label: { fontSize: 13, color: color.muted, paddingLeft: 4 },
  input: {
    height: 50,
    borderRadius: 12,
    backgroundColor: color.bg,
    borderWidth: 1,
    borderColor: color.border,
    paddingHorizontal: 14,
    color: color.text,
    fontSize: 16,
    outlineStyle: "none",
  } as any,
  path: { fontSize: 12, fontFamily: font.mono, color: color.faint, paddingLeft: 4 },
  seg: { flexDirection: "row", padding: 3, borderRadius: 10, backgroundColor: color.bg },
  segItem: { flex: 1, alignItems: "center", paddingVertical: 8, borderRadius: 8 },
  segOn: { backgroundColor: color.pill },
  segText: { fontSize: 14, color: color.textDim },
  foot: { flexDirection: "row", alignItems: "center", gap: 12 },
  more: { fontSize: 13, color: color.accentText },
  go: {
    height: 50,
    borderRadius: 12,
    backgroundColor: color.textStrong,
    alignItems: "center",
    justifyContent: "center",
  },
  goText: { fontSize: 16, fontWeight: "600", color: color.bg },
});
