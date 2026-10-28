import XCTest
@testable import GlideKit

final class ButtonEngineTests: XCTestCase {
    private let b3 = MouseButton.middle
    private let b4 = MouseButton.button4
    private let b5 = MouseButton.button5

    private func engine(_ configs: [MouseButton: ButtonConfig]) -> ButtonEngine {
        ButtonEngine(configs: configs, holdDelay: 0.3, doubleClickWindow: 0.3, dragThreshold: 7)
    }

    // MARK: - buttonConfigs

    func testButtonConfigsFromSettings() {
        var s = GlideSettings()
        s.remapsEnabled = true
        s.remaps = [
            ButtonRemap(button: .button4, trigger: .click, action: .back),
            ButtonRemap(button: .button4, trigger: .doubleClick, action: .missionControl),
            ButtonRemap(button: .button4, trigger: .hold, action: .showDesktop),
            ButtonRemap(button: .button5, trigger: .click, action: .none),
        ]
        s.dragGestureButton = .middle
        s.scrollGestureButton = .middle
        let c = s.buttonConfigs
        XCTAssertEqual(c[.button4], ButtonConfig(click: .back, doubleClick: .missionControl, hold: .showDesktop))
        XCTAssertEqual(c[.middle], ButtonConfig(drag: true, scroll: true))
        XCTAssertNil(c[.button5], ".none actions are ignored, so button 5 has nothing configured")
        XCTAssertEqual(Set(c.keys), s.interceptedButtons)
    }

    func testButtonConfigsRemapsDisabledKeepsOnlyGestureButtons() {
        var s = GlideSettings()
        s.remapsEnabled = false
        s.remaps = [ButtonRemap(button: .button4, trigger: .click, action: .back)]
        s.dragGestureButton = .button5
        let c = s.buttonConfigs
        XCTAssertEqual(c, [.button5: ButtonConfig(drag: true)])
    }

    func testButtonConfigsEmptyByDefault() {
        XCTAssertTrue(GlideSettings().buttonConfigs.isEmpty)
    }

    func testButtonConfigsShortcutAction() {
        var s = GlideSettings()
        s.remapsEnabled = true
        let k = KeyShortcut(keyCode: 0, modifiers: ShortcutFormatter.command)
        s.remaps = [ButtonRemap(button: .middle, trigger: .click, action: .shortcut(k))]
        XCTAssertEqual(s.buttonConfigs[.middle]?.click, .shortcut(k))
    }

    // MARK: - intercepts / unknown buttons

    func testInterceptsAndIgnoresUnconfiguredButtons() {
        var e = engine([b4: ButtonConfig(click: .back)])
        XCTAssertTrue(e.intercepts(b4))
        XCTAssertFalse(e.intercepts(b3))
        XCTAssertEqual(e.handle(.down(b3, t: 0)), [])
        XCTAssertEqual(e.handle(.drag(b3, dx: 50, dy: 0, t: 0.01)), [])
        XCTAssertEqual(e.handle(.scroll(b3, t: 0.02)), [])
        XCTAssertEqual(e.handle(.up(b3, t: 0.05)), [])
        XCTAssertNil(e.nextDeadline)
    }

    func testEmptyConfigIsNotIntercepted() {
        let e = engine([b4: ButtonConfig()])
        XCTAssertFalse(e.intercepts(b4))
    }

    // MARK: - Click

    func testClickRemapFiresOnUp() {
        var e = engine([b4: ButtonConfig(click: .back)])
        XCTAssertEqual(e.handle(.down(b4, t: 1)), [])
        XCTAssertNil(e.nextDeadline, "no hold/gesture: no deadline needed")
        XCTAssertEqual(e.handle(.up(b4, t: 1.1)), [.action(.back)])
        XCTAssertNil(e.nextDeadline)
    }

    func testPlainClickOnInterceptedButtonPassesClick() {
        var e = engine([b3: ButtonConfig(drag: true)])
        XCTAssertEqual(e.handle(.down(b3, t: 0)), [])
        XCTAssertEqual(e.handle(.up(b3, t: 0.1)), [.passClick(b3)])
    }

