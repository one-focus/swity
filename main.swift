// Swity: tap fn/🌐 alone -> instantly switch keyboard layout.
// Copyright © 2026 Alexandr Kardash. SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Carbon
import ServiceManagement

// UI language follows the system (or per-app) language: Russian if it comes first, English otherwise.
// Kept simple: two languages inline; move to Localizable.strings if a third one appears.
let myVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
let russian = Locale.preferredLanguages.first?.hasPrefix("ru") == true
func L(_ en: String, _ ru: String) -> String { russian ? ru : en }

// MARK: - Switching the layout

func layouts() -> [TISInputSource] {
    let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!,
                  kTISPropertyInputSourceIsSelectCapable: true] as CFDictionary
    return TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
}

func sourceID(_ s: TISInputSource) -> String {
    Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(s, kTISPropertyInputSourceID)).takeUnretainedValue() as String
}

func currentID() -> String { sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) }

// Kept simple: cycles to next enabled layout; with 3+ layouts the system flips to the *previous* one instead.
func switchLayout() {
    let list = layouts()
    guard !list.isEmpty else { return }
    let i = list.firstIndex { sourceID($0) == currentID() } ?? -1
    TISSelectInputSource(list[(i + 1) % list.count])
}

if CommandLine.arguments.contains("--toggle") {  // self-check, no permission needed
    let before = currentID()
    switchLayout()
    print(before, "->", currentID())
    exit(before == currentID() ? 1 : 0)
}

// MARK: - Input Monitoring access

// macOS answers the access question once per process: a grant or a removal made while Swity runs is not seen
// by it until relaunch. So the question is asked in a fresh copy of ourselves.
if CommandLine.arguments.contains("--access") { exit(CGPreflightListenEventAccess() ? 0 : 1) }

func allowed() -> Bool {
    guard let me = Bundle.main.executableURL, let p = try? Process.run(me, arguments: ["--access"])
    else { return CGPreflightListenEventAccess() }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

// Start again once this process is gone (willTerminate hands the 🌐 setting back, the new copy takes it again).
func relaunch() throws {
    _ = try Process.run(URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; open \"$0\"", Bundle.main.bundlePath])
    DispatchQueue.main.async { NSApp.terminate(nil) }
}

// MARK: - The 🌐 fn key

var tap: CFMachPort?
var denied = false  // this process was told "no access" and may go on believing it after a grant
var undo: TISInputSource?  // layout from before the switch, while fn is still held

// A keyboard without 🌐 fn (a Windows one, or one whose fn never leaves the keyboard) switches with left
// Control, the key in fn's corner. Unlike fn it is an everyday modifier, so the switch waits for the release:
// a short press with nothing else in between (no key, no click, no other modifier).
// A keyboard with 🌐 fn keeps Control for what it is. Which ones have it is learned, not looked up: a keyboard
// type that has ever sent fn is remembered, and Control is left alone on it from then on.
// Kept simple: two keyboards of the same type, one with fn and one without, are both taken as having it.
var armed: CFAbsoluteTime?  // when left Control went down alone
let longestTap = 0.4  // held longer, it was held for something else (ctrl+scroll, ctrl+drag)
var withFn = Set(UserDefaults.standard.array(forKey: "keyboardsWithFn") as? [Int] ?? [])
var lastKeyboard: Int64 = 0  // type of the keyboard the last modifier came from
// Picked in the panel for a little finger that lands next to fn: left Control (59) or left Option (58) then
// switches on every keyboard, along with fn. 0 = fn only (plus Control on keyboards without fn, as above).
var extraKey = UserDefaults.standard.integer(forKey: "extraKey")
var choosing = false  // the panel is waiting for the extra key to be pressed

