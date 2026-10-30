# Block Selection (draft)

Rectangular selection cannot live in `selectedRanges`: AppKit coalesces and
re-orders the array, and a column selection is not expressible as a set of
ranges that survives that. It lives beside it, in its own model, and the
text view draws it itself.

## Measured AppKit behaviour

- `selectedRanges` is normalised on assignment; adjacent ranges merge.
- `setSelectedRanges(_:affinity:stillSelecting:)` fires the delegate once
  per call, not once per range.
- Drawing into `drawBackground(forGlyphRange:at:)` is the only hook that
  survives a live resize.
