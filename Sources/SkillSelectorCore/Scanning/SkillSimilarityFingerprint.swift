import CryptoKit
import Foundation

/// A MinHash signature of a Skill's entry-file **body only** (frontmatter
/// stripped), used to find *near* duplicates — copies that drifted by a
/// few edits instead of matching byte-for-byte. The fingerprint is
/// formatting-insensitive on purpose: case, punctuation, and whitespace
/// runs are normalized away, so reformatting a copy does not hide its
/// origin.
///
/// MinHash estimates the Jaccard similarity of two shingle sets (the
/// fraction of matching minimum hashes), which separates cleanly where a
/// single SimHash word does not: on ~kilobyte bodies a 10% drift and a
/// 50% rewrite overlap in Hamming distance but sit far apart as estimated
/// similarity (≈90% vs ≈50%). Two bodies are near-duplicates when the
/// estimated similarity reaches `minimumSimilarityPercent`.
public enum SkillSimilarityFingerprint {
    /// Version marker of the MinHash algorithm (`s1:`). Independent of the
    /// exact fingerprint's `v2:` — the two fingerprints describe different
    /// notions of "same" and migrate separately.
    public static let versionPrefix = "s1:"

    /// Hashes in the signature. 64 keeps the standard error of the Jaccard
    /// estimate around ±6% while costing 512 bytes per Skill.
    public static let signatureCount = 64

    /// Normalized bodies shorter than this are too easy to collide
    /// (near-empty skills, stubs) — they get no similarity fingerprint and
    /// never take part in near-duplicate grouping.
    public static let minimumBodyLength = 200

    /// Character shingle length. Works for both spaced scripts (English)
    /// and unspaced ones (CJK), unlike word shingles.
    public static let shingleLength = 5

    /// Cap on the shingles hashed per body. Uniform subsampling barely
    /// moves a MinHash estimate, and the cap bounds the pass on megabyte
    /// bodies (the 1 MiB entry-file limit) to milliseconds.
    public static let maximumShingleSamples = 100_000

    /// Minimum estimated similarity (percent) for two bodies to count as
    /// near-duplicates: catches copies drifted by small edits and
    /// reformatting, leaves genuinely different content alone.
    public static let minimumSimilarityPercent = 75

    public enum Error: Swift.Error, LocalizedError, Equatable {
        case oversizedEntry(limit: Int)

        public var errorDescription: String? {
            switch self {
            case .oversizedEntry(let limit):
                return "Entry file exceeds the \(limit) byte read limit"
            }
        }
    }

