# Reviewing this SDK

The standard a change here is held to. cubic's review rule, configured in its web
UI rather than in this repository, points at this file, so it is what the
automated review applies, and it is the brief for anyone opening a pull request.

Two things make this repository unlike most, and nearly every rule below follows
from one of them: **the code runs inside somebody else's app**, and **it is
public**.

## How work moves

One branch, one pull request, one concern. `main` is linear — squash-merge keeps
it that way and makes the pull request title the commit subject that survives.

```
branch      <scope>/<subject>          transport/retry-a-lost-batch
PR title    <scope>: <subject>         transport: retry a lost batch
merge       squash, delete the branch
```

Scope is the area the change is about: an instrument domain (`camera`,
`network`, `runtime`, `lifecycle`, `location`, `notifications`, `render`,
`webkit`, `bluetooth`, `environment`, `permissions`), a subsystem
(`transport`, `control`, `wire`, `interception`, `concurrency`, `device`),
`build` or `ci` for tooling, or `all` when the change is about the repository
rather than one part of it.

Subject: imperative, lowercase, no trailing period, no `feat:`/`fix:` prefix,
50 characters ideally and 72 at the outside. Say what changes for a reader of
the code, not which files moved.

Bodies are rare, and belong to changes that alter someone else's assumptions:
breaking API changes, a fix with a security consequence, a behaviour change an
integrator would otherwise discover at runtime. Prose about why, wrapped at 72.

## It runs inside somebody else's app

The app it is linked into did not choose this code path and cannot debug it. The
bar is higher than "correct".

- **Never take the host process down.** No force-unwraps on anything the system
  supplies, no `try!`, no precondition on a value a framework returned. An
  instrument that cannot do its job stops doing its job; it does not raise.
- **Bounded work, always.** A buffer with no cap, a retry with no ceiling, a
  queue that grows under backpressure — each is a finding even when the happy
  path is fine. Say what bounds it.
- **Behaviourally invisible.** Nothing may change what the host app does:
  ordering, timing that a caller can observe, the values it receives. A
  swizzle that alters a return value is a bug, not an instrument.
- **Interception is hazardous and gets extra scrutiny.** Swizzling, KVO, and
  delegate proxies must forward faithfully to the original, tolerate the
  original being nil or already replaced, and release what they installed when
  the instrument deactivates. A hook that survives deactivation is a leak into
  an app that asked for nothing.
- **Hazardous contexts allocate nothing.** Code that runs with threads
  suspended, inside a signal handler, or during a fault has different rules
  than the rest of the file, and the comment saying so is load-bearing — do not
  suggest removing it.

## Zero dependencies

Apple's own frameworks cover the hard parts. A new package dependency is a
finding by default: it becomes a version conflict inside an integrator's build
graph, and no diagnostic feature is worth that.

## Comments say why, and only what a stranger can check

A comment earns its place by saying something the code cannot: a hazard, a
measured constant, or an alternative that was tried and failed. Never what the
line does — if a reader cannot follow the code, the fix is a better name or an
extracted function.

**One line, terse, always.** A comment that needs a second line is carrying
context that belongs in the commit body, the pull request, or a name. Cut it
until it fits.

The reader has **only this repository checked out**. A claim they cannot verify
from what they are holding does not belong in it:

- No paths, filenames, or documents outside this repository. Reasoning has to be
  restated in place or dropped — never linked.
- No `TODO`, `FIXME`, `HACK`, `XXX`, and no open design questions. An undecided
  question in shipped source reads as an unfinished product. Decide it, or state
  the current behaviour flatly and stop.
- No diary voice. Not "this cost a capture in July" — keep the finding, drop the
  story and the date.
- No comparisons to other vendors' products. The mechanism fact survives; the
  comparison does not.
- No server-side implementation detail. This code knows a protocol, not a
  database. "The control plane sends six fractional digits", never how anything
  stores them.

Public API doc comments stay, and stay short: one sentence on what it does, a
second only if a caller gets it wrong without one. No multi-paragraph essays, no
rhetorical scaffolding, no thesis restated at the end.

A comment left sitting above a declaration that no longer exists is a bug —
check placement after any refactor that moves code out from under one.

## Words a stranger reads cold

- "the request", "a caller", "whoever ordered the capture" — never "the agent".
- "the app", "a user" — never "the customer", who is the person reading the file.
- No invented abbreviations. `collectionView`, not `CV`. `DB`, `URL`, `API` are
  fine; coining is not.
- Names are literal. A protocol is a protocol, not a "contract". Code does not
  want, try, or decide — say what it does. Nothing beats, wins, or kills.

## Swift shape

- `*Type` on an enum naming the variant of a *separate* noun. Not when the enum
  **is** the noun. Remove the suffix: if it leaves "type of what?", keep it.
- `*Data` on a struct holding one case's payload. No suffix on owner types.
- Nested types drop what the outer namespace already says.
- Ternaries select values: one line, both branches values rather than calls.
  Anything else is `if`/`else`, which is an expression here and costs nothing.

## Entities and components are one shared vocabulary

An instrument owns its mechanism and owns none of the words it reports in.
`Entity.WireID` and `Component.WireID` are the whole catalog's vocabulary, and
every reader decodes a stored capture against them — including readers built
long after the capture was written.

**Ids only grow.** A case is never removed, renumbered, or reissued. That makes
a duplicate the expensive mistake: two names for one fact split every question
asked about that fact, both spellings stay in the space forever, and neither
can be retired.

