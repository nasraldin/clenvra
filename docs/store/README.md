# Publishing Clenvra

Clenvra ships as a signed, notarized download, not through the Mac App Store. The App Store requires the App Sandbox
and does not allow root helpers (App Review Guidelines 2.4.5); in a sandbox, uninstalling system files, startup and
extension changes, permissions, developer tool cleanup and Recent Items could not work.

## What is here

| File | What it is | How to remake it |
|---|---|---|
| `listing.md` | Name, subtitle, promotional text, keywords, description and release notes, in English and Arabic (Modern Standard Arabic), within Mac App Store limits | Edit by hand; every claim must match a shipped feature |
| `screenshots/en`, `screenshots/ar` | Eight 2880×1800 images with captions, dark mode | `scripts/store-screenshots.sh` (a throwaway VM with sample files; about 25 minutes) |

## Release steps

1. `scripts/release.sh` builds, signs, notarizes and staples `.build/release/Clenvra-<version>.dmg`.
2. Check it: `xcrun stapler validate` and `spctl -a -t open --context context:primary-signature -v` on the DMG.
3. Tag the release on `main`: `git tag v1.0.0 && git push origin v1.0.0`.
4. Publish the DMG where people can download it. The GitHub repository is private, so a GitHub Release there is not
   public. Choose one: make the repository public, use a separate public releases repository, or host the DMG on a
   website. Use `listing.md` for the release page and the screenshots for the page.
5. Optional, once the download link is public: a Homebrew cask (`brew install --cask clenvra`) pointing at it.

Publishing is public and cannot be taken back: the owner decides when.
