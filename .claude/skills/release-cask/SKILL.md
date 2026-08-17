---
name: release-cask
description: Cut a lil-ccgw release and update its Homebrew cask — build universal, verify the install in a clean room, package, publish, then bump version and sha in the tap. Use when releasing a new version or when the cask is out of date.
argument-hint: "<version>  e.g. 0.5.0"
---

# Release and publish the cask

Version to release: **$ARGUMENTS** (semver, no `v` prefix).

## Bind the version and the repo root before running anything

`$ARGUMENTS` is a prompt placeholder, not a shell variable. It is unset in the
shell, so pasting a snippet that mentions it yields a tag literally named `v` and
an asset called `lil-ccgw-.zip` that the cask's URL will never find. Bind both
variables once, in the shell you will run the release from:

```sh
VERSION=X.Y.Z                 # ← replace with the version from $ARGUMENTS

printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
  && ROOT="$(git rev-parse --show-toplevel)" \
  && [ -x "$ROOT/scripts/verify-cask.sh" ] \
  && cd "$ROOT" \
  && echo "releasing $VERSION from $ROOT"
```

`X.Y.Z` is left in deliberately, and the shape check is what catches it. A
plausible-looking default would be worse than an obviously-unset one: paste
`VERSION=0.5.0` and every downstream check — tag, `Info.plist`, asset name, cask
— agrees with the others and is wrong together, with nothing to contradict it. A
bare `${VERSION:?}` would not help, since `X.Y.Z` is set.

`grep -qE` rather than `[[ =~ ]]`, because the two shells disagree. zsh strips the
backslash from an unquoted right-hand side, so `^[0-9]+\.[0-9]+\.[0-9]+$` compiles
as `^[0-9]+.[0-9]+.[0-9]+$` — where `.` matches anything, and `1a2b3` and `0_5_0`
sail through. Quoting the RHS is not the fix either: that flips bash to a literal
string comparison. Verified in both shells.

`[ -x "$ROOT/scripts/verify-cask.sh" ]` is the check that you are in *this* repo.
`git rev-parse` answers about whatever directory you happen to be in, and step 7
leaves you inside the tap — which is also a git repo, also on `main`, and would
otherwise bind `ROOT` to itself and print a confident success line.

**Every later step re-checks both variables**, because a release spans enough
elapsed time and enough directories that a new terminal window is normal. The
checks are folded into their command chains with `&&` rather than standing alone:
a failing `${VAR:?}` on its own line aborts only *that* command in an interactive
shell, so the error scrolls past and the next line runs anyway. Verified — pasted
as two lines the guard prints and the command still executes; chained with `&&`
it does not.

**If what you were handed is not a bare `MAJOR.MINOR.PATCH`, stop and resolve it
first.** Derive it from the commit range and bump by the conventional-commit
types present — any `feat:` means minor, only `fix:`/`docs:`/`test:` means patch:

```sh
git log --format=%s "$(git describe --tags --abbrev=0)"..HEAD
```

`git describe --tags --abbrev=0` already emits the `v`; do not add another.

## Before anything: the publish precondition

`brew install --cask` **cannot work from a private repo.** Homebrew fetches
release assets anonymously, so both the tap and the release assets must be
public. Check first:

```sh
gh repo view AndrewHYi/lil-ccgw --json visibility
```

If it reports `PRIVATE`, **stop and ask.** Do not make a repo public on your own
initiative — that is a publishing decision. A local install works fine while
private and is the right answer until that decision is made:

```sh
scripts/build.sh --release
rm -rf /Applications/lil-ccgw.app        # ditto merges; it does not replace
ditto dist/lil-ccgw.app /Applications/lil-ccgw.app
```

## The one rule that governs the ordering

**The cask's sha256 must be the sha256 of the exact file that ends up on the
release — and the only proof of that is downloading it back.**

Everything below is arranged around that. In particular, *verify before you
package*, because `scripts/verify-cask.sh` rebuilds the app underneath you, and
package immediately before uploading, because nothing else may touch `dist/`
in between.

## 1. Preflight

```sh
git status --porcelain              # must be clean
git branch --show-current           # must be main
scripts/test.sh                     # must pass
```

