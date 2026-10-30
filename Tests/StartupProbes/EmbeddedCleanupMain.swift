import AppKit

// Compiled with the production cleanup source, then launched in a fresh process.
// A random identifier cannot refer to an existing user's sign-in store.
@main
struct EmbeddedCleanupStartupProbe {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        Task { @MainActor in
            do {
                let identifier = UUID()
                try await EmbeddedWebDataStoreCleanup.removePersistentStore(identifier)
                try await EmbeddedWebDataStoreCleanup.removePersistentStore(identifier)
                print("Cold-start cleanup completed")
                exit(0)
            } catch {
                fputs("Cold-start cleanup failed\n", stderr)
                exit(1)
            }
        }
        app.run()
    }
}
