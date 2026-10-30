---
title: House Style for Engineering Notes
author: A. Popov
---

# House Style for Engineering Notes

Every note in `docs/` is read twice: once by the person who wrote it, and
once, eighteen months later, by somebody working out *why*. We write for the
second reader.

## The three rules

1. **Say why, not what.** The code already says what it does.
2. **Record the thing you ruled out.** A rejected approach is the most expensive fact in the document.
3. **Date your measurements.** A latency number without a machine and a date
   is a rumour.

```swift
// Bad: restates the call. Delete it and the file reads the same.
// Collapse the outgoing pane, then uncollapse the incoming one.
outgoing.isCollapsed = true
incoming.isCollapsed = false

// Good: records the measurement and the reason the order matters.
// Uncollapsing first leaves a frame where both panes want the full
// width, and NSSplitViewController settles that by widening the
// window — it ratcheted ~340pt per switch (measured 2026-08-21).
outgoing.isCollapsed = true
incoming.isCollapsed = false

// Rule 3: a number with a machine and a date attached.
// M4 Pro, macOS 27.2, Release build, 4,000-line fixture:
//   before 180 ms, after 6 ms, median of 20 runs.
let coalescingWindow: Duration = .milliseconds(16)
```

> If a comment would be made redundant by renaming a variable, rename the
> variable instead. Prose is the most expensive place to keep a fact up to
> date, and the first place it rots.

## Review checklist

| Question | Required | Notes |
| --- | :---: | --- |
| Does the lead survive alone? | Yes | A reader may get no further |
| Are the numbers dated and attributed? | Yes | Machine, OS, build configuration |
| Is the rejected option named? | Yes | With the reason it lost |
| Is there a reproducer? | If a bug | A failing test beats a paragraph |
| Does `README.md` link to it? | Yes | An unlinked note is a lost note |

## Structure

A note that will be read under pressure has to be skimmable:

- **Lead** — two sentences. What broke, what changed.
- **Evidence** — the trace, the benchmark, the reproducer.
  - Include the command you ran, verbatim.
  - Include the output, verbatim. Paraphrased output is not evidence.
- **Decision** — what we chose, and what we deliberately did not.
  - Name the alternative, and say what would make us revisit it.

## A note on tone

Write in the past tense about what happened and the present tense about what
is true. Avoid "simply", "just", and "obviously" — all three are claims about
the reader, and all three are usually wrong.
