//  GPTCleaner - a small macOS front end for the gptcleaner engine.
//
//  The cleaning logic is NOT reimplemented here. This app runs the very same
//  web/cleaner.js through JavaScriptCore, so the menu-bar clipboard cleaner,
//  the in-app window and the website can never drift apart.

import AppKit
import Carbon.HIToolbox
import JavaScriptCore
import WebKit

// MARK: - Engine

/// Thin Swift wrapper around web/cleaner.js running in JavaScriptCore.
final class Engine {
    struct Result {
        var text: String
        var charsIn: Int
        var charsOut: Int
        var hidden: Int
        var punctuation: Int
        var detail: String      // "ZERO WIDTH SPACE x3, NO-BREAK SPACE x1"
    }

    private let context = JSContext()!

    init?(scriptURL: URL) {
        guard let source = try? String(contentsOf: scriptURL, encoding: .utf8) else { return nil }
        context.exceptionHandler = { _, err in
            FileHandler.log("js exception: \(err?.toString() ?? "unknown")")
        }
        context.evaluateScript(source)
        // Bridge shim: Maps don't cross into Swift cleanly, so flatten here.
        context.evaluateScript("""
        function __clean(text, opts) {
          const r = GPTCleaner.clean(text, opts);
          const top = [...r.report.removed.entries()]
            .sort((a, b) => b[1] - a[1]).slice(0, 3)
            .map(([c, n]) => GPTCleaner.charName(c) + " x" + n).join(", ");
          return { text: r.text, charsIn: r.report.charsIn, charsOut: r.report.charsOut,
                   hidden: r.report.hiddenTotal, punct: r.report.punctuationTotal, detail: top };
        }
        function __scanCount(text) { return GPTCleaner.scan(text).reduce((a, h) => a + h.count, 0); }
        """)
        guard context.objectForKeyedSubscript("GPTCleaner") != nil else { return nil }
    }

    func clean(_ text: String, options: Options) -> Result? {
        guard let fn = context.objectForKeyedSubscript("__clean"),
              let out = fn.call(withArguments: [text, options.jsDictionary]),
              let dict = out.toDictionary() as? [String: Any],
              let cleaned = dict["text"] as? String
        else { return nil }
        return Result(
            text: cleaned,
            charsIn: dict["charsIn"] as? Int ?? 0,
            charsOut: dict["charsOut"] as? Int ?? 0,
            hidden: dict["hidden"] as? Int ?? 0,
            punctuation: dict["punct"] as? Int ?? 0,
            detail: dict["detail"] as? String ?? "")
    }
}

enum FileHandler {
    static func log(_ msg: String) { FileHandle.standardError.write(Data("[gptcleaner] \(msg)\n".utf8)) }
}

// MARK: - Options

/// Mirrors the CLI flags and the web app's toggles; persisted in UserDefaults.
struct Options {
    var invisible = true
    var spaces = true
    var punctuation = true
    var dashes = true
    var spacing = true
    var markdown = false

    private static let keys = ["invisible", "spaces", "punctuation", "dashes", "spacing", "markdown"]

    static func load() -> Options {
        let d = UserDefaults.standard
        var o = Options()
        // First run: nothing stored, keep the defaults above.
        if d.object(forKey: "invisible") == nil { o.save(); return o }
        o.invisible = d.bool(forKey: "invisible")
        o.spaces = d.bool(forKey: "spaces")
        o.punctuation = d.bool(forKey: "punctuation")
        o.dashes = d.bool(forKey: "dashes")
        o.spacing = d.bool(forKey: "spacing")
        o.markdown = d.bool(forKey: "markdown")
        return o
    }

    func save() {
        let d = UserDefaults.standard
        for (k, v) in zip(Options.keys, [invisible, spaces, punctuation, dashes, spacing, markdown]) {
            d.set(v, forKey: k)
        }
    }

    var jsDictionary: [String: Any] {
        ["invisible": invisible, "spaces": spaces, "punctuation": punctuation,
         "dashes": dashes, "spacing": spacing, "markdown": markdown,
         "stripLists": false, "lineSpacing": "keep"]
    }
}

// MARK: - Hotkey (Carbon: works with no accessibility permission)

final class Hotkey {
    private var ref: EventHotKeyRef?
    private static var handler: (() -> Void)?

