//
//  SmartFiltersWindowController.swift
//  NetNewsWire
//

import AppKit
import Account

/// Edits a feed’s smart filters: rules that mark new articles as read, or star them, when they arrive.
/// Each action has one rule, edited with an `NSPredicateEditor`.
@MainActor final class SmartFiltersWindowController: NSWindowController {

	private static var openControllers = Set<SmartFiltersWindowController>()

	private let feed: Feed
	private var sections = [SmartFilterSection]()

	static func show(for feed: Feed) {
		if let existing = openControllers.first(where: { $0.feed == feed }) {
			existing.showWindow(nil)
			return
		}
		let controller = SmartFiltersWindowController(feed: feed)
		openControllers.insert(controller)
		controller.showWindow(nil)
	}

	private init(feed: Feed) {
		self.feed = feed

		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
		window.title = String(format: NSLocalizedString("Smart Filters for %@", comment: "Smart filters window title"), feed.nameForDisplay)
		window.isReleasedWhenClosed = false
		window.minSize = NSSize(width: 560, height: 420)

		super.init(window: window)

		window.delegate = self
		window.contentView = makeContentView()
		window.center()
		window.setFrameAutosaveName("SmartFiltersWindow")
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	// MARK: - Actions

	@objc func save(_ sender: Any?) {
		var filters = [SmartFilter]()
		for section in sections {
			guard let rule = section.rule else {
				showUnsupportedRuleError()
				return
			}
			if let pattern = rule.invalidRegexPatterns.first {
				showInvalidRegexError(pattern)
				return
			}
			if section.isEnabled || rule.hasConditions {
				filters.append(SmartFilter(action: section.action, isEnabled: section.isEnabled, rule: rule))
			}
		}

		// Keep filters for actions this window doesn’t show.
		let shownActions = Set(sections.map { $0.action })
		feed.smartFilters = feed.smartFilters.filter { !shownActions.contains($0.action) } + filters
		close()
	}

	@objc func cancel(_ sender: Any?) {
		close()
	}
}

extension SmartFiltersWindowController: NSWindowDelegate {

	func windowWillClose(_ notification: Notification) {
		Self.openControllers.remove(self)
	}
}

private extension SmartFiltersWindowController {

	func makeContentView() -> NSView {
		let explanation = NSTextField(wrappingLabelWithString: NSLocalizedString("Smart filters act on new articles from this feed when they arrive. Comparisons ignore case.", comment: "Smart filters window explanation"))
		explanation.textColor = .secondaryLabelColor

		let stackView = NSStackView(views: [explanation])
		stackView.orientation = .vertical
		stackView.alignment = .leading
		stackView.spacing = 8
		stackView.translatesAutoresizingMaskIntoConstraints = false

		for action in SmartFilter.Action.allCases {
			let filter = feed.smartFilters.first { $0.action == action }
			let section = SmartFilterSection(action: action, filter: filter)
			sections.append(section)
			stackView.addArrangedSubview(section.checkBox)
			stackView.setCustomSpacing(6, after: section.checkBox)
			stackView.addArrangedSubview(section.scrollView)
			stackView.setCustomSpacing(16, after: section.scrollView)
			section.scrollView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
		}
		if let first = sections.first?.scrollView {
			for section in sections.dropFirst() {
				section.scrollView.heightAnchor.constraint(equalTo: first.heightAnchor).isActive = true
			}
		}

		let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: "Cancel button"), target: self, action: #selector(cancel(_:)))
		cancelButton.keyEquivalent = "\u{1b}"
		let saveButton = NSButton(title: NSLocalizedString("Save", comment: "Save button"), target: self, action: #selector(save(_:)))
		saveButton.keyEquivalent = "\r"
		let buttons = NSStackView(views: [cancelButton, saveButton])
		buttons.spacing = 12
		buttons.translatesAutoresizingMaskIntoConstraints = false

		let contentView = NSView()
		contentView.addSubview(stackView)
		contentView.addSubview(buttons)
		NSLayoutConstraint.activate([
			stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
			stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
			stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
			buttons.topAnchor.constraint(equalTo: stackView.bottomAnchor, constant: 4),
			buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
			buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
		])
		return contentView
	}

	func showUnsupportedRuleError() {
		guard let window else {
			return
		}
		let alert = NSAlert()
		alert.messageText = NSLocalizedString("Can’t Save Smart Filters", comment: "Smart filters error")
		alert.informativeText = NSLocalizedString("A rule uses a comparison that smart filters don’t support.", comment: "Smart filters error")
		alert.beginSheetModal(for: window)
	}

