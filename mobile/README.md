# Peon (phone and web app)

Expo / React Native client for beamcode: the phone app (the "Peon iOS Green" design) and,
from the same code, the web app Phoenix serves at `/app` (a sidebar layout on desktop-sized
windows, the phone layout on narrow ones). Everything goes over one Phoenix websocket,
`/socket` (`BeamcodeWeb.UserSocket`):

- `auth`: log in with username and password, get a token (kept in the keychain)
- `app`: projects, inbox, running sessions, routines, schedules, the composer, new projects,
  keyboard settings, password
- `session:<id>`: one session, with streamed text, send (with images), stop, permissions,
  model/agent, rename, compact, diffs, `/` and `@` completion, spoken reply lines
- `project:<id>`: one project's sessions, runs, skills, schedules and settings
- `admin`: users, connectors and secrets, model providers (admins only)

The server pushes every change; the app never polls.

## Run on Android (emulator or device)

```sh
npm install
npx expo prebuild --platform android     # generates android/ (not checked in)
cd android && JAVA_HOME=<a full JDK 17–21> ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb reverse tcp:8081 tcp:8081            # Metro
adb reverse tcp:4000 tcp:4000            # Phoenix, so "localhost:4000" works as the server
npx expo start
```

Log in with server `localhost:4000` (or your host name; plain host names use `wss://`).

## Run on iPhone

Needs macOS, or an EAS cloud build (`npx eas-cli build --profile development --platform ios`)
plus an Apple developer account. `UIBackgroundModes: audio` is set, so hands-free keeps
listening with the screen locked.

## Web

Phoenix serves the web build at `/app` (`BeamcodeWeb.AppController`), logged in with the web
login cookie: the page gets a socket token, the app stores nothing. `mix assets.deploy` builds
it (`mix assets.app`: `npm ci` + `expo export` into `priv/static/app`), so the ansible deploy
picks it up. For development, `npx expo start` and open http://localhost:8081/app (log in with
the server address there).

On desktop: `mod+K` palette, the tmux (`ctrl+b` …) or standard keymap from Settings, `?` for
all shortcuts, `alt+k` composer, `alt+v` talk, a status line at the bottom.

## Checks

`npm run check` (types, lint, formatting). Server-side tests are in `test/beamcode_web/channels/`.

`npm run e2e` drives the built web app against a running server and OpenCode, one PASS/FAIL
line per feature: desktop in Chromium, and the phone layout in WebKit (Safari's engine) as an
iPhone 15. It makes and removes its own test data (`e2e-…`). Needs `npx playwright install
chromium webkit`.

```sh
PEON_URL=http://localhost:4000 PEON_USER=me PEON_PASS=… npm run e2e        # or: e2e -- desktop | iphone
```

## Notes

- If Metro doesn't pick up edits (too few inotify watches on the machine), restart `npx expo start`.
- `react-native-screens` is pinned to 4.29+ (above the SDK default) to fix a cold-start crash
  in Fabric (`MountingCoordinator::pullTransaction`).
- Testing voice on the Android emulator: the headless emulator has no audio. Run the windowed
  one on a private display (`Xvfb :93`, `DISPLAY=:93 emulator -avd … -allow-host-audio`), point
  its input at a PipeWire virtual source (`PULSE_SOURCE=<source>`), turn the host mic on over
  gRPC (`setMicrophoneState(realAudioEnabled)`), and play speech into that source. The emulator
  image's Google TTS voice data is broken; eSpeak NG (F-Droid) works as its TTS engine.
