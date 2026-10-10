import { useEffect, useRef, useState } from "react";
import { currentPayload } from "@/lib/current";
import { Animated, Easing, StyleSheet, Text, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { useKeepAwake } from "expo-keep-awake";
import { Icon } from "@/components/Icon";
import { ErrorLine, Screen, Tap } from "@/components/ui";
import { ask } from "@/lib/peon";
import { useSession } from "@/lib/useSession";
import { say, stopSpeaking, useDictation } from "@/lib/voice";
import { color } from "@/lib/theme";
import type { ComposeResult } from "@/lib/types";

type Phase = "listening" | "thinking" | "speaking" | "paused";

const label: Record<Phase, string> = {
  listening: "Listening",
  thinking: "Working",
  speaking: "Speaking",
  paused: "Paused",
};

const YES = /^(yes|yeah|yep|go|do it|ok|okay|sure|start|confirm)\b/i;

// 09 · Hands-free: talk, Peon answers out loud, and it listens again.
// With a session it talks to that session; without one, the first thing you
// say goes through the composer (and a new session becomes the conversation).
export default function HandsFree() {
  useKeepAwake();
  const params = useLocalSearchParams<{ session?: string }>();
  const [sessionId, setSessionId] = useState<string | null>(params.session ?? null);
  const [phase, setPhase] = useState<Phase>("listening");
  const [you, setYou] = useState("");
  const [peon, setPeon] = useState("");
  const [error, setError] = useState<string | null>(null);
  const pendingPlan = useRef(false);
  const muted = useRef(false);
  const ended = useRef(false);

  const session = useSession(sessionId, (text) => reply(text));
  // Silence ends a listen; start another, up to a few minutes of quiet.
  const quiet = useRef(0);
  const dictation = useDictation(
    (text) => {
      quiet.current = 0;
      heard(text);
    },
    () => {
      if (ended.current || muted.current) return;
      if (++quiet.current > 30) return setPhase("paused");
      setTimeout(listen, 250);
    },
  );

  // Says `text`, then listens again unless muted or ended.
  async function reply(text: string) {
    if (ended.current) return;
    setPeon(text);
    setPhase("speaking");
    await say(text, true);
    listen();
  }

  function listen() {
    if (ended.current) return;
    if (muted.current) return setPhase("paused");
    setPhase("listening");
    dictation.start().then((ok) => {
      if (!ok) setPhase("paused");
    });
  }

  async function heard(text: string) {
    setYou(text);
    setPhase("thinking");
    setError(null);
    try {
      if (sessionId) {
        await session.send(text);
        return; // the reply arrives as a "speak" push
      }
      const r =
        pendingPlan.current && YES.test(text)
          ? await ask<{ result: ComposeResult }>("compose:confirm", {}, 60000)
          : await ask<{ plan?: { summary: string | null; button: string }; result?: ComposeResult }>(
              "compose:submit",
              { text, current: currentPayload() },
              60000,
            );
      pendingPlan.current = false;

      if ("plan" in r && r.plan) {
        pendingPlan.current = true;
        return reply(`${r.plan.summary ?? "Got it."} Say yes to go.`);
      }
      const result = r.result!;
      if (result.kind === "navigate") {
        setSessionId(result.session_id);
        setPeon(result.spoken);
        await say(result.spoken, true);
        setPhase("thinking"); // now waiting for the session's reply
      } else {
        reply(result.spoken);
      }
    } catch (e: any) {
      setError(e.message);
      reply("That didn't work.");
    }
  }

  // Start listening when opened; stop everything when closed.
  useEffect(() => {
    listen();
    return () => {
      ended.current = true;
      stopSpeaking();
      dictation.cancel();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // A turn that ends without anything to say: listen again.
  useEffect(() => {
    if (phase === "thinking" && sessionId && session.status === "idle" && session.joined) {
      const t = setTimeout(() => phase === "thinking" && listen(), 2500);
      return () => clearTimeout(t);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session.status, phase]);

  // Paused (muted, or long quiet) → listen again; otherwise mute.
  function toggleMute() {
    if (phase === "paused") {
      muted.current = false;
      quiet.current = 0;
      listen();
    } else {
      muted.current = true;
      dictation.cancel();
      stopSpeaking();
      setPhase("paused");
    }
  }

  function end() {
    ended.current = true;
    dictation.cancel();
    stopSpeaking();
    router.back();
  }

  const where = sessionId ? (session.session?.title ?? "Session") : "New conversation";
  const caption = phase === "listening" ? dictation.transcript : null;

  return (
    <Screen bottom style={{ backgroundColor: color.bg }}>
      <View style={st.top}>
        <Text style={st.topText} numberOfLines={1}>
          Hands-free · {where}
        </Text>
        <Text style={[st.topText, { color: color.accentText }]}>Voice reply</Text>
      </View>

      <View style={st.middle}>
        <Orb phase={phase} level={dictation.level} />
        <Text style={st.phase}>{label[phase]}</Text>
        {caption ? <Text style={st.caption}>“…{caption}”</Text> : null}
        {!caption && (you || peon) ? (
          <View style={{ gap: 10 }}>
            {you ? <Text style={st.you}>You: {you}</Text> : null}
            {peon ? <Text style={st.peon}>Peon: {peon}</Text> : null}
          </View>
        ) : null}
        <ErrorLine message={error ?? dictation.error} />
      </View>

      <View style={st.buttons}>
        <Round
          label="Type"
          onPress={() => (sessionId ? router.replace(`/session/${sessionId}`) : router.replace("/compose"))}
        >
          <Icon name="keyboard" size={24} color={color.text} />
        </Round>
        <Round label={phase === "paused" ? "Unmute" : "Mute"} onPress={toggleMute} on={phase === "paused"}>
          <Icon name="micOff" size={22} color={phase === "paused" ? color.bg : color.text} />
        </Round>
        <Round label="End" onPress={end} tint={color.danger} testID="end">
          <Icon name="close" size={22} color="#fff" />
        </Round>
      </View>
      <Text style={st.foot}>Pause to send. Peon answers out loud and listens again.</Text>
    </Screen>
  );
}

function Round({
  label,
  children,
  onPress,
  tint,
  on,
  testID,
}: {
  label: string;
  children: React.ReactNode;
  onPress: () => void;
  tint?: string;
  on?: boolean;
  testID?: string;
}) {
  return (
    <View style={{ alignItems: "center", gap: 8 }}>
      <Tap
        haptic
        testID={testID}
        onPress={onPress}
        style={[st.round, { backgroundColor: tint ?? (on ? color.textStrong : color.raised) }]}
      >
        {children}
      </Tap>
      <Text style={st.roundLabel}>{label}</Text>
    </View>
  );
}

const BARS = [18, 36, 52, 30, 44, 22, 12];

// The circle with level bars: they follow your voice, pulse while Peon talks
// or works, and rest when paused.
function Orb({ phase, level }: { phase: Phase; level: number }) {
  const [pulse] = useState(() => new Animated.Value(0));

  useEffect(() => {
    if (phase === "speaking" || phase === "thinking") {
      const loop = Animated.loop(
        Animated.sequence([
          Animated.timing(pulse, {
            toValue: 1,
            duration: phase === "speaking" ? 380 : 900,
            easing: Easing.inOut(Easing.quad),
            useNativeDriver: true,
          }),
          Animated.timing(pulse, {
            toValue: 0,
            duration: phase === "speaking" ? 380 : 900,
            easing: Easing.inOut(Easing.quad),
            useNativeDriver: true,
          }),
        ]),
      );
      loop.start();
      return () => loop.stop();
    }
    pulse.setValue(0);
  }, [phase, pulse]);

  const live = phase === "listening" ? 0.35 + level * 0.65 : phase === "paused" ? 0.25 : 1;

  return (
    <View style={[st.orb, phase === "paused" && { borderColor: color.outline }]}>
      {BARS.map((h, i) => {
        const scale =
          phase === "speaking" || phase === "thinking"
            ? pulse.interpolate({
                inputRange: [0, 1],
                outputRange:
                  i % 2 ? [0.45, phase === "thinking" ? 0.7 : 1] : [phase === "thinking" ? 0.7 : 1, 0.45],
              })
            : live;
        return (
          <Animated.View
            key={i}
            style={[
              st.bar,
              {
                height: h,
                backgroundColor: phase === "paused" ? color.ghost : color.accent,
                transform: [{ scaleY: scale as any }],
              },
            ]}
          />
        );
      })}
    </View>
  );
}

const st = StyleSheet.create({
  top: {
    flexDirection: "row",
    justifyContent: "space-between",
    paddingHorizontal: 22,
    paddingVertical: 10,
    gap: 12,
  },
  topText: { fontSize: 14, color: color.muted, flexShrink: 1 },
  middle: { flex: 1, alignItems: "center", justifyContent: "center", gap: 24, paddingHorizontal: 28 },
  orb: {
    width: 150,
    height: 150,
    borderRadius: 75,
    borderWidth: 1,
    borderColor: color.accent,
    backgroundColor: color.card,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 4,
  },
  bar: { width: 4, borderRadius: 2 },
  phase: { fontSize: 24, fontWeight: "600", color: color.text },
  caption: { fontSize: 17, lineHeight: 25, color: color.textSoft, textAlign: "center" },
  you: { fontSize: 15, lineHeight: 22, color: color.muted },
  peon: { fontSize: 15, lineHeight: 22, color: color.textStrong },
  buttons: { flexDirection: "row", justifyContent: "center", gap: 28, paddingBottom: 22 },
  round: { width: 64, height: 64, borderRadius: 32, alignItems: "center", justifyContent: "center" },
  roundLabel: { fontSize: 12, color: color.textDim },
  foot: { textAlign: "center", fontSize: 13, color: color.faint, paddingHorizontal: 28, paddingBottom: 28 },
});