    /// Computes the MinHash signature of the body, or nil when the
    /// normalized body is below `minimumBodyLength`. The signature encodes
    /// as base64 (`s1:` + 684 characters).
    public static func compute(body: String) -> String? {
        let normalized = normalizedBody(body)
        let scalars = Array(normalized.unicodeScalars)
        guard scalars.count >= max(minimumBodyLength, shingleLength) else { return nil }

        // Encode once and index scalar positions in the byte stream: each
        // shingle then hashes ≤ 5×4 bytes with zero allocation.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(normalized.utf8.count)
        var offsets: [Int] = []
        offsets.reserveCapacity(scalars.count + 1)
        for scalar in scalars {
            offsets.append(bytes.count)
            appendUTF8(scalar, to: &bytes)
        }
        offsets.append(bytes.count)

        var signature = [UInt64](repeating: .max, count: signatureCount)
        let totalShingles = scalars.count - shingleLength + 1
        // Uniform sampling: deterministic (same body, same samples) and
        // insensitive for the estimate, while bounding the pass on
        // megabyte bodies.
        let stride = max(1, totalShingles / maximumShingleSamples)
        var sampled = 0
        var start = 0
        while start < totalShingles {
            let byteStart = offsets[start]
            let byteEnd = offsets[start + shingleLength]
            var shingle: UInt64 = 0xcbf29ce484222325
            for byte in bytes[byteStart..<byteEnd] {
                shingle ^= UInt64(byte)
                shingle = shingle &* 0x100000001b3
            }
            sampled += 1
            for index in 0..<signatureCount {
                let hashed = mix(shingle, salt: UInt64(index))
                if hashed < signature[index] {
                    signature[index] = hashed
                }
            }
            start += stride
        }
        guard sampled > 0 else { return nil }

        var digest = Data(capacity: signatureCount * 8)
        for value in signature {
            digest.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init(_:)))
        }
        return versionPrefix + digest.base64EncodedString()
    }

    /// Reads the entry file once and produces both fingerprints: the exact
    /// body SHA-256 (`v2:`) and the similarity MinHash (`s1:`, nil for
    /// short bodies). The deferred backfill uses this so one file read
    /// feeds both.
    public static func computePair(entryFileURL: URL) throws -> (content: String, similarity: String?) {
        let fileSize = try entryFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let fileSize, fileSize <= SkillDocumentReader.maximumRenderBytes else {
            throw Error.oversizedEntry(limit: SkillDocumentReader.maximumRenderBytes)
        }
        let text = try String(contentsOf: entryFileURL, encoding: .utf8)
        let body = FrontmatterParser.bodyLines(from: text).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(body.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return (
            SkillContentFingerprint.currentVersionPrefix + digest,
            compute(body: body)
        )
    }

    /// Estimated Jaccard similarity between two `s1:` signatures, as a
    /// percentage (0–100). Nil when either value is missing, malformed,
    /// or was produced by a different algorithm version.
    public static func similarityPercent(_ lhs: String, _ rhs: String) -> Int? {
        guard let left = parse(lhs), let right = parse(rhs) else { return nil }
        let matches = zip(left, right).filter { $0 == $1 }.count
        return matches * 100 / signatureCount
    }

    /// True when two signatures are similar enough to count as
    /// near-duplicates.
    public static func areNearDuplicates(_ lhs: String, _ rhs: String) -> Bool {
        guard let percent = similarityPercent(lhs, rhs) else { return false }
        return percent >= minimumSimilarityPercent
    }

    public static func isCurrentVersion(_ fingerprint: String) -> Bool {
        fingerprint.hasPrefix(versionPrefix)
    }

    private static func parse(_ fingerprint: String) -> [UInt64]? {
        guard fingerprint.hasPrefix(versionPrefix) else { return nil }
        let base64 = String(fingerprint.dropFirst(versionPrefix.count))
        guard let data = Data(base64Encoded: base64), data.count == signatureCount * 8 else {
            return nil
        }
        return (0..<signatureCount).map { index in
            let start = data.startIndex.advanced(by: index * 8)
            let value = data.subdata(in: start..<start.advanced(by: 8))
            return value.reduce(UInt64(0)) { result, byte in
                result << 8 | UInt64(byte)
            }
        }
    }

    /// SplitMix64 finalizer with a per-index salt: 64 decorrelated hash
    /// functions from one shingle hash.
    private static func mix(_ value: UInt64, salt: UInt64) -> UInt64 {
        var z = value &+ salt &+ 0x9e3779b97f4a7c15
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }

    /// Lowercasing plus punctuation/symbol (markdown syntax) removal and
    /// whitespace-run collapsing. Deliberately cheap: `.diacriticInsensitive`
    /// folding routes through ICU transliteration, which costs seconds on
    /// megabyte bodies — near-duplicate grouping does not need it.
    private static func normalizedBody(_ body: String) -> String {
        let folded = body.lowercased()
        var result = String.UnicodeScalarView()
        var previousWasSpace = false
        for scalar in folded.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !previousWasSpace { result.append(" ") }
                previousWasSpace = true
            } else if !CharacterSet.punctuationCharacters.contains(scalar),
                      !CharacterSet.symbols.contains(scalar) {
                result.append(scalar)
                previousWasSpace = false
            }
        }
        return String(result).trimmingCharacters(in: .whitespaces)
    }

    /// A scalar's UTF-8 bytes without materializing a String.
    private static func appendUTF8(_ scalar: Unicode.Scalar, to bytes: inout [UInt8]) {
        let value = scalar.value
        if value < 0x80 {
            bytes.append(UInt8(value))
        } else if value < 0x800 {
            bytes.append(UInt8(0xC0 | (value >> 6)))
            bytes.append(UInt8(0x80 | (value & 0x3F)))
        } else if value < 0x10000 {
            bytes.append(UInt8(0xE0 | (value >> 12)))
            bytes.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
            bytes.append(UInt8(0x80 | (value & 0x3F)))
        } else {
            bytes.append(UInt8(0xF0 | (value >> 18)))
            bytes.append(UInt8(0x80 | ((value >> 12) & 0x3F)))
            bytes.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
            bytes.append(UInt8(0x80 | (value & 0x3F)))
        }
    }
}
