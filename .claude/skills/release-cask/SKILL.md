---
name: release-cask
description: Cut a lil-ccgw release and update its Homebrew cask — build universal, assemble the app, zip, sha256, GitHub release, verify the install in a clean room, then bump version and sha in the tap. Use when releasing a new version or when the cask is out of date.
argument-hint: "<version>  e.g. 0.3.0"
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
scripts/test.sh                     # must pass
scripts/build.sh --universal        # must succeed
```

`--universal` now exits non-zero if the x86_64 slice cannot be built, so a
single-arch bundle can no longer reach a release by way of a warning nobody
read. **Never pass `--allow-single-arch` here** — that flag exists for local
builds, and an arm64-only release installs cleanly on an Intel Mac and then
cannot exec at all.

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

This is the first irreversible, outward-facing step: a pushed tag and a
published release are visible immediately and awkward to retract. **Confirm
before running it**, per CLAUDE.md's rule about outward-facing actions, even
though ordinary commits and pushes in this repo need no permission.

```sh
git push origin main --tags
gh release create "v$ARGUMENTS" \
  "dist/lil-ccgw-$ARGUMENTS.zip" \
  --title "lil-ccgw $ARGUMENTS" \
  --notes "..."
```

## 5. Tap

The tap is `AndrewHYi/homebrew-tap` (repo name `homebrew-tap`, referenced as
`AndrewHYi/tap`). It already exists and is public. It is tapped locally, so the
live cask is readable on disk — **edit that, do not retype it from memory:**

```sh
cat /opt/homebrew/Library/Taps/andrewhyi/homebrew-tap/Casks/lil-ccgw.rb
```

A release changes exactly two lines, `version` and `sha256`. Everything else —
the `depends_on`, the `postflight` that strips `com.apple.quarantine`, the `zap`
list — is already correct and should be left alone. This file used to inline a
full copy of the cask, which promptly drifted from the real one in three ways at
once (a stale version, a `">= :sonoma"` that the tap had already corrected to a
bare symbol, and a claim the tap did not exist). Pointing at the source of truth
is the fix.

Then commit and push the tap. That is a second repo and an outward-facing
publish — see the note in step 4.

Reference implementation for cask patterns, on disk if AeroSpace is installed:

```sh
cat /opt/homebrew/Library/Taps/nikitabobko/homebrew-tap/Casks/aerospace.rb
```

## 6. Verify the install path

```sh
scripts/verify-cask.sh --zap
```

This builds, packages, installs, launches, uninstalls and zaps the cask inside a
throwaway Homebrew prefix with its own Caskroom and `--appdir`, then asserts the
real `/Applications` bundle and Caskroom were untouched. It replaces the old
untap/tap/install-into-your-own-machine round trip, which mutated the machine
being released from and checked the result by eye.

It asserts what that checklist only looked at: both architectures survive into
the *installed* binary, the signature survives the `ditto` round trip, no
`com.apple.quarantine` remains, the version matches, the app actually launches,
and the zap stanza removes the plist it names.

Note it does **not** use `spctl --assess`. An ad-hoc signed app always fails
that. Gatekeeper only enforces on quarantined files, so the absence of the
quarantine attribute is the assertion that means anything here.

Run it against the tag you are about to ship, before touching the tap. If the
sha256 it prints differs from the one you put in the cask, the cask is wrong.

## Checklist

- [ ] Repo/releases public (or explicitly decided otherwise, and stopped here)
- [ ] Working tree clean, `scripts/test.sh` green
- [ ] Tagged **before** building the shipped artifact
- [ ] Version in `Info.plist` matches the tag
- [ ] Zipped with `ditto`, not `zip`
- [ ] `scripts/verify-cask.sh --zap` passes
- [ ] sha256 in the cask matches the one `verify-cask.sh` printed
- [ ] Only `version` and `sha256` changed in the tap
- [ ] Confirmed before pushing the tag, the release, and the tap

Most of what this list used to check by hand is now asserted by
`verify-cask.sh`. What is left is the part a script cannot do: deciding to
publish, and keeping the two repos in step.

## After the release

`brew upgrade --cask AndrewHYi/tap/lil-ccgw` on the release machine, so the
installed app is the one that was just shipped rather than a stale build. The
menu bar item has to be quit and relaunched to pick it up.
