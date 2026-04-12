import Foundation

struct YAMLPostProcessor {
    func deduplicateAndNormalize(_ proxies: [ProxyEntry]) -> [ProxyEntry] {
        var seenSignatures = Set<String>()
        var nameCounts: [String: Int] = [:]
        var normalized: [ProxyEntry] = []

        for var proxy in proxies {
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
}
