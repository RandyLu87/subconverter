import Foundation

struct ClashConfigBuilder {
    private let probeURL = "http://www.gstatic.com/generate_204"

    // Nodes whose name contains this keyword are gathered into a dedicated
    // self-built select group. That group is then offered as an option inside
    // every non-country select group, and is omitted entirely when no matching
    // node exists.
    private static let selfBuiltKeyword = "自建"
    private static let selfBuiltGroupName = "自建"

    func build(proxies: [ProxyEntry], ruleLines: [String]) -> String {
        let names = proxies.map(\.name)
        let countryBuckets = ProxyCountryClassifier.bucketed(names: names)
        let availableCountryGroups = CountryBucket.allCases.filter { !countryBuckets[$0, default: []].isEmpty }
        let countryGroupNames = availableCountryGroups.map(\.groupName)
        AppLogger.log("Country auto group summary: \(ProxyCountryClassifier.summary(for: countryBuckets))")

        let selfBuiltNames = names.filter { $0.contains(Self.selfBuiltKeyword) }
        let selfBuiltGroupName = selfBuiltNames.isEmpty ? nil : Self.selfBuiltGroupName
        if let selfBuiltGroupName {
            AppLogger.log("Self-built group \"\(selfBuiltGroupName)\" with \(selfBuiltNames.count) node(s).")
        }
        var lines: [String] = [
            "port: 7890",
            "socks-port: 7891",
            "allow-lan: true",
            "mode: Rule",
            "log-level: info"
        ]
        lines.append(contentsOf: renderDNS())
        lines.append(contentsOf: renderSniffer())
        lines.append(contentsOf: [
            "proxies:"
        ])

        lines.append(contentsOf: proxies.map { $0.renderedLine() })
        lines.append("")
        lines.append("proxy-groups:")
        for group in PresetBuilder.policyGroups {
            lines.append(
                contentsOf: renderPolicyGroup(
                    group,
                    names: names,
                    countryGroupNames: countryGroupNames,
                    preferredCountryGroupNames: preferredCountryGroups(for: group, availableCountryGroups: availableCountryGroups),
                    selfBuiltGroupName: selfBuiltGroupName
                )
            )
        }
        lines.append(contentsOf: renderDefaultGroup(names, countryGroupNames: countryGroupNames, selfBuiltGroupName: selfBuiltGroupName))
        if let selfBuiltGroupName {
            lines.append(contentsOf: renderSelfBuiltGroup(named: selfBuiltGroupName, names: selfBuiltNames))
        }
        for bucket in availableCountryGroups {
            lines.append(contentsOf: renderCountryAutoGroup(bucket, names: countryBuckets[bucket, default: []]))
        }
        lines.append("")
        lines.append("rule-providers:")
        lines.append(contentsOf: renderEnhancedChinaDomainProvider())
        lines.append("")
        lines.append("rules:")
        lines.append(contentsOf: ruleLines.map { "  - \($0)" })

        return lines.joined(separator: "\n") + "\n"
    }

    private func renderEnhancedChinaDomainProvider() -> [String] {
        [
            "  cn-domain:",
            "    type: http",
            "    behavior: domain",
            "    format: mrs",
            "    url: \"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs\"",
            "    interval: 86400"
        ]
    }

    private func renderDNS() -> [String] {
        [
            "dns:",
            "  enable: true",
            "  listen: 0.0.0.0:1053",
            "  ipv6: false",
            "  enhanced-mode: fake-ip",
            "  fake-ip-range: 198.18.0.1/16",
            "  fake-ip-filter:",
            "    - \"*.lan\"",
            "    - \"*.local\"",
            "    - \"localhost.ptlogin2.qq.com\"",
            "  default-nameserver:",
            "    - 223.5.5.5",
            "    - 119.29.29.29",
            "  nameserver:",
            "    - https://dns.alidns.com/dns-query",
            "    - https://doh.pub/dns-query",
            "  proxy-server-nameserver:",
            "    - https://dns.alidns.com/dns-query",
            ""
        ]
    }

    private func renderSniffer() -> [String] {
        [
            "sniffer:",
            "  enable: true",
            "  parse-pure-ip: true",
            "  sniff:",
            "    HTTP:",
            "      ports:",
            "        - 80",
            "        - 8080-8880",
            "      override-destination: true",
            "    TLS:",
            "      ports:",
            "        - 443",
            "        - 8443",
            "    QUIC:",
            "      ports:",
            "        - 443",
            "        - 8443",
            ""
        ]
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

    private func renderDefaultGroup(_ names: [String], countryGroupNames: [String], selfBuiltGroupName: String?) -> [String] {
        renderSelectGroup(
            named: "Default",
            icon: ProxyGroupIconCatalog.proxy,
            names: names,
            countryGroupNames: countryGroupNames,
            includeDefault: false,
            selfBuiltGroupName: selfBuiltGroupName
        )
    }

    // The self-built group uses the same icon as Default and lists only the
    // nodes whose name matched the keyword. It deliberately does not list
    // itself as an option, so it is rendered separately from renderSelectGroup.
    private func renderSelfBuiltGroup(named name: String, names: [String]) -> [String] {
        var lines = [
            "  - name: \(quoted(name))",
            "    icon: \(quoted(ProxyGroupIconCatalog.proxy))",
            "    type: select",
            "    proxies:"
        ]
        lines.append(contentsOf: names.map { "      - \(quoted($0))" })
        return lines
    }

    private func renderPolicyGroup(
        _ group: String,
        names: [String],
        countryGroupNames: [String],
        preferredCountryGroupNames: [String],
        selfBuiltGroupName: String?
    ) -> [String] {
        renderSelectGroup(
            named: group,
            icon: icon(for: group),
            names: names,
            countryGroupNames: preferredCountryGroupNames.isEmpty ? countryGroupNames : preferredCountryGroupNames,
            includeDefault: true,
            selfBuiltGroupName: selfBuiltGroupName
        )
    }

    private func renderSelectGroup(
        named name: String,
        icon: String,
        names: [String],
        countryGroupNames: [String],
        includeDefault: Bool,
        selfBuiltGroupName: String?
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
        if let selfBuiltGroupName {
            lines.append("      - \(quoted(selfBuiltGroupName))")
        }
        lines.append(contentsOf: names.map { "      - \(quoted($0))" })
        return lines
    }

    private func icon(for group: String) -> String {
        switch group {
        case "Claude Code":
            return ProxyGroupIconCatalog.claudeCode
        case "Gemini":
            return ProxyGroupIconCatalog.gemini
        case "Google":
            return ProxyGroupIconCatalog.google
        case "OpenAI":
            return ProxyGroupIconCatalog.ai
        case "Binance", "OKX", "Bybit":
            return ProxyGroupIconCatalog.crypto
        case "Apple":
            return ProxyGroupIconCatalog.apple
        case "YouTube":
            return ProxyGroupIconCatalog.youtube
        case "Netflix":
            return ProxyGroupIconCatalog.netflix
        case "Steam":
            return ProxyGroupIconCatalog.steam
        case "Futu":
            return ProxyGroupIconCatalog.futu
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