    func testPlainClickOnHoldOnlyButtonPassesClick() {
        var e = engine([b5: ButtonConfig(hold: .launchpad)])
        _ = e.handle(.down(b5, t: 0))
        XCTAssertEqual(e.handle(.up(b5, t: 0.2)), [.passClick(b5)])
        XCTAssertEqual(e.handle(.timer(t: 1)), [], "released before deadline: hold never fires")
    }

    func testUpWithoutDownDoesNothing() {
        var e = engine([b4: ButtonConfig(click: .back)])
        XCTAssertEqual(e.handle(.up(b4, t: 0)), [])
    }

    // MARK: - Hold

    func testHoldFiresAtDeadlineAndSuppressesClick() {
        var e = engine([b4: ButtonConfig(click: .back, hold: .missionControl)])
        _ = e.handle(.down(b4, t: 10))
        XCTAssertEqual(e.nextDeadline!, 10.3, accuracy: 1e-9)
        XCTAssertEqual(e.handle(.timer(t: 10.1)), [], "timer before deadline does nothing")
        XCTAssertEqual(e.handle(.timer(t: 10.3)), [.action(.missionControl)])
        XCTAssertNil(e.nextDeadline)
        XCTAssertEqual(e.handle(.timer(t: 10.5)), [], "hold fires once")
        XCTAssertEqual(e.handle(.up(b4, t: 11)), [], "release after hold emits nothing")
    }

    func testHoldFiresOnLateUpIfTimerWasMissed() {
        var e = engine([b4: ButtonConfig(click: .back, hold: .missionControl)])
        _ = e.handle(.down(b4, t: 0))
        XCTAssertEqual(e.handle(.up(b4, t: 0.5)), [.action(.missionControl)])
    }

    func testLongPressWithoutHoldActionOnDragButtonPassesDownThenUp() {
        var e = engine([b3: ButtonConfig(drag: true)])
        _ = e.handle(.down(b3, t: 0))
        XCTAssertEqual(e.nextDeadline!, 0.3, accuracy: 1e-9)
        XCTAssertEqual(e.handle(.timer(t: 0.35)), [.passDown(b3)])
        XCTAssertNil(e.nextDeadline)
        XCTAssertEqual(e.handle(.drag(b3, dx: 100, dy: 0, t: 0.4)), [], "press already handed to apps")
        XCTAssertEqual(e.handle(.up(b3, t: 1)), [.passUp(b3)])
    }

    func testLongPressOnScrollButtonPassesDownThenUp() {
        var e = engine([b5: ButtonConfig(scroll: true)])
        _ = e.handle(.down(b5, t: 0))
        XCTAssertEqual(e.handle(.timer(t: 0.3)), [.passDown(b5)])
        XCTAssertEqual(e.handle(.scroll(b5, t: 0.4)), [])
        XCTAssertEqual(e.handle(.up(b5, t: 0.5)), [.passUp(b5)])
    }

    // MARK: - Drag

    func testDragBelowThresholdStillClicks() {
        var e = engine([b3: ButtonConfig(click: .smartZoom, drag: true)])
        _ = e.handle(.down(b3, t: 0))
        XCTAssertEqual(e.handle(.drag(b3, dx: 3, dy: 3, t: 0.05)), [])
        XCTAssertEqual(e.handle(.drag(b3, dx: 1, dy: 1, t: 0.06)), [], "|(4,4)| = 5.66 <= 7")
        XCTAssertEqual(e.handle(.up(b3, t: 0.1)), [.action(.smartZoom)])
    }

