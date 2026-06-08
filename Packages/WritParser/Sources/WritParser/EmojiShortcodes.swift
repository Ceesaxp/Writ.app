import Foundation

/// GitHub-style emoji shortcode → glyph substitution for inline text.
///
/// Curated subset of the gemoji set — the ~200 most-commonly-used
/// shortcodes a markdown writer reaches for. Unknown shortcodes are
/// passed through verbatim (no warning, no error). The full gemoji
/// table is ~1,500 entries; expanding the bundled set later is purely
/// additive.
enum EmojiShortcodes {
    /// Replace every `:name:` token in `text` whose `name` matches a
    /// known shortcode with the corresponding emoji glyph. Tokens that
    /// don't match a known shortcode are left as literal text.
    static func substitute(in text: String) -> String {
        guard text.contains(":") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == ":" {
                // Scan forward for a closing ':' within a reasonable
                // window (32 chars is well above the longest gemoji
                // shortcode). The name body must match
                // [a-zA-Z0-9_+\-].
                var probe = text.index(after: i)
                var nameChars: [Character] = []
                let maxLen = 32
                var len = 0
                var found: String.Index?
                while probe < text.endIndex, len < maxLen {
                    let pc = text[probe]
                    if pc == ":" {
                        found = probe
                        break
                    }
                    if !isShortcodeChar(pc) {
                        break
                    }
                    nameChars.append(pc)
                    probe = text.index(after: probe)
                    len += 1
                }
                if let close = found, !nameChars.isEmpty,
                   let glyph = table[String(nameChars)] {
                    out.append(glyph)
                    i = text.index(after: close)
                    continue
                }
            }
            out.append(c)
            i = text.index(after: i)
        }
        return out
    }

    private static func isShortcodeChar(_ c: Character) -> Bool {
        if c.isLetter || c.isNumber { return true }
        if c == "_" || c == "-" || c == "+" { return true }
        return false
    }

    // MARK: - Table

    /// Curated common shortcodes. Sorted roughly by usage frequency.
    /// Add to this dictionary (don't rename existing entries — users
    /// have these in their docs already).
    private static let table: [String: String] = [
        // Faces — smiley
        "smile": "😄", "smiley": "😃", "grinning": "😀", "grin": "😁",
        "laughing": "😆", "satisfied": "😆", "sweat_smile": "😅",
        "joy": "😂", "rofl": "🤣", "rolling_on_the_floor_laughing": "🤣",
        "slightly_smiling_face": "🙂", "upside_down_face": "🙃",
        "wink": "😉", "blush": "😊", "innocent": "😇",
        "heart_eyes": "😍", "kissing_heart": "😘", "kissing": "😗",
        "yum": "😋", "stuck_out_tongue": "😛", "stuck_out_tongue_winking_eye": "😜",
        "zany_face": "🤪", "sunglasses": "😎", "nerd_face": "🤓",

        // Faces — neutral & sad
        "neutral_face": "😐", "expressionless": "😑", "no_mouth": "😶",
        "thinking": "🤔", "face_with_raised_eyebrow": "🤨",
        "smirk": "😏", "unamused": "😒", "roll_eyes": "🙄",
        "grimacing": "😬", "lying_face": "🤥",
        "relieved": "😌", "pensive": "😔", "sleepy": "😪",
        "drooling_face": "🤤", "sleeping": "😴",
        "mask": "😷", "thermometer_face": "🤒", "head_bandage": "🤕",
        "nauseated_face": "🤢", "vomiting_face": "🤮",
        "sneezing_face": "🤧", "hot_face": "🥵", "cold_face": "🥶",
        "dizzy_face": "😵", "exploding_head": "🤯",
        "cowboy_hat_face": "🤠", "partying_face": "🥳",
        "disguised_face": "🥸",

        // Faces — angry / sad
        "confused": "😕", "worried": "😟", "slightly_frowning_face": "🙁",
        "white_frowning_face": "☹️", "open_mouth": "😮", "hushed": "😯",
        "astonished": "😲", "flushed": "😳", "frowning": "😦",
        "anguished": "😧", "fearful": "😨", "cold_sweat": "😰",
        "disappointed_relieved": "😥", "cry": "😢", "sob": "😭",
        "scream": "😱", "confounded": "😖", "persevere": "😣",
        "disappointed": "😞", "sweat": "😓", "weary": "😩", "tired_face": "😫",
        "yawning_face": "🥱", "triumph": "😤", "rage": "😡", "pout": "😡",
        "angry": "😠", "cursing_face": "🤬",

        // Hands / gestures
        "wave": "👋", "raised_back_of_hand": "🤚", "raised_hand": "✋",
        "vulcan_salute": "🖖", "ok_hand": "👌", "pinching_hand": "🤏",
        "v": "✌️", "crossed_fingers": "🤞",
        "love_you_gesture": "🤟", "metal": "🤘", "call_me_hand": "🤙",
        "point_left": "👈", "point_right": "👉", "point_up_2": "👆",
        "middle_finger": "🖕", "point_down": "👇", "point_up": "☝️",
        "thumbsup": "👍", "+1": "👍", "thumbsdown": "👎", "-1": "👎",
        "fist": "✊", "facepunch": "👊", "punch": "👊", "left_facing_fist": "🤛",
        "right_facing_fist": "🤜", "clap": "👏", "raised_hands": "🙌",
        "open_hands": "👐", "palms_up_together": "🤲", "handshake": "🤝",
        "pray": "🙏", "muscle": "💪", "selfie": "🤳",

        // Hearts & symbols
        "heart": "❤️", "orange_heart": "🧡", "yellow_heart": "💛",
        "green_heart": "💚", "blue_heart": "💙", "purple_heart": "💜",
        "black_heart": "🖤", "white_heart": "🤍", "brown_heart": "🤎",
        "broken_heart": "💔", "heart_exclamation": "❣️",
        "two_hearts": "💕", "revolving_hearts": "💞",
        "heartbeat": "💓", "heartpulse": "💗", "sparkling_heart": "💖",
        "cupid": "💘", "gift_heart": "💝", "heart_decoration": "💟",

        // Status / check / alert
        "white_check_mark": "✅", "heavy_check_mark": "✔️",
        "check": "✅", "ballot_box_with_check": "☑️",
        "x": "❌", "negative_squared_cross_mark": "❎",
        "heavy_multiplication_x": "✖️",
        "warning": "⚠️", "no_entry": "⛔", "no_entry_sign": "🚫",
        "exclamation": "❗", "heavy_exclamation_mark": "❗",
        "grey_exclamation": "❕", "question": "❓", "grey_question": "❔",
        "information_source": "ℹ️", "ok": "🆗", "cool": "🆒",
        "new": "🆕", "free": "🆓", "vs": "🆚", "no_good": "🙅",
        "ng": "🆖", "sos": "🆘", "up": "🆙", "back": "🔙",
        "end": "🔚", "on": "🔛", "soon": "🔜", "top": "🔝",

        // Arrows
        "arrow_right": "➡️", "arrow_left": "⬅️", "arrow_up": "⬆️",
        "arrow_down": "⬇️", "arrow_upper_left": "↖️", "arrow_upper_right": "↗️",
        "arrow_lower_right": "↘️", "arrow_lower_left": "↙️",
        "leftwards_arrow_with_hook": "↩️", "arrow_right_hook": "↪️",
        "twisted_rightwards_arrows": "🔀", "repeat": "🔁",
        "repeat_one": "🔂", "arrows_clockwise": "🔃",
        "arrows_counterclockwise": "🔄",

        // Misc symbols
        "fire": "🔥", "star": "⭐", "star2": "🌟", "sparkles": "✨",
        "dizzy": "💫", "boom": "💥", "collision": "💥",
        "anger": "💢", "sweat_drops": "💦", "droplet": "💧",
        "zzz": "💤", "dash": "💨", "100": "💯", "tada": "🎉",
        "confetti_ball": "🎊", "balloon": "🎈", "gift": "🎁",
        "trophy": "🏆", "medal_sports": "🏅", "1st_place_medal": "🥇",
        "2nd_place_medal": "🥈", "3rd_place_medal": "🥉",
        "crown": "👑", "ring": "💍", "gem": "💎",

        // Travel / objects
        "rocket": "🚀", "airplane": "✈️", "car": "🚗", "bicycle": "🚲",
        "ship": "🚢", "anchor": "⚓", "sailboat": "⛵",
        "alarm_clock": "⏰", "hourglass": "⌛",
        "hourglass_flowing_sand": "⏳", "watch": "⌚",
        "calendar": "📆", "date": "📅", "spiral_calendar_pad": "🗓️",
        "spiral_notepad": "🗒️", "memo": "📝", "pencil2": "✏️",
        "pen": "🖊️", "fountain_pen": "🖋️",
        "book": "📖", "books": "📚", "scroll": "📜", "bookmark": "🔖",
        "label": "🏷️", "pushpin": "📌", "round_pushpin": "📍",
        "paperclip": "📎", "linked_paperclips": "🖇️", "link": "🔗",
        "lock": "🔒", "unlock": "🔓", "lock_with_ink_pen": "🔏",
        "closed_lock_with_key": "🔐", "key": "🔑",
        "old_key": "🗝️", "shield": "🛡️",
        "bulb": "💡", "wrench": "🔧", "hammer": "🔨",
        "hammer_and_wrench": "🛠️", "gear": "⚙️", "nut_and_bolt": "🔩",
        "magnet": "🧲", "test_tube": "🧪", "petri_dish": "🧫",
        "telescope": "🔭", "microscope": "🔬",
        "satellite": "🛰️", "satellite_antenna": "📡",

        // Tech
        "computer": "💻", "desktop_computer": "🖥️", "keyboard": "⌨️",
        "printer": "🖨️", "computer_mouse": "🖱️", "trackball": "🖲️",
        "iphone": "📱", "phone": "☎️", "telephone": "☎️",
        "email": "📧", "e-mail": "📧", "incoming_envelope": "📨",
        "envelope_with_arrow": "📩", "envelope": "✉️",
        "outbox_tray": "📤", "inbox_tray": "📥",
        "package": "📦", "mailbox": "📫", "mailbox_closed": "📪",
        "headphones": "🎧", "microphone": "🎤", "musical_note": "🎵",
        "notes": "🎶", "loud_sound": "🔊", "mute": "🔇",
        "speaker": "🔈", "sound": "🔉", "loudspeaker": "📢",
        "mega": "📣", "bell": "🔔", "no_bell": "🔕",

        // Nature
        "sunny": "☀️", "partly_sunny": "⛅", "cloud": "☁️",
        "umbrella": "☂️", "umbrella_with_rain_drops": "☔",
        "snowflake": "❄️", "rainbow": "🌈", "ocean": "🌊",
        "fog": "🌫️", "snowman": "⛄", "comet": "☄️",
        "earth_africa": "🌍", "earth_americas": "🌎", "earth_asia": "🌏",
        "moon": "🌖", "new_moon": "🌑", "full_moon": "🌕",
        "first_quarter_moon": "🌓", "crescent_moon": "🌙",
        "deciduous_tree": "🌳", "evergreen_tree": "🌲",
        "palm_tree": "🌴", "cactus": "🌵", "seedling": "🌱",
        "herb": "🌿", "shamrock": "☘️", "four_leaf_clover": "🍀",
        "tulip": "🌷", "rose": "🌹", "sunflower": "🌻",
        "blossom": "🌼", "cherry_blossom": "🌸",

        // Animals
        "dog": "🐶", "cat": "🐱", "mouse": "🐭", "hamster": "🐹",
        "rabbit": "🐰", "fox_face": "🦊", "bear": "🐻",
        "panda_face": "🐼", "koala": "🐨", "tiger": "🐯",
        "lion": "🦁", "cow": "🐮", "pig": "🐷", "frog": "🐸",
        "monkey_face": "🐵", "chicken": "🐔", "penguin": "🐧",
        "bird": "🐦", "baby_chick": "🐤", "duck": "🦆",
        "owl": "🦉", "bat": "🦇", "wolf": "🐺", "horse": "🐴",
        "unicorn": "🦄", "bee": "🐝", "bug": "🐛", "ladybug": "🐞",
        "spider": "🕷️", "fish": "🐠", "tropical_fish": "🐠",
        "whale": "🐳", "dolphin": "🐬", "shark": "🦈",
        "octopus": "🐙", "snail": "🐌", "turtle": "🐢",

        // Food
        "coffee": "☕", "tea": "🍵", "beer": "🍺", "beers": "🍻",
        "wine_glass": "🍷", "cocktail": "🍸", "tropical_drink": "🍹",
        "champagne": "🍾", "clinking_glasses": "🥂",
        "pizza": "🍕", "hamburger": "🍔", "fries": "🍟",
        "hotdog": "🌭", "sandwich": "🥪", "taco": "🌮",
        "burrito": "🌯", "salad": "🥗", "bread": "🍞",
        "croissant": "🥐", "bagel": "🥯", "cheese": "🧀",
        "egg": "🥚", "bacon": "🥓", "rice": "🍚",
        "apple": "🍎", "banana": "🍌", "grapes": "🍇",
        "watermelon": "🍉", "tangerine": "🍊", "lemon": "🍋",
        "strawberry": "🍓", "peach": "🍑", "cherries": "🍒",
        "pineapple": "🍍", "tomato": "🍅", "carrot": "🥕",
        "corn": "🌽", "cake": "🎂", "birthday": "🎂",
        "ice_cream": "🍨", "lollipop": "🍭", "candy": "🍬",
        "cookie": "🍪", "chocolate_bar": "🍫", "doughnut": "🍩",

        // People / activities (kept small — gendered/skin-toned variants
        // are out of scope for the curated set)
        "boy": "👦", "girl": "👧", "man": "👨", "woman": "👩",
        "baby": "👶", "older_man": "👴", "older_woman": "👵",
        "construction_worker": "👷", "cop": "👮", "guardsman": "💂",
        "santa": "🎅", "angel": "👼", "ghost": "👻", "alien": "👽",
        "imp": "👿", "skull": "💀", "skull_and_crossbones": "☠️",
        "poop": "💩", "robot": "🤖", "clown_face": "🤡",
        "see_no_evil": "🙈", "hear_no_evil": "🙉", "speak_no_evil": "🙊",
        "eyes": "👀", "eye": "👁️", "ear": "👂", "nose": "👃",
        "mouth": "👄", "tongue": "👅", "tooth": "🦷",
        "brain": "🧠"
    ]
}
