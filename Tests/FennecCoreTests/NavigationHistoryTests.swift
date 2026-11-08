import Foundation
import Testing
@testable import FennecCore

struct NavigationHistoryTests {
    let a = URL(filePath: "/a")
    let b = URL(filePath: "/a/b")
    let c = URL(filePath: "/a/b/c")

    @Test func backAndForwardRetraceVisits() {
        var history = NavigationHistory(start: a)
        history.visit(b)
        history.visit(c)

        #expect(history.goBack() == b)
        #expect(history.goBack() == a)
        #expect(history.goBack() == nil)
        #expect(history.goForward() == b)
        #expect(history.current == b)
    }

    @Test func visitingClearsForwardStack() {
        var history = NavigationHistory(start: a)
        history.visit(b)
        _ = history.goBack()
        history.visit(c)

        #expect(!history.canGoForward)
        #expect(history.goBack() == a)
    }

    @Test func revisitingCurrentFolderIsIgnored() {
        var history = NavigationHistory(start: a)
        history.visit(URL(filePath: "/a/", directoryHint: .isDirectory))
        #expect(!history.canGoBack)
    }

    @Test func cannotGoUpFromRoot() {
        #expect(!NavigationHistory(start: URL(filePath: "/")).canGoUp)
        #expect(NavigationHistory(start: b).canGoUp)
    }
}