// fn: switch the moment it goes down. ctrl/alt/cmd/shift already held = a shortcut, skip.
// A key pressed while fn is held makes it a combo (fn+arrow, fn+delete, fn+F): the switch is taken back.
// Key presses are only counted as "a key went down with fn held"; which key it was is never read.
let callback: CGEventTapCallBack = { _, type, event, _ in
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    if type == .flagsChanged { lastKeyboard = event.getIntegerValueField(.keyboardEventKeyboardType) }
    if choosing, type == .flagsChanged { return Unmanaged.passUnretained(event) }  // the press picks a key, not a layout
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        undo = nil  // fn may be released while the tap is off
        armed = nil
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
    } else if type == .keyDown {
        armed = nil
        if let before = undo, event.flags.contains(.maskSecondaryFn) {
            undo = nil
            TISSelectInputSource(before)
        }
    } else if type != .flagsChanged {
        armed = nil  // a mouse button
    } else if code == 63 {  // kVK_Function
        if event.flags.contains(.maskSecondaryFn), withFn.insert(Int(lastKeyboard)).inserted {
            UserDefaults.standard.set(Array(withFn), forKey: "keyboardsWithFn")
        }
        if event.flags.contains(.maskSecondaryFn),
           event.flags.isDisjoint(with: [.maskShift, .maskControl, .maskAlternate, .maskCommand]) {
            undo = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
            switchLayout()
        } else {
            undo = nil  // fn released
        }
    } else if code == extraKey || (code == 59 && !withFn.contains(Int(lastKeyboard))) {  // kVK_Control / kVK_Option, left ones
        let own: CGEventFlags = code == 59 ? .maskControl : .maskAlternate
        if event.flags.contains(own) {  // down
            armed = event.flags.isDisjoint(with: CGEventFlags([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]).subtracting(own))
                ? CFAbsoluteTimeGetCurrent() : nil
        } else {
            if let since = armed, CFAbsoluteTimeGetCurrent() - since < longestTap { switchLayout() }
            armed = nil
        }
    } else {
        armed = nil  // another modifier
    }
    return Unmanaged.passUnretained(event)
}

// Runs every 2 s until the tap exists, i.e. while waiting for Input Monitoring access.
func start() {
    guard tap == nil else { return }
    // Modifiers for the keys themselves; key and mouse downs only as "something else happened meanwhile"
    let watched: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    guard allowed() else { denied = true; return }
    guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                    eventsOfInterest: watched.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue },
                                    callback: callback, userInfo: nil)
    else {  // granted, but this process still holds the old answer: only a new one can make the tap
        if denied { denied = false; try? relaunch() }
        return
    }
    tap = t
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
}

// MARK: - The system's own 🌐 setting

// Private HIToolbox calls that System Settings itself uses for "Press 🌐 key to"; update writes the pref and
// notifies the system, so it applies live. 0 = Do Nothing, 1 = Change Input Source, 2 = Emoji, 3 = Dictation.
// Looked up at run time: an older macOS without them must still launch, it just keeps its own fn setting.
let hiToolbox = dlopen("/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox", RTLD_LAZY)
let getFnUsage = dlsym(hiToolbox, "TISGetFnUsageType").map { unsafeBitCast($0, to: (@convention(c) () -> Int32).self) }
let setFnUsage = dlsym(hiToolbox, "TISUpdateFnUsageType").map { unsafeBitCast($0, to: (@convention(c) (Int32) -> Void).self) }

/// macOS's own 🌐 action is off, so nothing switches twice. Cannot tell on a macOS without the call: assume fine.
func fnFree() -> Bool { getFnUsage.map { $0() == 0 } ?? true }

// Global pref for the blue language bubble macOS shows at the text cursor. It can lag one switch behind after
// quick presses, so it is off while Swity runs. Absent = shown (default).
let indicatorKey = "TSMLanguageIndicatorEnabled" as CFString