Tag on a side branch and the release points at a commit that is not on the
default branch, which is invisible until someone tries to build it.

## 2. Tag

`scripts/build.sh` derives the version from `git describe --tags --abbrev=0`
(then strips the `v`), so the tag must exist before the artifact is built.
Tagging locally is reversible — `git tag -d "v$VERSION"` — and nothing is
published until step 5.

```sh
PREV="$(git describe --tags --abbrev=0)"   # capture BEFORE tagging — step 5 needs it
git tag -a "v$VERSION" -m "lil-ccgw $VERSION"
git describe --tags --abbrev=0             # must print exactly v$VERSION
```

Capture `PREV` first or you lose the range: once the tag exists, the nearest tag
*is* this release, and `"$(git describe --tags --abbrev=0)"..HEAD` is empty.

**If that prints an older tag, `HEAD` already carried one.** With two tags on one
commit `git describe` breaks the tie by tagger date, newest first — so it usually
prints the new tag and all is well. It returns the *older* only when both tags
carry the same timestamp (tagged back-to-back by a script) or the clock ran
backwards. When that happens `build.sh` embeds the wrong version while every
later check still agrees, so the check above is worth running rather than
assuming. Delete the stale tag (`git tag -d v<old>`); if it is already pushed,
leave it and cut from a new commit instead.

## 3. Verify the install path

```sh
scripts/verify-cask.sh --zap && echo VERIFY_OK
```

**Do not continue unless you saw both `==> cask verified: lil-ccgw <version>` and
`VERIFY_OK`.** The script builds into `dist/` early and can exit non-zero later,
and its cleanup removes only its throwaway prefix — so a bundle sitting in
`dist/` is *not* evidence that verification passed. This is the one place a bad
artifact could otherwise walk straight into step 5.

It builds, packages, installs, launches, uninstalls and zaps the cask inside a
throwaway Homebrew prefix with its own Caskroom and `--appdir`, then asserts the
real `/Applications` bundle and Caskroom were untouched. It replaces the old
untap/tap/install-into-your-own-machine round trip, which mutated the machine
being released from and checked the result by eye.

It asserts what that checklist only looked at: both architectures survive into
the *installed* binary, the signature survives the `ditto` round trip, no
`com.apple.quarantine` remains, the version matches, the app actually launches,
and the zap stanza removes the plist it names.

It runs `scripts/build.sh --universal` itself, so there is no separate build
step. That build exits non-zero if the x86_64 slice cannot be produced. **Never
pass `--allow-single-arch`** anywhere in a release — that flag is for local
builds, and an arm64-only bundle installs cleanly on an Intel Mac and then
cannot exec at all.

Note it does **not** use `spctl --assess`. An ad-hoc signed app always fails
that. Gatekeeper only enforces on quarantined files, so the absence of the
quarantine attribute is the assertion that means anything here.

### Ignore the sha256 it prints

**It will never match the one you ship, and that is correct behaviour, not a
warning sign.** Two independent reasons:

- It packages into a temp room that its own `EXIT` trap deletes. The file that
  sha describes does not exist by the time the script returns.
- It rebuilds the app first, and **`ditto` records mtimes**. The rebuild is
  byte-identical in *content* — every file's digest is unchanged — but every
  mtime is new, so the archive bytes differ.

`ditto` itself is deterministic: archiving the *same* on-disk bundle twice gives
the same sha. It is the rebuild that moves the number. If you want to see that
for yourself, the demonstration is at the bottom of this file — **do not run it
mid-release**, because it rebuilds and would void the gate you just passed.

This guidance used to say the opposite — "if the sha256 it prints differs from
the one you put in the cask, the cask is wrong" — which is backwards. It always
differs. Following it means either shipping a sha for a deleted temp file, or
concluding a correct cask is broken.

### Then smoke-test the bundle you are about to ship

```sh
pkill -f '/Applications/lil-ccgw.app/Contents/MacOS/lil-ccgw'   # quit the installed one
open dist/lil-ccgw.app
# … check the menu bar, then quit what you just launched:
pkill -f "$ROOT/dist/lil-ccgw.app/Contents/MacOS/lil-ccgw"
```