	func showInvalidRegexError(_ pattern: String) {
		guard let window else {
			return
		}
		let alert = NSAlert()
		alert.messageText = NSLocalizedString("Invalid Regular Expression", comment: "Smart filters error")
		alert.informativeText = String(format: NSLocalizedString("“%@” isn’t a valid regular expression.", comment: "Smart filters error"), pattern)
		alert.beginSheetModal(for: window)
	}
}

// MARK: - SmartFilterSection

/// A checkbox that turns an action on and off, and a predicate editor for its rule.
@MainActor private final class SmartFilterSection {

	let action: SmartFilter.Action
	let checkBox: NSButton
	let scrollView = NSScrollView()
	private let predicateEditor = NSPredicateEditor()

	var isEnabled: Bool {
		checkBox.state == .on
	}

	/// Nil when the editor’s predicate can’t be a smart filter rule.
	var rule: SmartFilterRule? {
		guard let predicate = predicateEditor.objectValue as? NSPredicate else {
			return .empty
		}
		return SmartFilterRule(predicate: predicate)
	}

	init(action: SmartFilter.Action, filter: SmartFilter?) {
		self.action = action

		let title: String
		switch action {
		case .markAsRead:
			title = NSLocalizedString("Mark as read new articles that match:", comment: "Smart filters checkbox")
		case .star:
			title = NSLocalizedString("Star new articles that match:", comment: "Smart filters checkbox")
		}
		checkBox = NSButton(checkboxWithTitle: title, target: nil, action: nil)
		checkBox.state = (filter?.isEnabled ?? false) ? .on : .off

		predicateEditor.rowTemplates = [
			NSPredicateEditorRowTemplate(compoundTypes: [
				NSNumber(value: NSCompoundPredicate.LogicalType.and.rawValue),
				NSNumber(value: NSCompoundPredicate.LogicalType.or.rawValue),
				NSNumber(value: NSCompoundPredicate.LogicalType.not.rawValue)
			]),
			SmartFilterRowTemplate()
		]
		predicateEditor.canRemoveAllRows = false
		predicateEditor.objectValue = Self.editablePredicate(for: filter?.rule)
		predicateEditor.autoresizingMask = [.width]

		scrollView.documentView = predicateEditor
		scrollView.hasVerticalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.borderType = .bezelBorder
		scrollView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
		predicateEditor.frame.size.width = scrollView.contentSize.width
	}

	/// The editor needs a group at the top, and a condition row is a friendlier start than an empty group.
	private static func editablePredicate(for rule: SmartFilterRule?) -> NSPredicate {
		let starterCondition = SmartFilterRule.condition(SmartFilterCondition(field: .title, comparison: .contains, value: ""))
		switch rule {
		case .group(let match, let rules) where !rules.isEmpty:
			return SmartFilterRule.group(match, rules).predicate
		case .condition(let condition):
			return SmartFilterRule.group(.all, [.condition(condition)]).predicate
		default:
			return SmartFilterRule.group(.all, [starterCondition]).predicate
		}
	}
}

// MARK: - SmartFilterRowTemplate

/// A row comparing an article field to text, with field and comparison names for display.
private final class SmartFilterRowTemplate: NSPredicateEditorRowTemplate {

	override convenience init() {
		let options: NSComparisonPredicate.Options = [.caseInsensitive, .diacriticInsensitive]
		self.init(
			leftExpressions: SmartFilterField.allCases.map { NSExpression(forKeyPath: $0.rawValue) },
			rightExpressionAttributeType: .stringAttributeType,
			modifier: .direct,
			operators: SmartFilterComparison.allCases.map { NSNumber(value: $0.predicateOperator.rawValue) },
			options: Int(options.rawValue)
		)
	}

	override var templateViews: [NSView] {
		let views = super.templateViews
		// NSPredicateEditor asks for views on the main thread.
		MainActor.assumeIsolated {
			for view in views {
				if let popUpButton = view as? NSPopUpButton {
					for item in popUpButton.itemArray {
						if let expression = item.representedObject as? NSExpression, expression.expressionType == .keyPath, let field = SmartFilterField(rawValue: expression.keyPath) {
							item.title = field.displayName
						} else if let number = item.representedObject as? NSNumber, let predicateOperator = NSComparisonPredicate.Operator(rawValue: number.uintValue), let comparison = SmartFilterComparison(predicateOperator: predicateOperator) {
							item.title = comparison.displayName
						}
					}
				} else if let textField = view as? NSTextField {
					textField.frame.size.width = 240
				}
			}
		}
		return views
	}
}
