import Foundation

/// Chat-path apply_patch guidance, ported from codex-app-transfer
/// `request/tools.rs` (tool/input descriptions) and `request.rs` (system
/// guidance). The upstream Codex freeform `apply_patch` description says "do not
/// wrap the patch in JSON" because the Responses lark grammar accepts raw text —
/// but on the chat-completions path the model MUST emit a function call whose
/// `input` argument is a JSON string containing the V4A patch. These constants
/// rewrite the description / inject a system message so the model sees
/// instructions consistent with the wire format it has to produce, including the
/// `@@` single-sided anchor syntax and Add File `+`-prefix rules empirically
/// observed to fail on non-OpenAI chat providers (MOC-194 / MOC-268).
///
/// The text is empirically tuned — ported verbatim. Swift adjacent string
/// literals are implicitly concatenated, mirroring the Rust `concat!` pieces.
enum ApplyPatchGuidance {

    // MARK: - Tool-level description (EN, replaces the freeform apply_patch description)

    static let toolDescription = "Edit files using the apply_patch tool. " +
        "**ALWAYS use this tool to write file content** — new files, single-line edits, and full-file rewrites alike. " +
        "**NEVER use shell `cat <<EOF > file` / `printf '<content>' > file` / `echo '<content>' > file` / any `>` redirect to write actual file content** — doing so bypasses the Codex diff UI and audit trail. " +
        "(To create brand-new or empty files, use `*** Add File: <path>` — not a shell redirect.) " +
        "**PREFER SURGICAL TARGETED EDITS.** To change or replace existing content, emit ONLY the specific `-` (old) and `+` (new) lines for what actually changes, with minimal context. Do NOT regenerate the whole file/section and append it; do NOT rewrite an entire file just because part of it changed. Reserve full-file replacement (`*** Delete File: <path>` then `*** Add File: <path>` with every line `+`-prefixed, in one patch) for genuine cases ONLY: creating brand-new content, or when almost every line truly differs. " +
        "Call this function with a single `input` string containing a V4A patch. " +
        "**The patch MUST start with `*** Begin Patch` as the literal first line** (no leading whitespace, no other content before it), and end with `*** End Patch`. " +
        "Each file operation header is one of `*** Add File: <path>`, " +
        "`*** Update File: <path>` (optionally followed by `*** Move to: <path>`, but Update with Move STILL requires at least one hunk — see RENAME / MOVE FILE section), " +
        "or `*** Delete File: <path>`. " +
        "Within Update hunks, the simplest form is just `-`/`+` lines with no `@@` and " +
        "no context (suitable when the `-` line is unique in the file). If disambiguation " +
        "is needed, add space-prefixed context lines, or a single-sided `@@ <header>` " +
        "marker (e.g. `@@ class Foo`, `@@ def bar():`) — NEVER add a trailing `@@`. " +
        "Lines are `-line` (removed, no space after `-`), `+line` (added, no space after `+`), " +
        "or ` line` (single leading space = unchanged context). " +
        "Use relative paths only (never absolute). " +
        "Embed real newlines as `\\n` inside the JSON string value for `input`.\n\n" +
        "CRITICAL `@@` ANCHOR SYNTAX (the most common cause of patch rejection on chat-completions providers):\n" +
        "The V4A `@@` operator is SINGLE-SIDED: write `@@ <header>` where `<header>` " +
        "names the class/function/section the hunk belongs to (e.g. `@@ class MyClass`, " +
        "`@@ def my_function():`, `@@ fn main() {`). " +
        "**NEVER write a trailing `@@` (e.g. `@@ def f(): @@`)** — Codex Desktop's V4A " +
        "applier will treat the trailing `@@` as literal text inside the anchor and " +
        "fail with `Failed to find context '... @@'`. " +
        "The `@@` header is OPTIONAL: if 3 lines of surrounding context already uniquely " +
        "identify the location, omit the `@@` line entirely. " +
        "If a single `@@ <header>` is ambiguous (same name appears in multiple classes), " +
        "use MULTIPLE `@@` lines on separate rows (e.g. `@@ class Outer\\n@@ def inner():`) " +
        "to narrow down — each line is one `@@ <header>`, single-sided.\n\n" +
        "ADD FILE FORMAT (different from Update — no hunks, no `@@`):\n" +
        "After `*** Add File: <path>`, **every line of the new file's content MUST be " +
        "prefixed with `+`**, including blank lines (write them as a bare `+` on its own " +
        "row). Do NOT use `@@` markers, hunks, or space-prefixed context lines in an " +
        "Add File block — they are reserved for Update File. Writing raw source code " +
        "(e.g. `def main():` with no `+` prefix) directly after `*** Add File:` causes " +
        "`'def main():' is not a valid hunk header` errors.\n\n" +
        "RENAME / MOVE FILE (`*** Move to:` always needs ≥1 hunk, never empty):\n" +
        "`*** Update File: <old>\\n*** Move to: <new>` followed by **at least one hunk** with `-`/`+` lines (or `*** End of File` marker). An empty Update+Move block fails with `Update file hunk for path '<old>' is empty`. " +
        "**For pure rename (no content change)**: use a Delete + Add File pair within the same patch instead — `*** Delete File: <old>` followed by `*** Add File: <new>` with every original line prefixed `+`. " +
        "**For rename WITH content change**: keep `*** Update File:` + `*** Move to:` and include the actual `-`/`+` hunks for the changes.\n\n" +
        "LINE PREFIX FORMAT (zero whitespace between prefix and content):\n" +
        "Every line in a hunk starts with exactly ONE character followed by content with " +
        "NO intervening space — `-line_content` (NOT `- line_content`), `+line_content` " +
        "(NOT `+ line_content`), ` line_content` (single leading space = unchanged context). " +
        "Codex Desktop V4A applier may tolerate a stray space, but other apply_patch " +
        "implementations are strict — keep the prefix tight.\n\n" +
        "EXAMPLE 1 (MINIMAL UPDATE — preferred form for simple single-line edits): " +
        "When the `-` line you remove is byte-exact and unique in the file, you may omit " +
        "BOTH `@@` markers AND context lines — just write `-` and `+` lines directly:\n" +
        "*** Begin Patch\n" +
        "*** Update File: src/config.py\n" +
        "-DEBUG = False\n" +
        "+DEBUG = True\n" +
        "*** End Patch\n" +
        "This is the simplest and most reliable mode on chat-completions providers. Use " +
        "it whenever the `-` line is unique enough to pinpoint the change location.\n\n" +
        "EXAMPLE 2 — Update with `@@` header (only when needed: same name in multiple " +
        "classes/functions, or you want to disambiguate which occurrence to change):\n" +
        "*** Begin Patch\n" +
        "*** Update File: src/main.rs\n" +
        "@@ fn main() {\n" +
        "-    let x = 1;\n" +
        "+    let x = 2;\n" +
        "     println!(\"{}\", x);\n" +
        "*** End Patch\n" +
        "Notice: `@@ fn main() {` is single-sided (no trailing `@@`). The `-` line " +
        "is byte-exact what currently appears in the file. The space-prefixed line is " +
        "kept as-is for context. Use this form when `let x = 1;` appears in multiple " +
        "functions and you need to specify which one.\n\n" +
        "EXAMPLE 3 — create a brand new file (Add File, no `@@`, every line `+`):\n" +
        "*** Begin Patch\n" +
        "*** Add File: hello.py\n" +
        "+def greet(name: str) -> str:\n" +
        "+    return f\"Hello, {name}!\"\n" +
        "+\n" +
        "+if __name__ == \"__main__\":\n" +
        "+    print(greet(\"world\"))\n" +
        "*** End Patch\n" +
        "Notice: no `@@`, every line has `+` (including the blank line as a bare `+`).\n\n" +
        "EXAMPLE 4 — update a function body with context lines (no `@@`, use when the " +
        "`-` line is not unique enough by itself but a few surrounding lines pin it):\n" +
        "*** Begin Patch\n" +
        "*** Update File: src/util.py\n" +
        " def divide(a, b):\n" +
        "     \"\"\"Divide two numbers.\"\"\"\n" +
        "-    return a / b\n" +
        "+    if b == 0:\n" +
        "+        raise ValueError(\"divide by zero\")\n" +
        "+    return a / b\n" +
        "*** End Patch\n" +
        "Notice: 2 lines of space-prefixed context above the `-` line uniquely identify " +
        "where to apply. Use this when minimal form (EXAMPLE 1) is ambiguous but `@@` " +
        "(EXAMPLE 2) is overkill.\n\n" +
        "BYTE-EXACT MATCHING (#1 cause of `Failed to find context` on this path):\n" +
        "Every `-` line and every space-prefixed context line MUST match the file " +
        "byte-for-byte — same leading whitespace, no trimmed trailing spaces, exact " +
        "characters. If unsure, run `cat <path>` or `sed -n '1,80p' <path>` via shell " +
        "to read it first, then compose the patch from real bytes. Guessing or " +
        "paraphrasing produces `Failed to find context '<your guess>'` errors.\n\n" +
        "CHAT-PATH GOTCHAS (the lark grammar is gone here; observed empirically with non-OpenAI providers):\n" +
        "1. Use the SINGLE-SIDED `@@ <header>` form. The double-sided `@@ ... @@` form " +
        "is NOT V4A — the trailing `@@` becomes literal text and breaks context matching.\n" +
        "2. Do NOT combine `*** Add File: foo` and `*** Update File: foo` in the SAME patch — Update reads the file before Add lands on disk. " +
        "Either make Add File write the final content in one shot, or split into two separate patches.\n" +
        "3. To populate a brand-new or empty file, use `*** Add File: <path>` with every line `+`-prefixed (not `*** Update File:`).\n" +
        "4. In a multi-line file, lone `+` lines without a corresponding `-` APPEND below the previous context — they do NOT replace any existing line. " +
        "To change a line, use `-` to remove the old line AND `+` to add the new one; do not omit the `-`.\n" +
        "5. If an Update fails with `Failed to find context`, the `-`/context lines did not match the file byte-for-byte. Re-read the file (`cat <path>` / `sed -n`) and fix those lines to match exactly, then retry the SAME surgical Update. Do NOT escalate to rewriting or re-appending the whole file/section — keep the edit targeted to the lines that change.\n" +
        "6. `*** Begin Patch` MUST be the literal first line of `input` — no preamble, no whitespace, no `*** Add File:` directly. Forgetting it causes `invalid patch: The first line of the patch must be '*** Begin Patch'`.\n" +
        "7. `*** Update File: <old>` + `*** Move to: <new>` requires at least one hunk (rename-only is NOT supported via Move). For pure rename without content change, use `*** Delete File: <old>` + `*** Add File: <new>` (copy original content with `+` prefix). Empty Update+Move fails with `Update file hunk for path '<old>' is empty`."

