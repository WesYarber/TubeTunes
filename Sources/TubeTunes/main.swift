import Foundation

// `TubeTunes --background-sync` is the headless run started by the launchd agent;
// anything else launches the normal app.
if CommandLine.arguments.contains("--background-sync") {
    Task { @MainActor in
        await BackgroundSync.run()
        exit(0)
    }
    dispatchMain()
} else {
    TubeTunesApp.main()
}
