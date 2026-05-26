import Foundation

final class SubscriptionPrefetcher {
    static let userAgent = "ClashforWindows/0.20.39"

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        self.session = URLSession(configuration: configuration)
    }

    /// Downloads a subscription URL to a local cache file using a Clash-compatible UA.
    /// Many airport providers gate behind a WAF that rejects `subconverter` and similar
    /// engine UAs but happily serves Clash/Mihomo clients. Fetching here, then handing
    /// the engine a local file path, sidesteps that and also lets the engine see the
    /// richer Clash YAML many providers return only to Clash UAs.
    func prefetch(urlString: String, sourceID: UUID) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw SubscriptionPrefetchError.invalidURL
        }

        try AppPaths.ensureDirectories()
        let destination = AppPaths.subscriptionCacheDirectory
            .appendingPathComponent("\(sourceID.uuidString).sub")

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw SubscriptionPrefetchError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw SubscriptionPrefetchError.httpError(http.statusCode)
        }
        guard !data.isEmpty else {
            throw SubscriptionPrefetchError.emptyBody
        }

        try data.write(to: destination, options: .atomic)
        return destination.path
    }
}

enum SubscriptionPrefetchError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case emptyBody

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid subscription URL."
        case .invalidResponse:
            return "Subscription server returned an invalid response."
        case .httpError(let code):
            return "Subscription server returned HTTP \(code)."
        case .emptyBody:
            return "Subscription server returned an empty body."
        }
    }
}
