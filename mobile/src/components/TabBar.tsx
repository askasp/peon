import { Pressable, StyleSheet, Text, View } from "react-native";
import { router } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import type { BottomTabBarProps } from "expo-router/tabs";
import * as Haptics from "expo-haptics";
import { color } from "@/lib/theme";
import { Icon, IconName } from "./Icon";
import { Tap } from "./ui";
import { usePeon } from "@/lib/peon";
import { useWide } from "@/lib/useWide";

const tabs: { route: string; label: string; icon: IconName }[] = [
  { route: "index", label: "Inbox", icon: "inbox" },
  { route: "projects", label: "Projects", icon: "folder" },
  { route: "schedules", label: "Schedules", icon: "clock" },
  { route: "settings", label: "Settings", icon: "sliders" },
];

// Four tabs around the green +: a new chat in the Project you're in, or Home.
export function TabBar({ state, navigation }: BottomTabBarProps) {
  const insets = useSafeAreaInsets();
  const current = state.routes[state.index]?.name;
  const waiting = usePeon((s) => s.inbox.length);
  const wide = useWide();

  // Desktop: the sidebar takes the tabs' place.
  if (wide) return null;

  const tab = (t: (typeof tabs)[number]) => {
    const on = current === t.route;
    const tint = on ? color.textStrong : color.faint;
    return (
      <Pressable
        key={t.route}
        testID={`tab-${t.route}`}
        style={st.tab}
        onPress={() => {
          if (!on) navigation.navigate(t.route);
        }}
      >
        <View>
          <Icon name={t.icon} size={24} color={tint} />
          {t.route === "index" && waiting > 0 ? (
            <View style={st.badge}>
              <Text style={st.badgeText}>{waiting}</Text>
            </View>
          ) : null}
        </View>
        <Text style={[st.label, { color: tint }]}>{t.label}</Text>
      </Pressable>
    );
  };

  return (
    <View style={[st.bar, { paddingBottom: Math.max(insets.bottom, 12) }]}>
      {tab(tabs[0])}
      {tab(tabs[1])}
      <View style={st.tab}>
        <Tap
          testID="tab-mic"
          style={st.mic}
          onPress={() => {
            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light).catch(() => {});
            router.push("/compose");
          }}
        >
          <Icon name="plus" size={22} color={color.accentInk} strokeWidth={2.4} />
        </Tap>
      </View>
      {tab(tabs[2])}
      {tab(tabs[3])}
    </View>
  );
}

const st = StyleSheet.create({
  bar: {
    flexDirection: "row",
    alignItems: "flex-start",
    borderTopWidth: 1,
    borderTopColor: "#222228",
    backgroundColor: color.bar,
    paddingTop: 8,
  },
  tab: { flex: 1, alignItems: "center", gap: 3 },
  label: { fontSize: 10 },
  mic: {
    width: 52,
    height: 52,
    marginTop: -4,
    borderRadius: 26,
    backgroundColor: color.accent,
    alignItems: "center",
    justifyContent: "center",
    shadowColor: color.accent,
    shadowOpacity: 0.35,
    shadowRadius: 12,
    shadowOffset: { width: 0, height: 4 },
    elevation: 6,
  },
  badge: {
    position: "absolute",
    top: -3,
    left: 18,
    minWidth: 17,
    height: 17,
    paddingHorizontal: 4,
    borderRadius: 9,
    backgroundColor: color.needs,
    alignItems: "center",
    justifyContent: "center",
  },
  badgeText: { fontSize: 11, fontWeight: "700", color: "#1e140b" },
});
