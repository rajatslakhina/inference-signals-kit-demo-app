# InferenceSignals Demo

**Turn the thermal dial up and watch the sampler throw away healthy completions while every refusal, loop and slow request survives.**

This is the companion app for [`inference-signals-kit`](https://github.com/rajatslakhina/inference-signals-kit) — golden signals for on-device inference, built for the fleet rather than for a device you are holding. The app owns the observability *policy* (per-profile latency budgets, the sampling ladder, the buffer size, the tool-loop limits) and hands it to the library's dashboard, which drives a deterministic planner → executor → reviewer workload through a `SessionTracer` and renders what the collector knows.

The library is consumed as a **remote, version-pinned Swift package** (`XCRemoteSwiftPackageReference`, `upToNextMajorVersion` from `1.1.0`), not a local path and not a branch. Cloning this repo and opening `Demo.xcodeproj` resolves the package from GitHub.

## Why this matters

Xcode 27's Instruments template for the Foundation Models framework shows you sessions, requests, inferences and tool calls — on a device you own, for traffic that went through the framework. The fleet is where probabilistic failures actually live, and the app that wired a feature straight to a vendor SDK is invisible to it. So the observability decision is made at architecture time: what counts as an error when nothing throws, what may leave the device, and what you drop when the device is hot.

This demo makes the third decision visible. Under `.critical` thermal state in Low Power Mode the collector keeps **1%** of nominal completions and **100%** of guardrail refusals, tool-loop non-terminations, decode failures and over-budget completions — the "sampled out" counter climbs while the error counts keep rising at their usual pace. The buffer is deliberately tiny (32 records against ~200 emitted between automatic flushes), so at nominal thermal state its class-aware eviction is visible within seconds: nominal records are displaced first, tail records only once no nominal is left. The *refusal* path — a buffer full of protected records turning a nominal record away rather than evicting an error — needs protected records to accumulate. Healthy nominal traffic never produces that; hot traffic does, intermittently, between flushes (at `.critical` almost every completion is over budget, so the buffer fills with `tail` records in a few seconds and the 2% of nominal records still kept are refused until the next auto-flush empties it). The **Sink outage** toggle makes that immediate and repeatable: deliveries fail, the collector re-offers every batch through the buffer, and "Refused" climbs steadily instead of in bursts.

## What you see

The screen is a `List` with four kinds of section:

- **Device pressure** — a segmented thermal picker (nominal / fair / serious / critical), a Low Power Mode toggle, and a **Sink outage** toggle that makes every delivery fail, and three buttons: **Run traffic** (one simulated request every 120 ms, auto-flushing every 64), **One request**, **Flush**. The last simulated outcome is printed underneath (e.g. `executor: tool loop flagged — cycleDetected(period: 2, repetitions: 3)`).
- **Pipeline** — the nominal keep rate the policy currently applies, ingested vs. sampled-out counts, buffer occupancy against its 32-record capacity, evictions by class, refusals, and delivered vs. failed batches.
- **Profile · planner / executor / reviewer** — traffic (requests / completions / tool calls), error rate with a per-failure breakdown (tool-loop non-termination in red), the latency quartet as p50 / p95 (queue wait, TTFT, total, tokens/s), mean context headroom and KV-prefix reuse, and how many completions happened under pressure.
- **Last flush · N records (newest first)** — exactly the batch the most recent flush delivered (`SignalCollector.flushBatch()`), not the sink's cumulative history, each record tagged `nominal` / `tail` / `error` with the request ID and a one-line summary. Every record is the same `SignalRecord` type the `SignpostSink` would send to Instruments.

**Headline interaction, default state:** launch, tap **Run traffic**, wait a few seconds ("Evicted nominal" is already climbing), then move the thermal picker to **Critical**. "Nominal keep rate" drops from 100% to 2%; "sampled out" starts climbing on every step; the per-profile error counts and error rates keep increasing at the same pace as before; and the next flush delivers a *small* batch — a handful of records, almost all `tail` and `error` — because 98% of the healthy completions were never buffered. Then flip **Sink outage**: "delivery failures" climbs on every auto-flush, the buffer fills with re-offered protected records, and "Refused" starts counting. Session-lifecycle rows (`profileSwitched`) share one sampling coin per session and disappear from the list as a block under pressure; that is by design and is documented in the library.

## Screenshots

**There are no screenshots in this repository, and the app has not been run on a Simulator.** The unattended run that produced this repository could not obtain permission to drive Xcode or the Simulator (three attempts, nobody present to approve), so the app was never launched. Rather than describe an image that does not exist, this section states the gap. "Builds for a Simulator" (below, CI) and "ran on a Simulator" (did not happen) are two different facts and are reported separately.

## How to run it

```
git clone https://github.com/rajatslakhina/inference-signals-kit-demo-app.git
cd inference-signals-kit-demo-app
open Demo.xcodeproj
```

Select the **Demo** scheme, pick any iOS 17+ Simulator, Build & Run. Xcode resolves `inference-signals-kit` from GitHub on first open. Then: **Run traffic**, wait, set thermal to **Critical**, toggle **Low Power Mode**, tap **Flush**.

Requires Xcode 16 or later (the package uses Swift tools 6.0 and `@Observable`).

## Design decisions

**The app owns the policy, the library owns the mechanism.** `DemoApp.launch` builds a `TailPolicy` (planner 2.5 s, executor 1.5 s, reviewer 1 s), the library's `.standard` `SamplingPolicy`, a `ToolLoopPolicy` (24 calls, period ≤ 4, 3 repetitions) and a 32-record buffer, and hands them to `InferenceSignalsDashboardView` as a `DashboardConfiguration`. What "slow" means per profile and how hard to thin traffic under pressure are product decisions; a library default would be a guess. This is also why the app imports `InferenceSignals` directly and not only `InferenceSignalsUI`: every constant is built from the core module's validated types.

**Rejected:** hard-coding the configuration inside the view. It would make the demo shorter and hide the one thing an engineer adopting the library actually has to decide.

**The buffer is deliberately small, and the sink can be broken on purpose.** 32 records is far below what production would use; against ~200 records per auto-flush interval it makes class-aware eviction visible within seconds. Refusal needs a buffer full of *protected* records — something healthy traffic never produces and hot traffic produces only in bursts between flushes — so the dashboard's **Sink outage** toggle fails deliveries and lets the collector's re-offer path keep the buffer full of tail and error records. That is two library behaviours (failed-delivery re-offer, class-aware refusal) demonstrated by one switch, made deterministic rather than left to timing.

**Every initializer that can refuse a value is called through `Result`.** `ToolLoopPolicy` throws for a cycle window larger than the call budget; `SamplingPolicy` throws for a rate that rises with pressure. None of the constants here trips those checks, so the `.failure` branch is unreachable as written — but editing a constant into something the policy would refuse produces a readable `ConfigurationRejectedView`, never a launch crash.

**The workload is simulated on a manual clock.** `SimulatedExecutor` advances a `ManualClock` by the latencies it draws, so the dashboard's numbers are deterministic for the seed (`2026`) and the app does not need a Foundation Models entitlement, a network, or a real model to demonstrate the pipeline. Real integration is a `SessionTracer` call at each step of the actual `LanguageModelSession` — see the library README.

## Verification

What was and was not verified, exactly:

- **Library (Linux):** `rm -rf .build && swift build -Xswiftc -warnings-as-errors && swift build --build-tests -Xswiftc -warnings-as-errors && swift test` — build complete with zero warnings, **93 tests, 0 failures**. Repeated by the library's CI on every push: https://github.com/rajatslakhina/inference-signals-kit/actions
- **Library (macOS CI):** `xcodebuild build -scheme InferenceSignalsUI -destination 'generic/platform=iOS Simulator'` — compiles the SwiftUI dashboard for the Simulator SDK. Green on both tagged commits — `v1.0.0` (0c7edfb) and `v1.1.0` (4de637a); both jobs of both runs concluded `success`.
- **Demo (macOS CI, this repo):** https://github.com/rajatslakhina/inference-signals-kit-demo-app/actions — `xcodebuild -resolvePackageDependencies` (checks that the version-pinned remote package resolves from GitHub), then `xcodebuild build -scheme Demo -destination 'generic/platform=iOS Simulator'` with signing disabled. This is a compile-only check: it shows the project opens and links against the package, not that the app runs. **Status: green on the first run, on the commit that added the workflow** — every step (`xcodebuild -list`, `-resolvePackageDependencies`, `cat Package.resolved`, `xcodebuild build`) concluded `success`. The README you are reading was pushed *after* that run reported, which is why it can say so.
- **`project.pbxproj`:** hand-written; braces and parentheses balanced (33/33, 24/24), all 22 object IDs referenced are defined, `objectVersion = 60`, a shared `Demo.xcscheme` is committed.
- **Simulator run:** **did not happen** — see *Screenshots* above.
- **Review order, exactly:** the library was pushed, tagged `v1.0.0` and its CI went green first. Then three independent review rounds (a fresh model instance each time, no memory of writing the code, graded against a fixed checklist) ran against the on-disk code before anything else was pushed. Round 1: 3 blocking + 8 minor findings (a vacuous compaction test, a CI result asserted before the run existed, a mis-stated review order, an unbounded tracer map, a cumulative-log "last flush" list, among others). Round 2: 3 blocking + 9 minor (tense of CI/tag claims, a demo workload that never reached buffer eviction, a trap reachable through a degenerate `SimulatedProfile`, near-vacuous tests). Round 3: **0 blocking, 3 minor** (one more near-vacuous session-key test, a "two to seven records" comment that should read "two to nine", an over-stated rationale for the sink-outage toggle). Every finding was fixed; the round-3 fixes were *not* independently re-reviewed, since three rounds is the ceiling. The library was then re-pushed and tagged `v1.1.0`, this demo repo was pushed, its CI ran, and this README was written against the results.

## Layout

```
Demo.xcodeproj/                 project.pbxproj (remote package, pinned ≥ 1.1.0 < 2.0.0)
                                xcshareddata/xcschemes/Demo.xcscheme
Demo/DemoApp.swift              @main App: builds the configuration, mounts the dashboard
.github/workflows/ci.yml        resolve remote package + build for generic iOS Simulator
```

## License

MIT — see `LICENSE`.
