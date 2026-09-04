import Foundation
import Testing
@testable import ParsoAudioNeural

@Suite
struct RoBERTaTokenizerTests {
    /// A tiny synthetic vocab/merges pair — enough to exercise the special
    /// tokens, truncation and padding without a real ~50K-entry BPE table.
    private func makeTokenizer() throws -> RoBERTaTokenizer {
        let vocab: [String: Int] = [
            "<s>": 0, "<pad>": 1, "</s>": 2, "<unk>": 3,
            "a": 4, "b": 5, "ab": 6,
        ]
        let vocabData = try JSONEncoder().encode(vocab)
        let vocabURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-\(UUID().uuidString).json")
        try vocabData.write(to: vocabURL)

        let mergesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("merges-\(UUID().uuidString).txt")
        try "a b\n".write(to: mergesURL, atomically: true, encoding: .utf8)

        return try RoBERTaTokenizer(vocabURL: vocabURL, mergesURL: mergesURL)
    }

    @Test
    func encodeWrapsWithBosAndEos() throws {
        let tokenizer = try makeTokenizer()
        let (ids, mask) = try tokenizer.encode("", maxLength: 4)
        #expect(ids.first == RoBERTaTokenizer.bosID)
        #expect(ids.contains(RoBERTaTokenizer.eosID))
        #expect(mask.count == 4)
    }

    @Test
    func encodePadsToMaxLength() throws {
        let tokenizer = try makeTokenizer()
        let (ids, mask) = try tokenizer.encode("", maxLength: 8)
        #expect(ids.count == 8)
        #expect(mask.suffix(6).allSatisfy { $0 == 0 })
    }

    @Test
    func encodeTruncatesAndKeepsFinalEOS() throws {
        let tokenizer = try makeTokenizer()
        let (ids, _) = try tokenizer.encode("aaaaaaaaaa", maxLength: 5)
        #expect(ids.count == 5)
        #expect(ids.last == RoBERTaTokenizer.eosID)
    }
}
