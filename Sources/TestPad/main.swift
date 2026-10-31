import AppKit
import WebKit

// One-window target app for Utter's self-test. Shows either a native text view or a web <textarea>
// (like Electron/browser apps) and mirrors its text and focus state into a JSON file.
//
//   TestPad --state /tmp/pad.json [--field native|web|web-hidden|web-hidden-empty]
//
// web-hidden: the web view tells Accessibility nothing (like some web-view apps: only the window shows), so Utter can't
// see the field. web-hidden-empty: the same with no field on the page.

final class Pad: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var statePath = "/tmp/utter-testpad.json"
    var field = "native"
    var text = ""
    let textView = NSTextView()
    var web: WKWebView?

    func applicationDidFinishLaunching(_ n: Notification) {
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            if a == "--state" { statePath = it.next() ?? statePath }
            if a == "--field" { field = it.next() ?? field }
        }
        // A standard Edit menu, like real apps: ⌘V reaches the field through it.
        let main = NSMenu(), appItem = NSMenuItem(), editItem = NSMenuItem()
        main.addItem(appItem); main.addItem(editItem)
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit TestPad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Utter TestPad (\(field)) — synthetic keys only while this window is focused"
        window.delegate = self
        window.center()

        if field.hasPrefix("web") {
            let cfg = WKWebViewConfiguration()
            cfg.userContentController.add(self, name: "pad")
            let w = field == "web" ? WKWebView(frame: window.contentView!.bounds, configuration: cfg)
                : HiddenWebView(frame: window.contentView!.bounds, configuration: cfg)
            w.autoresizingMask = [.width, .height]
            w.loadHTMLString(field == "web-hidden-empty" ? "<body style='font:15px -apple-system;padding:12px'>No field here.</body>" : """
            <html><body style="margin:0;font:15px -apple-system">
            <textarea id=t autofocus style="width:100%;height:100vh;border:0;padding:12px;font:inherit;box-sizing:border-box"></textarea>
            <script>
            const t=document.getElementById('t');
            t.addEventListener('input',()=>webkit.messageHandlers.pad.postMessage(t.value));
            setTimeout(()=>t.focus(),50);
            </script></body></html>
            """, baseURL: nil)
            window.contentView = w
            web = w
        } else {
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            textView.frame = scroll.bounds
            textView.font = .systemFont(ofSize: 15)
            textView.isRichText = false
            textView.autoresizingMask = [.width]
            textView.delegate = self
            scroll.documentView = textView
            window.contentView = scroll
        }
        window.makeKeyAndOrderFront(nil)
        if field.hasPrefix("web") { window.makeFirstResponder(web) } else { window.makeFirstResponder(textView) }
        NSApp.activate(ignoringOtherApps: true)
        write()
    }

    func textDidChange(_ n: Notification) { text = textView.string; write() }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        text = (m.body as? String) ?? ""; write()
    }
    func windowDidBecomeKey(_ n: Notification) { write() }
    func windowDidResignKey(_ n: Notification) { write() }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func write() {
        let j: [String: Any] = ["text": text, "key": window?.isKeyWindow ?? false, "field": field, "pid": ProcessInfo.processInfo.processIdentifier]
        if let d = try? JSONSerialization.data(withJSONObject: j) {
            try? d.write(to: URL(fileURLWithPath: statePath), options: .atomic)
        }
    }
}

/// A web view that keeps itself and its page out of the Accessibility tree.
final class HiddenWebView: WKWebView {
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
    override var accessibilityFocusedUIElement: Any? { window }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? { window }
}

let app = NSApplication.shared
let pad = Pad()
app.delegate = pad
app.setActivationPolicy(.regular)
app.run()
