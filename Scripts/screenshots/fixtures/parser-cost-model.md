# A Cost Model for the Preview Pipeline

Before optimising the preview we needed a model that predicted its latency
from the document, not from vibes. This is the one we settled on, and the
measurements that justify each term.

## The model

Let $n$ be the number of top-level blocks and $b_i$ the byte length of block
$i$. Parsing is linear in bytes; mapping a block's source range to a UTF-16
offset costs $O(\log b_i)$ once the line table is warm. Summing over the
document:

$$
T(n) = \sum_{i=1}^{n} \Bigl( c_{\text{parse}} \, b_i + c_{\text{map}} \log b_i \Bigr) + c_{\text{paint}}
$$

The fitted constants, on an M-series laptop, are
$c_{\text{parse}} \approx 2.1\ \text{ns/byte}$ and
$c_{\text{map}} \approx 38\ \text{ns}$.

## Why the old code was quadratic

The pre-`LineTable` mapping rescanned from byte zero, so its cost was
proportional to the offset of the block rather than to the block itself:

$$
T_{\text{old}}(n) = c_{\text{map}} \sum_{i=1}^{n} \sum_{j < i} b_j
  \;=\; \frac{c_{\text{map}}}{2} \Bigl( B^2 - \sum_i b_i^2 \Bigr)
$$

where $B = \sum_i b_i$ is the document size. For a 4,000-line file that
second term is negligible, leaving a clean $O(B^2)$ — which is exactly the
shape the trace showed.

## Debounce window

With an edit arrival rate $\lambda$ and a coalescing window $w$, the expected
number of parses per second is $\lambda / (1 + \lambda w)$, so the marginal
benefit of a longer window falls off as $1/w^2$:

$$
\frac{\partial}{\partial w}\left(\frac{\lambda}{1 + \lambda w}\right)
  = -\frac{\lambda^{2}}{(1 + \lambda w)^{2}}
$$

At a brisk 8 keystrokes per second, moving $w$ from 16 ms to 32 ms saves
about one parse per second and costs a visible frame of preview lag. We kept
16 ms.
