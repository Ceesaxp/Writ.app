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
- Xcode 26.3 or newer, with command-line tools installed. Currently
  **Xcode 27.2 (`27B52`)** at `/Applications/Xcode.app`.
- **Never a beta Xcode.** Apple rejects App Store uploads built against a beta
  SDK. This was a real blocker here until 2026-10-30, when the only Xcode
  installed was `/Applications/Xcode-beta.app` (27.0, `27A5228h`) — a seed
  build, recognisable by the five-digit-plus-letter suffix. Check before
  archiving: `xcode-select -p` should not say `Xcode-beta`, and
  `xcodebuild -version` should not report a seed build number. Note that an
  Xcode Cloud workflow has its own Xcode selection, so setting it correctly
  locally does not set it there (§7 Option C).
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

### Option C — Xcode Cloud (recommended)

**Why this is the preferred route:** Xcode Cloud signs in the cloud, so it
needs neither an Apple Distribution certificate, nor a Mac Installer
Distribution certificate, nor a provisioning profile on the local machine. That
is the entire §1 *Certificates* blocker, gone. It also archives from a clean
clone, which is the only way to be sure the thing you upload is what is in git.

Four repository prerequisites, all in place. Each of the first three was
discovered by Xcode Cloud failing on it, in this order — the sequence is worth
keeping, because each failure looks nothing like the next:

| | | |
| --- | --- | --- |
| `Writ.xcodeproj` **committed** | **required** | Xcode Cloud validates the repository before accepting a workflow and refuses one whose project is not at the root: `Project Writ.xcodeproj does not exist at the root of the repository`, exit 66. |
| `ci_scripts/ci_post_clone.sh` | **required** | Regenerates the committed project from `project.yml` on every cloud build, so the committed copy cannot go stale. Also installs XcodeGen. |
| `Package.resolved` **committed** | **required** | Xcode Cloud runs with automatic dependency resolution **disabled**, and fails with `a resolved file is required when automatic dependency resolution is disabled` unless `Writ.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` is in the repository. It pins `swift-markdown` and `swift-cmark`. |
| Shared schemes in `project.yml` | insurance | XcodeGen emitted no scheme before; `xcodebuild` and Xcode each autocreated one per target into `xcuserdata/`, which never reaches a clone. Gridka's builds do work without one, but Gridka commits its project, so it is not evidence for Writ's case. Declaring them also pins the archive action to `Release`. |

Two of these are files that nothing in a local workflow needs — local builds
resolve packages automatically and generate the project on demand. That makes
them precisely the kind of thing a future tidy-up removes as dead weight, with
the breakage appearing only in Xcode Cloud. CI therefore asserts both are still
tracked, and the post-clone hook re-checks the resolved file after generating,
since `xcodegen generate` rewrites the directory it lives in.

**`Package.resolved` is the only one of the four whose contents matter.** After
changing a package dependency, resolve in Xcode and commit the updated file, or
cloud builds keep resolving against the old revisions.

**The first two are not alternatives, and this is the one thing most worth
understanding here.** The obvious design is to keep the generated project out
of version control and let the post-clone hook produce it — that was the
original arrangement, and Xcode Cloud rejects it outright, because its
repository check runs before any hook. The equally obvious opposite is to
commit the project and skip the hook, which is what Gridka did; the committed
project then went stale and uploaded version 1.2.1 after that train had closed
(`f8e3203`). Writ does both: the committed project satisfies the check, and the
hook makes its contents irrelevant. `project.yml` stays the only source of
truth.

**Do not try to verify that the committed project matches a fresh
`xcodegen generate`.** It was tried, in this very branch, and reverted the same
day. It fails for two independent reasons. First, `objectVersion` and
`preferredProjectObjectVersion` are derived from the *installed Xcode*, so a
laptop on 27.2 and a CI runner on 26.6 generate different bytes from identical
input — byte-equality is unattainable, not merely awkward. Second, it guards
nothing: every build path runs `xcodegen generate` first, so no build ever
reads the committed project's contents. The only property worth asserting is
that the file is still tracked, which CI does, because a file nothing appears
to need is exactly what a later tidy-up deletes — and the breakage would
surface in Xcode Cloud rather than in CI.

