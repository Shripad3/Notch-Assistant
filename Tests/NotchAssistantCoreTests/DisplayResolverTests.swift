@testable import NotchAssistantCore
import Testing

struct DisplayResolverTests {
    let notched = ScreenDescriptor(displayID: 1, topSafeAreaInset: 32, isBuiltin: true)
    let builtinNoInset = ScreenDescriptor(displayID: 1, topSafeAreaInset: 0, isBuiltin: true)
    let external = ScreenDescriptor(displayID: 2, topSafeAreaInset: 0, isBuiltin: false)
    let secondExternal = ScreenDescriptor(displayID: 3, topSafeAreaInset: 0, isBuiltin: false)

    @Test func builtInOnly() {
        #expect(DisplayResolver.resolve([notched]) == 1)
    }

    /// The external monitor listed first (it is the main display) must not win.
    @Test func builtInPlusExternal() {
        #expect(DisplayResolver.resolve([external, notched]) == 1)
        #expect(DisplayResolver.resolve([notched, external, secondExternal]) == 1)
    }

    /// Clamshell: the built-in display is gone. Must resolve to nothing, not crash.
    @Test func externalOnly() {
        #expect(DisplayResolver.resolve([external, secondExternal]) == nil)
    }

    @Test func noScreens() {
        #expect(DisplayResolver.resolve([]) == nil)
    }

    /// Fallback signal when the notch inset is not reported.
    @Test func builtInWithoutInsetStillResolves() {
        #expect(DisplayResolver.resolve([external, builtinNoInset]) == 1)
    }

    @Test func notchInsetWinsOverBuiltInFlag() {
        let oddExternal = ScreenDescriptor(displayID: 9, topSafeAreaInset: 24, isBuiltin: false)
        #expect(DisplayResolver.resolve([builtinNoInset, oddExternal]) == 9)
    }
}
