import Foundation

/// The environment variables a launch can carry (`open --env`), all of them for the test benches:
/// OLDTUNES_HARNESS picks a bench, and others give a run its own index or look (README ▸ Test
/// benches). Only Debug and Bench builds have the benches and read these. A Release build, the one
/// that ships, leaves the benches out (project.yml) and ignores every variable.
enum LaunchEnvironment {
    /// A variable's value; nil when it is unset or empty, and always nil in a Release build.
    static func value(_ name: String) -> String? {
        #if BENCHES
        return ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
        #else
        return nil
        #endif
    }

    /// The test bench this launch runs (OLDTUNES_HARNESS); nil when it runs the app.
    static var bench: String? {
        #if BENCHES
        return value("OLDTUNES_HARNESS")
        #else
        return nil
        #endif
    }
}
