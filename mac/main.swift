import Cocoa
import SwiftUI
import AVFoundation
import CoreAudio
import ServiceManagement
import Combine
import Carbon

// MARK: - Library (real recordings, see packs/LICENSES.txt)
struct KeyDef: Decodable { let d: [Int]; let u: [Int]?; let x: Double }
struct PackDef: Decodable { let id: String; let name: String; let sub: String; let file: String; let keys: [String: KeyDef] }
struct Library: Decodable { let packs: [PackDef] }

final class LoadedPack {
    var down: [Int: [AVAudioPCMBuffer]] = [:]
    var up: [Int: [AVAudioPCMBuffer]] = [:]
    var pan: [Int: Float] = [:]
}

// MARK: - Low-latency sampler
final class Sound {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    let base: URL = Bundle.main.resourceURL!.appendingPathComponent("packs")
    var lib: [PackDef] = []
    var nodes: [AVAudioPlayerNode] = []
    var next = 0
    var pack: LoadedPack?
    var token = 0
    var latencySet = false

    init() {
        if let data = try? Data(contentsOf: base.appendingPathComponent("packs.json")),
           let l = try? JSONDecoder().decode(Library.self, from: data) { lib = l.packs }
        for _ in 0..<24 {
            let n = AVAudioPlayerNode()
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: format)
            nodes.append(n)
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.start()
        }
        start()
    }

    func lowLatency() {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr else { return }
        var frames: UInt32 = 128
        var b = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectSetPropertyData(dev, &b, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
    }

    func start() {
        if engine.isRunning { return }
        if !latencySet { latencySet = true; lowLatency() }
        engine.prepare()
        do { try engine.start() } catch { return }
        for n in nodes { n.play() }
    }

    func load(_ index: Int, done: (() -> Void)? = nil) {
        guard !lib.isEmpty else { return }
        let def = lib[min(max(index, 0), lib.count - 1)]
        token += 1
        let mine = token
        DispatchQueue.global(qos: .userInitiated).async {
            let p = self.build(def)
            DispatchQueue.main.async {
                guard mine == self.token, let p = p else { return }
                self.pack = p
                done?()
            }
        }
    }

    func build(_ def: PackDef) -> LoadedPack? {
        guard let f = try? AVAudioFile(forReading: base.appendingPathComponent(def.file)),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return nil }
        do { try f.read(into: buf) } catch { return nil }
        guard let src = buf.floatChannelData?[0] else { return nil }
        let total = Int(buf.frameLength)
        var cache: [String: [AVAudioPCMBuffer]] = [:]
        func vars(_ s: [Int]) -> [AVAudioPCMBuffer] {
            let k = "\(s[0])-\(s[1])"
            if let c = cache[k] { return c }
            let v = makeVariants(src, total, s[0], s[1])
            cache[k] = v
            return v
        }
        let p = LoadedPack()
        for (k, kd) in def.keys {
            guard let code = Int(k) else { continue }
            p.down[code] = vars(kd.d)
            if let u = kd.u { p.up[code] = vars(u) }
            p.pan[code] = Float(kd.x) * 0.45
        }
        return p
    }

    // three slightly different pitches per sample, so repeated keys never sound identical
    func makeVariants(_ src: UnsafeMutablePointer<Float>, _ total: Int, _ start: Int, _ length: Int) -> [AVAudioPCMBuffer] {
        var out: [AVAudioPCMBuffer] = []
        let len = min(length, total - start)
        guard len > 8 else { return out }
        for rate in [0.975, 1.0, 1.025] {
            let n = Int(Double(len) / rate)
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { continue }
            b.frameLength = AVAudioFrameCount(n)
            let o = b.floatChannelData![0]
            for i in 0..<n {
                let pos = Double(i) * rate
                let i0 = Int(pos)
                let fr = Float(pos - Double(i0))
                let a = src[start + i0]
                let c = src[start + min(i0 + 1, len - 1)]
                let tail = min(1, Float(n - i) / 132)
                o[i] = (a + (c - a) * fr) * tail
            }
            out.append(b)
        }
        return out
    }

    func play(code: Int, down: Bool, volume: Float, stereo: Bool) {
        guard let p = pack, let buf = (down ? p.down : p.up)[code]?.randomElement() else { return }
        if !engine.isRunning { start(); if !engine.isRunning { return } }
        let n = nodes[next]
        next = (next + 1) % nodes.count
        n.volume = volume * Float.random(in: 0.9...1.0) * (down ? 1.0 : 0.85)
        n.pan = stereo ? (p.pan[code] ?? 0) : 0
        n.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
    }
}

