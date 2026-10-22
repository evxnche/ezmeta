import MWDATCore
import SwiftUI

struct HomeView: View {
  let app: AppModel
  @Binding var tab: AppTab
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  // Critically damped: things settle without bouncing (bounce is for flicks, and nothing here is flicked).
  private static let settle = Animation.spring(duration: 0.35, bounce: 0)

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 28) {
          if app.glasses.registration == .registered {
            GlassesPill(glasses: app.glasses)
          } else {
            ConnectCard(glasses: app.glasses)
          }
          VStack(spacing: 20) {
            TalkButton(app: app)
            if !app.reader.reading {
              Button { app.startReading() } label: {
                Label("Read My Articles", systemImage: "book")
                  .font(.subheadline.weight(.medium))
                  .padding(.horizontal, 6)
              }
              .buttonStyle(.bordered)
              .buttonBorderShape(.capsule)
              .transition(appear)
            }
          }
          .padding(.vertical, 8)
          if app.reader.reading {
            ReadingCard(reader: app.reader)
              .transition(appear)
          }
          if !app.pal.heard.isEmpty || !app.pal.reply.isEmpty {
            ConversationCard(pal: app.pal)
              .transition(appear)
          }
          SkillsStrip(tab: $tab)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .animation(Self.settle, value: app.reader.reading)
        .animation(Self.settle, value: app.pal.reply)
        .animation(Self.settle, value: app.glasses.registration)
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle("Desk Pal")
    }
  }

  // Nothing appears from nothing: a slight scale with the fade. Reduce Motion keeps just the fade.
  private var appear: AnyTransition {
    reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96))
  }
}

// Not connected yet: what to do, and the button that does it.
private struct ConnectCard: View {
  let glasses: Glasses

  var body: some View {
    Card {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          IconTile(symbol: "eyeglasses", size: 40)
          Text("Connect your glasses").font(.headline)
        }
        Text("Turn on Developer Mode for your glasses in the Meta AI app, then approve Desk Pal there.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Button { glasses.register() } label: {
          Group {
            if glasses.registration == .registering { ProgressView() } else { Text("Connect Glasses") }
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(glasses.registration == .registering)
      }
    }
  }
}

// Connected: one quiet line, like the AirPods status under Now Playing. Colour only where it means
// something: the dot (green on, amber connecting) and a low battery.
private struct GlassesPill: View {
  let glasses: Glasses

  var body: some View {
    HStack(spacing: 8) {
      Circle().fill(state.color).frame(width: 7, height: 7)
      Text(glasses.deviceName ?? "Ray-Ban Meta")
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
      Text(state.text)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      if let battery = glasses.battery {
        HStack(spacing: 3) {
          Image(systemName: Self.batterySymbol(battery))
          Text("\(battery)%").monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(battery <= 20 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }

  private var state: (text: String, color: Color) {
    switch glasses.linkState {
    case .connected:
      switch glasses.worn {
      case true: ("Worn", .green)
      case false: ("Not worn", .green)
      default: ("Connected", .green)
      }
    case .connecting: ("Connecting", .orange)
    default: ("Not nearby", Color(.systemGray3))
    }
  }

  private static func batterySymbol(_ level: Int) -> String {
    switch level {
    case 88...: "battery.100percent"
    case 63..<88: "battery.75percent"
    case 38..<63: "battery.50percent"
    case 13..<38: "battery.25percent"
    default: "battery.0percent"
    }
  }
}

// The big round button: tap to talk, tap again to stop. Shows what Desk Pal is doing.
private struct TalkButton: View {
  let app: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var status: Pal.Status { app.pal.status }
  private var listening: Bool { status == .listening || status == .replying || status == .dictating }
  private var hearsGigi: Bool { app.wakeWord && app.glasses.speech.hasPrefix("Listening") }

  var body: some View {
    VStack(spacing: 16) {
      Button { app.talk() } label: {
        ZStack {
          if listening && !reduceMotion {
            Circle()
              .stroke(Color.pal.opacity(0.35), lineWidth: 6)
              .phaseAnimator([false, true]) { ring, grown in
                ring.scaleEffect(grown ? 1.35 : 1).opacity(grown ? 0 : 1)
              } animation: { grown in grown ? .easeOut(duration: 1.3) : nil }
          }
          Circle()
            .fill(Color.pal)
            .overlay {
              // A faint lit top edge, so it reads as an object rather than a flat disc.
              Circle().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center),
                lineWidth: 1)
            }
            .shadow(color: Color.pal.opacity(0.35), radius: 24, y: 12)
          Image(systemName: symbol)
            .font(.system(size: 52, weight: .medium))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.variableColor.iterative, isActive: status == .speaking)
            .symbolEffect(.pulse, isActive: status == .thinking || listening)
        }
        .frame(width: 176, height: 176)
      }
      .buttonStyle(PressScale())
      // Haptics on the moment it starts and stops listening, in step with the chime.
      .sensoryFeedback(trigger: status) { old, new in
        if old == .ready && new != .ready { return .start }
        if old != .ready && new == .ready { return .stop }
        return nil
      }
      .accessibilityLabel(app.pal.busy ? "Stop" : "Talk to Desk Pal")
      .accessibilityValue(status.rawValue)

      VStack(spacing: 4) {
        Text(app.pal.busy ? status.rawValue : "Tap to talk")
          .font(.title3.weight(.semibold))
          .contentTransition(.opacity)
        Text(hint)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .animation(.spring(duration: 0.3, bounce: 0), value: status)
    }
    .frame(maxWidth: .infinity)
  }

  private var hint: String {
    if app.pal.busy { return "Tap to stop" }
    return hearsGigi ? "Or just say \u{201C}Gigi\u{201D}" : "Or double tap your glasses"
  }

  private var symbol: String {
    switch status {
    case .ready: "waveform"
    case .listening, .replying: "mic.fill"
    case .dictating: "keyboard"
    case .thinking: "ellipsis"
    case .speaking: "speaker.wave.2.fill"
    }
  }
}

private struct PressScale: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.spring(duration: 0.2, bounce: 0), value: configuration.isPressed)
  }
}

