// Voice in and out for the composers (the "Voice Composer" design).
//
//   [data-voice-mic="<field id>"]   mic button: talk into that input/textarea
//   [data-voice-reply-toggle]       spoken replies on/off (kept in localStorage)
//   alt+v                           talk into the focused composer, else the session
//                                   composer, else the global bar
//   alt+k                           focus the global bar
//   Escape                          stop listening / clear the global bar
//
// Speech-to-text is the browser's (Chrome, Edge, Safari). The server pushes
// "voice:speak" {text} with a short spoken version of a reply (Beamcode.Speech);
// it is said only while spoken replies are on.
//
// State goes on <html> (data-voice, data-voice-reply) so LiveView patches never
// undo it; app.css does the showing.

const root = document.documentElement
const SR = window.SpeechRecognition || window.webkitSpeechRecognition
const synth = window.speechSynthesis
const GLOBAL = "global-composer-input"

let rec = null

const store = {
  get(k) { try { return localStorage.getItem(k) } catch (_) { return null } },
  set(k, v) { try { localStorage.setItem(k, v) } catch (_) {} },
}

// The composer grammar is English ("new session in …"), so default to it.
const lang = () => store.get("peon:voice-lang") || "en-US"
const replyOn = () => root.hasAttribute("data-voice-reply")

function setReply(on) {
  root.toggleAttribute("data-voice-reply", on)
  store.set("peon:voice-reply", on ? "1" : "0")
  if (!on) stopSpeaking()
}
root.toggleAttribute("data-voice-reply", store.get("peon:voice-reply") === "1")

// ── Pill: "Speaking · Stop", or a short notice ─────────────────────────────

let pillTimer = null

function pill(kind, text) {
  clearTimeout(pillTimer)
  let el = document.getElementById("voice-pill")
  if (!el) {
    el = document.createElement("div")
    el.id = "voice-pill"
    el.setAttribute("role", "status")
    document.body.append(el)
  }
  el.className = kind === "notice" ? "notice" : ""
  el.replaceChildren()
  if (kind === "speaking") {
    const wave = document.createElement("span")
    wave.className = "voice-wave items-center gap-[2px]"
    for (let i = 0; i < 5; i++) {
      const bar = document.createElement("span")
      bar.className = "voice-bar"
      bar.style.animationDelay = `${i * 80}ms`
      wave.append(bar)
    }
    const stop = document.createElement("button")
    stop.type = "button"
    stop.textContent = "Stop"
    stop.addEventListener("click", stopSpeaking)
    el.append(wave, Object.assign(document.createElement("span"), {textContent: "Speaking"}), stop)
  } else {
    el.textContent = text
    pillTimer = setTimeout(hidePill, 3500)
  }
}

function hidePill() { document.getElementById("voice-pill")?.remove() }

const notice = (text) => pill("notice", text)

// ── Speaking ───────────────────────────────────────────────────────────────

function speak(text) {
  if (!synth || !text || !replyOn()) return
  synth.cancel()
  const u = new SpeechSynthesisUtterance(text)
  u.lang = lang()
  const voice = synth.getVoices().find(v => v.lang === u.lang && v.localService) ||
    synth.getVoices().find(v => v.lang === u.lang)
  if (voice) u.voice = voice
  u.rate = 1.05
  u.onstart = () => pill("speaking")
  u.onend = u.onerror = () => { if (!synth.speaking) hidePill() }
  synth.speak(u)
}

function stopSpeaking() {
  synth?.cancel()
  if (document.getElementById("voice-pill")?.className !== "notice") hidePill()
}

window.addEventListener("phx:voice:speak", (e) => speak(e.detail?.text))

// ── Listening ──────────────────────────────────────────────────────────────

function listening() { return rec !== null }

function stop() {
  if (rec) { try { rec.stop() } catch (_) {} }
}

function listen(el) {
  if (!el) return
  if (rec) { const same = rec.el === el; stop(); if (same) return }
  if (!SR) return notice("Voice input needs Chrome, Edge or Safari.")
  stopSpeaking()

  // Keep what was typed; speech goes after it.
  const base = el.value.trim() ? el.value.trimEnd() + " " : ""
  let written = el.value, heard = false
  const r = new SR()
  r.el = el
  r.lang = lang()
  r.interimResults = true
  r.continuous = false
  r.onresult = (e) => {
    // Sent or edited while we listened: stop rather than write over it.
    if (el.value !== written) return stop()
    heard = true
    written = base + Array.from(e.results).map(x => x[0].transcript).join("")
    el.value = written
    el.dispatchEvent(new Event("input", {bubbles: true}))
  }
  r.onerror = (e) => {
    if (e.error === "not-allowed" || e.error === "service-not-allowed")
      notice("Microphone is blocked. Allow it from the address bar.")
    else if (e.error === "no-speech") notice("Didn’t catch that.")
    else if (e.error === "network") notice("Speech service unreachable.")
  }
  r.onend = () => {
    if (rec !== r) return
    rec = null
    root.removeAttribute("data-voice")
    if (heard && document.body.contains(el)) {
      el.focus()
      el.setSelectionRange?.(el.value.length, el.value.length)
    }
  }
  rec = r
  root.setAttribute("data-voice", el.id)
  try { r.start() } catch (_) { rec = null; root.removeAttribute("data-voice") }
}

// The field alt+v talks into: the focused composer, else the session one, else the bar.
function talkTarget() {
  const active = document.activeElement
  if (active && (active.id === "composer" || active.id === GLOBAL)) return active
  return document.getElementById("composer") || document.getElementById(GLOBAL)
}

// ── Wiring ─────────────────────────────────────────────────────────────────

document.addEventListener("click", (e) => {
  const mic = e.target.closest?.("[data-voice-mic]")
  if (mic) { e.preventDefault(); return listen(document.getElementById(mic.dataset.voiceMic)) }
  const toggle = e.target.closest?.("[data-voice-reply-toggle]")
  if (toggle) {
    e.preventDefault()
    setReply(!replyOn())
    // Also unlocks speech on browsers that want a click first (Safari).
    if (replyOn()) speak("Voice replies on.")
  }
})

// Sending stops the mic.
document.addEventListener("submit", (e) => { if (e.target.id === "global-composer-form") stop() }, true)

// Capture phase, so these win over keybinds.js (where Escape interrupts a session).
window.addEventListener("keydown", (e) => {
  if (e.isComposing) return
  const alt = e.altKey && !e.ctrlKey && !e.metaKey
  if (alt && e.code === "KeyV") {
    e.preventDefault(); e.stopPropagation()
    return listen(talkTarget())
  }
  if (alt && e.code === "KeyK") {
    e.preventDefault(); e.stopPropagation()
    return document.getElementById(GLOBAL)?.focus()
  }
  if (e.key !== "Escape") return
  if (listening()) { e.preventDefault(); e.stopPropagation(); return stop() }
  if (synth?.speaking) { e.preventDefault(); e.stopPropagation(); return stopSpeaking() }
  if (e.target.id === GLOBAL) {
    e.preventDefault(); e.stopPropagation()
    if (e.target.value) {
      e.target.value = ""
      e.target.dispatchEvent(new Event("input", {bubbles: true}))
    } else {
      e.target.blur()
    }
  }
}, true)

// Leaving a page ends listening into a field that is going away.
window.addEventListener("phx:page-loading-start", stop)