    func testDragAboveThresholdBeginsMovesEndsWithoutClick() {
        var e = engine([b3: ButtonConfig(click: .smartZoom, hold: .launchpad, drag: true)])
        _ = e.handle(.down(b3, t: 0))
        XCTAssertEqual(e.handle(.drag(b3, dx: 4, dy: 0, t: 0.01)), [])
        XCTAssertEqual(e.handle(.drag(b3, dx: 4, dy: 0, t: 0.02)),
                       [.dragBegan(b3), .dragMoved(dx: 4, dy: 0)])
        XCTAssertNil(e.nextDeadline, "drag cancels the hold deadline")
        XCTAssertEqual(e.handle(.drag(b3, dx: -2, dy: 5, t: 0.03)), [.dragMoved(dx: -2, dy: 5)])
        XCTAssertEqual(e.handle(.timer(t: 1)), [], "hold is cancelled by the drag")
        XCTAssertEqual(e.handle(.drag(b3, dx: 1, dy: 1, t: 1.1)), [.dragMoved(dx: 1, dy: 1)])
        XCTAssertEqual(e.handle(.up(b3, t: 1.2)), [.dragEnded(b3)])
        XCTAssertEqual(e.handle(.timer(t: 5)), [])
    }

    func testDragUsesEuclideanDistance() {
        var e = engine([b3: ButtonConfig(drag: true)])
        _ = e.handle(.down(b3, t: 0))
        XCTAssertEqual(e.handle(.drag(b3, dx: 5, dy: 5, t: 0.01)), [.dragBegan(b3), .dragMoved(dx: 5, dy: 5)],
                       "|(5,5)| = 7.07 > 7")
    }

    func testDragAfterHoldFiredDoesNotBeginGesture() {
        var e = engine([b3: ButtonConfig(hold: .missionControl, drag: true)])
        _ = e.handle(.down(b3, t: 0))
        XCTAssertEqual(e.handle(.timer(t: 0.3)), [.action(.missionControl)])
        XCTAssertEqual(e.handle(.drag(b3, dx: 50, dy: 0, t: 0.4)), [])
        XCTAssertEqual(e.handle(.up(b3, t: 0.5)), [])
    }

    func testDragOnLateInputFiresDueHoldFirst() {
        var e = engine([b3: ButtonConfig(hold: .missionControl, drag: true)])
        _ = e.handle(.down(b3, t: 0))
        XCTAssertEqual(e.handle(.drag(b3, dx: 50, dy: 0, t: 0.4)), [.action(.missionControl)])
    }

    func testDragIgnoredWithoutDragGesture() {
        var e = engine([b4: ButtonConfig(click: .back)])
        _ = e.handle(.down(b4, t: 0))
        XCTAssertEqual(e.handle(.drag(b4, dx: 100, dy: 100, t: 0.05)), [])
        XCTAssertEqual(e.handle(.up(b4, t: 0.1)), [.action(.back)], "drags do not cancel the click")
    }

    func testDragOfOtherButtonIgnored() {
        var e = engine([b3: ButtonConfig(drag: true), b4: ButtonConfig(drag: true)])
        _ = e.handle(.down(b3, t: 0))
        XCTAssertEqual(e.handle(.drag(b4, dx: 100, dy: 0, t: 0.05)), [])
        XCTAssertEqual(e.handle(.up(b3, t: 0.1)), [.passClick(b3)])
    }

    // MARK: - Scroll gesture

    func testScrollGestureBeginEndAndNoClick() {
        var e = engine([b5: ButtonConfig(click: .forward, hold: .launchpad, scroll: true)])
        _ = e.handle(.down(b5, t: 0))
        XCTAssertEqual(e.handle(.scroll(b5, t: 0.1)), [.scrollGestureBegan(b5)])
        XCTAssertNil(e.nextDeadline)
        XCTAssertEqual(e.handle(.scroll(b5, t: 0.15)), [], "began only once")
        XCTAssertEqual(e.handle(.timer(t: 0.5)), [], "no hold after scroll")
        XCTAssertEqual(e.handle(.up(b5, t: 0.6)), [.scrollGestureEnded(b5)])
    }

    func testScrollIgnoredWithoutScrollGesture() {
        var e = engine([b5: ButtonConfig(click: .forward)])
        _ = e.handle(.down(b5, t: 0))
        XCTAssertEqual(e.handle(.scroll(b5, t: 0.1)), [])
        XCTAssertEqual(e.handle(.up(b5, t: 0.2)), [.action(.forward)])
    }