    // MARK: - Parameter-level input description (EN, mirrors tool-level in compact form)

    static let inputDescription = "A V4A patch starting with `*** Begin Patch` and ending with `*** End Patch`. " +
        "Use `*** Add File:`, `*** Update File:`, or `*** Delete File:` headers. " +
        "Update File simplest form: just `-line`/`+line` rows directly after the header " +
        "(no `@@`, no context) — use this when the `-` line is unique in the file. " +
        "If ambiguous, add space-prefixed context ` line` lines around the change, or " +
        "single-sided `@@ <header>` (e.g. `@@ def func():`, NO trailing `@@`). " +
        "Writing `@@ <header> @@` (double-sided) fails with `Failed to find context '... @@'`. " +
        "Lines are `-text`/`+text`/` text` (single char prefix, NO space between prefix and content). " +
        "Add File uses NO `@@` and NO hunks — prefix EVERY new content line with `+` " +
        "(blank lines as bare `+`). Relative paths only. " +
        "`-` lines and space-prefixed context MUST be byte-exact to the file's current content " +
        "(read via `cat <path>` first if unsure) — guessing produces `Failed to find context` errors. " +
        "**PREFER surgical targeted Update** (`-` old line + `+` new line for ONLY the changed lines, minimal context) — do NOT regenerate or append the whole file/section. " +
        "Chat-path gotchas: do not Add+Update the same path in one patch; for brand-new/empty files use `*** Add File:` (not Update); lone `+` without `-` APPENDS rather than replaces — to replace a line, pair `-` (old) with `+` (new). " +
        "If Update fails with `Failed to find context`, re-read the file (`cat`) and fix the `-`/context lines to be byte-exact, then retry the SAME targeted Update — do NOT escalate to rewriting the whole file. " +
        "**`*** Begin Patch` MUST be the literal first line of `input`** (no preamble). " +
        "**`*** Update File: <old>` + `*** Move to: <new>` requires ≥1 hunk** — for pure rename use `*** Delete File:` + `*** Add File:` instead."