So the first move when a reading needs a value is to look for the component
that already carries it. Several are deliberately general and already serve
several domains — `changeReason`, `errorDomain`, `errorCode`,
`callbackImplemented`, `occurrenceCount`. A near-match with the same meaning
and the same unit is a match.

A new component earns its place when no existing one names the fact, or when
reusing one would have to stretch its meaning to fit. Reuse stops at units and
at scalars: milliseconds do not go in a field named for nanoseconds, and a
count does not go in a field holding a name.

Entities follow the same rule and one more: an entity is the **subject** a
reading is about, not the instrument that produced it. Two instruments
describing the same subject share its entity, and an entity named after its
instrument is a duplicate waiting to be added.

Name both for what they are. A reader who has never seen the instrument has to
be able to tell what a component means from its name alone.

A review comment here is worth writing even when the addition is small: this is
the one part of the library where a mistake cannot be taken back.

## A framework's documentation is not evidence

Behaviour is established by running it. A constant's value is not its symbol's
name. A documented symbol may not exist in Swift. A getter with no entitlement
requirement can still terminate the process. A unit is often unstated.

When a change rests on a claim about an Apple framework, the question is what
was run to check it. "The documentation says" is not an answer. Prefer the
failure that is loud: a guess that crashes gets fixed, a guess that returns a
plausible wrong value ships.

## Tests and formatting

Tests drive instruments through the same activation path the device uses, not
by calling internals directly. Depth follows hazard: a swizzle or a fault
handler earns more than a value type.

Test fixtures are public too. A redaction test proving an email is stripped
should not use a real person's address to prove it.

Formatting is `swiftformat`'s output against this repository's `.swiftformat`,
enforced by a hook and by CI. Style comments are noise — if the formatter
accepts it, it is correct.

## Writing a finding

One line each, most severe first.

```
L<line>: <severity> <problem>. <fix>.
```

`bug` broken behaviour · `risk` fragile — a race, a missing guard, a swallowed
error, a hook that outlives its instrument · `nit` style the author may ignore ·
`q` a genuine question.

Exact symbol names in backticks, inline the fix when it is small. Two things
resist compression and get full prose: security findings, and disagreements
about design. Skip praise. If it is fine, say `LGTM` and stop.

## Findings are triaged, not obeyed

An automated review has no memory of why the code is shaped this way. Where it
is wrong about this repository, the fix usually belongs in this file rather than
in the code — that is what stops the next review repeating it.

A push that answers a review is reviewed again before the branch merges. A fix
is new code written under the pressure of a finding, which is when a lifecycle
guard gets added in one place and forgotten in the neighbouring one. A thread is
resolved when the re-review passes over it, not when the fix is pushed.

**A finding nobody ran gets a test before it gets a fix.** Most findings here are
reasoned rather than observed: a race read out of the code, a claim about what a
framework returns, an ordering nobody watched happen. Fixing one by reasoning
leaves both halves unproven — that the defect was real, and that the fix removes
it — and both can be answered by running something.

Reproduce the state the finding describes, watch the test fail, fix it, watch it
pass. Then revert the fix and confirm the test fails again: one that still passes
without it was testing something else.

Where the state cannot be forced — a thread interleaving, a device asleep, a
simulator with no camera — assert the state it produces rather than the timing
that produces it, and say in the test which half is out of reach. A reviewer
asking "what did you run" is asking for that, and "it should be fine now" is not
an answer.

### Already answered

- **`stopObserving()` may be empty.** An instrument does not release its own
  swizzles: `Context.teardown()` calls `swizzle.releaseObservers()`, and the
  runner calls `teardown()` on every deactivate. An empty `stopObserving()` on
  an instrument holding no state of its own is correct.
- **The `environment.*` baseline reads UIKit state on the runner's queue, and
  that is deliberate.** The getters involved are read-only; off-main they earn a
  Main Thread Checker diagnostic, never a raise. A main-queue hop is worse: in a
  process whose main thread is parked outside a run loop — a package-test host is
  one — the hop never runs and the initial reading is silently lost. A hop is
  right only when nothing observable waits on it, the way the display-rate cache
  is filled behind a synchronous fallback.
- **`sampleCount` beside `occurrenceCount` is not a split vocabulary.**
  `occurrenceCount` already carries two different facts depending on who writes
  it: how many times one subject occurred (`log.faults`, per subject) and how
  many there were in total (`concurrency.thread.inventory`, the same number on
  every row). Both readings are established and neither is wrong.
  `runtime.stackSamples` is the first reading that needs *both at once* — this
  stack's share, and the window it is a share of — so one id cannot carry them:
  repeated components are ordered, not named, and two `occurrenceCount` values
  in one entity are indistinguishable to a decoder. `occurrenceCount` keeps the
  per-subject meaning, `sampleCount` names the denominator.

  The denominator is on every stack rather than in a sibling of its own on
  purpose. A truncated window omits stacks, so summing the siblings does not
  recover it, and a segment read after a trim may not have the sibling at all.
- **Renaming an instrument or a domain is not an id change.** Ids are grow-only:
  never renumbered, reused, or removed. A *name* is catalog metadata that never
  rides the wire — `FrameEncoder` serializes the id, not the spelling — so
  changing one while its raw value stays put breaks nothing and needs no alias.
  A rename on a branch that has not merged cannot break a stored capture either,
  because no capture referring to it exists.
