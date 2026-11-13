import Foundation

/// The only network session the Admin app uses (owner: "never cache or download on phone or native app ever, only
/// encrypted stream"). Ephemeral (no cookies, credentials or cache on disk), a URL cache of zero bytes, every request
/// refetched, TLS only. Nothing it loads is ever written to disk; `PrivateMediaSessionTests` fails if it is.
public enum PrivateMediaSession {
    public static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 0, directory: nil)
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        return config
    }

    /// The shared private session (one per process).
    public static let shared = make()

    /// A new private session; tests pass protocol classes in `configure`.
    public static func make(configure: (URLSessionConfiguration) -> Void = { _ in }) -> URLSession {
        let config = configuration()
        configure(config)
        return URLSession(configuration: config, delegate: NoStoreDelegate(), delegateQueue: nil)
    }

    /// A request that may never be stored by any cache on the way.
    public static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }
}

/// Never caches a response handed to it (a second guard if a protocol class or proxy offers one).
final class NoStoreDelegate: NSObject, URLSessionDataDelegate, Sendable {
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
    ) {
        completionHandler(nil)
    }
}