// MARK: - Output device volume (virtual main volume, 0...1)
let vmvc = AudioObjectPropertySelector(0x766D7663)   // 'vmvc'

func outDevice() -> AudioDeviceID? {
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr, dev != 0 else { return nil }
    return dev
}

func volAddr() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: vmvc, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
}

func getVol(_ dev: AudioDeviceID) -> Float? {
    var a = volAddr()
    guard AudioObjectHasProperty(dev, &a) else { return nil }
    var v: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr else { return nil }
    return v
}

// MARK: - State
let modMasks: [Int: CGEventFlags] = [56: .maskShift, 60: .maskShift, 59: .maskControl, 62: .maskControl,
                                     58: .maskAlternate, 61: .maskAlternate, 55: .maskCommand, 54: .maskCommand,
                                     63: .maskSecondaryFn]

final class Model: ObservableObject {
    let sound = Sound()
    var held = Set<Int>()
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "on") } }
    @Published var packIndex: Int { didSet { UserDefaults.standard.set(packIndex, forKey: "pack") } }
    @Published var volume: Double { didSet { UserDefaults.standard.set(volume, forKey: "vol") } }
    @Published var release: Bool { didSet { UserDefaults.standard.set(release, forKey: "rel") } }
    @Published var stereo: Bool { didSet { UserDefaults.standard.set(stereo, forKey: "st") } }
    @Published var independent: Bool { didSet { UserDefaults.standard.set(independent, forKey: "ind") } }
    @Published var login = false
    @Published var granted = false
    @Published var stale = false

    init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "on") as? Bool ?? true
        packIndex = d.object(forKey: "pack") as? Int ?? 1
        volume = d.object(forKey: "vol") as? Double ?? 0.7
        release = d.object(forKey: "rel") as? Bool ?? true
        stereo = d.object(forKey: "st") as? Bool ?? true
        independent = d.object(forKey: "ind") as? Bool ?? true
        if #available(macOS 13.0, *) { login = SMAppService.mainApp.status == .enabled }
        sound.load(packIndex)
    }

    var gain: Float { Float(volume * volume * 1.5) }

    // Returns the digital gain to use right now. In independent mode the keyboard plays at a
    // constant level regardless of system volume: the gain is scaled to compensate for whatever
    // the system's output volume currently is. This never reads back or writes the system volume
    // itself, so pressing a key can never change the real output volume.
    func level() -> Float {
        guard independent, let dev = outDevice(), let cur = getVol(dev) else { return gain }
        let target = Float(volume)
        let c = max(cur, 0.02)
        return min(4, (target * target) / (c * c))
    }

    func hit(code: Int, down: Bool) {
        guard enabled else { return }
        if !down && !release { return }
        sound.play(code: code, down: down, volume: level(), stereo: stereo)
    }

    func modifier(code: Int, flags: CGEventFlags) {
        if code == 57 {   // caps lock only reports state changes
            hit(code: 57, down: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { self.hit(code: 57, down: false) }
            return
        }
        guard let m = modMasks[code] else { return }
        if !flags.contains(m) {
            held = held.filter { modMasks[$0] != m }
            hit(code: code, down: false)
        } else if held.contains(code) {
            held.remove(code)
            hit(code: code, down: false)
        } else {
            held.insert(code)
            hit(code: code, down: true)
        }
    }

    func select(_ i: Int) {
        packIndex = i
        sound.load(i) { self.preview() }
    }

    func preview() {
        let seq: [(Int, Double)] = [(17, 0), (4, 0.11), (14, 0.25), (49, 0.42)]
        for (code, t) in seq {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                self.sound.play(code: code, down: true, volume: self.level(), stereo: self.stereo)
            }
            if release {
                DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.07) {
                    self.sound.play(code: code, down: false, volume: self.level(), stereo: self.stereo)
                }
            }
        }
    }

    func setLogin(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {}
            login = SMAppService.mainApp.status == .enabled
        }
    }
}
let model = Model()

