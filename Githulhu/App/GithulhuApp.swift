import SwiftData
import SwiftUI

@main
struct GithulhuApp: App {
    private let container: ModelContainer
    @StateObject private var appModel: AppModel

    init() {
        do {
            let container = try ModelContainer(
                for: RepositoryRecord.self,
                OperationRecord.self
            )
            self.container = container
            _appModel = StateObject(
                wrappedValue: AppModel(
                    git: LibGit2Service(),
                    github: GitHubService(),
                    keychain: KeychainStore(),
                    bookmarks: BookmarkStore()
                )
            )
        } catch {
            fatalError("Unable to create the Githulhu database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
        }
        .modelContainer(container)
    }
}
