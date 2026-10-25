# M1 P0 Performance Gate — Measured Evidence

Date: 2026-05-20
Host: macOS 24.6.0, Apple Silicon
Configuration: `swift build -c release` (parser via `writ-bench`)

The MVP plan §3 M1 lists these P0 gate criteria. This document captures the
measurements that satisfy them.

| Gate criterion | Budget | Measurement | Verdict |
|---|---|---|---|
| 1 MB Markdown opens to editable state | < 1000 ms | parse p50 192 ms, leaving > 800 ms for app launch + WebKit init + first render | **PASS** |
| 5 MB Markdown editable, main thread unblocked | not blocked | parse p50 953 ms but runs on `PreviewScheduler`'s background queue, never on main | **PASS** |
| Preview update for 10 KB after debounce | < 500 ms | parse p50 2.2 ms, HTML 14 KB, WebKit roundtrip < 50 ms | **PASS** |
| Typing has no visible lag in normal documents | qualitative | confirmed in manual use of the smoke fixture (10 KB) | **PASS** |
| Editor scrolling smooth in large files | qualitative | confirmed by opening `1mb.md` and scrolling top-to-bottom | **PASS** |

## Raw parser numbers (current)

From `Benchmarks/Results/m0-parser.json`, regenerated 2026-05-20:

| Fixture | Bytes | parse_cold (µs) | parse_p50 (µs) | parse_p90 (µs) | tech blocks |
|---|---:|---:|---:|---:|---:|
| 10kb.md | 10 488 | 2 854 | 2 174 | 2 821 | 0 |
| 1mb.md | 1 000 275 | 192 493 | 192 911 | 193 529 | 0 |
| 5mb.md | 5 000 255 | 974 516 | 952 996 | 957 943 | 0 |
| code-heavy.md | 17 931 | 8 714 | 8 569 | 8 680 | 0 |
| math-heavy.md | 20 858 | 78 540 | 80 311 | 80 355 | 300 |
| mermaid-heavy.md | 6 660 | 3 347 | 3 118 | 3 471 | 60 |

## Notes

- **5 MB parse near the 1 s line.** 953 ms is comfortably under 1 s but
  the M0 spike measured ~1049 ms; subsequent caching and parser tweaks
  reduced it. Still worth a re-measure after any significant parser
  change.
- **math-heavy regression vs M0.** The M0 snapshot had `math-heavy`
  parse p50 ~8 573 µs; current is ~80 311 µs — roughly 9× slower.
  Likely caused by the inline-line-attribute emission and the
  tightened tight-list rendering walking children twice. Filed for
  follow-up; does **not** affect the P0 gate (the gate is about
  end-to-end open time on realistic documents, not microbenchmarks
  on a 300-math-block stress fixture).
- **In-app WKWebView round-trip** is not automated in this measurement
  pass — the `Writ --bench` mode trips over Xcode 17's stub-executor
  argv handling combined with the sandbox + Launch Services document
  open path. Refresh path: open `1mb.md` interactively and confirm
  subjective sub-second readiness. The parser/encoder numbers above
  bound the heavy work; the WKWebView round-trip is dominated by
  shell load (~80 ms cold) and `Writ.update(...)` evaluate
  (microseconds), well within budget.

## How to re-run

```sh
# From repo root
cd Benchmarks
swift run --configuration release writ-bench \
  "$(pwd)/Fixtures" \
  "$(pwd)/Results/m0-parser.json"
```

## Re-measure 2026-10-25 — the gate broke (and was fixed the same day)

Host: macOS 27.2, Apple Silicon. Same `--configuration release`, same
`writ-bench`, and **byte-identical fixtures** (`git diff f62d678 HEAD --
Benchmarks/Fixtures/` is empty).

The numbers above were taken at `f62d678` on macOS 24.6. Re-running on the
current tree showed parse times 3–6× higher, so the comparison was isolated
against two confounds before drawing any conclusion: the host OS, and the
`swift-markdown` version. Both manifests declare `from: "0.6.0"`, an open
range, so a freshly-resolved worktree picks up a newer library than the
committed lockfile pins — the first attempt at this comparison accidentally
ran old code on 0.9.0 against current code on 0.8.0 and was invalid.

Each cell is the p50 of two alternating runs, nothing else building:

