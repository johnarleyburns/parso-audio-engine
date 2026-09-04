//
//  RoBERTaTokenizer.swift
//  RoBERTa byte-level BPE tokenizer (the CLAP text encoder's tokenizer).
//  Ported from parso-tonearm/Sources/DJ/Semantic/RoBERTaTokenizer.swift.
//  See ATTRIBUTION.md. Pure and deterministic; no CoreML dependency, so this
//  file is not watchOS-gated (only Semantic.swift's model plumbing is).
//
import Foundation

/// Reproduces `transformers.RobertaTokenizer` (GPT-2-style) for a bundled
/// `vocab.json`/`merges.txt`.
public struct RoBERTaTokenizer: Sendable {

    public static let bosID = 0   // <s>
    public static let padID = 1   // <pad>
    public static let eosID = 2   // </s>
    public static let unkID = 3   // <unk>

    /// Byte-encoded token string -> vocab id.
    public let vocab: [String: Int]
    /// "left right" -> merge rank (lower = earlier in `merges.txt`).
    public let merges: [String: Int]
    /// byte -> the single Unicode scalar GPT-2 uses to represent it in a token.
    private let byteEncoder: [Int: Unicode.Scalar]

    public init(vocabURL: URL, mergesURL: URL) throws {
        let vocabData = try Data(contentsOf: vocabURL)
        let raw = try JSONDecoder().decode([String: Int].self, from: vocabData)
        vocab = raw

        let mergesText = try String(contentsOf: mergesURL, encoding: .utf8)
        var ranked: [String: Int] = [:]
        for (index, line) in mergesText.split(separator: "\n").enumerated()
        where !line.isEmpty {
            ranked[String(line)] = index
        }
        merges = ranked
        byteEncoder = Self.gpt2ByteEncoder()
    }

    /// GPT-2's byte-to-unicode table: printable ASCII and Latin-1 that look
    /// sane map to themselves; every other byte maps to a fresh scalar above
    /// U+0100 (so e.g. space -> U+0120 "Ġ").
    private static func gpt2ByteEncoder() -> [Int: Unicode.Scalar] {
        var bs = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs.map { UInt32($0) }
        var counter: UInt32 = 0
        for byte in 0...255 where !bs.contains(byte) {
            bs.append(byte)
            cs.append(256 + counter)
            counter += 1
        }
        var table: [Int: Unicode.Scalar] = [:]
        for (b, c) in zip(bs, cs) {
            if let scalar = Unicode.Scalar(c) { table[b] = scalar }
        }
        return table
    }

    /// Encode text into `maxLength` ids + attention mask (RoBERTa style: `<s>` …
    /// `</s>`, truncated to fit, right-padded with `<pad>`).
    public func encode(_ text: String, maxLength: Int) throws -> (ids: [Int], mask: [Int]) {
        var tokens: [String] = []
        for piece in Self.pretokenize(text) {
            tokens.append(contentsOf: bpe(byteEncode(piece)))
        }
        var ids = [Self.bosID]
        for token in tokens { ids.append(vocab[token] ?? Self.unkID) }
        ids.append(Self.eosID)
        if ids.count > maxLength {
            // Keep `<s>`, drop the tail, re-append `</s>` (transformers truncation).
            ids = Array(ids.prefix(maxLength - 1)) + [Self.eosID]
        }
        var mask = [Int](repeating: 1, count: ids.count)
        while ids.count < maxLength {
            ids.append(Self.padID)
            mask.append(0)
        }
        return (ids, mask)
    }

    /// The GPT-2 pretokenization regex, identical to `transformers.GPT2Tokenizer`.
    private static let pretokenRegex = try! NSRegularExpression(
        pattern: #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#)

    private static func pretokenize(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return pretokenRegex.matches(in: text, options: [], range: range)
            .map { match in
                guard let r = Range(match.range, in: text) else { return "" }
                return String(text[r])
            }
    }

    private func byteEncode(_ piece: String) -> String {
        var out = String()
        out.reserveCapacity(piece.utf8.count)
        for byte in piece.utf8 {
            if let scalar = byteEncoder[Int(byte)] { out.unicodeScalars.append(scalar) }
        }
        return out
    }

    /// Greedy BPE merge by rank, byte-identical to the reference implementation.
    private func bpe(_ token: String) -> [String] {
        guard !token.isEmpty else { return [] }
        var symbols = token.map { String($0) }
        while symbols.count > 1 {
            var bestRank = Int.max
            var bestIndex: Int?
            var bestMerged = ""
            for i in 0..<(symbols.count - 1) {
                let pair = symbols[i] + " " + symbols[i + 1]
                if let rank = merges[pair], rank < bestRank {
                    bestRank = rank
                    bestIndex = i
                    bestMerged = symbols[i] + symbols[i + 1]
                }
            }
            guard let index = bestIndex else { break }
            var merged: [String] = []
            merged.reserveCapacity(symbols.count)
            var i = 0
            while i < symbols.count {
                if i == index {
                    merged.append(bestMerged)
                    i += 2
                } else {
                    merged.append(symbols[i])
                    i += 1
                }
            }
            symbols = merged
        }
        return symbols
    }
}
