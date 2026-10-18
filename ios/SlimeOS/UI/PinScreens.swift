import SwiftUI

/// First run: choose the app's PIN, twice.
struct PinSetupScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var first: String?
    @State private var entry = ""
    @State private var mismatch = false

    var body: some View {
        PinLayout(title: first == nil ? "Choose a PIN" : "Enter it again",
                  subtitle: first == nil
                      ? "Six digits. Slime OS asks for it when it opens, so someone else picking up this device can't use your Brains."
                      : "To make sure it's the one you meant.",
                  entry: entry, error: mismatch ? "Those didn't match. Choose a PIN again." : nil,
                  enabled: !model.pinWorking,
                  onDigit: digit, onDelete: { if !entry.isEmpty { entry.removeLast() } },
                  footer: model.changingPin ? AnyView(TertiaryButton(title: "Cancel") { model.changingPin = false }) : nil)
    }

    private func digit(_ d: Character) {
        guard entry.count < AppLock.pinLength else { return }
        entry.append(d)
        mismatch = false
        guard entry.count == AppLock.pinLength else { return }
        let pin = entry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            entry = ""
            if let first {
                if first == pin {
                    model.choosePin(pin)
                } else {
                    self.first = nil
                    mismatch = true
                }
            } else {
                first = pin
            }
        }
    }
}

struct PinUnlockScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var entry = ""
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let waiting = model.pinRetryAt.map { $0 > now } ?? false
        PinLayout(title: "Enter your PIN", subtitle: "Slime OS is locked.",
                  entry: entry, error: waiting ? waitText : model.pinError,
                  enabled: !model.pinWorking && !waiting,
                  onDigit: digit, onDelete: { if !entry.isEmpty { entry.removeLast() } },
                  footer: AnyView(TertiaryButton(title: "Forgot PIN?") { model.modal = .resetApp }))
            .onReceive(timer) { now = $0 }
            .onChange(of: model.pinWorking) { _, working in if !working { entry = "" } }
    }

    private var waitText: String {
        let s = Int((model.pinRetryAt ?? now).timeIntervalSince(now).rounded(.up))
        return s >= 60 ? "Too many tries. Wait \(s / 60) min \(s % 60) s." : "Too many tries. Wait \(s) s."
    }

    private func digit(_ d: Character) {
        guard entry.count < AppLock.pinLength else { return }
        entry.append(d)
        model.pinError = nil
        if entry.count == AppLock.pinLength { model.unlock(entry) }
    }
}

private struct PinLayout: View {
    let title: String
    let subtitle: String
    let entry: String
    let error: String?
    let enabled: Bool
    let onDigit: (Character) -> Void
    let onDelete: () -> Void
    let footer: AnyView?

    var body: some View {
        ZStack {
            SlimeBackground()
            ViewThatFits(in: .vertical) {
                HStack(spacing: 48) { header; pad }.padding(24)
                VStack(spacing: 24) { header; pad }.padding(24)
                ScrollView { VStack(spacing: 24) { header; pad }.padding(24) }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            SlimeMark(size: 46)
            Text(title).font(Slime.display(26, 700)).foregroundStyle(Slime.title)
            Muted(text: subtitle, center: true).frame(maxWidth: 320)
            HStack(spacing: 14) {
                ForEach(0..<AppLock.pinLength, id: \.self) { i in
                    Circle()
                        .fill(i < entry.count ? Slime.teal : Color.clear)
                        .overlay(Circle().stroke(i < entry.count ? Slime.teal : Slime.textDim, lineWidth: 1.5))
                        .frame(width: 13, height: 13)
                }
            }
            .padding(.top, 6)
            Text(error ?? " ").font(Slime.body(14)).foregroundStyle(Slime.error)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
            if let footer { footer }
        }
    }

    private var pad: some View {
        let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]]
        return VStack(spacing: 12) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 18) {
                    ForEach(row, id: \.self) { key in
                        if key.isEmpty {
                            Color.clear.frame(width: 66, height: 66)
                        } else {
                            Button {
                                if key == "⌫" { onDelete() } else { onDigit(Character(key)) }
                            } label: {
                                Text(key).font(Slime.display(key == "⌫" ? 22 : 26, 600)).foregroundStyle(Slime.text)
                                    .frame(width: 66, height: 66)
                                    .background(Slime.surface, in: Circle())
                                    .overlay(Circle().stroke(Slime.border, lineWidth: 1))
                            }
                            .disabled(!enabled)
                            .opacity(enabled ? 1 : 0.4)
                        }
                    }
                }
            }
        }
    }
}