    func testScrollDuringDragDoesNotStartScrollGesture() {
        var e = engine([b3: ButtonConfig(drag: true, scroll: true)])
        _ = e.handle(.down(b3, t: 0))
        _ = e.handle(.drag(b3, dx: 10, dy: 0, t: 0.01))
        XCTAssertEqual(e.handle(.scroll(b3, t: 0.02)), [])
        XCTAssertEqual(e.handle(.up(b3, t: 0.1)), [.dragEnded(b3)])
    }

    // MARK: - Double click

    func testDoubleClickWithinWindowFiresOnceWithoutSingleClick() {
        var e = engine([b4: ButtonConfig(click: .back, doubleClick: .missionControl)])
        XCTAssertEqual(e.handle(.down(b4, t: 0)), [])
        XCTAssertEqual(e.handle(.up(b4, t: 0.1)), [])
        XCTAssertEqual(e.nextDeadline!, 0.4, accuracy: 1e-9)
        XCTAssertEqual(e.handle(.down(b4, t: 0.2)), [])
        XCTAssertNil(e.nextDeadline, "second down cancels the single-click deadline")
        XCTAssertEqual(e.handle(.up(b4, t: 0.25)), [.action(.missionControl)])
        XCTAssertNil(e.nextDeadline)
        XCTAssertEqual(e.handle(.timer(t: 2)), [], "no single click afterwards")
    }

    func testSingleClickWithDoubleClickConfiguredFiresAfterWindow() {
        var e = engine([b4: ButtonConfig(click: .back, doubleClick: .missionControl)])
        _ = e.handle(.down(b4, t: 0))
        XCTAssertEqual(e.handle(.up(b4, t: 0.1)), [])
        XCTAssertEqual(e.handle(.timer(t: 0.3)), [], "window still open")
        XCTAssertEqual(e.handle(.timer(t: 0.4)), [.action(.back)])
        XCTAssertNil(e.nextDeadline)
        XCTAssertEqual(e.handle(.timer(t: 0.5)), [])
    }

    func testSingleClickWithOnlyDoubleClickConfiguredPassesClickAfterWindow() {
        var e = engine([b4: ButtonConfig(doubleClick: .appExpose)])
        _ = e.handle(.down(b4, t: 0))
        _ = e.handle(.up(b4, t: 0.1))
        XCTAssertEqual(e.handle(.timer(t: 0.41)), [.passClick(b4)])
    }

    func testSecondDownAfterWindowIsANewFirstClick() {
        var e = engine([b4: ButtonConfig(click: .back, doubleClick: .missionControl)])
        _ = e.handle(.down(b4, t: 0))
        _ = e.handle(.up(b4, t: 0.1))
        // Timer was never delivered; the late down settles the first click first.
        XCTAssertEqual(e.handle(.down(b4, t: 0.6)), [.action(.back)])
        XCTAssertEqual(e.handle(.up(b4, t: 0.65)), [])
        XCTAssertEqual(e.handle(.timer(t: 0.95)), [.action(.back)])
    }

    func testTripleClickIsDoubleThenPendingSingle() {
        var e = engine([b4: ButtonConfig(click: .back, doubleClick: .missionControl)])
        _ = e.handle(.down(b4, t: 0)); _ = e.handle(.up(b4, t: 0.05))
        _ = e.handle(.down(b4, t: 0.1))
        XCTAssertEqual(e.handle(.up(b4, t: 0.15)), [.action(.missionControl)])
        _ = e.handle(.down(b4, t: 0.2))
        XCTAssertEqual(e.handle(.up(b4, t: 0.25)), [])
        XCTAssertEqual(e.handle(.timer(t: 0.55)), [.action(.back)])
    }

    func testSecondPressTurningIntoHoldReturnsFirstClick() {
        var e = engine([b4: ButtonConfig(click: .back, doubleClick: .missionControl, hold: .showDesktop)])
        _ = e.handle(.down(b4, t: 0)); _ = e.handle(.up(b4, t: 0.05))
        _ = e.handle(.down(b4, t: 0.1))
        XCTAssertEqual(e.nextDeadline!, 0.4, accuracy: 1e-9)
        XCTAssertEqual(e.handle(.timer(t: 0.4)), [.action(.back), .action(.showDesktop)])
        XCTAssertEqual(e.handle(.up(b4, t: 0.5)), [])
    }

