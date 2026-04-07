import SwiftUI
import Combine

enum SoundPack: String, CaseIterable, Identifiable {
    case cherryBlue = "cherry_blue"
    case typewriter = "typewriter"
    case thock = "thock"
    case bucklingSpring = "buckling_spring"
    case topre = "topre"
    case boxNavy = "box_navy"
    case alpsBlue = "alps_blue"
    case cherryRed = "cherry_red"
    case membrane = "membrane"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cherryBlue: "Cherry Blue"
        case .typewriter: "Typewriter"
        case .thock: "Thock"
        case .bucklingSpring: "Buckling Spring"
        case .topre: "Topre"
        case .boxNavy: "Box Navy"
        case .alpsBlue: "Alps Blue"
        case .cherryRed: "Cherry Red"
        case .membrane: "Membrane"
        }
    }

    var subtitle: String {
        switch self {
        case .cherryBlue: "Clicky"
        case .typewriter: "Mechanical"
        case .thock: "Deep linear"
        case .bucklingSpring: "IBM Model M"
        case .topre: "Quiet luxury"
        case .boxNavy: "Thick click"
        case .alpsBlue: "Vintage tactile"
        case .cherryRed: "Smooth linear"
        case .membrane: "Classic mushy"
        }
    }
}

@main
struct ClackApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(state)
        } label: {
            Image(systemName: state.isEnabled ? "keyboard.fill" : "keyboard")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Clack")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: $state.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if !state.hasAccessibility {
                accessibilityWarning
            }

            Divider()

            Text("Sound")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    soundRow(.cherryBlue)
                    soundRow(.cherryRed)
                    soundRow(.thock)
                    soundRow(.boxNavy)
                    soundRow(.alpsBlue)
                    soundRow(.topre)
                    soundRow(.bucklingSpring)
                    soundRow(.typewriter)
                    soundRow(.membrane)
                }
            }
            .frame(maxHeight: 250)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Slider(value: $state.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Divider()

            Button("Quit Clack") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 250)
    }

    private func soundRow(_ pack: SoundPack) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(pack.displayName)
                    .font(.system(size: 13))
                Text(pack.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if pack == state.selectedPack {
                Image(systemName: "checkmark")
                    .foregroundStyle(.blue)
                    .font(.system(size: 12))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { state.selectedPack = pack }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(pack == state.selectedPack ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(6)
    }

    private var accessibilityWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Accessibility access needed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Button("Open System Settings") {
                state.requestAccessibility()
            }
            .font(.caption)
        }
        .padding(8)
        .background(.orange.opacity(0.1))
        .cornerRadius(8)
    }
}

class AppState: ObservableObject {
    @Published var isEnabled: Bool
    @Published var selectedPack: SoundPack
    @Published var volume: Double
    @Published var hasAccessibility = false

    let soundEngine = SoundEngine()
    let keyboardMonitor = KeyboardMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var accessibilityTimer: Timer?

    init() {
        let d = UserDefaults.standard
        self.isEnabled = d.object(forKey: "clack.enabled") as? Bool ?? true
        self.selectedPack = SoundPack(rawValue: d.string(forKey: "clack.pack") ?? "") ?? .cherryBlue
        self.volume = d.object(forKey: "clack.volume") as? Double ?? 0.7

        soundEngine.currentPack = selectedPack
        soundEngine.volume = Float(volume)

        keyboardMonitor.onKeyEvent = { [weak self] keyCode, isDown in
            guard let self else { return }
            if isDown {
                self.soundEngine.playKeyDown(keyCode: keyCode)
            } else {
                self.soundEngine.playKeyUp(keyCode: keyCode)
            }
        }

        $isEnabled.dropFirst().sink { [weak self] enabled in
            UserDefaults.standard.set(enabled, forKey: "clack.enabled")
            self?.updateMonitoring()
        }.store(in: &cancellables)

        $selectedPack.dropFirst().sink { [weak self] pack in
            UserDefaults.standard.set(pack.rawValue, forKey: "clack.pack")
            self?.soundEngine.currentPack = pack
        }.store(in: &cancellables)

        $volume.dropFirst().sink { [weak self] vol in
            UserDefaults.standard.set(vol, forKey: "clack.volume")
            self?.soundEngine.volume = Float(vol)
        }.store(in: &cancellables)

        hasAccessibility = AXIsProcessTrusted()
        if isEnabled && hasAccessibility {
            keyboardMonitor.start()
        }

        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            if trusted != self.hasAccessibility {
                DispatchQueue.main.async {
                    self.hasAccessibility = trusted
                    if trusted && self.isEnabled {
                        self.keyboardMonitor.start()
                    }
                }
            }
        }
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func updateMonitoring() {
        if isEnabled && hasAccessibility {
            keyboardMonitor.start()
        } else {
            keyboardMonitor.stop()
        }
    }
}