Confirm the menu bar item appears and the panel reads live numbers, then quit it.
It must be `dist/lil-ccgw.app` — the bundle step 3 just built. Launching the
installed `/Applications` copy smoke-tests the *previous* release while reading
as though it passed. Whether launching perturbs the bundle at all does not matter
here: the sha is taken in step 4, after this, and step 6 confirms the bytes that
actually reached the release.

## 4. Package the artifact you will actually upload

Package the bundle step 3 left behind, and do not build again afterwards —
another build resets the mtimes and invalidates the sha you are about to record.
Re-running `scripts/test.sh` is safe; it never touches `dist/`.

```sh
: "${VERSION:?set VERSION first}" \
  && : "${ROOT:?set ROOT first}" \
  && cd "$ROOT" \
  && test -d dist/lil-ccgw.app \
  && [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            dist/lil-ccgw.app/Contents/Info.plist)" = "$VERSION" ] \
  && [ "$(lipo -archs dist/lil-ccgw.app/Contents/MacOS/lil-ccgw | tr -s ' ')" = "x86_64 arm64" ] \
  && rm -f "dist/lil-ccgw-$VERSION.zip" \
  && ditto -c -k --keepParent dist/lil-ccgw.app "dist/lil-ccgw-$VERSION.zip" \
  && shasum -a 256 "dist/lil-ccgw-$VERSION.zip"
```

The version and arch checks *compare* rather than print. Eyeballing them is how a
stale bundle survives to step 8 — which is after the tap is pushed, i.e. after
users are already broken. If the chain prints a sha, both matched.

One `&&` chain throughout, for the same reason. An earlier version guarded with
`test -d … || echo "STOP"`, which prints a warning and then packages anyway:
`echo` succeeds, so `$?` is 0 and control falls straight into `ditto`. Two `STOP`
lines scroll past in a wall of build output and you get a candidate sha for
whatever happened to be in `dist/`.

`ditto`, not `zip` — it preserves the bundle's symlinks, resource forks and code
signature, which a plain `zip` corrupts.

`PlistBuddy -c Print` exits 1 on a missing file and writes `File Doesn't Exist,
Will Create:` to **stdout**. It creates nothing, but that line lands in the same
stream as a real version string, so it reads as output rather than as an error —
check the value, not just that something printed.

`dist/` is gitignored, so packaging cannot dirty the tree step 1 checked.

Record that sha256 as a candidate. Step 6 is what confirms it.

## 5. Publish

The first irreversible, outward-facing step: a pushed tag and a published
release are visible immediately and awkward to retract. **Confirm before running
it**, per CLAUDE.md's rule about outward-facing actions, even though ordinary
commits and pushes in this repo need no permission.

Draft the notes first, from the same commit range used for the version bump, in
the style of `gh release view v0.4.0 --json body`. Use `--notes-file`: a
double-quoted `--notes` shell-expands `$`, and these notes carry dollar amounts.

```sh
: "${VERSION:?set VERSION first}" \
  && : "${ROOT:?set ROOT first}" \
  && : "${PREV:?capture PREV in step 2, before tagging}" \
  && NOTES="$(mktemp -d)/notes.md" \
  && git -C "$ROOT" log --format=%s "$PREV"..HEAD    # source material

vi "$NOTES"                                        # or whatever you use

[ -s "$NOTES" ] \
  && git -C "$ROOT" push origin main \
  && git -C "$ROOT" push origin "v$VERSION" \
  && gh release create "v$VERSION" \
       "$ROOT/dist/lil-ccgw-$VERSION.zip" \
       -R AndrewHYi/lil-ccgw \
       --title "lil-ccgw $VERSION" \
       --notes-file "$NOTES" \
       --verify-tag
```

Four things worth naming there:

- **The `:?` guards are chained, not standalone.** An unset `PREV` does not error
  on its own — git fills the empty side of `..HEAD`, giving `HEAD..HEAD`, which
  prints nothing and exits 0, and you edit an empty notes file with no indication
  why. Reaching step 5 in a fresh shell, or on a retry that skipped step 2, is
  exactly when that happens.
- **`[ -s "$NOTES" ]`** so quitting the editor without saving stops the release
  instead of pushing a tag and then failing, or publishing empty notes.
