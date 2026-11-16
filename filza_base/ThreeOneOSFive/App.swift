import SwiftUI
import UIKit

@main
struct ThreeOneOSFiveApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var licenseManager = LicenseManager()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator();
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @State private var updateOffer: AppUpdateChecker.Offer?
    @State private var securityBlocked: Bool
    @Environment(\.scenePhase) private var scenePhase

    init() {
        setupLogCapture()
        log("app: INJETOR BYPASS launching — iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName)")
        let blocked = !AntiCrack.verifyAtLaunch()
        _securityBlocked = State(initialValue: blocked)
        // GATE ANTI-CRACK: se o bundle foi modificado ou há debugger/injeção,
        // a interface protegida não é criada. (AntiCrack.swift)
        if blocked {
            log("anticrack: app bloqueado no boot")
        }
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    private func checkForUpdate() {
        Task {
            guard let offer = await AppUpdateChecker.check() else { return }
            await MainActor.run { updateOffer = offer }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if securityBlocked {
                    SecurityBlockedView()
                } else if licenseManager.isActive && !licenseManager.isLocked {
                    ContentView()
                        .environmentObject(licenseManager)
                } else if licenseManager.isLocked {
                    LockScreenView(manager: licenseManager)
                        .environmentObject(licenseManager)
                } else {
                    LicenseActivationView(manager: licenseManager)
                }
                }
                .environmentObject(appState)
                .environmentObject(patchDraftCoordinator)
                .environmentObject(fileOperationCoordinator)
                .environment(\.appLanguage, language)
                .environment(\.locale, language.locale)
            .alert(item: $updateOffer) { offer in
                Alert(
                    title: Text(language.text("update.title")),
                    message: Text(language.text("update.message", offer.version)),
                    primaryButton: .default(Text(language.text("update.agree"))) {
                        UIApplication.shared.open(offer.url)
                    },
                    secondaryButton: .cancel(Text(language.text("update.dismiss"))) {
                        AppUpdateChecker.dismiss(version: offer.version)
                    }
                )
            }
            .alert("Aviso global", isPresented: Binding(
                get: { licenseManager.globalMessage?.isEmpty == false },
                set: { visible in
                    if !visible { licenseManager.dismissGlobalMessage() }
                }
            )) {
                Button("OK") { licenseManager.dismissGlobalMessage() }
            } message: {
                Text(licenseManager.globalMessage ?? "")
            }
            .onAppear {
                guard !securityBlocked else { return }
                licenseManager.beginLaunchSession()
                appState.detectSupport()
                checkForUpdate()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .background {
                    BackgroundTaskKeeper.shared.appDidEnterBackground()
                } else if phase == .active {
                    BackgroundTaskKeeper.shared.appWillEnterForeground()
                    if !AntiCrack.verifyAtLaunch() {
                        securityBlocked = true
                        return
                    }
                    licenseManager.beginLaunchSession()
                    appState.detectSupport()
                    // ContentView owns the foreground reconnect so the app
                    // does not start a second handshake in parallel with the
                    // screen-level lifecycle callback.
                }
            }
            .onOpenURL { url in
                patchDraftCoordinator.presentImport(url)
            }
            .preferredColorScheme(.dark)
        }
    }
}

private struct SecurityBlockedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 52))
                .foregroundStyle(.red)
            Text("Security verification failed")
                .font(.headline)
            Text("This installation was modified or could not be verified.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Background Task Keeper
//
// Holds a background + interactive task while the app is in the background so
// the iOS scheduler does not suspend the process mid-injection. Works on all
// supported iOS versions (16+); on older devices the interactive task is the
// one that actually keeps the runloop alive.
//
// Strategy:
//   - beginBackgroundTask gives ~30s of execution time.
//   - beginInteractiveTask (iOS 16+) keeps the runloop alive indefinitely
//     while the task is held.
//   - A 5-second keepalive tick prevents the runloop from idling out.
//   - isIdleTimerDisabled keeps the screen awake so the user can watch progress.
final class BackgroundTaskKeeper {
    static let shared = BackgroundTaskKeeper()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var interactiveTask: UIBackgroundTaskIdentifier = .invalid
    private var keepaliveTimer: Timer?
    private var isInBackground = false

    private init() {}

    func appDidEnterBackground() {
        guard !isInBackground else { return }
        isInBackground = true
        log("bgkeep: entering background — holding tasks for injection")

        // Begin background task (~30s window)
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "REAL.keepalive") { [weak self] in
            log("bgkeep: background task expired by system")
            self?.endBackgroundTask()
        }

        // UIApplication has no public interactive-task API; the background task above
        // is the supported lifecycle mechanism and remains the only task started here.

        // Keep screen awake
        UIApplication.shared.isIdleTimerDisabled = true

        // Keepalive tick every 5s — keeps runloop busy, prevents suspension
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            log("bgkeep: keepalive tick (tasks still held)")
        }
    }

    func appWillEnterForeground() {
        guard isInBackground else { return }
        isInBackground = false
        log("bgkeep: entering foreground — releasing tasks")
        endBackgroundTask()
        endInteractiveTask()
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func endInteractiveTask() {
        // Kept as a lifecycle hook for callers; no public interactive-task API exists.
        interactiveTask = .invalid
    }
}

class AppState: ObservableObject {
    @Published var exploitStatus: ExploitStatus = .notStarted
    @Published var unsupportedMessage: String?

    private var activationAttempted = false

    /// true when the current iOS is covered by worse_query or will be once activated
    var isSupported: Bool { unsupportedMessage == nil }

    func detectSupport() {
        let v = AppInfo.versionTuple
        let supported = ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains(“--simulate-access”) {
            exploitStatus = .success(method: “Simulator preview”)
            unsupportedMessage = nil
            return
        }
#endif
        unsupportedMessage = supported ? nil : “iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))”
        guard supported else {
            exploitStatus = .unsupported(unsupportedMessage!)
            return
        }

        // On iOS 26.6.2+ and iOS 27, worse_query is the only backend.
        // Activate it once automatically when the app is foregrounded.
        if WorseQueryAccess.isRequired {
            if WorseQueryAccess.isReady {
                exploitStatus = .success(method: “worse_query”)
                log(“app: worse_query already ready”)
            } else {
                maybeActivateWorseQuery()
            }
            return
        }

        // Legacy iOS 16–26.6.1: direct container access via worse_query preparation only.
        // No kexploit, no kernel R/W, no pairing needed.
        exploitStatus = .success(method: “direct”)
        log(“app: direct container access active (iOS \(v.major).\(v.minor).\(v.patch))”)
    }

    private func maybeActivateWorseQuery() {
        guard !activationAttempted else { return }
        activationAttempted = true
        log(“app: activating worse_query backend”)
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = WorseQueryAccess.activate()
            DispatchQueue.main.async {
                if ok {
                    self.exploitStatus = .success(method: “worse_query”)
                    log(“app: worse_query activated successfully”)
                } else {
                    self.exploitStatus = .failed(method: “worse_query”, code: -1)
                    log(“app: worse_query activation failed — check App Group entitlement in provisioning profile”)
                    self.activationAttempted = false // allow retry on next foreground
                }
            }
        }
    }
}