func setIndicator(_ value: CFPropertyList?) {
    CFPreferencesSetValue(indicatorKey, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
}

// On launch: system 🌐 does nothing (Swity switches) and the cursor bubble is off.
// The previous values are remembered and put back on quit.
func takeOverSystem() {
    let d = UserDefaults.standard
    if let getFnUsage = getFnUsage, let setFnUsage = setFnUsage {
        let fn = getFnUsage()
        if fn != 0 {  // 0 here means already ours (e.g. after a crash): keep the value saved earlier
            d.set(Int(fn), forKey: "savedFnUsage")
            setFnUsage(0)
        }
    }
    let indicator = CFPreferencesCopyValue(indicatorKey, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                           kCFPreferencesAnyHost) as? Bool
    if indicator != false {
        d.set(true, forKey: "savedIndicator")
        setIndicator(false as CFBoolean)
    }
}

func giveBackSystem() {
    let d = UserDefaults.standard
    if let fn = d.object(forKey: "savedFnUsage") as? Int, let setFnUsage = setFnUsage {
        setFnUsage(Int32(fn))
        d.removeObject(forKey: "savedFnUsage")
    }
    if d.bool(forKey: "savedIndicator") {
        setIndicator(nil)  // back to the system default: shown
        d.removeObject(forKey: "savedIndicator")
    }
}

// MARK: - Menu bar

// Menu bar item: fixed fox icon; the system input menu keeps showing the current layout.
final class StatusMenu: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    override init() {
        super.init()
        item.button?.image = NSImage(named: "MenuIconTemplate")  // line-art fox from the artwork; "Template" = tinted by the menu bar
        item.button?.target = self
        item.button?.action = #selector(click)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // Left click: the panel (version, access, switch key). Right click: just Quit.
    @objc func click() {
        if NSApp.currentEvent?.type != .rightMouseUp { return popup.toggle() }
        let m = NSMenu()
        m.addItem(withTitle: L("Quit Swity", "Выйти из Swity"), action: #selector(NSApplication.terminate), keyEquivalent: "q")
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }
}

// MARK: - Panel

// The bubble under the menu bar icon: version, one tab for access (and macOS's own 🌐 action), one for the
// switch keys. Opens by itself when there is something to do. Drawn like swity.io: oat page, white cards,
// ink text, keycaps like the site's fn, the download button's tangerine.
let ink = Color(red: 21 / 255, green: 23 / 255, blue: 26 / 255)
let ink2 = Color(red: 86 / 255, green: 91 / 255, blue: 99 / 255)
let ink3 = Color(red: 105 / 255, green: 110 / 255, blue: 118 / 255)
let oat = Color(red: 246 / 255, green: 244 / 255, blue: 238 / 255)
let oatDeep = Color(red: 233 / 255, green: 229 / 255, blue: 214 / 255)
let hairline = Color(red: 228 / 255, green: 224 / 255, blue: 211 / 255)
let tangerine = Color(red: 1, green: 120 / 255, blue: 61 / 255)
let blue = Color(red: 37 / 255, green: 137 / 255, blue: 216 / 255)

final class PanelModel: ObservableObject {
    @Published var access = false
    @Published var fnFree = true
    @Published var tab = 0 {  // 0 access, 1 switch keys
        didSet { listening = false }
    }
    @Published var listening = false {  // waiting for the extra key to be pressed
        didSet { choosing = listening; wrong = false }
    }
    @Published var wrong = false  // got a key that cannot switch
    @Published var key = extraKey {
        didSet { extraKey = key; UserDefaults.standard.set(key, forKey: "extraKey") }
    }
}

struct Primary: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold)).foregroundColor(ink)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 16).frame(height: 34)
            .background(Capsule().fill(LinearGradient(gradient: Gradient(colors: [Color(red: 1, green: 145 / 255, blue: 96 / 255), tangerine]),
                                                      startPoint: .top, endPoint: .bottom)))
            .shadow(color: tangerine.opacity(0.34), radius: 8, y: 5)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct Quiet: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold)).foregroundColor(ink)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 14).frame(height: 30)
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().stroke(hairline))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// A key like the site's fn: white to grey, a lip at the bottom, a soft shadow, name top right, glyph bottom left
struct Keycap: View {
    let name: String
    let glyph: String
    var system = false  // glyph is an SF Symbol
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15)
                .fill(LinearGradient(gradient: Gradient(colors: [.white, Color(red: 230 / 255, green: 233 / 255, blue: 238 / 255)]),
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.black.opacity(0.06)))
                .shadow(color: Color(red: 40 / 255, green: 50 / 255, blue: 70 / 255).opacity(0.18), radius: 9, y: 7)
            Text(name).font(.system(size: 16, weight: .medium)).foregroundColor(ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.top, 9).padding(.trailing, 11)
            Group { if system { Image(systemName: glyph) } else { Text(glyph) } }
                .font(.system(size: 19)).foregroundColor(system ? tangerine : ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(.bottom, 10).padding(.leading, 11)
        }
        .frame(width: 72, height: 70)
    }
}

