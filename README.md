# Notch Assistant

A voice assistant for the MacBook notch. The design is in
[Notch Assistant Technical Specification.md](Notch%20Assistant%20Technical%20Specification.md).
This is **v1**: hold ⌥Space, speak, release. The notch shows what's happening
on the built-in display only; the menu bar icon mirrors it. Settings (menu bar
icon › Settings…) has Capabilities, Permissions and Display panes.

**Hands-free (v2):** Settings › Activation › *Listen for “Alfred”* (off by
default). Say "Alfred", optionally pause, then the command. It is paused on
battery, in Low Power Mode and when the Mac is hot; ⌥Space always works. Each
detection is confirmed by speech recognition before anything happens. Extra
wake models (e.g. "hey alfred" trained with openWakeWord's Colab notebook) go
in `~/Library/Application Support/NotchAssistant/WakeWords/`; see
`Resources/WakeWord/SOURCES.md` for the bundled models and their licences.

Debug builds add **Preview Notch States** to the menu bar menu, which cycles
through all six states without speaking.

## Requirements

- macOS 26, Xcode 26
- Apple Intelligence turned on (System Settings › Apple Intelligence & Siri)

## Build and run

```sh
scripts/build-app.sh          # → ~/Applications/NotchAssistant.app, signed with your Apple Development cert
open ~/Applications/NotchAssistant.app
```

Launch it with `open`, not by running the binary from a terminal. Otherwise
macOS attributes microphone access to the terminal instead of the app.

First launch asks for Microphone and Speech Recognition access.

Watch what it does:

```sh
log stream --level info --predicate 'subsystem == "dev.shripad.NotchAssistant"'
```

## Test

```sh
swift test                                            # state machine, name matching, URL safety, plan decoding
swift run plan-cli "open spotify" "open youtube in arc"   # dry-run the real model, executes nothing
swift run plan-cli - < Tests/Fixtures/intents.txt
```

## Layout

`Vendor/DynamicNotchKit` is a patched copy of DynamicNotchKit; see its
`PATCHES.md` for why and what changed.

`Sources/NotchAssistantCore` holds the layers from spec §3 (Activation, Speech,
Intelligence, Tools, Coordinator, Presentation). `Sources/NotchAssistant` is
the app shell and composition root. `Sources/PlanCLI` is the dry-run tool.