    // MARK: - System guidance (EN)

    static let chatPathSystemGuidanceEN = "[apply_patch chat-path guidance — injected by CodexSwitch adapter because the upstream lark grammar constraint is unavailable on chat function-call providers]\n" +
        "\n" +
        "**ALWAYS use the `apply_patch` tool to write file content** — new files, single-line edits, and full-file rewrites alike. **NEVER use shell `cat <<EOF > file` / `printf '<content>' > file` / `echo '<content>' > file` / any `>` redirect to write actual file content** — doing so bypasses the Codex diff UI and audit trail. **EQUALLY, NEVER use `sed -i` / `perl -i` / `ed`, or shell line-number deletion (e.g. `sed -i 'N,Md' file`), to edit or delete existing file content** — in-place shell editors bypass the diff UI and are fragile to line-number drift across successive edits (deleting by stale line numbers corrupts the file). (To create a brand-new or empty file, use `*** Add File: <path>` — not a shell redirect.) **PREFER surgical targeted edits**: to change or replace existing content, emit ONLY the specific `-` (old) and `+` (new) lines for what actually changes — keep each hunk minimal, and do NOT add or remove blank lines as part of an edit unless a blank line itself is the change (blank-line `+`/`-` are positionally ambiguous and may silently fail to apply). **To DELETE content — even a large contiguous block spanning many lines — emit those lines as `-` lines in an apply_patch hunk, or use `*** Delete File: <path>` to remove an entire file; do NOT switch to `sed`/`python` line-range deletion just because the block is large.** Multiple non-adjacent edits to the SAME file may go in ONE apply_patch call as separate hunks. Do NOT regenerate the whole file/section and append it, and do NOT rewrite an entire file just because part of it changed. Reserve full-file replacement (`*** Delete File: <path>` then `*** Add File: <path>` with every line `+`-prefixed, in one patch) for genuine cases ONLY: creating brand-new content, or when almost every line truly differs.\n" +
        "\n" +
        "When you call the `apply_patch` tool, follow these rules empirically observed with non-OpenAI chat providers:\n" +
        "\n" +
        "1. PREFERRED Update File form is MINIMAL: just `-line` (the row to remove, byte-exact) and `+line` (the new row) directly after `*** Update File: <path>` — NO `@@`, NO context lines. " +
        "Use this whenever the `-` line is unique in the file (true for most simple single-line edits, config changes, function signatures, etc.). Example:\n" +
        "  *** Update File: src/config.py\n" +
        "  -DEBUG = False\n" +
        "  +DEBUG = True\n" +
        "If the `-` line alone is ambiguous (same line text in multiple places), add space-prefixed context lines (` line`) above/below to pin it down. " +
        "Only if context lines are also insufficient, add a SINGLE-SIDED `@@ <header>` marker on its own row (`@@ class Foo`, `@@ def bar():`, `@@ fn main() {`). " +
        "**NEVER add a trailing `@@`** (`@@ <header> @@` is wrong) — Codex Desktop's V4A applier treats trailing `@@` as literal text and fails with `Failed to find context '... @@'`. " +
        "For deeply nested disambiguation use MULTIPLE `@@` lines on separate rows (e.g. `@@ class Outer\\n@@ def inner():`), each single-sided.\n" +
        "\n" +
        "2. Add File uses NO `@@` markers and NO hunks. After `*** Add File: <path>`, prefix every line of the new file's CONTENT with `+`, including blank lines (write them as a bare `+` on its own row). Raw source code without `+` prefix (e.g. `def main():` directly) causes `'def main():' is not a valid hunk header` errors. " +
        "But the structural markers `*** Begin Patch` / `*** Add File:` / `*** End Patch` are NOT content — write them with NO prefix. In particular **do NOT prefix the terminator** (`+*** End Patch` is wrong); a `+`-prefixed terminator is treated as a content line and leaves a literal `*** End Patch` row at the end of the created file.\n" +
        "\n" +
        "3. Every `-` line and space-prefixed context line MUST match the file byte-for-byte (same leading whitespace, no trimmed trailing spaces, exact characters). If unsure, run `cat <path>` or `sed -n '1,80p' <path>` via shell first, then compose the patch from real bytes. Guessing produces `Failed to find context '<your guess>'` errors.\n" +
        "\n" +
        "3a. Line prefix is a SINGLE character with NO space between prefix and content: write `-DEBUG = False` (not `- DEBUG = False`), `+DEBUG = True` (not `+ DEBUG = True`), and ` keepme` (single leading space, for unchanged context). Codex Desktop V4A applier may tolerate a stray space, but other apply_patch implementations are strict — keep the prefix tight.\n" +
        "\n" +
        "4. Do NOT combine `*** Add File: <path>` and `*** Update File: <path>` for the same path in a single patch. The Update step reads the file before the Add step lands on disk, so it sees an empty file and fails. Either: (a) make `*** Add File:` write the final content in one shot, or (b) split into two separate `apply_patch` invocations.\n" +
        "\n" +
        "5. To populate a brand-new or empty file, use `*** Add File: <path>` with every line `+`-prefixed (not `*** Update File:`, not a shell redirect).\n" +
        "\n" +
        "6. In a multi-line file, lone `+` lines without a corresponding `-` line APPEND below the previous context — they do NOT replace any existing line. To change an existing line, you MUST include BOTH a `-` line (removing the old content) AND a `+` line (adding the new content). " +
        "A space-prefixed context line is MATCHED against the file, never added — it must already exist in the file. To introduce a brand-new line, prefix it `+`; writing a not-yet-present line as a context line (or with no prefix) yields a hunk with no real change that fails to apply or `Failed to find context`.\n" +
        "\n" +
        "7. If an Update fails with `Failed to find context`, the `-`/context lines did not match the file byte-for-byte — re-read the file (`cat <path>` / `sed -n`) and fix those lines to match exactly, then retry the SAME surgical Update. Do NOT escalate to rewriting or re-appending the whole file; keep the edit targeted to the lines that change. " +
        "When you make several edits to the SAME file in one turn, each applied hunk shifts the file's content — put related edits in ONE patch as separate hunks, or re-read the file between separate calls. A `-` line that no longer matches may have ALREADY been removed (by a prior hunk or an earlier edit this turn) — confirm it still exists before re-issuing the same deletion, instead of blindly retrying.\n" +
        "\n" +
        "8. `*** Begin Patch` MUST be the literal first line of the `input` string — no leading whitespace, no other content before it, never put `*** Add File:` or any operation header directly. Forgetting this causes `invalid patch: The first line of the patch must be '*** Begin Patch'`.\n" +
        "\n" +
        "9. `*** Update File: <old>` + `*** Move to: <new>` REQUIRES at least one hunk (with `-`/`+` lines or `*** End of File` marker). An empty Update+Move block fails with `Update file hunk for path '<old>' is empty`. **For pure rename without content change**, use `*** Delete File: <old>` + `*** Add File: <new>` within the same patch (copy original content with `+` prefix per line). **For rename WITH content change**, keep Update+Move and include the actual `-`/`+` hunks.\n" +
        "\n" +
        "10. Editing memory files (e.g. `~/.codex/memories/MEMORY.md`) needs extra care: a concurrent process may rewrite the file between when you last read it and when your patch applies. `cat` the file IMMEDIATELY before patching, make every `-`/context line a row that exists in the CURRENT file, and use minimal unique anchors (e.g. a single `@@ <section header>` plus only the exact rows you change). Stale `-` lines — content a concurrent consolidation already changed — fail with `Failed to find context`; on failure re-read and rebuild from the current bytes rather than retrying the stale patch.\n" +
        "\n" +
        "Following these rules avoids retry storms and improves the success rate on first attempt."

