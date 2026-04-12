import Foundation

struct YAMLPostProcessor {
    func deduplicateAndNormalize(_ proxies: [ProxyEntry]) -> [ProxyEntry] {
        var seenSignatures = Set<String>()
        var nameCounts: [String: Int] = [:]
        var normalized: [ProxyEntry] = []

        for var proxy in proxies {
            guard !shouldDropTrafficDisplayNode(named: proxy.name) else {
                continue
            }
            guard seenSignatures.insert(proxy.signature).inserted else {
                continue
            }

            let baseName = proxy.name
            let nextCount = (nameCounts[baseName] ?? 0) + 1
            nameCounts[baseName] = nextCount

            if nextCount > 1 {
                proxy.name = "\(baseName) #\(nextCount)"
            }

            normalized.append(proxy)
        }

        return normalized
    }

    private func shouldDropTrafficDisplayNode(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        let keywordPatterns = [
            "剩余流量",
            "到期",
            "重置",
            "重置时间",
            "流量重置",
            "traffic reset",
            "reset day",
            "reset time",
            "reset on",
            "Bandwidth",
            "expire",
            "expiry",
            "expiration",
            "流量",
            "应急"
        ]
        if keywordPatterns.contains(where: { trimmed.range(of: $0, options: .caseInsensitive) != nil }) {
            return true
        }

        let dataOnlyPattern = #"^[\p{Emoji_Presentation}\p{Emoji}\p{So}\s"]*\d+(?:\.\d+)?\s*(?:[KMGTPE]?i?B|[KMGTPE])(?:\s*\|\s*\d+(?:\.\d+)?\s*(?:[KMGTPE]?i?B|[KMGTPE]))+[\p{Emoji_Presentation}\p{Emoji}\p{So}\s"]*$"#
        return trimmed.range(of: dataOnlyPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
