//
//  SmartFilter.swift
//  Account
//

import Foundation
import RSCore
import Articles

/// A per-feed rule that marks new articles as read, or stars them, when they arrive.
public struct SmartFilter: Codable, Hashable, Sendable {

	public enum Action: String, Codable, CaseIterable, Sendable {
		case markAsRead
		case star

		public var statusKey: ArticleStatus.Key {
			switch self {
			case .markAsRead:
				return .read
			case .star:
				return .starred
			}
		}
	}

	public var action: Action
	public var isEnabled: Bool
	public var rule: SmartFilterRule

	public init(action: Action, isEnabled: Bool = true, rule: SmartFilterRule) {
		self.action = action
		self.isEnabled = isEnabled
		self.rule = rule
	}
}

/// An article attribute a smart filter condition looks at.
/// The raw value is the key path used in `NSPredicate`s.
public enum SmartFilterField: String, Codable, CaseIterable, Sendable {
	case title
	case author
	case content
	case summary
	case link
	case externalLink
	case enclosureURL
	case enclosureType

	public var displayName: String {
		switch self {
		case .title:
			return NSLocalizedString("Title", comment: "Smart filter field")
		case .author:
			return NSLocalizedString("Author", comment: "Smart filter field")
		case .content:
			return NSLocalizedString("Content", comment: "Smart filter field")
		case .summary:
			return NSLocalizedString("Summary", comment: "Smart filter field")
		case .link:
			return NSLocalizedString("Link", comment: "Smart filter field")
		case .externalLink:
			return NSLocalizedString("External Link", comment: "Smart filter field")
		case .enclosureURL:
			return NSLocalizedString("Enclosure URL", comment: "Smart filter field")
		case .enclosureType:
			return NSLocalizedString("Enclosure Type", comment: "Smart filter field")
		}
	}
}

/// How a condition compares a field to its value. Comparisons ignore case and diacritics.
public enum SmartFilterComparison: String, Codable, CaseIterable, Sendable {
	case contains
	case beginsWith
	case endsWith
	case isEqual
	case isNotEqual
	/// A regular expression found anywhere in the field.
	case matchesRegex

	public var displayName: String {
		switch self {
		case .contains:
			return NSLocalizedString("contains", comment: "Smart filter comparison")
		case .beginsWith:
			return NSLocalizedString("begins with", comment: "Smart filter comparison")
		case .endsWith:
			return NSLocalizedString("ends with", comment: "Smart filter comparison")
		case .isEqual:
			return NSLocalizedString("is", comment: "Smart filter comparison")
		case .isNotEqual:
			return NSLocalizedString("is not", comment: "Smart filter comparison")
		case .matchesRegex:
			return NSLocalizedString("matches regex", comment: "Smart filter comparison")
		}
	}
}

/// Whether a group of conditions needs all, any, or none of them to be true.
public enum SmartFilterMatch: String, Codable, CaseIterable, Sendable {
	case all
	case any
	case none
}

public struct SmartFilterCondition: Codable, Hashable, Sendable {
	public var field: SmartFilterField
	public var comparison: SmartFilterComparison
	public var value: String

	public init(field: SmartFilterField, comparison: SmartFilterComparison, value: String) {
		self.field = field
		self.comparison = comparison
		self.value = value
	}
}

public indirect enum SmartFilterRule: Codable, Hashable, Sendable {
	case group(SmartFilterMatch, [SmartFilterRule])
	case condition(SmartFilterCondition)

	public static let empty = SmartFilterRule.group(.all, [])

	/// True when the rule has at least one condition with a value. Rules without one never match.
	public var hasConditions: Bool {
		switch self {
		case .group(_, let rules):
			return rules.contains { $0.hasConditions }
		case .condition(let condition):
			return !condition.value.isEmpty
		}
	}

	/// Regex values that aren’t valid regular expressions. Conditions with them never match.
	public var invalidRegexPatterns: [String] {
		switch self {
		case .group(_, let rules):
			return rules.flatMap { $0.invalidRegexPatterns }
		case .condition(let condition):
			guard condition.comparison == .matchesRegex, !condition.value.isEmpty, (try? NSRegularExpression(pattern: condition.value)) == nil else {
				return []
			}
			return [condition.value]
		}
	}
}

// MARK: - Matching

public extension SmartFilterRule {

	/// Field values are lists, since an article can have several authors or enclosures.
	/// A positive comparison is true when any value satisfies it; `isNotEqual` when none is equal.
	func matches(_ values: [SmartFilterField: [String]]) -> Bool {
		switch self {
		case .group(let match, let rules):
			let rules = rules.filter { $0.hasConditions }
			guard !rules.isEmpty else {
				return false
			}
			switch match {
			case .all:
				return rules.allSatisfy { $0.matches(values) }
			case .any:
				return rules.contains { $0.matches(values) }
			case .none:
				return !rules.contains { $0.matches(values) }
			}
		case .condition(let condition):
			return condition.matches(values[condition.field] ?? [])
		}
	}
}

extension SmartFilterCondition {

