import Foundation
import SwiftUI
import UIKit

/// The app's screens and flows, as android/.../MainActivity.kt: PIN, pairing,
/// Slime ID, the Brain list, waking a Brain and its session.
@MainActor
final class AppModel: ObservableObject {
    enum Screen {
        case welcome
        case pair(hint: String?)
        /// Something in progress: ring, title, `stage`.
        case working(title: String)
        case slimeIdEntry(SlimeId.DeviceCode)
        case addBrain
        /// Who signs in on `brain`.
        case credentials(SavedBrain)
        case picker
        case connecting(name: String)
        case reconnecting(name: String, attempt: Int)
        case session
        case error(title: String, body: String?, detail: String?, retry: Bool, reenter: Bool)
    }

    enum Modal: Identifiable {
        case removeBrain(SavedBrain)
        case saveToSlimeId(SavedBrain)
        case forgetPairing
        case resetApp
        var id: String {
            switch self {
            case let .removeBrain(b): return "remove-\(b.id)"
            case let .saveToSlimeId(b): return "save-\(b.id)"
            case .forgetPairing: return "forget"
            case .resetApp: return "reset"
            }
        }
    }

    struct PickerItem: Identifiable {
        let id: String
        let name: String
        let host: String
        let remote: Bool
        let status: BrainPower.Status?
        let lastConnected: Date?
        let action: () -> Void
        let remove: (() -> Void)?
    }

    @Published var screen: Screen = .welcome
    @Published var stage = ""
    @Published var modal: Modal?
    @Published var notice: String?
    @Published var settingsShown = false
    /// The slimeos.com demo desktop, full screen (Session/DemoBrainScreen.swift).
    @Published var demoBrainShown = false

    // PIN
    @Published private(set) var pinSet = AppLock.isSet
    @Published private(set) var locked = AppLock.isSet
    @Published private(set) var pinWorking = false
    @Published var pinError: String?
    @Published private(set) var pinRetryAt: Date?
    @Published var changingPin = false

    @Published private(set) var brains = Store.brains
    @Published private(set) var remoteBrains: [SlimeId.RemoteBrain] = []
    @Published private(set) var brainStatus: [String: BrainPower.Status] = [:]
    @Published private(set) var slimeIdEmail: String?
    @Published private(set) var session: RdpSession?
    @Published private(set) var hubPingMs: Int?

    let tunnel = TunnelController()

    private var sessionBrain: SavedBrain?
    private var sessionTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var slimeIdTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var pendingBookmark: SlimeId.RemoteBrain?
    private var userClosed = false
    private var quickReconnects = 0
    private var backgroundedAt: Date?
    private static let lockAfterBackground: TimeInterval = 5 * 60
    private static let minSession: TimeInterval = 10
    private static let maxQuickReconnects = 3