- **A literal editor, not `$EDITOR`.** Quoted, `"${EDITOR:-vi}"` breaks a
  multi-word `EDITOR` like `code -w`; unquoted it breaks *anyway* in zsh, which
  does not word-split unquoted expansions. Not worth a workaround for one
  personal runbook — name your editor.
- **`git -C "$ROOT"`** on both pushes. Cwd is not trustworthy this late — a retry
  reached from step 7 would otherwise push the *tap*.

Three things in that chain are load-bearing:

- **`--verify-tag`.** Without it, if the tag is not on the remote `gh` *invents
  one from the latest state of the default branch* — so a rejected `git push
  origin main` (a non-fast-forward is the ordinary case) publishes a release
  whose tag points at the old remote commit while the asset was built from
  yours. The tag and the bytes disagree, silently and permanently.
- **`&&` all the way through**, so a failed push cannot fall through to a
  publish. On separate lines, `gh release create` runs regardless.
- **One tag by name.** `--tags` publishes every local tag, including experiments
  you never meant to ship.

`-R AndrewHYi/lil-ccgw` on every `gh release` call, here and below. `gh` otherwise
infers the repo from the current directory's git remote, and step 7 leaves you
inside the *tap* — from there a bare `gh release view` reports "release not
found" for a release that exists. `$ROOT` for the asset path for the same reason.

`$NOTES` lives outside the repo so a half-finished release cannot leave an
untracked file behind and fail step 1's clean-tree check on the retry.

## 6. Confirm the published asset

The check the whole ordering exists to make possible. Nothing before this proves
the cask will work; a truncated upload or the wrong file produces a release that
looks fine and fails on every user's `brew install` with a checksum mismatch.

```sh
: "${VERSION:?set VERSION first}" \
  && gh release view "v$VERSION" -R AndrewHYi/lil-ccgw \
       --json assets --jq '.assets[].name' \
  && REL="$(mktemp -d)/rel.zip" \
  && curl -fsSL -o "$REL" \
       "https://github.com/AndrewHYi/lil-ccgw/releases/download/v$VERSION/lil-ccgw-$VERSION.zip" \
  && shasum -a 256 "$REL"
```

The asset list must print exactly `lil-ccgw-$VERSION.zip`, and nothing else.

`-f` is load-bearing: without it `curl` exits 0 on a 404 and writes a 9-byte
`Not Found` body to the output file, whose sha would sail into the cask.

Compare with step 4. **Only if they are equal does that number go in the cask.**
If they differ, the release does not hold the artifact you verified — re-upload
and re-check rather than copying the downloaded sha:

```sh
: "${ROOT:?set ROOT first}" \
  && gh release upload "v$VERSION" "$ROOT/dist/lil-ccgw-$VERSION.zip" \
       -R AndrewHYi/lil-ccgw --clobber
```

Then run this step again. A re-upload is not confirmed until it has been
downloaded back.

## 7. Tap

The tap is `AndrewHYi/homebrew-tap` (repo name `homebrew-tap`, referenced as
`AndrewHYi/tap`). It already exists and is public. It is tapped locally, so the
live cask is readable on disk — **edit that, do not retype it from memory:**

```sh
cd /opt/homebrew/Library/Taps/andrewhyi/homebrew-tap \
  && git pull \
  && cat Casks/lil-ccgw.rb
```

Pull first: the local tap is a working copy that may be behind, and editing a
stale one produces a push that silently reverts someone else's change. Chained
with `&&` because on a machine where the tap is not tapped, a bare `cd` fails and
the `git pull` on the next line runs **in the lil-ccgw repo** — fast-forwarding
`main` past the commit you just tagged, built and uploaded.

**You are now in a different git repository.** Every `gh release` command from
here on needs `-R AndrewHYi/lil-ccgw`, and any path into `dist/` needs `$ROOT`.
That includes the recovery table below, whose last row is by definition reached
from this directory.

A release changes exactly two lines. Edit them by hand, or:

```sh
vi Casks/lil-ccgw.rb
#   version "<the new VERSION>"
#   sha256  "<the sha from step 6 — the DOWNLOADED one, confirmed equal to step 4>"
```

Everything else — the `depends_on`, the `postflight` that strips
`com.apple.quarantine`, the `zap` list — is already correct and should be left
alone. `depends_on macos: :sonoma` in particular reads as an exact-version pin
and is not: `brew info` reports it as `Required: macOS >= 14`.

