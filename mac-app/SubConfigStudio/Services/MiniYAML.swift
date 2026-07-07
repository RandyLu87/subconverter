import Foundation

/// 极简块式 YAML 解析器,面向 Clash / Clash.Meta 机器生成的配置。
/// 只覆盖本项目转换所需:块映射、块序列、标量(含引号)、行内 flow `[...]` / `{...}`。
/// 不支持锚点、块标量(`|`/`>`)、复杂多文档等——Clash 配置用不到。
indirect enum YAMLValue {
    case scalar(String)
    case sequence([YAMLValue])
    case mapping([(key: String, value: YAMLValue)])

    var string: String? {
        if case let .scalar(s) = self { return s }
        return nil
    }

    var sequenceValues: [YAMLValue]? {
        if case let .sequence(v) = self { return v }
        return nil
    }

    /// 序列里全部标量取字符串;单标量也宽容返回 [自身]。
    var stringArray: [String]? {
        switch self {
        case let .sequence(v):
            return v.compactMap { $0.string }
        case let .scalar(s):
            return [s]
        default:
            return nil
        }
    }

    subscript(key: String) -> YAMLValue? {
        if case let .mapping(entries) = self {
            return entries.first { $0.key == key }?.value
        }
        return nil
    }

    var mappingEntries: [(key: String, value: YAMLValue)]? {
        if case let .mapping(e) = self { return e }
        return nil
    }
}

enum MiniYAMLError: LocalizedError {
    case empty
    var errorDescription: String? {
        switch self {
        case .empty: return "YAML 内容为空或无法解析。"
        }
    }
}

enum MiniYAML {
    static func parse(_ text: String) throws -> YAMLValue {
        var lines: [(indent: Int, text: String)] = []
        for rawSub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawSub)
            if line.hasSuffix("\r") { line.removeLast() }
            let indent = line.prefix { $0 == " " }.count
            let content = String(line.dropFirst(indent))
            if content.isEmpty { continue }
            if content.hasPrefix("#") { continue }
            if content == "---" || content == "..." { continue }
            lines.append((indent, content))
        }
        guard !lines.isEmpty else { throw MiniYAMLError.empty }
        var parser = BlockParser(lines: lines)
        return parser.parseBlock()
    }

    // MARK: - Block parser

    private struct BlockParser {
        var lines: [(indent: Int, text: String)]
        var i = 0

        mutating func parseBlock() -> YAMLValue {
            guard i < lines.count else { return .scalar("") }
            let text = lines[i].text
            if text == "-" || text.hasPrefix("- ") {
                return parseSequence(indent: lines[i].indent)
            }
            return parseMapping(indent: lines[i].indent)
        }

        mutating func parseMapping(indent: Int) -> YAMLValue {
            var entries: [(key: String, value: YAMLValue)] = []
            while i < lines.count {
                let (curIndent, text) = lines[i]
                if curIndent != indent { break }
                guard let colon = colonIndex(in: text) else { break }
                let key = unquote(String(text[..<colon]).trimmingCharacters(in: .whitespaces))
                let after = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                i += 1
                if after.isEmpty {
                    if i < lines.count, lines[i].indent > indent {
                        entries.append((key, parseBlock()))
                    } else {
                        entries.append((key, .scalar("")))
                    }
                } else {
                    entries.append((key, parseInline(after)))
                }
            }
            return .mapping(entries)
        }

        mutating func parseSequence(indent: Int) -> YAMLValue {
            var items: [YAMLValue] = []
            while i < lines.count {
                let (curIndent, text) = lines[i]
                if curIndent != indent { break }
                guard text == "-" || text.hasPrefix("- ") else { break }
                let content = text == "-" ? "" : String(text.dropFirst(2))
                if content.isEmpty {
                    i += 1
                    if i < lines.count, lines[i].indent > indent {
                        items.append(parseBlock())
                    } else {
                        items.append(.scalar(""))
                    }
                } else if isMapEntry(content) {
                    // 序列项是映射:把 "- k: v" 改写成缩进后的映射首行,交给 parseMapping 连带后续对齐行。
                    lines[i] = (indent + 2, content)
                    items.append(parseMapping(indent: indent + 2))
                } else {
                    i += 1
                    items.append(parseInline(content))
                }
            }
            return .sequence(items)
        }

        // MARK: helpers

        /// 判断 "key: value" 形态(冒号后跟空格或到行尾),用于区分映射项 vs 含冒号的标量(如 IPv6 规则)。
        private func isMapEntry(_ s: String) -> Bool {
            if s.hasPrefix("[") || s.hasPrefix("{") { return false }
            return colonIndex(in: s) != nil
        }

        /// 找到顶层 "key:" 的冒号位置:冒号后是空格或行尾,且不在引号/括号内。
        private func colonIndex(in s: String) -> String.Index? {
            var inQuote: Character?
            var depth = 0
            var idx = s.startIndex
            while idx < s.endIndex {
                let c = s[idx]
                if let q = inQuote {
                    if c == q { inQuote = nil }
                } else if c == "\"" || c == "'" {
                    inQuote = c
                } else if c == "[" || c == "{" {
                    depth += 1
                } else if c == "]" || c == "}" {
                    depth -= 1
                } else if c == ":" && depth == 0 {
                    let next = s.index(after: idx)
                    if next == s.endIndex || s[next] == " " {
                        return idx
                    }
                }
                idx = s.index(after: idx)
            }
            return nil
        }

        private func parseInline(_ raw: String) -> YAMLValue {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("[") && s.hasSuffix("]") {
                let inner = String(s.dropFirst().dropLast())
                if inner.trimmingCharacters(in: .whitespaces).isEmpty { return .sequence([]) }
                return .sequence(splitTopLevel(inner).map { parseInline($0) })
            }
            if s.hasPrefix("{") && s.hasSuffix("}") {
                let inner = String(s.dropFirst().dropLast())
                var entries: [(key: String, value: YAMLValue)] = []
                for part in splitTopLevel(inner) {
                    if let colon = colonIndex(in: part) {
                        let key = unquote(String(part[..<colon]).trimmingCharacters(in: .whitespaces))
                        let val = String(part[part.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                        entries.append((key, parseInline(val)))
                    }
                }
                return .mapping(entries)
            }
            return .scalar(unquote(s))
        }

        private func splitTopLevel(_ s: String) -> [String] {
            var result: [String] = []
            var current = ""
            var inQuote: Character?
            var depth = 0
            for c in s {
                if let q = inQuote {
                    current.append(c)
                    if c == q { inQuote = nil }
                    continue
                }
                switch c {
                case "\"", "'": inQuote = c; current.append(c)
                case "[", "{": depth += 1; current.append(c)
                case "]", "}": depth -= 1; current.append(c)
                case "," where depth == 0:
                    result.append(current.trimmingCharacters(in: .whitespaces)); current = ""
                default: current.append(c)
                }
            }
            let last = current.trimmingCharacters(in: .whitespaces)
            if !last.isEmpty { result.append(last) }
            return result
        }

        private func unquote(_ v: String) -> String {
            guard v.count >= 2 else { return v }
            if (v.first == "\"" && v.last == "\"") || (v.first == "'" && v.last == "'") {
                return String(v.dropFirst().dropLast())
            }
            return v
        }
    }
}