| Fixture | old code (f62d678) + 0.9.0 | current + 0.8.0 | current + 0.9.0 | same-library change |
|---|---:|---:|---:|---:|
| `10kb.md` | 1.9 ms | 5.1 ms | 5.5 ms | **2.9×** |
| `1mb.md` | 157 ms | 555 ms | 555 ms | **3.5×** |
| `5mb.md` | 795 ms | 4 868 ms | 4 872 ms | **6.1×** |
| `code-heavy.md` | 7.1 ms | 7.7 ms | 7.7 ms | 1.09× |
| `math-heavy.md` | 73 ms | 107 ms | 107 ms | 1.46× |
| `mermaid-heavy.md` | 2.46 ms | 2.67 ms | 2.69 ms | 1.09× |

**Conclusions.**

- **Not the host.** Old code on this machine runs *faster* than its own
  recorded numbers (157 ms vs 193 ms for 1 MB; 795 ms vs 953 ms for 5 MB).
- **Not the dependency.** Current code is equally slow on 0.8.0 and 0.9.0.
  The library version moves nothing.
- **It is Writ's own parse/emit path**, and the shape is diagnostic: the
  cost scales with **document size** and is flat against **block density**.
  `code-heavy` (18 KB, many fences) and `mermaid-heavy` (6.6 KB, 60 blocks)
  are unchanged at 1.09×, while the three plain-prose size fixtures regress
  2.9× / 3.5× / 6.1×. Cost per byte roughly doubles from 1 MB to 5 MB, so
  the work is super-linear in length — something per-line or per-character
  that scans more than it should, not the per-block attribute emission.

Gate impact:

| Gate criterion | Then | Now |
|---|---|---|
| 1 MB opens to editable < 1 s | 193 ms parse, > 800 ms headroom | 555 ms parse, ~445 ms headroom — **tight** |
| 5 MB editable, main thread unblocked | 953 ms off-main | 4 872 ms off-main — still off-main, but a ~5 s wait for first preview |
| 10 KB preview < 500 ms after debounce | 2.2 ms | 5.5 ms — **still passes comfortably** |
| Typing lag / scroll smoothness | qualitative, TextKit 2 | **unverified** — the editor moved to TextKit 1 since |

### Bisected 2026-10-25 — `fc438ca`, the autolink scanner

`git bisect` over the 82 commits in `f62d678..master`, measuring `1mb.md`
p50 with the dependency pinned at every step and the predicate validated
against both endpoints first. Seven steps, no skips. First bad commit:

```
fc438ca feat: emoji shortcodes + autolink bare URLs (v0.4.11)
```

It accounts for **the entire regression** — everything after it is flat:

| Fixture | `cae9d46` (parent) | `fc438ca` (culprit) | `master` |
|---|---:|---:|---:|
| `10kb.md` | 1.69 ms | 5.67 ms | 5.1 ms |
| `1mb.md` | 157.7 ms | 545.7 ms | 549 ms |
| `5mb.md` | 786.6 ms | 4 849.9 ms | 4 868 ms |
| `code-heavy.md` | 7.0 ms | 7.7 ms | 7.7 ms |
| `math-heavy.md` | 104.6 ms | 106.4 ms | 107 ms |
| `mermaid-heavy.md` | 2.49 ms | 2.66 ms | 2.69 ms |

**Mechanism.** `AutolinkExtractor.findNextStart` walks every character
position in every `Text` node and calls `startsWith(ns, at:, needle)` once
per candidate scheme (`https://`, `http://`, `www.`). That helper, per call:

```swift
let n = (needle as NSString).length              // bridges the needle
let slice = ns.substring(with: NSRange(...))     // allocates a String
return slice.lowercased() == needle.lowercased() // allocates two more
```

So a 1 MB document performs roughly **3 million of those calls and ~12
million String allocations**, re-lowercasing the same string literals every
time. `1mb.md` contains **zero** `http`/`www` occurrences, so all of that
work finds nothing. This is also why the cost tracks document *size* and not
block density, and why `code-heavy` and `mermaid-heavy` barely move: their
text volume is small.

**Second mechanism — the one that made the cost super-linear.** The scan
above is strictly linear, so it cannot explain cost-per-byte doubling from
1 MB to 5 MB. `fc438ca` also changed the emitter's `Text` case from

```swift
out.append(escape(text.string))                     // cae9d46
```

to a call passing the output buffer `inout` *and* the escape function as a
closure argument:

```swift
InlineTextTransform.emit(text: text.string, allowAutolink: !insideLink,
                         into: &out, escape: escape)   // fc438ca
```

`HTMLEmitter` is a **struct** and `out` is one of its stored properties, so
`escape: escape` — a reference to an *instance* method — builds a partial
application that captures a **copy of `self`**, and that copy holds a second
reference to `out`'s storage. The buffer is therefore no longer uniquely
referenced, and every `out.append(…)` inside `emit` deep-copies the entire
accumulated HTML. One full copy of the output per inline `Text` node, i.e.
**O(n²) in document length**: ~10 K nodes against a 1.37 MB output for
`1mb.md`, ~51 K nodes against 6.9 MB for `5mb.md`.

