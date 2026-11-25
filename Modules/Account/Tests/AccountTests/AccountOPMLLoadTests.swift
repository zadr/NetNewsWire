//
//  AccountOPMLLoadTests.swift
//  AccountTests
//
//  Created by Brent Simmons on 8/15/26.
//

import Foundation
import Testing
import RSParser
@testable import Account

@MainActor struct AccountOPMLLoadTests {

	private let accountManager = TestAccountManager()

	@Test func restoringOwnFileSetsNameOnly() throws {
		let account = accountManager.createAccount(type: .onMyMac)
		defer {
			accountManager.deleteAccount(account)
		}

		account.loadOPMLItems(try opmlItems(title: "Feed One"), isManualImport: false)

		let feed = try #require(account.flattenedFeeds().first)
		#expect(feed.name == "Feed One")
		#expect(feed.editedName == nil)
		#expect(feed.nameForDisplay == "Feed One")
	}

	@Test func importingSetsEditedNameSoTheTitleSurvivesRefreshes() throws {
		let account = accountManager.createAccount(type: .onMyMac)
		defer {
			accountManager.deleteAccount(account)
		}

		account.loadOPMLItems(try opmlItems(title: "My Name For It"), isManualImport: true)

		let feed = try #require(account.flattenedFeeds().first)
		#expect(feed.name == "My Name For It")
		#expect(feed.editedName == "My Name For It")
	}

	@Test func restoringOwnFileLeavesAnExistingEditedNameAlone() throws {
		let account = accountManager.createAccount(type: .onMyMac)
		defer {
			accountManager.deleteAccount(account)
		}

		// The user renamed this feed, so editedName is in the settings database already.
		account.loadOPMLItems(try opmlItems(title: "Feed One"), isManualImport: false)
		let renamedFeed = try #require(account.flattenedFeeds().first)
		renamedFeed.editedName = "My Name For It"

		// A later launch restores the file, which by then carries the edited name as its title.
		let specifier = try #require(try opmlItems(title: "My Name For It").first?.feedSpecifier)
		let restoredFeed = account.newFeed(with: specifier, isManualImport: false)

		#expect(restoredFeed.name == "My Name For It")
		#expect(restoredFeed.editedName == "My Name For It", "The rename lives in feed settings and should survive the restore.")
	}

	@Test func importingAFileWithoutFeedsThrows() async throws {
		let account = accountManager.createAccount(type: .onMyMac)
		defer {
			accountManager.deleteAccount(account)
		}

		let opml = """
		<?xml version="1.0" encoding="UTF-8"?>
		<opml version="1.1">
		<body>
		</body>
		</opml>
		"""
		let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("Empty-\(UUID().uuidString).opml")
		try opml.write(to: fileURL, atomically: true, encoding: .utf8)
		defer {
			try? FileManager.default.removeItem(at: fileURL)
		}

		await #expect(throws: AccountError.self) {
			try await account.delegate.importOPML(opmlFile: fileURL)
		}
	}

	@Test func importingAFileAddsItsFeeds() async throws {
		let account = accountManager.createAccount(type: .onMyMac)
		defer {
			accountManager.deleteAccount(account)
		}

		let opml = """
		<?xml version="1.0" encoding="UTF-8"?>
		<opml version="1.1">
		<body>
		<outline text="One" title="One" type="rss" xmlUrl="https://example.com/one.xml"/>
		<outline text="Folder" title="Folder">
		<outline text="Two" title="Two" type="rss" xmlUrl="https://example.com/two.xml"/>
		</outline>
		</body>
		</opml>
		"""
		let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("Feeds-\(UUID().uuidString).opml")
		try opml.write(to: fileURL, atomically: true, encoding: .utf8)
		defer {
			try? FileManager.default.removeItem(at: fileURL)
		}

		try await account.delegate.importOPML(opmlFile: fileURL)

		#expect(Set(account.flattenedFeeds().map { $0.url }) == ["https://example.com/one.xml", "https://example.com/two.xml"])
		#expect(account.folders?.map { $0.name } == ["Folder"])
	}

	// MARK: - Helpers

	private func opmlItems(title: String) throws -> [OPMLItem] {
		let opml = """
		<?xml version="1.0" encoding="UTF-8"?>
		<opml version="1.1">
		<body>
		<outline text="\(title)" title="\(title)" type="rss" version="RSS" htmlUrl="https://example.com/" xmlUrl="https://example.com/feed.xml"/>
		</body>
		</opml>
		"""
		let data = try #require(opml.data(using: .utf8))
		let parserData = ParserData(url: "https://example.com/subscriptions.opml", data: data)
		let document = try OPMLParser.parseOPML(with: parserData)

		return try #require(document.children)
	}
}
