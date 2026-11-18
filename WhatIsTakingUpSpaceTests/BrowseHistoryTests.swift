import Testing
@testable import WhatIsTakingUpSpace

struct BrowseHistoryTests {
    @Test func aNewHistoryIsAtTheScanRootWithNothingBehindIt() {
        let history = BrowseHistory()

        #expect(history.location == [])
        #expect(!history.canGoBack)
    }

    @Test func goingSomewhereShowsItAndRemembersWhereYouWere() {
        var history = BrowseHistory()

        history.go(to: ["Users"])

        #expect(history.location == ["Users"])
        #expect(history.canGoBack)
    }

    @Test func backGoesThroughEarlierPlacesNewestFirst() {
        var history = BrowseHistory()
        history.go(to: ["Users"])
        history.go(to: ["Users", "ada"])
        history.go(to: ["Applications"])

        history.goBack()
        #expect(history.location == ["Users", "ada"])
        history.goBack()
        #expect(history.location == ["Users"])
        history.goBack()
        #expect(history.location == [])
        #expect(!history.canGoBack)
    }

    @Test func goingWhereYouAlreadyAreLeavesNothingToGoBackTo() {
        var history = BrowseHistory()
        history.go(to: ["Users"])

        history.go(to: ["Users"])
        history.goBack()

        #expect(history.location == [])
        #expect(!history.canGoBack)
    }

    @Test func backWithNothingBehindStaysWhereItIs() {
        var history = BrowseHistory()

        history.goBack()

        #expect(history.location == [])
    }
}
