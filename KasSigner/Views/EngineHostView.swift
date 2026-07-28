import SwiftUI
import WebKit

struct EngineHostView: UIViewRepresentable {
    @EnvironmentObject private var engine: KasSignerEngine

    func makeUIView(context: Context) -> WKWebView {
        engine.attachedWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
