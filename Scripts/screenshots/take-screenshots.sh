#!/bin/bash
# take-screenshots.sh — Capture Mac App Store screenshots of Writ.
#
# Usage:
#   ./take-screenshots.sh --app-path /path/to/Writ.app [options]
#
# Options:
#   --state STATE     Capture only this state (split, math, diagram, folder,
#                     preview). Default: all states.
#   --output DIR      Output directory. Default: <repo>/build/screenshots
#   --app-path PATH   Path to the Writ.app bundle to photograph. Required:
#                     resolving by name would pick up /Applications/Writ.app,
#                     which is usually an older release.
#   --interactive     Pause before each capture for manual adjustment.
#   --verify-only     Skip capture; just verify whatever is in --output.
#   --help            Show this help message.
#
# Prerequisites:
#   - Screen Recording permission for this terminal
#     (System Settings > Privacy & Security > Screen Recording)
#   - Accessibility permission for this terminal
#   - ImageMagick (`magick`) for the blank-preview verification
#   - A clean desktop and a tidy menu bar
#
# Output is exactly 2880x1800 per shot: the window frame is set to 1440x900
# points and the display is 2x Retina, so nothing is ever resampled.
#
# What this does NOT do: it never resets, deletes or overwrites the app's
# sandbox container or any user preference. Panes are switched through the
# View menu, which does not persist a default layout, and the document
# window's original frame is restored before quitting because the window
# does use setFrameAutosaveName.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# ─── Defaults ────────────────────────────────────────────────────────────

OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/build/screenshots}"
FIXTURES_DIR="${FIXTURES_DIR:-${SCRIPT_DIR}/fixtures}"
INTERACTIVE="${INTERACTIVE:-false}"
CAPTURE_STATE="${CAPTURE_STATE:-all}"
VERIFY_ONLY=false

EXPECTED_W=2880
EXPECTED_H=1800
MIN_BYTES=307200          # 300 KB; a blank or black shot comes in far under

# ─── Parse arguments ─────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --state)       CAPTURE_STATE="$2"; shift 2 ;;
        --output)      OUTPUT_DIR="$2";    shift 2 ;;
        --app-path)    APP_PATH="$2";      shift 2 ;;
        --interactive) INTERACTIVE=true;   shift ;;
        --verify-only) VERIFY_ONLY=true;   shift ;;
        --help)
            # Print the whole header block — everything between the
            # shebang and the first line of code — so the help can never
            # drift out of sync with the comment or stop mid-sentence.
            # BSD sed has no `\?` in a basic regex, hence `\{0,1\}`.
            sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# ─── Helpers ─────────────────────────────────────────────────────────────

maybe_pause() {
    if [[ "$INTERACTIVE" == "true" ]]; then
        wait_for_user "${1:-Adjust the window if needed, then press Enter to capture.}"
    fi
}

should_capture() {
    [[ "$CAPTURE_STATE" == "all" || "$CAPTURE_STATE" == "$1" ]]
}

# Preview-pane sample rectangles, window-relative points. Inset well
# inside the pane so the probe never catches the toolbar, the status bar
# or the scroller — those carry contrast even when the preview is blank
# and would make the blank check vacuous.
#   split:   right-hand pane of a 1440pt window split down the middle
#   preview: the single full-width pane
SPLIT_PROBE=(760 140 620 680)
PREVIEW_PROBE=(240 140 960 680)
OUTLINE_PREVIEW_PROBE=(420 140 860 680)

# Geometry restored before quitting, so the autosaved window frame the
# user comes back to is the one they left. Captured from the first window
# we see, which is the frame the app restored on launch.
ORIGINAL_BOUNDS=""

remember_original_bounds() {
    [[ -n "$ORIGINAL_BOUNDS" ]] && return 0
    ORIGINAL_BOUNDS="$(get_window_bounds)"
    echo "    Remembered the user's window frame: ${ORIGINAL_BOUNDS}"
}

restore_original_bounds() {
    [[ -z "$ORIGINAL_BOUNDS" ]] && return 0
    is_app_running || return 0
    echo "==> Restoring the original window frame: ${ORIGINAL_BOUNDS}"
    IFS=',' read -r x y w h <<< "$ORIGINAL_BOUNDS"
    # The last state closes its document, so there may be no window left
    # to resize. The autosaved frame is written whenever a window using
    # that name changes size, so open a scratch one, size it, close it.
    local opened_scratch=false
    if ! get_window_bounds > /dev/null 2>&1; then
        send_keystroke "n" "command down"
        sleep "$DELAY_MEDIUM"
        opened_scratch=true
    fi
    set_window_geometry "$x" "$y" "$w" "$h" || true
    if [[ "$opened_scratch" == "true" ]]; then
        close_front_document
    fi
}

