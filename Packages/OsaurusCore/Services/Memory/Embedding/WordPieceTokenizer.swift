//
//  WordPieceTokenizer.swift
//  OsaurusCore (Intel fork)
//
//  Minimal BERT-style WordPiece tokenizer for the static model2vec embedder.
//  model2vec pools *content* subword tokens only — there are no [CLS]/[SEP]
//  markers — so this just turns text into token ids for matrix lookup.
//

#if OSAURUS_INTEL
import Foundation

public struct WordPieceTokenizer: Sendable {
    public let vocab: [String: Int]
    public let unkId: Int
    public let lowercase: Bool
    private let maxInputCharsPerWord = 200

    public init(vocab: [String: Int], unkToken: String = "[UNK]", lowercase: Bool = true) {
        self.vocab = vocab
        self.unkId = vocab[unkToken] ?? 0
        self.lowercase = lowercase
    }

    /// Load from a `vocab.txt` (one token per line; id == line index).
    public init(vocabFile url: URL, unkToken: String = "[UNK]", lowercase: Bool = true) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var v: [String: Int] = [:]
        var i = 0
        text.enumerateLines { line, _ in
            v[line] = i
            i += 1
        }
        self.init(vocab: v, unkToken: unkToken, lowercase: lowercase)
    }

    /// Tokenize text into vocabulary ids (no special tokens).
    public func tokenize(_ text: String) -> [Int] {
        var ids: [Int] = []
        for word in basicTokens(text) {
            ids.append(contentsOf: wordpiece(word))
        }
        return ids
    }

    /// Whitespace + punctuation splitting (BERT basic tokenizer, simplified: no
    /// accent stripping — fine for English personal-memory recall).
    private func basicTokens(_ text: String) -> [String] {
        let lowered = lowercase ? text.lowercased() : text
        var tokens: [String] = []
        var current = ""
        for ch in lowered {
            if ch.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else if isPunctuation(ch) {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(ch))
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private func isPunctuation(_ ch: Character) -> Bool {
        if let s = ch.unicodeScalars.first {
            let v = s.value
            if (v >= 33 && v <= 47) || (v >= 58 && v <= 64)
                || (v >= 91 && v <= 96) || (v >= 123 && v <= 126) {
                return true
            }
        }
        return ch.isPunctuation || ch.isSymbol
    }

    /// Greedy longest-match WordPiece over a single word. If any piece fails to
    /// match, the whole word becomes `[UNK]` (matches BERT semantics).
    private func wordpiece(_ word: String) -> [Int] {
        let chars = Array(word)
        if chars.count > maxInputCharsPerWord { return [unkId] }
        var subTokens: [Int] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var matchedId: Int? = nil
            while start < end {
                var piece = String(chars[start..<end])
                if start > 0 { piece = "##" + piece }
                if let id = vocab[piece] { matchedId = id; break }
                end -= 1
            }
            guard let id = matchedId else { return [unkId] }
            subTokens.append(id)
            start = end
        }
        return subTokens.isEmpty ? [unkId] : subTokens
    }
}
#endif
