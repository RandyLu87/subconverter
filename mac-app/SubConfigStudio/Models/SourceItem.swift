import Foundation

enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case subscriptionURL
    case importedYAML

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subscriptionURL:
            return "Subscription URL"
        case .importedYAML:
            return "Imported YAML"
        }
    }
}

enum SourceStatus: String, Codable {
    case idle
    case ready
    case error

    var title: String {
        switch self {
        case .idle:
            return "Idle"
        case .ready:
            return "Ready"
        case .error:
            return "Error"
        }
    }
}

struct SourceItem: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var kind: SourceKind
    var value: String
    var enabled: Bool
    var order: Int
    var lastStatus: SourceStatus
    var lastError: String?

    init(
        id: UUID = UUID(),
        name: String,
        kind: SourceKind,
        value: String,
        enabled: Bool = true,
        order: Int,
        lastStatus: SourceStatus = .idle,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.value = value
        self.enabled = enabled
        self.order = order
        self.lastStatus = lastStatus
        self.lastError = lastError
    }

    var displayValue: String {
        if kind == .subscriptionURL {
            return value
        }

        return URL(fileURLWithPath: value).lastPathComponent
    }
}

struct PersistedAppState: Codable {
    var sources: [SourceItem]
    var lastGeneratedAt: Date?
    var lastGeneratedProxyCount: Int?

    static let empty = PersistedAppState(sources: [], lastGeneratedAt: nil, lastGeneratedProxyCount: nil)
}
