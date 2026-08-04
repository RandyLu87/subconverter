import Foundation

enum ProxyGroupIconCatalog {
    // Extracted from the sample Clash YAML provided by the user.
    // Served over the jsDelivr GitHub CDN rather than raw.githubusercontent.com:
    // raw is often blocked/throttled on CN networks and from shared airport exit IPs.
    static let proxy = "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/icon/qure/color/Proxy.png"
    static let ai = "https://cdn.jsdelivr.net/gh/HotKids/Rules@master/Quantumult/X/Images/Color/ChatGPT.png"
    static let claudeCode = "https://cdn.jsdelivr.net/gh/lobehub/lobe-icons@8466f33c37a37f1c4df47938627ef2f52f192b36/packages/static-png/light/claudecode-color.png"
    static let gemini = "https://cdn.jsdelivr.net/gh/lobehub/lobe-icons@8466f33c37a37f1c4df47938627ef2f52f192b36/packages/static-png/light/gemini-color.png"
    static let google = "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/icon/qure/color/Google.png"
    static let crypto = "https://www.naiixi.com/Crypto.png"
    // apple/youtube/netflix used to point at HotKids `Images/Icons/`, which no longer
    // exists upstream (404 on raw as well) — repointed at paths that actually resolve.
    static let apple = "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/icon/qure/color/Apple.png"
    static let youtube = "https://cdn.jsdelivr.net/gh/HotKids/Rules@master/Quantumult/X/Images/Color/YouTube.png"
    static let netflix = "https://cdn.jsdelivr.net/gh/HotKids/Rules@master/Quantumult/X/Images/Color/Netflix.png"
    static let steam = "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/icon/qure/color/Steam.png"
    // Supercell / ClashRoyale 图标在 blackmatrix7、HotKids、Koolson/Qure、
    // dashboard-icons 四个源里都是 404,所以自托管在本仓库 assets/icons/ 下。
    // 按 commit SHA 固定,避免 @main 的 CDN 缓存漂移(与上面 lobe-icons 同做法)。
    static let supercell = "https://cdn.jsdelivr.net/gh/RandyLu87/subconverter@2e3ac776ef3d3e02acf50ee6db4abe0f6b43d149/assets/icons/supercell.png"
    static let futu = "https://cdn.jsdelivr.net/gh/lxfcx/QuanX-icon-rule@main/icon/futunn.png"
    static let lark = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@main/png/lark.png"
    static let github = "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/icon/qure/color/GitHub.png"
    static let telegram = "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/icon/qure/color/Telegram.png"
    static let x = "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/icon/qure/color/Twitter.png"
    static let final = "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/icon/qure/color/Final.png"
}

enum CountryBucket: CaseIterable {
    case hongKong
    case unitedStates
    case singapore
    case japan
    case taiwan
    case korea
    case unitedKingdom
    case india
    case other

    var groupName: String {
        switch self {
        case .hongKong:
            return "🇭🇰 Hong Kong Auto"
        case .unitedStates:
            return "🇺🇸 United States Auto"
        case .singapore:
            return "🇸🇬 Singapore Auto"
        case .japan:
            return "🇯🇵 Japan Auto"
        case .taiwan:
            return "🇹🇼 Taiwan Auto"
        case .korea:
            return "🇰🇷 Korea Auto"
        case .unitedKingdom:
            return "🇬🇧 United Kingdom Auto"
        case .india:
            return "🇮🇳 India Auto"
        case .other:
            return "🌍 Other Countries Auto"
        }
    }

    var iconURL: String {
        switch self {
        case .hongKong:
            return "https://flagcdn.com/w80/hk.png"
        case .unitedStates:
            return "https://flagcdn.com/w80/us.png"
        case .singapore:
            return "https://flagcdn.com/w80/sg.png"
        case .japan:
            return "https://flagcdn.com/w80/jp.png"
        case .taiwan:
            return "https://flagcdn.com/w80/tw.png"
        case .korea:
            return "https://flagcdn.com/w80/kr.png"
        case .unitedKingdom:
            return "https://flagcdn.com/w80/gb.png"
        case .india:
            return "https://flagcdn.com/w80/in.png"
        case .other:
            return ProxyGroupIconCatalog.proxy
        }
    }

    fileprivate var patterns: [String] {
        switch self {
        case .hongKong:
            return ["🇭🇰", "hong\\s*kong", "hongkong", "香港", "(?:^|[^a-z])hk(?:[^a-z]|$)"]
        case .unitedStates:
            return ["🇺🇸", "united\\s*states", "usa", "los\\s*angeles", "san\\s*jose", "seattle", "america", "美国"]
        case .singapore:
            return ["🇸🇬", "singapore", "新加坡"]
        case .japan:
            return ["🇯🇵", "japan", "日本", "tokyo", "osaka"]
        case .taiwan:
            return ["🇹🇼", "taiwan", "台湾", "台灣", "taipei"]
        case .korea:
            return ["🇰🇷", "korea", "韩国", "韓國", "首尔", "首爾", "seoul"]
        case .unitedKingdom:
            return ["🇬🇧", "united\\s*kingdom", "(?:^|[^a-z])uk(?:[^a-z]|$)", "england", "london", "英国"]
        case .india:
            return ["🇮🇳", "india", "印度", "mumbai", "delhi", "bangalore"]
        case .other:
            return []
        }
    }
}

enum ProxyCountryClassifier {
    static func bucketed(names: [String]) -> [CountryBucket: [String]] {
        var result: [CountryBucket: [String]] = [:]

        for bucket in CountryBucket.allCases {
            result[bucket] = []
        }

        for name in names {
            result[bucket(for: name), default: []].append(name)
        }

        return result
    }

    static func bucket(for name: String) -> CountryBucket {
        let normalized = name.lowercased()
        if isBritishIndianOceanTerritory(normalized) {
            return .other
        }
        for bucket in CountryBucket.allCases where bucket != .other {
            if bucket.patterns.contains(where: { normalized.range(of: $0, options: .regularExpression) != nil }) {
                return bucket
            }
        }

        return .other
    }

    static func summary(for buckets: [CountryBucket: [String]]) -> String {
        CountryBucket.allCases
            .map { "\($0.groupName)=\(buckets[$0, default: []].count)" }
            .joined(separator: ", ")
    }

    private static func isBritishIndianOceanTerritory(_ normalized: String) -> Bool {
        let exclusionPatterns = [
            "british\\s*indian\\s*ocean\\s*territory",
            "英属印度洋领地",
            "diego\\s*garcia",
            "迪戈加西亚"
        ]
        return exclusionPatterns.contains { normalized.range(of: $0, options: .regularExpression) != nil }
    }
}