A consequence worth stating plainly, because it is a trap with no error
message: **never edit the project in Xcode.** A change in the General tab is
discarded by the next `xcodegen generate` — silently, and that generate runs at
the start of every release script and every cloud build. Change `project.yml`
instead, regenerate, and commit both.

#### Setting up the workflow

1. `xcodegen generate`, then open `Writ.xcodeproj`.
2. **Product → Xcode Cloud → Create Workflow** (the Report navigator's *Cloud*
   tab reaches the same place). Choose the **Writ** product.
3. **Grant source access.** Xcode asks to connect `Ceesaxp/Writ.app`, which
   installs the Xcode Cloud GitHub app. This needs admin rights on the
   repository, and it is a one-time grant per repo.
4. Xcode proposes a default workflow. Change three parts of it:
   - **Environment** — pick an explicit *release* Xcode (27.2). Do **not**
     leave it on a "Latest Beta" option: Apple rejects App Store uploads built
     against a beta SDK, and the whole point of installing a release Xcode
     locally was to avoid exactly that.
   - **Start Conditions** — delete the default *Branch Changes* condition and
     use **Manual**. A release workflow that fires on every push uploads a
     build per push, and build numbers are spent permanently whether or not the
     upload is ever submitted (§6).
   - **Actions** — one **Archive** action. Scheme **Writ**, configuration
     **Release**, and **Deployment Preparation: App Store Connect**. That last
     setting is what makes the archive sign for distribution and upload; an
     Archive action without it produces a build you cannot submit.
     **"Developer ID" is also offered there, and it is not what this workflow
     wants** — it is the DMG channel's output, which `Scripts/make-release.sh`
     already builds and notarizes locally. The two preparations are not
     interchangeable: one signs for the Store, the other for distribution
     outside it.
   - **Post-Actions** — and in particular, do **not** add **Notarize**. It
     looks like something a macOS release ought to have, but notarization
     belongs to the DMG channel and happens locally; asking for it here makes
     Xcode Cloud export a Developer-ID-signed copy, which needs a certificate
     it does not have. See §8.
   - **Post-Actions** — none, for a first submission. The build lands in App
     Store Connect and gets attached to the version by hand, which is one fewer
     moving part while establishing that the pipeline works. TestFlight can come
     later.
5. Save, then **Product → Xcode Cloud → Start Build**.

#### Reading the build log

`ci_post_clone.sh` prints the XcodeGen generation and then the two numbers the
build will carry:

```
MARKETING_VERSION = 0.7.0
CURRENT_PROJECT_VERSION = 34
```

Check those *first*, before anything else in the log. They are deliberately
printed early because this is the last cheap moment to notice a wrong version —
after the upload, that version train is closed in App Store Connect and no
later build of the same number can replace it.

#### The build-number trap

`CURRENT_PROJECT_VERSION` is a static value in `project.yml`, so **two Xcode
Cloud runs of the same commit upload the same build number**, and the second is
rejected. Xcode Cloud exposes an incrementing `$CI_BUILD_NUMBER` that a
`ci_pre_xcodebuild.sh` hook could patch in, but that makes the uploaded build
number disagree with the repository, which is its own kind of confusion.
Gridka chose the other way — bump by hand, commit the bump, and skip numbers
freely when in doubt (`045faff`, `567d167`). Writ follows Gridka here. Bump
`CURRENT_PROJECT_VERSION` before every upload attempt, not every release.

#### What Xcode Cloud does not do

Signing and building only. The App Store Connect version record must already
exist at the matching version number, and the listing's metadata, screenshots,
price and privacy answers are all still manual.

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

### Xcode Cloud: `Export archive for developer-id distribution` fails, exit 70

**A developer-id export step does not mean Deployment Preparation is set to
Developer ID.** That inference was made here and was wrong: the step appeared
on a workflow whose Archive action was set to *App Store Connect*. Xcode Cloud
runs more than one export per archive — a community report shows development,
ad-hoc and app-store exports all running on a workflow whose only post-action
was TestFlight — and for macOS a developer-id export can appear alongside them.
So the step's name identifies which export failed, not what the workflow asked
for.

