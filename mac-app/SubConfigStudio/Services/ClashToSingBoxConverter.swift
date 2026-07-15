import Foundation

// MARK: - 报告

enum ConversionLevel: String {
    case error
    case warning
    case info
}

struct ConversionMessage: Identifiable {
    let id = UUID()
    let level: ConversionLevel
    let text: String
}

struct ConversionReport {
    private(set) var messages: [ConversionMessage] = []
    mutating func error(_ t: String) { messages.append(.init(level: .error, text: t)) }
    mutating func warn(_ t: String) { messages.append(.init(level: .warning, text: t)) }
    mutating func info(_ t: String) { messages.append(.init(level: .info, text: t)) }
    var hasError: Bool { messages.contains { $0.level == .error } }
}

struct ConversionOutput {
    let configJSON: String
    let iconsJSON: String?
    let report: ConversionReport
}

enum ClashConversionError: LocalizedError {
    case engineFailed(String)
    case noValidNodes
    case validationFailed([String])

    var errorDescription: String? {
        switch self {
        case let .engineFailed(m): return "引擎转换节点失败:\(m)"
        case .noValidNodes: return "没有可用节点(可能全是 SSR 或解析失败)。"
        case let .validationFailed(errs): return "生成的 sing-box 配置未通过校验:\n" + errs.joined(separator: "\n")
        }
    }
}

// MARK: - 转换器

final class ClashToSingBoxConverter {
    private let runtimeInstaller: RuntimeInstaller
    private let engine: EngineController

    // sing-box 不支持的协议类型(引擎可能照样吐出来)
    private static let unsupportedOutboundTypes: Set<String> = ["shadowsocksr", "snell"]

    // 已知 Clash rule-provider → sing-box 远程 srs 对照表
    private static let providerMap: [String: (tag: String, url: String)] = [
        "cn-domain": ("geosite-geolocation-cn",
                      "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs")
    ]

    init(runtimeInstaller: RuntimeInstaller = RuntimeInstaller(), engine: EngineController) {
        self.runtimeInstaller = runtimeInstaller
        self.engine = engine
    }

