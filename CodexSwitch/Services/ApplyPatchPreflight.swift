import Foundation
import os.log

private let logger = Logger(subsystem: "com.codex.switch", category: "apply_patch")

// MARK: - Repair Record

/// One pre-flight processing record (for diagnostics / logging). Mirrors
/// `apply_patch_preflight::Repair` in codex-app-transfer.
struct ApplyPatchRepair {
    /// Patch file path (relative, as-is) or a synthetic tag like `(@@ header)`.
    let file: String
    /// `repaired` / `clean` / `skipped:<reason>`.
    let kind: String
    /// Human-readable detail (how many lines fixed / why skipped).
    let detail: String
}

// MARK: - apply_patch pre-flight middle layer
//
// apply_patch **pre-flight auto-repair**: before sending a V4A patch to the
// Codex applier, read the target file and recover known format errors that
// third-party chat models (no lark-grammar constraint) produce, so the patch
// still applies. **Only fixes known-safe cases; unknown malformations pass
// through verbatim — never guess, never lose content.**
//
// Two tiers (mirrors codex-app-transfer MOC-194 / MOC-263 / MOC-268):
//
// Tier A — syntax tidy (pure string, no disk read):
//   • stripTrailingAt        — double `@@ … @@` → single
//   • ensureAddFilePlus      — Add File body missing `+` → fill
//   • ensureV4aEnvelope      — missing `*** Begin/End Patch` → add (last,
//     gated on jsonComplete, with MOC-268 terminator disambiguation)
//
// Tier B — semantic recovery (needs cwd, reads disk):
//   • recoverUpdateEmptyFile — Update empty file → Delete+Add
//   • recoverEmptyMove       — empty rename-only → Delete+Add copy
//   • alignAtHeaders         — partial `@@` header → real file line
//   • fixUnprefixedLines     — unprefixed lines → context space / drop dup
//   • preflightRepair        — byte-exact context mismatch → align (incl.
//     auto-@@-splitting when uniquely segmentable)
enum ApplyPatchPreflight {

    /// Codex freeform tool name we special-case. Must stay in sync with the
    /// request-side rewrite (`CodexToolContext.addCustomTool`) and the
    /// response-side reshape (`ProtocolConverter` / `StreamingConverter`).
    static let applyPatchToolName = "apply_patch"

    static func isApplyPatchTool(_ name: String) -> Bool { name == applyPatchToolName }

    // MARK: - cwd candidate history (MOC-263 P1)
    //
    // Process-level "most-recently-seen cwd" candidate list (most-recent-first,
    // deduped, capped). Codex only sends `<cwd>` in turn-start requests; the
    // apply_patch tool-loop requests that follow carry no cwd, so we rely on
    // cross-request memory. A single global slot gets clobbered by *other*
    // concurrent Codex sessions (each changing a different project) → the
    // fallback resolves to a stale foreign cwd → every disk-read rule no-ops.
    // The candidate list lets each read try `cwd/<relpath>` across recent cwds
    // and pick the one whose file actually exists / matches anchors.

    /// Remember a cwd (dedup, move to front, evict oldest past cap). Empty ignored.
    static func rememberCwd(_ cwd: String?) {
        guard let cwd = cwd, !cwd.isEmpty else { return }
        CwdHistory.shared.remember(cwd)
    }

    /// Remember the cwd extracted from a request body (walks the JSON tree for
    /// `<cwd>…</cwd>`). Call for **every** request: the turn-start request that
    /// carries `<cwd>` produces no apply_patch, while apply_patch shows up in a
    /// later tool-loop request with no cwd — so the memory point must be a
    /// per-request path, not inside `optimizePatch`.
    static func rememberCwd(fromRequest request: [String: Any]?) {
        if let cwd = extractCwd(from: request) {
            CwdHistory.shared.remember(cwd)
        }
    }

    /// Extract `<cwd>…</cwd>` from a Codex Responses request body. Walks the
    /// already-deserialized JSON tree (string values are the un-escaped source)
    /// rather than re-serializing — re-serializing would re-escape Windows paths
    /// (`C:\Users` → `C:\\Users`) and yield a wrong path. Scans any nesting
    /// level, not just `instructions`.
    static func extractCwd(from request: [String: Any]?) -> String? {
        guard let request = request else { return nil }
        return findCwd(in: request as Any)
    }

    private static func findCwd(in value: Any) -> String? {
        if let s = value as? String {
            return extractCwd(fromStr: s)
        }
        if let arr = value as? [Any] {
            for v in arr { if let c = findCwd(in: v) { return c } }
            return nil
        }
        if let dict = value as? [String: Any] {
            for v in dict.values { if let c = findCwd(in: v) { return c } }
            return nil
        }
        return nil
    }