This document used to inline a full copy of the cask, which promptly drifted from
the real one in three ways at once (a stale version, a `">= :sonoma"` that the tap
had already corrected to a bare symbol, and a claim the tap did not exist).
Pointing at the source of truth is the fix.

**If you change any stanza other than `version`/`sha256`, mirror it into the cask
heredoc in `scripts/verify-cask.sh` first** — that script verifies its own inline
copy, so an unmirrored change means step 3 verifies a cask nobody ships.

Confirm the diff is those two lines and nothing else, then commit and push. That
is a second repo and an outward-facing publish — see the note in step 5.

```sh
git diff --stat                     # 1 file changed, 2 insertions(+), 2 deletions(-)
```

Reference implementation for cask patterns, on disk if AeroSpace is installed:

```sh
cat /opt/homebrew/Library/Taps/nikitabobko/homebrew-tap/Casks/aerospace.rb
```

## 8. Install it the way a user would

The only step that exercises the published release, the published cask and
Homebrew's own checksum check together. A sha mismatch fails loudly here.

```sh
brew update
if brew list --cask lil-ccgw >/dev/null 2>&1; then
  brew upgrade --cask AndrewHYi/tap/lil-ccgw
else
  # Not brew-managed. If a hand-copied bundle is sitting there, brew refuses to
  # overwrite it — remove it, but only after confirming that is what it is.
  ls -d /Applications/lil-ccgw.app 2>/dev/null && rm -rf /Applications/lil-ccgw.app
  brew install --cask AndrewHYi/tap/lil-ccgw
fi
```

`brew upgrade` errors if the cask is not currently installed — which is the state
after the local-install fallback above — so this check is what keeps the release's
only end-to-end test from silently not running. The `rm -rf` fires only in that
same not-brew-managed case, because a hand-copied `/Applications/lil-ccgw.app`
makes Homebrew refuse to overwrite it.

Written as `if`/`else` on purpose: `list && upgrade || install` would run the
install when the *upgrade* failed, converting the one failure this step exists to
catch into a second command that hides it.

The menu bar item has to be quit and relaunched to pick up the new bundle:

```sh
pkill -f '/Applications/lil-ccgw.app/Contents/MacOS/lil-ccgw'
open -a /Applications/lil-ccgw.app
: "${VERSION:?set VERSION first}" \
  && [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            /Applications/lil-ccgw.app/Contents/Info.plist)" = "$VERSION" ] \
  && echo "INSTALL_OK $VERSION"
```

Compared, not printed — this is the last confirmation in the runbook, and by the
time you reach it the tap is already published, so a mismatch here is the signal
to start the recovery table rather than something to squint at. Guarded for the
same reason: step 7 leaves you in the tap and step 8 is the likeliest place to be
reached from a new terminal, where an unset `VERSION` would silently read as a
failed install.

Match the full binary path, not just the bundle — a bare `lil-ccgw.app` pattern
also matches an `open -a` still in flight.

## If it goes wrong

Every row assumes `VERSION` and `ROOT` are still bound. You are most likely
reading this from inside the tap (step 7) or a fresh terminal, so **check them
first, and only re-bind if they are actually empty**:

```sh
echo "VERSION=[$VERSION] ROOT=[$ROOT]"
```

If either is empty, re-run the binding chain at the top of this document —
do not assign them by hand here. An earlier version of this preamble printed
`VERSION=X.Y.Z; ROOT=~/personal/lil-ccgw`, which destroyed a correct binding
(the common case when you arrive from step 7), substituted the placeholder the
opening section exists to reject, and hardcoded a path that is wrong whenever the
release was cut from a worktree.

