import SwiftUI
import InferenceSignals
import InferenceSignalsUI

/// The demo app for `inference-signals-kit`.
///
/// The app owns the observability *policy* and hands it to the library's
/// dashboard. That split is deliberate: which Dynamic Profiles exist, what
/// "slow" means for each of them, how hard to thin nominal traffic when the
/// device heats up, and how many records may sit in memory between flushes
/// are product and platform decisions, not library defaults. It is also why
/// this file imports `InferenceSignals` as well as `InferenceSignalsUI` —
/// every value below is built from the core module's validated types
/// (`SamplingPolicy`, `TailPolicy`, `ToolLoopPolicy`, `SimulatedProfile`),
/// and the fallback screen reports the core module's error if a constant is
/// ever edited into something a policy would refuse.
@main
struct DemoApp: App {

    var body: some Scene {
        WindowGroup {
            switch DemoApp.launch {
            case .success(let configuration):
                InferenceSignalsDashboardView(configuration: configuration)
            case .failure(let error):
                // Unreachable with the constants below (see `launch`), but a
                // configuration error must degrade to a readable screen,
                // never to a crash at launch.
                ConfigurationRejectedView(message: DemoApp.describe(error))
            }
        }
    }

    /// Per-profile latency budgets: the planner may take 2.5 s end to end,
    /// the executor 1.5 s, the reviewer 1 s. A completion over its budget is
    /// a `.tail` record and survives sampling at any thermal state.
    ///
    /// Sampling is the library's standard ladder (100% → 50% → 10% → 2% of
    /// nominal traffic as the device heats up, halved in Low Power Mode) so
    /// the pipeline numbers on screen match the README. The buffer is small
    /// on purpose — 32 records, against a driver that emits roughly 200
    /// records between automatic flushes — so class-aware eviction is
    /// visible within seconds of traffic; the "refused" counter needs the
    /// buffer full of *protected* records, which the dashboard's sink-outage
    /// toggle produces at critical thermal state.
    ///
    /// Every initializer used here throws for values its policy would refuse
    /// (a rate that rises with pressure, a tool-loop window larger than the
    /// call budget); none of these constants trips them, so the `.failure`
    /// branch is unreachable as written. It exists so that editing a
    /// constant can never turn a typo into a launch crash.
    static let launch: Result<DashboardConfiguration, any Error> = Result {
        let profiles = SimulatedProfile.standard
        let tail = TailPolicy(defaultBudget: .milliseconds(1_500),
                              budgets: [SimulatedProfile.planner.id: .milliseconds(2_500),
                                        SimulatedProfile.reviewer.id: .milliseconds(1_000)])
        let loop = try ToolLoopPolicy(maximumCalls: 24, maximumPeriod: 4, repetitionsToFlag: 3)
        return DashboardConfiguration(profiles: profiles,
                                      tailPolicy: tail,
                                      samplingPolicy: .standard,
                                      bufferCapacity: 32,
                                      seed: 2026,
                                      toolLoopPolicy: loop)
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as ToolLoopPolicy.ConfigurationError:
            switch error {
            case .nonPositive(let name, let value):
                return "Tool-loop policy: \(name) must be positive, got \(value)"
            case .periodExceedsWindow(let period, let repetitions, let maximumCalls):
                return "Tool-loop policy: \(period) × \(repetitions) does not fit in \(maximumCalls) calls"
            }
        case let error as SamplingPolicy.ConfigurationError:
            return "Sampling policy rejected: \(error)"
        default:
            return String(describing: error)
        }
    }
}

/// Shown only if the launch configuration is rejected by the library.
struct ConfigurationRejectedView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text("The demo configuration was rejected by InferenceSignals.")
                .multilineTextAlignment(.center)
            Text(message)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