    private static func extractCwd(fromStr s: String) -> String? {
        guard let open = s.range(of: "<cwd>") else { return nil }
        let after = open.upperBound
        guard let close = s.range(of: "</cwd>", range: after..<s.endIndex) else { return nil }
        let cwd = String(s[after..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return cwd.isEmpty ? nil : cwd
    }

    // MARK: - Middle-layer entry

    /// apply_patch middle-layer entry: recover known format errors one by one
    /// so a patch the model produced without following guidance still applies
    /// in Codex. Only fixes known pitfalls; unknown malformations pass through.
    ///
    /// `primaryCwd`: the current request's `<cwd>` (apply_patch requests usually
    /// have none → nil). State-rewrite rules use *only* this fresh cwd (judgment
    /// file == application file; a stale foreign cwd would delete the wrong
    /// project's file). Byte-exact rules use it as primary, then fall back to
    /// the candidate history via `readPatchFile` (worst case: no unique match →
    /// safe no-op).
    ///
    /// `jsonComplete`: caller passes whether the wrapping JSON is complete (not
    /// a streaming truncation). Envelope completion is gated on this so we never
    /// "complete" a half-truncated patch into a destructive half-application.
    static func optimizePatch(
        _ v4a: String,
        primaryCwd: String?,
        jsonComplete: Bool
    ) -> (String, [ApplyPatchRepair]) {
        // Remember the current request's cwd into the candidate history (the
        // turn-start cwd is mainly remembered per-request by the caller; this is
        // a belt-and-suspenders in case an apply_patch request itself carries one).
        if let c = primaryCwd { rememberCwd(c) }

        var repairs: [ApplyPatchRepair] = []
        var s = v4a

        // ── Tier A: syntax tidy (pure string) ──
        let (s1, r1) = stripTrailingAt(s); s = s1; repairs.append(contentsOf: r1)
        let (sg, rg) = ensureAddFilePlus(s); s = sg; repairs.append(contentsOf: rg)

        // ── Tier B: semantic recovery (state-rewrite → fresh cwd only) ──
        let (sf, rf) = recoverUpdateEmptyFile(s, primaryCwd: primaryCwd); s = sf; repairs.append(contentsOf: rf)
        let (s3, r3) = recoverEmptyMove(s, primaryCwd: primaryCwd); s = s3; repairs.append(contentsOf: r3)

        // byte-exact alignment → primaryCwd as primary, readPatchFile falls back to history
        let (sh, rh) = alignAtHeaders(s, primaryCwd: primaryCwd); s = sh; repairs.append(contentsOf: rh)
        let (su, ru) = fixUnprefixedLines(s, primaryCwd: primaryCwd); s = su; repairs.append(contentsOf: ru)
        let (s2, r2) = preflightRepair(s, primaryCwd: primaryCwd); s = s2; repairs.append(contentsOf: r2)

        // ── Envelope completion last: wraps any Tier-B-added Delete+Add etc. ──
        if jsonComplete {
            let (s4, r4) = ensureV4aEnvelope(s)
            s = s4
            if let r = r4 { repairs.append(r) }
        }

        if !repairs.isEmpty {
            logger.info("apply_patch preflight: \(repairs.count) repair(s) — \(repairs.map { $0.kind }.joined(separator: ", "))")
        }
        return (s, repairs)
    }

    // MARK: Tier A — strip trailing `@@`

    /// Double-sided `@@ … @@` → single-sided `@@ …`. V4A's `@@` is a single-sided
    /// anchor (`@@ <header>`); models often write `@@ <header> @@` and Codex
    /// treats the trailing `@@` as literal text → `Failed to find context '... @@'`.
    /// Only touches column-0 `@@` header lines; bare `@@` (section separator) is
    /// left alone.
    static func stripTrailingAt(_ v4a: String) -> (String, [ApplyPatchRepair]) {
        var changed = 0
        let lines = splitLines(v4a)
        let out = lines.map { (l: String) -> String in
            if l.hasPrefix("@@") {
                let t = l.trimEnd()
                // bare `@@` (count==2) is a valid section separator; `@@ x @@` strips the tail
                if t.count > 2 && t.hasSuffix("@@") {
                    let body = String(t.dropLast(2)).trimEnd()
                    if !body.isEmpty && body != "@@" {
                        changed += 1
                        return body
                    }
                }
            }
            return l
        }
        let joined = rejoin(out, preservingTrailingNewlineOf: v4a)
        let repairs = changed > 0 ? [ApplyPatchRepair(file: "(@@ header)", kind: "repaired",
            detail: "双边 @@ → 单边: \(changed) 行(prompt gotcha #1)")] : []
        return (joined, repairs)
    }

    // MARK: Tier A — ensure Add File `+` prefix

    /// Add File content lines missing the `+` prefix → fill. Add File semantics:
    /// every line after the header is literal new-file content and must be
    /// `+`-prefixed (blank → bare `+`). Unambiguous inside an Add File section
    /// (all additions); pure string, no disk read.
    static func ensureAddFilePlus(_ v4a: String) -> (String, [ApplyPatchRepair]) {
        if !v4a.contains("*** Add File:") { return (v4a, []) }
        let lines = splitLines(v4a)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var repairs: [ApplyPatchRepair] = []
        var i = 0
        while i < lines.count {
            if let path = stripPrefix(lines[i], "*** Add File: ") {
                out.append(lines[i]) // header
                i += 1
                var fixed = 0
                // body runs to the next `*** ` control line / EOF
                while i < lines.count && !lines[i].hasPrefix("*** ") {
                    if lines[i].hasPrefix("+") {
                        out.append(lines[i])
                    } else {
                        out.append("+\(lines[i])")
                        fixed += 1
                    }
                    i += 1
                }
                if fixed > 0 {
                    repairs.append(ApplyPatchRepair(file: path.trimmingCharacters(in: .whitespacesAndNewlines),
                        kind: "repaired", detail: "Add File \(fixed) 行漏 `+` 前缀 → 补全(lark add_line)"))
                }
            } else {
                out.append(lines[i])
                i += 1
            }
        }
        return (rejoin(out, preservingTrailingNewlineOf: v4a), repairs)
    }

    // MARK: Tier B — recover Update empty file → Delete+Add

    /// `Update File` targeting an empty file → `Delete File + Add File` (lossless).
    /// `*** Update File:` cannot operate on a truly 0-byte file (Codex reports
    /// `cannot operate on a completely empty file`). When the target exists and is
    /// truly empty (0 bytes, not whitespace-only) and the body is pure `+` lines,
    /// convert to Delete+Add with the original `+` body. Body with `-`/context or
    /// Move → leave alone. Requires fresh cwd.
    static func recoverUpdateEmptyFile(_ v4a: String, primaryCwd: String?) -> (String, [ApplyPatchRepair]) {
        guard let cwd = primaryCwd else { return (v4a, []) }
        if !v4a.contains("*** Update File:") { return (v4a, []) }
        let lines = splitLines(v4a)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var repairs: [ApplyPatchRepair] = []
        var i = 0
        while i < lines.count {
            if let path = stripPrefix(lines[i], "*** Update File: ") {
                let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
                // Only a truly 0-byte file (whitespace-only files are readable
                // content and Update normally). String(contentsOfFile:) returns
                // "" for a 0-byte file, nil for a missing one.
                let content = try? String(contentsOfFile: resolvePath(p, cwd), encoding: .utf8)
                let isEmpty = content.map { $0.isEmpty } ?? false
                if isEmpty {
                    let bodyStart = i + 1
                    var j = bodyStart
                    while j < lines.count && !lines[j].hasPrefix("*** ") { j += 1 }
                    let body = Array(lines[bodyStart..<j])
                    let hasMove = (body.first?.hasPrefix("*** Move to:")) ?? false
                    let content2 = body.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.hasPrefix("@@") }
                    let allPlus = !content2.isEmpty && content2.allSatisfy { $0.hasPrefix("+") }
                    if !hasMove && allPlus {
                        out.append("*** Delete File: \(p)")
                        out.append("*** Add File: \(p)")
                        for b in body where b.hasPrefix("+") { out.append(b) }
                        repairs.append(ApplyPatchRepair(file: p, kind: "repaired",
                            detail: "Update 空文件 → Delete+Add 写入(prompt gotcha #3)"))
                        i = j
                        continue
                    }
                }
            }
            out.append(lines[i])
            i += 1
        }
        return (rejoin(out, preservingTrailingNewlineOf: v4a), repairs)
    }

    // MARK: Tier B — recover empty rename-only → Delete+Add

    /// Empty `Update File + Move to` (rename-only, no hunk) → `Delete + Add File`.
    /// A bare `*** Update File: X` + `*** Move to: Y` with no hunk fails with
    /// `Update file hunk for path 'X' is empty`. Read X's content and rebuild as
    /// `*** Delete File: X` + `*** Add File: Y` + per-line `+` copy (blanks as
    /// bare `+`). Unreadable/empty X → pass through. Requires fresh cwd.
    static func recoverEmptyMove(_ v4a: String, primaryCwd: String?) -> (String, [ApplyPatchRepair]) {
        guard let cwd = primaryCwd else { return (v4a, []) }
        if !v4a.contains("*** Move to:") { return (v4a, []) }
        let lines = splitLines(v4a)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var repairs: [ApplyPatchRepair] = []
        var i = 0
        while i < lines.count {
            if let old = stripPrefix(lines[i], "*** Update File: ") {
                if i + 1 < lines.count, let new = stripPrefix(lines[i + 1], "*** Move to: ") {
                    // Scan after Move up to the next file-op control line for hunk content.
                    // `*** End of File` is a documented in-hunk marker (RENAME/MOVE section),
                    // NOT a section boundary — don't stop on it (else rename+EOF append is
                    // misjudged empty → lossy Delete+Add). It itself signals "has hunk".
                    var j = i + 2
                    var hasHunk = false
                    while j < lines.count {
                        let t = lines[j]
                        if t.trimEnd() == "*** End of File" { hasHunk = true; j += 1; continue }
                        if t.hasPrefix("*** ") { break }
                        if t.hasPrefix("+") || t.hasPrefix("-") || t.hasPrefix(" ") || t.hasPrefix("@@") {
                            hasHunk = true
                        }
                        j += 1
                    }
                    if !hasHunk {
                        let abs = resolvePath(old.trimmingCharacters(in: .whitespacesAndNewlines), cwd)
                        if let content = try? String(contentsOfFile: abs, encoding: .utf8), !content.isEmpty {
                            out.append("*** Delete File: \(old.trimmingCharacters(in: .whitespacesAndNewlines))")
                            out.append("*** Add File: \(new.trimmingCharacters(in: .whitespacesAndNewlines))")
                            for cl in splitLines(content) { out.append("+\(cl)") }
                            repairs.append(ApplyPatchRepair(file: old.trimmingCharacters(in: .whitespacesAndNewlines),
                                kind: "repaired",
                                detail: "空 Update+Move(rename-only)→ Delete+Add 复制原内容 → \(new.trimmingCharacters(in: .whitespacesAndNewlines))(prompt gotcha #7)"))
                            i = j // skip original Update/Move (+empty body)
                            continue
                        } else {
                            repairs.append(ApplyPatchRepair(file: old.trimmingCharacters(in: .whitespacesAndNewlines),
                                kind: "skipped:unreadable_or_empty",
                                detail: "空 Update+Move 但原文件读不到 / 为空 → 原样放行"))
                        }
                    }
                }
            }
            out.append(lines[i])
            i += 1
        }
        return (rejoin(out, preservingTrailingNewlineOf: v4a), repairs)
    }

    // MARK: Tier B — align `@@ <header>` to real file line

    /// `@@ <header>` partial anchor → align to the real file line. Codex matches
    /// `@@ <header>` by exact whole-line; models write a partial header (e.g.
    /// `@@ 系统架构建议` vs real `## 6. 系统架构建议`) → no anchor. When the
    /// header is not any whole line but is uniquely contained in exactly one file
    /// line, align to that whole line. 0 / multiple → ambiguous, pass through.
    static func alignAtHeaders(_ v4a: String, primaryCwd: String?) -> (String, [ApplyPatchRepair]) {
        if !hasCwdCandidate(primaryCwd) { return (v4a, []) }
        if !v4a.contains("*** Update File:") { return (v4a, []) }
        let lines = splitLines(v4a)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var repairs: [ApplyPatchRepair] = []
        var fileLines: [String] = []
        var haveFile = false
        var fixed = 0
        var i = 0
        while i < lines.count {
            if let path = stripPrefix(lines[i], "*** Update File: ") {
                // Switched to a new Update File section → resolve the target file
                // via candidate cwd + anchor probe (MOC-263 P1/P2).
                var se = i + 1
                while se < lines.count && !lines[se].hasPrefix("*** ") { se += 1 }
                let probe = anchorProbe(Array(lines[(i + 1)..<se]))
                fileLines = readPatchFile(relpath: path.trimmingCharacters(in: .whitespacesAndNewlines),
                                          primary: primaryCwd, probe: probe).map { splitLines($0) } ?? []
                haveFile = !fileLines.isEmpty
                out.append(lines[i])
                i += 1
                continue
            }
            // `@@ <header>` anchor (not bare `@@`), file loaded
            if haveFile, let header = stripPrefix(lines[i], "@@ ") {
                let h = header.trimmingCharacters(in: .whitespacesAndNewlines)
                if !h.isEmpty && !fileLines.contains(h) {
                    let hits = fileLines.filter { $0.contains(h) }
                    if hits.count == 1 {
                        out.append("@@ \(hits[0])")
                        fixed += 1
                        i += 1
                        continue
                    }
                }
            }
            out.append(lines[i])
            i += 1
        }
        if fixed > 0 {
            repairs.append(ApplyPatchRepair(file: "(@@ anchor)", kind: "repaired",
                detail: "@@ 锚点残缺 → 对齐文件真实整行: \(fixed) 处(Failed to find context)"))
        }
        return (rejoin(out, preservingTrailingNewlineOf: v4a), repairs)
    }

    // MARK: Tier B — fix unprefixed lines in Update body

    /// Update body unprefixed lines → fix by file judgment (non-destructive:
    /// only add prefixes / drop provably-duplicate junk, never lose content):
    /// • unprefixed line duplicating an adjacent `+<same>` → drop the dup
    /// • else unprefixed non-empty line that is an exact whole file line → it's
    ///   a context line missing its space → add ` `
    /// • otherwise → pass through (let validate error, model self-corrects).
    /// Only inside `*** Update File:` sections. Requires cwd.
    static func fixUnprefixedLines(_ v4a: String, primaryCwd: String?) -> (String, [ApplyPatchRepair]) {
        if !hasCwdCandidate(primaryCwd) { return (v4a, []) }
        if !v4a.contains("*** Update File:") { return (v4a, []) }
        let lines = splitLines(v4a)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var repairs: [ApplyPatchRepair] = []
        var inUpdate = false
        var fileLines: [String] = []
        var dropDups = 0
        var addCtx = 0
        var i = 0
        while i < lines.count {
            let l = lines[i]
            if let path = stripPrefix(l, "*** Update File: ") {
                inUpdate = true
                var se = i + 1
                while se < lines.count && !lines[se].hasPrefix("*** ") { se += 1 }
                let probe = anchorProbe(Array(lines[(i + 1)..<se]))
                fileLines = readPatchFile(relpath: path.trimmingCharacters(in: .whitespacesAndNewlines),
                                          primary: primaryCwd, probe: probe).map { splitLines($0) } ?? []
                out.append(l)
                i += 1
                continue
            }
            if l.hasPrefix("*** ") {
                inUpdate = false
                out.append(l)
                i += 1
                continue
            }
            let first = l.first
            let valid = first == "+" || first == "-" || first == " " || l.hasPrefix("@@") || l.isEmpty
            if inUpdate && !valid {
                // case 1: dup of an adjacent `+<same>` line → drop (content lives in the + line)
                let plusDup = "+\(l)"
                let nextDup = (i + 1 < lines.count) && (lines[i + 1] == plusDup)
                let prevDup = out.last == plusDup
                if nextDup || prevDup {
                    dropDups += 1
                    i += 1
                    continue
                }
                // case 2: exact whole file line → context missing its space → add ` `
                if fileLines.contains(l) {
                    out.append(" \(l)")
                    addCtx += 1
                    i += 1
                    continue
                }
                // else: pass through (don't guess)
            }
            out.append(l)
            i += 1
        }
        if dropDups + addCtx > 0 {
            repairs.append(ApplyPatchRepair(file: "(unprefixed)", kind: "repaired",
                detail: "Update 无前缀行修复: 补 context 空格 \(addCtx) / 删重复废行 \(dropDups)(lark change_line)"))
        }
        return (rejoin(out, preservingTrailingNewlineOf: v4a), repairs)
    }

    // MARK: Tier B — preflight byte-exact repair

    /// Pre-flight repair of a V4A patch. `primaryCwd` resolves the patch's
    /// relative paths to real files. Returns `(repaired V4A, repairs)`. No cwd /
    /// no `Update File` / unreadable file → V4A returned as-is.
    static func preflightRepair(_ v4a: String, primaryCwd: String?) -> (String, [ApplyPatchRepair]) {
        if !hasCwdCandidate(primaryCwd) { return (v4a, []) }
        // Short-circuit: no Update File → nothing to do (Add/Delete don't anchor-match)
        if !v4a.contains("*** Update File:") { return (v4a, []) }
        var repairs: [ApplyPatchRepair] = []
        let lines = splitLines(v4a)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let path = stripPrefix(line, "*** Update File: ") {
                out.append(line)
                i += 1
                // Collect this Update File section's body (up to the next `*** ` control line).
                let bodyStart = i
                while i < lines.count && !lines[i].hasPrefix("*** ") { i += 1 }
                let body = Array(lines[bodyStart..<i])
                let (repairedBody, rep) = repairUpdateSection(
                    path: path.trimmingCharacters(in: .whitespacesAndNewlines),
                    body: body, primaryCwd: primaryCwd)
                out.append(contentsOf: repairedBody)
                repairs.append(rep)
            } else {
                out.append(line)
                i += 1
            }
        }
        return (rejoin(out, preservingTrailingNewlineOf: v4a), repairs)
    }

