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
            guard !shouldDropHighMultiplierNode(named: proxy.name) else {
                continue
            }
            guard !shouldDropGameNode(named: proxy.name) else {
                continue
            }
            guard !shouldDropDisallowedCountry(named: proxy.name) else {
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

    private func shouldDropDisallowedCountry(named name: String) -> Bool {
        // Keep only mainstream regions. Anything the classifier can't place into
        // a recognized country bucket (i.e. lands in `.other`) is dropped — this
        // covers unused countries (Israel, Germany, Canada, single-node tails)
        // as well as junk/ad nodes that carry no country flag (e.g. 官网地址 …).
        // The keep-list is therefore defined in one place: the set of buckets the
        // ProxyCountryClassifier recognizes. Add/remove a bucket there to change it.
        return ProxyCountryClassifier.bucket(for: name) == .other
    }

    private func shouldDropGameNode(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        // Drop dedicated gaming nodes. Covers every simplified/traditional
        // combination of 游/遊 (you) + 戏/戲 (xi).
        let keywordPatterns = [
            "游戏",
            "遊戲",
            "游戲",
            "遊戏"
        ]
        return keywordPatterns.contains { trimmed.contains($0) }
    }

    private func shouldDropHighMultiplierNode(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        let pattern = #"(\d+(?:\.\d+)?)\s*(?:[xX]|倍)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }

        let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let nsString = trimmed as NSString
        for match in regex.matches(in: trimmed, range: nsRange) {
            guard match.numberOfRanges > 1,
                  let multiplierRange = Range(match.range(at: 1), in: trimmed),
                  let multiplier = Double(trimmed[multiplierRange]),
                  multiplier >= 5 else {
                continue
            }

            let matchRange = match.range(at: 0)
            if matchRange.location != 0 {
                let previous = nsString.substring(with: NSRange(location: matchRange.location - 1, length: 1))
                if previous.range(of: #"[A-Za-z0-9]"#, options: .regularExpression) != nil {
                    continue
                }
            }

            let nextLocation = matchRange.location + matchRange.length
            if nextLocation < nsString.length {
                let next = nsString.substring(with: NSRange(location: nextLocation, length: 1))
                if next.range(of: #"[A-Za-z0-9.]"#, options: .regularExpression) != nil {
                    continue
                }
            }

            return true
        }

        return false
    }
}
