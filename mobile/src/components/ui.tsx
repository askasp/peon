import { ReactNode, useEffect, useState } from "react";
import {
  ActivityIndicator,
  Animated,
  Platform,
  Pressable,
  PressableProps,
  StyleProp,
  StyleSheet,
  Text,
  TextStyle,
  View,
  ViewStyle,
} from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { router } from "expo-router";
import * as Haptics from "expo-haptics";
import { color } from "@/lib/theme";
import { useWide } from "@/lib/useWide";
import { Icon } from "./Icon";

const AnimatedPressable = Animated.createAnimatedComponent(Pressable);

export type KbKind = "row" | "item" | "tab" | "search";

/**
 * Web: marks an element for keyboard navigation (lib/keys): sidebar items,
 * tabs, and rows in the main area that j/k move through and Enter opens.
 */
export const kbProps = (kind?: KbKind, current = false): object =>
  kind && Platform.OS === "web" ? { dataSet: { kb: kind, kbCurrent: current ? "1" : undefined } } : {};

/** A pressable that dips slightly while held: the app's one micro-interaction. */
export function Tap({
  style,
  children,
  haptic = false,
  kb,
  onPress,
  ...rest
}: PressableProps & { style?: StyleProp<ViewStyle>; children?: ReactNode; haptic?: boolean; kb?: KbKind }) {
  const [scale] = useState(() => new Animated.Value(1));
  const to = (v: number) =>
    Animated.spring(scale, { toValue: v, useNativeDriver: true, speed: 40, bounciness: 0 }).start();

  return (
    <AnimatedPressable
      {...rest}
      {...kbProps(kb)}
      style={[style, { transform: [{ scale }] }, rest.disabled ? { opacity: 0.5 } : null]}
      onPressIn={(e) => {
        to(0.97);
        rest.onPressIn?.(e);
      }}
      onPressOut={(e) => {
        to(1);
        rest.onPressOut?.(e);
      }}
      onPress={(e) => {
        if (haptic) Haptics.selectionAsync().catch(() => {});
        onPress?.(e);
      }}
    >
      {children}
    </AnimatedPressable>
  );
}

export function Screen({
  children,
  style,
  bottom = false,
  full = false,
}: {
  children: ReactNode;
  style?: StyleProp<ViewStyle>;
  bottom?: boolean;
  /** Desktop: use the whole content area instead of a centred column. */
  full?: boolean;
}) {
  const insets = useSafeAreaInsets();
  const wide = useWide();
  return (
    <View
      style={[
        { flex: 1, backgroundColor: color.bg, paddingTop: insets.top },
        bottom && { paddingBottom: insets.bottom },
        style,
      ]}
    >
      {/* Desktop: a readable column in the middle of the content area. */}
      {wide && !full ? (
        <View style={{ flex: 1, width: "100%", maxWidth: 980, alignSelf: "center" }}>{children}</View>
      ) : (
        children
      )}
    </View>
  );
}

export function LargeTitle({ children, right }: { children: ReactNode; right?: ReactNode }) {
  return (
    <View style={s.titleRow}>
      <Text style={s.largeTitle} numberOfLines={1}>
        {children}
      </Text>
      {right}
    </View>
  );
}

export function BackHeader({ label, right }: { label: string; right?: ReactNode }) {
  return (
    <View style={s.backRow}>
      <Tap
        onPress={() => (router.canGoBack() ? router.back() : router.replace("/"))}
        style={s.back}
        hitSlop={10}
      >
        <Icon name="back" size={22} color={color.accentText} />
        <Text style={s.backLabel}>{label}</Text>
      </Tap>
      {right}
    </View>
  );
}

export function Card({
  children,
  style,
  accent,
  needs,
}: {
  children: ReactNode;
  style?: StyleProp<ViewStyle>;
  accent?: boolean;
  /** Waiting on you: amber. */
  needs?: boolean;
}) {
  return <View style={[s.card, accent && s.cardAccent, needs && s.cardNeeds, style]}>{children}</View>;
}