    /// Repair one `Update File` section's body. `path` is the (relative) patch
    /// path. `primaryCwd` is the current request's cwd (primary hint); disk reads
    /// go through `readPatchFile` which also consults the candidate history.
    private static func repairUpdateSection(path: String, body: [String], primaryCwd: String?) -> ([String], ApplyPatchRepair) {
        let probe = anchorProbe(body)
        guard let content = readPatchFile(relpath: path, primary: primaryCwd, probe: probe) else {
            return (body, ApplyPatchRepair(file: path, kind: "skipped:unreadable",
                detail: "读不到文件 \(path)(候选 cwd 均无)→ 原样放行"))
        }
        let fileLines = splitLines(content)

        // body with no `@@` but multiple disjoint edit groups (model omitted `@@`
        // separators) → auto-segment by file position, join with bare `@@`, so the
        // applier locates each segment as an independent hunk. Only when uniquely
        // segmentable; single segment / ambiguous → keep original body.
        var splitOwned: [String] = []
        // Use column-0 `@@` (not trim_start) to decide whether hunk separators
        // already exist, matching the segmenter below — else a context line
        // ` @@ ...` (leading space, content starts with @@) would wrongly disable
        // auto-split while the segmenter still won't split it → failure.
        let didSplit: Bool
        if !body.contains(where: { $0.hasPrefix("@@") }) {
            if let subhunks = segmentNoAtBody(body, file: fileLines) {
                for (k, sub) in subhunks.enumerated() {
                    if k > 0 { splitOwned.append("@@") }
                    splitOwned.append(contentsOf: sub)
                }
                didSplit = true
            } else {
                didSplit = false
            }
        } else {
            didSplit = false
        }
        let effectiveBody = didSplit ? splitOwned : body

        // Split body into hunks (by `@@` lines; `@@` lines are kept, not anchored).
        var newBody: [String] = []
        newBody.reserveCapacity(effectiveBody.count)
        var repairedHunks = 0
        var cleanHunks = 0
        var skipped: [String] = []
        var hunk: [String] = []
        for l in effectiveBody {
            if l.hasPrefix("@@") {
                flushHunk(&hunk, &newBody, &repairedHunks, &cleanHunks, &skipped, fileLines: fileLines)
                newBody.append(l)
            } else {
                hunk.append(l)
            }
        }
        flushHunk(&hunk, &newBody, &repairedHunks, &cleanHunks, &skipped, fileLines: fileLines)

        let kind = (repairedHunks > 0 || didSplit) ? "repaired" : (skipped.isEmpty ? "clean" : "skipped:no_unique_match")
        let prefix = didSplit ? "多 hunk 无 @@ 分隔 → 自动按文件位置切段插裸 @@; " : ""
        let suffix = skipped.isEmpty ? "" : " (\(skipped.joined(separator: "; ")))"
        let detail = "\(prefix)hunk: 修复 \(repairedHunks) / 本就匹配 \(cleanHunks) / 放行 \(skipped.count)\(suffix)"
        return (newBody, ApplyPatchRepair(file: path, kind: kind, detail: detail))
    }