# Open a fixture, force a layout, pin the geometry and wait for the
# preview to actually finish painting. One retry through Refresh Preview
# covers the known cold-launch race where the first payload is posted
# before the WKWebView shell has signalled ready.
stage_document() {
    local fixture="$1" layout="$2"
    shift 2
    local probe=("$@")

    open_file "${FIXTURES_DIR}/${fixture}"
    remember_original_bounds
    "$layout"
    set_window_geometry
    assert_window_geometry

    # The divider position is restored from the user's persisted
    # WritEditorPreviewSplitFraction, and resizing the window afterwards
    # pushes it further off, so a split shot inherits whatever ratio the
    # owner happens to use. Force an even split, then let the preview
    # settle — the drag itself triggers a re-layout.
    if [[ "$layout" == "show_split" ]]; then
        drag_divider_to_fraction 0.5 || drag_divider_to_fraction 0.5
    fi
    sleep "$DELAY_MEDIUM"

    if ! wait_for_preview_rendered "${probe[@]}"; then
        refresh_preview
        wait_for_preview_rendered "${probe[@]}" || {
            echo "ERROR: preview did not render for ${fixture}" >&2
            return 1
        }
    fi
    assert_window_geometry
}

# ═══════════════════════════════════════════════════════════════════════════
#  STATE: split — the hero shot. Source and live preview, rich document.
# ═══════════════════════════════════════════════════════════════════════════

capture_split() {
    log_step "split — source and live preview"
    stage_document "incremental-parsing.md" show_split "${SPLIT_PROBE[@]}"
    maybe_pause
    capture_window_only "${OUTPUT_DIR}/01-split.png"
    close_front_document
}

# ═══════════════════════════════════════════════════════════════════════════
#  STATE: math — rendered KaTeX, inline and display
# ═══════════════════════════════════════════════════════════════════════════

capture_math() {
    log_step "math — rendered KaTeX"
    stage_document "parser-cost-model.md" show_split "${SPLIT_PROBE[@]}"
    maybe_pause
    capture_window_only "${OUTPUT_DIR}/02-math.png"
    close_front_document
}

# ═══════════════════════════════════════════════════════════════════════════
#  STATE: diagram — rendered Mermaid flowchart
# ═══════════════════════════════════════════════════════════════════════════

capture_diagram() {
    log_step "diagram — rendered Mermaid"
    stage_document "render-pipeline.md" show_split "${SPLIT_PROBE[@]}"
    maybe_pause
    capture_window_only "${OUTPUT_DIR}/03-diagram.png"
    close_front_document
}

# ═══════════════════════════════════════════════════════════════════════════
#  STATE: preview — preview only, clean rendered typography
# ═══════════════════════════════════════════════════════════════════════════

capture_preview() {
    log_step "preview — rendered typography, no source pane"
    stage_document "writing-with-writ.md" show_preview_only "${PREVIEW_PROBE[@]}"

    # The preview theme centres a readable column, so at 1440pt a bare
    # preview is mostly margin. The outline sidebar fills that space with
    # something worth showing, and AppKit widens the window to make room
    # for a sidebar, so the frame has to be pinned again afterwards.
    toggle_outline
    set_window_geometry
    assert_window_geometry
    wait_for_preview_rendered "${OUTLINE_PREVIEW_PROBE[@]}"

    maybe_pause
    capture_window_only "${OUTPUT_DIR}/04-preview.png"
    toggle_outline            # leave the window as we found it
    close_front_document
}

# ═══════════════════════════════════════════════════════════════════════════
#  STATE: folder — the folder browser listing several documents
# ═══════════════════════════════════════════════════════════════════════════

capture_folder() {
    log_step "folder — folder browser over a document"
    # The browser is a floating NSPanel, not a sidebar, so it lives in its
    # own window on a higher layer. screencapture -l renders one window and
    # would leave it out; capture the document window's screen rectangle
    # instead, which is 1440x900pt and therefore still exactly 2880x1800.
    stage_document "release-checklist.md" show_split "${SPLIT_PROBE[@]}"

    open_folder_via_dialog "$FIXTURES_DIR"
    local panel_title
    panel_title="$(basename "$FIXTURES_DIR")"

    # Inside the document window's frame, clear of its titlebar. 420pt is
    # the panel's own minimum plus a little: tall enough for the fixture
    # list without a half-empty panel under it.
    local panel_x=$((WINDOW_X + 40)) panel_y=$((WINDOW_Y + 90))
    set_panel_geometry "$panel_title" "$panel_x" "$panel_y" 320 420 || {
        echo "ERROR: folder browser panel \"${panel_title}\" did not appear" >&2
        return 1
    }

    # Expand the subfolder so the tree shows real nested structure. The
    # search field takes first responder when the panel opens, so arrow
    # keys alone go to the text field — click the first row first.
    click_at $((panel_x + 60)) $((panel_y + 70))
    send_key_code 124         # Right — expand the selected folder
    sleep "$DELAY_MEDIUM"

    assert_window_geometry
    maybe_pause
    capture_document_window_region "${OUTPUT_DIR}/05-folder.png"

    # Close the panel, then the document.
    send_keystroke "w" "command down"
    sleep "$DELAY_MEDIUM"
    close_front_document
}

