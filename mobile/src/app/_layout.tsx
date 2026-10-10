import { useEffect } from "react";
import { View } from "react-native";
import { Stack } from "expo-router";
import { StatusBar } from "expo-status-bar";
import { SafeAreaProvider } from "react-native-safe-area-context";
import * as SplashScreen from "expo-splash-screen";
import { useFonts, BricolageGrotesque_700Bold } from "@expo-google-fonts/bricolage-grotesque";
import { boot, usePeon } from "@/lib/peon";
import { loadVoiceSettings } from "@/lib/voice";
import { color } from "@/lib/theme";
import { useWide } from "@/lib/useWide";
import { DesktopShell } from "@/components/desktop/DesktopShell";
import { SpeakingPill } from "@/components/SpeakingPill";
import { Notice } from "@/components/Notice";

SplashScreen.preventAutoHideAsync().catch(() => {});

export default function RootLayout() {
  const [fontsLoaded] = useFonts({ BricolageGrotesque_700Bold });
  const ready = usePeon((s) => s.ready);
  const loggedIn = usePeon((s) => s.token != null);
  const wide = useWide();

  useEffect(() => {
    boot();
    loadVoiceSettings();
  }, []);

  useEffect(() => {
    if (ready && fontsLoaded) SplashScreen.hideAsync().catch(() => {});
  }, [ready, fontsLoaded]);

  if (!ready || !fontsLoaded) return <View style={{ flex: 1, backgroundColor: color.bg }} />;

  const stack = (
    <Stack
      screenOptions={{
        headerShown: false,
        contentStyle: { backgroundColor: color.bg },
        animation: wide ? "none" : "slide_from_right",
      }}
    >
      <Stack.Protected guard={loggedIn}>
        <Stack.Screen name="(tabs)" />
        <Stack.Screen name="project/[id]" />
        <Stack.Screen name="session/[id]" />
        <Stack.Screen name="routine/[id]" />
        <Stack.Screen name="schedules" />
        <Stack.Screen name="new" />
        <Stack.Screen name="users" />
        <Stack.Screen name="connectors" />
        <Stack.Screen name="models" />
        <Stack.Screen
          name="compose"
          options={{
            presentation: "transparentModal",
            animation: "fade",
            contentStyle: { backgroundColor: "transparent" },
          }}
        />
        <Stack.Screen
          name="handsfree"
          options={{ presentation: "fullScreenModal", animation: "slide_from_bottom" }}
        />
      </Stack.Protected>
      <Stack.Protected guard={!loggedIn}>
        <Stack.Screen name="connect" options={{ animation: "fade" }} />
      </Stack.Protected>
    </Stack>
  );

  return (
    <SafeAreaProvider>
      <StatusBar style="light" />
      {wide && loggedIn ? <DesktopShell>{stack}</DesktopShell> : stack}
      <SpeakingPill />
      <Notice />
    </SafeAreaProvider>
  );
}
