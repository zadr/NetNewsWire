//
//  SmartFiltersView.swift
//  NetNewsWire-iOS
//

import SwiftUI
import Account

/// Edits a feed’s smart filters: rules that mark new articles as read, or star them, when they arrive.
/// The iOS counterpart of the Mac’s predicate editor: each action has a group of conditions
/// that all, any, or none must match.
struct SmartFiltersView: View {

	let feed: Feed
	@State private var sections: [EditableSmartFilter]

	init(feed: Feed) {
		self.feed = feed
		_sections = State(initialValue: SmartFilter.Action.allCases.map { action in
			EditableSmartFilter(action: action, filter: feed.smartFilters.first { $0.action == action })
		})
	}

	var body: some View {
		List {
			ForEach($sections) { $section in
				SmartFilterSectionView(section: $section)
			}
		}
		.navigationTitle(String(localized: "Smart Filters", comment: "Smart filters screen title"))
		.navigationBarTitleDisplayMode(.inline)
		.onChange(of: sections) {
			save()
		}
	}

	private func save() {
		let filters = sections.compactMap { $0.smartFilter }
		let shownActions = Set(sections.map { $0.action })
		feed.smartFilters = feed.smartFilters.filter { !shownActions.contains($0.action) } + filters
	}
}

// MARK: - Section

private struct SmartFilterSectionView: View {

	@Binding var section: EditableSmartFilter

	var body: some View {
		Section {
			Toggle(toggleTitle, isOn: $section.isEnabled)

			if section.isEnabled {
				Picker(String(localized: "Match", comment: "Smart filter match picker"), selection: $section.match) {
					Text(String(localized: "All Conditions", comment: "Smart filter match")).tag(SmartFilterMatch.all)
					Text(String(localized: "Any Condition", comment: "Smart filter match")).tag(SmartFilterMatch.any)
					Text(String(localized: "No Conditions", comment: "Smart filter match")).tag(SmartFilterMatch.none)
				}

				ForEach($section.items) { $item in
					SmartFilterItemView(item: $item)
				}
				.onDelete { offsets in
					section.items.remove(atOffsets: offsets)
				}

				Button {
					section.items.append(EditableSmartFilter.Item(rule: .condition(SmartFilterCondition(field: .title, comparison: .contains, value: ""))))
				} label: {
					Label(String(localized: "Add Condition", comment: "Smart filter button"), systemImage: "plus.circle")
				}
			}
		} footer: {
			Text(footerText)
		}
	}

	private var toggleTitle: String {
		switch section.action {
		case .markAsRead:
			return String(localized: "Mark New Articles as Read", comment: "Smart filter toggle")
		case .star:
			return String(localized: "Star New Articles", comment: "Smart filter toggle")
		}
	}

	private var footerText: String {
		switch section.action {
		case .markAsRead:
			return String(localized: "New articles from this feed that match are marked as read when they arrive. Comparisons ignore case.", comment: "Smart filter footer")
		case .star:
			return String(localized: "New articles from this feed that match are starred when they arrive. Comparisons ignore case.", comment: "Smart filter footer")
		}
	}
}

// MARK: - Condition

private struct SmartFilterItemView: View {

	@Binding var item: EditableSmartFilter.Item

	var body: some View {
		switch item.rule {
		case .condition(let condition):
			SmartFilterConditionView(condition: Binding(get: { condition }, set: { item.rule = .condition($0) }))
		case .group(_, let rules):
			// Only made by editing on another platform; smart filters on iOS edit one level of conditions.
			Text(String(format: String(localized: "Group of %ld conditions", comment: "Smart filter nested group"), rules.count))
				.foregroundStyle(.secondary)
		}
	}
}

private struct SmartFilterConditionView: View {

	@Binding var condition: SmartFilterCondition

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Picker(String(localized: "Field", comment: "Smart filter field picker"), selection: $condition.field) {
					ForEach(SmartFilterField.allCases, id: \.self) { field in
						Text(field.displayName).tag(field)
					}
				}
				Picker(String(localized: "Comparison", comment: "Smart filter comparison picker"), selection: $condition.comparison) {
					ForEach(SmartFilterComparison.allCases, id: \.self) { comparison in
						Text(comparison.displayName).tag(comparison)
					}
				}
			}
			.labelsHidden()
			.pickerStyle(.menu)

			TextField(String(localized: "Value", comment: "Smart filter value placeholder"), text: $condition.value)
				.textFieldStyle(.roundedBorder)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()

			if !SmartFilterRule.condition(condition).invalidRegexPatterns.isEmpty {
				Text(String(localized: "Not a valid regular expression. This condition won’t match.", comment: "Smart filter regex error"))
					.font(.footnote)
					.foregroundStyle(.red)
			}
		}
		.padding(.vertical, 4)
	}
}

// MARK: - EditableSmartFilter

/// One action’s filter as edited here: a top-level group whose rules have identities for the list.
private struct EditableSmartFilter: Identifiable, Equatable {

	struct Item: Identifiable, Equatable {
		let id = UUID()
		var rule: SmartFilterRule
	}

	let action: SmartFilter.Action
	var isEnabled: Bool
	var match: SmartFilterMatch
	var items: [Item]

	var id: SmartFilter.Action {
		action
	}

	init(action: SmartFilter.Action, filter: SmartFilter?) {
		self.action = action
		self.isEnabled = filter?.isEnabled ?? false

		switch filter?.rule {
		case .group(let match, let rules):
			self.match = match
			self.items = rules.map { Item(rule: $0) }
		case .condition(let condition):
			self.match = .all
			self.items = [Item(rule: .condition(condition))]
		case nil:
			self.match = .all
			self.items = [Item(rule: .condition(SmartFilterCondition(field: .title, comparison: .contains, value: "")))]
		}
	}

	/// Nil when there’s nothing worth keeping: turned off, with no conditions.
	var smartFilter: SmartFilter? {
		let rule = SmartFilterRule.group(match, items.map { $0.rule })
		guard isEnabled || rule.hasConditions else {
			return nil
		}
		return SmartFilter(action: action, isEnabled: isEnabled, rule: rule)
	}
}
