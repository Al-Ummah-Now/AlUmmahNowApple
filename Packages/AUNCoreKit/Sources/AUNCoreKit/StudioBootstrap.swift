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
    /// switches features off.
    public static func services(
        defaults: UserDefaults = .standard, bundle: Bundle = .main
    ) -> StudioServices {
        if defaults.bool(forKey: "AUNUseFixtures") {
            let state = defaults.string(forKey: "AUNFixtureAccountState").flatMap(FixtureStudioService.AccountState.init)
            let off = (defaults.string(forKey: "AUNFixtureFeaturesOff") ?? "").split(separator: ",").map(String.init)
            return .fixtures(
                signedIn: defaults.bool(forKey: "AUNFixtureSignedIn"), accountState: state ?? .creator, featuresOff: Set(off))
        }
        let environment = AppEnvironment.fromInfoDictionary(bundle.infoDictionary)
        do {
            let accounts = try CoreAccountService.live(
                environment: environment, bundleID: bundle.bundleIdentifier ?? "net.alummahnow.studio")
            return withMediaEngines(
                StudioServices(
                    environment: environment, accounts: accounts,
                    studio: NativeStudioService(
                        baseURL: environment.apiBaseURL, accounts: accounts, proofs: nativeProofs(environment, bundle)),
                    transfer: liveTransfer,
                    search: CoreSearchService(accounts: accounts, baseURL: environment.apiBaseURL)))
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
}