    func convert(clashYAML: String) async throws -> ConversionOutput {
        var report = ConversionReport()

        // 1) 解析源 YAML(只取分组/规则/provider/dns;节点交给引擎)
        let root = try MiniYAML.parse(clashYAML)
        let clashGroups = root["proxy-groups"]?.sequenceValues ?? []
        let clashRules = root["rules"]?.stringArray ?? []

        // 2) 节点:引擎 target=singbox&list=true
        let nodeObjects = try await fetchNodes(clashYAML: clashYAML)
        var droppedTags = Set<String>()
        var validNodes: [[String: Any]] = []
        for node in nodeObjects {
            let type = (node["type"] as? String) ?? ""
            let tag = (node["tag"] as? String) ?? ""
            if Self.unsupportedOutboundTypes.contains(type) {
                if !tag.isEmpty { droppedTags.insert(tag) }
            } else {
                validNodes.append(node)
            }
        }
        if !droppedTags.isEmpty {
            report.warn("跳过 \(droppedTags.count) 个 sing-box 不支持的节点(SSR/Snell 等)。")
        }
        guard !validNodes.isEmpty else { throw ClashConversionError.noValidNodes }
        let nodeTags = Set(validNodes.compactMap { $0["tag"] as? String })
        report.info("有效节点 \(validNodes.count) 个。")

        // 平移机场私有 DNS:节点服务器域名常为 CDN 前置 / 私有解析,必须用机场自带 DoH 才能
        // 解析到可连通 IP,明文 / 公共 DNS 会解析到错误地址导致节点连不上。sing-box 里出站服务器
        // 域名的解析由各出站的 domain_resolver 决定(且会绕过 dns.rules),所以给服务器域名命中
        // 机场策略的节点逐个注入 domain_resolver,并新增对应的 DoH 解析器。
        var passthrough = PassthroughDNS()
        passthrough.merge(configYAML: root)
        let nodeResolvers = buildNodeDomainResolvers(policy: passthrough.nameserverPolicy)
        if !nodeResolvers.servers.isEmpty {
            var injected = 0
            validNodes = validNodes.map { node in
                guard let server = node["server"] as? String,
                      let tag = nodeResolvers.tag(forServerDomain: server) else { return node }
                var updated = node
                updated["domain_resolver"] = ["server": tag]
                injected += 1
                return updated
            }
            report.info("平移机场私有 DNS:为 \(injected) 个节点注入 domain_resolver,新增 \(nodeResolvers.servers.count) 个 DoH 解析器。")
        }

        // 3) 策略组
        let (groupObjects, groupTags) = buildGroups(clashGroups, nodeTags: nodeTags, dropped: droppedTags, report: &report)
        report.info("策略组 \(groupObjects.count) 个。")

        // 全部合法出站 tag(校验 + policy 解析用)
        var allTags = nodeTags.union(groupTags)
        allTags.insert("direct")

        // 4) 规则 + rule_set(geo 引用先在线校验 + 回退,保证不产出 404 的 srs URL)
        var ruleSetRegistry: [String: [String: Any]] = [:]  // tag -> rule_set 定义(先不填 detour)
        let finalOutbound = resolveFinalOutbound(clashRules, groupTags: groupTags, report: &report)
        let resolvedGeo = await resolveGeoReferences(clashRules, ruleSetRegistry: &ruleSetRegistry, report: &report)
        let routeRules = buildRouteRules(clashRules,
                                         resolvedGeo: resolvedGeo,
                                         allTags: allTags,
                                         ruleSetRegistry: &ruleSetRegistry,
                                         report: &report)

        // remote rule_set 下载出站:用 http_client(sing-box 1.14+ 新写法;旧的 download_detour 1.16 移除)。
        // 指向最终出站(通常是含节点的组)。
        let detour = groupTags.contains(finalOutbound) ? finalOutbound : (groupTags.first ?? "direct")
        var ruleSetArray: [[String: Any]] = []
        for (_, var rs) in ruleSetRegistry.sorted(by: { ($0.value["tag"] as! String) < ($1.value["tag"] as! String) }) {
            rs["http_client"] = ["detour": detour]
            ruleSetArray.append(rs)
        }

        // 5) 出站模式:合成 GLOBAL 选择器(全局模式的出口,成员=所有分组+所有节点)。
        //    若源配置已占用 GLOBAL 名,复用它并提示,不重复合成。
        let sanitizedFinal = allTags.contains(finalOutbound) ? finalOutbound : detour
        let globalTag = "GLOBAL"
        var globalGroup: [String: Any]?
        if groupTags.contains(globalTag) || nodeTags.contains(globalTag) {
            report.warn("源配置已存在名为 GLOBAL 的组/节点,全局模式将直接复用它。")
        } else {
            // 成员只平铺节点(不含分组):全局模式下用户直接从节点列表选出口,符合 Clash 客户端习惯
            let members = validNodes.compactMap { $0["tag"] as? String }
            globalGroup = [
                "type": "selector", "tag": globalTag,
                "outbounds": members,
                "default": members.contains(sanitizedFinal) ? sanitizedFinal : members[0]
            ]
            report.info("已启用出站模式(Rule / Global / Direct),合成 GLOBAL 组(平铺节点 \(members.count) 个)。")
        }

        // 6) 组装(面向 Nest 的固定模板)
        let config = assemble(nodes: validNodes,
                              extraDNSServers: nodeResolvers.servers,
                              groups: groupObjects,
                              routeRules: routeRules,
                              ruleSets: ruleSetArray,
                              finalOutbound: sanitizedFinal,
                              globalGroup: globalGroup,
                              globalTag: globalTag)

        // 7) 校验
        let errs = validate(config)
        if !errs.isEmpty { throw ClashConversionError.validationFailed(errs) }

        // 8) 序列化
        let data = try JSONSerialization.data(withJSONObject: config,
                                              options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        let configJSON = String(decoding: data, as: UTF8.self)

        // 9) 图标旁路
        let icons = extractIcons(clashGroups)
        var iconsJSON: String?
        if !icons.isEmpty {
            let idata = try JSONSerialization.data(withJSONObject: icons,
                                                   options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
            iconsJSON = String(decoding: idata, as: UTF8.self)
            report.info("提取图标 \(icons.count) 个 → icons.json。")
        }

        return ConversionOutput(configJSON: configJSON, iconsJSON: iconsJSON, report: report)
    }

    // MARK: 节点(引擎)

    private func fetchNodes(clashYAML: String) async throws -> [[String: Any]] {
        try AppPaths.ensureDirectories()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("c2s-\(UUID().uuidString).yaml")
        try clashYAML.data(using: .utf8)?.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }  // 含节点凭据,用后即删

        let runtime = try runtimeInstaller.installIfNeeded()
        try await engine.start(using: runtime)
        let body: String
        do {
            body = try await engine.fetchSingBoxNodes(fromConfigPath: tmp.path)
        } catch {
            throw ClashConversionError.engineFailed(error.localizedDescription)
        }
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = obj["outbounds"] as? [[String: Any]] else {
            throw ClashConversionError.engineFailed("引擎返回的 sing-box 节点列表无法解析。")
        }
        return outbounds
    }

    // MARK: 策略组

    private func buildGroups(_ clashGroups: [YAMLValue],
                             nodeTags: Set<String>,
                             dropped: Set<String>,
                             report: inout ConversionReport) -> ([[String: Any]], Set<String>) {
        var result: [[String: Any]] = []
        var groupTags = Set<String>()
        // 先收集所有组名,便于成员引用校验(成员可能是嵌套组)
        for g in clashGroups {
            if let name = g["name"]?.string { groupTags.insert(name) }
        }

        for g in clashGroups {
            guard let name = g["name"]?.string, let type = g["type"]?.string else { continue }
            let members = (g["proxies"]?.stringArray ?? [])

            let sbType: String
            switch type {
            case "select": sbType = "selector"
            case "url-test", "fallback": sbType = "urltest"
            case "load-balance":
                sbType = "urltest"
                report.warn("组「\(name)」load-balance 降级为 urltest。")
            case "relay":
                report.warn("组「\(name)」relay 无法转换,已跳过。")
                groupTags.remove(name)
                continue
            default:
                sbType = "selector"
                report.warn("组「\(name)」未知类型 \(type),按 selector 处理。")
            }

            var resolved: [String] = []
            for m in members {
                if dropped.contains(m) { continue }               // 剔除 SSR 等
                if m == "REJECT" || m == "REJECT-DROP" {
                    report.warn("组「\(name)」的 REJECT 成员无法在组内表达,已剔除。")
                    continue
                }
                let tag = (m == "DIRECT") ? "direct" : m
                if tag == "direct" || nodeTags.contains(tag) || groupTags.contains(tag) {
                    resolved.append(tag)
                } else {
                    report.warn("组「\(name)」成员「\(m)」找不到对应出站,已剔除。")
                }
            }
            if resolved.isEmpty {
                resolved = ["direct"]
                report.warn("组「\(name)」无有效成员,已用 direct 兜底。")
            }

            var obj: [String: Any] = ["type": sbType, "tag": name, "outbounds": resolved]
            if sbType == "selector" {
                obj["default"] = resolved.first!
            } else {
                if let url = g["url"]?.string, !url.isEmpty { obj["url"] = url }
                if let intervalStr = g["interval"]?.string, !intervalStr.isEmpty {
                    obj["interval"] = formatInterval(intervalStr)
                }
            }
            result.append(obj)
        }
        return (result, groupTags)
    }

    // MARK: 规则

    private func resolveFinalOutbound(_ rules: [String],
                                      groupTags: Set<String>,
                                      report: inout ConversionReport) -> String {
        for rule in rules {
            let parts = rule.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.first == "MATCH", parts.count >= 2 {
                let p = parts[1]
                return p == "DIRECT" ? "direct" : p
            }
        }
        report.warn("源规则无 MATCH,route.final 兜底为第一个组或 direct。")
        return groupTags.first ?? "direct"
    }

    /// 中间原子规则
    private struct AtomicRule {
        var field: String          // domain / domain_suffix / domain_keyword / ip_cidr / rule_set
        var value: String
        var outbound: String?      // 二选一
        var action: String?
    }

    private func buildRouteRules(_ rules: [String],
                                 resolvedGeo: [String: String],
                                 allTags: Set<String>,
                                 ruleSetRegistry: inout [String: [String: Any]],
                                 report: inout ConversionReport) -> [[String: Any]] {
        var atomics: [AtomicRule] = []

        for rule in rules {
            let parts = rule.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let type = parts.first else { continue }
            if type == "MATCH" { continue }  // → final

            // policy 通常是第 3 段(部分类型第 2 段);no-resolve 等修饰忽略
            func policyResolve(_ p: String) -> (out: String?, act: String?) {
                if p == "DIRECT" { return ("direct", nil) }
                if p == "REJECT" || p == "REJECT-DROP" { return (nil, "reject") }
                return (p, nil)
            }

            switch type {
            case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6":
                guard parts.count >= 3 else { continue }
                let value = parts[1]
                let (out, act) = policyResolve(parts[2])
                if let out, !allTags.contains(out) {
                    report.warn("规则「\(rule)」目标「\(out)」不存在,已跳过。")
                    continue
                }
                let field: String
                switch type {
                case "DOMAIN": field = "domain"
                case "DOMAIN-SUFFIX": field = "domain_suffix"
                case "DOMAIN-KEYWORD": field = "domain_keyword"
                default: field = "ip_cidr"
                }
                atomics.append(.init(field: field, value: value, outbound: out, action: act))

            case "GEOIP", "GEOSITE":
                guard parts.count >= 3 else { continue }
                let code = parts[1].lowercased()
                let (out, act) = policyResolve(parts[2])
                if code == "private" {
                    // 由 ip_is_private 覆盖(已在模板前置),这里跳过并说明
                    report.info("\(type),private 由 ip_is_private 规则覆盖。")
                    continue
                }
                if let out, !allTags.contains(out) {
                    report.warn("规则「\(rule)」目标「\(out)」不存在,已跳过。")
                    continue
                }
                // 用在线校验阶段解析出的真实可用 tag;解析不到的(404)已在 resolve 阶段告警,这里跳过。
                guard let tag = resolvedGeo["\(type):\(code)"] else { continue }
                atomics.append(.init(field: "rule_set", value: tag, outbound: out, action: act))

            case "RULE-SET":
                guard parts.count >= 3 else { continue }
                let name = parts[1]
                let (out, act) = policyResolve(parts[2])
                guard let mapped = Self.providerMap[name] else {
                    report.warn("规则集 provider「\(name)」无 sing-box 对照,已跳过该 RULE-SET 规则。")
                    continue
                }
                if let out, !allTags.contains(out) {
                    report.warn("规则「\(rule)」目标「\(out)」不存在,已跳过。")
                    continue
                }
                if ruleSetRegistry[mapped.tag] == nil {
                    ruleSetRegistry[mapped.tag] = ["type": "remote", "tag": mapped.tag, "format": "binary", "url": mapped.url]
                }
                atomics.append(.init(field: "rule_set", value: mapped.tag, outbound: out, action: act))

            default:
                report.warn("规则类型「\(type)」暂不支持(\(rule)),已跳过。")
            }
        }

        // 合并相邻的同 field + 同目标规则
        var out: [[String: Any]] = []
        var i = 0
        while i < atomics.count {
            let base = atomics[i]
            var values = [base.value]
            var j = i + 1
            while j < atomics.count,
                  atomics[j].field == base.field,
                  atomics[j].outbound == base.outbound,
                  atomics[j].action == base.action {
                values.append(atomics[j].value)
                j += 1
            }
            var rule: [String: Any] = [base.field: values]
            if let act = base.action { rule["action"] = act }
            else if let o = base.outbound { rule["outbound"] = o }
            out.append(rule)
            i = j
        }
        return out
    }

    // MARK: geo 规则集在线校验 + 回退

    private static let geositeBase = "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/"
    private static let geoipBase = "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/"

    /// 收集所有 GEOIP/GEOSITE 引用,在线校验其 srs 是否存在,必要时回退别名/域名集。
    /// 返回 "TYPE:code" → 实际可用 tag;并把对应 rule_set 定义写入 registry。
    private func resolveGeoReferences(_ rules: [String],
                                      ruleSetRegistry: inout [String: [String: Any]],
                                      report: inout ConversionReport) async -> [String: String] {
        var refs: [(type: String, code: String)] = []
        var seen = Set<String>()
        for rule in rules {
            let p = rule.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let t = p.first, t == "GEOIP" || t == "GEOSITE", p.count >= 2 else { continue }
            let code = p[1].lowercased()
            if code == "private" { continue }
            let key = "\(t):\(code)"
            if seen.insert(key).inserted { refs.append((t, code)) }
        }

        var resolved: [String: String] = [:]
        for ref in refs {
            if let hit = await resolveGeoOne(type: ref.type, code: ref.code, report: &report) {
                resolved["\(ref.type):\(ref.code)"] = hit.tag
                if ruleSetRegistry[hit.tag] == nil {
                    ruleSetRegistry[hit.tag] = ["type": "remote", "tag": hit.tag, "format": "binary", "url": hit.url]
                }
            }
        }
        return resolved
    }

    private func resolveGeoOne(type: String, code: String,
                               report: inout ConversionReport) async -> (tag: String, url: String)? {
        if type == "GEOSITE" {
            var candidates: [(String, String)] = [("geosite-\(code)", Self.geositeBase + "geosite-\(code).srs")]
            if code.hasSuffix("-cn") {
                let alt = "geosite-\(code.dropLast(3))@cn"
                candidates.append((alt, Self.geositeBase + alt + ".srs"))
            }
            for (tag, url) in candidates where await probe(url) { return (tag, url) }
            report.warn("GEOSITE,\(code) 无对应 sing-geosite 规则集,已跳过该规则。")
            return nil
        } else { // GEOIP
            let ipURL = Self.geoipBase + "geoip-\(code).srs"
            if await probe(ipURL) { return ("geoip-\(code)", ipURL) }
            // sing-geoip 只有国家码;provider 类回退到域名规则集(语义从 IP 匹配变为域名匹配)
            let gsURL = Self.geositeBase + "geosite-\(code).srs"
            if await probe(gsURL) {
                report.warn("GEOIP,\(code) 无 IP 规则集,回退到域名规则集 geosite-\(code)(匹配语义由 IP 变为域名)。")
                return ("geosite-\(code)", gsURL)
            }
            report.warn("GEOIP,\(code) 无对应规则集,已跳过该规则。")
            return nil
        }
    }

    private func probe(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 12
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: 组装(Nest 模板)

    private func assemble(nodes: [[String: Any]],
                          extraDNSServers: [[String: Any]] = [],
                          groups: [[String: Any]],
                          routeRules: [[String: Any]],
                          ruleSets: [[String: Any]],
                          finalOutbound: String,
                          globalGroup: [String: Any]?,
                          globalTag: String) -> [String: Any] {
        var outbounds: [[String: Any]] = []
        // GLOBAL 置顶:全局模式下用户来组页第一眼就能选出口
        if let globalGroup { outbounds.append(globalGroup) }
        outbounds.append(contentsOf: groups)
        outbounds.append(contentsOf: nodes)
        outbounds.append(["type": "direct", "tag": "direct"])

        // clash_mode 规则刻意放在 ip_is_private 之后:任何模式下局域网都保持直连
        var routeRuleList: [[String: Any]] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
            ["ip_is_private": true, "outbound": "direct"],
            ["clash_mode": "Direct", "outbound": "direct"],
            ["clash_mode": "Global", "outbound": globalTag]
        ]
        routeRuleList.append(contentsOf: routeRules)

        var route: [String: Any] = [
            "rules": routeRuleList,
            "final": finalOutbound,
            "auto_detect_interface": true,
            "default_domain_resolver": ["server": "dns-direct"]
        ]
        if !ruleSets.isEmpty { route["rule_set"] = ruleSets }

        var dnsServers: [[String: Any]] = [
            ["tag": "fake", "type": "fakeip", "inet4_range": "198.18.0.0/15"],
            ["tag": "dns-direct", "type": "udp", "server": "223.5.5.5"]
        ]
        // 机场私有 DoH 解析器:仅供命中机场域名的节点(经 outbound.domain_resolver)解析服务器地址
        dnsServers.append(contentsOf: extraDNSServers)

        let dns: [String: Any] = [
            "servers": dnsServers,
            "rules": [
                // 直连模式整体切真实 IP,绕开 fakeip 回源路径;全局模式 CN 域名也走 fakeip→代理。
                // Direct 规则必须带 rewrite_ttl=1:明文国内 DNS 对被墙域名返回污染 IP,若按原始
                // TTL 缓存,切回规则模式后 App 仍连污染 IP,间歇性失败直到过期。
                ["clash_mode": "Direct", "server": "dns-direct", "rewrite_ttl": 1],
                ["clash_mode": "Global", "query_type": ["A", "AAAA"], "server": "fake", "rewrite_ttl": 1],
                ["rule_set": ["geosite-geolocation-cn"], "server": "dns-direct"],
                ["query_type": ["A", "AAAA"], "server": "fake", "rewrite_ttl": 1]
            ],
            "final": "dns-direct",
            "strategy": "ipv4_only"
        ]

        let inbounds: [[String: Any]] = [[
            "type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"],
            "auto_route": true, "strict_route": true, "stack": "system"
        ]]

        // clash_api:模式列表 = default_mode + 规则里出现的 clash_mode 值(Rule/Global/Direct);
        // external_controller 留空 → 只建模式管理,不开 HTTP 监听。
        // cache_file:持久化模式 + selector 选点 + fakeip 映射(跨 VPN/App 重启保持)。
        let experimental: [String: Any] = [
            "clash_api": ["default_mode": "Rule"],
            "cache_file": ["enabled": true, "store_fakeip": true]
        ]

        return [
            "log": ["level": "info", "timestamp": true],
            "dns": dns,
            "inbounds": inbounds,
            "outbounds": outbounds,
            "route": route,
            "experimental": experimental
        ]
    }

