import Foundation
import os.log

private let logger = Logger(subsystem: "com.codex.switch", category: "thinksplitter")

/// A segment of streamed content after splitting out inline thinking tags.
enum ThinkSegment {
    case text(String)
    case reasoning(String)
}

/// Splits a stream of `delta.content` strings into text and reasoning segments,
/// handling non-standard `<think>...</think>` tags that some Chat Completions
/// upstreams (GLM, Kimi, etc.) emit inline instead of via `reasoning_content`.
///
/// The tags themselves are stripped and never forwarded to Codex. Tags may be
/// split across chunk boundaries; the splitter buffers a potential partial-tag
/// tail until it can be resolved on the next chunk.
final class InlineThinkSplitter {
    private static let openTag = "<think"
    private static let closeTag = "</think"

    enum Mode { case text, thinking }

    private var mode: Mode = .text
    private var pending = ""

    /// Feed one content delta; returns fully-resolved segments. A residual that
    /// could be the start of a tag is held back until the next call.
    func feed(_ delta: String) -> [ThinkSegment] {
        pending += delta
        var segments: [ThinkSegment] = []

        while true {
            switch mode {
            case .text:
                if let openRange = pending.range(of: Self.openTag) {
                    let before = String(pending[..<openRange.lowerBound])
                    if !before.isEmpty { segments.append(.text(before)) }
                    pending.removeSubrange(pending.startIndex..<openRange.upperBound)
                    mode = .thinking
                    continue
                }
                // Hold back a tail that could be the prefix of "<think>".
                let safe = Self.flusheablePrefix(pending, tag: Self.openTag)
                if !safe.isEmpty {
                    segments.append(.text(String(pending[..<safe.endIndex])))
                    pending.removeSubrange(pending.startIndex..<safe.endIndex)
                }
                return segments

            case .thinking:
                if let closeRange = pending.range(of: Self.closeTag) {
                    let inside = String(pending[..<closeRange.lowerBound])
                    if !inside.isEmpty { segments.append(.reasoning(inside)) }
                    pending.removeSubrange(pending.startIndex..<closeRange.upperBound)
                    mode = .text
                    continue
                }
                let safe = Self.flusheablePrefix(pending, tag: Self.closeTag)
                if !safe.isEmpty {
                    segments.append(.reasoning(String(pending[..<safe.endIndex])))
                    pending.removeSubrange(pending.startIndex..<safe.endIndex)
                }
                return segments
            }
        }
    }

    /// Flush any remaining buffered content at stream end. A trailing partial
    /// tag prefix (e.g. a lone `<`) is emitted as ordinary text rather than
    /// dropped, since by now it can never complete into a full tag and is far
    /// more likely to be literal text than an unterminated think block. An
    /// already-opened `<think>` with no close tag is emitted as reasoning.
    func flush() -> [ThinkSegment] {
        var segments: [ThinkSegment] = []
        switch mode {
        case .text:
            if !pending.isEmpty {
                segments.append(.text(pending))
            }
        case .thinking:
            logger.debug("Flushing unterminated think block (\(self.pending.count) chars) as reasoning")
            if !pending.isEmpty { segments.append(.reasoning(pending)) }
        }
        pending = ""
        mode = .text
        return segments
    }

    // MARK: - Tag-boundary helpers

    /// The longest prefix of `buffer` that is safe to emit right now. Only a
    /// partial tag prefix sitting at the **very end** of the buffer must be
    /// held back (it may complete into a full tag on the next chunk). A partial
    /// match in the middle is ordinary text, since `range(of:)` already proved
    /// no full tag exists anywhere.
    private static func flusheablePrefix(_ buffer: String, tag: String) -> Substring {
        guard let first = tag.first else { return buffer[...] }

        // Scan backward from the end: the only position a held-back partial tag
        // can start is within `tag.count - 1` characters of the end.
        let maxTagOverlap = tag.count - 1
        var scan = buffer.endIndex
        for _ in 0..<maxTagOverlap {
            guard scan > buffer.startIndex else { break }
            scan = buffer.index(before: scan)
            if buffer[scan] == first {
                let matched = matchedTagLength(buffer, at: scan, tag: tag)
                if matched > 0 && matched < tag.count {
                    // Partial tag prefix at the tail — hold it back.
                    return buffer[..<scan]
                }
            }
        }
        return buffer[...]
    }

    /// How many leading characters of `tag` match `buffer` starting at `pos`.
    private static func matchedTagLength(_ buffer: String, at pos: String.Index, tag: String) -> Int {
        var bufferIdx = pos
        var tagIdx = tag.startIndex
        var matched = 0
        while bufferIdx < buffer.endIndex, tagIdx < tag.endIndex, buffer[bufferIdx] == tag[tagIdx] {
            matched += 1
            bufferIdx = buffer.index(after: bufferIdx)
            tagIdx = tag.index(after: tagIdx)
        }
        return matched
    }
}
