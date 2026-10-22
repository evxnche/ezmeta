import MWDATCore
import SwiftUI

struct ContentView: View {
  let app: AppModel
  @State private var keepAlive = AudioRoute.shared.keepAlive

  var body: some View {
    NavigationStack {
      Form {
        glassesSection
        talkSection
        readerSection
        pagerSection
        postureSection
        headSwitchSection
        Section("Log") {
          ForEach(Array(Log.shared.lines.suffix(30).reversed().enumerated()), id: \.offset) { _, line in
            Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Desk Pal")
    }
  }

  private var glassesSection: some View {
    Section("Glasses") {
      if app.glasses.registration != .registered {
        Button("Connect glasses (opens Meta AI)") { app.glasses.register() }
          .disabled(app.glasses.registration == .registering)
        Text("Turn on Developer Mode in the Meta AI app first.").font(.footnote).foregroundStyle(.secondary)
      }
      row("Status", app.glasses.registration.description)
      row("Glasses", [app.glasses.deviceName, app.glasses.battery.map { "\($0)%" },
                      app.glasses.worn.map { $0 ? "on your face" : "off" }].compactMap { $0 }.joined(separator: " · "))
      row("Link", app.glasses.link ?? "no glasses seen")
      row("Session", app.glasses.session)
      row("Touch input", app.glasses.inputs)
      Toggle("Keep running in background", isOn: $keepAlive)
        .onChange(of: keepAlive) { AudioRoute.shared.keepAlive = keepAlive }
    }
  }

  private var talkSection: some View {
    Section("Desk Pal") {
      Button { app.talk() } label: {
        Label(app.pal.busy ? "\(app.pal.status.rawValue)… (tap to stop)" : "Talk", systemImage: "waveform")
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(.borderedProminent)
      Toggle("Start when I say \"Gigi\"", isOn: Bindable(app).wakeWord)
      if app.wakeWord {
        row("Glasses", app.glasses.speech)
        row("Last heard", app.glasses.lastHeard)
      }
      if !app.pal.heard.isEmpty { row("You", app.pal.heard) }
      if !app.pal.reply.isEmpty { row("Pal", app.pal.reply) }
      Text("Say \"Gigi\", then after the chime try: \"Note: buy solder\", \"Add call the bank to my tasks\", \"What's on my plan?\", \"Read my articles\".")
        .font(.footnote).foregroundStyle(.secondary)
    }
  }

  private var readerSection: some View {
    Section("ezRead") {
      if app.reader.reading {
        Text(app.reader.title).font(.headline)
        Text(app.reader.progress).font(.footnote).foregroundStyle(.secondary)
        HStack {
          Button(app.reader.paused ? "Resume" : "Pause") { app.reader.togglePause() }
          Spacer()
          Button("Again") { app.reader.repeatParagraph() }
          Spacer()
          Button("Next article") { app.reader.nextArticle() }
          Spacer()
          Button("Stop", role: .destructive) { app.reader.stop() }
        }
        .buttonStyle(.borderless)
      } else {
        Button("Read my articles") { app.startReading() }
      }
    }
  }

  private var pagerSection: some View {
    Section("Agent pager") {
      Toggle("Say Claude Code / Codex alerts", isOn: Bindable(app.pager).enabled)
      row("Last", app.pager.last)
    }
  }

  private var postureSection: some View {
    Section("Posture") {
      Toggle("Nudge me after \(Int(Posture.nudgeAfter)) min looking down",
             isOn: Binding(get: { app.posture.enabled }, set: { app.setPosture($0) }))
      if app.posture.enabled {
        row("Head tilt", app.posture.tilt.map { "\(Int($0))°" } ?? "waiting for glasses")
        row("Looking down", String(format: "%.1f min", app.posture.downMinutes))
        row("Motion", app.glasses.motion)
        Button("Calibrate (look straight ahead)") { Task { await app.posture.calibrate() } }
      }
    }
  }

  private var headSwitchSection: some View {
    Section("Mac Spaces") {
      Toggle("Flick head left/right to switch Spaces",
             isOn: Binding(get: { app.headSwitch.enabled }, set: { app.setHeadSwitch($0) }))
      if app.headSwitch.enabled {
        row("Turn speed", app.headSwitch.noGyroscope ? "no gyroscope from glasses"
            : app.headSwitch.turnRate.map { "\(Int($0))°/s (switches past \(Int(HeadSwitch.flick)))" } ?? "waiting for glasses")
        row("Last", app.headSwitch.last)
        row("Motion", app.glasses.motion)
      }
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .top) {
      Text(label).foregroundStyle(.secondary)
      Spacer()
      Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing)
    }
  }
}
