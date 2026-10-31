#!/bin/bash
# lib.sh — Reusable helpers for Writ screenshot automation.
# Adapted from Gridka's scripts/screenshots/lib.sh.
#
# Usage:
#   source "$(dirname "$0")/lib.sh"
#
# Everything is driven by APP_NAME / APP_BUNDLE_ID / APP_PATH and the
# WINDOW_* geometry variables, which may be overridden before or after
# sourcing.
#
# Prerequisites: Screen Recording and Accessibility permission for the
# terminal running this, and ImageMagick for the render verification.

# ─── Configuration (override any of these before or after sourcing) ──────

APP_NAME="${APP_NAME:-Writ}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-org.ceesaxp.Writ}"
# Which bundle to drive. Must be set by the caller: resolving the app by
# name would pick up whatever copy is in /Applications, which is normally
# an older release than the build we want to photograph.
APP_PATH="${APP_PATH:-}"

# Mac App Store wants 2880x1800 for a 16:10 Mac screenshot. The display
# here is 2x Retina, so a window whose *frame* is 1440x900 points captures
# to exactly 2880x1800 physical pixels with no resampling anywhere. That
# is the only reason for these numbers; changing them costs image quality.
WINDOW_X="${WINDOW_X:-180}"                       # window left edge (points)
# Clear of the menu bar at the top and the Dock at the bottom; a
# notification landing in a region capture is handled by
# assert_region_unobstructed, not by where the window sits.
WINDOW_Y="${WINDOW_Y:-60}"                        # window top edge (points)
WINDOW_W="${WINDOW_W:-1440}"                      # window width (points)
WINDOW_H="${WINDOW_H:-900}"                       # window height (points)

DELAY_SHORT="${DELAY_SHORT:-0.5}"
DELAY_MEDIUM="${DELAY_MEDIUM:-1.5}"
DELAY_LONG="${DELAY_LONG:-3.0}"
DELAY_FILE_LOAD="${DELAY_FILE_LOAD:-4.0}"

# The preview is a WKWebView and KaTeX/Mermaid render asynchronously, so
# "it has been N seconds" is never a sufficient reason to press the
# shutter. These bound wait_for_preview_rendered, which polls instead.
PREVIEW_SETTLE_TRIES="${PREVIEW_SETTLE_TRIES:-25}"
PREVIEW_SETTLE_INTERVAL="${PREVIEW_SETTLE_INTERVAL:-1}"
# Normalised (0..1) standard deviation below which a sampled preview
# region is treated as blank. Flat white measures ~0.000; a page of body
# text measures ~0.1. 0.02 is clear of both.
PREVIEW_MIN_STDDEV="${PREVIEW_MIN_STDDEV:-0.02}"

SCRATCH_DIR="${SCRATCH_DIR:-${TMPDIR:-/tmp}/writ-screenshot-scratch}"

# Every geometry helper addresses the document window by subrole rather
# than as "front window". The folder browser is a floating NSPanel, so
# once it opens it *is* the front window, and measuring or resizing that
# instead of the document silently photographs the wrong rectangle.
DOC_WINDOW_REF='first window whose value of attribute "AXSubrole" is "AXStandardWindow"'

# ═══════════════════════════════════════════════════════════════════════════
#  App Lifecycle
# ═══════════════════════════════════════════════════════════════════════════

is_app_running() {
    pgrep -x "$APP_NAME" > /dev/null 2>&1
}

running_app_path() {
    # Executable path of the running instance, or empty if none.
    local pid
    pid=$(pgrep -x "$APP_NAME" | head -1) || true
    [[ -z "$pid" ]] && return 0
    ps -o comm= -p "$pid" 2>/dev/null || true
}

assert_app_path_set() {
    if [[ -z "$APP_PATH" ]]; then
        echo "ERROR: APP_PATH is empty. Pass --app-path /path/to/${APP_NAME}.app." >&2
        return 1
    fi
    if [[ ! -d "$APP_PATH" ]]; then
        echo "ERROR: no app bundle at: ${APP_PATH}" >&2
        return 1
    fi
    # Resolve to the physical path. `ps` reports the real path, so a
    # bundle reached through a symlinked parent (/tmp -> /private/tmp)
    # would otherwise fail assert_running_from_app_path on a prefix
    # comparison that is only cosmetically different.
    APP_PATH="$(cd "$APP_PATH" && pwd -P)"
}

