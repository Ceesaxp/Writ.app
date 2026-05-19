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
  };

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
    state.theme = theme;
    document.documentElement.dataset.writTheme = theme;
  }

  function renderMath(el, source, isBlock) {
    const renderer = state.mathRenderer;
    if (renderer === "none") {
      el.textContent = source;
      return;
    }
    if (renderer === "katex" && window.katex) {
      try {
        window.katex.render(source, el, {
          displayMode: isBlock,
          throwOnError: false,
          output: "html",
        });
      } catch (e) {
        el.classList.add("writ-math-error");
        el.textContent = "math: " + (e.message || String(e));
      }
      return;
    }
    if (renderer === "mathjax" && window.MathJax) {
      // MathJax 3 typeset path — render synchronously where possible.
      const delim = isBlock ? ["\\[", "\\]"] : ["\\(", "\\)"];
      el.textContent = delim[0] + source + delim[1];
      window.MathJax.typesetPromise([el]).catch(function (e) {
        el.classList.add("writ-math-error");
        el.textContent = "math: " + (e.message || String(e));
      });
      return;
    }
    // Fall back to readable source.
    el.classList.add("writ-math-error");
    el.textContent = source;
  }

  function renderMermaid(el, source) {
    if (!window.mermaid) {
      el.innerHTML = '<div class="writ-mermaid-error">Mermaid is not loaded</div>';
      return;
    }
    const id = "writ-mermaid-" + Math.random().toString(36).slice(2);
    try {
      window.mermaid
        .render(id, source)
        .then(function (result) { el.innerHTML = result.svg; })
        .catch(function (e) {
          el.innerHTML = '<div class="writ-mermaid-error">' + escapeHTML(String(e.message || e)) + "</div>";
        });
    } catch (e) {
      el.innerHTML = '<div class="writ-mermaid-error">' + escapeHTML(String(e.message || e)) + "</div>";
    }
  }

  function highlightCode() {
    if (!window.hljs) return;
    const codes = document.querySelectorAll("#writ-content pre code[class*='language-']");
    codes.forEach(function (el) {
      try { window.hljs.highlightElement(el); } catch (_) { /* ignore */ }
    });
  }

  function renderTechnicalBlocks() {
    document.querySelectorAll("[data-writ-block]").forEach(function (el) {
      const blockID = el.getAttribute("data-writ-block");
      const block = state.blocks.get(blockID);
      if (!block) return;
      switch (block.kind) {
        case "math":
          renderMath(el, block.source, true);
          break;
        case "mathInline":
          renderMath(el, block.source, false);
          break;
        case "mermaid":
          renderMermaid(el, block.source);
          break;
        // plantuml left inline as source per MVP scope
        default:
          break;
      }
    });
  }

  function applyUpdate(payload) {
    if (!payload || typeof payload !== "object") return;
    if (payload.revision <= state.revision) return; // stale
    state.revision = payload.revision;
    state.blocks.clear();
    (payload.blocks || []).forEach(function (b) { state.blocks.set(b.id, b); });
    if (payload.theme) setTheme(payload.theme);

    applyHTML(payload.html || "");
    highlightCode();
    renderTechnicalBlocks();
    document.body.classList.remove("writ-loading");
    document.body.classList.add("writ-ready");
    send({ type: "rendered", revision: payload.revision });
  }

  // Public API the native bridge uses.
  window.Writ = {
    update: applyUpdate,
    setMathRenderer: function (name) {
      state.mathRenderer = name;
      if (name === "katex") {
        const link = document.getElementById("katex-css");
        if (link) link.removeAttribute("disabled");
      }
      // Re-render existing blocks on switch.
      renderTechnicalBlocks();
    },
    setTheme: setTheme,
    state: state,
  };

  // Mermaid initial config (no auto-start; we render manually per block).
  document.addEventListener("DOMContentLoaded", function () {
    if (window.mermaid) {
      window.mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: "default" });
    }
    send({ type: "ready" });
  });
})();
