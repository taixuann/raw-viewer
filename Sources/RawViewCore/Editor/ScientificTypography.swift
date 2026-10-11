import Foundation

/// Fast, deterministic formatting engine that transforms scientific shorthands,
/// LaTeX commands, Greek names, and power/subscript annotations into publication-grade Unicode.
public enum ScientificTypography {

    private static let superscriptMap: [Character: Character] = [
        "-": "⁻",
        "+": "⁺",
        "0": "⁰",
        "1": "¹",
        "2": "²",
        "3": "³",
        "4": "⁴",
        "5": "⁵",
        "6": "⁶",
        "7": "⁷",
        "8": "⁸",
        "9": "⁹",
        "n": "ⁿ",
        "i": "ⁱ"
    ]

    private static let subscriptMap: [Character: Character] = [
        "0": "₀",
        "1": "₁",
        "2": "₂",
        "3": "₃",
        "4": "₄",
        "5": "₅",
        "6": "₆",
        "7": "₇",
        "8": "₈",
        "9": "₉",
        "+": "₊",
        "-": "₋",
        "a": "ₐ",
        "e": "ₑ",
        "i": "ᵢ",
        "o": "ₒ",
        "p": "ₚ",
        "r": "ᵣ",
        "t": "ₜ",
        "x": "ₓ",
        "y": "ᵧ"
    ]

    /// Categorized standard units for combo-box selections and quick pickers.
    public static let unitCategories: [(category: String, units: [String])] = [
        ("Electrical / Electrochemistry", [
            "V", "mV", "μV", "A", "mA", "μA", "nA", "pA",
            "Ω", "kΩ", "MΩ", "S", "mS", "μS",
            "F", "μF", "nF", "pF", "C", "μC"
        ]),
        ("Areal & Specific Density", [
            "mA/cm²", "μA/cm²", "A/m²", "F/g", "mAh/g", "Wh/kg", "mW/cm²"
        ]),
        ("Spectroscopy & Optics", [
            "cm⁻¹", "nm", "μm", "eV", "meV", "a.u.", "counts", "cps"
        ]),
        ("Time, Frequency & Scan Rate", [
            "s", "ms", "μs", "ns", "min", "h", "Hz", "kHz", "MHz", "GHz",
            "V/s", "mV/s", "°C/min"
        ]),
        ("Thermodynamic & Chemical", [
            "°C", "K", "M", "mM", "μM", "nM", "ppm", "ppb", "pH",
            "bar", "mbar", "Pa", "kPa", "Torr", "atm",
            "J", "kJ", "W", "mW", "μW"
        ]),
        ("Dimensionless & Progression", [
            "", "%", "count", "cycle", "scan", "step"
        ])
    ]