What most plausibly pulls it in is a **Notarize post-action**. Notarizing
requires a Developer-ID-signed build, so adding it makes Xcode Cloud export one,
and that export fails when the cloud has no Developer ID certificate to sign
with. Writ does not need it: `make-release.sh` notarizes the DMG locally with
the `writ-notary` keychain profile (§2). Remove the Notarize post-action and the
developer-id export has no reason to run. This rests on a single anecdotal
report, so confirm it against the log below rather than assuming it.

**Exit 70 is only a wrapper** — `xcodebuild`'s generic distribution failure. It
carries no diagnostic information at all, and the step's own output carries
none either. The real error is in the artifact the failing command names
itself:

```
-IDEDistributionLogDirectory=/Volumes/workspace/tmp/developer-id-export-archive-logs
```

Download the build's artifacts and read
`developer-id-export-archive-logs/xcodebuild-export-archive.log`. Start there,
before changing any setting — every other step in this entry is guesswork until
that log is read.

Three causes reported for exit 70 at the export step, once the log names one:

| Log says | Reported fix |
| --- | --- |
| no signing certificate found | Revoke the matching **"… Managed (Xcode Cloud)"** certificate in the [portal](https://developer.apple.com/account/resources/certificates/list) and re-run; Xcode Cloud regenerates it. Several people report this as the fix, with no confirmed root cause. |
| a bundle ID could not be registered | Archive once from Xcode and upload it, which creates the identifier, then return to Xcode Cloud. |
| an authentication error on a recent Xcode | One report of export failing on Xcode 26.2 RC and succeeding on 26.1. Pin the workflow's Xcode version — but never to a beta (above). |

Sources: Apple Developer Forums
[816085](https://developer.apple.com/forums/thread/816085) (multiple export
steps, managed signing),
[772909](https://developer.apple.com/forums/thread/772909) (certificate
revocation),
[766079](https://developer.apple.com/forums/thread/766079) (unregistered bundle
ID), [810011](https://developer.apple.com/forums/thread/810011) (Xcode version
regression).

### "Invalid toolchain" / beta SDK rejection

Built with a beta Xcode. Check `xcode-select -p` for an `Xcode-beta` path and
`xcodebuild -version` for a seed build number, switch to a release Xcode and
rebuild (§1). If the build came from Xcode Cloud, the Xcode version is set in
the workflow's *Environment*, not by `xcode-select` — a local fix does not
reach it.

### "Missing privacy manifest" / undeclared required-reason API

`App/Resources/PrivacyInfo.xcprivacy` exists and `project.yml` lists it as a
resource, so the likely cause is that it did not reach the bundle rather than
that it is missing from the repository. Check the archive, not the source
tree:

```sh
ls build/Writ-AppStore.xcarchive/Products/Applications/Writ.app/Contents/Resources/PrivacyInfo.xcprivacy
```

If that path is absent, the resources build phase lost it — most likely a
`project.yml` edit dropped the `App/Resources/PrivacyInfo.xcprivacy` sources
entry, since a stale `Writ.xcodeproj` is impossible here (`xcodegen generate`
runs first in every path). If the file is present, the complaint is about its
*contents*: an API Writ calls without a matching declaration. §1 lists what is
declared and what is deliberately not.

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

## Decisions

- **Price: free**, with no in-app purchase. The Homebrew cask stays as an
  alternative install route rather than the recommended one.
- **The mini-site leads with the App Store.** The hero CTA becomes the App
  Store; the DMG and `brew install --cask writ` move to secondary position. Not
  yet done — it lives in the separate `ceesaxp.github.io` repository, so it is
  its own pull request, and it should not land before the listing is live or the
  CTA points at a page that does not exist.
- **First App Store version: 0.7.0**, matching the Developer ID release of the
  PlantUML work. See §6.
- **Bundle ID stays `org.ceesaxp.Writ`.** See §1 *App ID* for why renaming it
  would have cost every existing user their container.

## Open questions for the owner

1. **Bump `MARKETING_VERSION` to 0.7.0 before any App Store archive.** The App
   Store Connect version record is set to 0.7.0, but `project.yml` still reads
   `0.6.0`, and the generated project reflects `project.yml` — which is why
   Xcode's General tab shows 0.6.0 and will keep showing it until the release
   bump lands. Archiving before then uploads 0.6.0 and closes that train
   permanently (§6).
