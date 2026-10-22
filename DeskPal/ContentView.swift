import SwiftUI

// Three tabs: Talk (the glasses, Talk, what's playing), Skills (everything Desk Pal can do, with the
// switches for the hands-free ones) and Settings (the glasses, "Gigi", and Diagnostics for the log).
enum AppTab: Hashable { case home, skills, settings }

struct ContentView: View {
  let app: AppModel
  @State private var tab = AppTab.home

  var body: some View {
    TabView(selection: $tab) {
      HomeView(app: app, tab: $tab)
        .tabItem { Label("Talk", systemImage: "waveform") }
        .tag(AppTab.home)
      SkillsView(app: app)
        .tabItem { Label("Skills", systemImage: "sparkles") }
        .tag(AppTab.skills)
      SettingsView(app: app)
        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        .tag(AppTab.settings)
    }
    .tint(.pal)
  }
}

// Desk Pal's one colour: Claude's coral (the Pal is Claude's crab). Everything interactive or "yours" uses it;
// status colours (green on, amber connecting, red low battery) keep their usual meanings. A touch lighter
// in Dark Mode so it holds the same weight on black.
extension Color {
  static let pal = Color(UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 0.91, green: 0.56, blue: 0.44, alpha: 1)
      : UIColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
  })
}

// A symbol in coral on a soft coral square: one hue at two strengths, rather than a colour per icon.
struct IconTile: View {
  let symbol: String
  var size: CGFloat = 30

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.45, weight: .medium))
      .foregroundStyle(Color.pal)
      .frame(width: size, height: size)
      .background(Color.pal.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
      .accessibilityHidden(true)
  }
}

// The rounded card used on Home.
struct Card<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }
}
