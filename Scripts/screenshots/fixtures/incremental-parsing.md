# Incremental Parsing Notes

Re-parsing a 4,000-line document on every keystroke was costing 180 ms of
main-thread time. Typing felt like wading. This note records what the
profiler actually showed, and the three changes that brought it down to 6 ms.

## Where the time went

`Walker.visit(_:)` translated every cmark source range into a UTF-16 offset
by rescanning the document from byte zero. With *n* blocks that is quadratic
— and because cmark reports `column` in **UTF-8 bytes**, not characters, the
rescan could not simply be skipped.

```swift
/// Caches line starts so a cmark byte column maps to a UTF-16 offset
/// in O(line length) instead of O(document length).
struct LineTable {
    private let lineStarts: [Int]

    init(utf8 bytes: [UInt8]) {
        var starts = [0]
        for (offset, byte) in bytes.enumerated() where byte == 0x0A {
            starts.append(offset + 1)
        }
        self.lineStarts = starts
    }

    func utf16Offset(line: Int, column: Int, in text: String) -> Int {
        let byteStart = lineStarts[line - 1] + column - 1
        return text.utf16Offset(forUTF8Offset: byteStart)
    }
}
```

| Change | Before | After | Why it helped |
| --- | ---: | ---: | --- |
| Cached line table | 180 ms | 41 ms | Removes the per-block full-document rescan |
| Stop passing the walker `inout` | 41 ms | 12 ms | Closure capture was forcing a copy-on-write copy |
| Debounce the highlighter | 12 ms | 6 ms | One 16 ms coalescing window per burst |

## What we changed, in order

1. **Build the line table once per parse.**
   - Walk the UTF-8 bytes looking for `0x0A` and record each line start.
   - Keep the table alive for the whole walk, not per visit.
2. **Separate the structural change from the behavioural one.**
   - First commit: extract `LineTable`, no behaviour change, suite green.
   - Second commit: swap the rescan for a table lookup.
3. **Debounce syntax highlighting.**
   - Coalesce edits inside a single frame; highlight once.

> The `inout` regression was invisible in the diff and the compiler was
> silent about it. A struct passed `inout` to an instance method that also
> captures `self` in a closure gets copied on every call. Only the trace
> showed it — which is the whole argument for measuring before guessing.

## Still open

- [x] Restore the performance gate in CI
- [x] Add a 4,000-line fixture to the benchmark corpus
- [ ] Decide whether the table belongs in `WritParser` or `WritCore`
