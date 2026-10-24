import SwiftUI
import WebKit

/// The Membrane kiosk's DEMO_BRAIN_URL: the slimeos.com demo desktop.
private let demoBrainURL = URL(string: "https://www.slimeos.com/demo/brain/")! // slimeos.com 301s to www

/// Demo Brain: until a Brain is added, the welcome screen offers the slimeos.com demo
/// desktop, full screen like a session, so a new device shows what a Brain feels like
/// before anyone buys or sets one up. A web page (no RDP, Brain or hub); Disconnect
/// closes it. Same as android/.../ui/DemoBrain.kt.
struct DemoBrainScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var loaded = false
    @State private var failed = false

    var body: some View {
        ZStack(alignment: .top) {
            Slime.shell.ignoresSafeArea()
            if !loaded {
                Text(failed ? "Couldn't reach the demo Brain. Check the internet connection."
                            : "Connecting to the demo Brain…")
                    .font(Slime.mono(12.5)).foregroundStyle(Slime.textMuted)
                    .multilineTextAlignment(.center).padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            DemoWebView(loaded: $loaded, failed: $failed)
                .opacity(loaded ? 1 : 0)
                .ignoresSafeArea(edges: .bottom)

            // Like a remote-desktop connection bar, as on the Membrane.
            HStack(spacing: 8) {
                Circle().fill(Slime.auroraGreen).frame(width: 6, height: 6)
                    .shadow(color: Slime.auroraGreen.opacity(0.6), radius: 3)
                Text("Demo Brain").font(Slime.mono(11.5)).foregroundStyle(Slime.textSoft)
                Button { model.demoBrainShown = false } label: {
                    Text("Disconnect").font(Slime.mono(11.5)).foregroundStyle(Slime.text)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Slime.borderButton, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 5)
            .background(Slime.shell.opacity(0.85),
                        in: UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
            .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12)
                .stroke(Slime.border, lineWidth: 1))
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}

private struct DemoWebView: UIViewRepresentable {
    @Binding var loaded: Bool
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: demoBrainURL))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: DemoWebView
        init(_ parent: DemoWebView) { self.parent = parent }

        func webView(_ web: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.failed = false
        }

        // Shown once the page starts drawing: WebKit's "finished" can come late
        // or not at all (a script still loading), long after the desktop is up.
        func webView(_ web: WKWebView, didCommit navigation: WKNavigation!) {
            if !parent.failed { parent.loaded = true }
        }

        func webView(_ web: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.failed = true
            parent.loaded = false
        }

        // Stay on slimeos.com: nothing else of the web opens in here.
        func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let host = action.request.url?.host ?? ""
            let ours = host == "slimeos.com" || host.hasSuffix(".slimeos.com")
            decisionHandler(ours || action.targetFrame?.isMainFrame == false ? .allow : .cancel)
        }
    }
}
