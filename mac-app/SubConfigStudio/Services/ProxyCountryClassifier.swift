import Foundation

enum ProxyGroupIconCatalog {
    // Extracted from the sample Clash YAML provided by the user.
    static let proxy = "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/icon/qure/color/Proxy.png"
    static let ai = "https://raw.githubusercontent.com/HotKids/Rules/master/Quantumult/X/Images/Color/ChatGPT.png"
    static let claudeCode = "https://raw.githubusercontent.com/lobehub/lobe-icons/8466f33c37a37f1c4df47938627ef2f52f192b36/packages/static-png/light/claudecode-color.png"
    static let gemini = "https://raw.githubusercontent.com/lobehub/lobe-icons/8466f33c37a37f1c4df47938627ef2f52f192b36/packages/static-png/light/gemini-color.png"
    static let crypto = "https://www.naiixi.com/Crypto.png"
    static let youtube = "https://raw.githubusercontent.com/HotKids/Rules/master/Quantumult/X/Images/Icons/YouTube.png"
    static let netflix = "https://raw.githubusercontent.com/HotKids/Rules/master/Quantumult/X/Images/Icons/Netflix.png"
    static let final = "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/icon/qure/color/Final.png"
}

enum CountryBucket: CaseIterable {
    case hongKong
    case unitedStates
    case singapore
    case japan
    case taiwan
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
            return ["🇹🇼", "taiwan", "台湾", "taipei"]
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
}