	func matches(_ fieldValues: [String]) -> Bool {
		guard !value.isEmpty else {
			return false
		}
		let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

		switch comparison {
		case .contains:
			return fieldValues.contains { $0.range(of: value, options: options) != nil }
		case .beginsWith:
			return fieldValues.contains { $0.range(of: value, options: options.union(.anchored)) != nil }
		case .endsWith:
			return fieldValues.contains { $0.range(of: value, options: options.union([.anchored, .backwards])) != nil }
		case .isEqual:
			return fieldValues.contains { $0.compare(value, options: options) == .orderedSame }
		case .isNotEqual:
			return !fieldValues.contains { $0.compare(value, options: options) == .orderedSame }
		case .matchesRegex:
			guard let regex = try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) else {
				return false
			}
			return fieldValues.contains { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
		}
	}
}

public extension SmartFilterField {

	@MainActor static func values(for article: Article, feed: Feed?) -> [SmartFilterField: [String]] {
		let authors = article.authors ?? feed?.authors ?? []
		let attachments = article.attachments ?? []

		var content = [String]()
		if let contentHTML = article.contentHTML {
			content.append(contentHTML.strippingHTML())
		}
		if let contentText = article.contentText {
			content.append(contentText)
		}
		if let markdown = article.markdown {
			content.append(markdown)
		}

		return [
			.title: [article.title].compactMap { $0 },
			.author: authors.compactMap { $0.name ?? $0.emailAddress },
			.content: content,
			.summary: [article.summary].compactMap { $0 },
			.link: [article.rawLink].compactMap { $0 },
			.externalLink: [article.rawExternalLink].compactMap { $0 },
			.enclosureURL: attachments.map { $0.url },
			.enclosureType: attachments.compactMap { $0.mimeType }
		]
	}
}

// MARK: - NSPredicate

/// Smart filters are stored and evaluated as `SmartFilterRule`s.
/// `NSPredicate` is how they’re shown in `NSPredicateEditor`.
public extension SmartFilterRule {

	var predicate: NSPredicate {
		switch self {
		case .group(let match, let rules):
			let subpredicates = rules.map { $0.predicate }
			switch match {
			case .all:
				return NSCompoundPredicate(andPredicateWithSubpredicates: subpredicates)
			case .any:
				return NSCompoundPredicate(orPredicateWithSubpredicates: subpredicates)
			case .none:
				// The form NSPredicateEditor uses for “None of the following are true”.
				return NSCompoundPredicate(notPredicateWithSubpredicate: NSCompoundPredicate(orPredicateWithSubpredicates: subpredicates))
			}
		case .condition(let condition):
			return NSComparisonPredicate(
				leftExpression: NSExpression(forKeyPath: condition.field.rawValue),
				rightExpression: NSExpression(forConstantValue: condition.value),
				modifier: .direct,
				type: condition.comparison.predicateOperator,
				options: [.caseInsensitive, .diacriticInsensitive]
			)
		}
	}

	/// Nil when the predicate uses a key path, operator, or value smart filters don’t support.
	init?(predicate: NSPredicate) {
		if let compound = predicate as? NSCompoundPredicate {
			guard let subpredicates = compound.subpredicates as? [NSPredicate] else {
				return nil
			}
			let match: SmartFilterMatch
			var children = subpredicates
			switch compound.compoundPredicateType {
			case .and:
				match = .all
			case .or:
				match = .any
			case .not:
				match = .none
				// NOT(OR(a, b)) is “none of a, b”.
				if children.count == 1, let inner = children.first as? NSCompoundPredicate, inner.compoundPredicateType == .or, let innerSubpredicates = inner.subpredicates as? [NSPredicate] {
					children = innerSubpredicates
				}
			@unknown default:
				return nil
			}
			var rules = [SmartFilterRule]()
			for child in children {
				guard let rule = SmartFilterRule(predicate: child) else {
					return nil
				}
				rules.append(rule)
			}
			self = .group(match, rules)
			return
		}

		guard let comparison = predicate as? NSComparisonPredicate,
			  comparison.leftExpression.expressionType == .keyPath,
			  let field = SmartFilterField(rawValue: comparison.leftExpression.keyPath),
			  let filterComparison = SmartFilterComparison(predicateOperator: comparison.predicateOperatorType),
			  comparison.rightExpression.expressionType == .constantValue else {
			return nil
		}
		let value = comparison.rightExpression.constantValue as? String ?? ""
		self = .condition(SmartFilterCondition(field: field, comparison: filterComparison, value: value))
	}
}

public extension SmartFilterComparison {

	var predicateOperator: NSComparisonPredicate.Operator {
		switch self {
		case .contains:
			return .contains
		case .beginsWith:
			return .beginsWith
		case .endsWith:
			return .endsWith
		case .isEqual:
			return .equalTo
		case .isNotEqual:
			return .notEqualTo
		case .matchesRegex:
			return .matches
		}
	}

	init?(predicateOperator: NSComparisonPredicate.Operator) {
		guard let comparison = Self.allCases.first(where: { $0.predicateOperator == predicateOperator }) else {
			return nil
		}
		self = comparison
	}
}