# ═══════════════════════════════════════════════════════════════════════════
#  Verification
# ═══════════════════════════════════════════════════════════════════════════

verify_outputs() {
    log_step "Verifying output"
    local failures=0 count=0 f

    shopt -s nullglob
    local pngs=("${OUTPUT_DIR}"/*.png)
    shopt -u nullglob

    if [[ ${#pngs[@]} -eq 0 ]]; then
        echo "FAIL: no PNGs in ${OUTPUT_DIR}" >&2
        return 1
    fi

    for f in "${pngs[@]}"; do
        count=$((count + 1))
        local w h bytes alpha sd
        w=$(sips -g pixelWidth  "$f" | awk '/pixelWidth/  {print $2}')
        h=$(sips -g pixelHeight "$f" | awk '/pixelHeight/ {print $2}')
        bytes=$(stat -f%z "$f")
        alpha=$(sips -g hasAlpha "$f" | awk '/hasAlpha/ {print $2}')
        sd=$(image_stddev "$f")

        local status="ok"
        [[ "$w" == "$EXPECTED_W" && "$h" == "$EXPECTED_H" ]] || status="BAD SIZE (${w}x${h})"
        [[ "$bytes" -ge "$MIN_BYTES" ]] || status="TOO SMALL (${bytes} bytes)"
        [[ "$alpha" != "yes" ]] || status="HAS ALPHA"
        awk -v a="$sd" 'BEGIN { exit !(a > 0.02) }' || status="LOOKS BLANK (stddev ${sd})"

        printf '  %-28s %sx%s  %6s KB  stddev %-8.5f  %s\n' \
            "$(basename "$f")" "$w" "$h" "$((bytes / 1024))" "$sd" "$status"
        [[ "$status" == "ok" ]] || failures=$((failures + 1))
    done

    echo ""
    if [[ $count -lt 4 ]]; then
        echo "FAIL: only ${count} screenshot(s); at least 4 states are required" >&2
        failures=$((failures + 1))
    fi
    if [[ $failures -gt 0 ]]; then
        echo "FAIL: ${failures} problem(s) found." >&2
        return 1
    fi
    echo "PASS: ${count} screenshots, all ${EXPECTED_W}x${EXPECTED_H}, none blank."
}

# ═══════════════════════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════════════════════

main() {
    ensure_dir "$OUTPUT_DIR"

    if [[ "$VERIFY_ONLY" == "true" ]]; then
        verify_outputs
        return
    fi

    assert_app_path_set
    assert_no_foreign_instance

    echo ""
    echo "================================================================"
    echo "  Writ App Store Screenshot Automation"
    echo "================================================================"
    echo "  App:      ${APP_PATH}"
    echo "  Fixtures: ${FIXTURES_DIR}"
    echo "  Output:   ${OUTPUT_DIR}"
    echo "  Window:   ${WINDOW_W}x${WINDOW_H}pt at (${WINDOW_X},${WINDOW_Y}) -> ${EXPECTED_W}x${EXPECTED_H}px"
    echo ""

    if [[ "$INTERACTIVE" == "true" ]]; then
        wait_for_user "Press Enter to begin..."
    else
        echo "  Starting in 3 seconds... (use --interactive for manual control)"
        sleep 3
    fi

    launch_app
    # Restore the frame even if a capture aborts partway: the document
    # window uses setFrameAutosaveName, so leaving it at 1440x900 would
    # change the size the user's own Writ opens at next time.
    trap 'restore_original_bounds || true' EXIT

    # Re-running must overwrite cleanly rather than accumulate stale shots.
    should_capture "split"   && rm -f "${OUTPUT_DIR}/01-split.png"
    should_capture "math"    && rm -f "${OUTPUT_DIR}/02-math.png"
    should_capture "diagram" && rm -f "${OUTPUT_DIR}/03-diagram.png"
    should_capture "preview" && rm -f "${OUTPUT_DIR}/04-preview.png"
    should_capture "folder"  && rm -f "${OUTPUT_DIR}/05-folder.png"

    should_capture "split"   && capture_split
    should_capture "math"    && capture_math
    should_capture "diagram" && capture_diagram
    should_capture "preview" && capture_preview
    should_capture "folder"  && capture_folder

    restore_original_bounds
    quit_app

    verify_outputs
}

main "$@"
