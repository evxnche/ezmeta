# Desk Pal for Ray-Ban Meta

An iPhone app that puts five things in your Ray-Ban Meta glasses, using Meta's Wearables Device Access
Toolkit (1.0.1):

1. **Desk Pal on the go** — "Hey Meta, start Desk Pal" (or a tap on the glasses, or the Talk button),
   a chime, then talk. Same brain as the desk board: desk-voice `/api/glasses` (web search, weather,
   Noty notes, limits, Spanish practice). After an answer it listens 5 s for a reply.
2. **Agent pager** — Claude Code / Codex alerts from the Mac (`desk-voice/mac/deskpal-notify.py` →
   `/api/agent`) are polled every 20 s and spoken.
3. **Voice notes** — "Note: …" appends a line to the **Inbox** note in Noty; "Add … to my tasks"
   adds a ☐ to the Desk Pal note's to-do list.
4. **ezRead** — "Read my articles" reads the Xteink article inbox (reader-inbox `/api/text`) aloud,
   newest first. Glasses tap = pause/resume, swipe = next article / repeat. Remembers where you were;
   finished or skipped articles aren't read again.
5. **Posture nudge** — head tilt from the glasses' accelerometer (Meta's Motion, beta). Calibrate once
   looking straight ahead; 20 minutes of looking down gets a chime and a reminder.

The phone runs everything; the glasses are mic, speakers, touchpad and motion sensor. "Keep running in
background" plays silence so iOS keeps the app alive in your pocket (fine for a personal build; the App
Store wouldn't allow it).

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

`Config/Secrets.xcconfig` (not committed; see `Secrets.example.xcconfig`) holds `VOICE_KEY` and
`READER_KEY`. Signing uses a free Apple ID team, so the app must be reinstalled every 7 days.

## One-time setup on the phone

1. Meta AI app → your glasses → Developer Mode on.
2. Open Desk Pal → **Connect glasses** → approve in Meta AI.
3. For "Hey Meta, start Desk Pal", touch input and posture: in the Wearables Developer Center
   (wearables.developer.meta.com) create a project with bundle ID `com.evancheriyan.deskpal`, app name
   **Desk Pal**, and turn on Voice Invocation, Inputs and Motion.

In Developer Mode only one third-party app can be registered with Meta AI at a time.
