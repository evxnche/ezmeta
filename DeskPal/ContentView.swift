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
      row("Session", app.glasses.session)
      row("Hey Meta", app.glasses.voice)
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
      if !app.pal.heard.isEmpty { row("You", app.pal.heard) }
      if !app.pal.reply.isEmpty { row("Pal", app.pal.reply) }
      Text("Say \"Hey Meta, start Desk Pal\". Try: \"Note: buy solder\", \"Add call the bank to my tasks\", \"What's on my plan?\", \"Read my articles\".")
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

  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .top) {
      Text(label).foregroundStyle(.secondary)
      Spacer()
      Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing)
    }
  }
}