`escape` reads no instance state, so making it `static` removes the capture
and restores in-place appends. This is why the 5 MB fixture was hit so much
harder than 1 MB, and why `code-heavy` / `mermaid-heavy` were nearly
untouched — few `Text` nodes and a small output.

### Fixed 2026-10-25 — both causes, measured separately

Two structural (behaviour-preserving) commits. All three binaries were run
back-to-back in one session against byte-identical fixtures, with
`Benchmarks/Package.resolved` untouched (swift-markdown 0.8.0 throughout):

| Fixture | before | + autolink rewrite | + `static escape` | total |
|---|---:|---:|---:|---:|
| `10kb.md` | 5.12 ms | 3.35 ms | **3.55 ms** | 1.44× |
| `1mb.md` | 561.7 ms | 247.7 ms | **180.4 ms** | **3.11×** |
| `5mb.md` | 4 848.2 ms | 3 405.8 ms | **905.5 ms** | **5.35×** |
| `code-heavy.md` | 7.78 ms | 7.30 ms | **7.13 ms** | 1.09× |
| `math-heavy.md` | 105.1 ms | 104.7 ms | **104.4 ms** | 1.01× |
| `mermaid-heavy.md` | 2.70 ms | 2.53 ms | **2.53 ms** | 1.07× |

The split is diagnostic in itself: the autolink rewrite is a *linear* win
(1.37× at both 1 MB and 5 MB), while `static escape` is worth 1.37× at 1 MB
but **3.76×** at 5 MB — the signature of removing a quadratic term.

**The super-linearity is gone.** `5mb.md` / `1mb.md` is now 5.02×, against
4.99× at `cae9d46` before either feature existed. It was 8.8× before the fix.

**Parity.** The `html` byte count is identical in all three runs for every
fixture (`1mb.md` 1 373 605; `5mb.md` 6 910 683), which is the evidence that
both commits are structural. 73 parser tests pass, zero warnings.

Gate criteria, restored:

| Gate criterion | Budget | Now | Verdict |
|---|---|---:|---|
| 1 MB opens to editable state | < 1000 ms | 180 ms parse, > 800 ms headroom | **PASS** |
| 5 MB editable, main thread unblocked | not blocked | 905 ms, off-main on `PreviewScheduler` | **PASS** |
| 10 KB preview after debounce | < 500 ms | 3.6 ms | **PASS** |

Residual against the pre-feature baseline (`cae9d46`: 157.7 ms / 786.6 ms) is
**~15 %**, and that is the cost of the two features themselves rather than a
regression. It is accounted for: a probe over `1mb.md` split into line-sized
nodes measures `EmojiShortcodes.substitute` at ~22.6 ms and the rewritten
`AutolinkExtractor.scan` at ~3.8 ms (finding zero matches), against a 180 ms
parse. `substitute` has a `guard text.contains(":")` fast path but then
rebuilds the string `Character` by `Character` whenever *any* colon is
present, and `1mb.md` has 403 of them. Returning early unless a table lookup
actually hits would recover most of that ~20 ms; not done, since it is
feature cost and not regression repair.

Deliberately left alone: the trailing-`)` trim runs two full `url.filter`
passes per removed character, but only on real matches, of which `1mb.md`
has none. Also noted, not touched — `InlineTextTransform.swift` has
`if !url.contains("."), url.count < 4 { … }`, a comma where the comment
describes an `||`; it is a pre-existing logic bug and fixing it would be a
behavioural change.

`data-writ-line` was the first suspect and is ruled out — `html` byte counts
are identical at `cae9d46` and `master`, and
`HTMLEmitter.sourceLineAttribute(for:)` reads `markup.range?.lowerBound.line`
straight from swift-markdown, O(1).

### Separate, still unexplained: `math-heavy`

The 9× `math-heavy` regression noted above (M0 ~8.5 ms → 80 ms at
`f62d678`) is **not** this bug. It measures ~105 ms at `cae9d46`, at
`fc438ca` and at `master` alike, so it predates this bisect range entirely
and remains uninvestigated.

### How to reproduce this comparison

```sh
# old code, in a throwaway worktree
git worktree add /tmp/old-perf f62d678
cd /tmp/old-perf/Benchmarks && swift build -c release
# pin BOTH trees to the same library version before comparing, or the
# open-ended `from:` requirement will silently resolve them differently
.build/release/writ-bench <repo>/Benchmarks/Fixtures /tmp/old.json
```

