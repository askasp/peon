import { ReactNode, useState } from "react";
import { Modal, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { color } from "@/lib/theme";
import { useKeyboardHeight } from "@/lib/useKeyboard";
import { useWide } from "@/lib/useWide";

/** A modal panel: a bottom sheet on phones, a centred card on desktop. */
export function Sheet({
  visible,
  title,
  onClose,
  children,
  width = 480,
  tall = false,
}: {
  visible: boolean;
  title?: string;
  onClose: () => void;
  children: ReactNode;
  width?: number;
  /** Phone: nearly full height (long lists with a search box). */
  tall?: boolean;
}) {
  const wide = useWide();
  const insets = useSafeAreaInsets();
  // A Modal doesn't move for the keyboard, so the sheet sits on top of it.
  const keyboard = useKeyboardHeight();
  return (
    <Modal visible={visible} transparent animationType={wide ? "fade" : "slide"} onRequestClose={onClose}>
      <View style={[st.backdrop, wide && st.backdropWide]}>
        <Pressable style={StyleSheet.absoluteFill} onPress={onClose} />
        <View
          style={[
            st.sheet,
            wide
              ? [st.card, { width }]
              : [
                  { paddingBottom: keyboard > 0 ? keyboard + 8 : Math.max(insets.bottom, 12) + 8 },
                  tall && { height: "88%" },
                ],
          ]}
        >
          {!wide ? <View style={st.grabber} /> : null}
          {title ? <Text style={st.title}>{title}</Text> : null}
          {children}
        </View>
      </View>
    </Modal>
  );
}

export type PickItem = {
  key: string;
  label: string;
  detail?: string | null;
  active?: boolean;
  danger?: boolean;
};

/** A list to pick one item from, with a search box when it is long. */
export function PickSheet({
  visible,
  title,
  items,
  onPick,
  onClose,
}: {
  visible: boolean;
  title: string;
  items: PickItem[];
  onPick: (key: string) => void;
  onClose: () => void;
}) {
  const [query, setQuery] = useState("");
  const q = query.trim().toLowerCase();
  const shown = items.filter((i) => !q || `${i.label} ${i.detail ?? ""}`.toLowerCase().includes(q));
  const wide = useWide();
  const long = items.length > 8;

  return (
    <Sheet visible={visible} title={title} onClose={onClose} tall={long}>
      {long ? (
        <TextInput
          value={query}
          onChangeText={setQuery}
          placeholder="Search"
          placeholderTextColor={color.faint}
          // Phone: the keyboard would cover half the list straight away.
          autoFocus={wide}
          autoCapitalize="none"
          autoCorrect={false}
          clearButtonMode="while-editing"
          style={st.search}
        />
      ) : null}
      <ScrollView
        style={wide || !long ? { maxHeight: 420 } : { flex: 1 }}
        keyboardShouldPersistTaps="handled"
        keyboardDismissMode="on-drag"
      >
        {shown.map((i) => (
          <Pressable
            key={i.key}
            onPress={() => {
              setQuery("");
              onPick(i.key);
            }}
            style={(s: any) => [st.item, (s.hovered || s.pressed) && { backgroundColor: color.raised }]}
          >
            <View style={{ flex: 1 }}>
              <Text
                style={[st.label, i.danger && { color: color.red }, i.active && { color: color.accentText }]}
              >
                {i.label}
              </Text>
              {i.detail ? (
                <Text style={st.detail} numberOfLines={1}>
                  {i.detail}
                </Text>
              ) : null}
            </View>
            {i.active ? <Text style={{ color: color.accentText }}>✓</Text> : null}
          </Pressable>
        ))}
        {shown.length === 0 ? <Text style={[st.detail, { padding: 12 }]}>Nothing matches.</Text> : null}
      </ScrollView>
    </Sheet>
  );
}

const st = StyleSheet.create({
  backdrop: { flex: 1, justifyContent: "flex-end", backgroundColor: "rgba(5,5,7,0.6)" },
  backdropWide: { justifyContent: "center", alignItems: "center" },
  sheet: {
    backgroundColor: color.card,
    borderTopLeftRadius: 24,
    borderTopRightRadius: 24,
    paddingHorizontal: 14,
    paddingTop: 10,
    gap: 10,
  },
  card: { borderRadius: 16, paddingBottom: 14, borderWidth: 1, borderColor: color.border },
  grabber: { alignSelf: "center", width: 36, height: 5, borderRadius: 3, backgroundColor: color.ghost },
  title: { fontSize: 16, fontWeight: "600", color: color.text, paddingHorizontal: 4, paddingTop: 4 },
  search: {
    height: 38,
    borderRadius: 10,
    backgroundColor: color.field,
    paddingHorizontal: 12,
    color: color.text,
    fontSize: 14,
  },
  item: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingVertical: 10,
    paddingHorizontal: 10,
    borderRadius: 10,
  },
  label: { fontSize: 15, color: color.text },
  detail: { fontSize: 12, color: color.muted, marginTop: 2 },
});