    private static func flushHunk(
        _ hunk: inout [String],
        _ newBody: inout [String],
        _ repaired: inout Int,
        _ clean: inout Int,
        _ skipped: inout [String],
        fileLines: [String]
    ) {
        guard !hunk.isEmpty else { return }
        switch repairHunk(hunk, file: fileLines) {
        case .clean:
            clean += 1
            newBody.append(contentsOf: hunk)
        case .repaired(let fixed):
            repaired += 1
            newBody.append(contentsOf: fixed)
        case .skipped(let reason):
            skipped.append(reason)
            newBody.append(contentsOf: hunk)
        }
        hunk.removeAll()
    }

    private enum HunkOutcome {
        /// Anchors match the file exactly, no change needed.
        case clean
        /// The whole hunk after aligning anchors to real file bytes (incl. raw `+` lines).
        case repaired([String])
        /// Not repaired (0 or multiple matches), with reason.
        case skipped(String)
    }

    /// Repair one hunk: anchors = context (space-prefixed) + deletion (`-`) line
    /// *contents* (prefix stripped), in order should be a contiguous block in the
    /// file. Exact match → Clean; else find candidates by "ignore trailing
    /// whitespace / leading+trailing whitespace", unique → align, else pass through.
    private static func repairHunk(_ hunk: [String], file fileLines: [String]) -> HunkOutcome {
        let anchors: [(idx: Int, content: String)] = hunk.enumerated().compactMap { (idx, l) in
            guard let first = l.first else { return nil }
            if first == " " || first == "-" { return (idx, String(l.dropFirst())) }
            return nil // '+' / empty / other → not an anchor
        }
        if anchors.isEmpty { return .clean } // pure addition, no anchors
        let anchorContents = anchors.map { $0.content }

        // Exact: a contiguous block equal to the anchors exists → no repair needed.
        if !findBlock(fileLines, anchorContents, { $0 == $1 }).isEmpty {
            return .clean
        }

        // Fuzzy: per-line "ignore trailing whitespace"; if still 0, "ignore both ends".
        var matches = findBlock(fileLines, anchorContents, { $0.trimEnd() == $1.trimEnd() })
        var mode = "尾随空格"
        if matches.isEmpty {
            matches = findBlock(fileLines, anchorContents, {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == $1.trimmingCharacters(in: .whitespacesAndNewlines)
            })
            mode = "首尾空白"
        }
        switch matches.count {
        case 1:
            let pos = matches[0]
            // Align anchor lines to real file bytes (preserve hunk +/- / space interleaving + `+` lines).
            var fixed = hunk
            for (k, anchor) in anchors.enumerated() {
                let prefix = String(hunk[anchor.idx].first!)
                let fileLine = fileLines[pos + k]
                fixed[anchor.idx] = "\(prefix)\(fileLine)"
            }
            return .repaired(fixed)
        case let n where n > 1:
            return .skipped("\(mode)下 \(n) 处匹配(歧义)")
        default: // 0 contiguous → try blank-tolerant (model omitted/added blank lines)
            // Blank-tolerant rebuild drops blank anchor lines and uses file blanks → can't
            // faithfully express deleting a blank line (would silently turn into context =
            // not-deleted). If the hunk has a blank-line deletion, bail (don't guess).
            let hasBlankDeletion = hunk.contains { $0.hasPrefix("-") && $0.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if hasBlankDeletion {
                return .skipped("含空白行删除,blank-tolerant 不安全 → 放行")
            }
            let regions = findRegionsBlankTolerant(fileLines, anchorContents)
            switch regions.count {
            case 1:
                let (s, e) = regions[0]
                return .repaired(rebuildHunkWithRegion(hunk, region: Array(fileLines[s..<e])))
            case 0:
                return .skipped("锚点在文件中 0 匹配(疑模型改错内容)")
            case let n:
                return .skipped("忽略空行下 \(n) 处匹配(歧义)")
            }
        }
    }

    /// EP-1 helper: find regions in `fileLines` where the anchor *non-blank* line
    /// sequence locates uniquely (allowing the file region to contain blank lines
    /// the model omitted, but no extra non-blank lines). Returns all `[start, end)`.
    private static func findRegionsBlankTolerant(_ fileLines: [String], _ anchorContents: [String]) -> [(Int, Int)] {
        let nb = anchorContents.map { $0.trimEnd() }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if nb.isEmpty { return [] }
        var regions: [(Int, Int)] = []
        for start in 0..<fileLines.count {
            if fileLines[start].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || fileLines[start].trimEnd() != nb[0] { continue }
            var fi = start
            var ai = 0
            var ok = true
            while ai < nb.count {
                if fi >= fileLines.count { ok = false; break }
                let fl = fileLines[fi]
                if fl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fi += 1; continue }
                if fl.trimEnd() == nb[ai] { ai += 1; fi += 1 }
                else { ok = false; break }
            }
            if ok && ai == nb.count { regions.append((start, fi)) }
        }
        return regions
    }