    // MARK: 校验

    private func validate(_ config: [String: Any]) -> [String] {
        var errs: [String] = []
        guard let outbounds = config["outbounds"] as? [[String: Any]] else {
            return ["缺少 outbounds"]
        }
        let tags = outbounds.compactMap { $0["tag"] as? String }
        let tagSet = Set(tags)
        if tags.count != tagSet.count { errs.append("存在重复的 outbound tag") }

        // 组成员引用
        for ob in outbounds {
            guard let type = ob["type"] as? String, type == "selector" || type == "urltest" else { continue }
            let tag = (ob["tag"] as? String) ?? "?"
            let members = (ob["outbounds"] as? [String]) ?? []
            for m in members where !tagSet.contains(m) {
                errs.append("组「\(tag)」引用了不存在的成员「\(m)」")
            }
            if type == "selector", let def = ob["default"] as? String, !members.contains(def) {
                errs.append("组「\(tag)」default「\(def)」不在成员内")
            }
            if members.contains(tag) { errs.append("组「\(tag)」自引用") }
        }

        // route.final / rule outbound / rule_set 引用
        if let route = config["route"] as? [String: Any] {
            if let f = route["final"] as? String, !tagSet.contains(f) {
                errs.append("route.final「\(f)」不存在")
            }
            let ruleSetTags = Set(((route["rule_set"] as? [[String: Any]]) ?? []).compactMap { $0["tag"] as? String })
            if let rules = route["rules"] as? [[String: Any]] {
                for r in rules {
                    if let o = r["outbound"] as? String, !tagSet.contains(o) {
                        errs.append("规则 outbound「\(o)」不存在")
                    }
                    if let rs = r["rule_set"] as? [String] {
                        for t in rs where !ruleSetTags.contains(t) {
                            errs.append("规则引用了未注册的 rule_set「\(t)」")
                        }
                    }
                }
            }
        }
        return errs
    }

