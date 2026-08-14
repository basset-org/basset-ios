# basset for iOS

Live, on-demand iOS diagnostics. An app links this library; a request names
instruments to activate and an expiry, and the device streams what they observe
until it lapses. Nothing is collected unless a request asks for it.

`REVIEW.md` is the standard a change here is held to. Read it before writing
code, not after — most of what it says follows from two facts that shape
everything in this repository, and neither is obvious from the code alone:
**this runs inside somebody else's app**, and **it is public**.

## Layout

```
Sources/Basset/        the library an app links: instruments, transports, control
Sources/BassetECS/     the entity-component layer instruments record through
Tests/                 host tests
Demo/                  an executable that exercises the library by hand
```

`Basset` is the only product. `BassetECS` is a separate module because the wire
format and the instruments both depend on it and neither should depend on the
other.

## Build and test

Two build systems describe the same sources, and both must keep working.

```sh
swift build            # SwiftPM, what an integrator's Xcode uses
swift test

bazel build //...      # Bazel
bazel test //...
```

**CI runs neither of these directly.** `.github/workflows/test.yml` drives
`xcodebuild` against two simulator runtimes — the oldest and newest the image
carries, because a control-plane timestamp once parsed on the newest and
returned nil on everything below it — plus `swift test --sanitize=thread` on
the host, which is what a data race fails. Nothing runs Bazel, so the second
graph is held by whoever remembers to build it before pushing.

`Package.swift` is the file an integrator resolves against, so it is the one
that decides the platform floor: iOS 17, macOS 13. Adding a source file means
adding it to both graphs.

Instruments that touch UIKit or AVFoundation only compile for iOS; the macOS
floor exists so the tests and the demo can run on a development machine, not
because the library targets the Mac.

## Before your first commit

```sh
git config core.hooksPath .githooks
```

A fresh clone does not pick this up on its own, and `.github/workflows/format.yml`
lints the tree on every pull request — so without it, the first thing a
contributor learns is that CI disagrees with their editor. The hook runs
`swiftformat` over staged Swift files and re-stages them. A file that is only
partly staged is linted instead of formatted, because formatting it would stage
the hunks that were deliberately left out.

`.github/workflows/test.yml` runs the tests on every pull request.

## No dependencies

Apple's own frameworks cover what this library needs. There are no package
dependencies and there should not be: a diagnostics library that drags a
dependency graph into an app becomes a version conflict inside somebody else's
build, and no feature here is worth that.

The same reasoning applies to Swift language features. An experimental feature
flag in a public library means an integrator's toolchain upgrade can break their
build, and the failure will be attributed here.

## Writing for a reader who has only this repository

Every claim in this repository has to be checkable by someone holding nothing
else. No paths to files that are not here, no references to documents they
cannot open, no comparisons to other products, and no open questions left in
shipped source — decide them, or state the current behaviour flatly.

Comments record why a choice was made over the obvious alternative: a hazard, a
measured constant, an approach that was tried and failed. Never what the line
does. `REVIEW.md` has the rest, including the vocabulary that reads as jargon
when encountered cold.
