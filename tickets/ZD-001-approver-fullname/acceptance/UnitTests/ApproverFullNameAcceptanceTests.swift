//
//  ApproverFullNameAcceptanceTests.swift
//  HIDDEN acceptance suite for ZD-001 — overlaid into ZohoDeskUnitTests by the
//  scorer AFTER the agent finishes. The agent never sees this file.
//
//  Uses the existing ApproverBuilder so it is not coupled to any new API.
//

import XCTest
@testable import ZohoDesk

final class ApproverFullNameAcceptanceTests: XCTestCase {

    // AC-001 — joins first + last with a single space.
    func test_AC001_joinsFirstAndLast() {
        let a = ApproverBuilder().make()
            .with(firstName: "Anbu")
            .with(lastName: "D")
            .build()
        XCTAssertEqual(a.fullName, "Anbu D")
    }

    // AC-002 — collapses internal whitespace; no double spaces.
    func test_AC002_collapsesInternalWhitespace() {
        let a = ApproverBuilder().make()
            .with(firstName: "John ")
            .with(lastName: " Doe")
            .build()
        XCTAssertEqual(a.fullName, "John Doe")
        XCTAssertFalse(a.fullName.contains("  "), "fullName must not contain a double space")
    }

    // AC-003 — whitespace-only / empty parts treated as missing.
    func test_AC003_whitespaceOnlyTreatedAsMissing() {
        let a = ApproverBuilder().make()
            .with(firstName: "   ")
            .with(lastName: "Doe")
            .build()
        XCTAssertEqual(a.fullName, "Doe")
    }

    // AC-004 — both parts missing → empty string.
    func test_AC004_bothMissingIsEmpty() {
        let a = ApproverBuilder().make()
            .with(firstName: "")
            .with(lastName: nil)
            .build()
        XCTAssertEqual(a.fullName, "")
    }
}