export function Group({ children, style }: { children: ReactNode; style?: StyleProp<ViewStyle> }) {
  return <View style={[s.group, style]}>{children}</View>;
}

export function SectionLabel({ children, style }: { children: ReactNode; style?: StyleProp<TextStyle> }) {
  return <Text style={[s.section, style]}>{children}</Text>;
}

type ButtonKind = "primary" | "secondary" | "accent" | "danger";

export function Button({
  label,
  onPress,
  kind = "primary",
  busy,
  disabled,
  style,
  height = 40,
  icon,
  testID,
}: {
  label: string;
  onPress?: () => void;
  kind?: ButtonKind;
  busy?: boolean;
  disabled?: boolean;
  style?: StyleProp<ViewStyle>;
  height?: number;
  icon?: ReactNode;
  testID?: string;
}) {
  const look = {
    primary: { bg: color.textStrong, fg: color.bg, border: "transparent" },
    secondary: { bg: "transparent", fg: color.text, border: color.outline },
    accent: { bg: color.accent, fg: color.accentInk, border: "transparent" },
    danger: { bg: "transparent", fg: color.red, border: color.outline },
  }[kind];

  return (
    <Tap
      testID={testID}
      haptic
      onPress={onPress}
      disabled={disabled || busy}
      style={[
        s.button,
        { height, backgroundColor: look.bg, borderColor: look.border, borderRadius: height >= 50 ? 12 : 10 },
        style,
      ]}
    >
      {busy ? (
        <ActivityIndicator color={look.fg} />
      ) : (
        <>
          {icon}
          <Text style={[s.buttonText, { color: look.fg, fontWeight: kind === "secondary" ? "400" : "600" }]}>
            {label}
          </Text>
        </>
      )}
    </Tap>
  );
}

