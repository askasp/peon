// Voice in and out, on the phone: Apple/Google speech recognition for what you
// say, the system voice for spoken replies. Settings live in lib/storage.

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import * as storage from "./storage";
import * as Speech from "expo-speech";
import { ExpoSpeechRecognitionModule, useSpeechRecognitionEvent } from "expo-speech-recognition";

type VoiceSettings = { reply: boolean; rate: number };

let settings: VoiceSettings = { reply: true, rate: 1.1 };
const listeners = new Set<() => void>();

export async function loadVoiceSettings() {
  try {
    const raw = await storage.getItem("voice");
    if (raw) settings = { ...settings, ...JSON.parse(raw) };
  } catch {}
  listeners.forEach((l) => l());
}

export function setVoiceSettings(patch: Partial<VoiceSettings>) {
  settings = { ...settings, ...patch };
  if (patch.reply === false) Speech.stop();
  storage.setItem("voice", JSON.stringify(settings)).catch(() => {});
  listeners.forEach((l) => l());
}

export function useVoiceSettings(): VoiceSettings {
  const [, force] = useState(0);
  useEffect(() => {
    const l = () => force((n) => n + 1);
    listeners.add(l);
    return () => {
      listeners.delete(l);
    };
  }, []);
  return settings;
}

/** Says `text` when spoken replies are on (or `force`). Resolves when done or stopped. */
// What is being said right now (for the "Speaking · Stop" pill), or null.
let speaking: string | null = null;
const speakingListeners = new Set<() => void>();
const setSpeaking = (text: string | null) => {
  speaking = text;
  speakingListeners.forEach((l) => l());
};

export function useSpeaking(): string | null {
  return useSyncExternalStore(
    (l) => {
      speakingListeners.add(l);
      return () => speakingListeners.delete(l);
    },
    () => speaking,
  );
}

export const isSpeaking = () => speaking != null;

// Whether voice typing is on anywhere (for Escape, which stops it first).
let listeningNow = false;
export const isListening = () => listeningNow;
export const stopListening = () => ExpoSpeechRecognitionModule.stop();

export function say(text: string, force = false): Promise<void> {
  if (!text || (!settings.reply && !force)) return Promise.resolve();
  return new Promise((resolve) => {
    Speech.stop();
    setSpeaking(text);
    const done = () => {
      setSpeaking(null);
      resolve();
    };
    Speech.speak(text, {
      language: "en-US",
      rate: settings.rate,
      onDone: done,
      onStopped: done,
      onError: done,
    });
  });
}

export const stopSpeaking = () => {
  setSpeaking(null);
  return Speech.stop();
};

/**
 * Dictation. `start()` listens; `transcript` follows along while you talk and
 * `onFinal` gets the whole utterance once you pause (or `stop()`). `onSilence`
 * runs when listening ended without any words.
 */
/** What went wrong with voice typing, in words (the recognizer's codes are terse). */
function dictationError(code: string, message?: string): string {
  if (code === "audio-capture") return "No microphone found.";
  if (code === "not-allowed") return "Peon isn't allowed to use the microphone.";
  if (code === "network")
    return "Voice typing needs a connection to the speech service, which isn't reachable.";
  return message || code;
}

export function useDictation(onFinal?: (text: string) => void, onSilence?: () => void) {
  const [listening, setListening] = useState(false);
  const [transcript, setTranscript] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [level, setLevel] = useState(0);
  // Android's continuous mode starts a new segment after each final result.
  const done = useRef("");
  const final = useRef(onFinal);
  const silence = useRef(onSilence);
  useEffect(() => {
    final.current = onFinal;
    silence.current = onSilence;
  });
  const active = useRef(false);
  // A listen that hears no words for a while is stopped, so it can't hang.
  const watchdog = useRef<ReturnType<typeof setTimeout> | null>(null);
  const resetWatchdog = () => {
    if (watchdog.current) clearTimeout(watchdog.current);
    watchdog.current = setTimeout(() => {
      if (active.current) ExpoSpeechRecognitionModule.stop();
    }, 12000);
  };
  const clearWatchdog = () => {
    if (watchdog.current) clearTimeout(watchdog.current);
    watchdog.current = null;
  };

  useSpeechRecognitionEvent("start", () => {
    if (!active.current) return;
    setListening(true);
    listeningNow = true;
    resetWatchdog();
  });

  useSpeechRecognitionEvent("result", (e) => {
    if (!active.current) return;
    const text = e.results[0]?.transcript ?? "";
    resetWatchdog();
    if (e.isFinal) {
      done.current = `${done.current} ${text}`.trim();
      setTranscript(done.current);
    } else {
      setTranscript(`${done.current} ${text}`.trim());
    }
  });

  useSpeechRecognitionEvent("volumechange", (e) => {
    if (active.current) setLevel(Math.max(0, Math.min(1, (e.value + 2) / 12)));
  });

  useSpeechRecognitionEvent("error", (e) => {
    if (!active.current) return;
    if (e.error !== "aborted" && e.error !== "no-speech") setError(dictationError(e.error, e.message));
  });

  useSpeechRecognitionEvent("end", () => {
    if (!active.current) return;
    clearWatchdog();
    active.current = false;
    setListening(false);
    listeningNow = false;
    setLevel(0);
    const text = done.current.trim();
    if (text) final.current?.(text);
    else silence.current?.();
  });

  /** Starts listening; false when it can't (no microphone permission). */
  async function start(): Promise<boolean> {
    setError(null);
    // Firefox (and some other browsers) ship no Web Speech recognition at all.
    if (!ExpoSpeechRecognitionModule.isRecognitionAvailable()) {
      setError("This browser has no speech recognition. Use Chrome, Edge or Safari for voice.");
      return false;
    }
    const perm = await ExpoSpeechRecognitionModule.requestPermissionsAsync();
    if (!perm.granted) {
      setError("Peon needs the microphone and speech recognition. Allow them in Settings.");
      return false;
    }
    Speech.stop();
    done.current = "";
    setTranscript("");
    active.current = true;
    ExpoSpeechRecognitionModule.start({
      lang: "en-US",
      interimResults: true,
      continuous: false,
      addsPunctuation: true,
      volumeChangeEventOptions: { enabled: true, intervalMillis: 120 },
      // Keep the session alive with the screen locked (iOS background audio).
      iosCategory: {
        category: "playAndRecord",
        categoryOptions: ["defaultToSpeaker", "allowBluetooth", "mixWithOthers"],
        mode: "voiceChat",
      },
    });
    return true;
  }

  const stop = () => ExpoSpeechRecognitionModule.stop();

  const cancel = () => {
    clearWatchdog();
    active.current = false;
    done.current = "";
    setTranscript("");
    setListening(false);
    listeningNow = false;
    ExpoSpeechRecognitionModule.abort();
  };

  return { listening, transcript, error, level, start, stop, cancel };
}