    /// ⌃⌥⌘C - clean whatever is on the clipboard, in place.
    func register(_ action: @escaping () -> Void) {
        Hotkey.handler = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Hotkey.handler?()
            return noErr
        }, 1, &spec, nil, nil)

        let id = EventHotKeyID(signature: OSType(0x4750_4343), id: 1)   // 'GPCC'
        RegisterEventHotKey(UInt32(kVK_ANSI_C),
                            UInt32(controlKey | optionKey | cmdKey),
                            id, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var webView: WKWebView?
    private var engine: Engine?
    private var options = Options.load()
    private let hotkey = Hotkey()
    private var resetTitleWork: DispatchWorkItem?

    private var webDirectory: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let js = Bundle.main.url(forResource: "cleaner", withExtension: "js", subdirectory: "web") {
            engine = Engine(scriptURL: js)
        }
        if engine == nil {
            let a = NSAlert()
            a.messageText = "Cleaning engine missing"
            a.informativeText = "web/cleaner.js was not found inside the app bundle. "
                + "Rebuild with macos/build.sh."
            a.alertStyle = .critical
            a.runModal()
            NSApp.terminate(nil)
        }

        buildStatusItem()
        buildMainMenu()
        hotkey.register { [weak self] in self?.cleanClipboard() }

        if UserDefaults.standard.bool(forKey: "hideDock") {
            NSApp.setActivationPolicy(.accessory)
        } else {
            showWindow(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    // MARK: status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "👻"
        statusItem.button?.toolTip = "GPTCleaner - ⌃⌥⌘C cleans the clipboard"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let clean = NSMenuItem(title: "Clean Clipboard", action: #selector(cleanClipboardAction),
                               keyEquivalent: "c")
        clean.keyEquivalentModifierMask = [.control, .option, .command]
        clean.target = self
        menu.addItem(clean)

        let open = NSMenuItem(title: "Open Cleaner Window…", action: #selector(showWindow(_:)),
                              keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let header = NSMenuItem(title: "Clipboard cleaning", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let toggles: [(String, Bool, Int)] = [
            ("Invisible characters", options.invisible, 0),
            ("Odd spaces", options.spaces, 1),
            ("Smart quotes", options.punctuation, 2),
            ("Em / en dashes", options.dashes, 3),
            ("Spacing & blank lines", options.spacing, 4),
            ("Markdown", options.markdown, 5),
        ]
        for (title, on, tag) in toggles {
            let item = NSMenuItem(title: title, action: #selector(toggleOption(_:)), keyEquivalent: "")
            item.state = on ? .on : .off
            item.tag = tag
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let dock = NSMenuItem(title: "Hide Dock Icon", action: #selector(toggleDock(_:)), keyEquivalent: "")
        dock.state = UserDefaults.standard.bool(forKey: "hideDock") ? .on : .off
        dock.target = self
        menu.addItem(dock)

        let quit = NSMenuItem(title: "Quit GPTCleaner", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func toggleOption(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: options.invisible.toggle()
        case 1: options.spaces.toggle()
        case 2: options.punctuation.toggle()
        case 3: options.dashes.toggle()
        case 4: options.spacing.toggle()
        default: options.markdown.toggle()
        }
        options.save()
        rebuildMenu()
    }

    @objc private func toggleDock(_ sender: NSMenuItem) {
        let hide = !UserDefaults.standard.bool(forKey: "hideDock")
        UserDefaults.standard.set(hide, forKey: "hideDock")
        NSApp.setActivationPolicy(hide ? .accessory : .regular)
        rebuildMenu()
    }

    // MARK: clipboard

    @objc private func cleanClipboardAction() { cleanClipboard() }

    private func cleanClipboard() {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string), !text.isEmpty else {
            return flashStatus("∅", tooltip: "Clipboard has no text")
        }
        guard let r = engine?.clean(text, options: options) else {
            return flashStatus("!", tooltip: "Cleaning failed")
        }
        pb.clearContents()
        pb.setString(r.text, forType: .string)

        let total = r.hidden + r.punctuation
        if total == 0 {
            flashStatus("✓", tooltip: "Already clean - nothing to remove")
        } else {
            flashStatus("✓\(total)",
                        tooltip: "\(r.hidden) hidden, \(r.punctuation) punctuation"
                            + (r.detail.isEmpty ? "" : " - \(r.detail)"))
        }
    }

    /// Feedback without notification permissions: briefly relabel the menu bar.
    private func flashStatus(_ label: String, tooltip: String) {
        resetTitleWork?.cancel()
        statusItem.button?.title = label
        statusItem.button?.toolTip = tooltip
        let work = DispatchWorkItem { [weak self] in
            self?.statusItem.button?.title = "👻"
            self?.statusItem.button?.toolTip = "GPTCleaner - ⌃⌥⌘C cleans the clipboard"
        }
        resetTitleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    // MARK: window

    @objc func showWindow(_ sender: Any?) {
        if window == nil { buildWindow() }
        NSApp.setActivationPolicy(UserDefaults.standard.bool(forKey: "hideDock") ? .accessory : .regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.title = "GPTCleaner"
        win.center()
        win.setFrameAutosaveName("GPTCleanerWindow")
        win.delegate = self
        win.minSize = NSSize(width: 720, height: 560)

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        let web = WKWebView(frame: win.contentLayoutRect, configuration: config)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")     // let the page paint its own void
        if let index = webDirectory {
            web.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        }
        win.contentView?.addSubview(web)
        webView = web
        window = win
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window?.orderOut(nil)
        return false      // keep running in the menu bar
    }

    // MARK: main menu (⌘Q, ⌘W, copy/paste in the web view)

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About GPTCleaner", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let hide = appMenu.addItem(withTitle: "Hide GPTCleaner", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit GPTCleaner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu
        main.addItem(winItem)

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