| State | Do this |
|---|---|
| Before step 5, anything | `git tag -d "v$VERSION"` and start over; nothing is published |
| Tag pushed, `gh release create` failed | `gh release view "v$VERSION" -R AndrewHYi/lil-ccgw` first. Nothing there → re-run `create`. A **draft** → the upload stage failed, so `gh release upload "v$VERSION" "$ROOT/dist/lil-ccgw-$VERSION.zip" -R AndrewHYi/lil-ccgw --clobber`, **then re-run step 6 before publishing**, then `gh release edit "v$VERSION" -R AndrewHYi/lil-ccgw --draft=false`. Do not re-run `create`; it collides with `already_exists`. This is the one path that could otherwise publish bytes nobody confirmed |
| Step 6 shows no such asset | `gh release view "v$VERSION" -R AndrewHYi/lil-ccgw` — if the release is missing entirely, re-run step 5; `--clobber` is for a *bad* upload, not an absent one |
| Step 6 sha mismatch | `gh release upload "v$VERSION" "$ROOT/dist/lil-ccgw-$VERSION.zip" -R AndrewHYi/lil-ccgw --clobber`, then re-check. Never copy the downloaded sha into the cask |
| Tag pushed, release wrong beyond repair | `gh release delete "v$VERSION" -R AndrewHYi/lil-ccgw -y` removes the release and leaves the tag (`--cleanup-tag` is opt-in); re-cut from a new commit rather than reusing the tag |
| Step 8 fails after the tap was pushed | **Revert and push the tap commit first**, then diagnose. Until you do, every user's `brew install` is broken |

## Checklist

- [ ] `VERSION` and `ROOT` bound; `VERSION` a bare semver derived from the commit range
- [ ] Every guard chained with `&&`, not left standing alone on its own line
- [ ] Repo/releases public (or explicitly decided otherwise, and stopped here)
- [ ] On `main`, tree clean, `scripts/test.sh` green
- [ ] `PREV` captured **before** tagging — step 5 has no other source for it
- [ ] Tagged before the artifact was built; `describe` returns the new tag
- [ ] `scripts/verify-cask.sh --zap` printed `VERIFY_OK` — and its sha256 was **ignored**
- [ ] Smoke-tested `dist/lil-ccgw.app`, not the installed copy, and quit it
- [ ] Packaged *after* verifying, with nothing rebuilt in between
- [ ] Version and both arches **compared**, not eyeballed — the chain printed a sha
- [ ] Zipped with `ditto`, not `zip`
- [ ] Release notes file non-empty before the push chain ran
- [ ] `gh release create` carried `--verify-tag`, and the push chain was `&&`
- [ ] `gh release view` showed exactly one asset, named `lil-ccgw-$VERSION.zip`
- [ ] Downloaded the published asset with `curl -f` and its sha matches step 4
- [ ] That sha is the one in the cask
- [ ] Tap pulled before editing; only `version` and `sha256` changed
- [ ] Every `gh release` call after step 7 used `-R AndrewHYi/lil-ccgw`
- [ ] `brew install`/`upgrade` succeeded and the relaunched app printed `INSTALL_OK`
- [ ] Confirmed before pushing the tag, the release, and the tap

Most of what this list used to check by hand is now asserted by
`verify-cask.sh`. What is left is the part a script cannot do: deciding to
publish, keeping the two repos in step, and making sure the bytes on the release
are the bytes the cask promises.

## Appendix: proving the mtime claim

**Not during a release.** This rebuilds `dist/`, which voids step 3's
verification — the exact hazard step 3 warns about. Run it when you doubt the
reasoning, on a scratch copy, with no release in flight.

```sh
W="$(mktemp -d)"
ditto "${ROOT:-.}/dist/lil-ccgw.app" "$W/x.app"

# 1. ditto is deterministic: same bundle twice, same sha.
ditto -c -k --keepParent "$W/x.app" "$W/a.zip"
ditto -c -k --keepParent "$W/x.app" "$W/b.zip"
shasum -a 256 "$W/a.zip" "$W/b.zip"                    # identical

# 2. mtimes alone move it: same content, touched.
find "$W/x.app" -exec touch {} +
ditto -c -k --keepParent "$W/x.app" "$W/c.zip"
shasum -a 256 "$W/a.zip" "$W/c.zip"                    # DIFFERENT

# 3. and the content really is unchanged either way.
find "$W/x.app" -type f -exec shasum -a 256 {} \; | sort -k2 | shasum
rm -rf "$W"
```

Step 2 is the half that matters and the one an earlier version of this appendix
left out: without it the snippet showed determinism and content-stability but
never the thing being defended — that identical content archives to a different
sha once the mtimes move.
