import Foundation

struct ClashConfigBuilder {
    private let probeURL = "http://www.gstatic.com/generate_204"

    // Nodes whose name contains this keyword are gathered into a dedicated
    // self-built select group. That group is then offered as an option inside
    // every non-country select group, and is omitted entirely when no matching
    // node exists. Such nodes are also kept out of the country auto groups —
    // see build(proxies:ruleLines:passthroughDNS:).
    private static let selfBuiltKeyword = "自建"
    private static let selfBuiltGroupName = "自建"

    func build(proxies: [ProxyEntry], ruleLines: [String], passthroughDNS: PassthroughDNS = .empty) -> String {
        let names = proxies.map(\.name)

        let selfBuiltNames = names.filter { $0.contains(Self.selfBuiltKeyword) }
        let selfBuiltGroupName = selfBuiltNames.isEmpty ? nil : Self.selfBuiltGroupName
        if let selfBuiltGroupName {
            AppLogger.log("Self-built group \"\(selfBuiltGroupName)\" with \(selfBuiltNames.count) node(s).")
        }

        // Self-built nodes belong to their own group only — bucketing them by
        // country as well would list the same node twice. Excluding them from
        // the bucketing input is enough: a country whose nodes were all
        // self-built ends up with an empty bucket and is dropped by the
        // non-empty filter below, so no empty url-test group is ever emitted.
        let countryCandidates = names.filter { !$0.contains(Self.selfBuiltKeyword) }
        let countryBuckets = ProxyCountryClassifier.bucketed(names: countryCandidates)
        let availableCountryGroups = CountryBucket.allCases.filter { !countryBuckets[$0, default: []].isEmpty }
        let countryGroupNames = availableCountryGroups.map(\.groupName)
        if !selfBuiltNames.isEmpty {
            AppLogger.log("Excluded \(selfBuiltNames.count) self-built node(s) from country auto groups.")
        }
        AppLogger.log("Country auto group summary: \(ProxyCountryClassifier.summary(for: countryBuckets))")
        var lines: [String] = [
            "port: 7890",
            "socks-port: 7891",
            "allow-lan: true",
            "mode: Rule",
            "log-level: info"
        ]
        lines.append(contentsOf: renderHosts(passthroughDNS.hosts))
        lines.append(contentsOf: renderDNS(passthrough: passthroughDNS))
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

    /// 顶层 hosts,透传自机场订阅。为使其生效,dns 块里会一并写 `use-hosts: true`。
    private func renderHosts(_ hosts: [PassthroughDNS.HostEntry]) -> [String] {
        guard !hosts.isEmpty else { return [] }
        var lines = ["hosts:"]
        for entry in hosts {
            let rendered = entry.values.count == 1
                ? Self.yamlQuoted(entry.values[0])
                : Self.renderFlowList(entry.values)
            lines.append("  \(Self.yamlQuoted(entry.host)): \(rendered)")
        }
        return lines
    }

    private func renderDNS(passthrough: PassthroughDNS) -> [String] {
        var lines: [String] = [
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
            "    - https://223.5.5.5/dns-query",
            "    - https://223.6.6.6/dns-query",
            "    - https://dns.alidns.com/dns-query",
            "    - https://doh.pub/dns-query"
        ]

        if !passthrough.hosts.isEmpty {
            lines.append("  use-hosts: true")
        }

        // 透传机场原始 nameserver-policy。节点服务器域名常为 CDN 前置 / 私有解析,
        // 只有走机场自带的解析服务器才能拿到可连通的 IP,公共 DNS 会解析出错误地址。
        if !passthrough.nameserverPolicy.isEmpty {
            lines.append("  nameserver-policy:")
            for entry in passthrough.nameserverPolicy {
                lines.append("    \(Self.yamlQuoted(entry.key)): \(Self.renderFlowList(entry.servers))")
            }
        }

        // proxy-server-nameserver 一旦设置就会“绕过”nameserver-policy 直接解析节点域名
        // (见 mihomo 文档:留空才会回落到 nameserver-policy / nameserver / fallback)。
        //   - 机场自带 proxy-server-nameserver → 原样透传;
        //   - 否则若已有可依赖的 nameserver-policy → 省略本项,让节点域名回落到 policy;
        //   - 都没有 → 保留默认公共 DoH(维持旧行为)。
        if !passthrough.proxyServerNameserver.isEmpty {
            lines.append("  proxy-server-nameserver:")
            for server in passthrough.proxyServerNameserver {
                lines.append("    - \(server)")
            }
        } else if passthrough.nameserverPolicy.isEmpty {
            lines.append("  proxy-server-nameserver:")
            lines.append("    - https://dns.alidns.com/dns-query")
        }

        lines.append("")
        return lines
    }

    /// 单引号包裹并转义,安全用于含 `:` / `,` / `*` 的 key(如 `*.example.com`、`geosite:cn`)。
    static func yamlQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func renderFlowList(_ items: [String]) -> String {
        "[" + items.map { yamlQuoted($0) }.joined(separator: ", ") + "]"
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
        case "Lark":
            return ProxyGroupIconCatalog.lark
        case "GitHub":
            return ProxyGroupIconCatalog.github
        case "Telegram":
            return ProxyGroupIconCatalog.telegram
        case "X":
            return ProxyGroupIconCatalog.x
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

/// 从机场订阅原始 Clash 配置里提取、可安全透传的 DNS 片段。
///
/// App 自己生成 fake-ip 基础 DNS,但节点服务器域名(常为 CDN 前置 / 机场私有解析)
/// 只有走机场自带的解析服务器才能拿到可连通的 IP。这些信息只存在于订阅原文的
/// `dns` / `hosts` 中,而 subconverter 引擎不会保留它——所以由 App 直接读取本地
/// 订阅文件补齐。合并按 key 去重,首个来源优先。
struct PassthroughDNS {
    typealias PolicyEntry = (key: String, servers: [String])
    typealias HostEntry = (host: String, values: [String])

    private(set) var nameserverPolicy: [PolicyEntry] = []
    private(set) var proxyServerNameserver: [String] = []
    private(set) var hosts: [HostEntry] = []

    static let empty = PassthroughDNS()

    var isEmpty: Bool {
        nameserverPolicy.isEmpty && proxyServerNameserver.isEmpty && hosts.isEmpty
    }

    private var policyKeys = Set<String>()
    private var proxyServerSet = Set<String>()
    private var hostKeys = Set<String>()

    mutating func merge(configYAML root: YAMLValue) {
        if let dns = root["dns"] {
            if let entries = dns["nameserver-policy"]?.mappingEntries {
                for entry in entries {
                    guard !policyKeys.contains(entry.key),
                          let servers = entry.value.stringArray, !servers.isEmpty else { continue }
                    policyKeys.insert(entry.key)
                    nameserverPolicy.append((entry.key, servers))
                }
            }
            if let servers = dns["proxy-server-nameserver"]?.stringArray {
                for server in servers where !proxyServerSet.contains(server) {
                    proxyServerSet.insert(server)
                    proxyServerNameserver.append(server)
                }
            }
        }
        if let hostEntries = root["hosts"]?.mappingEntries {
            for entry in hostEntries {
                guard !hostKeys.contains(entry.key),
                      let values = entry.value.stringArray, !values.isEmpty else { continue }
                hostKeys.insert(entry.key)
                hosts.append((entry.key, values))
            }
        }
    }

    /// 读取每个来源的本地 YAML 文件,提取并合并可透传的 DNS 配置。
    /// 非 YAML(如 base64 节点列表)或读取失败的来源会被安全跳过。
    static func collect(fromFilePaths paths: [String]) -> PassthroughDNS {
        var result = PassthroughDNS()
        for path in paths {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                AppLogger.log("DNS 透传:无法读取来源文件 \(path)")
                continue
            }
            guard let root = try? MiniYAML.parse(text) else {
                AppLogger.log("DNS 透传:来源不是可解析 YAML,跳过 \(path)")
                continue
            }
            result.merge(configYAML: root)
        }
        AppLogger.log("DNS 透传:policy=\(result.nameserverPolicy.count) proxy-server-ns=\(result.proxyServerNameserver.count) hosts=\(result.hosts.count)")
        return result
    }
}
