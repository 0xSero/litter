import XCTest
import UIKit
@testable import Litter

@MainActor
final class ConversationKeyboardWarmupTests: XCTestCase {
    func testWarmupPreservesExistingTextViewResponderAndCompletesOnce() async {
        let fixture = makeWindow()
        defer { fixture.close() }
        let userInput = UITextView(frame: CGRect(x: 0, y: 60, width: 200, height: 80))
        fixture.window.rootViewController!.view.addSubview(userInput)
        XCTAssertTrue(userInput.becomeFirstResponder())
        let completed = expectation(description: "Warmup skipped for real input")
        completed.assertForOverFulfill = true
        var completions = 0
        let coordinator = attach(to: fixture.field) {
            completions += 1
            completed.fulfill()
        }

        coordinator.primeIfNeeded()
        coordinator.primeIfNeeded()
        coordinator.cancel()
        XCTAssertTrue(userInput.isFirstResponder)
        XCTAssertFalse(fixture.field.isFirstResponder)
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(userInput.isFirstResponder)
    }

    func testWarmupPrimesWhenUnfocusedThenReleasesItsResponder() async {
        let fixture = makeWindow()
        defer { fixture.close() }
        let completed = expectation(description: "Keyboard primed")
        completed.assertForOverFulfill = true
        let coordinator = attach(to: fixture.field) { completed.fulfill() }

        coordinator.primeIfNeeded()
        XCTAssertTrue(fixture.field.isFirstResponder)
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertTrue(coordinator.isComplete)
        XCTAssertFalse(fixture.field.isFirstResponder)
        coordinator.primeIfNeeded()
        XCTAssertFalse(fixture.field.isFirstResponder)
    }

    func testCancellationBeforeQueuedPrimeCannotAcquireFocus() async {
        let fixture = makeWindow()
        defer { fixture.close() }
        let completed = expectation(description: "Cancelled warmup completed")
        completed.assertForOverFulfill = true
        let coordinator = attach(to: fixture.field) { completed.fulfill() }
        DispatchQueue.main.async { coordinator.primeIfNeeded() }

        ConversationKeyboardWarmupTextView.dismantleUIView(fixture.field, coordinator: coordinator)
        coordinator.cancel()
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertTrue(coordinator.isComplete)
        XCTAssertFalse(fixture.field.isFirstResponder)
        XCTAssertNil(fixture.field.delegate)
    }

    func testCancellationAfterPrimingDoesNotResignNewUserResponder() async {
        let fixture = makeWindow()
        defer { fixture.close() }
        let completed = expectation(description: "Cancelled active warmup completed once")
        completed.assertForOverFulfill = true
        let coordinator = attach(to: fixture.field) { completed.fulfill() }
        coordinator.primeIfNeeded()
        XCTAssertTrue(fixture.field.isFirstResponder)
        let userInput = UITextField(frame: CGRect(x: 0, y: 60, width: 200, height: 44))
        fixture.window.rootViewController!.view.addSubview(userInput)
        XCTAssertTrue(userInput.becomeFirstResponder())

        coordinator.cancel()
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertTrue(userInput.isFirstResponder)
        XCTAssertFalse(fixture.field.isFirstResponder)
    }

    private func attach(to field: UITextField, completion: @escaping () -> Void) -> ConversationKeyboardWarmupTextView.Coordinator {
        let coordinator = ConversationKeyboardWarmupTextView.Coordinator(onDidPrimeKeyboard: completion)
        coordinator.field = field
        field.delegate = coordinator
        return coordinator
    }

    private func makeWindow() -> (window: UIWindow, field: UITextField, close: () -> Void) {
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window: UIWindow
        if let scene = previous?.windowScene {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        }
        window.rootViewController = UIViewController()
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 44))
        window.rootViewController!.view.addSubview(field)
        window.makeKeyAndVisible()
        return (window, field, {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        })
    }
}
