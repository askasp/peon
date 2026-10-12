import { Tabs } from "expo-router";
import { TabBar } from "@/components/TabBar";
import { color } from "@/lib/theme";

export default function TabsLayout() {
  return (
    <Tabs
      tabBar={(props) => <TabBar {...props} />}
      screenOptions={{ headerShown: false, sceneStyle: { backgroundColor: color.bg } }}
    >
      <Tabs.Screen name="index" />
      <Tabs.Screen name="projects" />
      {/* Routines are Folders now; the old tab stays routable for links. */}
      <Tabs.Screen name="routines" options={{ href: null }} />
      <Tabs.Screen name="schedules" />
      <Tabs.Screen name="settings" />
    </Tabs>
  );
}
