//
//  SiteSignInViewController.swift
//  NetNewsWire-iOS
//

import UIKit
import WebKit
import RSCore
import Account

/// A browser for signing in to a site whose feeds are truncated
/// for signed-out readers. The resulting cookies go to `SiteCookies`.
///
/// Uses a non-persistent data store, so the sign-in is isolated from
/// other web views, and the stored cookies are the only record of it.
@MainActor final class SiteSignInViewController: UIViewController {

	private let siteURL: URL
	private let host: String
	private let webView: WKWebView

	static func present(for feed: Feed, from presentingViewController: UIViewController) {
		guard let siteURL = SiteCookies.siteURL(for: feed), let controller = SiteSignInViewController(siteURL: siteURL) else {
			return
		}
		let navigationController = UINavigationController(rootViewController: controller)
		navigationController.isToolbarHidden = false
		navigationController.modalPresentationStyle = .formSheet
		presentingViewController.present(navigationController, animated: true)
	}

	/// Signs out if signed in to the feed’s site; otherwise presents the sign-in browser.
	static func toggleSignIn(for feed: Feed, from presentingViewController: UIViewController) {
		guard let feedURL = URL(string: feed.url) else {
			return
		}
		guard SiteCookies.shared.isSignedIn(to: feedURL) else {
			present(for: feed, from: presentingViewController)
			return
		}
		do {
			try SiteCookies.shared.removeCookies(for: feedURL)
		} catch {
			presentingViewController.presentError(error)
		}
	}

	/// “Sign In to example.com…” or “Sign Out of example.com”, or nil if the feed can’t use site cookies.
	static func toggleSignInTitle(for feed: Feed) -> String? {
		guard SiteCookies.canUseCookies(for: feed), let feedURL = URL(string: feed.url), let host = SiteCookies.host(for: feedURL) else {
			return nil
		}
		if SiteCookies.shared.isSignedIn(to: feedURL) {
			return String(format: NSLocalizedString("Sign Out of %@", comment: "Command"), host)
		}
		return String(format: NSLocalizedString("Sign In to %@…", comment: "Command"), host)
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

		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		view = webView
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		navigationItem.title = String(format: NSLocalizedString("Sign In to %@", comment: "Site sign-in title"), host)
		navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
			self?.dismiss(animated: true)
		})
		navigationItem.rightBarButtonItem = UIBarButtonItem(title: NSLocalizedString("Done", comment: "Done"), style: .done, target: self, action: #selector(save(_:)))

		let pasteLinkItem = UIBarButtonItem(title: NSLocalizedString("Open Copied Sign-In Link", comment: "Site sign-in toolbar button"), image: nil, primaryAction: UIAction { [weak self] _ in
			self?.openCopiedLink()
		})
		toolbarItems = [.flexibleSpace(), pasteLinkItem, .flexibleSpace()]

		webView.navigationDelegate = self
		webView.load(URLRequest(url: siteURL))
	}

	// MARK: - Actions

	@objc func save(_ sender: Any?) {
		Task {
			await saveCookies()
		}
	}
}

// MARK: - WKNavigationDelegate

extension SiteSignInViewController: WKNavigationDelegate {

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

private extension SiteSignInViewController {

	/// Sign-in emails open their links in Safari, so the link has to be copied and opened here instead.
	func openCopiedLink() {
		let pasteboard = UIPasteboard.general
		let url = pasteboard.url ?? pasteboard.string.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
		guard let url, url.scheme == "https" || url.scheme == "http" else {
			let alert = UIAlertController(title: NSLocalizedString("No Link Copied", comment: "Site sign-in alert title"), message: NSLocalizedString("In the sign-in email, touch and hold the sign-in link, choose Copy Link, then try again.", comment: "Site sign-in alert message"), preferredStyle: .alert)
			alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "OK"), style: .default))
			present(alert, animated: true)
			return
		}
		webView.load(URLRequest(url: url))
	}

	func saveCookies() async {
		let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
		do {
			if try SiteCookies.shared.store(cookies, for: siteURL) {
				dismiss(animated: true)
			} else {
				let alert = UIAlertController(title: NSLocalizedString("Not Signed In", comment: "Site sign-in alert title"), message: String(format: NSLocalizedString("%@ hasn’t set any cookies yet. Sign in on the page, then try again.", comment: "Site sign-in alert message"), host), preferredStyle: .alert)
				alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "OK"), style: .default))
				present(alert, animated: true)
			}
		} catch {
			presentError(error)
		}
	}
}
