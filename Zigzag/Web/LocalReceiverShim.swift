import Foundation
import WebKit

/// The page's side of the local-receiver door. It puts the page's own `fetch` aside for a loopback address and asks
/// Zigzag to make the call. The page cannot say who it is: native reads the frame's own origin and the site's switch
/// from Site Controls, and a site that is off gets the same `TypeError` WebKit's block would have given it.
@MainActor
enum LocalReceiverShim {
    static let name = "localReceivers"

    /// Adds the page script and the handler that answers it. A page made by another page gets them too; an
    /// extension's own page does not. The handler comes back so the tab can end a page's sockets when it leaves.
    @discardableResult
    static func attach(to configuration: WKWebViewConfiguration, tab: Tab) -> LocalReceiverMessages? {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source.hasPrefix(marker) }) else { return nil }
        let messages = LocalReceiverMessages(tab: tab)
        controller.addScriptMessageHandler(messages, contentWorld: .page, name: name)
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        return messages
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

      // WebSocket to this Mac, over the same door. The page's own WebSocket stays for everything else.
      const NativeWebSocket = window.WebSocket;
      const sockets = Object.create(null);
      const held = Symbol('zigzagListeners');
      const wsURL = (value) => {
        try {
          const url = new URL(value, location.href);
          if (url.protocol !== 'ws:') return null;
          if (!isLoopback({ protocol: 'http:', hostname: url.hostname })) return null;
          return url;
        } catch (error) { return null; }
      };
      const encodeData = async (data) => {
        if (typeof data === 'string') return { text: data };
        if (data instanceof Blob) return { base64: encode(await data.arrayBuffer()) };
        if (data instanceof ArrayBuffer) return { base64: encode(data) };
        if (ArrayBuffer.isView(data)) {
          return { base64: encode(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)) };
        }
        return { text: String(data) };
      };
      window.__zigzagLocalSocketEvent = (id, event) => {
        const socket = sockets[id];
        if (socket) socket.dispatch(event);
      };
      class LocalWebSocket {
        constructor(url, protocols) {
          const target = wsURL(url);
          if (!target) return new NativeWebSocket(url, protocols);
          this.url = target.href;
          this.readyState = 0;
          this.protocol = '';
          this.extensions = '';
          this.bufferedAmount = 0;
          this.binaryType = 'blob';
          this.onopen = this.onmessage = this.onerror = this.onclose = null;
          this[held] = Object.create(null);
          const id = (window.crypto && crypto.randomUUID) ? crypto.randomUUID()
            : String(Date.now()) + String(Math.random()).slice(2);
          this.id = id;
          const list = protocols == null ? [] : (typeof protocols === 'string' ? [protocols] : Array.from(protocols));
          sockets[id] = this;
          messages.postMessage({ kind: 'socket-open', id, url: this.url, protocols: list })
            .then((answer) => {
              if (!answer || answer.error) { this.fail(); return; }
              if (this.readyState !== 0) return;
              this.protocol = answer.protocol || '';
              this.readyState = 1;
              this.emit('open', new Event('open'));
            })
            .catch(() => this.fail());
        }
        emit(type, event) {
          const on = this['on' + type];
          if (typeof on === 'function') {
            try { on.call(this, event); } catch (error) { setTimeout(() => { throw error; }); }
          }
          const list = this[held][type];
          if (!list) return;
          for (const listener of list.slice()) {
            try { listener.call(this, event); } catch (error) { setTimeout(() => { throw error; }); }
          }
        }
        dispatch(event) {
          if (event.type === 'message') {
            const data = event.text != null ? event.text : binaryFor(this, event.base64 || '');
            this.emit('message', new MessageEvent('message', { data }));
          } else if (event.type === 'error') {
            this.emit('error', new Event('error'));
          } else if (event.type === 'close') {
            if (this.readyState === 3) return;
            this.readyState = 3;
            delete sockets[this.id];
            this.emit('close', new CloseEvent('close', { code: event.code || 1006, reason: event.reason || '',
                                                         wasClean: event.clean === true }));
          }
        }
        fail() {
          if (this.readyState === 3) return;
          this.emit('error', new Event('error'));
          this.dispatch({ type: 'close', code: 1006, reason: '', clean: false });
        }
        addEventListener(type, listener) {
          const list = this[held][type] || (this[held][type] = []);
          if (!list.includes(listener)) list.push(listener);
        }
        removeEventListener(type, listener) {
          const list = this[held][type];
          if (!list) return;
          const at = list.indexOf(listener);
          if (at >= 0) list.splice(at, 1);
        }
        dispatchEvent(event) { this.emit(event.type, event); return true; }
        send(data) {
          if (this.readyState === 0) throw new DOMException('Still connecting', 'InvalidStateError');
          if (this.readyState !== 1) return;
          encodeData(data).then((payload) => {
            messages.postMessage({ kind: 'socket-send', id: this.id, text: payload.text, base64: payload.base64 })
              .catch(() => this.fail());
          }).catch(() => this.fail());
        }
        close(code, reason) {
          if (this.readyState === 3) return;
          if (this.readyState === 0) { this.readyState = 2; return; }
          this.readyState = 2;
          messages.postMessage({ kind: 'socket-close', id: this.id, code, reason })
            .catch(() => this.fail());
        }
      }
      const binaryFor = (socket, text) => {
        const bytes = decode(text);
        return socket.binaryType === 'arraybuffer' ? bytes.buffer : new Blob([bytes]);
      };
      for (const key of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) {
        LocalWebSocket[key] = NativeWebSocket[key];
      }
      window.WebSocket = LocalWebSocket;
    })();
    """#
}

/// Answers one page's loopback calls, for the tab that page is in.
@MainActor
final class LocalReceiverMessages: NSObject, WKScriptMessageHandlerWithReply {
    private weak var tab: Tab?
    private var sockets: [String: LocalReceiverSocket] = [:]

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
        guard let body = message.body as? [String: Any] else {
            replyHandler(["error": "unknown"], nil)
            return
        }
        switch body["kind"] as? String {
        case "fetch":
            fetch(body, from: origin, webView: message.webView, reply: replyHandler)
        case "socket-open":
            openSocket(body, from: origin, webView: message.webView, reply: replyHandler)
        case "socket-send":
            guard let id = body["id"] as? String, let socket = sockets[id] else {
                replyHandler(["error": "unknown"], nil)
                return
            }
            socket.send(text: body["text"] as? String, base64: body["base64"] as? String)
            replyHandler(["ok": true], nil)
        case "socket-close":
            guard let id = body["id"] as? String, let socket = sockets[id] else {
                replyHandler(["error": "unknown"], nil)
                return
            }
            socket.close(code: body["code"] as? Int, reason: body["reason"] as? String)
            replyHandler(["ok": true], nil)
        default:
            replyHandler(["error": "unknown"], nil)
        }
    }

    /// Ends every socket this page opened: a page that is going away has nothing left to talk to.
    func closeAllSockets() {
        for socket in sockets.values { socket.cancelForNavigation() }
        sockets.removeAll()
    }

    private func openSocket(_ body: [String: Any], from origin: String, webView: WKWebView?,
                            reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let id = body["id"] as? String, let text = body["url"] as? String, let url = URL(string: text),
              url.scheme?.lowercased() == "ws", LocalReceivers.isLoopback(url) else {
            reply(["error": "refused"], nil)
            return
        }
        let socket = LocalReceiverSocket(id: id, url: url, protocols: (body["protocols"] as? [String]) ?? [],
                                         origin: origin, webView: webView, reply: reply)
        socket.onClose = { [weak self] id in self?.sockets[id] = nil }
        sockets[id] = socket
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

/// One WebSocket a page opened to this Mac: Zigzag makes the connection and pushes what arrives back into the page.
@MainActor
final class LocalReceiverSocket: NSObject, URLSessionWebSocketDelegate {
    private let id: String
    private weak var webView: WKWebView?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var reply: (@MainActor @Sendable (Any?, String?) -> Void)?
    private var opened = false
    private var closed = false
    var onClose: ((String) -> Void)?

    init(id: String, url: URL, protocols: [String], origin: String, webView: WKWebView?,
         reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        self.id = id
        self.webView = webView
        self.reply = reply
        super.init()
        var request = URLRequest(url: url)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        if !protocols.isEmpty {
            request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receive()
    }

    func send(text: String?, base64: String?) {
        guard !closed else { return }
        if let text {
            task?.send(.string(text)) { _ in }
        } else if let base64, let data = Data(base64Encoded: base64) {
            task?.send(.data(data)) { _ in }
        }
    }

    func close(code: Int?, reason: String?) {
        guard !closed else { return }
        let closeCode = code.flatMap { URLSessionWebSocketTask.CloseCode(rawValue: $0) } ?? .normalClosure
        task?.cancel(with: closeCode, reason: reason?.data(using: .utf8))
        finish(code: closeCode.rawValue, reason: reason ?? "", clean: closeCode == .normalClosure)
    }

    /// The page is navigating away: no close frame to send, just the connection ended.
    func cancelForNavigation() {
        guard !closed else { return }
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        // The session holds this socket as its delegate: ended here, or it would outlive the page.
        session?.invalidateAndCancel()
        onClose = nil
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol subprotocol: String?) {
        MainActor.assumeIsolated {
            guard !closed else { return }
            opened = true
            reply?(["protocol": subprotocol ?? ""], nil)
            reply = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        MainActor.assumeIsolated {
            let text = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            finish(code: closeCode.rawValue, reason: text,
                   clean: closeCode == .normalClosure || closeCode == .goingAway)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let error else { return }
            if opened {
                finish(code: 1006, reason: "", clean: false)
            } else {
                reply?(["error": "failed"], nil)
                reply = nil
                finish(code: 1006, reason: "", clean: false)
            }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    switch result {
                    case .success(.string(let text)):
                        self.push(["type": "message", "text": text])
                        self.receive()
                    case .success(.data(let data)):
                        self.push(["type": "message", "base64": data.base64EncodedString()])
                        self.receive()
                    case .failure:
                        self.finish(code: 1006, reason: "", clean: false)
                    @unknown default:
                        self.finish(code: 1006, reason: "", clean: false)
                    }
                }
            }
        }
    }

    private func finish(code: Int, reason: String, clean: Bool) {
        guard !closed else { return }
        closed = true
        session?.invalidateAndCancel()
        if !opened {
            reply?(["error": "failed"], nil)
            reply = nil
        }
        push(["type": "close", "code": code, "reason": reason, "clean": clean])
        onClose?(id)
        onClose = nil
    }

    private func push(_ event: [String: Any]) {
        guard let webView, JSONSerialization.isValidJSONObject(event),
              let payload = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: payload, encoding: .utf8) else { return }
        let idJSON = "\"" + id.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        webView.evaluateJavaScript("window.__zigzagLocalSocketEvent && window.__zigzagLocalSocketEvent(\(idJSON), \(text))",
                                   completionHandler: nil)
    }
}
