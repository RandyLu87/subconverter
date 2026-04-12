import Foundation

struct ProxyField: Hashable {
    var key: String
    var value: String
}

struct ProxyEntry: Hashable, Identifiable {
    let id = UUID()
    var fields: [ProxyField]

    var name: String {
        get { value(for: "name") ?? "Unnamed Proxy" }
        set { setValue(newNameLiteral(newValue), for: "name") }
    }

    var signature: String {
        fields
            .filter { $0.key != "name" }
            .map { "\($0.key)=\($0.value.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "|")
    }

    func renderedLine() -> String {
        let renderedFields = fields.map { field -> String in
            if field.key == "name" {
                return "name: \(newNameLiteral(name))"
            }
            return "\(field.key): \(field.value)"
        }

        return "  - {\(renderedFields.joined(separator: ", "))}"
    }

    private func value(for key: String) -> String? {
        guard let value = fields.first(where: { $0.key == key })?.value else {
            return nil
        }
        return Self.unquote(value)
    }

    private mutating func setValue(_ value: String, for key: String) {
        if let index = fields.firstIndex(where: { $0.key == key }) {
            fields[index].value = value
            return
        }

        fields.insert(ProxyField(key: key, value: value), at: 0)
    }

    private func newNameLiteral(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    static func unquote(_ value: String) -> String {
        guard value.count >= 2 else {
            return value
        }

        if (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
            return String(value.dropFirst().dropLast())
        }

        return value
    }
}

enum ProxyListParser {
    static func parse(_ raw: String) throws -> [ProxyEntry] {
        let lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "proxies:" else {
            throw ProxyListParserError.invalidRoot
        }

        var entries: [ProxyEntry] = []
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- {"), trimmed.hasSuffix("}") else {
                continue
            }

            let startIndex = trimmed.index(trimmed.startIndex, offsetBy: 3)
            let endIndex = trimmed.index(before: trimmed.endIndex)
            let body = String(trimmed[startIndex..<endIndex])
            let segments = splitTopLevel(body, separator: ",")
            var fields: [ProxyField] = []
            for segment in segments {
                let parts = splitOnce(segment, separator: ":")
                guard parts.count == 2 else {
                    throw ProxyListParserError.invalidProxyLine(segment)
                }

                fields.append(
                    ProxyField(
                        key: parts[0].trimmingCharacters(in: .whitespaces),
                        value: parts[1].trimmingCharacters(in: .whitespaces)
                    )
                )
            }

            entries.append(ProxyEntry(fields: fields))
        }

        if entries.isEmpty {
            throw ProxyListParserError.noProxyEntries
        }

        return entries
    }

    private static func splitTopLevel(_ input: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var braceDepth = 0
        var bracketDepth = 0
        var inQuotes = false
        var quoteCharacter: Character?
        var escaping = false

        for character in input {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }

            if character == "\\" {
                current.append(character)
                escaping = true
                continue
            }

            if inQuotes {
                current.append(character)
                if character == quoteCharacter {
                    inQuotes = false
                    quoteCharacter = nil
                }
                continue
            }

            switch character {
            case "\"", "'":
                inQuotes = true
                quoteCharacter = character
                current.append(character)
            case "{":
                braceDepth += 1
                current.append(character)
            case "}":
                braceDepth -= 1
                current.append(character)
            case "[":
                bracketDepth += 1
                current.append(character)
            case "]":
                bracketDepth -= 1
                current.append(character)
            default:
                if character == separator && braceDepth == 0 && bracketDepth == 0 {
                    result.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(character)
                }
            }
        }

        if !current.isEmpty {
            result.append(current.trimmingCharacters(in: .whitespaces))
        }

        return result
    }

    private static func splitOnce(_ input: String, separator: Character) -> [String] {
        var braceDepth = 0
        var bracketDepth = 0
        var inQuotes = false
        var quoteCharacter: Character?
        var escaping = false

        for (index, character) in input.enumerated() {
            if escaping {
                escaping = false
                continue
            }

            if character == "\\" {
                escaping = true
                continue
            }

            if inQuotes {
                if character == quoteCharacter {
                    inQuotes = false
                    quoteCharacter = nil
                }
                continue
            }

            switch character {
            case "\"", "'":
                inQuotes = true
                quoteCharacter = character
            case "{":
                braceDepth += 1
            case "}":
                braceDepth -= 1
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth -= 1
            default:
                if character == separator && braceDepth == 0 && bracketDepth == 0 {
                    let left = input[..<input.index(input.startIndex, offsetBy: index)]
                    let right = input[input.index(after: input.index(input.startIndex, offsetBy: index))...]
                    return [String(left), String(right)]
                }
            }
        }

        return [input]
    }
}

enum ProxyListParserError: LocalizedError {
    case invalidRoot
    case invalidProxyLine(String)
    case noProxyEntries

    var errorDescription: String? {
        switch self {
        case .invalidRoot:
            return "The generated proxy list is not valid Clash proxy YAML."
        case .invalidProxyLine(let line):
            return "Unable to parse proxy line: \(line)"
        case .noProxyEntries:
            return "No valid proxy entries were found."
        }
    }
}
