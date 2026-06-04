//
//  AppBundleConfiguration.swift
//  leanring-buddy
//
//  Shared helper for reading runtime configuration from the built app bundle.
//

import Foundation

enum AppBundleConfiguration {
    /// The single source of truth for the Cloudflare Worker proxy base URL.
    ///
    /// Reads `ClickyProxyBaseURL` from Info.plist so the deployed Worker URL
    /// lives in one place instead of being hardcoded across multiple Swift
    /// files. Set this to your `https://<name>.<subdomain>.workers.dev` URL
    /// after deploying the Worker. Any trailing slash is trimmed so callers
    /// can safely append paths like "/chat" or "/tts".
    static var proxyBaseURL: String {
        let configuredValue = stringValue(forKey: "ClickyProxyBaseURL")
            ?? "https://your-worker-name.your-subdomain.workers.dev"
        if configuredValue.hasSuffix("/") {
            return String(configuredValue.dropLast())
        }
        return configuredValue
    }

    static func stringValue(forKey key: String) -> String? {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }

        guard let resourceInfoPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
              let resourceInfo = NSDictionary(contentsOfFile: resourceInfoPath),
              let value = resourceInfo[key] as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
