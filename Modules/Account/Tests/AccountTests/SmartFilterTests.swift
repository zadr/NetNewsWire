//
//  SmartFilterTests.swift
//  AccountTests
//

import Foundation
import Testing
@testable import Account

struct SmartFilterTests {

	private let values: [SmartFilterField: [String]] = [
		.title: ["Sponsored: The Best Café Gadgets"],
		.author: ["Jane Doe", "John Smith"],
		.content: ["A review of espresso machines."],
		.link: ["https://example.com/2026/sponsored-post"],
		.enclosureType: []
	]

	private func condition(_ field: SmartFilterField, _ comparison: SmartFilterComparison, _ value: String) -> SmartFilterRule {
		.condition(SmartFilterCondition(field: field, comparison: comparison, value: value))
	}

	// MARK: - Comparisons

	@Test func comparisonsIgnoreCaseAndDiacritics() {
		#expect(condition(.title, .contains, "cafe").matches(values))
		#expect(condition(.title, .beginsWith, "SPONSORED").matches(values))
		#expect(condition(.title, .endsWith, "gadgets").matches(values))
		#expect(condition(.author, .isEqual, "jane doe").matches(values))
		#expect(!condition(.title, .beginsWith, "best").matches(values))
		#expect(!condition(.title, .endsWith, "sponsored").matches(values))
	}

	@Test func multipleValuesMatchIfAnyDoes() {
		#expect(condition(.author, .isEqual, "John Smith").matches(values))
		#expect(!condition(.author, .isNotEqual, "John Smith").matches(values))
		#expect(condition(.author, .isNotEqual, "Someone Else").matches(values))
	}

	@Test func missingValues() {
		#expect(!condition(.summary, .contains, "anything").matches(values))
		#expect(condition(.enclosureType, .isNotEqual, "audio/mpeg").matches(values))
	}

	@Test func regexMatchesAnywhereAndInvalidRegexDoesNotMatch() {
		#expect(condition(.link, .matchesRegex, "/20[0-9]{2}/sponsored").matches(values))
		#expect(!condition(.link, .matchesRegex, "^/sponsored").matches(values))
		#expect(!condition(.title, .matchesRegex, "(unclosed").matches(values))
	}

	@Test func emptyValuesNeverMatch() {
		#expect(!condition(.title, .contains, "").matches(values))
		#expect(!SmartFilterRule.empty.matches(values))
		#expect(!SmartFilterRule.group(.none, [condition(.title, .contains, "")]).matches(values))
		#expect(!SmartFilterRule.group(.all, [.group(.any, [])]).matches(values))
	}

	// MARK: - Groups

	@Test func groups() {
		let sponsored = condition(.title, .contains, "sponsored")
		let podcast = condition(.title, .contains, "podcast")

		#expect(SmartFilterRule.group(.any, [sponsored, podcast]).matches(values))
		#expect(!SmartFilterRule.group(.all, [sponsored, podcast]).matches(values))
		#expect(SmartFilterRule.group(.none, [podcast]).matches(values))
		#expect(!SmartFilterRule.group(.none, [sponsored, podcast]).matches(values))
		#expect(SmartFilterRule.group(.all, [sponsored, .group(.none, [podcast])]).matches(values))
	}

	@Test func groupIgnoresConditionsWithoutValues() {
		let rule = SmartFilterRule.group(.all, [condition(.title, .contains, "sponsored"), condition(.author, .isEqual, "")])
		#expect(rule.matches(values))
	}

	// MARK: - NSPredicate

	@Test func predicateRoundTrip() throws {
		let rule = SmartFilterRule.group(.all, [
			condition(.title, .contains, "sponsored"),
			.group(.none, [condition(.author, .isEqual, "Jane \"JD\" Doe"), condition(.link, .matchesRegex, "^https?://")]),
			.group(.any, [condition(.enclosureType, .beginsWith, "audio/"), condition(.content, .endsWith, ".")])
		])

		let predicate = rule.predicate
		#expect(try #require(SmartFilterRule(predicate: predicate)) == rule)

		let reparsed = NSPredicate(format: predicate.predicateFormat)
		#expect(try #require(SmartFilterRule(predicate: reparsed)) == rule)
	}

	@Test func predicateNotWithSeveralSubpredicatesIsNone() throws {
		let predicate = NSCompoundPredicate(type: .not, subpredicates: [
			NSPredicate(format: "title CONTAINS[cd] 'a'"),
			NSPredicate(format: "title CONTAINS[cd] 'b'")
		])
		let expected = SmartFilterRule.group(.none, [condition(.title, .contains, "a"), condition(.title, .contains, "b")])
		#expect(try #require(SmartFilterRule(predicate: predicate)) == expected)
	}

	@Test func unsupportedPredicatesAreRejected() {
		#expect(SmartFilterRule(predicate: NSPredicate(format: "unknownField CONTAINS 'a'")) == nil)
		#expect(SmartFilterRule(predicate: NSPredicate(format: "title LIKE 'a*'")) == nil)
		#expect(SmartFilterRule(predicate: NSPredicate(format: "title == author")) == nil)
	}

	// MARK: - Storage

	@Test func codableRoundTrip() throws {
		let filters = [
			SmartFilter(action: .markAsRead, rule: .group(.any, [condition(.title, .contains, "sponsored")])),
			SmartFilter(action: .star, isEnabled: false, rule: .group(.all, [condition(.author, .isEqual, "Jane Doe")]))
		]
		let data = try JSONEncoder().encode(filters)
		#expect(try JSONDecoder().decode([SmartFilter].self, from: data) == filters)
	}

	@Test func smartFiltersAreStoredAndCleared() {
		let database = FeedSettingsDatabase(databasePath: ":memory:")
		let feedURL = "https://example.com/feed.xml"
		let filters = [SmartFilter(action: .star, rule: .group(.all, [condition(.title, .contains, "release notes")]))]

		database.ensureFeedExists(feedURL, feedID: feedURL)
		#expect(database.allRows()[feedURL]?.smartFilters == nil)

		database.setSmartFilters(filters, for: feedURL)
		#expect(database.allRows()[feedURL]?.smartFilters == filters)

		database.setSmartFilters([], for: feedURL)
		#expect(database.allRows()[feedURL]?.smartFilters == nil)
	}
}