    /// Formats a raw input string into publication-ready scientific Unicode.
    public static func format(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var result = raw

        // 1. Explicit LaTeX backslash commands
        let latexCommands: [(String, String)] = [
            ("\\AA", "Å"),
            ("\\degC", "°C"),
            ("\\degF", "°F"),
            ("\\deg", "°"),
            ("\\ohm", "Ω"),
            ("\\Omega", "Ω"),
            ("\\omega", "ω"),
            ("\\mu", "μ"),
            ("\\micro", "μ"),
            ("\\alpha", "α"),
            ("\\beta", "β"),
            ("\\gamma", "γ"),
            ("\\Gamma", "Γ"),
            ("\\delta", "δ"),
            ("\\Delta", "Δ"),
            ("\\epsilon", "ε"),
            ("\\theta", "θ"),
            ("\\Theta", "Θ"),
            ("\\lambda", "λ"),
            ("\\Lambda", "Λ"),
            ("\\pi", "π"),
            ("\\Pi", "Π"),
            ("\\sigma", "σ"),
            ("\\Sigma", "Σ"),
            ("\\phi", "φ"),
            ("\\Phi", "Φ"),
            ("\\times", "×"),
            ("\\pm", "±"),
            ("\\leq", "≤"),
            ("\\geq", "≥"),
            ("\\approx", "≈"),
            ("\\neq", "≠")
        ]
        for (cmd, repl) in latexCommands {
            result = result.replacingOccurrences(of: cmd, with: repl)
        }

        // 2. Named temperature & length tokens
        result = result.replacingOccurrences(of: "degC", with: "°C")
        result = result.replacingOccurrences(of: "degF", with: "°F")
        result = replaceWord(in: result, target: "deg", with: "°")
        result = result.replacingOccurrences(of: "Angstrom", with: "Å")
        result = result.replacingOccurrences(of: "angstrom", with: "Å")

        // 3. Greek letter shorthands with word boundaries
        let namedWords: [(String, String)] = [
            ("alpha", "α"),
            ("Alpha", "Α"),
            ("beta", "β"),
            ("Beta", "Β"),
            ("gamma", "γ"),
            ("Gamma", "Γ"),
            ("delta", "δ"),
            ("Delta", "Δ"),
            ("theta", "θ"),
            ("Theta", "Θ"),
            ("lambda", "λ"),
            ("Lambda", "Λ"),
            ("sigma", "σ"),
            ("Sigma", "Σ"),
            ("omega", "ω"),
            ("Omega", "Ω")
        ]
        for (word, sym) in namedWords {
            result = replaceWord(in: result, target: word, with: sym)
        }

        // 4. Ohm and metric Ohm shorthands
        result = replaceWord(in: result, target: "ohm", with: "Ω")
        result = replaceWord(in: result, target: "Ohm", with: "Ω")
        result = replaceWord(in: result, target: "kohm", with: "kΩ")
        result = replaceWord(in: result, target: "Mohm", with: "MΩ")
        result = replaceWord(in: result, target: "mohm", with: "mΩ")
        result = replaceWord(in: result, target: "Gohm", with: "GΩ")
        result = replaceWord(in: result, target: "uohm", with: "μΩ")
        result = replaceWord(in: result, target: "muohm", with: "μΩ")

        // 5. Micro prefixes: "mu", "u" with unit letters
        result = replaceWord(in: result, target: "mu", with: "μ")
        result = replaceWord(in: result, target: "micro", with: "μ")
        let microUnits: [(String, String)] = [
            ("uA", "μA"),
            ("muA", "μA"),
            ("um", "μm"),
            ("mum", "μm"),
            ("us", "μs"),
            ("mus", "μs"),
            ("uV", "μV"),
            ("muV", "μV"),
            ("uF", "μF"),
            ("muF", "μF"),
            ("uL", "μL"),
            ("muL", "μL"),
            ("uM", "μM"),
            ("muM", "μM"),
            ("ug", "μg"),
            ("mug", "μg"),
            ("uW", "μW"),
            ("muW", "μW"),
            ("uC", "μC"),
            ("muC", "μC")
        ]
        for (token, repl) in microUnits {
            result = replaceWord(in: result, target: token, with: repl)
        }

        // 6. Superscript powers: ^{...} or ^(-N) or ^N
        result = replacePowerSuperscripts(in: result)

        // 7. Subscripts: _{...} or _N or _letter
        result = replaceSubscripts(in: result)

        return result
    }

    private static func replaceWord(in text: String, target: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?<![a-zA-Z0-9])\(NSRegularExpression.escapedPattern(for: target))(?![a-zA-Z0-9])") else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private static func replacePowerSuperscripts(in text: String) -> String {
        // Match patterns like ^{...} or ^-1 or ^2
        guard let regex = try? NSRegularExpression(pattern: "\\^\\{?([\\+\\-]?[0-9a-zA-Z]+)\\}?") else {
            return text
        }
        let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
        guard !matches.isEmpty else { return text }

        var output = text
        // Process in reverse to maintain indices
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let matchRange = Range(match.range(at: 0), in: output),
                  let groupRange = Range(match.range(at: 1), in: output) else { continue }

            let powerStr = String(output[groupRange])
            var superStr = ""
            var allMapped = true
            for ch in powerStr {
                if let mapped = superscriptMap[ch] {
                    superStr.append(mapped)
                } else {
                    allMapped = false
                    break
                }
            }
            if allMapped && !superStr.isEmpty {
                output.replaceSubrange(matchRange, with: superStr)
            }
        }
        return output
    }

    private static func replaceSubscripts(in text: String) -> String {
        // Match patterns like _{...} or _0 or _p
        guard let regex = try? NSRegularExpression(pattern: "_\\{?([0-9a-zA-Z\\+\\-]+)\\}?") else {
            return text
        }
        let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
        guard !matches.isEmpty else { return text }

        var output = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let matchRange = Range(match.range(at: 0), in: output),
                  let groupRange = Range(match.range(at: 1), in: output) else { continue }

            let subStr = String(output[groupRange])
            var converted = ""
            var allMapped = true
            for ch in subStr {
                if let mapped = subscriptMap[ch] {
                    converted.append(mapped)
                } else {
                    allMapped = false
                    break
                }
            }
            if allMapped && !converted.isEmpty {
                output.replaceSubrange(matchRange, with: converted)
            }
        }
        return output
    }
}