// MARK: - Global key listener (listen-only, never modifies typing)
var gPort: CFMachPort?
var gToggle: (() -> Void)?
var gSrc: CFRunLoopSource?
var gLastKey = Date.distantPast
var gAwaiting = false

func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
    if type == .keyDown || type == .keyUp { gLastKey = Date() }
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let p = gPort { CGEvent.tapEnable(tap: p, enable: true) }
    case .keyDown:
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { break }   // held key = no repeat clicks, like a real board
        if code == 40 && event.flags.contains([.maskControl, .maskAlternate, .maskCommand]) {
            model.enabled.toggle()   // ⌃⌥⌘K
            break
        }
        if code == 17 && event.flags.contains([.maskControl, .maskAlternate, .maskCommand]) {
            gToggle?()   // ⌃⌥⌘T opens the panel even if the menu bar icon is hidden
            break
        }
        model.hit(code: code, down: true)
    case .keyUp:
        model.hit(code: code, down: false)
    case .flagsChanged:
        model.modifier(code: code, flags: event.flags)
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

func installTap() -> Bool {
    if gPort != nil { return true }
    var mask: CGEventMask = 0
    for t in [CGEventType.keyDown, CGEventType.keyUp, CGEventType.flagsChanged] {
        mask |= CGEventMask(1) << CGEventMask(t.rawValue)
    }
    guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                       eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else { return false }
    gPort = port
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    gSrc = src
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    return true
}

func dropTap() {
    if let s = gSrc { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes); gSrc = nil }
    if let p = gPort { CGEvent.tapEnable(tap: p, enable: false); CFMachPortInvalidate(p); gPort = nil }
}

func runTool(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

func openPrivacySettings() {
    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
        NSWorkspace.shared.open(u)
    }
}

// Throws away the old (possibly stale) permission record + tap, asks again, and the app restarts itself once allowed.
func refreshPermission() {
    dropTap()
    runTool("/usr/bin/tccutil", ["reset", "ListenEvent", Bundle.main.bundleIdentifier ?? "com.local.keypheus"])
    gAwaiting = true
    _ = CGRequestListenEventAccess()
    openPrivacySettings()
}

// MARK: - UI
func spring() -> Animation {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ? .easeInOut(duration: 0.15)
        : .spring(response: 0.35, dampingFraction: 1.0)
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct PopoverView: View {
    @ObservedObject var m: Model
    @Namespace private var ns

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !m.granted || m.stale { permission }
            grid
            VStack(alignment: .leading, spacing: 4) {
                volume
                Text(m.independent ? "Plays at this level no matter the system volume" : "Follows the system volume")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                row("Independent of system volume", $m.independent)
                row("Release sound", $m.release)
                row("Stereo position", $m.stereo)
                row("Start at login", Binding(get: { m.login }, set: { m.setLogin($0) }))
            }
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("Refresh permission") { refreshPermission() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.secondary)
                }
                Text("⌃⌥⌘K toggle · ⌃⌥⌘T panel").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.8))
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    func row(_ t: String, _ b: Binding<Bool>) -> some View {
        HStack {
            Text(t).font(.system(size: 13))
            Spacer()
            Toggle("", isOn: b).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }

    var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor)
                Image(systemName: "keyboard").font(.system(size: 17, weight: .medium)).foregroundColor(.white)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Keypheus").font(.system(size: 15, weight: .semibold))
                Text(m.enabled ? "On" : "Off").font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: $m.enabled).toggleStyle(.switch).labelsHidden()
        }
    }

    var permission: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(m.granted
                 ? "Permission shows as granted, but keystrokes aren’t being heard. Refresh and grant it again."
                 : "Grant Keypheus permission in Input Monitoring to hear keystrokes.")
                .font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button("Refresh permission") { refreshPermission() }
                Button("Open Settings") { _ = CGRequestListenEventAccess(); openPrivacySettings() }
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.14)))
    }

    var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
            ForEach(0..<m.sound.lib.count, id: \.self) { i in card(i) }
        }
    }

    func card(_ i: Int) -> some View {
        let sel = m.packIndex == i
        let p = m.sound.lib[i]
        return Button {
            withAnimation(spring()) { m.select(i) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(size: 13, weight: .semibold))
                Text(p.sub).font(.system(size: 11)).opacity(0.75)
            }
            .foregroundColor(sel ? .white : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.07))
                    if sel {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor)
                            .matchedGeometryEffect(id: "sel", in: ns)
                    }
                }
            )
        }
        .buttonStyle(PressStyle())
    }

    var volume: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundColor(.secondary)
            Slider(value: $m.volume, in: 0...1)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
}

