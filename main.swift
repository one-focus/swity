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

// fn: switch the moment it goes down. ctrl/alt/cmd/shift already held = a shortcut, skip.
// A key pressed while fn is held makes it a combo (fn+arrow, fn+delete, fn+F): the switch is taken back.
// Key presses are only counted as "a key went down with fn held"; which key it was is never read.
let callback: CGEventTapCallBack = { _, type, event, _ in
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    if type == .flagsChanged { lastKeyboard = event.getIntegerValueField(.keyboardEventKeyboardType) }
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
    } else if code == 59, !withFn.contains(Int(lastKeyboard)) {  // kVK_Control, the left one
        if event.flags.contains(.maskControl) {  // down
            armed = event.flags.isDisjoint(with: [.maskShift, .maskAlternate, .maskCommand, .maskSecondaryFn]) ? CFAbsoluteTimeGetCurrent() : nil
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

    // Everything fine: a short menu. Something to do (access, macOS switching too): the panel with one button.
    @objc func click() {
        if NSApp.currentEvent?.type != .rightMouseUp, tap == nil || !fnFree() || popup.popover.isShown { return popup.toggle() }
        open()
    }

    func open() {
        let m = NSMenu()
        m.addItem(withTitle: "Swity \(myVersion)", action: nil, keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: L("Quit Swity", "Выйти из Swity"), action: #selector(NSApplication.terminate), keyEquivalent: "q")
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }
}

// MARK: - Panel

// The panel that drops from the menu bar icon when there is something to do: grant access, or switch off
// macOS's own 🌐 action. Drawn like swity.io: oat page, white card, ink text, the download button's tangerine.
let ink = Color(red: 21 / 255, green: 23 / 255, blue: 26 / 255)
let ink2 = Color(red: 86 / 255, green: 91 / 255, blue: 99 / 255)
let ink3 = Color(red: 105 / 255, green: 110 / 255, blue: 118 / 255)
let oat = Color(red: 246 / 255, green: 244 / 255, blue: 238 / 255)
let hairline = Color(red: 228 / 255, green: 224 / 255, blue: 211 / 255)
let tangerine = Color(red: 1, green: 120 / 255, blue: 61 / 255)

final class PanelModel: ObservableObject {
    @Published var access = false
    @Published var fnFree = true
}

struct Primary: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold)).foregroundColor(ink)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 16).frame(height: 34)
            .background(Capsule().fill(LinearGradient(gradient: Gradient(colors: [Color(red: 1, green: 145 / 255, blue: 96 / 255), tangerine]),
                                                      startPoint: .top, endPoint: .bottom)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct PanelView: View {
    @ObservedObject var m: PanelModel
    let p: Panel

    func row<Actions: View>(mark: String?, _ title: String, _ hint: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let mark = mark { Image(systemName: mark).foregroundColor(tangerine) }
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(ink)
                }
                Text(hint).font(.system(size: 12)).foregroundColor(ink2).fixedSize(horizontal: false, vertical: true)
            }
            actions()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    // What to do next, or that there is nothing to do: the tap exists and macOS is not switching as well
    @ViewBuilder var working: some View {
        if !m.access {
            row(mark: "exclamationmark.circle.fill", L("Let Swity see the 🌐 key", "Дай Swity видеть клавишу 🌐"),
                L("Allow Input Monitoring in System Settings.", "Разреши «Мониторинг ввода» в Системных настройках.")) {
                Button(L("Grant Access", "Дать доступ")) { p.grantAccess() }.buttonStyle(Primary())
            }
        } else if !m.fnFree {
            row(mark: "exclamationmark.circle.fill", L("macOS switches too", "macOS тоже переключает"),
                L("Set “Press 🌐 key to” to “Do Nothing”.", "Поставь «Нажатие клавиши 🌐» в «Не выполнять действие».")) {
                Button(L("Open Keyboard Settings", "Открыть настройки клавиатуры")) { p.keyboardSettings() }.buttonStyle(Primary())
            }
        } else {
            row(mark: nil, L("Works", "Работает"), L("fn switches the layout on the first press.", "fn меняет раскладку с первого нажатия.")) {}
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Swity").font(.system(size: 20, weight: .bold)).foregroundColor(ink)
                Spacer()
                Text(myVersion).font(.system(size: 12)).foregroundColor(ink3)
            }
            working
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(hairline))
        }
        .padding(16)
        .frame(width: 320)
        .background(oat)
        // Light whatever the system is: older macOS gives SwiftUI the dark scheme even in an aqua window
        .environment(\.colorScheme, .light)
    }
}

final class Panel: NSObject {
    let model = PanelModel()
    let popover = NSPopover()
    var host: NSHostingController<PanelView>!

    override init() {
        super.init()
        host = NSHostingController(rootView: PanelView(m: model, p: self))
        popover.contentViewController = host
        popover.appearance = NSAppearance(named: .aqua)
        refresh()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            if self?.popover.isShown == true { self?.refresh() }
        }
    }

    func refresh() {
        let free = fnFree()
        guard model.access != (tap != nil) || model.fnFree != free else { return }
        model.access = tap != nil
        model.fnFree = free
        DispatchQueue.main.async { [self] in popover.contentSize = host.view.fittingSize }  // rows come and go
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
    }

    func toggle() { if popover.isShown { popover.close() } else { show() } }

    func grantAccess() {
        CGRequestListenEventAccess()  // adds Swity to the Input Monitoring list
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    func keyboardSettings() {
        for pane in ["x-apple.systempreferences:com.apple.Keyboard-Settings.extension", "x-apple.systempreferences:com.apple.preference.keyboard"] {
            if NSWorkspace.shared.open(URL(string: pane)!) { return }
        }
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
// The panel opens by itself on the first launch, and later if Input Monitoring access was taken away.
if !UserDefaults.standard.bool(forKey: "setupDone") || tap == nil {
    UserDefaults.standard.set(true, forKey: "setupDone")
    DispatchQueue.main.async { popup.show() }  // once the run loop is up and the menu bar icon is on screen
}
app.run()
