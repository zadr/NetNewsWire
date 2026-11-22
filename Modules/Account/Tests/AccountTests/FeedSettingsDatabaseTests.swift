//
//  FeedSettingsDatabaseTests.swift
//  AccountTests
//
//  Created by Brent Simmons on 8/2/26.
//

import Foundation
import Testing
import SQLite3
@testable import Account

struct FeedSettingsDatabaseTests {

	@Test func feedIDColumnIsUpdatable() {
		let database = makeDatabase()
		let feedURL = "https://example.com/feed.xml"
		let canonicalFeedID = "feed/\(feedURL)"

		database.ensureFeedExists(feedURL, feedID: feedURL)
		database.setString(canonicalFeedID, for: feedURL, column: .feedID)

		#expect(database.allRows()[feedURL]?.feedID == canonicalFeedID)
	}

	@Test func ensureFeedExistsDoesNotReplaceFeedID() {
		let database = makeDatabase()
		let feedURL = "https://example.com/feed.xml"
		let canonicalFeedID = "feed/\(feedURL)"

		database.ensureFeedExists(feedURL, feedID: canonicalFeedID)
		database.ensureFeedExists(feedURL, feedID: feedURL)

		#expect(database.allRows()[feedURL]?.feedID == canonicalFeedID)
	}

	@Test func languageIsStoredAndCleared() {
		let database = makeDatabase()
		let feedURL = "https://example.com/podcast.xml"

		database.ensureFeedExists(feedURL, feedID: feedURL)
		#expect(database.allRows()[feedURL]?.language == nil)

		database.setString("de-DE", for: feedURL, column: .language)
		#expect(database.allRows()[feedURL]?.language == "de-DE")

		database.setString(nil, for: feedURL, column: .language)
		#expect(database.allRows()[feedURL]?.language == nil)
	}

	@Test func languageColumnIsAddedToExistingDatabase() throws {
		let databasePath = FileManager.default.temporaryDirectory.appendingPathComponent("FeedSettings-\(UUID().uuidString).db").path
		defer {
			try? FileManager.default.removeItem(atPath: databasePath)
		}
		let feedURL = "https://example.com/podcast.xml"

		// The table as it was before the language column.
		var connection: OpaquePointer?
		#expect(sqlite3_open(databasePath, &connection) == SQLITE_OK)
		let statements = """
		CREATE TABLE feedSettings (feedURL TEXT PRIMARY KEY, feedID TEXT NOT NULL DEFAULT '', homePageURL TEXT, iconURL TEXT, faviconURL TEXT, editedName TEXT, contentHash TEXT, newArticleNotificationsEnabled INTEGER NOT NULL DEFAULT 0, readerViewAlwaysEnabled INTEGER NOT NULL DEFAULT 0, authors TEXT, conditionalGetInfoLastModified TEXT, conditionalGetInfoEtag TEXT, conditionalGetInfoDate REAL, cacheControlInfoDateCreated REAL, cacheControlInfoMaxAge REAL, externalID TEXT, folderRelationship TEXT, lastCheckDate REAL, lastResponseCode INTEGER);
		INSERT INTO feedSettings (feedURL, feedID, editedName) VALUES ('\(feedURL)', '\(feedURL)', 'Podcast');
		"""
		#expect(sqlite3_exec(connection, statements, nil, nil, nil) == SQLITE_OK)
		sqlite3_close(connection)

		let database = FeedSettingsDatabase(databasePath: databasePath)
		let row = try #require(database.allRows()[feedURL])
		#expect(row.editedName == "Podcast")
		#expect(row.language == nil)

		database.setString("fr", for: feedURL, column: .language)
		#expect(database.allRows()[feedURL]?.language == "fr")
	}

	private func makeDatabase() -> FeedSettingsDatabase {
		FeedSettingsDatabase(databasePath: ":memory:")
	}
}
