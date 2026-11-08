// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsFormFailurePopupTests.swift
//  RivuletTests
//
//  A Settings form that fails says so in the app's popup card with one OK
//  button, not in a row under the button.
//

import XCTest
@testable import Rivulet

@MainActor
final class SettingsFormFailurePopupTests: XCTestCase {
    private func focusableViews(in view: UIView) -> Int {
        view.subviews.reduce(view.canBecomeFocused ? 1 : 0) { $0 + focusableViews(in: $1) }
    }

    func test_popupWithoutCancelTitle_hasOneButton() {
        let popup = ConfirmationPopupViewController(title: "Couldn't Sign In", message: "Something failed.",
                                                    confirmTitle: "OK", cancelTitle: nil, onConfirm: {})
        popup.loadViewIfNeeded()
        XCTAssertEqual(focusableViews(in: popup.view), 1)
    }
}