// ezRead while it's reading: the article and its controls.
private struct ReadingCard: View {
  let reader: Reader

  var body: some View {
    Card {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          IconTile(symbol: "book.fill", size: 40)
          VStack(alignment: .leading, spacing: 2) {
            Text(reader.title.isEmpty ? "Getting your articles\u{2026}" : reader.title)
              .font(.headline)
              .lineLimit(2)
            if !reader.progress.isEmpty {
              Text(reader.progress).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
          }
        }
        HStack {
          control("backward.end.fill", "Repeat paragraph") { reader.repeatParagraph() }
          Spacer()
          control(reader.paused ? "play.fill" : "pause.fill", reader.paused ? "Resume" : "Pause", large: true) {
            reader.togglePause()
          }
          Spacer()
          control("forward.end.fill", "Next article") { reader.nextArticle() }
          Spacer()
          control("stop.fill", "Stop reading") { reader.stop() }
        }
        .padding(.horizontal, 8)
      }
    }
  }

  private func control(_ symbol: String, _ label: String, large: Bool = false, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(large ? .title : .title3)
        .frame(width: 44, height: 44)
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(PressScale())
    .foregroundStyle(large ? Color.pal : .primary)
    .accessibilityLabel(label)
  }
}

// What you said and what Desk Pal answered, last time.
private struct ConversationCard: View {
  let pal: Pal

  var body: some View {
    Card {
      VStack(alignment: .leading, spacing: 10) {
        Text("Last conversation").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        if !pal.heard.isEmpty { bubble(pal.heard, mine: true) }
        if !pal.reply.isEmpty { bubble(pal.reply, mine: false) }
      }
    }
  }

  private func bubble(_ text: String, mine: Bool) -> some View {
    Text(text)
      .font(.subheadline)
      .foregroundStyle(mine ? .white : .primary)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(mine ? Color.pal : Color(.tertiarySystemFill),
                  in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
      .padding(mine ? .leading : .trailing, 40)
      .textSelection(.enabled)
      .accessibilityLabel((mine ? "You: " : "Desk Pal: ") + text)
  }
}

// A row of everything Desk Pal can do; any of them opens Skills.
private struct SkillsStrip: View {
  @Binding var tab: AppTab

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("What Desk Pal can do").font(.headline)
        Spacer()
        Button("See All") { tab = .skills }.font(.subheadline)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(Skill.all) { skill in
            Button { tab = .skills } label: {
              VStack(alignment: .leading, spacing: 10) {
                IconTile(symbol: skill.symbol, size: 34)
                Text(skill.title)
                  .font(.subheadline.weight(.semibold))
                  .foregroundStyle(.primary)
                  .lineLimit(2, reservesSpace: true)
                  .multilineTextAlignment(.leading)
              }
              .frame(width: 110, alignment: .leading)
              .padding(12)
              .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressScale())
          }
        }
      }
      .scrollClipDisabled()
    }
  }
}