func keyName(_ code: Int) -> String { code == 59 ? "Control" : "Option" }

struct PanelView: View {
    @ObservedObject var m: PanelModel
    let p: Panel

    func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(hairline))
    }

    // One permission or setting: what it is, whether it is fine, and the one button that fixes it
    func status<Fix: View>(_ ok: Bool, _ title: String, _ state: String, @ViewBuilder fix: () -> Fix) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 15)).foregroundColor(ok ? blue : tangerine)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(ink)
                    Text(state).font(.system(size: 12)).foregroundColor(ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !ok { fix().padding(.leading, 23) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    var access: some View {
        card {
            VStack(spacing: 0) {
                status(m.access, L("Input Monitoring", "Мониторинг ввода"),
                       m.access ? L("Allowed: Swity sees the 🌐 key.", "Разрешено: Swity видит клавишу 🌐.")
                                : L("Needed to see the 🌐 key.", "Нужен, чтобы видеть клавишу 🌐.")) {
                    Button(L("Grant Access", "Дать доступ")) { p.grantAccess() }.buttonStyle(Primary())
                }
                Rectangle().fill(hairline).frame(height: 1)
                status(m.fnFree, L("macOS 🌐 key", "Клавиша 🌐 в macOS"),
                       m.fnFree ? L("Set to “Do Nothing”: only Swity switches.", "«Не выполнять действие»: переключает только Swity.")
                                : L("macOS switches too. Set “Press 🌐 key to” to “Do Nothing”.",
                                    "macOS тоже переключает. Поставь «Нажатие клавиши 🌐» в «Не выполнять действие».")) {
                    Button(L("Open Keyboard Settings", "Открыть настройки клавиатуры")) { p.keyboardSettings() }.buttonStyle(Primary())
                }
            }
        }
    }

    func labeled<V: View>(_ text: String, _ view: V) -> some View {
        VStack(spacing: 10) {
            view
            Text(text).font(.system(size: 11, weight: .medium)).foregroundColor(ink3)
        }
    }

    // fn always switches; one extra key, left Control or left Option, may join it for a little finger that
    // lands there. It is only listened for after the button: any other key, a right-hand one too, gets a no.
    var keys: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 18) {
                    labeled(L("main", "основная"), Keycap(name: "fn", glyph: "globe", system: true).rotationEffect(.degrees(-6)))
                    Text("+").font(.system(size: 20, weight: .medium)).foregroundColor(ink3).padding(.top, 24)
                    if m.key != 0 && !m.listening {
                        labeled(L("extra", "дополнительная"), Keycap(name: m.key == 59 ? "control" : "option", glyph: m.key == 59 ? "⌃" : "⌥")
                                    .rotationEffect(.degrees(5)))
                    } else {
                        labeled(m.listening ? L("press it now", "нажми её") : L("extra", "дополнительная"),
                                RoundedRectangle(cornerRadius: 15)
                                    .stroke(m.listening ? tangerine : ink3.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                    .overlay(Text(m.listening ? "…" : L("none", "нет")).font(.system(size: 13, weight: .medium))
                                                .foregroundColor(m.listening ? tangerine : ink3))
                                    .frame(width: 72, height: 70))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                Text(m.wrong ? L("Only left Control or left Option.", "Только левый Control или левый Option.")
                     : m.listening ? L("Press left Control or left Option. Esc to cancel.", "Нажми левый Control или левый Option. Esc — отмена.")
                     : L("fn always switches. The extra key switches with a short tap on its own.",
                         "fn переключает всегда. Дополнительная — коротким нажатием, отдельно от других."))
                    .font(.system(size: 12)).foregroundColor(m.wrong ? tangerine : ink2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if m.listening {
                        Button(L("Cancel", "Отмена")) { m.listening = false }.buttonStyle(Quiet())
                    } else {
                        Button(m.key == 0 ? L("Add Extra Key", "Назначить дополнительную") : L("Change", "Сменить")) { m.listening = true }
                            .buttonStyle(Primary())
                        if m.key != 0 { Button(L("Remove", "Убрать")) { m.key = 0 }.buttonStyle(Quiet()) }
                    }
                }
            }
            .padding(14)
        }
    }

    func tab(_ i: Int, _ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(m.tab == i ? ink : ink2)
            .frame(maxWidth: .infinity).frame(height: 28)
            .background(Capsule().fill(m.tab == i ? Color.white : Color.clear)
                            .shadow(color: Color.black.opacity(m.tab == i ? 0.08 : 0), radius: 2, y: 1))
            .contentShape(Capsule())
            .onTapGesture { m.tab = i }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                Text("Swity").font(.system(size: 18, weight: .bold)).foregroundColor(ink)
                Spacer()
                Text(myVersion).font(.system(size: 12)).foregroundColor(ink3)
            }
            HStack(spacing: 2) {
                tab(0, L("Access", "Доступ"))
                tab(1, L("Switch keys", "Клавиши"))
            }
            .padding(3)
            .background(Capsule().fill(oatDeep))
            if m.tab == 0 { access } else { keys }
        }
        .padding(16)
        .frame(width: 320)
        .background(oat)
        // Light whatever the system is: older macOS gives SwiftUI the dark scheme even in an aqua window
        .environment(\.colorScheme, .light)
    }
}