    // MARK: - System guidance (ZH)
    //
    // V4A keywords / error messages / shell examples stay English (Codex CLI's
    // V4A parser / error matcher only recognize the English literals); emphasis
    // words translated. Mirrors the EN version rule-by-rule (rule 10 = MOC-268
    // memory-file guidance).

    static let chatPathSystemGuidanceZH = "[apply_patch chat-path 指引 — 由 CodexSwitch adapter 注入,因为上游 lark 语法约束在 chat function-call provider 上不可用]\n" +
        "\n" +
        "**务必使用 `apply_patch` tool 写文件内容** —— 新建文件、单行编辑、整文件重写都一样。**绝不使用 shell `cat <<EOF > file` / `printf '<content>' > file` / `echo '<content>' > file` / 任何 `>` 重定向来写实际文件内容** —— 这样做会绕过 Codex diff UI 和审计 trail。**同样,绝不使用 `sed -i` / `perl -i` / `ed`、或 shell 按行号删除(如 `sed -i 'N,Md' file`)来编辑或删除已有文件内容** —— 就地 shell 编辑器绕过 diff UI,且对多次编辑间的行号漂移很脆弱(按过期行号删会切错、损坏文件)。(新建或空文件用 `*** Add File: <path>` —— 不要用 shell 重定向。)**优先外科式针对性编辑**:要改/替换已有内容时,只发改动那几行的 `-`(旧)和 `+`(新),保持每个 hunk 最小;且**不要**把增删空行作为编辑的一部分,除非空行本身就是改动(空行 `+`/`-` 位置歧义、可能静默 apply 失败)。**删除内容 —— 即便是跨很多行的大段连续块 —— 也用 apply_patch hunk 里的 `-` 行表达,或用 `*** Delete File: <path>` 删整个文件;不要因为块大就改用 `sed`/`python` 按行范围删除。** 对同一文件的多处不相邻编辑可以放进**一次** apply_patch 调用、分成多个 hunk。**不要**整段重新生成再追加,**不要**因为改了一部分就整文件重写。整文件替换(同一 patch 内 `*** Delete File: <path>` + `*** Add File: <path>`、每行前缀 `+`)**仅限**真正需要时:新建全新内容,或几乎每行都不同。\n" +
        "\n" +
        "调用 `apply_patch` tool 时,遵循以下基于非 OpenAI chat provider 实战观察总结的规则:\n" +
        "\n" +
        "1. 推荐的 Update File 形式是**最简形态**:仅 `-line`(要删的行,byte-exact)和 `+line`(新行)直接跟在 `*** Update File: <path>` 之后 —— 无 `@@`、无 context 行。" +
        "凡是 `-` 行在文件里**唯一**时(简单单行编辑、配置改动、function 签名等绝大多数场景皆是)就用这个形态。例:\n" +
        "  *** Update File: src/config.py\n" +
        "  -DEBUG = False\n" +
        "  +DEBUG = True\n" +
        "若 `-` 行单独**有歧义**(同一行文本在文件多处出现),在上方/下方加空格前缀的 context 行(` line`)钉住它。" +
        "若 context 行也不足以消歧,再在独立行上加**单端** `@@ <header>` 标记(`@@ class Foo`、`@@ def bar():`、`@@ fn main() {`)。" +
        "**绝不加尾随 `@@`**(`@@ <header> @@` 是错的)—— Codex Desktop 的 V4A applier 会把尾随 `@@` 当字面文本,报 `Failed to find context '... @@'`。" +
        "深层嵌套消歧时用**多个** `@@` 行各占一行(例如 `@@ class Outer\\n@@ def inner():`),每条都是单端。\n" +
        "\n" +
        "2. Add File **不用** `@@` 标记、**不用** hunk。`*** Add File: <path>` 之后,新文件**每一行内容**(包括空行,写成单个 `+` 占一行)都前缀 `+`。没 `+` 前缀的原始源码(例如直接写 `def main():`)会触发 `'def main():' is not a valid hunk header` 错误。" +
        "但结构标记 `*** Begin Patch` / `*** Add File:` / `*** End Patch` **不是内容,不加前缀**。尤其**绝不给终止符加前缀**(`+*** End Patch` 是错的):带 `+` 的终止符会被当成内容行,在新建文件末尾留下一行字面 `*** End Patch`。\n" +
        "\n" +
        "3. 每个 `-` 行和空格前缀的 context 行**必须**跟文件 byte-for-byte 一致(同样的前导 whitespace,不能 trim 尾随空格,字符完全相同)。不确定时先用 shell 跑 `cat <path>` 或 `sed -n '1,80p' <path>` 查一下,再用真实字节组 patch。靠猜会触发 `Failed to find context '<your guess>'` 错误。\n" +
        "\n" +
        "3a. 行前缀是**单字符**,前缀和内容之间**没有空格**:写 `-DEBUG = False`(不是 `- DEBUG = False`)、`+DEBUG = True`(不是 `+ DEBUG = True`),context 行 ` keepme`(单个前导空格)。Codex Desktop V4A applier 可能容忍多余空格,但其它 apply_patch 实现严格 —— 前缀写紧凑。\n" +
        "\n" +
        "4. **不要**在同一 patch 内对同一路径同时用 `*** Add File: <path>` 和 `*** Update File: <path>`。Update 步骤会在 Add 步骤落盘前读文件,看到空文件后失败。要么 (a) 让 `*** Add File:` 一次性写最终内容,要么 (b) 拆成两个独立的 `apply_patch` 调用。\n" +
        "\n" +
        "5. 新建或空文件用 `*** Add File: <path>`、每行前缀 `+`(不要用 `*** Update File:`,也不要用 shell 重定向)。\n" +
        "\n" +
        "6. 多行文件里,**没有**对应 `-` 行的孤立 `+` 行会**追加**在上文 context 之下 —— **不会**替换任何已有行。要修改已有行,**必须**同时包含 `-` 行(删旧内容)和 `+` 行(加新内容)。" +
        "空格前缀的 context 行是拿来**跟文件匹配**的、绝不新增 —— 它必须已存在于文件中。要引入全新行,前缀 `+`;把文件里还没有的行写成 context(或不加前缀)会得到一个无实际改动、apply 失败或 `Failed to find context` 的 hunk。\n" +
        "\n" +
        "7. Update 报 `Failed to find context` 时,说明 `-`/context 行跟文件 byte 对不上 —— 重新 `cat <path>` / `sed -n` 读文件、把这些行改成完全一致,再重试**同一个**针对性 Update。**不要**升级成整文件重写/重新追加,把编辑保持在改动的那几行。" +
        "在**一次**回合里对**同一文件**做多处编辑时,每个已应用的 hunk 都会改变文件内容 —— 把相关编辑放进**一个** patch 的多个 hunk,或在多次独立调用之间重新读文件。某个 `-` 行不再匹配,可能是它**已经被删掉**(被前一个 hunk、或本回合更早的编辑)—— 重发同一删除前先确认它还在,别盲目重试。\n" +
        "\n" +
        "8. `*** Begin Patch` **必须**是 `input` 字符串的字面第一行 —— 不能有前导空格,前面不能有其它内容,绝不能直接写 `*** Add File:` 或任何操作 header。漏了会触发 `invalid patch: The first line of the patch must be '*** Begin Patch'`。\n" +
        "\n" +
        "9. `*** Update File: <old>` + `*** Move to: <new>` **要求**至少一个 hunk(带 `-`/`+` 行或 `*** End of File` 标记)。空的 Update+Move 块会报 `Update file hunk for path '<old>' is empty`。**纯重命名不改内容**时,在同一 patch 内用 `*** Delete File: <old>` + `*** Add File: <new>`(把原内容每行前缀 `+` 复制过去)。**重命名同时改内容**时,保留 Update+Move 并写真实的 `-`/`+` hunk。\n" +
        "\n" +
        "10. 编辑 memory 文件(如 `~/.codex/memories/MEMORY.md`)要格外小心:并发进程可能在你上次读它、到你的 patch 落地之间重写该文件。打 patch **前立即** `cat` 该文件,让每个 `-`/context 行都是**当前**文件里存在的行,并用最小唯一锚点(如单个 `@@ <section header>` + 只写你实际改的那几行)。过期的 `-` 行 —— 内容已被并发固化(consolidation)改掉 —— 会报 `Failed to find context`;失败时重新读、按当前字节重建,而不是重试过期 patch。\n" +
        "\n" +
        "遵循这些规则可以避免 retry 风暴,提升首次尝试的成功率。"

