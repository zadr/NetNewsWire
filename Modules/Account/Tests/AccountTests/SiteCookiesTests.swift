//
//  SiteCookiesTests.swift
//  AccountTests
//

import Foundation
import Testing
@testable import Account

@MainActor struct SiteCookiesTests {

	@Test func cookiesFromHeaderCoverTheWholeSite() {
		let cookies = SiteCookies.cookies(fromHeader: "session=abc; token=x=y==; empty=", host: "example.com")

		#expect(cookies.map { $0.name } == ["session", "token", "empty"])
		#expect(cookies.map { $0.value } == ["abc", "x=y==", ""])
		#expect(cookies.allSatisfy { $0.domain == ".example.com" && $0.path == "/" })
	}

	@Test func malformedPairsAreSkipped() {
		let cookies = SiteCookies.cookies(fromHeader: "session=abc; junk; =nameless", host: "example.com")

		#expect(cookies.map { $0.name } == ["session"])
	}
}