final class Panel: NSObject, NSPopoverDelegate {
    let model = PanelModel()
    let popover = NSPopover()
    var host: NSHostingController<PanelView>!
    var monitor: Any?
    var resize: AnyObject?

    override init() {
        super.init()
        host = NSHostingController(rootView: PanelView(m: model, p: self))
        popover.contentViewController = host
        popover.appearance = NSAppearance(named: .aqua)
        popover.delegate = self
        refresh()
        resize = model.objectWillChange.sink { [weak self] _ in  // rows and tabs come and go
            DispatchQueue.main.async { if let self = self { self.popover.contentSize = self.host.view.fittingSize } }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            if self?.popover.isShown == true { self?.refresh() }
        }
    }

    func refresh() {
        let free = fnFree()
        if model.access != (tap != nil) { model.access = tap != nil }
        if model.fnFree != free { model.fnFree = free }
    }

    func show() {
        refresh()
        guard !popover.isShown, let button = menu.item.button else { return }
        // Stays open while it waits for access; otherwise a click elsewhere closes it
        popover.behavior = tap == nil ? .applicationDefined : .transient
        popover.contentSize = host.view.fittingSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        host.view.window?.makeFirstResponder(nil)  // no keyboard focus ring around the first button
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        monitor = monitor ?? NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            self?.model.listening == true ? self?.pressed(e) : e
        }
    }

    func popoverDidClose(_ notification: Notification) {
        model.listening = false
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func toggle() { if popover.isShown { popover.close() } else { show() } }

    // While listening, a press picks the extra key
    func pressed(_ e: NSEvent) -> NSEvent? {
        if e.type == .keyDown {
            if e.keyCode == 53 { model.listening = false } else { model.wrong = true }  // esc
            return nil
        }
        switch (e.keyCode, e.modifierFlags.intersection([.function, .control, .option, .shift, .command])) {
        case (59, .control): model.key = 59
        case (58, .option): model.key = 58
        case (_, []): return nil  // a key let go
        default: model.wrong = true; return nil
        }
        model.listening = false
        return nil
    }

    // No system prompt on top of Settings: Swity is dragged into the list from the guide under its window
    func grantAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        guide.show()
    }

    func keyboardSettings() {
        for pane in ["x-apple.systempreferences:com.apple.Keyboard-Settings.extension", "x-apple.systempreferences:com.apple.preference.keyboard"] {
            if NSWorkspace.shared.open(URL(string: pane)!) { return }
        }
    }
}

// MARK: - Drag-to-allow guide

