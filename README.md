# Notch Assistant ("Alfred")

A voice assistant that lives in the MacBook notch. Say "Alfred, …" (or hold ⌥Space) and it acts on the Mac.

- **No cloud AI.** Commands are understood by Apple's on-device Foundation Models.
- **Speech stays on the Mac.** Recognition is on-device, and so is the optional natural voice (Kokoro).

The design, and every place the build departs from it, is in [Notch Assistant Technical Specification.md](Notch%20Assistant%20Technical%20Specification.md).

## What it can do

| Area | Say |
| --- | --- |
| Apps and web | "open Spotify", "open YouTube in Arc", "search for …" |
| YouTube | "play Mat Armstrong's latest video on YouTube" (opens in its own tab) |
| Spotify | "play my Liked Songs", "play Bohemian Rhapsody", "next", "pause" |
| System | "volume 30", "brightness up", "turn on Do Not Disturb", "lock the screen" |
| Files | "open my latest screenshot", "rename test txt to notes", "move … to Documents", "undo that". Metadata only; nothing is ever read or permanently deleted |
| Weather | "how's the weather", "will it rain tomorrow in Paris" |
| Clock | "set a timer for 10 minutes", "wake me up at 7 on weekdays", "start the stopwatch", "remind me to call Mum at 6", "what time is it in Tokyo" |
| Calendar | "what's on my calendar tomorrow", "when's my next meeting", "am I free at 3". Apple Calendar, Google or Outlook, read-only |
| Windows | "put Safari on the left half", "full screen", "move this to the other display" |
| Clipboard and notes | "what's on my clipboard", "paste as plain text", "note that the Wi-Fi password is on the router" |
| Routines | Your own phrases that run several steps: "I'm home" → lights (via Shortcuts), a playlist, VS Code |

**How it shows and starts:**

- **Notch:** timers ring in the notch with Stop and Snooze, and a running timer counts down beside it.
- **Hands-free:** the "Alfred" wake word is optional. So are hand gestures: an open palm starts listening and a fist cancels.

## Requirements

- An Apple silicon MacBook with a notch, running macOS 26.
- Xcode 26 (Swift 6.2).
- Apple Intelligence turned on in System Settings. The Mac and Siri languages must match.

## Build and run

```sh
scripts/build-app.sh            # release build → ~/Applications/NotchAssistant.app
open ~/Applications/NotchAssistant.app
scripts/build-app.sh debug      # adds a main-thread stall detector and a notch preview menu item
```

**Signing.** The script signs with your Apple Development certificate if there is one; otherwise the signature is ad hoc, and macOS asks for permissions again after every build. It builds outside the project folder because iCloud Drive's file attributes break `codesign`.

**Launching.** Start the app with `open`, not by running the binary from a terminal. Otherwise macOS attributes microphone access to the terminal. The first launch asks for Microphone and Speech Recognition; everything else is asked the first time a feature needs it. Settings › Permissions shows every grant.

### Optional setup

All of these use your own free credentials. The repository contains none.

- **Spotify song and playlist names:** create an app at developer.spotify.com, then follow Settings › Spotify.
- **Google Calendar or Outlook:** create an OAuth client or app registration and follow Settings › Calendar. Apple Calendar needs nothing, and also covers Google and Exchange accounts added in System Settings › Internet Accounts.
- **Apple WeatherKit:** place a macOS provisioning profile with the WeatherKit capability at `Resources/NotchAssistant.provisionprofile` (git-ignored). Without it, weather comes from Open-Meteo.
- **Natural voice:** pick a Kokoro voice in Settings › Model & Voice. It downloads once, about 80 MB.

## Test

```sh
swift test                                                # about 270 tests; no microphone or model needed
swift run plan-cli "open spotify" "set a timer for 10 minutes"   # see the plan for a command; executes nothing
log stream --level info --predicate 'subsystem == "dev.shripad.NotchAssistant"'
```

## Layout

- `Sources/NotchAssistantCore` holds the layers from the spec: Activation, Speech, Intelligence, Tools, Clock, Calendar and Coordinator.
- `Sources/NotchAssistant` is the app shell: menu bar, notch UI, Settings, Kokoro.
- `Sources/PlanCLI` is the dry-run tool.
- `Vendor/DynamicNotchKit` is a patched copy of DynamicNotchKit; see its `PATCHES.md`.

## Privacy

- **Requests:** everything is understood and acted on locally.
- **What goes online:** the weather's place name, web searches you ask for, and your own Spotify or calendar accounts when connected.
- **Credentials:** tokens and secrets are stored in the Keychain.
- **Camera:** used only while hand gestures are on. Nothing is recorded.

## Credits

- [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) (MIT)
- [openWakeWord](https://github.com/dscripka/openWakeWord) models (see `Resources/WakeWord/SOURCES.md`)
- [ONNX Runtime](https://github.com/microsoft/onnxruntime-swift-package-manager) (MIT)
- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0)
- [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) (Apache-2.0)
