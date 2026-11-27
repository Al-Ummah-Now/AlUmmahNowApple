import AUNCoreBridge
import Foundation

public enum StudioBootstrap {
    /// One per process: iOS reconnects the background upload session by its identifier.
    public static let liveTransfer = TUSTransfer.live()

    /// Fixture runs start from empty preferences, so UI tests never see an earlier test's choices.
    public static func preferences(defaults: UserDefaults = .standard) -> UserDefaults {
        guard defaults.bool(forKey: "AUNUseFixtures") else { return defaults }
        let name = "net.alummahnow.studio.fixtures"
        defaults.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name) ?? defaults
    }

    /// Fixture runs sign in without a browser.
    @MainActor public static func usesFixtures(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "AUNUseFixtures")
    }

    /// The Studio services for this build. `-AUNUseFixtures YES` selects hermetic data for UI tests,
    /// `-AUNFixtureSignedIn YES` starts them signed in, and `-AUNFixtureAccountState invitation|pendingDeletion` starts
    /// the account without a creator tier or with its videos data pending deletion. `-AUNFixtureFeaturesOff upload,analytics`
    /// switches features off. `-AUNFixtureDeleteMode` says how deleting the account goes (also `stepUp` and `wrongAccount`:
    /// a fresh sign-in is asked for first, and comes back as someone else), and `-AUNFixtureDeletionStage erasing` starts
    /// with a deletion that got that far (`unsettled`: with nothing left to ask with).
    public static func services(
        defaults: UserDefaults = .standard, bundle: Bundle = .main
    ) -> StudioServices {
        if defaults.bool(forKey: "AUNUseFixtures") {
            let state = defaults.string(forKey: "AUNFixtureAccountState").flatMap(FixtureStudioService.AccountState.init)
            let off = (defaults.string(forKey: "AUNFixtureFeaturesOff") ?? "").split(separator: ",").map(String.init)
            let termsMode =
                defaults.string(forKey: "AUNFixtureTermsMode").flatMap(FixtureStudioService.TermsMode.init) ?? .accepted
            return .fixtures(
                accountState: state ?? .creator, featuresOff: Set(off), termsMode: termsMode,
                deletion: deletionMode(defaults), deletionRecord: deletionRecord(defaults), accounts: fixtureAccounts(defaults),
                channels: defaults.string(forKey: "AUNFixtureChannels").flatMap(FixtureStudioService.Channels.init) ?? .all)
        }
        let environment = AppEnvironment.fromInfoDictionary(bundle.infoDictionary)
        do {
            let bundleID = bundle.bundleIdentifier ?? "net.alummahnow.studio"
            let accounts = try CoreAccountService.live(environment: environment, bundleID: bundleID)
            let proofs = nativeProofs(environment, bundle)
            var services = StudioServices(
                environment: environment, accounts: accounts,
                studio: NativeStudioService(baseURL: environment.apiBaseURL, accounts: accounts, proofs: proofs),
                transfer: liveTransfer,
                search: CoreSearchService(accounts: accounts, baseURL: environment.apiBaseURL))
            services.deletion = NativeDeletionService(
                apiBaseURL: environment.apiBaseURL, authIssuer: environment.authIssuer, proofs: proofs)
            services.deletionRecords = KeychainDeletionRecords(service: "\(bundleID).deletions")
            let telemetry = CoreTelemetryService.live(
                environment: environment, bundle: bundle, defaults: defaults,
                userAgentPrefix: "AlUmmahNow-Studio-Apple", bufferFilename: "studio-telemetry-buffer.json")
            CrashTelemetryHook.install(service: telemetry)
            services.telemetry = telemetry
            return withMediaEngines(services)
        } catch {
            AUNLog.studio.fault("Studio services could not start: \(error)")
            return StudioServices(
                environment: environment, accounts: FixtureAccountService(),
                studio: NativeStudioService(baseURL: environment.apiBaseURL, accounts: FixtureAccountService()),
                transfer: liveTransfer, search: FixtureSearchService())
        }
    }

    /// App Attest proofs for writes (NAT-REL): iPhone and iPad only, and only once videos admin turns Apple attestation
    /// on. Mac has no App Attest for this app, so it sends none.
    static func nativeProofs(_ environment: AppEnvironment, _ bundle: Bundle) -> (any NativeProofProviding)? {
        #if os(iOS)
            NativeAttestationService(
                baseURL: environment.apiBaseURL, bundleID: bundle.bundleIdentifier ?? "net.alummahnow.studio",
                attest: DeviceAppAttest())
        #else
            nil
        #endif
    }

    /// Core's media engines. The editor runs everywhere; pre-encoding and whisper are desktop features (D10, D11),
    /// and Core ships whisper only in its macOS slice.
    static func withMediaEngines(_ services: StudioServices) -> StudioServices {
        var services = services
        services.edl = CoreEDLEditing()
        #if os(macOS)
            services.renditionPackaging = CoreRenditionPackaging()
            let transcriber = CoreOnDeviceTranscriber()
            services.transcription = transcriber.isAvailable ? transcriber : nil
        #endif
        return services
    }

    // MARK: Fixtures of account deletion

    private static func deletionMode(_ defaults: UserDefaults) -> FixtureDeletionService.Mode {
        defaults.string(forKey: "AUNFixtureDeleteMode").flatMap(FixtureDeletionService.Mode.init) ?? .succeed
    }

    private static func fixtureAccounts(_ defaults: UserDefaults) -> FixtureAccountService {
        let mode = defaults.string(forKey: "AUNFixtureDeleteMode")
        let asksForSignIn = mode == "stepUp" || mode == "wrongAccount"
        return FixtureAccountService(
            signedIn: defaults.bool(forKey: "AUNFixtureSignedIn") ? [FixtureAccountService.creator] : [],
            signedInAt: asksForSignIn ? Date(timeIntervalSinceNow: -3600) : Date(),
            stepUpAccount: mode == "wrongAccount"
                ? StudioAccount(id: "fixture-other", email: "amina.yusuf@example.org", displayName: "Amina Yusuf") : nil)
    }

    private static func deletionRecord(_ defaults: UserDefaults) -> DeletionRecord? {
        guard let stage = defaults.string(forKey: "AUNFixtureDeletionStage").flatMap(DeletionStage.init) else { return nil }
        let account = FixtureAccountService.creator
        return DeletionRecord(
            accountID: account.id, label: account.email ?? account.label, stage: stage,
            receipt: defaults.string(forKey: "AUNFixtureDeleteMode") == "unsettled" ? nil : "fixture-receipt")
    }
}
