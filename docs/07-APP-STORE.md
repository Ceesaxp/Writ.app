# Mac App Store Submission

How to put Writ on the Mac App Store. Writ has only ever been distributed with
a Developer ID — notarized DMG plus a Homebrew cask — so everything in §1 is
new ground, and the first submission is blocked on two certificates that do not
exist on this machine yet.

Modelled on the guide Gridka actually shipped with
(`/Users/andrei/Code/Swift/Gridka/docs/APP_STORE_SUBMISSION.md`). Where Gridka
hit a wall, the relevant commit is cited so the claim can be checked.

## 1. Prerequisites

### Certificates — the current blocker

A Developer ID build and an App Store build are signed by different
certificates. `security find-identity -v -p codesigning` on this machine
reports exactly two identities:

| Identity | Team | Use |
| --- | --- | --- |
| `Developer ID Application: Andrei Popov (Q34D9AYJ95)` | Q34D9AYJ95 | DMG / Homebrew. Already in use. |
| `Apple Development: Andrei Popov (FJZF85YVKR)` | FJZF85YVKR | Local development only. |

Note that the second identity belongs to a *different* team ID than the one
`project.yml` builds against (`DEVELOPMENT_TEAM: Q34D9AYJ95`). It is not
partial progress toward a distribution certificate.

Two certificates still have to be created in the developer portal, both under
team Q34D9AYJ95:

1. **Apple Distribution** — signs the `.app` for App Store submission.
2. **Mac Installer Distribution** — signs the `.pkg` that is uploaded. Apple
   has renamed this one more than once (older keychains show
   `3rd Party Mac Developer Installer`), so confirm the current label in the
   portal rather than trusting any string written down here.

Create them at
[Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list),
then re-run `security find-identity -v -p codesigning` and confirm both appear.

### App ID — done

`org.ceesaxp.Writ` is registered as an explicit App ID with the **App Sandbox**
capability, and the App Store Connect record is created against it. Writ is a
single target with no extensions, so one App ID is enough.

**Why this ID and not `org.ceesaxp.writ.app`.** Gridka uses the `.app` suffix
(`org.ceesaxp.gridka.app`) for every channel, and the first App Store Connect
record for Writ was created the same way. It was deleted and recreated as
`org.ceesaxp.Writ` instead, because Writ has already shipped under that ID
since 0.4.x and it is a *sandboxed* app: all of its user data lives in
`~/Library/Containers/org.ceesaxp.Writ/`. Changing `CFBundleIdentifier` would
orphan that container for every existing user — preferences reset, the
app-scope bookmark behind the custom-CSS setting revoked — in exchange for
nothing. Gridka needed the suffix because it namespaces a Quick Look
extension; Writ has no extension to namespace.

The rule this leaves behind: **`CFBundleIdentifier` in `project.yml` is load
bearing for user data, not just for signing.** Do not change it.

### Entitlements

Already in place, in `project.yml` under the `Writ` target, and no change is
needed for the App Store:

| Entitlement | Why |
| --- | --- |
| `com.apple.security.app-sandbox` | Mandatory on the App Store. Already on. |
| `com.apple.security.files.user-selected.read-write` | Open and save documents the user picked. |
| `com.apple.security.files.bookmarks.app-scope` | Re-open a user-chosen file across launches without re-prompting. Used by the custom preview CSS setting (`PreviewTheme.swift` stores a `.withSecurityScope` bookmark). |
| `com.apple.security.network.client` | **Not** for fetching content — see §5. WebKit's content process will not initialise without it, even for `file://` loads from inside the bundle. |

### Privacy manifest

`App/Resources/PrivacyInfo.xcprivacy` ships in the bundle at
`Contents/Resources/PrivacyInfo.xcprivacy`, wired in through `project.yml`'s
resources build phase. Apple's required-reason API rules are documented most
firmly for the iOS family, so how hard macOS enforcement bites is less
certain — but an upload *can* be rejected for an undeclared one, and Gridka
both ships a manifest and keeps a "Missing privacy manifest" troubleshooting
entry, which settles it in practice.

What Writ declares, and why:

| Category | Reasons | Justified by |
| --- | --- | --- |
| `UserDefaults` | `CA92.1` | The app's own defaults only: editor font and line height, preview theme, split positions, the PlantUML endpoint. |
| `FileTimestamp` | `C617.1`, `3B52.1` | `C617.1` — the folder browser displays a relative "modified" column (`FolderNode.swift`, `FolderWindowController.swift`). `3B52.1` — `WritDocument` compares the on-disk modification date to notice a file changed underneath the editor, and that file is always one the user opened themselves. |

