---
name: release-cask
description: Cut a lil-ccgw release and update its Homebrew cask — build universal, assemble the app, zip, sha256, GitHub release, then bump version and sha in the tap. Use when releasing a new version or when the cask is out of date.
argument-hint: "<version>  e.g. 0.2.0"
---

# Release and publish the cask

Version to release: **$ARGUMENTS** (semver, no `v` prefix).

## Before anything: the publish precondition

`brew install --cask` **cannot work from a private repo.** Homebrew fetches
release assets anonymously, so both the tap and the release assets must be
public. Check first:

```sh
gh repo view AndrewHYi/lil-ccgw --json visibility
```

If it reports `PRIVATE`, **stop and ask.** Do not make a repo public on your own
initiative — that is a publishing decision. Local install
(`scripts/build.sh --release && cp -r dist/lil-ccgw.app /Applications/`) works
fine while private, and is the right answer until that decision is made.

## 1. Preflight

```sh
git -C . status --porcelain          # must be clean
scripts/build.sh --universal        # must succeed
```

Confirm the built binary is genuinely universal — the build script warns and
falls back to a single slice if the x86_64 cross-compile fails, and shipping a
single-arch binary as universal is a silent regression:

```sh
lipo -archs dist/lil-ccgw.app/Contents/MacOS/lil-ccgw   # expect: x86_64 arm64
```

Launch it once and confirm the menu bar item appears and the panel reads live
numbers.

## 2. Tag

The build script derives `CFBundleShortVersionString` from `git describe`, so
**tag before building the artifact you ship**:

```sh
git tag -a "v$ARGUMENTS" -m "lil-ccgw $ARGUMENTS"
scripts/build.sh --universal        # rebuild so the plist carries the version
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  dist/lil-ccgw.app/Contents/Info.plist   # verify it matches
```

## 3. Package

Use `ditto`, not `zip` — `ditto -c -k --keepParent` preserves the bundle's
resource forks and symlinks, which a plain `zip` corrupts:

```sh
cd dist
ditto -c -k --keepParent lil-ccgw.app "lil-ccgw-$ARGUMENTS.zip"
shasum -a 256 "lil-ccgw-$ARGUMENTS.zip"
```

Record that sha256 — the cask needs it.

## 4. GitHub release

```sh
git push origin main --tags
gh release create "v$ARGUMENTS" \
  "dist/lil-ccgw-$ARGUMENTS.zip" \
  --title "lil-ccgw $ARGUMENTS" \
  --notes "..."
```

## 5. Tap

The tap is `AndrewHYi/homebrew-tap` (repo name `homebrew-tap`, referenced as
`AndrewHYi/tap`). **It does not exist yet** — create it once:

```sh
gh repo create AndrewHYi/homebrew-tap --public \
  --description "Homebrew tap for AndrewHYi's tools"
```

`Casks/lil-ccgw.rb`:

```ruby
cask "lil-ccgw" do
  version "0.2.0"
  sha256 "<sha256 from step 3>"

  url "https://github.com/AndrewHYi/lil-ccgw/releases/download/v#{version}/lil-ccgw-#{version}.zip"
  name "lil-ccgw"
  desc "Menu bar app for the ccgw Claude Code cost gateway"
  homepage "https://github.com/AndrewHYi/lil-ccgw"

  depends_on macos: ">= :sonoma" # macOS 14

  app "lil-ccgw.app"

  # The app is ad-hoc signed — there is no Developer ID on the build machine, so
  # notarization is impossible and Gatekeeper would otherwise refuse to launch
  # it. Stripping the quarantine attribute is the same posture AeroSpace takes.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/lil-ccgw.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/com.andrewhyi.lil-ccgw.plist",
  ]
end
```

Reference implementation to copy patterns from — already on disk if AeroSpace is
installed:

```sh
cat /opt/homebrew/Library/Taps/nikitabobko/homebrew-tap/Casks/aerospace.rb
```

## 6. Verify the install path

```sh
brew untap AndrewHYi/tap 2>/dev/null
brew tap AndrewHYi/tap
brew install --cask AndrewHYi/tap/lil-ccgw
open /Applications/lil-ccgw.app          # must launch with no Gatekeeper prompt
brew uninstall --cask lil-ccgw           # must remove cleanly
```

If Gatekeeper still complains, the `postflight` `xattr` did not run — check the
path in the cask matches the actual `.app` name inside the zip.

## Checklist

- [ ] Repo/releases public (or explicitly decided otherwise, and stopped here)
- [ ] Working tree clean
- [ ] Tagged **before** building the shipped artifact
- [ ] `lipo -archs` shows both arches
- [ ] Version in `Info.plist` matches the tag
- [ ] Zipped with `ditto`, not `zip`
- [ ] sha256 in the cask matches the uploaded asset
- [ ] `brew install --cask` launches without a Gatekeeper prompt
- [ ] `brew uninstall --cask` removes it
