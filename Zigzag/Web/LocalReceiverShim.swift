import Foundation
import WebKit

/// The page's side of the local-receiver door. It puts the page's own `fetch` aside for a loopback address and asks
/// Zigzag to make the call. The page cannot say who it is: native reads the frame's own origin and the site's switch
/// from Site Controls, and a site that is off gets the same `TypeError` WebKit's block would have given it.
@MainActor
enum LocalReceiverShim {
    static let name = "localReceivers"

    /// Adds the page script and the handler that answers it. A page made by another page gets them too; an
    /// extension's own page does not.
    static func attach(to configuration: WKWebViewConfiguration, tab: Tab) {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source.hasPrefix(marker) }) else { return }
        controller.addScriptMessageHandler(LocalReceiverMessages(tab: tab), contentWorld: .page, name: name)
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
    }

    private static let marker = "/* zigzag local receivers */"

    private static let source = #"""
    /* zigzag local receivers */
    (() => {
      if (window.__zigzagLocalReceivers) return;
      const messages = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.localReceivers;
      if (!messages) return;
      window.__zigzagLocalReceivers = true;
      const nativeFetch = window.fetch.bind(window);

      // This Mac by the names loopback is reached by; http only, because that is what WebKit blocks from https.
      const isLoopback = (url) => {
        if (url.protocol !== 'http:') return false;
        let host = url.hostname.toLowerCase();
        if (host.startsWith('[') && host.endsWith(']')) host = host.slice(1, -1);
        if (host.endsWith('.')) host = host.slice(0, -1);
        if (host === 'localhost' || host.endsWith('.localhost')
            || host === '::1' || host === '0:0:0:0:0:0:0:1') return true;
        const parts = host.split('.');
        return parts.length === 4 && parts.every((p) => /^\d{1,3}$/.test(p) && Number(p) <= 255)
          && parts[0] === '127';
      };

      const encode = (buffer) => {
        const bytes = new Uint8Array(buffer);
        let binary = '';
        for (let i = 0; i < bytes.length; i += 0x8000) {
          binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
        }
        return btoa(binary);
      };
      const decode = (text) => {
        const binary = atob(text);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
        return bytes;
      };
      const failed = () => new TypeError('Load failed');
      const aborted = () => new DOMException('The user aborted a request.', 'AbortError');

      window.fetch = async (input, init) => {
        let request;
        try { request = new Request(input, init); } catch (error) { return nativeFetch(input, init); }
        let url;
        try { url = new URL(request.url, location.href); } catch (error) { return nativeFetch(input, init); }
        if (!isLoopback(url)) return nativeFetch(input, init);
        if (request.mode === 'no-cors' || request.mode === 'navigate' || request.redirect === 'manual') {
          return nativeFetch(input, init);
        }
        if (request.signal.aborted) throw aborted();
        let body = null;
        try {
          if (request.method !== 'GET' && request.method !== 'HEAD') {
            body = encode(await request.arrayBuffer());
          }
        } catch (error) {
          return nativeFetch(input, init);
        }
        let answer;
        try {
          answer = await messages.postMessage({
            kind: 'fetch', url: request.url, method: request.method,
            headers: Array.from(request.headers), body, credentials: request.credentials,
          });
        } catch (error) {
          throw failed();
        }
        if (request.signal.aborted) throw aborted();
        if (!answer || answer.error) throw failed();
        const noBody = answer.status === 204 || answer.status === 205 || answer.status === 304;
        const response = new Response(noBody ? null : decode(answer.body), {
          status: answer.status, statusText: answer.statusText, headers: answer.headers,
        });
        Object.defineProperties(response, {
          url: { value: answer.url },
          redirected: { value: answer.redirected },
          type: { value: 'cors' },
        });
        return response;
      };
    })();
    """#
}

/// Answers one page's loopback calls, for the tab that page is in.
@MainActor
private final class LocalReceiverMessages: NSObject, WKScriptMessageHandlerWithReply {
    private weak var tab: Tab?

    init(tab: Tab) {
        self.tab = tab
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let tab, message.frameInfo.isMainFrame,
              let origin = SiteOrigin.of(message.frameInfo.securityOrigin),
              !tab.isPrivate,
              SitePermissions.localReceivers(origin: origin) else {
            replyHandler(["error": "denied"], nil)
            return
        }
        guard let body = message.body as? [String: Any], body["kind"] as? String == "fetch" else {
            replyHandler(["error": "unknown"], nil)
            return
        }
        fetch(body, from: origin, webView: message.webView, reply: replyHandler)
    }

    private func fetch(_ body: [String: Any], from origin: String, webView: WKWebView?,
                       reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let text = body["url"] as? String, let url = URL(string: text), LocalReceivers.isLoopback(url) else {
            reply(["error": "refused"], nil)
            return
        }
        let credentials = Self.credentials(body["credentials"])
        var request = LocalReceivers.Request(url: url,
                                             method: (body["method"] as? String) ?? "GET",
                                             headers: Self.headers(body["headers"]),
                                             body: (body["body"] as? String).flatMap { Data(base64Encoded: $0) },
                                             credentials: credentials)
        Task { @MainActor in
            if credentials.sendsCookies, let cookie = await Self.cookies(for: url, in: webView) {
                request.headers["Cookie"] = cookie
            }
            do {
                let answer = try await LocalReceivers.send(request, as: .site(origin: origin))
                if credentials.sendsCookies { await Self.store(answer, for: url, in: webView) }
                reply(Self.reply(answer, to: request), nil)
            } catch {
                reply(["error": "failed"], nil)
            }
        }
    }

    /// The page's headers, without the ones only native code may set. The page's `Origin` is not its to choose.
    private static func headers(_ raw: Any?) -> [String: String] {
        guard let pairs = raw as? [[String]] else { return [:] }
        var out: [String: String] = [:]
        for pair in pairs where pair.count == 2 {
            let name = pair[0].lowercased()
            if ["host", "cookie", "origin", "referer", "content-length", "connection", "transfer-encoding",
                "upgrade", "keep-alive", "expect", "te", "trailer"].contains(name) { continue }
            if name.hasPrefix("proxy-") || name.hasPrefix("sec-") { continue }
            out[pair[0]] = pair[1]
        }
        return out
    }

    private static func credentials(_ raw: Any?) -> LocalReceivers.Credentials {
        switch raw as? String {
        case "omit": .omit
        case "include": .include
        default: .sameOrigin
        }
    }

    /// What the page may read: the CORS-safelisted response headers and whatever the helper exposed, which is what a
    /// browser would show it. The helper's cookies are Zigzag's to keep, never the page's to see.
    private static let visibleHeaders: Set<String> = [
        "cache-control", "content-language", "content-length", "content-type", "expires", "last-modified", "pragma",
    ]

    private static func reply(_ answer: LocalReceivers.Response, to request: LocalReceivers.Request) -> [String: Any] {
        let exposed = Set((answer.header("access-control-expose-headers") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let headers = answer.headers
            .filter { visibleHeaders.contains($0.key) || exposed.contains($0.key) }
            .map { [$0.key, $0.value] }
        return [
            "status": answer.status,
            "statusText": HTTPURLResponse.localizedString(forStatusCode: answer.status),
            "headers": headers,
            "body": answer.body.base64EncodedString(),
            "url": answer.url.absoluteString,
            "redirected": answer.url != request.url,
        ]
    }

    /// The cookies WebKit would have sent to the helper from this profile, for the moment the call is made.
    private static func cookies(for url: URL, in webView: WKWebView?) async -> String? {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { return nil }
        let all: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        let host = url.host()?.lowercased() ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let now = Date()
        let matching = all.filter { cookie in
            if let expires = cookie.expiresDate, expires <= now { return false }
            if cookie.isSecure, url.scheme?.lowercased() != "https" { return false }
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !domain.isEmpty, host == domain || host.hasSuffix("." + domain) else { return false }
            return path.hasPrefix(cookie.path.isEmpty ? "/" : cookie.path)
        }
        return matching.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
    }

    /// Cookies the helper set, kept where WebKit keeps the profile's, so the next call sends them back.
    private static func store(_ answer: LocalReceivers.Response, for url: URL, in webView: WKWebView?) async {
        guard let value = answer.header("set-cookie"),
              let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": value], for: url) {
            await store.setCookie(cookie)
        }
    }
}