Deliberately **not** declared, because Writ never calls them: `DiskSpace`,
`SystemBootTime`, `ActiveKeyboards`. Gridka's manifest declares `DiskSpace`
(`E174.1`) and omits `UserDefaults` entirely, so it is wrong for Writ in both
directions — do not copy it.

**How the `FileTimestamp` entry was nearly missed.** A first pass concluded
Writ touched no timestamp APIs, on the strength of this:

```sh
grep -rlE 'contentModificationDate\|modificationDate' --include='*.swift' App/Sources
```

That matches zero files — not because there are none, but because `-E` reads
`\|` as an *escaped literal pipe*, so the pattern searched for the single
string `contentModificationDate|modificationDate`. With real alternation the
same command finds 15 hits across two files. A grep that returns nothing is
evidence only once you have seen it return something.

### Tools

- Active Apple Developer Program membership.
- Xcode 26.3 or newer, with command-line tools installed.
- **Not a beta Xcode.** `xcode-select -p` on this machine currently points at
  `/Applications/Xcode-beta.app` (Xcode 27.0, build `27A5228h`). Apple rejects
  App Store uploads built against a beta SDK. Point `xcode-select` at a release
  Xcode before archiving, and check with `xcodebuild -version`.
- XcodeGen (`brew install xcodegen`) — `Writ.xcodeproj` is generated, not
  committed as the source of truth.

## 2. Two distribution channels, one codebase

The App Store is an *addition*, not a replacement. The existing channel keeps
working and keeps its audience: users who want a direct download, and anyone
installing with `brew`. Both channels build from the same sources and the same
`project.yml`.

| | Developer ID channel | App Store channel |
| --- | --- | --- |
| Driver | `Scripts/make-release.sh` | `Scripts/appstore-release.sh`, or Xcode Organizer |
| Signing identity | Developer ID Application | Apple Distribution (+ installer cert) |
| Export options | `Scripts/ExportOptions-DeveloperID.plist`, `method` = `developer-id` | `Scripts/ExportOptions-AppStore.plist`, `method` = `app-store-connect` |
| Gatekeeper step | `xcrun notarytool` + `stapler`, keychain profile `writ-notary` | none — the App Store reviews and signs |
| Artifact | signed, notarized `Writ-<version>.dmg` | `.pkg` uploaded to App Store Connect |
| Downstream | Homebrew cask in `ceesaxp/homebrew-tap`, mini-site CTA | App Store listing |

The two export-options plists must stay separate. `method` is the field that
decides which certificate the export step looks for, so one plist cannot serve
both. Both `app-store-connect` and the legacy alias `app-store` are present in
Xcode 27's `IDEDistribution` framework; prefer `app-store-connect`.

Do not retire `make-release.sh`. The sandbox is the one place the two builds can
diverge in behaviour, and the Developer ID build stays the quickest way to check
whether a bug is sandbox-related.

## 3. App Store Connect metadata

### Create the app record

