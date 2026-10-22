# Desk Pal for Ray-Ban Meta

An iPhone app that puts six things in your Ray-Ban Meta glasses, using Meta's Wearables Device Access
Toolkit (1.0.1):

1. **Desk Pal on the go** — say "Gigi" (or double tap the glasses, or press Talk), a chime, then talk.
   The glasses' own speech recognition (Meta's Speech, beta) listens for "Gigi" while the app runs.
   Same brain as the desk board: desk-voice `/api/glasses` (web search, weather, Noty notes, limits,
   Spanish practice). After an answer it listens 5 s for a reply. "Dictation mode" types each sentence
   wherever the Mac's cursor is (transcribed by `/api/glasses` with `X-Dictate: 1`, typed by desk-voice's
   `mac/deskpal-mac.py` on port 8737, same Wi-Fi) until "stop dictation", a tap, or 10 quiet minutes.
2. **Agent pager** — Claude Code / Codex alerts from the Mac (`desk-voice/mac/deskpal-notify.py` →
   `/api/agent`) are polled every 20 s and spoken.
3. **Voice notes** — "Note: …" appends a line to the **Inbox** note in Noty; "Add … to my tasks"
   adds a ☐ to the Desk Pal note's to-do list.
4. **ezRead** — "Read my articles" reads the Xteink article inbox (reader-inbox `/api/text`) aloud,
   newest first. Glasses tap = pause/resume, swipe = next article / repeat. Remembers where you were;
   finished or skipped articles aren't read again.
5. **Posture nudge** — head tilt from the glasses' accelerometer (Meta's Motion, beta). Calibrate once
   looking straight ahead; 20 minutes of looking down gets a chime and a reminder.
6. **Mac Spaces** — a quick head turn left or right switches Mac Spaces like a four-finger swipe
   (gyroscope, 30 Hz). The phone calls Head Spaces on the Mac (`mac/HeadSpaces.swift`, port 8765,
   same Wi-Fi), which presses Ctrl+←/→. Build it with
   `swiftc -O mac/HeadSpaces.swift -o ~/.claude/deskpal/headspaces`, copy `mac/com.evan.headspaces.plist`
   to `~/Library/LaunchAgents`, and allow the binary in Privacy & Security → Accessibility.

The phone runs everything; the glasses are mic, speakers, touchpad and motion sensor. The app always
plays silence so iOS keeps it alive in your pocket (fine for a personal build; the App Store wouldn't
allow it).

The app has three tabs: **Home** (Talk, the glasses, ezRead, the last conversation), **Skills**
(everything above with example phrases, and the switches for agent alerts, posture and Mac Spaces) and
**Settings** ("Start when I say Gigi", and **Diagnostics**: connection details, what the glasses last
heard, and the log).

Setting it up from zero on your own Mac, servers and Apple ID: [HANDOVER.md](HANDOVER.md).

## Build

The project folder's path has a colon (`s:w`), which breaks Xcode's dependency files, so build through
the symlink `~/Developer/ezmeta`:

```sh
cd ~/Developer/ezmeta
xcodegen generate
xcodebuild -project DeskPal.xcodeproj -scheme DeskPal -destination 'id=<iPhone UDID>' \
  -clonedSourcePackagesDirPath build/spm -derivedDataPath ~/Developer/ezmeta-dd -allowProvisioningUpdates build
xcrun devicectl device install app --device <iPhone UDID> ~/Developer/ezmeta-dd/Build/Products/Debug-iphoneos/DeskPal.app
```

`Config/Secrets.xcconfig` (not committed; see `Secrets.example.xcconfig`) holds the bundle ID and team
(`BUNDLE_ID`, `TEAM_ID`), the servers' host names (`VOICE_HOST`, `READER_HOST`, `MAC_HOST`) and keys
(`VOICE_KEY`, `READER_KEY`). Signing uses a free Apple ID team, so the app must be reinstalled every
7 days.

## One-time setup on the phone

1. Meta AI app → your glasses → Developer Mode on.
2. Open Desk Pal → **Connect glasses** → approve in Meta AI.
3. For touch input, posture and head switching: in the Wearables Developer Center
   (wearables.developer.meta.com) create a project with your `BUNDLE_ID`, app name **Desk Pal**, and
   turn on Inputs and Motion.
4. Leave Settings → "Start when I say Gigi" on; Meta AI asks once for the glasses' microphone.

In Developer Mode only one third-party app can be registered with Meta AI at a time.
