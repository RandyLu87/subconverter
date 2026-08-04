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

    // fake-ip-filter:命中的域名不走 fake-ip,客户端拿到真实 IP。收录标准是
    // “这个域名的客户端会不会自己拿 IP 做事”—— STUN/P2P 打洞、流媒体 CDN 自行测速
    // 选节点、本地探测与对时,这三类拿到假 IP 就会失效。
    // 来源:OpenClash 0.47 自带的 openclash_custom_fake_filter.list。
    // 注意分类名有歧义:Google / Netflix 段只有 STUN 服务器和视频 CDN,
    // 不含 google.com / netflix.com 本体,服务主域名照常走 fake-ip 与域名分流。
    // 必须与 sniffer.parse-pure-ip 配套:命中后 mihomo 只看得到纯 IP 连接,
    // 要靠嗅探还原域名,否则 DOMAIN-SUFFIX 类规则会失配。
    private static let fakeIPFilter: [String] = [
        // LAN
        "*.lan",
        "*.localdomain",
        "*.example",
        "*.invalid",
        "*.localhost",
        "*.test",
        "*.local",
        "*.home.arpa",
        // 放行NTP服务
        "time.*.com",
        "time.*.gov",
        "time.*.edu.cn",
        "time.*.apple.com",
        "time-ios.apple.com",
        "time1.*.com",
        "time2.*.com",
        "time3.*.com",
        "time4.*.com",
        "time5.*.com",
        "time6.*.com",
        "time7.*.com",
        "ntp.*.com",
        "ntp1.*.com",
        "ntp2.*.com",
        "ntp3.*.com",
        "ntp4.*.com",
        "ntp5.*.com",
        "ntp6.*.com",
        "ntp7.*.com",
        "*.time.edu.cn",
        "*.ntp.org.cn",
        "+.pool.ntp.org",
        "time1.cloud.tencent.com",
        // 放行网易云音乐
        "music.163.com",
        "*.music.163.com",
        "*.126.net",
        // 百度音乐
        "musicapi.taihe.com",
        "music.taihe.com",
        // 酷狗音乐
        "songsearch.kugou.com",
        "trackercdn.kugou.com",
        // 酷我音乐
        "*.kuwo.cn",
        // JOOX音乐
        "api-jooxtt.sanook.com",
        "api.joox.com",
        "joox.com",
        // QQ音乐
        "y.qq.com",
        "*.y.qq.com",
        "streamoc.music.tc.qq.com",
        "mobileoc.music.tc.qq.com",
        "isure.stream.qqmusic.qq.com",
        "dl.stream.qqmusic.qq.com",
        "aqqmusic.tc.qq.com",
        "amobile.music.tc.qq.com",
        // 虾米音乐
        "*.xiami.com",
        // 咪咕音乐
        "*.music.migu.cn",
        "music.migu.cn",
        // win10本地连接检测
        "+.msftconnecttest.com",
        "+.msftncsi.com",
        // QQ登录
        "localhost.ptlogin2.qq.com",
        "localhost.sec.qq.com",
        "+.qq.com",
        "+.tencent.com",
        // Game
        // Nintendo Switch
        "+.srv.nintendo.net",
        "*.n.n.srv.nintendo.net",
        // Sony PlayStation
        "+.stun.playstation.net",
        // Microsoft Xbox
        "xbox.*.*.microsoft.com",
        "*.*.xboxlive.com",
        "xbox.*.microsoft.com",
        "xnotify.xboxlive.com",
        // Wotgame
        "+.battlenet.com.cn",
        "+.wotgame.cn",
        "+.wggames.cn",
        "+.wowsgame.cn",
        "+.wargaming.net",
        // Golang
        "proxy.golang.org",
        // STUN
        "stun.*.*",
        "stun.*.*.*",
        "+.stun.*.*",
        "+.stun.*.*.*",
        "+.stun.*.*.*.*",
        "+.stun.*.*.*.*.*",
        // Linksys Router
        "heartbeat.belkin.com",
        "*.linksys.com",
        "*.linksyssmartwifi.com",
        // ASUS Router
        "*.router.asus.com",
        // Apple Software Update Service
        "mesu.apple.com",
        "swscan.apple.com",
        "swquery.apple.com",
        "swdownload.apple.com",
        "swcdn.apple.com",
        "swdist.apple.com",
        // Google
        "lens.l.google.com",
        "stun.l.google.com",
        "na.b.g-tun.com",
        // Netflix
        "+.nflxvideo.net",
        // FinalFantasy XIV Worldwide Server & CN Server
        "*.square-enix.com",
        "*.finalfantasyxiv.com",
        "*.ffxiv.com",
        "*.ff14.sdo.com",
        "ff.dorado.sdo.com",
        // Bilibili
        "*.mcdn.bilivideo.cn",
        // Disney Plus
        "+.media.dssott.com",
        // shark007 Codecs
        "shark007.net",
        // Mijia
        "Mijia Cloud",
        // 招商银行
        "+.cmbchina.com",
        "+.cmbimg.com",
        // AdGuard
        "local.adguard.org",
        // 迅雷
        "+.sandai.net",
        "+.n0808.com",
    ]

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
            "log-level: info",
            // store-fake-ip 把 fake-ip 映射表落盘。不开的话每次重启映射表清空,
            // 客户端手里缓存的 198.18.x.x 全部失效 —— 表现为重启后部分 App 异常,
            // 要等客户端 DNS 缓存过期才自愈。
            "profile:",
            "  store-selected: true",
            "  store-fake-ip: true"
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
                    pinnedCountryGroupName: pinnedCountryGroup(for: group, availableCountryGroups: availableCountryGroups),
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
            "  fake-ip-filter:"
        ]
        lines.append(contentsOf: Self.fakeIPFilter.map { "    - \(Self.yamlQuoted($0))" })
        lines.append(contentsOf: [
            "  default-nameserver:",
            "    - 223.5.5.5",
            "    - 119.29.29.29",
            "  nameserver:",
            "    - https://223.5.5.5/dns-query",
            "    - https://223.6.6.6/dns-query",
            "    - https://dns.alidns.com/dns-query",
            "    - https://doh.pub/dns-query",
            // 规则判定为 DIRECT 的连接用国内明文 DNS 解析。按路由结果生效,
            // 与按域名匹配的 nameserver-policy 互补,且不依赖 GeoSite 数据新鲜度。
            // 需要 mihomo >= 1.18.8。
            "  direct-nameserver:",
            "    - 223.5.5.5",
            "    - 119.29.29.29"
        ])

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
        //   - 都没有 → 兜底明文 UDP。
        // 兜底刻意不用 DoH:节点域名要靠它解析,而 DoH 端点自己也是域名,
        // 会形成 default-nameserver → TCP+TLS → 才拿到结果的自举链条,
        // 每次启动和断线重连都多付几百毫秒;明文 UDP 一个包就够。
        if !passthrough.proxyServerNameserver.isEmpty {
            lines.append("  proxy-server-nameserver:")
            for server in passthrough.proxyServerNameserver {
                lines.append("    - \(server)")
            }
        } else if passthrough.nameserverPolicy.isEmpty {
            lines.append("  proxy-server-nameserver:")
            lines.append("    - 223.5.5.5")
            lines.append("    - 119.29.29.29")
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
        pinnedCountryGroupName: String?,
        selfBuiltGroupName: String?
    ) -> [String] {
        renderSelectGroup(
            named: group,
            icon: icon(for: group),
            names: names,
            countryGroupNames: preferredCountryGroupNames.isEmpty ? countryGroupNames : preferredCountryGroupNames,
            includeDefault: true,
            pinnedCountryGroupName: pinnedCountryGroupName,
            selfBuiltGroupName: selfBuiltGroupName
        )
    }

    // pinnedCountryGroupName 的语义见 pinnedCountryGroup(for:availableCountryGroups:)。
    private func renderSelectGroup(
        named name: String,
        icon: String,
        names: [String],
        countryGroupNames: [String],
        includeDefault: Bool,
        pinnedCountryGroupName: String? = nil,
        selfBuiltGroupName: String?
    ) -> [String] {
        var lines = [
            "  - name: \(quoted(name))",
            "    icon: \(quoted(icon))",
            "    type: select",
            "    proxies:"
        ]

        if let pinnedCountryGroupName {
            lines.append("      - \(quoted(pinnedCountryGroupName))")
        }
        if includeDefault {
            lines.append("      - \(quoted("Default"))")
        }
        lines.append("      - \(quoted("DIRECT"))")
        lines.append(contentsOf: countryGroupNames
            .filter { $0 != pinnedCountryGroupName }
            .map { "      - \(quoted($0))" })
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
        case "Supercell":
            return ProxyGroupIconCatalog.game
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

    /// 需要「开箱即走某个地区」的策略组。返回的地区组会被排到候选首项,
    /// 也就是 mihomo 的默认选中项 —— 与 preferredCountryGroups 只改菜单顺序不同。
    ///
    /// Supercell 国际服钉美国:账号侧的对战服务器由 Supercell 分配,换出口改不了
    /// 匹配池,这里钉的只是到 Supercell 的入口链路。
    ///
    /// 机场没有对应地区的节点时返回 nil,候选顺序完全回退到未钉之前的形状。
    private func pinnedCountryGroup(for group: String, availableCountryGroups: [CountryBucket]) -> String? {
        let pinned: CountryBucket
        switch group {
        case "Supercell":
            pinned = .unitedStates
        default:
            return nil
        }

        return availableCountryGroups.contains(pinned) ? pinned.groupName : nil
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