// While Settings is open for access: a strip pinned to the bottom of its window, with Swity to drag into the
// list above. Settings' window is found by its pid in the window list, which needs no permission. The strip
// hides while Settings is not in front and goes away with it; a grant relaunches Swity, which ends it too.
struct GuideView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)).foregroundColor(.accentColor)
                Text(L("Drag Swity to the list above to allow access", "Перетащи Swity в список выше, чтобы дать доступ"))
                    .font(.system(size: 13)).foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                Text("Swity").font(.system(size: 14, weight: .medium))
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.08)))
        }
        .padding(14)
        .frame(width: 440)
    }
}

// The whole strip is the drag handle: what it drags is Swity.app itself, as Finder would
final class DragHandle: NSView, NSDraggingSource {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }  // no click to focus the strip first
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        let at = convert(event.locationInWindow, from: nil)
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(NSRect(x: at.x - 24, y: at.y - 24, width: 48, height: 48), contents: NSApp.applicationIconImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

final class Guide {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    var timer: Timer?
    var seen = false  // Settings may take a moment to start

    init() {
        let content = NSHostingView(rootView: GuideView())
        let size = content.fittingSize
        let back = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        back.material = .menu
        back.state = .active
        back.wantsLayer = true
        back.layer?.cornerRadius = 14
        back.layer?.masksToBounds = true
        content.frame = back.bounds
        let handle = DragHandle(frame: back.bounds)
        back.addSubview(content)
        back.addSubview(handle)
        panel.contentView = back
        panel.setContentSize(size)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false  // Swity itself is never the active app here
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show() {
        seen = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.follow() }
    }

    func follow() {
        guard tap == nil, let settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first
        else {
            if seen || tap != nil { timer?.invalidate(); panel.orderOut(nil) }
            return
        }
        seen = true
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        // Front to back. The biggest is the main window; a smaller one in front (the password prompt) hides the strip.
        let frames = windows.filter { $0[kCGWindowOwnerPID as String] as? pid_t == settings.processIdentifier
                                      && $0[kCGWindowLayer as String] as? Int == 0 }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
        guard settings.isActive, let r = frames.first, r == frames.max(by: { $0.width * $0.height < $1.width * $1.height })
        else { return panel.orderOut(nil) }
        // Window list is top-left based on the main display; AppKit is bottom-left
        let top = NSScreen.screens[0].frame.height
        panel.setFrameOrigin(NSPoint(x: r.maxX - panel.frame.width - 14, y: top - r.maxY + 14))
        panel.orderFrontRegardless()
    }
}

// MARK: - Self-update

// Self-update: swity.io/version.json names the latest DMG; a newer one is downloaded, checked to be signed by
// our own Developer ID, swapped in place of this bundle, and the app relaunches.
// Kept simple: silent, no UI, needs a writable /Applications; move to Sparkle if release notes or deltas matter.
struct Release: Decodable { let version: String; let url: URL }
// `defaults write io.swity.app updateFeed <url>` points a copy at another feed, to try an update before releasing it
let updateFeed = URL(string: UserDefaults.standard.string(forKey: "updateFeed") ?? "https://swity.io/version.json")!
let ourSignature = "identifier \"io.swity.app\" and anchor apple generic and certificate leaf[subject.OU] = \"J226WEZ2AM\""

// A build from source (ad hoc, or someone else's certificate) stays what its owner built: no self-update.
func official() -> Bool {
    var me: SecCode?
    var requirement: SecRequirement?
    SecCodeCopySelf([], &me)
    SecRequirementCreateWithString(ourSignature as CFString, [], &requirement)
    guard let me, let requirement else { return false }
    return SecCodeCheckValidity(me, [], requirement) == errSecSuccess
}

func newer(_ v: String) -> Bool { v.compare(myVersion, options: .numeric) == .orderedDescending }

func run(_ tool: String, _ args: String...) throws {
    let p = try Process.run(URL(fileURLWithPath: tool), arguments: args)
    p.waitUntilExit()
    if p.terminationStatus != 0 { throw CocoaError(.executableLoad) }
}

func checkForUpdate() {
    URLSession.shared.dataTask(with: updateFeed) { data, _, _ in
        guard let data, let release = try? JSONDecoder().decode(Release.self, from: data), newer(release.version) else { return }
        URLSession.shared.downloadTask(with: release.url) { dmg, _, _ in  // dmg is deleted when this returns
            guard let dmg = dmg else { return }
            do { try install(dmg) } catch { NSLog("Swity: update failed: \(error)") }
        }.resume()
    }.resume()
}

func install(_ dmg: URL) throws {
    let fm = FileManager.default
    let mount = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try run("/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path)
    defer { try? run("/usr/bin/hdiutil", "detach", "-force", mount.path) }
    // Stage next to the installed app (same volume) so the swap is atomic.
    let stage = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: Bundle.main.bundleURL, create: true)
    defer { try? fm.removeItem(at: stage) }  // a rejected copy is not left behind; after the swap it is empty
    let staged = stage.appendingPathComponent("Swity.app")
    try run("/usr/bin/ditto", mount.appendingPathComponent("Swity.app").path, staged.path)
    var code: SecStaticCode?
    var requirement: SecRequirement?
    SecStaticCodeCreateWithPath(staged as CFURL, [], &code)
    SecRequirementCreateWithString(ourSignature as CFString, [], &requirement)
    guard let code, let requirement, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess,
          let version = Bundle(url: staged)?.infoDictionary?["CFBundleShortVersionString"] as? String, newer(version)
    else { throw CocoaError(.fileReadCorruptFile) }  // not ours, or a stale cached DMG
    _ = try fm.replaceItemAt(Bundle.main.bundleURL, withItemAt: staged)
    try relaunch()
}

// MARK: - Launch

// Start with the Mac: a login item on macOS 13+, a launch agent before that
func startAtLogin() {
    if #available(macOS 13, *) {
        do { try SMAppService.mainApp.register() } catch { NSLog("Swity: login item: \(error)") }
        return
    }
    let agents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    let plist: NSDictionary = ["Label": "io.swity.app", "RunAtLoad": true,
                               "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath]]
    try? FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    plist.write(to: agents.appendingPathComponent("io.swity.app.plist"), atomically: true)
}

// Opening Swity while it already runs (Finder, Spotlight) shows the panel. That is also the moment to
// notice that access was taken away meanwhile: the panel then asks for it again.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if let t = tap, !allowed() {
            CFMachPortInvalidate(t)
            tap = nil
            undo = nil
            denied = true
        }
        popup.show()
        return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