    init() {
        if let s = Store.slimeId { slimeIdEmail = Self.accountLabel(s) }
        pinRetryAt = AppLock.retryAt
        showHome()
        refreshRemoteBrains()
        startPings()
        // Swiped away from the app switcher: iOS skips .background and the
        // extension would keep the VPN on (it also stops by itself, see
        // TunnelController's heartbeat).
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tunnel.stop() }
        }
    }

    // MARK: - Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            backgroundedAt = Date()
            // iOS suspends the app: the session can't live on. Keep its last
            // picture and reconnect when the app comes back.
            if session != nil, let brain = sessionBrain {
                let picture = session?.snapshot()
                endSessionQuietly()
                pendingResume = (brain, picture)
            }
            // The tunnel is only on while Slime OS is in use (as on Android).
            tunnel.stop()
        case .active:
            if let at = backgroundedAt, pinSet, Date().timeIntervalSince(at) >= Self.lockAfterBackground {
                lock()
            }
            backgroundedAt = nil
            if tunnel.isPaired {
                Task {
                    _ = await tunnel.ensureUp()
                    refreshBrainStatus()
                }
            }
            if let (brain, picture) = pendingResume {
                pendingResume = nil
                if !locked { resume(brain, picture: picture) } else { resumeAfterUnlock = (brain, picture) }
            }
            refreshRemoteBrains()
        default:
            break
        }
    }

    private var pendingResume: (SavedBrain, CGImage?)?
    private var resumeAfterUnlock: (SavedBrain, CGImage?)?

    private func resume(_ brain: SavedBrain, picture: CGImage?) {
        screen = .reconnecting(name: brain.name, attempt: 1)
        doConnect(brain, picture: picture, reconnecting: true)
    }

    // MARK: - PIN

    func lock() {
        locked = true
        settingsShown = false
        modal = nil
        pinError = nil
        pinRetryAt = AppLock.retryAt
    }

    func choosePin(_ pin: String) {
        pinWorking = true
        Task.detached {
            AppLock.set(pin)
            await MainActor.run {
                self.pinWorking = false
                self.pinSet = true
                self.changingPin = false
                self.locked = false
            }
        }
    }

    func unlock(_ pin: String) {
        pinWorking = true
        Task.detached {
            let result = AppLock.check(pin)
            await MainActor.run {
                self.pinWorking = false
                switch result {
                case .ok:
                    self.locked = false
                    self.pinError = nil
                    self.pinRetryAt = nil
                    if let (brain, picture) = self.resumeAfterUnlock {
                        self.resumeAfterUnlock = nil
                        self.resume(brain, picture: picture)
                    }
                case let .wrong(tries):
                    self.pinError = tries <= 2
                        ? "Wrong PIN. \(tries) more \(tries == 1 ? "try" : "tries") before a wait."
                        : "Wrong PIN."
                case let .wait(until):
                    self.pinError = nil
                    self.pinRetryAt = until
                }
            }
        }
    }

    /// "Forgot PIN?": back to a fresh install.
    func resetApp() {
        modal = nil
        endSessionQuietly()
        Task { await tunnel.forget() }
        signOutSlimeId()
        Store.wipe()
        AppLock.clear()
        brains = []
        brainStatus = [:]
        pinSet = false
        locked = false
        pinError = nil
        pinRetryAt = nil
        showHome()
    }

    // MARK: - Navigation

    func showHome() {
        pendingBookmark = nil
        screen = (brains.isEmpty && unsavedRemoteBrains.isEmpty) ? .welcome : .picker
        if case .picker = screen { refreshBrainStatus() }
    }

    func addBrain() {
        screen = tunnel.isPaired ? .addBrain : .pair(hint: nil)
    }

    /// Add a Brain -> who signs in, offering to save it to the Slime ID first.
    func brainAdded(name: String, host: String, port: Int) {
        let brain = SavedBrain(name: name.isEmpty ? "My Brain" : name, host: host, port: port)
        screen = .credentials(brain)
        if slimeIdEmail != nil, !remoteBrains.contains(where: { brain.sameAddress($0.host, $0.port) }) {
            modal = .saveToSlimeId(brain)
        }
    }

    func credentialsEntered(_ brain: SavedBrain, username: String, password: String) {
        var b = brain
        b.username = username
        b.password = password
        save(b)
        connect(b)
    }

    func askRemove(_ brain: SavedBrain) { modal = .removeBrain(brain) }

    func remove(_ brain: SavedBrain) {
        modal = nil
        Store.remove(brain.id)
        brains = Store.brains
        showHome()
    }

    private func save(_ brain: SavedBrain) {
        Store.put(brain)
        brains = Store.brains
    }

    var unsavedRemoteBrains: [SlimeId.RemoteBrain] {
        remoteBrains.filter { r in !brains.contains { $0.sameAddress(r.host, r.port) } }
    }

    var pickerItems: [PickerItem] {
        brains.map { b in
            PickerItem(id: b.id, name: b.name, host: b.host, remote: false, status: brainStatus[b.id],
                       lastConnected: b.lastConnected, action: { [weak self] in self?.connect(b) },
                       remove: { [weak self] in self?.askRemove(b) })
        } + unsavedRemoteBrains.map { r in
            PickerItem(id: "remote:\(r.id)", name: r.name, host: r.host, remote: true, status: nil,
                       lastConnected: nil, action: { [weak self] in self?.connectBookmark(r) }, remove: nil)
        }
    }

    /// The picker's Asleep/Offline badges, probed in parallel.
    func refreshBrainStatus() {
        let list = brains
        guard !list.isEmpty, tunnel.status == .connected else { return }
        Task {
            var result: [String: BrainPower.Status] = [:]
            await withTaskGroup(of: (String, BrainPower.Status).self) { group in
                for b in list { group.addTask { (b.id, await BrainPower.status(b.host, b.port)) } }
                for await (id, status) in group { result[id] = status }
            }
            brainStatus = result
        }
    }

    private func startPings() {
        pingTask = Task {
            while !Task.isCancelled {
                hubPingMs = tunnel.status == .connected ? await BrainPower.pingHubMs() : nil
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    // MARK: - Pairing

    func pair(host: String, code: String) {
        screen = .working(title: "Pairing")
        stage = "Fetching your Brain's configuration…"
        Task {
            await tunnel.pair(enrollmentHost: host, code: code)
            if let error = tunnel.lastError {
                screen = .error(title: "Couldn't pair.", body: error, detail: nil, retry: false, reenter: false)
                return
            }
            stage = "Opening the secure tunnel…"
            guard await tunnel.ensureUp() else {
                screen = .error(title: "The secure tunnel didn't open.",
                                body: "Check the connection and try again.", detail: tunnel.lastError,
                                retry: false, reenter: false)
                return
            }
            if let r = pendingBookmark {
                probeBookmark(r)
            } else {
                screen = .addBrain
            }
        }
    }

    func forgetPairing() {
        modal = nil
        endSessionQuietly()
        Task { await tunnel.forget() }
        brainStatus = [:]
        showHome()
    }

    // MARK: - Slime ID

    private static func accountLabel(_ s: SlimeIdSession) -> String {
        !s.email.isEmpty ? s.email : (!s.name.isEmpty ? s.name : "your Slime ID")
    }

    func startSlimeIdSignIn() {
        slimeIdTask?.cancel()
        screen = .working(title: "Slime ID")
        stage = "Preparing sign-in…"
        slimeIdTask = Task {
            let code: SlimeId.DeviceCode
            do {
                code = try await SlimeId.start()
            } catch {
                screen = .error(title: "Couldn't reach Slime ID right now.", body: nil,
                                detail: error.localizedDescription, retry: false, reenter: false)
                return
            }
            screen = .slimeIdEntry(code)
            let deadline = Date().addingTimeInterval(code.expiresIn)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(code.interval * 1_000_000_000))
                if Task.isCancelled { return }
                switch await SlimeId.poll(code.deviceCode) {
                case let .approved(session):
                    Store.slimeId = session
                    slimeIdEmail = Self.accountLabel(session)
                    showHome()
                    refreshRemoteBrains()
                    return
                case .expired:
                    break
                case .pending:
                    continue
                }
                break
            }
            screen = .error(title: "That sign-in link expired.", body: nil, detail: nil, retry: false, reenter: false)
        }
    }

    func cancelSlimeIdSignIn() {
        slimeIdTask?.cancel()
        slimeIdTask = nil
        showHome()
    }

    func signOutSlimeId() {
        let token = Store.slimeId?.token
        Store.slimeId = nil
        slimeIdEmail = nil
        remoteBrains = []
        if let token { Task { await SlimeId.logout(token) } }
        if case .picker = screen { showHome() } else if case .welcome = screen { showHome() }
    }

    func refreshRemoteBrains() {
        guard let token = Store.slimeId?.token else {
            remoteBrains = []
            return
        }
        Task {
            guard let list = await SlimeId.brains(token) else { return }
            remoteBrains = list
            linkSavedBrains(list)
            if case .welcome = screen, !list.isEmpty { showHome() }
        }
    }

    /// A Brain saved here that's also on the account remembers its Slime ID id
    /// and kind, so a paid one can fetch its Windows sign-in.
    private func linkSavedBrains(_ list: [SlimeId.RemoteBrain]) {
        var changed = false
        let updated = brains.map { b -> SavedBrain in
            guard let r = list.first(where: { b.sameAddress($0.host, $0.port) }),
                  b.slimeIdBrainId != r.id || b.kind != r.kind else { return b }
            changed = true
            var c = b
            c.slimeIdBrainId = r.id
            c.kind = r.kind
            return c
        }
        if changed {
            Store.brains = updated
            brains = updated
        }
    }

    func saveToSlimeId(_ brain: SavedBrain) {
        modal = nil
        guard let token = Store.slimeId?.token else { return }
        Task {
            if await SlimeId.saveBrain(token, name: brain.name, host: brain.host, port: brain.port) {
                refreshRemoteBrains()
            }
        }
    }

    private func signsInWithSlimeId(_ brain: SavedBrain) -> Bool {
        brain.kind == "paid" && brain.slimeIdBrainId != nil && Store.slimeId != nil
    }

    /// A tap on a Slime ID card. Slime ID never holds the WireGuard key, but
    /// this device's tunnel may already reach the Brain: then it's saved here
    /// and connected. Only a Brain that isn't reachable asks for a pairing code.
    private func connectBookmark(_ r: SlimeId.RemoteBrain) {
        notice = nil
        guard tunnel.isPaired else {
            askPairing(for: r)
            return
        }
        screen = .connecting(name: r.name)
        stage = "Opening the secure tunnel…"
        Task {
            guard await tunnel.ensureUp() else {
                screen = .error(title: "The secure tunnel didn't open.", body: "Check the connection and try again.",
                                detail: nil, retry: false, reenter: false)
                return
            }
            probeBookmark(r)
        }
    }

    private func askPairing(for r: SlimeId.RemoteBrain) {
        pendingBookmark = r
        screen = .pair(hint: "Reconnecting to “\(r.name)” (\(r.host)): enter a fresh pairing code from its enroll screen.")
    }

    private func probeBookmark(_ r: SlimeId.RemoteBrain) {
        pendingBookmark = r
        screen = .connecting(name: r.name)
        stage = "Looking for \(r.name)…"
        Task {
            let status = await BrainPower.status(r.host, r.port)
            if status == .offline {
                askPairing(for: r)
                return
            }
            pendingBookmark = nil
            let brain = SavedBrain(name: r.name, host: r.host, port: r.port, kind: r.kind, slimeIdBrainId: r.id)
            if status == .notAllowed {
                save(brain)
                screen = .error(title: "“\(r.name)” is asleep.",
                                body: "This device isn't allowed to wake it yet. Wake it from another device, then try again.",
                                detail: "Hub refused /status for \(r.host) (403)", retry: true, reenter: false)
                return
            }
            if signsInWithSlimeId(brain) {
                save(brain)
                connect(brain)
            } else {
                screen = .credentials(brain)
            }
        }
    }

    // MARK: - Connecting

    func connect(_ brain: SavedBrain) {
        notice = nil
        quickReconnects = 0
        if brain.password.isEmpty && !signsInWithSlimeId(brain) {
            screen = .credentials(brain)
            return
        }
        guard tunnel.isPaired else {
            screen = .pair(hint: nil)
            return
        }
        screen = .connecting(name: brain.name)
        doConnect(brain, picture: nil, reconnecting: false)
    }

    func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        endSessionQuietly()
        showHome()
    }

    /// The error screen's Try again: the Brain it was about.
    func retry() {
        if let brain = sessionBrain ?? brains.first(where: { $0.lastConnected != nil }) {
            connect(Store.brains.first { $0.id == brain.id } ?? brain)
        } else {
            showHome()
        }
    }

    func reenterPassword() {
        guard let brain = sessionBrain else { return showHome() }
        var b = brain
        b.password = ""
        save(b)
        screen = .credentials(b)
    }

    private func doConnect(_ target: SavedBrain, picture: CGImage?, reconnecting: Bool) {
        var brain = target
        brain.lastConnected = Date()
        save(brain)
        sessionBrain = brain
        connectTask?.cancel()
        connectTask = Task {
            if !reconnecting { stage = "Opening the secure tunnel…" }
            guard await tunnel.ensureUp() else {
                screen = .error(title: "The secure tunnel didn't open.",
                                body: "Check this device's internet connection and try again.",
                                detail: nil, retry: true, reenter: false)
                return
            }
            // A password saved here wins; a paid Brain without one gets it from
            // Slime ID, fresh before every connect and never stored.
            var username = brain.username
            var password = brain.password
            if password.isEmpty {
                var credential: (username: String, password: String)?
                if let token = Store.slimeId?.token, let id = brain.slimeIdBrainId, brain.kind == "paid" {
                    if !reconnecting { stage = "Getting your sign-in from Slime ID…" }
                    credential = await SlimeId.credential(token, brainId: id)
                }
                guard let credential else {
                    screen = .credentials(brain)
                    return
                }
                username = credential.username.isEmpty ? brain.username : credential.username
                password = credential.password
            }
            if Task.isCancelled { return }
            if !reconnecting { stage = "Waking up your Brain…" }
            let awake = await waitForBrainAwake(brain.host, brain.port)
            if Task.isCancelled { return }
            if awake == .no {
                screen = .error(title: "\(brain.name) didn't wake up.", body: "Try again in a moment.",
                                detail: "The hub couldn't start it, or it took longer than 8 minutes.",
                                retry: true, reenter: false)
                return
            }
            if awake == .yes && !reconnecting { stage = "Connecting…" }
            startSession(brain, username: username, password: password, picture: picture)
        }
    }

    private enum Awake { case yes, no, unknown }

    /// connect.sh's wake_brain(): keep asking the hub while waiting for the RDP
    /// port; "running" isn't enough (Windows listens later).
    private func waitForBrainAwake(_ host: String, _ port: Int) async -> Awake {
        let started = Date()
        let deadline = started.addingTimeInterval(8 * 60)
        var sawRunning = false
        while Date() < deadline, !Task.isCancelled {
            switch await BrainPower.wake(host) {
            case .ready:
                if await BrainPower.rdpListening(host, port) { return .yes }
                sawRunning = true
                stage = "Brain is up. Starting the desktop…"
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            case .notAllowed:
                stage = "This device isn't allowed to wake the Brain. Connecting anyway; if it's asleep, wake it from another device."
                return .unknown
            case .failed:
                return .no
            case .restarting:
                stage = "Restarting your Brain… (about 2 minutes)"
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            case .cleaning:
                stage = "Finishing your last session…"
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            case .starting, .error:
                let s = Int(Date().timeIntervalSince(started))
                stage = String(format: "Waking up your Brain… This usually takes 1–2 minutes (%d:%02d)", s / 60, s % 60)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        return sawRunning ? .yes : .no
    }

    private func startSession(_ brain: SavedBrain, username: String, password: String, picture: CGImage?) {
        endSessionQuietly()
        let s = RdpSession(initialPicture: picture)
        var user = username
        var domain = ""
        if let slash = username.firstIndex(of: "\\") {
            domain = String(username[..<slash])
            user = String(username[username.index(after: slash)...])
        }
        let (w, h) = Self.desktopSize()
        s.connect(host: brain.host, port: UInt16(clamping: brain.port), username: user, password: password,
                  domain: domain, width: w, height: h)
        session = s
        userClosed = false
        let started = Date()
        sessionTask = Task { [weak self, weak s] in
            guard let s else { return }
            var wasConnected = false
            for await state in s.$state.values {
                guard let self else { return }
                switch state {
                case .connected, .reconnecting:
                    if !wasConnected {
                        wasConnected = true
                        self.screen = .session
                    }
                case let .ended(error, info):
                    self.sessionEnded(brain, error: error, errorInfo: info, wasConnected: wasConnected,
                                      lasted: Date().timeIntervalSince(started), picture: s.snapshot())
                    return
                default:
                    break
                }
            }
        }
        if picture != nil { screen = .session }
    }

    /// The session's close button.
    func closeSession() {
        userClosed = true
        session?.disconnect()
    }

    private func endSessionQuietly() {
        sessionTask?.cancel()
        sessionTask = nil
        session?.disconnect()
        session = nil
    }

    private func sessionEnded(_ brain: SavedBrain, error: UInt32, errorInfo: UInt32, wasConnected: Bool,
                              lasted: TimeInterval, picture: CGImage?) {
        sessionTask = nil
        session = nil
        // The user's close, or the server's logoff / disconnect-by-user: clean.
        // Only then does the hub log off the disconnected session (#17).
        if userClosed || [2, 11, 12].contains(errorInfo) {
            quickReconnects = 0
            BrainPower.notifySessionEnded(brain.host)
            showHome()
            return
        }
        if errorInfo == 5 { // ERRINFO_DISCONNECTED_BY_OTHERCONNECTION
            notice = "Your session moved to another device."
            showHome()
            return
        }
        let quick = lasted < Self.minSession
        let authOrCert = error == SL_ERROR_CERTIFICATE_CHANGED || [0x0009, 0x0014, 0x0015, 0x0018].contains(error & 0xFFFF)
        if wasConnected, errorInfo == 0, !authOrCert, !quick || quickReconnects < Self.maxQuickReconnects {
            if quick { quickReconnects += 1 }
            screen = .reconnecting(name: brain.name, attempt: quickReconnects + 1)
            stage = ""
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if case .reconnecting = screen { doConnect(brain, picture: picture, reconnecting: true) }
            }
            return
        }
        quickReconnects = 0
        if errorInfo == 1 {
            screen = .error(title: "\(brain.name) closed the connection.",
                            body: "Maybe it was opened on another device. Your session is kept; connect again when ready.",
                            detail: "ERRINFO 1 (RPC_INITIATED_DISCONNECT)", retry: true, reenter: false)
            return
        }
        let message = RdpSession.describe(error: error, errorInfo: errorInfo) ?? "The connection ended."
        let auth = [0x0009, 0x0014, 0x0015].contains(error & 0xFFFF)
        screen = .error(title: wasConnected ? "The connection dropped." : "Couldn't connect to \(brain.name).",
                        body: message, detail: String(format: "error 0x%08X, info %u", error, errorInfo),
                        retry: true, reenter: auth && !signsInWithSlimeId(brain))
    }

    /// The Brain's desktop size: the window's shape, landscape on a phone, at
    /// about two pixels per point but no wider than 1920. Width a multiple of 4.
    static func desktopSize() -> (UInt32, UInt32) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var size = scene?.coordinateSpace.bounds.size ?? CGSize(width: 1280, height: 800)
        if UIDevice.current.userInterfaceIdiom == .phone && size.height > size.width {
            size = CGSize(width: size.height, height: size.width)
        }
        let scale = min(2, 1920 / max(size.width, size.height))
        let w = UInt32(size.width * scale) & ~3
        let h = UInt32(size.height * scale) & ~1
        return (max(w, 640), max(h, 480))
    }
}