    // MARK: 图标

    private func extractIcons(_ clashGroups: [YAMLValue]) -> [String: String] {
        var icons: [String: String] = [:]
        for g in clashGroups {
            if let name = g["name"]?.string, let icon = g["icon"]?.string, !icon.isEmpty {
                icons[name] = icon
            }
        }
        return icons
    }

    // MARK: 工具

    private func formatInterval(_ raw: String) -> String {
        // Clash interval 通常是秒数(整数);已是时长串则原样返回
        if raw.allSatisfy(\.isNumber) { return "\(raw)s" }
        return raw
    }

    // MARK: 机场私有 DNS 平移(节点服务器域名解析)

    private struct NodeDNSResolvers {
        var servers: [[String: Any]] = []
        var suffixTags: [(suffix: String, tag: String)] = []

        /// 服务器域名命中某个机场后缀 → 返回对应 DoH 解析器 tag。
        func tag(forServerDomain server: String) -> String? {
            let host = server.lowercased()
            for st in suffixTags where host == st.suffix || host.hasSuffix("." + st.suffix) {
                return st.tag
            }
            return nil
        }
    }

    /// 从机场 nameserver-policy 里挑出“节点域名 → 加密 DoH”的映射,构造 sing-box DoH 解析器,
    /// 并给出“域名后缀 → 解析器 tag”的对应表。相同上游只建一个解析器(按 server 列表去重)。
    private func buildNodeDomainResolvers(policy: [PassthroughDNS.PolicyEntry]) -> NodeDNSResolvers {
        var result = NodeDNSResolvers()
        var signatureToTag: [String: String] = [:]
        var index = 0
        for entry in policy {
            // 只取节点域名类 key,排除 geosite:/geoip:/rule-set: 等特殊选择器
            guard !entry.key.contains(":") else { continue }
            let suffix = Self.normalizedDomainSuffix(entry.key)
            guard !suffix.isEmpty else { continue }
            // 仅采用带 scheme 的加密上游(DoH 等);纯 IP / system 对绕过污染无意义
            let encrypted = entry.servers.filter { $0.contains("://") }
            guard let primary = encrypted.first else { continue }
            let signature = encrypted.joined(separator: "|")
            let tag: String
            if let existing = signatureToTag[signature] {
                tag = existing
            } else {
                guard let server = Self.makeDoHServer(urlString: primary, tag: "dns-node-\(index)") else { continue }
                tag = server["tag"] as! String
                signatureToTag[signature] = tag
                result.servers.append(server)
                index += 1
            }
            result.suffixTags.append((suffix, tag))
        }
        return result
    }

    private static func normalizedDomainSuffix(_ key: String) -> String {
        var s = key.lowercased()
        for prefix in ["*.", "+.", "."] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        return s
    }

    /// 把一个 DoH URL 转成 sing-box 1.12 的 https DNS server。
    /// - domain_resolver: 用明文直连解析器 bootstrap 自身域名。
    /// 不设 detour:空 direct 出站本就是默认直连,sing-box 1.12 会拒绝“detour 到空 direct 出站”
    /// (报 "detour to an empty direct outbound makes no sense"),省略即走直连,正是所需。
    private static func makeDoHServer(urlString: String, tag: String) -> [String: Any]? {
        guard let comps = URLComponents(string: urlString), let host = comps.host else { return nil }
        var server: [String: Any] = [
            "type": "https",
            "tag": tag,
            "server": host,
            "domain_resolver": ["server": "dns-direct"]
        ]
        if let port = comps.port { server["server_port"] = port }
        if !comps.path.isEmpty && comps.path != "/" { server["path"] = comps.path }
        return server
    }
}
