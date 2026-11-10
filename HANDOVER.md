# Handover: run Desk Pal on your own glasses, Mac and servers

Everything below uses your own accounts and keys. About 1–2 hours the first time. Do the steps in
order; each one needs the ones before it.

You need: a Mac with Xcode, an iPhone (iOS 17.2+), your Ray-Ban Meta glasses paired in the Meta AI
app, a GitHub account, a Vercel account and a free Apple ID.

```sh
brew install xcodegen
```

## 1. Deploy the three servers on Vercel

Fork or clone each repo, import it in Vercel (vercel.com/new) and set the env vars its README lists.
Don't guess them; the READMEs are the source of truth.

1. **Noty sync server** — github.com/evxnche/noty, folder `web/`. Follow `web/README.md` →
   "Private cloud setup" (its own Vercel project, root directory `web`).
2. **desk-voice** — github.com/evxnche/desk-voice, see its `README.md`. It talks to your Noty sync
   server from step 1.
3. **reader-inbox** — github.com/evxnche/reader-inbox, see its `README.md`.

For all three:

- **Upstash Redis**: Vercel project → Storage → Upstash (free plan). This adds `KV_REST_API_URL` and
  `KV_REST_API_TOKEN`. Redeploy after connecting it.
- **AI Gateway credits** (desk-voice): Vercel dashboard → AI Gateway → add credits. desk-voice's
  speech, model and voice calls go through it.
- Make up the keys with `openssl rand -hex 24` and save them; you need `VOICE_KEY` and `READER_KEY`
  again in step 3.

Write down the two host names Vercel gives you, e.g. `desk-voice-yourname.vercel.app` and
`reader-inbox-yourname.vercel.app`.

## 2. Build the Noty Mac app

```sh
git clone https://github.com/evxnche/noty ~/Developer/noty
cd ~/Developer/noty
./build.sh release
open build/Noty.app
```

Then right-click the Noty pill → **Task Sync…** → enter your Noty sync server's URL and its
`NOTY_SYNC_TOKEN`.

## 3. Fill in Config/Secrets.xcconfig

```sh
git clone https://github.com/evxnche/ezmeta ~/Developer/ezmeta
cd ~/Developer/ezmeta
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
open -e Config/Secrets.xcconfig
```

Fill every line (each has a comment). Host names only, no `https://`. `TEAM_ID` comes in step 4;
`MAC_HOST` is only for step 7. This file is gitignored; never commit it.

## 4. Apple ID and Wearables Developer Center

1. Xcode → Settings → Accounts → **+** → sign in with your Apple ID.
2. Same screen → Manage Certificates… → **+** → Apple Development.
3. Print your team ID and put it in `TEAM_ID`:

   ```sh
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject | grep -o 'OU=[A-Z0-9]*'
   ```

4. In wearables.developer.meta.com, create a project: app name **Desk Pal**, bundle ID = your
   `BUNDLE_ID`, and turn on **Inputs** and **Motion**.

## 5. Build and install on the iPhone

1. iPhone: plug into the Mac, then Settings → Privacy & Security → Developer Mode on (it restarts).
2. Get the phone's UDID:

   ```sh
   xcrun devicectl list devices
   ```

3. Build and install (replace `<UDID>` both times):

   ```sh
   cd ~/Developer/ezmeta
   xcodegen generate
   xcodebuild -project DeskPal.xcodeproj -scheme DeskPal -destination 'id=<UDID>' -clonedSourcePackagesDirPath build/spm -derivedDataPath build/dd -allowProvisioningUpdates build
   xcrun devicectl device install app --device <UDID> build/dd/Build/Products/Debug-iphoneos/DeskPal.app
   ```

4. First launch only: iPhone Settings → General → VPN & Device Management → your Apple ID → Trust.

A free Apple ID signs the app for 7 days. **Every 7 days, run step 5.3 again** (the app stops opening
when it expires).

## 6. Connect the glasses

1. Meta AI app → your glasses → settings → **Developer Mode** on.
2. Open Desk Pal → **Connect glasses** → approve in Meta AI.
3. Leave Settings → "Start when I say Gigi" on; Meta AI asks once for the glasses' microphone. Allow it.
4. Try it: say "Gigi", wait for the chime, say "What's the weather?".

In Developer Mode only one third-party app can be registered with Meta AI at a time.

## 7. Optional: Mac extras

**Head Spaces** (flick your head left/right to switch Mac Spaces, tilt it down/up to scroll; phone and Mac
on the same Wi-Fi):

1. Set `MAC_HOST` in `Config/Secrets.xcconfig` to the output of the line below, then redo step 5.3:

   ```sh
   echo "$(scutil --get LocalHostName).local"
   ```

2. Build and start it (it reads your `VOICE_KEY` from `~/.claude/deskpal/key`; replace `<VOICE_KEY>`):

   ```sh
   mkdir -p ~/.claude/deskpal
   printf '%s' '<VOICE_KEY>' > ~/.claude/deskpal/key
   swiftc -O mac/HeadSpaces.swift -o ~/.claude/deskpal/headspaces
   codesign -f -s "Apple Development" -i com.evan.headspaces ~/.claude/deskpal/headspaces
   sed "s#/Users/evancheriyan#$HOME#" mac/com.evan.headspaces.plist > ~/Library/LaunchAgents/com.evan.headspaces.plist
   launchctl load ~/Library/LaunchAgents/com.evan.headspaces.plist
   ```

3. System Settings → Privacy & Security → Accessibility → **+** → `~/.claude/deskpal/headspaces`
   (press Cmd+Shift+G to type the path).
4. In Desk Pal, Skills tab → turn on **Mac Spaces** and/or **Mac scroll** (scroll asks you to look at the
   screen, then tilt down a little, to calibrate).

**Agent pager** (if you use Claude Code): Desk Pal speaks "done" / "needs you" alerts from Claude
Code. Install `mac/deskpal-notify.py` from your desk-voice repo as its `README.md` describes, pointed at
your desk-voice host.