let menu = StatusMenu()
let popup = Panel()
let guide = Guide()
if !Bundle.main.bundlePath.hasPrefix("/Volumes/") {  // not when launched straight from the DMG
    if !UserDefaults.standard.bool(forKey: "loginItemSet") {  // once: switched off in System Settings, it stays off
        startAtLogin()
        UserDefaults.standard.set(true, forKey: "loginItemSet")
    }
    if official() {
        checkForUpdate()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in checkForUpdate() }
    }
}
takeOverSystem()
var poweringOff = false  // logout/shutdown: keep our settings, Swity relaunches at login anyway
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
    poweringOff = true
}
NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
    guard !poweringOff else { return }
    giveBackSystem()
    // The system hears about the 🌐 change through an async message; exiting at once can drop it, leaving
    // macOS still on Do Nothing although the pref says otherwise. Give it a moment to go out.
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
}
// SIGTERM (pkill, killall, Activity Monitor's Quit) would skip willTerminate and leave 🌐 on Do Nothing.
// Kept simple: Force Quit (SIGKILL) and crashes cannot be caught; the next launch still restores on its quit.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { NSApp.terminate(nil) }
sigterm.resume()
start()
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in start() }
// The panel opens by itself until it has been seen working (the launch after the grant, with the key choice),
// and later if Input Monitoring access was taken away.
if !UserDefaults.standard.bool(forKey: "setupDone") || tap == nil {
    if tap != nil {  // the launch after the grant: on to the keys
        UserDefaults.standard.set(true, forKey: "setupDone")
        popup.model.tab = 1
    }
    DispatchQueue.main.async { popup.show() }  // once the run loop is up and the menu bar icon is on screen
}
app.run()
