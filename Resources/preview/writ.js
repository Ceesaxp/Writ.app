// Writ preview runtime.
//
// Receives `PreviewBridgePayload` JSON from the native side and patches the
// preview DOM. Holds local technical-block rendering (math via KaTeX/MathJax,
// diagrams via Mermaid). All work is best-effort and never throws back to the
// native bridge — render failures are surfaced inline.
(function () {
  "use strict";

  const state = {
    revision: 0,
    mathRenderer: "katex", // 'katex' | 'mathjax' | 'none'; M0 spike toggles
    blocks: new Map(),     // id -> { kind, source, language }
    theme: "auto",
    // True when the native side is resolving ```plantuml``` fences against
    // a configured server for this revision. Off by default and off
    // whenever the feature isn't configured, in which case the fences keep
    // the emitter's "not configured" notice plus their source.
    plantUMLEnabled: false,
    // A resolved-blocks message that arrived before the payload it belongs
    // to. The native side encodes the payload off the main actor, so a
    // cache-hit resolve can overtake it; holding the message here instead
    // of dropping it is what keeps cached diagrams from showing
    // "Rendering diagram…" forever. See `applyResolvedBlocks`.
    pendingResolved: null,
  };

  // Per-renderer-version cache keyed by kind + source. Bounded LRU.
  const renderCache = (function () {
    const max = 256;
    const map = new Map();
    function key(kind, source) { return kind + "\u0000" + source; }
    return {
      get: function (kind, source) {
        const k = key(kind, source);
        const v = map.get(k);
        if (v !== undefined) {
          map.delete(k);
          map.set(k, v); // mark as MRU
        }
        return v;
      },
      set: function (kind, source, html) {
        const k = key(kind, source);
        if (map.has(k)) map.delete(k);
        map.set(k, html);
        while (map.size > max) {
          const oldest = map.keys().next().value;
          map.delete(oldest);
        }
      },
      clear: function () { map.clear(); },
    };
  })();

  function send(message) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.writ) {
      window.webkit.messageHandlers.writ.postMessage(message);
    }
  }

  function escapeHTML(s) {
    return s.replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function applyHTML(html) {
    const root = document.getElementById("writ-content");
    if (!root) return;
    root.innerHTML = html;
  }

  function setTheme(theme) {
    // Legacy color-scheme hint (`auto` / `light` / `dark`) from the
    // initial bridge payload. Kept for back-compat; the new
    // preview-theme system is `setPreviewTheme` below.
    state.theme = theme;
    document.documentElement.dataset.writTheme = theme;
  }

  /// Swap the active preview-theme stylesheet (`<link id="writ-theme">`).
  /// Valid names match the Swift `PreviewTheme` enum: `github`, `serif`,
  /// `mono`, `sans`. Unknown names fall back to `github`.
  function setPreviewTheme(name) {
    var link = document.getElementById("writ-theme");
    if (!link) return;
    var validThemes = ["github", "serif", "mono", "sans"];
    var resolved = validThemes.indexOf(name) >= 0 ? name : "github";
    var newHref = "themes/" + resolved + ".css";
    if (link.getAttribute("href") !== newHref) {
      link.setAttribute("href", newHref);
    }
    document.documentElement.dataset.writPreviewTheme = resolved;
  }

  /// Inline the user's custom CSS into a `<style>` block in the head.
  /// Swift reads the file (with security-scoped access) and passes the
  /// contents; we don't link to it directly because sandboxed
  /// WKWebView can't reliably load arbitrary file:// stylesheets.
  function setCustomCSS(content) {
    var style = document.getElementById("writ-custom-style");
    if (!style) {
      style = document.createElement("style");
      style.id = "writ-custom-style";
      document.head.appendChild(style);
    }
    style.textContent = content || "";
  }

  // Each technical-block render function returns a promise that resolves
  // when the block has reached a stable rendered state, so `applyUpdate`
  // can defer the `rendered` notification until every block for the
  // current revision has finished. Synchronous renderers return a
  // resolved promise so callers don't need to branch.
  function renderMath(el, source, isBlock) {
    const renderer = state.mathRenderer;
    const cacheKind = "math:" + renderer + ":" + (isBlock ? "block" : "inline");
    const cached = renderCache.get(cacheKind, source);
    if (cached !== undefined) {
      el.innerHTML = cached;
      return Promise.resolve();
    }
    if (renderer === "none") {
      el.textContent = source;
      return Promise.resolve();
    }
    if (renderer === "katex" && window.katex) {
      try {
        window.katex.render(source, el, {
          displayMode: isBlock,
          throwOnError: false,
          output: "html",
        });
        renderCache.set(cacheKind, source, el.innerHTML);
      } catch (e) {
        el.classList.add("writ-math-error");
        el.textContent = "math: " + (e.message || String(e));
      }
      return Promise.resolve();
    }
    if (renderer === "mathjax" && window.MathJax) {
      // MathJax 3 typeset path — render synchronously where possible.
      const delim = isBlock ? ["\\[", "\\]"] : ["\\(", "\\)"];
      el.textContent = delim[0] + source + delim[1];
      return window.MathJax.typesetPromise([el]).catch(function (e) {
        el.classList.add("writ-math-error");
        el.textContent = "math: " + (e.message || String(e));
      });
    }
    // Fall back to readable source.
    el.classList.add("writ-math-error");
    el.textContent = source;
    return Promise.resolve();
  }

  function renderMermaid(el, source) {
    if (!window.mermaid) {
      el.innerHTML = '<div class="writ-mermaid-error">Mermaid is not loaded</div>';
      return Promise.resolve();
    }
    const cacheKind = "mermaid";
    const cached = renderCache.get(cacheKind, source);
    if (cached !== undefined) {
      el.innerHTML = cached;
      return Promise.resolve();
    }
    const id = "writ-mermaid-" + Math.random().toString(36).slice(2);
    try {
      return window.mermaid
        .render(id, source)
        .then(function (result) {
          el.innerHTML = result.svg;
          renderCache.set(cacheKind, source, result.svg);
        })
        .catch(function (e) {
          el.innerHTML = '<div class="writ-mermaid-error">' + escapeHTML(String(e.message || e)) + "</div>";
        });
    } catch (e) {
      el.innerHTML = '<div class="writ-mermaid-error">' + escapeHTML(String(e.message || e)) + "</div>";
      return Promise.resolve();
    }
  }

  function highlightCode() {
    if (!window.hljs) return;
    const codes = document.querySelectorAll("#writ-content pre code[class*='language-']");
    codes.forEach(function (el) {
      try { window.hljs.highlightElement(el); } catch (_) { /* ignore */ }
    });
  }

  // Annotate each fenced code block with its language so the
  // theme CSS can render a small chip in the corner. Reads the
  // `language-<name>` class hljs/HTMLEmitter emits; falls back to
  // any custom class starting with `language-`.
  function tagCodeBlockLanguages() {
    const codes = document.querySelectorAll("#writ-content pre > code[class*='language-']");
    codes.forEach(function (codeEl) {
      const pre = codeEl.parentElement;
      if (!pre) return;
      const lang = (codeEl.className.match(/language-([^\s]+)/) || [])[1];
      if (lang && lang !== "plaintext" && lang !== "text") {
        pre.setAttribute("data-writ-lang", lang);
      } else {
        pre.removeAttribute("data-writ-lang");
      }
    });
  }

  // Returns a promise that resolves once every async technical block has
  // settled. Callers can chain on this to know when the preview has
  // reached its final state for the current revision.
  function renderTechnicalBlocks() {
    const pending = [];
    document.querySelectorAll("[data-writ-block]").forEach(function (el) {
      const blockID = el.getAttribute("data-writ-block");
      const block = state.blocks.get(blockID);
      if (!block) return;
      switch (block.kind) {
        case "math":
          pending.push(renderMath(el, block.source, true));
          break;
        case "mathInline":
          pending.push(renderMath(el, block.source, false));
          break;
        case "mermaid":
          pending.push(renderMermaid(el, block.source));
          break;
        case "plantuml":
          // Deliberately not pushed onto `pending`: PlantUML resolves over
          // the network, out of band, and the `rendered` signal (which the
          // HTML/PDF export path waits on) must not wait for a server.
          // When the feature is off, the element is left exactly as the
          // emitter produced it.
          if (state.plantUMLEnabled) {
            const notice = el.querySelector(".writ-plantuml-notice");
            // The <pre> source stays visible underneath — it is the
            // fallback if the render never arrives.
            if (notice) notice.textContent = "Rendering diagram…";
          }
          break;
        default:
          break;
      }
    });
    return Promise.all(pending);
  }

  function resolveImagePaths(base) {
    if (!base) return;
    document.querySelectorAll("#writ-content img").forEach(function (img) {
      const src = img.getAttribute("src") || "";
      if (!src) return;
      // Skip absolute URLs (http, https, data, file, etc.) and protocol-relative paths.
      if (/^[a-z][a-z0-9+.-]*:/i.test(src) || src.startsWith("//")) return;
      // Route document-relative paths through the writ-doc:// custom scheme
      // so the native side serves the bytes (the file:// sandbox refuses
      // direct loads outside the WebView's read-access grant). Use the
      // empty-host form `writ-doc:///<path>` so the handler can use the
      // url.path component directly.
      const encoded = encodeURI(src);
      img.src = "writ-doc:///" + encoded.replace(/^\//, "");
    });
  }

  function attachImageDiagnostics() {
    document.querySelectorAll("#writ-content img").forEach(function (img) {
      img.addEventListener("error", function () {
        const placeholder = document.createElement("span");
        placeholder.className = "writ-missing-image";
        const src = img.getAttribute("src") || "(no source)";
        placeholder.textContent = "missing image: " + src;
        img.replaceWith(placeholder);
        updateDiagnosticsRibbon();
      });
    });
  }

  function updateDiagnosticsRibbon() {
    const root = document.getElementById("writ-content");
    if (!root) return;
    const errors = root.querySelectorAll(".writ-mermaid-error, .writ-math-error, .writ-missing-image");
    let ribbon = document.getElementById("writ-diagnostics-ribbon");
    if (errors.length === 0) {
      if (ribbon) ribbon.remove();
      return;
    }
    if (!ribbon) {
      ribbon = document.createElement("div");
      ribbon.id = "writ-diagnostics-ribbon";
      ribbon.className = "writ-diagnostics-ribbon";
      ribbon.addEventListener("click", function () {
        const first = root.querySelector(".writ-mermaid-error, .writ-math-error, .writ-missing-image");
        if (first) first.scrollIntoView({ behavior: "smooth", block: "center" });
      });
      root.parentNode.insertBefore(ribbon, root);
    }
    const word = errors.length === 1 ? "issue" : "issues";
    ribbon.textContent = errors.length + " render " + word + " — click to jump";
    // Re-add the icon prefix via ::before (the textContent above wiped it).
    ribbon.classList.remove("writ-diagnostics-ribbon");
    ribbon.classList.add("writ-diagnostics-ribbon");
  }

  // Patch blocks the native side resolved out of band (remote PlantUML).
  // The SVG was sanitised natively before it was sent.
  function applyResolvedBlocks(msg) {
    try {
      if (!msg || typeof msg !== "object") return;
      // Older than what's on screen: the document has moved on, drop it.
      if (msg.revision < state.revision) return;
      // Newer than what's on screen: the payload it belongs to is still
      // being encoded off the main actor and will arrive in a moment.
      // Hold it rather than drop it — otherwise a cache hit, which answers
      // in microseconds, loses the race with its own payload every time.
      if (msg.revision > state.revision) {
        state.pendingResolved = msg;
        return;
      }
      const resolved = msg.resolved || {};
      Object.keys(resolved).forEach(function (id) {
        const el = document.querySelector('[data-writ-block="' + id + '"]');
        if (!el) return;
        el.innerHTML = resolved[id];
      });
    } catch (e) {
      send({ type: "console", level: "error", message: "applyResolvedBlocks: " + e });
    }
  }

  function applyUpdate(payload) {
    try {
      if (!payload || typeof payload !== "object") return;
      if (payload.revision <= state.revision) return; // stale
      state.revision = payload.revision;
      state.blocks.clear();
      (payload.blocks || []).forEach(function (b) { state.blocks.set(b.id, b); });
      if (payload.theme) setTheme(payload.theme);
      state.plantUMLEnabled = payload.plantUMLEnabled === true;

      // Drop any previous diagnostics ribbon — it'll be rebuilt by
      // attachImageDiagnostics / renderTechnicalBlocks if errors recur.
      const oldRibbon = document.getElementById("writ-diagnostics-ribbon");
      if (oldRibbon) oldRibbon.remove();

      applyHTML(payload.html || "");
      try { resolveImagePaths(payload.documentBaseURL); } catch (e) {
        send({ type: "console", level: "error", message: "resolveImagePaths: " + e });
      }
      try { attachImageDiagnostics(); } catch (e) {
        send({ type: "console", level: "error", message: "attachImageDiagnostics: " + e });
      }
      try { highlightCode(); } catch (e) {
        send({ type: "console", level: "error", message: "highlightCode: " + e });
      }
      try { tagCodeBlockLanguages(); } catch (e) {
        send({ type: "console", level: "error", message: "tagCodeBlockLanguages: " + e });
      }
      // Mermaid/MathJax render asynchronously; wait until they settle for
      // this revision before signalling `rendered` so callers that depend
      // on the preview being final (HTML/PDF export, status bar) don't
      // capture placeholders.
      const renderedRevision = payload.revision;
      let blocksPromise;
      try {
        blocksPromise = renderTechnicalBlocks();
      } catch (e) {
        send({ type: "console", level: "error", message: "renderTechnicalBlocks: " + e });
        blocksPromise = Promise.resolve();
      }
      // A resolve that overtook this payload (a cache hit on the native
      // side) parked itself in `state.pendingResolved`; now that the DOM
      // for its revision exists, apply it.
      const parked = state.pendingResolved;
      state.pendingResolved = null;
      if (parked && parked.revision === payload.revision) {
        applyResolvedBlocks(parked);
      }

      document.body.classList.remove("writ-loading");
      document.body.classList.add("writ-ready");
      blocksPromise.then(function () {
        // Drop the notification if a newer revision has already taken
        // over — the later payload owns the `rendered` signal.
        if (renderedRevision < state.revision) return;
        updateDiagnosticsRibbon();
        send({ type: "rendered", revision: renderedRevision });
      });
    } catch (e) {
      send({ type: "console", level: "error", message: "applyUpdate fatal: " + (e && e.stack ? e.stack : e) });
    }
  }

  // Expected scrollTop after a programmatic scroll. A scroll event whose
  // position matches is our own scroll landing — swallowed so it can't
  // echo `previewScrolled` back to the editor. Any other position means
  // the user moved the view: clear the expectation and resume notifying.
  // Deterministic replacement for the old 250 ms suppression flag, whose
  // overlapping timers leaked during continuous wheel scrolling (and any
  // fixed window loses to a late MathJax/Mermaid reflow anyway).
  let expectedScrollTop = null;

  function currentScroller() {
    return document.scrollingElement || document.documentElement || document.body;
  }

  function scrollToRatio(ratio) {
    const scroller = currentScroller();
    const max = scroller.scrollHeight - scroller.clientHeight;
    if (max <= 0) return;
    scroller.scrollTop = max * ratio;
    // Read back rather than trust the assignment — the browser clamps.
    expectedScrollTop = scroller.scrollTop;
  }

  // Preview → editor: notify the native side which source line is at the
  // top of the preview pane so the editor can scroll to match.
  let lastTopLine = 0;
  function computeTopLine() {
    const scroller = currentScroller();
    const top = scroller.scrollTop;
    const candidates = document.querySelectorAll("[data-writ-line]");
    let bestLine = 1;
    let bestY = -Infinity;
    for (const el of candidates) {
      const lineNum = parseInt(el.getAttribute("data-writ-line"), 10);
      if (Number.isNaN(lineNum)) continue;
      const rect = el.getBoundingClientRect();
      const y = rect.top + top;
      if (y <= top + 4 && y > bestY) {
        bestY = y;
        bestLine = lineNum;
      }
    }
    return bestLine;
  }
  function notifyTopLine() {
    const bestLine = computeTopLine();
    if (bestLine !== lastTopLine) {
      lastTopLine = bestLine;
      send({ type: "previewScrolled", line: bestLine });
    }
  }
  // Debounce scroll → notify so we don't flood the bridge while the user is
  // actively scrolling.
  let scrollNotifyTimer = null;
  window.addEventListener("scroll", function () {
    if (expectedScrollTop !== null) {
      if (Math.abs(currentScroller().scrollTop - expectedScrollTop) < 2) {
        return; // our own programmatic scroll landing — not user input
      }
      expectedScrollTop = null;
    }
    if (scrollNotifyTimer) clearTimeout(scrollNotifyTimer);
    scrollNotifyTimer = setTimeout(notifyTopLine, 60);
  }, { passive: true });

  // Block-aware scroll sync: find the rendered element whose source line is
  // closest to `line` and align it to the top of the preview viewport.
  function scrollToSourceLine(line, fallbackRatio) {
    const elements = document.querySelectorAll("[data-writ-line]");
    let best = null;
    let bestLine = -Infinity;
    for (const el of elements) {
      const elLine = parseInt(el.getAttribute("data-writ-line"), 10);
      if (Number.isNaN(elLine)) continue;
      if (elLine <= line && elLine > bestLine) {
        best = el;
        bestLine = elLine;
      }
    }
    if (!best) {
      scrollToRatio(fallbackRatio);
      return;
    }
    const rect = best.getBoundingClientRect();
    const scroller = currentScroller();
    scroller.scrollTop += rect.top - 12; // small top padding
    expectedScrollTop = scroller.scrollTop;
  }

  // Public API the native bridge uses.
  window.Writ = {
    update: applyUpdate,
    applyResolvedBlocks: applyResolvedBlocks,
    setMathRenderer: function (name) {
      if (name === state.mathRenderer) return;
      state.mathRenderer = name;
      if (name === "katex") {
        const link = document.getElementById("katex-css");
        if (link) link.removeAttribute("disabled");
      }
      // Renderer-specific cache entries must be dropped when switching.
      renderCache.clear();
      renderTechnicalBlocks();
    },
    setTheme: setTheme,
    setPreviewTheme: setPreviewTheme,
    setCustomCSS: setCustomCSS,
    scrollToRatio: scrollToRatio,
    scrollToSourceLine: scrollToSourceLine,
    currentTopLine: computeTopLine,
    state: state,
  };

  // Mermaid initial config (no auto-start; we render manually per block).
  // Send `ready` repeatedly until the native side acknowledges by pushing the
  // first update — the cold-launch path sometimes drops the first message
  // before the bridge is fully wired. Once `applyUpdate` has run for any
  // payload, state.revision > 0 and we can stop announcing.
  function announceReady() {
    if (state.revision > 0) return;
    send({ type: "ready" });
    setTimeout(announceReady, 250);
  }

  // Expose a manual nudge so the native side can probe after didFinish.
  window.Writ.markReady = announceReady;

  document.addEventListener("DOMContentLoaded", function () {
    if (window.mermaid) {
      window.mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: "default" });
    }
    announceReady();
  });

  // Also kick off on first load in case DOMContentLoaded already fired by
  // the time this script is executed (cold WebKit warm-up edge case).
  if (document.readyState === "interactive" || document.readyState === "complete") {
    if (window.mermaid) {
      window.mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: "default" });
    }
    announceReady();
  }
})();
