import GSDCore
import SwiftUI
import WebKit

/// Gradescope's own login page (school SSO works too).  Once the browser lands
/// anywhere past login, its cookies become the app's session; the password is
/// typed into Gradescope's page and never seen by the app.
struct GradescopeLoginView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Sign in to Gradescope. Tick “Remember me” so the session lasts."
    @State private var busy = false
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if busy || loading { ProgressView().controlSize(.small) }
                Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            WebView(loading: $loading, onPage: check)
        }
        .frame(width: 580, height: 720)
    }

    /// Called after each page load; adopts the session once past login.
    private func check(_ webView: WKWebView) {
        guard !busy, let url = webView.url, let host = url.host, host.hasSuffix("gradescope.com") else { return }
        let path = url.path
        if path.hasPrefix("/login") || path.hasPrefix("/auth") || path.hasPrefix("/saml") || path.hasPrefix("/signup") { return }
        busy = true
        status = "Checking session…"
        webView.evaluateJavaScript("navigator.userAgent") { ua, _ in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                Task { @MainActor in
                    do {
                        try await model.gradescopeAdoptSession(cookies: cookies, userAgent: ua as? String)
                        model.notify("Gradescope connected; syncing…")
                        dismiss()
                    } catch {
                        status = "Not logged in yet (\(error)). Try again."
                        busy = false
                    }
                }
            }
        }
    }
}

private struct WebView: NSViewRepresentable {
    @Binding var loading: Bool
    let onPage: (WKWebView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // A fresh, throwaway cookie jar: the app keeps only what it copies out.
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: URL(string: "\(Gradescope.base)/login")!))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebView
        init(_ parent: WebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            parent.onPage(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
        }
    }
}