    /// EP-1 helper: rebuild hunk from the real file region (incl. blanks) —
    /// anchors (context/`-`) align to file bytes, omitted file blanks re-added as
    /// context, `+` insert lines keep their hunk position. The model's own blank
    /// anchor lines are dropped (use the file's blanks instead, avoiding dupes).
    private static func rebuildHunkWithRegion(_ hunk: [String], region: [String]) -> [String] {
        var out: [String] = []
        var fi = 0
        for hl in hunk {
            let first = hl.first
            if first == "+" {
                out.append(hl) // insert line, keep position
            } else if first == " " || first == "-" {
                let prefix = String(first!)
                let content = String(hl.dropFirst())
                if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue } // drop model blank anchor
                // First re-add file blanks the model omitted (as context)
                while fi < region.count && region[fi].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(" \(region[fi])")
                    fi += 1
                }
                if fi < region.count {
                    out.append("\(prefix)\(region[fi])")
                    fi += 1
                } else {
                    out.append(hl)
                }
            } else {
                // no-prefix empty etc → drop, use file blank
            }
        }
        return out
    }

    // MARK: - auto-segment a no-`@@` Update body (MOC-263 P0)

    /// Find the longest contiguous block starting at `anchors[0]` that matches
    /// **uniquely** in `file[floor..]`. Anchors compare by "ignore trailing
    /// whitespace". Returns `(blockLen = matched anchor count, fileStart)`.
    /// Longest & unique → some; longest non-empty match >1 (ambiguous) → none;
    /// all 0 → none. The segment's first anchor must be globally unique in
    /// `file[floor..]`, else its start is ambiguous → bail (don't guess).
    private static func longestUniqueBlock(anchors: [String], file: [String], floor: Int) -> (len: Int, pos: Int)? {
        if anchors.isEmpty || floor >= file.count { return nil }
        let first = anchors[0].trimEnd()
        let firstCount = file[floor...].filter { $0.trimEnd() == first }.count
        if firstCount != 1 { return nil }
        let maxLen = min(anchors.count, file.count - floor)
        for len in stride(from: maxLen, through: 1, by: -1) {
            let block = Array(anchors.prefix(len))
            var hits: [Int] = []
            var start = floor
            while start + len <= file.count {
                if (0..<len).allSatisfy({ file[start + $0].trimEnd() == block[$0].trimEnd() }) {
                    hits.append(start)
                    if hits.count > 1 { break }
                }
                start += 1
            }
            switch hits.count {
            case 1: return (len, hits[0])
            case 0: continue   // too long (straddles a file jump) → shorten
            default: return nil // longest non-empty match is ambiguous → bail
            }
        }
        return nil
    }

    /// Split a no-`@@` Update body into multiple hunks by real file position.
    /// Greedily cut into ordered, non-overlapping, each-uniquely-locatable segments
    /// (each = the longest contiguous anchor block uniquely matching from the
    /// previous segment's end); `+` lines stay with the adjacent segment. Only
    /// return `Some` when N≥2 and every segment is uniquely locatable; single /
    /// any-ambiguous → `nil` (caller passes through). A floating `+` insert line
    /// between segments is positionally ambiguous → always bail.
    private static func segmentNoAtBody(_ body: [String], file: [String]) -> [[String]]? {
        let anchors: [(idx: Int, content: String)] = body.enumerated().compactMap { (idx, l) in
            guard let first = l.first else { return nil }
            if first == " " || first == "-" { return (idx, String(l.dropFirst())) }
            return nil
        }
        if anchors.count < 2 { return nil }
        let anchorContents = anchors.map { $0.content }

        // Greedy segmentation.
        var raw: [(aStart: Int, aEnd: Int, fStart: Int, fEnd: Int)] = []
        var ai = 0
        var floor = 0
        while ai < anchors.count {
            guard let (len, pos) = longestUniqueBlock(anchors: Array(anchorContents[ai...]), file: file, floor: floor) else {
                return nil
            }
            raw.append((ai, ai + len, pos, pos + len))
            ai += len
            floor = pos + len
        }

        // Merge adjacent segments whose file gap is all-blank (model omitted file
        // blanks) → same hunk, don't cut here (leave to repairHunk's blank-tolerant
        // path). Only keep as separate segments when the gap has non-blank lines.
        var groups: [(aStart: Int, aEnd: Int, fStart: Int, fEnd: Int)] = []
        for g in raw {
            if !groups.isEmpty {
                let lastIdx = groups.count - 1
                let gap = Array(file[groups[lastIdx].fEnd..<g.fStart])
                if gap.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    groups[lastIdx].aEnd = g.aEnd
                    groups[lastIdx].fEnd = g.fEnd
                    continue
                }
            }
            groups.append(g)
        }
        if groups.count < 2 { return nil }

        // Floating `+` insert line between segments → bail (positional ambiguity).
        if groups.count >= 2 {
            for gi in 0..<(groups.count - 1) {
                let lastAnchorLine = anchors[groups[gi].aEnd - 1].idx
                let nextAnchorLine = anchors[groups[gi + 1].aStart].idx
                let gapHasAdd = body[(lastAnchorLine + 1)..<nextAnchorLine].contains { $0.hasPrefix("+") }
                if gapHasAdd { return nil }
            }
        }

        // Segment g's body line range: first segment includes leading lines; others
        // start at their first anchor, end at the next segment's first anchor →
        // in-segment / post-segment `+` lines stay with the *previous* segment.
        var subhunks: [[String]] = []
        for gi in 0..<groups.count {
            let lineStart = gi == 0 ? 0 : anchors[groups[gi].aStart].idx
            let lineEnd = gi + 1 < groups.count ? anchors[groups[gi + 1].aStart].idx : body.count
            subhunks.append(Array(body[lineStart..<lineEnd]))
        }
        return subhunks
    }

    /// Find all start `i` in `fileLines` where `fileLines[i..i+anchor.count]`
    /// matches `anchor` per `eq`. Returns all match starts.
    private static func findBlock(_ fileLines: [String], _ anchor: [String], _ eq: (String, String) -> Bool) -> [Int] {
        if anchor.isEmpty || anchor.count > fileLines.count { return [] }
        var hits: [Int] = []
        let upper = fileLines.count - anchor.count
        for i in 0...upper {
            if (0..<anchor.count).allSatisfy({ eq(fileLines[i + $0], anchor[$0]) }) {
                hits.append(i)
            }
        }
        return hits
    }

    // MARK: - V4A envelope completion (MOC-268 terminator disambiguation)

    /// Whether the last patch op is `*** Add File:` targeting a code / structured
    /// config file. Used by `ensureV4aEnvelope` to decide whether a trailing
    /// `+*** End Patch` can be safely stripped to a bare terminator: **only Add
    /// File** (a new file — a bare `*** End Patch` can't be a legit source line →
    /// must be a mistakenly-prefixed terminator) is stripped; `*** Update File:`'s
    /// `+*** End Patch` is a new line (could be adding that literal string into a
    /// fixture) → don't strip. Docs/text/unknown also not stripped (could be
    /// prose). Conservative allowlist.
    static func lastOpIsAddFileCode(_ body: String) -> Bool {
        let lastOp = splitLines(body).reversed().first { l in
            let t = l.trimEnd()
            return t.hasPrefix("*** Add File: ") || t.hasPrefix("*** Update File: ") || t.hasPrefix("*** Delete File: ")
        }
        guard let path = lastOp.flatMap({ stripPrefix($0.trimEnd(), "*** Add File: ") }) else {
            return false // no op, or last op is Update/Delete (not Add File) → don't strip
        }
        let ext = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).pathExtension.lowercased()
        let codeExts: Set<String> = [
            "rs", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "go", "java", "kt", "kts",
            "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "cs", "rb", "php", "swift", "scala",
            "lua", "sql", "sh", "bash", "zsh", "css", "scss", "sass", "less", "html", "htm",
            "xml", "vue", "svelte", "json", "toml", "yaml", "yml", "gradle", "cmake",
            "proto", "graphql", "dart", "r"
        ]
        return codeExts.contains(ext)
    }

    /// Missing-envelope auto-completion: models often write only `*** Add/Update
    /// File:` + content, omitting `*** Begin Patch` / `*** End Patch` → Codex
    /// judges it incomplete → forced retry. When the patch has ≥1 file op, JSON is
    /// complete, but lacks the Begin/End envelope, **purely add markers** (change
    /// no content byte, don't guess). Already-complete / non-patch → as-is.
    ///
    /// MOC-268: a trailing `+*** End Patch` (Add-line prefix) is the
    /// "mistakenly-prefixed terminator" shape. ` `/`-`-prefixed `*** End Patch`
    /// are legit Update hunk lines (deleting/anchoring a residual terminator) →
    /// keep them and append a real terminator. For `+*** End Patch`, disambiguate
    /// by file type: code/structured-config → strip the prefix; docs/text/unknown
    /// → don't guess (don't strip prose, don't append → leave incomplete, let the
    /// model re-emit per the guidance).
    static func ensureV4aEnvelope(_ input: String) -> (String, ApplyPatchRepair?) {
        let isOp: (String) -> Bool = { l in
            let t = l.trimEnd()
            return t.hasPrefix("*** Add File:") || t.hasPrefix("*** Update File:") || t.hasPrefix("*** Delete File:")
        }
        let lines = splitLines(input)
        if !lines.contains(where: isOp) {
            return (input, nil) // not a recognizable patch body, don't touch
        }
        let hasBegin = lines.contains { $0.trimEnd() == "*** Begin Patch" }
        let hasEnd = lines.contains { $0.trimEnd() == "*** End Patch" }
        if hasBegin && hasEnd { return (input, nil) }

        var body = input
        var added: [String] = []
        if !hasBegin {
            // Only safe if the first non-empty line is itself an op line (no leading prose).
            let firstNonempty = lines.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
            if !isOp(firstNonempty) { return (input, nil) }
            body = "*** Begin Patch\n\(body)"
            added.append("Begin Patch")
        }
        if !hasEnd {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let last = splitLines(trimmed).last ?? ""
            if last == "+*** End Patch" {
                if lastOpIsAddFileCode(body) {
                    // Strip the erroneous prefix (cut to the last line's start, keep its
                    // preceding newline; last line is ASCII so the boundary is safe).
                    let head = String(trimmed.dropLast(last.count))
                    body = "\(head)*** End Patch"
                    added.append("End Patch(代码文件·剥误加前缀终止符)")
                } else {
                    // Doc/text/unknown — could be prose. Don't guess, don't append →
                    // leave incomplete for downstream truncation detection / model re-emit.
                    return (body, ApplyPatchRepair(file: "(envelope)", kind: "skipped:ambiguous_prefixed_end",
                        detail: "末行 +*** End Patch 且目标非代码文件(可能是正文)→ 不猜不补全,留 incomplete"))
                }
            } else {
                // ` *** End Patch` / `-*** End Patch` (legit hunk lines) or plain content → append a real terminator.
                body = "\(trimmed)\n*** End Patch"
                added.append("End Patch")
            }
        }
        return (body, ApplyPatchRepair(file: "(envelope)", kind: "repaired",
            detail: "模型漏写信封,自动补全: \(added.joined(separator: " + "))"))
    }

    // MARK: - file reading & cwd helpers

    /// Patch section "anchor probe", each `(isHeader, text)`:
    /// • context(` `)/deletion(`-`) lines → `(false, content)`, matched by exact
    ///   whole line (trim) across candidate files;
    /// • `@@ <header>` header text → `(true, header)`, matched by *substring*
    ///   (a partial header is a substring of a real whole line).
    /// Used by `readPatchFile` to pick the target file among same-named candidates.
    private static func anchorProbe(_ body: [String]) -> [(isHeader: Bool, text: String)] {
        var probe: [(isHeader: Bool, text: String)] = []
        for l in body {
            let first = l.first
            if first == " " || first == "-" {
                probe.append((false, String(l.dropFirst())))
            } else if first == "+" {
                // new line — not in the target file, not a probe
            } else {
                if let h = stripPrefix(l, "@@ ") {
                    let h = h.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !h.isEmpty { probe.append((true, h)) }
                } else if !l.isEmpty && !l.hasPrefix("@@") && !l.hasPrefix("*** ") {
                    // unprefixed line (model omitted prefix; fixUnprefixedLines matches
                    // by exact whole file line) → whole line as exact probe so the
                    // empty-probe path still picks the right file among candidates.
                    probe.append((false, l))
                }
            }
        }
        return probe
    }

    /// Resolve & read the patch target file across candidate cwds (MOC-263 P1+P2).
    /// `primary` (current request cwd, usually nil for apply_patch) first, then
    /// the recent cwd history. `probe` = the patch's context/deletion anchor lines;
    /// when multiple candidate cwds all have the same-named relative file, pick the
    /// one whose content hits the most probe anchors (= the file the patch is
    /// really about), not just the first readable. All-candidates-0-hits → none
    /// (skip, safe). Empty probe (pure-add patch) → first readable (best-effort).
    /// Absolute paths read directly.
    private static func readPatchFile(relpath: String, primary: String?, probe: [(isHeader: Bool, text: String)]) -> String? {
        if relpath.hasPrefix("/") {
            return try? String(contentsOfFile: relpath, encoding: .utf8)
        }
        // ① fresh primary is authoritative: current request cwd + readable → use it.
        //    probe is only a tie-breaker among same-named candidates, never a gate
        //    (a partial `@@` header / single candidate would be wrongly "unreadable").
        if let c = primary, !c.isEmpty {
            let abs = (c as NSString).appendingPathComponent(relpath)
            if let content = try? String(contentsOfFile: abs, encoding: .utf8) {
                return content
            }
        }
        // ② recent cwd candidate history (most-recent-first); read all that exist.
        var readable: [(abs: String, content: String)] = []
        for c in CwdHistory.shared.recall() {
            let abs = (c as NSString).appendingPathComponent(relpath)
            if let content = try? String(contentsOfFile: abs, encoding: .utf8) {
                readable.append((abs, content))
            }
        }
        switch readable.count {
        case 0: return nil
        case 1: return readable[0].content // single candidate → use it (don't skip on 0 probe hits)
        default: break
        }
        // ③ multiple same-named candidates → pick by anchor probe score.
        let probeT = probe.map { (isHeader: $0.isHeader, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
        if probeT.isEmpty {
            return readable[0].content // no anchors (pure-add patch) → most recent
        }
        let scores = readable.map { (_, content) -> Int in
            let fl = splitLines(content).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return probeT.filter { (isHeader, t) in
                if isHeader {
                    return fl.contains { !$0.isEmpty && $0.contains(t) }
                } else {
                    return fl.contains { $0 == t }
                }
            }.count
        }
        let maxScore = scores.max() ?? 0
        if maxScore == 0 { return nil } // no candidate contains any anchor → none is the target → skip
        if scores.filter { $0 == maxScore }.count != 1 { return nil } // tied → ambiguous → don't guess
        guard let bestIdx = scores.firstIndex(of: maxScore) else { return nil }
        return readable[bestIdx].content
    }

    /// Any cwd available (current request's `primary` or history)? Byte-exact
    /// rules short-circuit on this.
    private static func hasCwdCandidate(_ primary: String?) -> Bool {
        if let p = primary, !p.isEmpty { return true }
        return !CwdHistory.shared.recall().isEmpty
    }

    /// Resolve a patch path to an absolute path. Absolute passes through;
    /// relative is joined with `cwd`.
    private static func resolvePath(_ path: String, _ cwd: String) -> String {
        if path.hasPrefix("/") { return path }
        return (cwd as NSString).appendingPathComponent(path)
    }

    // MARK: - line helpers

    /// Split into lines the way Rust's `str::lines()` does: drops the final empty
    /// element produced by a trailing newline, strips a trailing `\r` per line.
    private static func splitLines(_ s: String) -> [String] {
        var lines = s.components(separatedBy: "\n")
        if !lines.isEmpty && lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// Rejoin lines, preserving the original's trailing-newline semantics.
    private static func rejoin(_ lines: [String], preservingTrailingNewlineOf original: String) -> String {
        var s = lines.joined(separator: "\n")
        if original.hasSuffix("\n") { s += "\n" }
        return s
    }

    private static func stripPrefix(_ s: String, _ p: String) -> String? {
        s.hasPrefix(p) ? String(s.dropFirst(p.count)) : nil
    }
}

// MARK: - String helpers

private extension String {
    /// Trim trailing whitespace (mirrors Rust `str::trim_end()`).
    func trimEnd() -> String {
        var s = self
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }
}

// MARK: - process-global cwd candidate history

private final class CwdHistory {
    static let shared = CwdHistory()
    private let lock = NSLock()
    private var queue: [String] = [] // most-recent-first
    private let cap = 12

    private init() {}

    func remember(_ cwd: String) {
        lock.lock(); defer { lock.unlock() }
        if let i = queue.firstIndex(of: cwd) { queue.remove(at: i) }
        queue.insert(cwd, at: 0)
        while queue.count > cap { queue.removeLast() }
    }

    func recall() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return queue
    }
}