    /// Chinese users get an explicit "reply in Chinese" directive prepended to the
    /// guidance (it sits at the top of the system instruction block, so the model
    /// reads it first and doesn't drift to English under the large English Codex
    /// system template).
    private static let chineseLanguageDirective =
        "**请始终使用简体中文回复用户**(代码、命令、标识符、文件路径等技术内容保持原文,不要翻译)。"

    /// Pick the apply_patch chat-path guidance for the current UI language.
    static func systemGuidance(for language: AppLanguage) -> String {
        switch language {
        case .simplifiedChinese: return chatPathSystemGuidanceZH
        case .english: return chatPathSystemGuidanceEN
        }
    }

    /// Build the apply_patch chat-path guidance system message. Chinese users get
    /// the language directive prepended into the **same** message (so it doesn't
    /// shift subsequent message indices).
    static func chatPathGuidanceMessage(language: AppLanguage) -> [String: Any] {
        let guidance = systemGuidance(for: language)
        let content: String
        if language == .simplifiedChinese {
            content = "\(chineseLanguageDirective)\n\n\(guidance)"
        } else {
            content = guidance
        }
        return ["role": "system", "content": content]
    }

    /// Whether the Responses request body's `tools` array registers `apply_patch`
    /// (as `type:"custom", name:"apply_patch"`, before the chat-side lowering).
    /// Decides whether this turn gets the chat-path guidance injected.
    static func toolsRegisterApplyPatch(_ body: [String: Any]) -> Bool {
        guard let tools = body["tools"] as? [[String: Any]] else { return false }
        return tools.contains {
            ($0["name"] as? String) == ApplyPatchPreflight.applyPatchToolName
                && ($0["type"] as? String) == "custom"
        }
    }
}
