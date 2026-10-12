import { createElement } from "react";
import { Linking, Platform, Pressable, StyleSheet, Text, UIManager, View } from "react-native";
import { color } from "@/lib/theme";

// Native only: the web build uses an iframe. A dev build made before
// react-native-webview was added has the JS but not the native view.
const hasWebView = Platform.OS !== "web" && !!UIManager.hasViewManagerConfig?.("RNCWebView");
const WebView = hasWebView
  ? // eslint-disable-next-line @typescript-eslint/no-require-imports
    (require("react-native-webview").WebView as React.ComponentType<any>)
  : null;

/**
 * A page from the server, laid out at `width`×`height` (a phone or a desktop)
 * and scaled to `scale`. Agent-made pages run sandboxed: on the web the server
 * serves them with a CSP sandbox, and the iframe is sandboxed too.
 */
export function Frame({
  url,
  width,
  height,
  scale = 1,
  version = 0,
}: {
  url: string;
  width: number;
  height: number;
  scale?: number;
  /** Changing it reloads the page (the agent edited it). */
  version?: number;
}) {
  const box = { width: width * scale, height: height * scale, overflow: "hidden" as const };
  const inner = { width, height, transform: [{ scale }], transformOrigin: "top left" } as any;
  if (WebView)
    return (
      <View style={box}>
        <View style={inner}>
          <WebView key={version} source={{ uri: url }} style={{ flex: 1, backgroundColor: "#fff" }} />
        </View>
      </View>
    );
  if (Platform.OS !== "web")
    return (
      <Pressable style={[box, st.open]} onPress={() => Linking.openURL(url)}>
        <Text style={st.openText}>Open in Safari</Text>
        <Text style={st.openSub}>This build can&apos;t show pages yet</Text>
      </Pressable>
    );
  return (
    <View style={box}>
      {createElement("iframe", {
        key: version,
        src: url,
        sandbox: "allow-scripts allow-forms allow-popups allow-modals",
        style: {
          width,
          height,
          // A flex child: without this it shrinks to the scaled box's height.
          flexShrink: 0,
          border: 0,
          background: "#fff",
          transform: `scale(${scale})`,
          transformOrigin: "0 0",
        },
      })}
    </View>
  );
}

const st = StyleSheet.create({
  open: {
    alignItems: "center",
    justifyContent: "center",
    gap: 4,
    borderRadius: 12,
    backgroundColor: color.card,
    borderWidth: 1,
    borderColor: color.border,
  },
  openText: { fontSize: 15, fontWeight: "600", color: color.accentText },
  openSub: { fontSize: 12, color: color.faint },
});