    func testSecondPressTurningIntoDragReturnsFirstClick() {
        var e = engine([b3: ButtonConfig(doubleClick: .missionControl, drag: true)])
        _ = e.handle(.down(b3, t: 0)); _ = e.handle(.up(b3, t: 0.05))
        _ = e.handle(.down(b3, t: 0.1))
        XCTAssertEqual(e.handle(.drag(b3, dx: 10, dy: 0, t: 0.12)),
                       [.passClick(b3), .dragBegan(b3), .dragMoved(dx: 10, dy: 0)])
        XCTAssertEqual(e.handle(.up(b3, t: 0.2)), [.dragEnded(b3)])
    }

    func testOtherButtonDownSettlesPendingClick() {
        var e = engine([b4: ButtonConfig(click: .back, doubleClick: .missionControl),
                        b5: ButtonConfig(click: .forward)])
        _ = e.handle(.down(b4, t: 0)); _ = e.handle(.up(b4, t: 0.05))
        XCTAssertEqual(e.handle(.down(b5, t: 0.1)), [.action(.back)])
        XCTAssertEqual(e.handle(.up(b5, t: 0.15)), [.action(.forward)])
        XCTAssertNil(e.nextDeadline)
    }

    // MARK: - nextDeadline

    func testNextDeadlineValues() {
        var e = engine([b4: ButtonConfig(click: .back, doubleClick: .missionControl, hold: .showDesktop)])
        XCTAssertNil(e.nextDeadline)
        _ = e.handle(.down(b4, t: 2))
        XCTAssertEqual(e.nextDeadline!, 2.3, accuracy: 1e-9, "hold deadline")
        _ = e.handle(.up(b4, t: 2.1))
        XCTAssertEqual(e.nextDeadline!, 2.4, accuracy: 1e-9, "double-click window end")
        _ = e.handle(.timer(t: 2.4))
        XCTAssertNil(e.nextDeadline)
    }