1. [App Store Connect](https://appstoreconnect.apple.com) → Apps → "+" → New App.
2. Platform: **macOS**. Name: **Writ**. Primary language: **English (U.S.)**.
3. Bundle ID: `org.ceesaxp.Writ` (available only once §1's App ID exists).
4. SKU: `writ-macos`, or whatever the owner prefers — it is internal and never
   shown to users.

### App information

| Field | Value |
| --- | --- |
| Primary category | Productivity |
| Secondary category | Developer Tools (optional) |
| Age rating | 4+ |
| Copyright | © 2026 Andrei Popov (matches `NSHumanReadableCopyright`) |
| Support URL | https://ceesaxp.github.io/writ/ |
| Marketing URL | https://ceesaxp.github.io/writ/ (optional) |
| Privacy Policy URL | https://ceesaxp.github.io/writ/privacy.html (required) |

The privacy page already exists on the mini-site, so the required URL needs no
new work.

### Description — DRAFT, needs the owner's edit

> **The text below is a draft assembled from the feature list in `README.md`.
> It is not approved copy. Read it as a starting point and rewrite it in your
> own voice before pasting it into App Store Connect.**

> Writ is a native Markdown editor for technical writing on macOS.
>
> Plain text goes in; a publication-quality technical preview comes out.
> Markdown stays the canonical format — your files are your files, on your
> disk, readable by every other tool you own.
>
> Features:
>
> - A native AppKit editor. No Electron, no browser engine driving the typing
>   surface, no cloud account.
> - Live preview beside the source, with two-way scroll sync. Source-only,
>   preview-only and split views.
> - Math with KaTeX, and MathJax as a switchable alternate for documents that
>   need its macros.
> - Mermaid diagrams and syntax-highlighted code fences, rendered from
>   libraries bundled in the app.
> - Block (rectangular) selection for column edits across many lines at once.
> - Export to PDF and to self-contained HTML, with math and diagrams intact.
> - Open a folder and filter-as-you-type to jump between files; outline
>   navigation within a document.
> - Four preview themes, plus your own CSS.
> - Per-document front-matter pragmas to switch rendering behaviour where the
>   defaults misfire.
>
> Everything renders offline. Writ collects no analytics and no personal data.

### Keywords — DRAFT, needs the owner's edit

The keyword field is capped at **100 characters** including commas and spaces.
The line below is 79, leaving room for two or three more terms:

```
markdown,editor,latex,math,mermaid,diagram,preview,writing,technical,pdf,export
```

Do not repeat the app name or the category in keywords — Apple indexes those
separately, and the space is better spent on terms a user would actually type.

## 4. Screenshots

### Required sizes

Apple's Mac screenshot sizes are 16:10 only. The size Gridka's tooling is
actually built to produce, and therefore the one known to work, is
**2880 × 1800** — a 1440 × 900 pt capture region on a 2× Retina display
(`lib.sh` derives it as a 1280 × 740 pt window plus 80 pt of padding on each
side). Confirm the current full list of accepted sizes in App Store Connect
Help before capturing; do not copy Gridka's table, which lists one 16:9 size
that Apple does not accept for Mac.

Between one and ten screenshots are allowed. Three to five is a sensible target.

### Suggested shots for Writ

1. **Split view, technical document** — source on the left, preview on the
   right, with math and a Mermaid diagram both rendered. This single shot
   carries the product's whole claim.
2. **Block selection mid-edit** — a rectangle selected across a dozen lines,
   showing a column edit in progress. The most distinctive editor feature.
3. **Folder window** (⇧⌘O) — the sidebar file list with the filter field
   narrowing a directory of documents.
4. **Preview themes** — the same document under a different theme, showing
   that typography is configurable.
5. **Diagnostics ribbon** — the preview ribbon reporting a diagram error, to
   show that render failures are inline rather than modal.

### Tooling

Gridka has a working, non-interactive capture harness worth adapting rather
than rebuilding:

- `/Users/andrei/Code/Swift/Gridka/scripts/screenshots/take-screenshots.sh` —
  per-state capture with `--state`, `--output` and `--interactive` flags.
- `/Users/andrei/Code/Swift/Gridka/scripts/screenshots/lib.sh` — the reusable
  half: `launch_app`, `set_window_geometry`, `send_keystroke`, `open_file`,
  `capture_with_padding` and `capture_window_only`, all driving AppleScript and
  `screencapture -R`.

Adapting it means replacing the per-state `capture_*` functions with Writ's
states and swapping the generated fixtures for Markdown ones — the sample
documents under `samples/` are a starting point. `lib.sh` needs no changes.

It requires Accessibility and Screen Recording permission for the terminal
app, and a clean desktop wallpaper.

## 5. Review notes

Paste something close to this into the review-notes field. Every claim in it is
checkable in the repository, which matters: a reviewer who sees the
`com.apple.security.network.client` entitlement will reasonably ask what Writ
does with the network.

> Writ is a Markdown editor. To test: launch it and type Markdown into the
> editor, or open any `.md` file. ⌥⌘3 shows the editor and preview side by
> side.
>
> **Rendering is entirely local.** Markdown, math (KaTeX, with MathJax as an
> alternate), Mermaid diagrams and syntax highlighting are all rendered by
> JavaScript libraries bundled inside the app, under
> `Writ.app/Contents/Resources/preview/vendor/`. The preview is a `WKWebView`
> loading a `file://` shell from the app bundle; that shell references no
> remote URL of any kind. Nothing is downloaded or executed from the network
> to render a document.
>
> **The `com.apple.security.network.client` entitlement is required by
> WebKit, not by a feature.** WebKit's content process does not initialise
> without it, even for a `file://` load from inside the app bundle; without
> the entitlement the preview stays blank at `about:blank`.
>
> **One feature can make an outbound request, and it is doubly opt-in.**
> PlantUML diagram rendering requires *both* that the document carries a
> `plantuml: true` front-matter pragma *and* that the user has entered a
> PlantUML or Kroki server endpoint in Settings. No endpoint ships with the
> app and no PlantUML engine is bundled. With no endpoint configured, a
> `plantuml` fence is displayed as source and nothing leaves the machine.
> Responses pass through the app's HTML sanitiser before reaching the
> preview. Export never triggers a request.
>
> Writ collects no analytics, no telemetry and no user data. It requires no
> account. Documents are plain files the user opens and saves through the
> standard sandbox-mediated panels.

No demo account is needed. If the reviewer wants a document that exercises
math and diagrams, point them at a file in `samples/`.

## 6. Version and build numbers

**The first App Store release is 0.7.0**, the same number the PlantUML work
ships under through the Developer ID channel. One binary carries one version:
an App Store listing at `1.0.0` while the Homebrew cask and the mini-site say
`0.7.0` is a permanent support tax every time someone reports a bug against a
version number that only exists on one channel.

**Outstanding:** App Store Connect defaults a new app record's first version to
`1.0.0`, so the record's version has to be set to `0.7.0` by hand. Do it while
the version is still in *Prepare for Submission* with no build attached, where
the field is editable — and before uploading, because a build whose
`CFBundleShortVersionString` is `0.7.0` cannot be attached to a `1.0.0`
version record.

Current state in `project.yml` — still pre-release, bumped on the
`release/0.7.0` branch:

| Setting | Value | At release |
| --- | --- | --- |
| `MARKETING_VERSION` | `0.6.0` | `0.7.0` |
| `CURRENT_PROJECT_VERSION` | `33` | `34` |

Two rules, both learned the hard way on Gridka:

**Build numbers must strictly increase, across the whole version train, and
across rejected uploads too.** A build number that reached App Store Connect is
spent even if that upload was rejected or never submitted. Gridka commit
`045faff` is a bump made for exactly this reason, and `567d167` skips build 8
outright because an earlier bump had been reverted without a note and it was no
longer certain whether that number had reached Apple. Its commit message is the
rule in one line: *"Build numbers are free; a rejected upload is not."* When in
doubt, skip ahead.

**Run `xcodegen generate` before archiving.** `Writ.xcodeproj` is generated
from `project.yml`; a stale `.xcodeproj` carries whatever version it was
generated with, and App Store Connect rejects the upload with **"train version
<N> is closed"** — it has already seen that version and will not accept
another build of it. That is not a hypothetical: Gridka commit `f8e3203` fixes
precisely this, where a stale project uploaded version 1.2.1 long after that
train had closed. `Scripts/make-release.sh` already runs `xcodegen generate`
as its first step; the App Store path must do the same.

The error is confusing because the version in `project.yml` is correct — only
the generated project is wrong. So check the *generated project*, not
`project.yml` and not a previously exported app:

```sh
xcodegen generate
xcodebuild -project Writ.xcodeproj -scheme Writ -configuration Release \
  -showBuildSettings | grep -E ' MARKETING_VERSION =| CURRENT_PROJECT_VERSION ='
```

Run against the current tree this prints `CURRENT_PROJECT_VERSION = 33` and
`MARKETING_VERSION = 0.6.0`. If those two numbers are not what you intend to
ship, stop — archiving now is what produces the closed-train rejection.

## 7. Build, archive, and upload

An App Store export needs its own options plist, and it exists:
`Scripts/ExportOptions-AppStore.plist`, beside the Developer ID one — same
`teamID` and `signingStyle`, `method` set to `app-store-connect`. This is
exactly the plist Gridka's `scripts/build-release.sh` writes for itself, which
also sets a `destination` key:

- `destination` = `export` (the default) leaves a local `.pkg` you can validate
  before spending a build number. Recommended for the first submission.
- `destination` = `upload` makes `-exportArchive` upload directly, with no
  local `.pkg` to inspect. Gridka's generated plist uses this.

### Option A — Xcode Organizer

Lowest-risk route for the first submission, because Xcode resolves the
provisioning profile itself and reports signing problems in a readable form.

1. `xcodegen generate`
2. Open `Writ.xcodeproj`, select the **Writ** scheme, destination **My Mac**.
3. Product → Archive.
4. In Organizer: Distribute App → App Store Connect.

### Option B — `Scripts/appstore-release.sh`

The whole sequence, wrapped:

```sh
./Scripts/appstore-release.sh             # archive + export a local .pkg
./Scripts/appstore-release.sh --validate  # also validate it against Apple
./Scripts/appstore-release.sh --upload    # also upload to App Store Connect
```

It runs `xcodegen generate` first (§6 explains why that is not optional), then
archives to `build/Writ-AppStore.xcarchive` and exports to
`build/Writ-AppStore-export`. Those paths are deliberately disjoint from
`make-release.sh`'s, and the script removes only its own two directories —
a blanket `rm -rf build` would destroy the Developer ID channel's archive,
export and signed DMG.

**Validate before uploading.** Validation catches the whole class of metadata
and entitlement errors without spending a build number, and build numbers are
the one resource here you cannot get back.

The script deliberately does **not** pass `-allowProvisioningUpdates`, so it
cannot create certificates in the portal as a side effect of a release. That
also means it will not bootstrap signing for you — see §1.

`altool` is still present and functional in the current toolchain
(`xcrun altool --version` reports 27.0.5), and is what Gridka's release script
calls for both steps. It is, however, the deprecated path: Apple now steers
submission through Transporter or `-exportArchive` with `destination` set to
`upload`. Fine for a first submission, worth revisiting if a future Xcode drops
it — the switch is contained to this one script.

An API key for the non-interactive calls comes from
[Users and Access → Integrations → Keys](https://appstoreconnect.apple.com/access/api).
One gotcha worth copying from Gridka's script: `altool` does not take a path to
the `.p8` key file. It searches `~/private_keys`, `~/.private_keys` and
`~/.appstoreconnect/private_keys` for `AuthKey_<ID>.p8`, so the downloaded key
has to be copied into one of those directories before `--apiKey` will resolve.

### Before submitting

Run the sandboxed App Store build locally first, from `/Applications`, and walk
the preview smoke checklist in `samples/preview-smoke/CHECKLIST.md`. The
Developer ID build already runs sandboxed, so large behavioural surprises are
unlikely, but the preview and the export paths are where a sandbox difference
would show up first.

## 8. Troubleshooting

### "train version <N> is closed"

The generated project is stale. See §6 — `xcodegen generate`, then confirm the
version in the built `Info.plist` before archiving again.

### "The bundle version must be higher than the previously uploaded version"

`CURRENT_PROJECT_VERSION` is at or below a number App Store Connect has already
seen. Bump it past the highest number ever uploaded, not merely past the last
one you remember submitting.

### "Invalid toolchain" / beta SDK rejection

Built with a beta Xcode. `xcode-select -p` on this machine points at
`/Applications/Xcode-beta.app`; switch it to a release Xcode and rebuild
(§1).

### "Missing privacy manifest" / undeclared required-reason API

`PrivacyInfo.xcprivacy` does not exist yet. See §1 — it needs the
`FileTimestamp` (`C617.1`) and `UserDefaults` (`CA92.1`) declarations, and
`project.yml` must list it as a resource. Gridka hit this and keeps the same
entry in its own troubleshooting list.

### Code signing errors on export

1. Confirm both distribution certificates from §1 are in the login keychain:
   `security find-identity -v -p codesigning`.
2. Confirm the App ID `org.ceesaxp.Writ` is registered with App Sandbox
   enabled, and that its bundle ID matches `project.yml` exactly.
3. Refresh certificates in Xcode → Settings → Accounts → Download Manual
   Profiles.
4. Check that the export plist names `method` `app-store-connect`, not
   `developer-id`.

### Preview is blank in the App Store build

Almost certainly the `com.apple.security.network.client` entitlement went
missing. WebKit's content process needs it even for `file://` loads from the
bundle; without it the webview never leaves `about:blank` and no
`didFinish`/`didFail` callback arrives. Verify what actually shipped:

```sh
codesign -d --entitlements - build/Writ-appstore/Writ.app
```

### "The app references non-public selectors"

Validate before uploading and read the detail — `altool --validate-app` names
the symbol. Writ uses no private API deliberately, so track the named symbol
back to the code that references it rather than assuming either way.

### Sandbox denials while testing

Check Console.app for sandbox denial messages. For Writ the likely candidates
are the `writ-doc://` scheme handler resolving an image path outside the
document's directory, and the app-scope bookmark for a folder opened with
⇧⌘O going stale.

## Open questions for the owner

1. **A release Xcode has to be installed.** The only Xcode on the build machine
   is `/Applications/Xcode-beta.app` (27.0, `27A5228h`), and Apple rejects App
   Store uploads built against a beta SDK. This blocks the App Store channel
   outright — the Developer ID channel is unaffected, so 0.7.0 can ship to
   Homebrew before this is resolved. See §1 *Tools* and §8.
2. **Does the App Store listing change the mini-site?** The hero CTA currently
   points at the DMG. Two channels means deciding whether the App Store badge
   leads, follows, or sits beside it.
3. **Price.** Free, paid, or free with no in-app purchase. This has to be set
   before the listing can be submitted, and it interacts with whether the
   Homebrew cask stays the recommended install route.
