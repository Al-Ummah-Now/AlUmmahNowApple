import AUNCoreBridge
import Foundation
import Testing

@testable import AUNCoreKit

@Suite("CoreTelemetryService")
struct CoreTelemetryServiceTests {
    @Test("Fixture runs get the no-op service")
    func fixturesUseNullService() {
        let service = CoreTelemetryService.live(
            environment: AppEnvironment.fromInfoDictionary([:]), userAgentPrefix: "AlUmmahNow-Test", fixtures: true)
        #expect(service is NullTelemetryService)
        #expect(service.consent == .off)
    }

    @Test("The no-op service stays off and only accepts off")
    func nullServiceStaysOff() async {
        let service = NullTelemetryService()
        #expect(service.setConsent(.off))
        #expect(!service.setConsent(.full))
        #expect(service.consent == .off)
        service.reportCrash(kind: "NSRangeException", message: "index 3 beyond bounds", stack: nil)
        service.persist()
        await service.flush()
        #expect(service.consent == .off)
    }

    @Test("Live service starts off unless the person opted in, and follows consent changes")
    func liveConsent() throws {
        let suite = "aun-tel-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = CoreTelemetryService.live(
            environment: AppEnvironment.fromInfoDictionary([:]), defaults: defaults,
            userAgentPrefix: "AlUmmahNow-Test", bufferFilename: "test-\(suite).json")
        // Where the core library cannot load, the no-op service is used and stays off.
        #expect(service.consent == .off)
        guard service is CoreTelemetryService else { return }
        #expect(service.setConsent(.full))
        #expect(service.consent == .full)
        service.reportCrash(kind: "NSInvalidArgumentException", message: "bad", stack: "0 App 0x1")
        #expect(service.setConsent(.off))
        #expect(service.consent == .off)
    }

    @Test("Resolve ingest URL requires HTTPS, strips path/query/fragment, and rejects credentials")
    func resolveIngestURLStrict() {
        #expect(
            CoreTelemetryService.resolveIngestURL("https://videos.api.alummahnow.net/")
                == "https://videos.api.alummahnow.net/api/v1/telemetry/batches")
        #expect(
            CoreTelemetryService.resolveIngestURL("https://videos.api.example/some/path?x=1#frag")
                == "https://videos.api.example/api/v1/telemetry/batches")
        #expect(
            CoreTelemetryService.resolveIngestURL("https://videos.api.example:8443/v2?token=abc#top")
                == "https://videos.api.example:8443/api/v1/telemetry/batches")
        #expect(
            CoreTelemetryService.resolveIngestURL("https://videos.api.example:443/v1")
                == "https://videos.api.example/api/v1/telemetry/batches")
        #expect(
            CoreTelemetryService.resolveIngestURL("https://videos.api.example?x=1")
                == "https://videos.api.example/api/v1/telemetry/batches")
        #expect(CoreTelemetryService.resolveIngestURL("https://user:pass@videos.api.example/path") == nil)
        #expect(CoreTelemetryService.resolveIngestURL("https://user@videos.api.example") == nil)
        #expect(CoreTelemetryService.resolveIngestURL("http://videos.api.alummahnow.net") == nil)
        #expect(CoreTelemetryService.resolveIngestURL("http://127.0.0.1:3086") == nil)
        #expect(CoreTelemetryService.resolveIngestURL("") == nil)
        #expect(CoreTelemetryService.resolveIngestURL(nil as String?) == nil)
        #expect(CoreTelemetryService.resolveIngestURL(nil as URL?) == nil)
    }
}
