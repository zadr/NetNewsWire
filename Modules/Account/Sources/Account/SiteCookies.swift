//
//  SiteCookies.swift
//  Account
//

import Foundation
import os
import RSCore
import RSWeb
import Secrets

public extension Notification.Name {
	static let SiteCookiesDidChange = Notification.Name("SiteCookiesDidChange")
}

/// Cookies from signing in to a site, sent when refreshing that site’s feeds
/// so that sites with paywalls return full-text feeds.
///
/// Stored in the keychain, keyed by host, so one sign-in covers every feed on a site.
/// Only feeds that NetNewsWire downloads itself (On My Mac, iCloud) use them.
@MainActor public final class SiteCookies {
	public static let shared = SiteCookies()

	public static let hostUserInfoKey = "host"

	/// Host → Cookie header. A nil value means the keychain has nothing for that host.
	private var cache = [String: String?]()

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "SiteCookies")

	/// The host cookies are keyed by: lowercased, without a leading `www.`.
	public static func host(for url: URL) -> String? {
		guard let host = url.host()?.lowercased(), !host.isEmpty else {
			return nil
		}
		if host.hasPrefix("www.") {
			return String(host.dropFirst(4))
		}
		return host
	}

	/// The site to sign in to for a feed: its home page, or else the root of its host.
	public static func siteURL(for feed: Feed) -> URL? {
		if let homePageURL = feed.homePageURL, let url = URL(string: homePageURL), url.host() != nil {
			return url
		}
		guard let feedURL = URL(string: feed.url), let host = feedURL.host() else {
			return nil
		}
		return URL(string: "https://\(host)/")
	}

	public static func canUseCookies(for feed: Feed) -> Bool {
		guard let accountType = feed.account?.type else {
			return false
		}
		return accountType == .onMyMac || accountType == .cloudKit
	}

	public func cookieHeader(for url: URL) -> String? {
		guard let host = Self.host(for: url) else {
			return nil
		}
		if let cached = cache[host] {
			return cached
		}

		let cookieHeader: String?
		do {
			cookieHeader = try CredentialsManager.retrieveCredentials(type: .siteCookies, server: host, username: host)?.secret
		} catch {
			Self.logger.error("SiteCookies: failed to retrieve cookies for \(host, privacy: .public): \(error.localizedDescription, privacy: .public)")
			return nil
		}
		cache[host] = cookieHeader
		return cookieHeader
	}

	public func isSignedIn(to url: URL) -> Bool {
		cookieHeader(for: url) != nil
	}

	/// Stores the unexpired cookies that apply to `url`, replacing any stored before.
	/// Returns false if there were no such cookies.
	@discardableResult
	public func store(_ cookies: [HTTPCookie], for url: URL) throws -> Bool {
		guard let host = Self.host(for: url) else {
			return false
		}

		let now = Date()
		let applicableCookies = cookies.filter { cookie in
			if let expiresDate = cookie.expiresDate, expiresDate < now {
				return false
			}
			return Self.cookie(cookie, appliesTo: host)
		}
		guard let cookieHeader = HTTPCookie.requestHeaderFields(with: applicableCookies)[HTTPRequestHeader.cookie], !cookieHeader.isEmpty else {
			return false
		}

		let credentials = Credentials(type: .siteCookies, username: host, secret: cookieHeader)
		try CredentialsManager.storeCredentials(credentials, server: host)
		cache[host] = cookieHeader
		Self.logger.info("SiteCookies: stored \(applicableCookies.count) cookies for \(host, privacy: .public)")

		didChangeCookies(host: host)
		return true
	}

	public func removeCookies(for url: URL) throws {
		guard let host = Self.host(for: url) else {
			return
		}
		try CredentialsManager.removeCredentials(type: .siteCookies, server: host, username: host)
		cache[host] = .some(nil)
		Self.logger.info("SiteCookies: removed cookies for \(host, privacy: .public)")

		didChangeCookies(host: host)
	}
}

private extension SiteCookies {

	static func cookie(_ cookie: HTTPCookie, appliesTo host: String) -> Bool {
		var domain = cookie.domain.lowercased()
		if domain.hasPrefix(".") {
			domain.removeFirst()
		}
		return domain == host || domain == "www.\(host)" || host.hasSuffix(".\(domain)")
	}

	/// Feeds on this host likely have new content now, so forget what
	/// was downloaded before and refresh them.
	func didChangeCookies(host: String) {
		for account in AccountManager.shared.activeAccounts {
			for feed in account.flattenedFeeds() {
				guard Self.canUseCookies(for: feed), let feedURL = URL(string: feed.url), Self.host(for: feedURL) == host else {
					continue
				}
				feed.conditionalGetInfo = nil
				feed.cacheControlInfo = nil
				feed.contentHash = nil
				feed.lastCheckDate = nil
			}
		}

		NotificationCenter.default.post(name: .SiteCookiesDidChange, object: self, userInfo: [Self.hostUserInfoKey: host])
		AccountManager.shared.refreshAllWithoutWaiting()
	}
}