export function Segmented<T extends string>({
  options,
  value,
  onChange,
}: {
  options: { value: T; label: string }[];
  value: T;
  onChange: (v: T) => void;
}) {
  return (
    <View style={s.segmented}>
      {options.map((o) => {
        const on = o.value === value;
        return (
          <Pressable
            key={o.value}
            {...kbProps("tab", on)}
            onPress={() => onChange(o.value)}
            style={[s.segment, on && s.segmentOn]}
          >
            <Text style={[s.segmentText, on && s.segmentTextOn]}>{o.label}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}

/** Tabs as text with an underline (desktop page headers). */
export function UnderlineTabs<T extends string>({
  options,
  value,
  onChange,
}: {
  options: { value: T; label: string }[];
  value: T;
  onChange: (v: T) => void;
}) {
  return (
    <View style={s.utabs}>
      {options.map((o) => {
        const on = o.value === value;
        return (
          <Pressable
            key={o.value}
            {...kbProps("tab", on)}
            onPress={() => onChange(o.value)}
            style={(st: any) => [
              s.utab,
              on && s.utabOn,
              st.hovered && !on && { borderBottomColor: color.ghost },
            ]}
          >
            <Text style={[s.utabText, on && { color: color.textStrong }]}>{o.label}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}

export function Dot({ size = 8, tint = color.accent }: { size?: number; tint?: string }) {
  return <View style={{ width: size, height: size, borderRadius: size / 2, backgroundColor: tint }} />;
}

export function Badge({
  label,
  tint = "accent",
}: {
  label: string;
  tint?: "accent" | "muted" | "red" | "needs";
}) {
  const look = {
    accent: { bg: color.accentWash, fg: color.accentText },
    needs: { bg: color.needsWash, fg: color.needs },
    muted: { bg: color.raised, fg: color.textDim },
    red: { bg: "#2a1716", fg: color.red },
  }[tint];
  return <Text style={[s.badge, { backgroundColor: look.bg, color: look.fg }]}>{label}</Text>;
}

export function Toggle({
  value,
  onChange,
  label,
}: {
  value: boolean;
  onChange: (v: boolean) => void;
  label?: string;
}) {
  const [x] = useState(() => new Animated.Value(value ? 22 : 2));
  // Follows the value, also when the server changes or reverts it.
  useEffect(() => {
    Animated.spring(x, { toValue: value ? 22 : 2, useNativeDriver: true, speed: 30, bounciness: 4 }).start();
  }, [value, x]);
  return (
    <Pressable
      role="switch"
      aria-checked={value}
      aria-label={label}
      onPress={() => {
        Haptics.selectionAsync().catch(() => {});
        onChange(!value);
      }}
      style={[s.toggle, { backgroundColor: value ? color.switchOn : "#39393d" }]}
    >
      <Animated.View style={[s.knob, { transform: [{ translateX: x }] }]} />
    </Pressable>
  );
}

export function Empty({ title, detail }: { title: string; detail?: string }) {
  return (
    <View style={s.empty}>
      <Text style={s.emptyTitle}>{title}</Text>
      {detail ? <Text style={s.emptyDetail}>{detail}</Text> : null}
    </View>
  );
}

export function Loading() {
  return (
    <View style={s.empty}>
      <ActivityIndicator color={color.muted} />
    </View>
  );
}

export function ErrorLine({ message }: { message: string | null }) {
  if (!message) return null;
  return <Text style={s.error}>{message}</Text>;
}

/** A letter tile for projects. */
export function Tile({ name, size = 36 }: { name: string; size?: number }) {
  return (
    <View style={[s.tile, { width: size, height: size, borderRadius: size / 4 }]}>
      <Text style={s.tileText}>{name.slice(0, 1).toUpperCase()}</Text>
    </View>
  );
}

export const s = StyleSheet.create({
  titleRow: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", gap: 12 },
  largeTitle: { flexShrink: 1, fontSize: 32, fontWeight: "700", letterSpacing: -0.6, color: color.text },
  backRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 12,
    paddingVertical: 6,
  },
  back: { flexDirection: "row", alignItems: "center", gap: 4 },
  backLabel: { color: color.accentText, fontSize: 16 },
  card: {
    padding: 14,
    borderRadius: 16,
    backgroundColor: color.card,
    borderWidth: 1,
    borderColor: color.border,
    gap: 10,
  },
  cardAccent: { backgroundColor: color.accentCard, borderColor: color.accentBorder },
  utabs: { flexDirection: "row", gap: 24 },
  utab: {
    paddingTop: 4,
    paddingBottom: 10,
    paddingHorizontal: 1,
    borderBottomWidth: 2,
    borderBottomColor: "transparent",
  },
  utabOn: { borderBottomColor: color.textStrong },
  utabText: { fontSize: 14, color: color.muted },
  cardNeeds: { backgroundColor: color.needsCard, borderColor: color.needsBorder },
  group: { borderRadius: 14, backgroundColor: color.card, overflow: "hidden" },
  section: { fontSize: 13, color: color.muted, marginTop: 4 },
  button: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    borderWidth: 1,
    paddingHorizontal: 14,
  },
  buttonText: { fontSize: 15 },
  segmented: { flexDirection: "row", padding: 3, borderRadius: 10, backgroundColor: color.field },
  segment: { flex: 1, alignItems: "center", paddingVertical: 7, borderRadius: 8 },
  segmentOn: { backgroundColor: color.pill },
  segmentText: { fontSize: 14, color: color.textDim },
  segmentTextOn: { color: color.text, fontWeight: "600" },
  badge: {
    fontSize: 12,
    paddingHorizontal: 8,
    paddingVertical: 2,
    borderRadius: 6,
    overflow: "hidden",
  },
  toggle: { width: 51, height: 31, borderRadius: 16 },
  knob: { position: "absolute", top: 2, width: 27, height: 27, borderRadius: 14, backgroundColor: "#fff" },
  empty: { paddingVertical: 48, alignItems: "center", gap: 6 },
  emptyTitle: { color: color.textSoft, fontSize: 16 },
  emptyDetail: { color: color.muted, fontSize: 14, textAlign: "center", paddingHorizontal: 24 },
  error: { color: color.red, fontSize: 14 },
  tile: { borderWidth: 1, borderColor: color.outline, alignItems: "center", justifyContent: "center" },
  tileText: { color: color.text, fontWeight: "600", fontSize: 16 },
});
