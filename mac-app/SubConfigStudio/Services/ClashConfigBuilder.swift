import Foundation

struct ClashConfigBuilder {
    private let probeURL = "http://www.gstatic.com/generate_204"

    func build(proxies: [ProxyEntry], ruleLines: [String]) -> String {
        let names = proxies.map(\.name)
        let countryBuckets = ProxyCountryClassifier.bucketed(names: names)
        let availableCountryGroups = CountryBucket.allCases.filter { !countryBuckets[$0, default: []].isEmpty }
        let countryGroupNames = availableCountryGroups.map(\.groupName)
        AppLogger.log("Country auto group summary: \(ProxyCountryClassifier.summary(for: countryBuckets))")
        var lines: [String] = [
            "port: 7890",
            "socks-port: 7891",
            "allow-lan: true",
            "mode: Rule",
            "log-level: info",
            "proxies:"
        ]

        lines.append(contentsOf: proxies.map { $0.renderedLine() })
        lines.append("")
        lines.append("proxy-groups:")
        for group in PresetBuilder.policyGroups {
            lines.append(
                contentsOf: renderPolicyGroup(
                    group,
                    names: names,
                    countryGroupNames: countryGroupNames,
                    preferredCountryGroupNames: preferredCountryGroups(for: group, availableCountryGroups: availableCountryGroups)
                )
            )
        }
        lines.append(contentsOf: renderDefaultGroup(names, countryGroupNames: countryGroupNames))
        for bucket in availableCountryGroups {
            lines.append(contentsOf: renderCountryAutoGroup(bucket, names: countryBuckets[bucket, default: []]))
        }
        lines.append("")
        lines.append("rules:")
        lines.append(contentsOf: ruleLines.map { "  - \($0)" })

        return lines.joined(separator: "\n") + "\n"
    }

    private func renderCountryAutoGroup(_ bucket: CountryBucket, names: [String]) -> [String] {
        var lines = [
            "  - name: \(quoted(bucket.groupName))",
            "    icon: \(quoted(bucket.iconURL))",
            "    type: url-test",
            "    url: \(quoted(probeURL))",
            "    interval: 300",
            "    proxies:"
        ]
        lines.append(contentsOf: names.map { "      - \(quoted($0))" })
        return lines
    }

    private func renderDefaultGroup(_ names: [String], countryGroupNames: [String]) -> [String] {
        renderSelectGroup(
            named: "Default",
            icon: ProxyGroupIconCatalog.proxy,
            names: names,
            countryGroupNames: countryGroupNames,
            includeDefault: false
        )
    }

    private func renderPolicyGroup(
        _ group: String,
        names: [String],
        countryGroupNames: [String],
        preferredCountryGroupNames: [String]
    ) -> [String] {
        renderSelectGroup(
            named: group,
            icon: icon(for: group),
            names: names,
            countryGroupNames: preferredCountryGroupNames.isEmpty ? countryGroupNames : preferredCountryGroupNames,
            includeDefault: true
        )
    }

    private func renderSelectGroup(
        named name: String,
        icon: String,
        names: [String],
        countryGroupNames: [String],
        includeDefault: Bool
    ) -> [String] {
        var lines = [
            "  - name: \(quoted(name))",
            "    icon: \(quoted(icon))",
            "    type: select",
            "    proxies:"
        ]

        if includeDefault {
            lines.append("      - \(quoted("Default"))")
        }
        lines.append("      - \(quoted("DIRECT"))")
        lines.append(contentsOf: countryGroupNames.map { "      - \(quoted($0))" })
        lines.append(contentsOf: names.map { "      - \(quoted($0))" })
        return lines
    }

    private func icon(for group: String) -> String {
        switch group {
        case "Claude Code", "OpenAI", "Gemini":
            return ProxyGroupIconCatalog.ai
        case "Binance", "OKX", "Bybit":
            return ProxyGroupIconCatalog.crypto
        case "YouTube":
            return ProxyGroupIconCatalog.youtube
        case "Netflix":
            return ProxyGroupIconCatalog.netflix
        case "Other":
            return ProxyGroupIconCatalog.final
        default:
            return ProxyGroupIconCatalog.proxy
        }
    }

    private func preferredCountryGroups(for group: String, availableCountryGroups: [CountryBucket]) -> [String] {
        let preferredBuckets: [CountryBucket]

        switch group {
        case "Claude Code", "OpenAI":
            preferredBuckets = [.unitedStates, .singapore, .japan, .unitedKingdom]
        case "Gemini":
            preferredBuckets = [.unitedStates, .singapore, .japan, .taiwan]
        default:
            preferredBuckets = availableCountryGroups
        }

        let availableSet = Set(availableCountryGroups)
        return preferredBuckets
            .filter { availableSet.contains($0) }
            .map(\.groupName)
    }

    private func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