assert_no_foreign_instance() {
    # A copy of the app launched from somewhere else would swallow the
    # documents we open (LaunchServices routes them to the running
    # instance) and we would photograph the wrong build. Refuse rather
    # than quit it for the user: it may be holding unsaved work.
    local running
    running=$(running_app_path)
    [[ -z "$running" ]] && return 0
    case "$running" in
        "${APP_PATH%/}"/*) return 0 ;;
    esac
    echo "ERROR: ${APP_NAME} is already running from a different bundle:" >&2
    echo "         ${running}" >&2
    echo "       Expected it under: ${APP_PATH}" >&2
    echo "       Quit that instance yourself (it may hold unsaved work) and retry." >&2
    return 1
}

assert_running_from_app_path() {
    local running
    running=$(running_app_path)
    case "$running" in
        "${APP_PATH%/}"/*) return 0 ;;
    esac
    echo "ERROR: expected a running ${APP_NAME} under ${APP_PATH}, found: ${running:-<none>}" >&2
    return 1
}

launch_app() {
    echo "==> Launching ${APP_NAME} from ${APP_PATH}"
    open -a "$APP_PATH"
    sleep "$DELAY_LONG"
    assert_running_from_app_path
    activate_app
}

activate_app() {
    # System Events rather than `tell application "Writ" to activate`:
    # the latter resolves the app by name and would launch the copy in
    # /Applications if ours were not running.
    osascript -e "
        tell application \"System Events\"
            tell process \"${APP_NAME}\" to set frontmost to true
        end tell
        delay 0.3
    " > /dev/null
}

quit_app() {
    # Guarded, and addressed by bundle id: an unguarded
    # `tell application "Writ" to quit` *launches* a Writ in order to
    # quit it, and resolves by name while doing so.
    is_app_running || return 0
    echo "==> Quitting ${APP_NAME}..."
    osascript -e "tell application id \"${APP_BUNDLE_ID}\" to quit" > /dev/null 2>&1 || true
    sleep "$DELAY_MEDIUM"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Window Management
# ═══════════════════════════════════════════════════════════════════════════

get_window_bounds() {
    # Returns: x,y,w,h in points, top-left origin — the same coordinate
    # space screencapture -R uses.
    osascript -e "
        tell application \"System Events\"
            tell process \"${APP_NAME}\"
                tell (${DOC_WINDOW_REF})
                    set {x, y} to position
                    set {w, h} to size
                end tell
                return (x as text) & \",\" & (y as text) & \",\" & (w as text) & \",\" & (h as text)
            end tell
        end tell
    "
}

set_window_geometry() {
    local x="${1:-$WINDOW_X}" y="${2:-$WINDOW_Y}" w="${3:-$WINDOW_W}" h="${4:-$WINDOW_H}"
    osascript -e "
        tell application \"System Events\"
            tell process \"${APP_NAME}\"
                set frontmost to true
                delay 0.2
                tell (${DOC_WINDOW_REF})
                    set position to {${x}, ${y}}
                    set size to {${w}, ${h}}
                end tell
            end tell
        end tell
    " > /dev/null
    sleep "$DELAY_SHORT"
}

assert_window_geometry() {
    # The pixel dimensions of every shot depend on this being exact, and
    # switching layout mode has historically moved the window on its own
    # (the 2026-08-21 ratchet bug), so check rather than assume.
    local want_w="${1:-$WINDOW_W}" want_h="${2:-$WINDOW_H}"
    local bounds
    bounds=$(get_window_bounds)
    IFS=',' read -r _x _y w h <<< "$bounds"
    if [[ "$w" != "$want_w" || "$h" != "$want_h" ]]; then
        echo "ERROR: window is ${w}x${h}, expected ${want_w}x${want_h}" >&2
        return 1
    fi
}

get_window_id() {
    # CGWindowID of the frontmost document window. Layer 0 excludes the
    # folder browser, which is a floating NSPanel and therefore sits on a
    # higher layer.
    #
    # ObjC.bindFunction rather than relying on `ObjC.import('CoreGraphics')`
    # to supply the signature: on macOS 27 the imported symbol comes back
    # as an unresolved stub, so the call returns a function object and
    # every property read off it is undefined.
    osascript -l JavaScript -e "
        ObjC.import('Cocoa');
        ObjC.bindFunction('CGWindowListCopyWindowInfo',
                          ['id', ['unsigned int', 'unsigned int']]);
        var kOnScreenOnly = 1;
        var info = \$.CGWindowListCopyWindowInfo(kOnScreenOnly, 0);
        var found = -1;
        for (var i = 0; i < info.count && found === -1; i++) {
            var w = info.objectAtIndex(i);
            if (ObjC.unwrap(w.objectForKey('kCGWindowOwnerName')) === '${APP_NAME}'
                && ObjC.unwrap(w.objectForKey('kCGWindowLayer')) === 0) {
                found = ObjC.unwrap(w.objectForKey('kCGWindowNumber'));
            }
        }
        found;
    "
}

get_divider_geometry() {
    # Echoes "win_x win_w divider_x divider_w mid_y" for the editor|preview
    # divider, read from the accessibility tree. The collapsed outline
    # sidebar contributes a zero-width splitter, so pick the one that has
    # width. Returns 1 when no such splitter exists (single-pane layouts).
    osascript -e "
        tell application \"System Events\"
            tell process \"${APP_NAME}\"
                tell (${DOC_WINDOW_REF})
                    set {wx, wy} to position
                    set {ww, wh} to size
                    repeat with g in (every splitter group)
                        repeat with s in (every splitter of g)
                            set {sx, sy} to position of s
                            set {sw, sh} to size of s
                            if sw > 0 then
                                set midY to sy + (sh div 2)
                                return (wx as text) & \" \" & (ww as text) & \" \" & (sx as text) & \" \" & (sw as text) & \" \" & (midY as text)
                            end if
                        end repeat
                    end repeat
                end tell
                return \"\"
            end tell
        end tell
    " 2>/dev/null | grep . || return 1
}

drag_divider_to_fraction() {
    # Move the editor|preview divider so the editor occupies `fraction` of
    # the editing area. There is no API for this: the split position is
    # persisted by the app's own splitViewDidResize observer, so the only
    # way to set it is to actually drag the divider.
    #
    # NOTE: this necessarily changes the user's persisted
    # WritEditorPreviewSplitFraction. That is deliberate and sanctioned
    # for screenshots; nothing else here touches a preference.
    local fraction="${1:-0.5}" tolerance="${2:-8}"
    local geom wx ww dx dw my target grab release

    geom=$(get_divider_geometry) || { echo "    No divider in this layout; skipping"; return 0; }
    read -r wx ww dx dw my <<< "$geom"

    # Measure to equal *pane* widths, so the divider's own thickness is
    # split between them rather than silently charged to the preview.
    target=$(awk -v wx="$wx" -v ww="$ww" -v dw="$dw" -v f="$fraction" \
        'BEGIN { printf "%d", wx + f * (ww - dw) }')
    grab=$((dx + dw / 2))
    release=$((target + dw / 2))

    local gap=$((dx > target ? dx - target : target - dx))
    if [[ $gap -le $tolerance ]]; then
        echo "    Divider already at ${dx} (target ${target})"
        return 0
    fi

    echo "    Dragging divider ${dx} -> ${target}"
    # AppKit ignores a single teleporting drag event, so step toward the
    # target. CGEvent and AppleScript window coordinates are both
    # top-left origin, so no conversion is needed.
    osascript -l JavaScript -e "
        ObjC.import('CoreGraphics');
        function post(type, x, y) {
            var e = \$.CGEventCreateMouseEvent(\$(), type, \$.CGPointMake(x, y), \$.kCGMouseButtonLeft);
            \$.CGEventPost(\$.kCGHIDEventTap, e);
        }
        var fromX = ${grab}, toX = ${release}, y = ${my};
        post(\$.kCGEventMouseMoved, fromX, y);
        delay(0.3);
        post(\$.kCGEventLeftMouseDown, fromX, y);
        delay(0.2);
        for (var i = 1; i <= 20; i++) {
            post(\$.kCGEventLeftMouseDragged, Math.round(fromX + (toX - fromX) * i / 20), y);
            delay(0.02);
        }
        delay(0.2);
        post(\$.kCGEventLeftMouseUp, toX, y);
    " > /dev/null
    sleep "$DELAY_MEDIUM"

    # Verify the events actually landed rather than assuming they did.
    geom=$(get_divider_geometry) || return 1
    read -r wx ww dx dw my <<< "$geom"
    local delta=$((dx > target ? dx - target : target - dx))
    if [[ $delta -gt $tolerance ]]; then
        echo "    WARNING: divider is at ${dx}, wanted ${target} (off by ${delta})" >&2
        return 1
    fi
    awk -v a="$dx" -v b="$wx" -v c="$ww" \
        'BEGIN { printf "    Divider at %d (editor %.1f%% of the window)\n", a, 100*(a-b)/c }'
}

set_panel_geometry() {
    # Position a named auxiliary window (the folder browser panel) so it
    # sits inside the document window's frame.
    local title="$1" x="$2" y="$3" w="$4" h="$5"
    osascript -e "
        tell application \"System Events\"
            tell process \"${APP_NAME}\"
                tell window \"${title}\"
                    set position to {${x}, ${y}}
                    set size to {${w}, ${h}}
                end tell
            end tell
        end tell
    " > /dev/null
    sleep "$DELAY_SHORT"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Screenshot Capture
# ═══════════════════════════════════════════════════════════════════════════

flatten_png() {
    # screencapture leaves the window's rounded corners transparent.
    # App Store Connect rejects PNGs with an alpha channel, so composite
    # onto white. -alpha remove/off touches only the alpha channel, so
    # the pixel dimensions are untouched and nothing is resampled.
    local file="$1"
    [[ "$(sips -g hasAlpha "$file" 2>/dev/null | awk '/hasAlpha/ {print $2}')" == "yes" ]] || return 0
    magick "$file" -background white -alpha remove -alpha off "$file"
}

capture_window_only() {
    # Capture just the frontmost document window. -o drops the drop
    # shadow, which is what makes the output exactly the window's frame
    # in physical pixels rather than shadow-padded.
    local output_file="$1"
    local wid
    wid=$(get_window_id)
    if [[ "$wid" == "-1" || -z "$wid" ]]; then
        echo "ERROR: could not find a ${APP_NAME} window to capture" >&2
        return 1
    fi
    screencapture -x -o -l "$wid" "$output_file"
    flatten_png "$output_file"
    echo "    Saved: $output_file"
}

# Owners of permanent full-screen system windows that sit above the
# normal layer and are never actually visible over a document. The Dock
# in particular hosts a 1800x1169 window at layer 20 at all times, so
# without this list every region would look obstructed.
OBSTRUCTION_IGNORE="${OBSTRUCTION_IGNORE:-Dock|Window Server|WindowManager|Wallpaper|Finder}"

foreign_windows_overlapping() {
    # Echo one line per on-screen window above the normal layer, not
    # owned by this app, whose frame intersects the given rect.
    local x="$1" y="$2" w="$3" h="$4"
    osascript -l JavaScript -e "
        ObjC.import('Cocoa');
        ObjC.bindFunction('CGWindowListCopyWindowInfo',
                          ['id', ['unsigned int', 'unsigned int']]);
        var RX = ${x}, RY = ${y}, RW = ${w}, RH = ${h};
        var ignore = '${OBSTRUCTION_IGNORE}'.split('|');
        var info = \$.CGWindowListCopyWindowInfo(1, 0);
        var out = [];
        for (var i = 0; i < info.count; i++) {
            var win = info.objectAtIndex(i);
            var owner = ObjC.unwrap(win.objectForKey('kCGWindowOwnerName'));
            var layer = ObjC.unwrap(win.objectForKey('kCGWindowLayer'));
            if (layer <= 0) continue;
            if (owner === '${APP_NAME}' || ignore.indexOf(owner) !== -1) continue;
            var b = win.objectForKey('kCGWindowBounds');
            if (!b) continue;
            var bx = ObjC.unwrap(b.objectForKey('X')), by = ObjC.unwrap(b.objectForKey('Y'));
            var bw = ObjC.unwrap(b.objectForKey('Width')), bh = ObjC.unwrap(b.objectForKey('Height'));
            if (bx < RX + RW && bx + bw > RX && by < RY + RH && by + bh > RY) {
                out.push(owner + ' [' + bx + ',' + by + ' ' + bw + 'x' + bh + ']');
            }
        }
        out.join('\n');
    " 2>/dev/null
}

assert_region_unobstructed() {
    # A region capture renders whatever is on screen, so a notification
    # banner dropping in mid-shot lands in the PNG — and ships the
    # user's private message to the App Store. Window captures (-l) are
    # immune; this is only for the region path. Banners self-dismiss, so
    # wait rather than fail outright.
    local x="$1" y="$2" w="$3" h="$4"
    local i intruders
    for ((i = 1; i <= 10; i++)); do
        intruders=$(foreign_windows_overlapping "$x" "$y" "$w" "$h")
        [[ -z "$intruders" ]] && return 0
        echo "    Waiting for an overlapping window to go away: ${intruders//$'\n'/; }"
        sleep 2
    done
    echo "ERROR: something is covering the capture region: ${intruders//$'\n'/; }" >&2
    return 1
}

capture_document_window_region() {
    # Capture the screen rectangle the document window occupies.
    # Needed when the shot must include a floating panel stacked over the
    # window: screencapture -l renders a single window and would leave the
    # panel out.
    local output_file="$1"
    local bounds
    bounds=$(get_window_bounds)
    IFS=',' read -r wx wy ww wh <<< "$bounds"
    assert_region_unobstructed "$wx" "$wy" "$ww" "$wh" || return 1
    screencapture -x -R "${wx},${wy},${ww},${wh}" "$output_file"
    flatten_png "$output_file"
    echo "    Saved: $output_file"
}

capture_region_to() {
    # Raw region capture, used for the render probe rather than for output.
    local output_file="$1" x="$2" y="$3" w="$4" h="$5"
    screencapture -x -R "${x},${y},${w},${h}" "$output_file"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Render Verification
# ═══════════════════════════════════════════════════════════════════════════

image_stddev() {
    # Normalised 0..1 standard deviation of an image's pixels. ~0 for a
    # flat fill, which is what a blank or still-loading preview looks like.
    # stderr is dropped: screencapture writes an ICC profile ImageMagick
    # grumbles about on every single read, which would bury real errors.
    magick "$1" -colorspace Gray -format '%[fx:standard_deviation]' info: 2>/dev/null
}

wait_for_preview_rendered() {
    # Poll a window-relative rectangle of the preview pane until it both
    # (a) carries content and (b) stops changing between samples. Two
    # identical non-flat samples means KaTeX/Mermaid have settled; a
    # fixed sleep cannot tell "finished" from "about to repaint", and a
    # half-rendered preview is the main way this task fails silently.
    local rel_x="$1" rel_y="$2" w="$3" h="$4"
    local bounds
    bounds=$(get_window_bounds)
    IFS=',' read -r wx wy _ww _wh <<< "$bounds"
    local x=$((wx + rel_x)) y=$((wy + rel_y))

    mkdir -p "$SCRATCH_DIR"
    local probe="${SCRATCH_DIR}/preview-probe.png"
    local previous="" current sd
    local i
    for ((i = 1; i <= PREVIEW_SETTLE_TRIES; i++)); do
        capture_region_to "$probe" "$x" "$y" "$w" "$h"
        current=$(md5 -q "$probe")
        sd=$(image_stddev "$probe")
        if awk -v a="$sd" -v b="$PREVIEW_MIN_STDDEV" 'BEGIN { exit !(a > b) }' \
           && [[ "$current" == "$previous" ]]; then
            echo "    Preview settled after ${i}s (stddev ${sd})"
            return 0
        fi
        previous="$current"
        sleep "$PREVIEW_SETTLE_INTERVAL"
    done
    echo "    WARNING: preview never settled (last stddev ${sd})" >&2
    return 1
}

refresh_preview() {
    echo "    Refreshing preview (Cmd+R)"
    send_keystroke "r" "command down"
    sleep "$DELAY_MEDIUM"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Keyboard / Menus
# ═══════════════════════════════════════════════════════════════════════════

send_keystroke() {
    # Usage: send_keystroke "r" "command down"
    local key="$1" modifiers="${2:-}"
    if [[ -n "$modifiers" ]]; then
        osascript -e "
            tell application \"System Events\"
                tell process \"${APP_NAME}\"
                    keystroke \"${key}\" using {${modifiers}}
                end tell
            end tell
        " > /dev/null
    else
        osascript -e "
            tell application \"System Events\"
                tell process \"${APP_NAME}\"
                    keystroke \"${key}\"
                end tell
            end tell
        " > /dev/null
    fi
}

send_key_code() {
    # Return=36, Tab=48, Escape=53, Delete=51, Space=49,
    # Down=125, Up=126, Left=123, Right=124
    local code="$1" modifiers="${2:-}"
    if [[ -n "$modifiers" ]]; then
        osascript -e "
            tell application \"System Events\"
                tell process \"${APP_NAME}\"
                    key code ${code} using {${modifiers}}
                end tell
            end tell
        " > /dev/null
    else
        osascript -e "
            tell application \"System Events\"
                tell process \"${APP_NAME}\"
                    key code ${code}
                end tell
            end tell
        " > /dev/null
    fi
}

type_text() {
    local text="$1"
    osascript -e "
        tell application \"System Events\"
            tell process \"${APP_NAME}\"
                keystroke \"${text}\"
            end tell
        end tell
    " > /dev/null
}

click_at() {
    # Left-click at absolute screen coordinates (points).
    local x="$1" y="$2"
    osascript -l JavaScript -e "
        ObjC.import('CoreGraphics');
        var pt = \$.CGPointMake(${x}, ${y});
        var down = \$.CGEventCreateMouseEvent(\$(), \$.kCGEventLeftMouseDown, pt, \$.kCGMouseButtonLeft);
        \$.CGEventPost(\$.kCGHIDEventTap, down);
        delay(0.05);
        var up = \$.CGEventCreateMouseEvent(\$(), \$.kCGEventLeftMouseUp, pt, \$.kCGMouseButtonLeft);
        \$.CGEventPost(\$.kCGHIDEventTap, up);
    " > /dev/null
    sleep "$DELAY_SHORT"
}

click_menu_item() {
    # Click a menu item by title. Preferred over the keyboard equivalent
    # for the layout switcher: those are Cmd+Opt+digit, and Option+digit
    # is keyboard-layout dependent, so a keystroke can silently insert a
    # character instead of switching panes.
    local menu="$1" item="$2"
    echo "    Menu: ${menu} > ${item}"
    osascript -e "
        tell application \"System Events\"
            tell process \"${APP_NAME}\"
                set frontmost to true
                delay 0.2
                click menu item \"${item}\" of menu 1 of menu bar item \"${menu}\" of menu bar 1
            end tell
        end tell
    " > /dev/null
    sleep "$DELAY_SHORT"
}

# ═══════════════════════════════════════════════════════════════════════════
#  View State
# ═══════════════════════════════════════════════════════════════════════════

# These go through the View menu, which calls setLayout(_:) — it does not
# write WritDefaultLayoutMode, so switching panes here leaves no trace in
# the user's preferences.
show_source_only()  { click_menu_item "View" "Source Only"; }
show_preview_only() { click_menu_item "View" "Preview Only"; }
show_split()        { click_menu_item "View" "Source & Preview"; }

toggle_outline() {
    # validateMenuItem rewrites this item's title on every menu open, so
    # the title is the state: whichever of the two exists is the one that
    # will flip it. Toggling the sidebar persists nothing.
    click_menu_item "View" "Show Outline" 2>/dev/null \
        || click_menu_item "View" "Hide Outline"
}

# ═══════════════════════════════════════════════════════════════════════════
#  File Operations
# ═══════════════════════════════════════════════════════════════════════════

open_file() {
    # Opened through APP_PATH so the document cannot land in a different
    # copy of the app.
    local filepath="$1"
    echo "    Opening: $(basename "$filepath")"
    open -a "$APP_PATH" "$filepath"
    sleep "$DELAY_FILE_LOAD"
}

close_front_document() {
    send_keystroke "w" "command down"
    sleep "$DELAY_MEDIUM"
}

open_folder_via_dialog() {
    # File > Open Folder… is an NSOpenPanel; in a sandboxed app that is
    # Powerbox, and picking the folder there is what grants access to it.
    # Cmd+Shift+G ("Go to Folder") is the only reliable way to steer it
    # without clicking around a file browser.
    local folder="$1"
    echo "    Opening folder via dialog: ${folder}"
    send_keystroke "O" "command down, shift down"
    sleep "$DELAY_MEDIUM"

    send_keystroke "g" "command down, shift down"
    sleep "$DELAY_MEDIUM"

    type_text "$folder"
    sleep "$DELAY_MEDIUM"
    send_key_code 36          # Return — resolve the typed path
    sleep "$DELAY_MEDIUM"
    send_key_code 36          # Return — accept it and open
    sleep "$DELAY_LONG"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Utilities
# ═══════════════════════════════════════════════════════════════════════════

wait_for_user() {
    local message="${1:-Press Enter to continue...}"
    echo ""
    echo "    >>> $message"
    read -r
}

log_step() {
    local label="$1"
    echo ""
    echo "========================================================"
    echo "  $label"
    echo "========================================================"
}

ensure_dir() {
    mkdir -p "$1"
}
