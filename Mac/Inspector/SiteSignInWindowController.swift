//
//  SiteSignInWindowController.swift
//  NetNewsWire
//

import AppKit
import WebKit
import RSCore
import Account

/// A browser window for signing in to a site whose feeds are truncated
/// for signed-out readers. The resulting cookies go to `SiteCookies`.
///
/// Uses a non-persistent data store, so the sign-in is isolated from
/// other web views, and the stored cookies are the only record of it.
@MainActor final class SiteSignInWindowController: NSWindowController {

	private static var openControllers = Set<SiteSignInWindowController>()

	private let siteURL: URL
	private let host: String
	private let webView: WKWebView
	private let addressField = NSTextField()
	private var observation: NSKeyValueObservation?

	static func show(for feed: Feed) {
		guard let siteURL = SiteCookies.siteURL(for: feed) else {
			return
		}
		if let existing = openControllers.first(where: { $0.host == SiteCookies.host(for: siteURL) }) {
			existing.showWindow(nil)
			return
		}
		guard let controller = SiteSignInWindowController(siteURL: siteURL) else {
			return
		}
		openControllers.insert(controller)
		controller.showWindow(nil)
	}

	private init?(siteURL: URL) {
		guard let host = SiteCookies.host(for: siteURL) else {
			return nil
		}
		self.siteURL = siteURL
		self.host = host

		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		webView = WKWebView(frame: .zero, configuration: configuration)

		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
		window.title = String(format: NSLocalizedString("Sign In to %@", comment: "Site sign-in window title"), host)
		window.isReleasedWhenClosed = false

		super.init(window: window)

		window.delegate = self
		window.contentView = makeContentView()
		window.center()
		window.setFrameAutosaveName("SiteSignInWindow")

		webView.navigationDelegate = self
		observation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
			MainActor.assumeIsolated {
				self?.addressField.stringValue = webView.url?.absoluteString ?? ""
			}
		}

		webView.load(URLRequest(url: siteURL))
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	// MARK: - Actions

	@objc func loadAddress(_ sender: Any?) {
		let text = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let url = URL(string: text), url.scheme == "https" || url.scheme == "http" else {
			NSSound.beep()
			return
		}
		webView.load(URLRequest(url: url))
	}

	@objc func save(_ sender: Any?) {
		Task {
			await saveCookies()
		}
	}

	@objc func cancel(_ sender: Any?) {
		window?.performClose(sender)
	}
}

// MARK: - NSWindowDelegate

extension SiteSignInWindowController: NSWindowDelegate {

	func windowWillClose(_ notification: Notification) {
		observation = nil
		webView.stopLoading()
		Self.openControllers.remove(self)
	}
}

// MARK: - WKNavigationDelegate

extension SiteSignInWindowController: WKNavigationDelegate {

	func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
		// Links that open new windows (target=_blank) would otherwise do nothing.
		if navigationAction.targetFrame == nil {
			webView.load(navigationAction.request)
			return .cancel
		}
		return .allow
	}
}

// MARK: - Private

private extension SiteSignInWindowController {

	func saveCookies() async {
		let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
		do {
			if try SiteCookies.shared.store(cookies, for: siteURL) {
				window?.close()
			} else {
				showNoCookiesAlert()
			}
		} catch {
			if let window {
				NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
			}
		}
	}

	func showNoCookiesAlert() {
		guard let window else {
			return
		}
		let alert = NSAlert()
		alert.alertStyle = .informational
		alert.messageText = NSLocalizedString("Not Signed In", comment: "Site sign-in alert title")
		alert.informativeText = String(format: NSLocalizedString("%@ hasn’t set any cookies yet. Sign in on the page, then try again.", comment: "Site sign-in alert message"), host)
		alert.beginSheetModal(for: window, completionHandler: nil)
	}

	func makeContentView() -> NSView {
		addressField.placeholderString = NSLocalizedString("Address — paste a sign-in link from your email here", comment: "Site sign-in address field placeholder")
		addressField.target = self
		addressField.action = #selector(loadAddress(_:))
		addressField.lineBreakMode = .byTruncatingMiddle
		addressField.cell?.usesSingleLineMode = true
		addressField.cell?.isScrollable = true

		let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: "Cancel"), target: self, action: #selector(cancel(_:)))
		cancelButton.keyEquivalent = "\u{1b}"

		let saveButton = NSButton(title: NSLocalizedString("Done Signing In", comment: "Site sign-in save button"), target: self, action: #selector(save(_:)))
		saveButton.bezelColor = .controlAccentColor

		let toolbar = NSStackView(views: [addressField, cancelButton, saveButton])
		toolbar.orientation = .horizontal
		toolbar.spacing = 8
		toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
		addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
		cancelButton.setContentHuggingPriority(.required, for: .horizontal)
		saveButton.setContentHuggingPriority(.required, for: .horizontal)

		let separator = NSBox()
		separator.boxType = .separator

		let contentView = NSView()
		for view in [toolbar, separator, webView] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			contentView.addSubview(view)
		}

		NSLayoutConstraint.activate([
			toolbar.topAnchor.constraint(equalTo: contentView.topAnchor),
			toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			toolbar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
			separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			webView.topAnchor.constraint(equalTo: separator.bottomAnchor),
			webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
			contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
			contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 400)
		])

		return contentView
	}
}
