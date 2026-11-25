//
//  SmartFilterApplyTests.swift
//  AccountTests
//

import Foundation
import Testing
import RSParser
import Articles
@testable import Account

@MainActor struct SmartFilterApplyTests {

	@Test func newArticlesAreMarkedAsReadAndStarred() async throws {
		let account = TestAccountManager.shared.createAccount(type: .onMyMac)
		defer {
			TestAccountManager.shared.deleteAccount(account)
		}

		let feedURL = "https://example.com/feed.xml"
		let feed = account.createFeed(with: "Example", url: feedURL, feedID: feedURL, homePageURL: nil)
		account.addFeedToTreeAtTopLevel(feed)
		feed.smartFilters = [
			SmartFilter(action: .markAsRead, rule: .group(.any, [.condition(SmartFilterCondition(field: .title, comparison: .beginsWith, value: "Sponsored"))])),
			SmartFilter(action: .star, rule: .group(.all, [.condition(SmartFilterCondition(field: .author, comparison: .isEqual, value: "Jane Doe"))])),
			SmartFilter(action: .star, isEnabled: false, rule: .group(.all, [.condition(SmartFilterCondition(field: .title, comparison: .contains, value: "news"))]))
		]

		let items: Set<ParsedItem> = [
			parsedItem(uniqueID: "sponsored", feedURL: feedURL, title: "Sponsored: Buy Things", author: nil),
			parsedItem(uniqueID: "jane", feedURL: feedURL, title: "Weekly News", author: "Jane Doe"),
			parsedItem(uniqueID: "other", feedURL: feedURL, title: "Other News", author: "John Smith")
		]

		let changes = await account.updateAsync(feedID: feed.feedID, parsedItems: items, deleteOlder: false)
		let newArticles = try #require(changes.new)
		#expect(newArticles.count == 3)

		let articleID = { (uniqueID: String) in
			Article.calculatedArticleID(feedID: feedURL, uniqueID: uniqueID)
		}

		let unreadArticleIDs = await account.fetchUnreadArticleIDsAsync()
		#expect(unreadArticleIDs == [articleID("jane"), articleID("other")])

		let starredArticleIDs = await account.fetchStarredArticleIDsAsync()
		#expect(starredArticleIDs == [articleID("jane")])

		// New-article notifications see the statuses the filters set.
		let sponsored = try #require(newArticles.first { $0.uniqueID == "sponsored" })
		#expect(sponsored.status.read)
	}

	private func parsedItem(uniqueID: String, feedURL: String, title: String, author: String?) -> ParsedItem {
		let authors: Set<ParsedAuthor>? = author.map { [ParsedAuthor(name: $0, url: nil, avatarURL: nil, emailAddress: nil)] }
		return ParsedItem(syncServiceID: nil, uniqueID: uniqueID, feedURL: feedURL, url: nil, externalURL: nil, title: title, language: nil, contentHTML: "<p>Body</p>", contentText: nil, markdown: nil, summary: nil, imageURL: nil, thumbnailURL: nil, bannerImageURL: nil, datePublished: Date(), dateModified: nil, authors: authors, tags: nil, attachments: nil)
	}
}