// MARK: - App
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var panel: FloatingPanel!
    var host: NSHostingView<PopoverView>!
    var timer: Timer?
    var missed = 0
    var autoTried = false
    var bag = Set<AnyCancellable>()
    var mouseMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keypheus")
            b.target = self
            b.action = #selector(toggle(_:))
        }
        model.$enabled.sink { [weak self] on in self?.item.button?.alphaValue = on ? 1.0 : 0.4 }.store(in: &bag)

        host = NSHostingView(rootView: PopoverView(m: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            host.topAnchor.constraint(equalTo: fx.topAnchor),
            host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = fx
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        gToggle = { [weak self] in self?.toggle(nil) }

        // permission banner appears/disappears -> refit the panel
        model.$granted.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self?.place() }
        }.store(in: &bag)
        model.$stale.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self?.place() }
        }.store(in: &bag)

        if !CGPreflightListenEventAccess() {
            gAwaiting = true
            _ = CGRequestListenEventAccess()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.check() }
        check()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.show() }
    }

    func check() {
        let allowed = CGPreflightListenEventAccess()
        if allowed {
            if gAwaiting { relaunch(); return }   // permission was just granted -> restart for a clean state
            _ = installTap()
        } else {
            dropTap()
        }
        if model.granted != allowed { model.granted = allowed }
        detectDeadTap(allowed)
    }

    // The system says a key was pressed but our tap heard nothing -> the permission record is stale.
    func detectDeadTap(_ allowed: Bool) {
        guard allowed, !IsSecureEventInputEnabled() else { missed = 0; return }
        let sys = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let ours = Date().timeIntervalSince(gLastKey)
        if sys < 1.2 && ours - sys > 1.0 {
            missed += 1
        } else if ours < 1.5 {
            missed = 0
            if model.stale { model.stale = false }
        }
        if missed >= 2 && !model.stale {
            model.stale = true
            if !autoTried { autoTried = true; refreshPermission() }
        }
    }

    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    // top edge is always anchored just under the menu bar, fully inside the visible screen area
    func place() {
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let bf: NSRect? = item.button?.window?.frame
        var screen = NSScreen.main ?? NSScreen.screens[0]
        if let b = bf {
            for s in NSScreen.screens where s.frame.contains(NSPoint(x: b.midX, y: b.midY)) { screen = s }
        }
        let vf = screen.visibleFrame
        var x = vf.maxX - size.width - 8
        if let b = bf, screen.frame.contains(NSPoint(x: b.midX, y: b.midY)) { x = b.midX - size.width / 2 }
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        let h = min(size.height, vf.height - 16)
        panel.setFrame(NSRect(x: x, y: vf.maxY - h - 6, width: size.width, height: h), display: true)
    }

    @objc func toggle(_ sender: Any?) {
        if panel.isVisible { hide() } else { show() }
    }

    func show() {
        place()
        let dur = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.0 : 0.16
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = dur
            panel.animator().alphaValue = 1
        }
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hide()
            }
        }
    }

    func hide() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        panel.orderOut(nil)
    }
}

signal(SIGTERM, SIG_IGN)
let termSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSrc.setEventHandler { exit(0) }
termSrc.resume()

let delegate = AppDelegate()
let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory)
nsApp.delegate = delegate
nsApp.run()
