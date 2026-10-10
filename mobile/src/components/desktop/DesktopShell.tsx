import { ReactNode, useEffect } from "react";
import { StyleSheet, View } from "react-native";
import { usePathname } from "expo-router";
import { KeyOverlays } from "./KeyOverlays";
import { Palette } from "./Palette";
import { Sidebar } from "./Sidebar";
import { TopBar } from "./TopBar";
import { trackPath, useKb, useShortcuts } from "@/lib/keys";
import { color } from "@/lib/theme";

// Desktop browsers: top bar across, sidebar left (zoom hides it), the current
// screen in the rest; keyboard shortcuts, the palette and the status line on top.
export function DesktopShell({ children }: { children: ReactNode }) {
  const path = usePathname();
  const { zoom } = useKb();
  useShortcuts();
  useEffect(() => trackPath(path), [path]);

  return (
    <View style={st.root}>
      <TopBar />
      <View style={st.body}>
        {zoom ? null : <Sidebar />}
        <View style={st.main}>{children}</View>
      </View>
      <KeyOverlays />
      <Palette />
    </View>
  );
}

const st = StyleSheet.create({
  root: { flex: 1, backgroundColor: color.bg },
  body: { flex: 1, flexDirection: "row", minHeight: 0 },
  main: { flex: 1, minWidth: 0 },
});