    func testCustomDelays() {
        var e = ButtonEngine(configs: [b4: ButtonConfig(hold: .launchpad)], holdDelay: 0.5)
        _ = e.handle(.down(b4, t: 0))
        XCTAssertEqual(e.nextDeadline!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(e.handle(.timer(t: 0.45)), [])
        XCTAssertEqual(e.handle(.timer(t: 0.5)), [.action(.launchpad)])
    }

    // MARK: - Repeated down / reset

    func testDownWhilePressedEndsPreviousDragCleanly() {
        var e = engine([b3: ButtonConfig(drag: true)])
        _ = e.handle(.down(b3, t: 0))
        _ = e.handle(.drag(b3, dx: 20, dy: 0, t: 0.05))
        XCTAssertEqual(e.handle(.down(b3, t: 0.1)), [.dragEnded(b3)], "lost up: close the old gesture")
        XCTAssertEqual(e.handle(.up(b3, t: 0.15)), [.passClick(b3)], "new press is a fresh click")
    }

    func testDownWhilePressedAfterPassDownReleases() {
        var e = engine([b3: ButtonConfig(drag: true)])
        _ = e.handle(.down(b3, t: 0))
        XCTAssertEqual(e.handle(.timer(t: 0.3)), [.passDown(b3)])
        XCTAssertEqual(e.handle(.down(b3, t: 1)), [.passUp(b3)])
    }

    func testResetDuringDragEmitsDragEnded() {
        var e = engine([b3: ButtonConfig(drag: true)])
        _ = e.handle(.down(b3, t: 0))
        _ = e.handle(.drag(b3, dx: 20, dy: 0, t: 0.05))
        XCTAssertEqual(e.reset(), [.dragEnded(b3)])
        XCTAssertEqual(e.handle(.up(b3, t: 0.1)), [], "press forgotten")
        XCTAssertEqual(e.reset(), [])
    }

    func testResetDuringScrollEmitsScrollGestureEnded() {
        var e = engine([b5: ButtonConfig(scroll: true)])
        _ = e.handle(.down(b5, t: 0))
        _ = e.handle(.scroll(b5, t: 0.05))
        XCTAssertEqual(e.reset(), [.scrollGestureEnded(b5)])
    }

    func testResetDropsPendingClickAndDeadlines() {
        var e = engine([b4: ButtonConfig(click: .back, doubleClick: .missionControl)])
        _ = e.handle(.down(b4, t: 0)); _ = e.handle(.up(b4, t: 0.05))
        XCTAssertEqual(e.reset(), [])
        XCTAssertNil(e.nextDeadline)
        XCTAssertEqual(e.handle(.timer(t: 1)), [])
    }

    func testResetHoldingPlainPress() {
        var e = engine([b4: ButtonConfig(hold: .launchpad)])
        _ = e.handle(.down(b4, t: 0))
        XCTAssertEqual(e.reset(), [])
        XCTAssertNil(e.nextDeadline)
        XCTAssertEqual(e.handle(.timer(t: 1)), [])
    }

    // MARK: - Robustness

    func testNaNDragDeltasIgnored() {
        var e = engine([b3: ButtonConfig(drag: true)])
        _ = e.handle(.down(b3, t: 0))
        XCTAssertEqual(e.handle(.drag(b3, dx: .nan, dy: 100, t: 0.01)), [])
        XCTAssertEqual(e.handle(.drag(b3, dx: .infinity, dy: 0, t: 0.02)), [])
        XCTAssertEqual(e.handle(.drag(b3, dx: 2, dy: 2, t: 0.03)), [], "NaN did not poison the offset")
        XCTAssertEqual(e.handle(.drag(b3, dx: 8, dy: 0, t: 0.04)), [.dragBegan(b3), .dragMoved(dx: 8, dy: 0)])
        XCTAssertEqual(e.handle(.drag(b3, dx: .nan, dy: .nan, t: 0.05)), [], "NaN ignored while dragging too")
        XCTAssertEqual(e.handle(.up(b3, t: 0.1)), [.dragEnded(b3)])
    }

    func testNaNAndNegativeTimesDoNotCrashOrFireEarly() {
        var e = engine([b4: ButtonConfig(click: .back, doubleClick: .missionControl, hold: .showDesktop)])
        XCTAssertEqual(e.handle(.down(b4, t: 5)), [])
        XCTAssertEqual(e.handle(.timer(t: .nan)), [])
        XCTAssertEqual(e.handle(.timer(t: -1)), [])
        XCTAssertEqual(e.handle(.timer(t: .infinity)), [], "infinite time must not trigger the hold")
        XCTAssertEqual(e.handle(.timer(t: 1)), [], "time going backwards is clamped")
        XCTAssertEqual(e.nextDeadline!, 5.3, accuracy: 1e-9)
        XCTAssertEqual(e.handle(.up(b4, t: .nan)), [], "NaN up counts as 'now' (5.0): pending first click")
        XCTAssertEqual(e.nextDeadline!, 5.3, accuracy: 1e-9)
        XCTAssertEqual(e.handle(.timer(t: 5.3)), [.action(.back)])
    }

    func testNaNDownTimeUsesLatestValidTime() {
        var e = engine([b4: ButtonConfig(hold: .launchpad)])
        _ = e.handle(.timer(t: 3))
        _ = e.handle(.down(b4, t: .nan))
        XCTAssertEqual(e.nextDeadline!, 3.3, accuracy: 1e-9)
        XCTAssertFalse(e.nextDeadline!.isNaN)
        XCTAssertEqual(e.handle(.timer(t: 3.3)), [.action(.launchpad)])
    }

    func testInvalidInitParametersFallBackToDefaults() {
        var e = ButtonEngine(configs: [b4: ButtonConfig(hold: .launchpad)],
                             holdDelay: .nan, doubleClickWindow: -1, dragThreshold: .nan)
        _ = e.handle(.down(b4, t: 0))
        XCTAssertEqual(e.nextDeadline!, 0.3, accuracy: 1e-9)
    }
}
