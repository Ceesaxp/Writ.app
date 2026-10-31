# Release Checklist

Worked through in order. Nothing here is optional; the steps that look
skippable are the ones that have bitten us.

## Before tagging

1. Version numbers
   - `project.yml` marketing version
   - `CHANGELOG.md` has a dated section, not "Unreleased"
2. Tests
   - Unit suite green on the `Writ` scheme
   - The app target itself compiles — a green test target does not prove it
3. Performance gate
   - 4,000-line fixture parses under 10 ms
   - Cold-launch preview is not blank on first run

## Signing and notarisation

| Step | Command | Gate |
| --- | --- | --- |
| Archive | `make-release.sh` | Exit 0 |
| Notarise | `make-release.sh --notarize` | `Accepted` |
| Staple | `stapler staple` | `The validate action worked` |
| Verify | `spctl -a -vvv` | `source=Notarized Developer ID` |

## After the tag

- Upload the notarised DMG to the GitHub release
- Bump the hero call-to-action on the mini-site
- Update the cask
- Post the changelog entry

> Run the app from `/Applications`, never from the mounted DMG. A WebKit
> crash with a `/Volumes/...` process path is the launch location, not a bug
> in the preview.
