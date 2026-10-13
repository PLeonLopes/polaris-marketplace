// polaris-monitor window for macOS: the same card as window.ps1, in Swift and AppKit. An
// always-on-top card in the bottom-right corner that lists the Claude Code sessions recorded
// by session.sh, with the usage limits saved by statusline.sh. It never reads the Claude
// login or calls an API.
//
// /polaris-monitor:open-window copies this file, mascots.json and themes.json to
// ~/.polaris-monitor, compiles the window there (xcrun swiftc -swift-version 5 -O) and starts
// it. A lock on window.lock keeps a single window; when the binary changes (a newer plugin
// version was compiled), the open window exits and the new one, which waits up to 5 seconds
// for the lock, takes over.
//
// Dots: green (pulsing) working, red finished, blue asked a question, yellow waiting for
// permission. The mascot walks around the card while a session works, jumps on top while
// one waits for you and stands still otherwise. Drag with the left button; the arrow on a
// session with subagents collapses its subagent rows; right-click for the options, which
// are saved in config.json (the Windows window reads the same file).
//
// Mascots and color themes come from mascots.json and themes.json next to the binary, plus
// the user's own in <folder>/custom/, which add to or replace them and are never overwritten.
// The window reloads them within 2 seconds of a change.
//
// Testing: --snapshot out.png draws the window, saves the PNG and, next to it, out.png.txt
// with what the window saw, then exits. --folder replaces ~/.polaris-monitor, --usage reads
// the usage from that file whatever its age, and --pulse sets the phase of the working dot
// (0 = brightest, 0.5 = dimmest).
import Cocoa

let environment = ProcessInfo.processInfo.environment
let home = environment["HOME"] ?? NSHomeDirectory()
let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    if let i = arguments.firstIndex(of: name), i + 1 < arguments.count { return arguments[i + 1] }
    return nil
}
let snapshotFile = argument("--snapshot")
let folder = argument("--folder") ?? home + "/.polaris-monitor"
let sessionsDir = folder + "/sessions"
let fileSystem = FileManager.default

try? fileSystem.createDirectory(atPath: folder, withIntermediateDirectories: true)

func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

func matches(_ pattern: String, _ text: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}
func isColor(_ value: Any?) -> Bool {
    guard let s = value as? String else { return false }
    return matches("^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$", s)
}
func isKey(_ value: Any?) -> Bool {
    guard let s = value as? String else { return false }
    return matches("^[a-z0-9-]{1,32}$", s)
}
func isValidId(_ id: String) -> Bool { matches("^[A-Za-z0-9_-]{1,128}$", id) }

func hex(_ code: String) -> NSColor {
    var s = code.hasPrefix("#") ? String(code.dropFirst()) : code
    var alpha: CGFloat = 1
    if s.count == 8 {
        alpha = CGFloat(Int(s.prefix(2), radix: 16) ?? 255) / 255
        s = String(s.dropFirst(2))
    }
    let v = Int(s, radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
}

func modificationDate(_ path: String) -> Date? {
    (try? fileSystem.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}
let binary = Bundle.main.executablePath ?? arguments[0]
let version = modificationDate(binary)

// --- Mascots and themes: the plugin's files, then the user's in custom/ (same key replaces).
let assetsDir = (binary as NSString).deletingLastPathComponent
let assetFiles: [(kind: String, path: String)] = [
    ("mascots", assetsDir + "/mascots.json"), ("themes", assetsDir + "/themes.json"),
    ("mascots", folder + "/custom/mascots.json"), ("themes", folder + "/custom/themes.json"),
]
// The Dark theme, also the fallback for any color a theme leaves out or gets wrong.
let themeColors = ["card", "text", "muted", "faint", "accent", "divider", "track", "bar", "barWarning",
                   "barCritical", "working", "finished", "question", "permission"]
let defaultTheme: [String: String] = [
    "card": "#F21C1D2F", "text": "#FFFFFF", "muted": "#A6A5C4", "faint": "#7C7F9E", "accent": "#DEDAF4",
    "divider": "#33FFFFFF", "track": "#33365A", "bar": "#699BFB", "barWarning": "#F59E0B", "barCritical": "#EF4444",
    "working": "#22C55E", "finished": "#EF4444", "question": "#699BFB", "permission": "#FACC15",
]
let sizes: [(key: String, label: String, scale: CGFloat)] = [("small", "Small", 0.85), ("normal", "Normal", 1), ("large", "Large", 1.25)]

struct Theme {
    let name: String
    let colors: [String: String]
    func color(_ key: String) -> NSColor { hex(colors[key] ?? defaultTheme[key] ?? "#FFFFFF") }
}

// Sprite characters: '#' body, 'o' eyes and 'u' smile (the face color), 'A' and 'B' the two
// pairs of feet, which alternate while walking. The origin (0,0) is between the feet, so the
// mascot stands on the card's edge.
struct Mascot {
    let name: String
    let sprite: [String]
    let pw: CGFloat
    let ph: CGFloat
    let body: String
    let face: String
    let feet: String
    let outline: String?
}

// A mascot needs a rectangular sprite and a pixel size that keep it within 32 px of height
// (the room above the card) and 64 px of width; its colors must be hex.
func mascot(_ key: String, _ entry: Any) -> Mascot? {
    guard let e = entry as? [String: Any], let sprite = e["sprite"] as? [String], let first = sprite.first,
          !first.isEmpty, sprite.allSatisfy({ $0.count == first.count }),
          let pixel = e["pixel"] as? [Any], pixel.count == 2, let pw = number(pixel[0]), let ph = number(pixel[1]),
          pw >= 0.5, ph >= 0.5, Double(sprite.count) * ph <= 32, Double(first.count) * pw <= 64,
          let colors = e["colors"] as? [String: Any],
          isColor(colors["body"]), isColor(colors["face"]), isColor(colors["feet"]),
          colors["outline"] == nil || isColor(colors["outline"]) else { return nil }
    let name = (e["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    return Mascot(name: name.isEmpty ? key : name, sprite: sprite, pw: CGFloat(pw), ph: CGFloat(ph),
                  body: colors["body"] as! String, face: colors["face"] as! String,
                  feet: colors["feet"] as! String, outline: colors["outline"] as? String)
}

var mascots: [(key: String, mascot: Mascot)] = []
var themes: [(key: String, theme: Theme)] = []
var assetStamps = ""
func currentAssetStamps() -> String {
    assetFiles.map { f in modificationDate(f.path).map { "\($0.timeIntervalSince1970)" } ?? "0" }.joined(separator: ",")
}
func upsert<T>(_ list: inout [(key: String, value: T)], _ key: String, _ value: T) {
    if let i = list.firstIndex(where: { $0.key == key }) { list[i].value = value } else { list.append((key, value)) }
}
func loadAssets() {
    var newMascots: [(key: String, value: Mascot)] = []
    var newThemes: [(key: String, value: Theme)] = [("dark", Theme(name: "Dark", colors: defaultTheme))]
    for file in assetFiles {
        guard let data = fileSystem.contents(atPath: file.path),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
        for key in o.keys.sorted() where isKey(key) {
            if file.kind == "mascots" {
                if let m = mascot(key, o[key]!) { upsert(&newMascots, key, m) }
            } else if let t = o[key] as? [String: Any] {
                var colors = defaultTheme
                for c in themeColors where isColor(t[c]) { colors[c] = t[c] as? String }
                upsert(&newThemes, key, Theme(name: t["name"] as? String ?? key, colors: colors))
            }
        }
    }
    // JSON objects carry no order: the plugin's built-ins first, then the rest by name
    func order(_ key: String) -> Int { ["star": 0, "clawd": 1, "dark": 0, "light": 1, "midnight": 2, "contrast": 3][key] ?? 9 }
    mascots = newMascots.sorted { (order($0.key), $0.key) < (order($1.key), $1.key) }.map { (key: $0.key, mascot: $0.value) }
    themes = newThemes.sorted { (order($0.key), $0.key) < (order($1.key), $1.key) }.map { (key: $0.key, theme: $0.value) }
    assetStamps = currentAssetStamps()
}
loadAssets()

// --- Options (right-click), saved in config.json; without the file, the defaults.
struct Config {
    var opacity = 1.0
    var mascot = true
    var character = "star"
    var theme = "dark"
    var size = "normal"
    var volume = 1.0
    var usage = true
    var sound = false
    var subagents = true
}
let configFile = folder + "/config.json"
var config = Config()
if let data = fileSystem.contents(atPath: configFile),
   let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
    if let v = number(saved["opacity"]) { config.opacity = min(1, max(0.2, v)) }
    if let v = number(saved["volume"]) { config.volume = min(1, max(0, v)) }
    if let v = saved["mascot"] as? Bool { config.mascot = v }
    if let v = saved["usage"] as? Bool { config.usage = v }
    if let v = saved["sound"] as? Bool { config.sound = v }
    if let v = saved["subagents"] as? Bool { config.subagents = v }
    if isKey(saved["character"]) { config.character = saved["character"] as! String }
    if isKey(saved["theme"]) { config.theme = saved["theme"] as! String }
    if isKey(saved["size"]) { config.size = saved["size"] as! String }
}
func saveConfig() {
    let saved: [String: Any] = [
        "opacity": config.opacity, "mascot": config.mascot, "character": config.character, "theme": config.theme,
        "size": config.size, "volume": config.volume, "usage": config.usage, "sound": config.sound,
        "subagents": config.subagents,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: saved) { try? data.write(to: URL(fileURLWithPath: configFile)) }
}
// a choice that no longer exists (a removed custom file) falls back to the default
func themeKey() -> String { themes.contains { $0.key == config.theme } ? config.theme : "dark" }
func theme() -> Theme { themes.first { $0.key == themeKey() }?.theme ?? Theme(name: "Dark", colors: defaultTheme) }
func sizeKey() -> String { sizes.contains { $0.key == config.size } ? config.size : "normal" }
func scale() -> CGFloat { sizes.first { $0.key == sizeKey() }?.scale ?? 1 }
func mascotKey() -> String? {
    if mascots.contains(where: { $0.key == config.character }) { return config.character }
    if mascots.contains(where: { $0.key == "star" }) { return "star" }
    return mascots.first?.key
}

// Single window: wait up to 5 s for the lock, held by a window that is closing after an update.
// The descriptor stays open (and the lock held) until the process exits.
if snapshotFile == nil {
    let lock = open(folder + "/window.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    var locked = false
    if lock >= 0 {
        for _ in 0..<50 {
            if flock(lock, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            usleep(100_000)
        }
    }
    if !locked { exit(0) }
}

let tooltips = ["working": "working", "finished": "finished", "question": "asked you a question",
                "permission": "waiting for permission"]

// --- Sounds: off by default (the hooks already beep). Custom files in sounds/ replace the
// macOS ones: question, finished and all-done, as .wav or .mp3.
func customSound(_ name: String) -> String? {
    for ext in ["wav", "mp3"] {
        let file = folder + "/sounds/" + name + "." + ext
        if let type = (try? fileSystem.attributesOfItem(atPath: file))?[.type] as? FileAttributeType, type == .typeRegular {
            return file
        }
    }
    return nil
}
let systemSounds = ["question": "Ping", "finished": "Glass", "all-done": "Hero"]
var playing: NSSound?  // keeps the sound alive until it finishes
func play(_ name: String) {
    guard config.sound, config.volume > 0 else { return }
    var sound: NSSound?
    if let file = customSound(name) { sound = NSSound(contentsOfFile: file, byReference: true) }
    if sound == nil, let system = systemSounds[name] { sound = NSSound(named: NSSound.Name(system)) }
    playing?.stop()
    playing = sound
    sound?.volume = Float(config.volume)
    sound?.play()
}

// --- Sessions
struct Subagent { let type: String; let desc: String; let since: Double }
struct Session {
    var id: String
    var name: String
    var state: String
    var since: Double
    var updated: Double
    var pid: Int32?
    var transcript: String
    var situation = ""
    var subagents: [Subagent] = []
}

// Transcripts: only regular files (no links) whose real path is under the Claude config
// directory's projects folder. The path comes from a session file anything could write.
let configDir = environment["CLAUDE_CONFIG_DIR"] ?? home + "/.claude"
let projectsRoot = URL(fileURLWithPath: configDir + "/projects").resolvingSymlinksInPath().path + "/"
func safeTranscript(_ path: String) -> String? {
    guard !path.isEmpty,
          let type = (try? fileSystem.attributesOfItem(atPath: path))?[.type] as? FileAttributeType,
          type == .typeRegular else { return nil }
    let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    return real.hasPrefix(projectsRoot) ? real : nil
}

// The /rename title ("custom-title") wins over the automatic one ("ai-title"). Reads only the
// part of the transcript added since the last read, and never half a line.
final class TitleRead { var read: UInt64 = 0; var custom: String?; var ai: String? }
var titles: [String: TitleRead] = [:]
let aiTitleMark = Data("\"type\":\"ai-title\"".utf8)
let customTitleMark = Data("\"type\":\"custom-title\"".utf8)
func title(_ original: String) -> String? {
    guard let transcript = safeTranscript(original) else { return nil }
    let t = titles[transcript] ?? TitleRead()
    titles[transcript] = t
    guard let handle = FileHandle(forReadingAtPath: transcript) else { return t.custom ?? t.ai }
    defer { handle.closeFile() }
    let size = handle.seekToEndOfFile()
    if size < t.read { t.read = 0; t.custom = nil; t.ai = nil }
    if size > t.read {
        handle.seek(toFileOffset: t.read)
        let data = handle.readData(ofLength: Int(size - t.read))
        if let end = data.lastIndex(of: 10) {
            let complete = data[data.startIndex...end]
            t.read += UInt64(complete.count)
            for line in complete.split(separator: 10) {
                guard line.range(of: aiTitleMark) != nil || line.range(of: customTitleMark) != nil,
                      let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                if o["type"] as? String == "custom-title", let v = o["customTitle"] as? String, !v.isEmpty { t.custom = v }
                if o["type"] as? String == "ai-title", let v = o["aiTitle"] as? String, !v.isEmpty { t.ai = v }
            }
        }
    }
    return t.custom ?? t.ai
}

// What the last message of the conversation asks for: "box" (an open AskUserQuestion), "text"
// (a reply ending in a question) or nothing. Reads only the end of the transcript, and only
// when its size changed.
final class RequestRead { var size: UInt64 = 0; var result: String? }
var requests: [String: RequestRead] = [:]
func lastRequest(_ original: String) -> String? {
    guard let transcript = safeTranscript(original), let handle = FileHandle(forReadingAtPath: transcript) else { return nil }
    defer { handle.closeFile() }
    let size = handle.seekToEndOfFile()
    if let cached = requests[transcript], cached.size == size { return cached.result }
    let count = min(size, 65536)
    handle.seek(toFileOffset: size - count)
    var lines = handle.readData(ofLength: Int(count)).split(separator: 10)
    if count < size, !lines.isEmpty { lines.removeFirst() }  // read from the middle: the first line may be cut
    var result: String?
    for line in lines.reversed() {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
        let type = o["type"] as? String
        if type != "assistant" && type != "user" { continue }
        if o["isSidechain"] as? Bool == true { continue }
        if type == "assistant", let block = ((o["message"] as? [String: Any])?["content"] as? [[String: Any]])?.last {
            if block["type"] as? String == "tool_use" {
                if block["name"] as? String == "AskUserQuestion" { result = "box" }
            } else if block["type"] as? String == "text", let text = block["text"] as? String {
                // a "?" inside quotes or backticks is a quotation, not a question for you
                let last = (text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "")
                    .replacingOccurrences(of: "\"[^\"]*\"|`[^`]*`", with: "", options: .regularExpression)
                if last.contains("?") { result = "text" }
            }
        }
        break
    }
    let cached = RequestRead()
    cached.size = size
    cached.result = result
    requests[transcript] = cached
    return result
}

// The situation, from the hook state and the last message. Working and permission only turn
// into a question with the box (a "?" in the middle of the work does not count).
func situation(_ s: Session) -> String {
    var state = s.state
    // approving a permission fires no hook until the session stops: if the transcript changed
    // after the request, the session went back to work
    if state == "permission", let safe = safeTranscript(s.transcript), let changed = modificationDate(safe),
       changed.timeIntervalSince1970 > s.since + 2 {
        state = "working"
    }
    let request = lastRequest(s.transcript)
    if state == "working" || state == "permission" { return request == "box" ? "question" : state }
    return request != nil ? "question" : "finished"
}

// A session is alive while its process runs; without a process id, while it was updated in
// the last 6 hours. Files of dead sessions are deleted.
func readSessions(now: Double) -> [Session] {
    guard let files = try? fileSystem.contentsOfDirectory(atPath: sessionsDir) else { return [] }
    var seen: [String: Session] = [:]
    for file in files where file.hasSuffix(".json") {
        let id = String(file.dropLast(5))
        let path = sessionsDir + "/" + file
        guard isValidId(id), let data = fileSystem.contents(atPath: path),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
        let pid = number(d["pid"]).flatMap { Int32(exactly: $0) }
        let updated = number(d["updated"]) ?? 0
        let alive: Bool
        if let p = pid, p > 0 {
            alive = kill(p, 0) == 0 || errno == EPERM
        } else {
            alive = now - updated <= 6 * 3600
        }
        if !alive {
            try? fileSystem.removeItem(atPath: path)
            continue
        }
        let transcript = d["transcript"] as? String ?? ""
        var s = Session(id: id, name: title(transcript) ?? (d["name"] as? String ?? "session"),
                        state: d["state"] as? String ?? "waiting", since: number(d["since"]) ?? updated,
                        updated: updated, pid: pid, transcript: transcript)
        if let list = d["subagents"] as? [Any] {
            for item in list {
                guard let sub = item as? [String: Any], sub["id"] is String else { continue }
                s.subagents.append(Subagent(type: sub["type"] as? String ?? "agent",
                                            desc: sub["desc"] as? String ?? "",
                                            since: number(sub["since"]) ?? updated))
            }
        }
        let key = pid.map { "pid:\($0)" } ?? "id:\(id)"
        if let other = seen[key], other.updated >= s.updated { continue }
        seen[key] = s
    }
    return seen.values.map { s -> Session in
        var s = s
        s.situation = situation(s)
        return s
    }.sorted { $0.updated > $1.updated }
}

// A sound when a session changes to finished, question or permission (once per change, never
// on opening). A question wins over finished; when the last session finishes and nothing
// else runs or waits, the all-done sound.
var lastSituation: [String: String] = [:]
// Snapshot: start from the situations in previous.json, to see which sound would play
if snapshotFile != nil, let data = fileSystem.contents(atPath: folder + "/previous.json"),
   let previous = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
    lastSituation = previous
}
var soundChosen: String?
func notice(_ sessions: [Session]) {
    var chosen: String?
    for s in sessions {
        if let before = lastSituation[s.id], before != s.situation, s.situation != "working",
           chosen != "permission", chosen != "question" {
            chosen = s.situation
        }
        lastSituation[s.id] = s.situation
    }
    guard let c = chosen else { return }
    var name = c == "finished" ? "finished" : "question"
    if c == "finished", sessions.allSatisfy({ $0.situation == "finished" }) { name = "all-done" }
    soundChosen = name
    if snapshotFile == nil { play(name) }
}

// "now", "12m", "1h05", "3d4h"
func elapsed(_ minutes: Double) -> String {
    guard minutes.isFinite else { return "" }
    let m = max(0, Int(minutes.rounded(.down)))
    if m < 1 { return "now" }
    if m < 60 { return "\(m)m" }
    if m < 1440 { return "\(m / 60)h" + (m % 60 < 10 ? "0" : "") + "\(m % 60)" }
    return "\(m / 1440)d\((m % 1440) / 60)h"
}

// --- Usage, from the file the status line saves; older than 1 hour means unavailable.
struct Meter { let label: String; let percent: Double; let resets: Date? }
var usage: [Meter]?
var nextUsageRead = Date.distantPast
func readUsage(_ path: String, anyAge: Bool = false) -> [Meter]? {
    guard let data = fileSystem.contents(atPath: path),
          let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    if !anyAge {
        guard let updated = number(o["updated"]), Date().timeIntervalSince1970 - updated <= 3600 else { return nil }
    }
    let meters = [("5h", o["five_hour"]), ("7d", o["seven_day"])].compactMap { pair -> Meter? in
        guard let w = pair.1 as? [String: Any], let percent = number(w["used_percentage"]) else { return nil }
        return Meter(label: pair.0, percent: percent, resets: number(w["resets_at"]).map { Date(timeIntervalSince1970: $0) })
    }
    return meters.isEmpty ? nil : meters
}
func refreshUsage() {
    if snapshotFile != nil {
        if usage == nil, let file = argument("--usage") { usage = readUsage(file, anyAge: true) }
        return
    }
    guard config.usage, Date() >= nextUsageRead else { return }
    nextUsageRead = Date().addingTimeInterval(10)
    usage = readUsage(folder + "/usage.json")
}

// --- Drawing, in a fixed 320x440 layout that the size option scales
let windowWidth: CGFloat = 320, windowHeight: CGFloat = 440  // the rest of the window is transparent
let margin: CGFloat = 34                                     // room around the card, where the mascot walks
let cardWidth: CGFloat = 242
let font = NSFont(name: "Inter", size: 12) ?? NSFont.systemFont(ofSize: 12)

func drawText(_ s: String, _ color: NSColor, _ r: NSRect, _ alignment: NSTextAlignment = .left, size: CGFloat? = nil) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    paragraph.alignment = alignment
    let f = size.map { NSFont.systemFont(ofSize: $0) } ?? font
    let h = ceil(f.ascender - f.descender)
    (s as NSString).draw(in: NSRect(x: r.minX, y: r.minY + (r.height - h) / 2, width: r.width, height: h + 1),
                         withAttributes: [.font: f, .foregroundColor: color, .paragraphStyle: paragraph])
}

final class Root: NSView {
    override var isFlipped: Bool { true }
}

// Working: the green dot pulses, for anyone who cannot tell green from red. Opacity
// 0.65 + 0.35 * cos(2 pi phase), a full cycle in 1.6 s; the snapshot uses --pulse.
func pulseOpacity() -> CGFloat {
    let phase = snapshotFile != nil ? Double(argument("--pulse") ?? "0") ?? 0
        : Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
    return CGFloat(0.65 + 0.35 * cos(2 * Double.pi * phase))
}

struct Row { let id: String; let situation: String; let name: String; let elapsed: String; let tooltip: String }
struct ChildRow { let type: String; let text: String; let elapsed: String }

final class Options: NSObject {
    @objc func toggleMascot(_ item: NSMenuItem) { config.mascot.toggle(); saveConfig(); applyConfig() }
    @objc func chooseMascot(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        config.character = key
        saveConfig()
        applyConfig()
    }
    @objc func chooseTheme(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        config.theme = key
        saveConfig()
        applyConfig()
    }
    @objc func chooseSize(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        config.size = key
        saveConfig()
        applySize()
    }
    @objc func toggleUsage(_ item: NSMenuItem) {
        config.usage.toggle()
        if config.usage { nextUsageRead = Date.distantPast } else { usage = nil }
        saveConfig()
        update()
    }
    @objc func toggleSound(_ item: NSMenuItem) { config.sound.toggle(); saveConfig() }
    @objc func toggleSubagents(_ item: NSMenuItem) { config.subagents.toggle(); saveConfig(); update() }
    // deletes the session's state file; a live session comes back on its next hook event
    @objc func removeSession(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, isValidId(id) else { return }
        try? fileSystem.removeItem(atPath: sessionsDir + "/" + id + ".json")
        update()
    }
    @objc func opacityChanged(_ slider: NSSlider) {
        config.opacity = slider.doubleValue.rounded() / 100
        label(slider)
        saveConfig()
        applyConfig()
    }
    @objc func volumeChanged(_ slider: NSSlider) {
        config.volume = slider.doubleValue.rounded() / 100
        label(slider)
        saveConfig()
    }
    func label(_ slider: NSSlider) {
        (slider.superview?.viewWithTag(1) as? NSTextField)?.stringValue = "\(Int(slider.doubleValue.rounded()))%"
    }
    func sliderItem(_ name: String, _ minimum: Double, _ value: Double, _ action: Selector) -> NSMenuItem {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 26))
        let caption = NSTextField(labelWithString: name)
        caption.font = NSFont.menuFont(ofSize: 0)
        caption.frame = NSRect(x: 20, y: 4, width: 72, height: 18)
        let slider = NSSlider(value: value, minValue: minimum, maxValue: 100, target: self, action: action)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.frame = NSRect(x: 92, y: 3, width: 94, height: 20)
        let percent = NSTextField(labelWithString: "\(Int(value.rounded()))%")
        percent.font = NSFont.menuFont(ofSize: 12)
        percent.textColor = .secondaryLabelColor
        percent.alignment = .right
        percent.tag = 1
        percent.frame = NSRect(x: 186, y: 4, width: 36, height: 18)
        for view in [caption, slider, percent] as [NSView] { box.addSubview(view) }
        let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        item.view = box
        return item
    }
}
let options = Options()

final class Card: NSView {
    var rows: [Row] = []
    var children: [String: [ChildRow]] = [:]  // subagent rows by session id, 17 pt each
    var collapsed: Set<String> = []           // sessions whose subagent rows are hidden (until the window closes)
    var tooltipOwners: [NSString] = []        // tooltips do not retain their owner
    var scrollTimer: Timer?                   // redraws while a subagent row scrolls
    let childWidth: CGFloat = 144
    let childFont = NSFont.systemFont(ofSize: 11)
    let slotX: CGFloat = 168, slotWidth: CGFloat = 28  // the arrow slot, right before the elapsed time
    override var isFlipped: Bool { true }

    func visibleChildren(_ id: String) -> [ChildRow] { collapsed.contains(id) ? [] : (children[id] ?? []) }
    func hasChildren(_ id: String) -> Bool { !(children[id]?.isEmpty ?? true) }
    // top y of session row i (the subagent rows above included)
    func rowTop(_ i: Int) -> CGFloat {
        var y: CGFloat = 6
        for j in 0..<i { y += 20 + CGFloat(visibleChildren(rows[j].id).count) * 17 }
        return y
    }
    func textWidth(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: childFont]).width }
    func color(_ situation: String) -> NSColor { tooltips[situation] != nil ? theme().color(situation) : theme().color("muted") }

    // the redraw timer runs only while a visible subagent row is wider than its text area
    func updateScrolling() {
        let scrolls = snapshotFile == nil && rows.contains(where: { r in
            visibleChildren(r.id).contains(where: { textWidth($0.text) > childWidth + 1 })
        })
        if scrolls && scrollTimer == nil {
            scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
                self?.needsDisplay = true
            }
        } else if !scrolls, let t = scrollTimer {
            t.invalidate()
            scrollTimer = nil
        }
    }

    // a subagent row's text: plain when it fits; otherwise it slides sideways, the offset taken
    // from the clock so the rebuild every 2 s does not restart it
    func drawChild(_ text: String, _ r: NSRect) {
        let color = theme().color("muted")
        let w = textWidth(text)
        guard snapshotFile == nil, w > childWidth + 1, let ctx = NSGraphicsContext.current?.cgContext else {
            drawText(text, color, r, size: 11)
            return
        }
        let overflow = Double(w - childWidth)
        let target = overflow + 4
        let slide = max(1.5, overflow / 25)
        let cycle = 2 * slide + 2.4
        let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        var offset = 0.0
        if phase < 1.2 {
            offset = 0
        } else if phase < 1.2 + slide {
            offset = target * (phase - 1.2) / slide
        } else if phase < 2.4 + slide {
            offset = target
        } else {
            offset = target * (1 - (phase - 2.4 - slide) / slide)
        }
        let h = ceil(childFont.ascender - childFont.descender)
        ctx.saveGState()
        ctx.clip(to: r)
        (text as NSString).draw(at: NSPoint(x: r.minX - CGFloat(offset), y: r.minY + (r.height - h) / 2),
                                withAttributes: [.font: childFont, .foregroundColor: color])
        ctx.restoreGState()
    }

    // pinned to the bottom-right corner, growing upwards
    func arrange() {
        let sessionRows = CGFloat(max(rows.count, 1))
        let meters = CGFloat(max(usage?.count ?? 1, 1))
        let childRows = rows.reduce(CGFloat(0)) { $0 + CGFloat(visibleChildren($1.id).count) } * 17
        let h = 6 + sessionRows * 20 + childRows + 10 + meters * 20 + 6
        frame = NSRect(x: windowWidth - margin - cardWidth, y: windowHeight - margin - h, width: cardWidth, height: h)
        removeAllToolTips()
        tooltipOwners = []
        func tip(_ text: String, _ rect: NSRect) {
            tooltipOwners.append(text as NSString)
            addToolTip(rect, owner: tooltipOwners[tooltipOwners.count - 1], userData: nil)
        }
        for (i, r) in rows.enumerated() {
            let top = rowTop(i)
            if hasChildren(r.id) {
                // split around the arrow slot, so the tooltip rects do not overlap
                tip(r.tooltip, NSRect(x: 0, y: top, width: slotX, height: 20))
                tip(r.tooltip, NSRect(x: slotX + slotWidth, y: top, width: cardWidth - slotX - slotWidth, height: 20))
                tip(collapsed.contains(r.id) ? "Show subagents" : "Hide subagents", NSRect(x: slotX, y: top, width: slotWidth, height: 20))
            } else {
                tip(r.tooltip, NSRect(x: 0, y: top, width: cardWidth, height: 20))
            }
            for (k, child) in visibleChildren(r.id).enumerated() {
                tip("\(child.type): \(child.text)", NSRect(x: 0, y: top + 20 + CGFloat(k) * 17, width: cardWidth, height: 17))
            }
        }
        updateScrolling()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = theme()
        // the opacity option: the whole card in one transparency layer, like WPF's Opacity
        let layer = config.opacity < 1 ? NSGraphicsContext.current?.cgContext : nil
        layer?.saveGState()
        layer?.setAlpha(CGFloat(config.opacity))
        layer?.beginTransparencyLayer(auxiliaryInfo: nil)
        defer {
            layer?.endTransparencyLayer()
            layer?.restoreGState()
        }
        t.color("card").setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let x: CGFloat = 10
        var y: CGFloat = 6
        if rows.isEmpty {
            drawText("no open sessions", t.color("muted"), NSRect(x: x, y: y, width: 222, height: 20))
            y += 20
        }
        for r in rows {
            let c = color(r.situation)
            (r.situation == "working" ? c.withAlphaComponent(pulseOpacity()) : c).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y + 6, width: 8, height: 8)).fill()
            drawText(r.name, t.color("text"), NSRect(x: x + 16, y: y, width: config.subagents ? 170 - slotWidth : 170, height: 20))
            if hasChildren(r.id), let ctx = NSGraphicsContext.current?.cgContext {
                let isCollapsed = collapsed.contains(r.id)
                let arrow = (isCollapsed ? "\u{203A} \(children[r.id]?.count ?? 0)" : "\u{203A}") as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: t.color("accent")]
                let size = arrow.size(withAttributes: attributes)
                ctx.saveGState()
                ctx.translateBy(x: slotX + slotWidth / 2, y: y + 10)
                if !isCollapsed { ctx.rotate(by: CGFloat.pi / 2) }  // y grows downwards: points down
                arrow.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attributes)
                ctx.restoreGState()
            }
            drawText(r.elapsed, c, NSRect(x: x + 186, y: y, width: 36, height: 20), .right)
            y += 20
            for child in visibleChildren(r.id) {
                drawText("\u{2514}", t.color("faint"), NSRect(x: x + 8, y: y, width: 16, height: 17), size: 11)
                drawChild(child.text, NSRect(x: x + 30, y: y, width: childWidth, height: 17))
                drawText(child.elapsed, t.color("faint"), NSRect(x: x + 186, y: y, width: 36, height: 17), .right, size: 11)
                y += 17
            }
        }
        y += 5
        t.color("divider").setFill()
        NSRect(x: x, y: y, width: 222, height: 1).fill()
        y += 5
        guard let meters = usage else {
            drawText(config.usage || snapshotFile != nil ? "usage unavailable" : "usage off (right-click)",
                     t.color("faint"), NSRect(x: x, y: y, width: 222, height: 20))
            return
        }
        for m in meters {
            let c = m.percent >= 95 ? t.color("barCritical") : m.percent >= 80 ? t.color("barWarning") : t.color("bar")
            drawText(m.label, t.color("muted"), NSRect(x: x, y: y, width: 18, height: 20))
            let track = NSRect(x: x + 18, y: y + 8, width: 118, height: 4)
            t.color("track").setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            c.setFill()
            let filled = 118 * CGFloat(min(max(m.percent, 0), 100)) / 100
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: filled, height: 4), xRadius: 2, yRadius: 2).fill()
            drawText(String(format: "%.0f%%", m.percent), c, NSRect(x: x + 136, y: y, width: 38, height: 20), .right)
            let left = m.resets.map { elapsed($0.timeIntervalSinceNow / 60) } ?? ""
            drawText(left, t.color("faint"), NSRect(x: x + 174, y: y, width: 48, height: 20), .right)
            y += 20
        }
    }

    // the row under a point (card coordinates): "session:<id>", "collapse:<id>" or nothing
    func target(at p: NSPoint) -> String? {
        guard bounds.contains(p), p.y >= 6 else { return nil }
        for (i, r) in rows.enumerated() {
            let top = rowTop(i)
            if p.y >= top, p.y < top + 20 {
                if hasChildren(r.id), p.x >= slotX, p.x < slotX + slotWidth { return "collapse:" + r.id }
                return "session:" + r.id
            }
        }
        return nil
    }

    // Dragging by hand (performDrag hands it to the system, and then a click cannot be told
    // apart): moving less than 3 points is a click.
    var mouseStart = NSPoint.zero, windowStart = NSPoint.zero
    var pressed: String?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        mouseStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin ?? .zero
        pressed = target(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        var origin = NSPoint(x: windowStart.x + m.x - mouseStart.x, y: windowStart.y + m.y - mouseStart.y)
        // keep the card on screen vertically (screen points: the layout is scaled by the size option)
        if let visible = (window?.screen ?? NSScreen.main)?.visibleFrame {
            let s = scale()
            origin.y = min(max(origin.y, visible.minY - (windowHeight - frame.maxY) * s), visible.maxY - (windowHeight - frame.minY) * s)
        }
        window?.setFrameOrigin(origin)
    }
    override func mouseUp(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        if let p = pressed, p.hasPrefix("collapse:"), hypot(m.x - mouseStart.x, m.y - mouseStart.y) < 3 {
            let id = String(p.dropFirst(9))
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
            update()
        }
        pressed = nil
    }
    override func rightMouseDown(with event: NSEvent) {
        var removeId: String?
        if let t = target(at: convert(event.locationInWindow, from: nil)) {
            removeId = t.hasPrefix("session:") ? String(t.dropFirst(8)) : String(t.dropFirst(9))
        }
        NSMenu.popUpContextMenu(buildMenu(removeId: removeId), with: event, for: self)
    }
}

// The right-click menu, rebuilt on every right-click so it lists the mascots and themes of the
// files as they are now. Themes and sizes sit in submenus.
func buildMenu(removeId: String?) -> NSMenu {
    let menu = NSMenu()
    func item(_ title: String, _ action: Selector, _ on: Bool? = nil, _ value: String? = nil, in parent: NSMenu? = nil) {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = options
        if let on = on { i.state = on ? .on : .off }
        i.representedObject = value
        (parent ?? menu).addItem(i)
    }
    func submenu(_ title: String) -> NSMenu {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        holder.submenu = sub
        menu.addItem(holder)
        return sub
    }
    if let id = removeId {
        item("Remove session from the monitor", #selector(Options.removeSession(_:)), nil, id)
        menu.addItem(.separator())
    }
    item("Show mascot", #selector(Options.toggleMascot(_:)), config.mascot)
    let current = mascotKey()
    for m in mascots { item("Mascot: \(m.mascot.name)", #selector(Options.chooseMascot(_:)), m.key == current, m.key) }
    menu.addItem(.separator())
    let themeMenu = submenu("Theme")
    for t in themes { item(t.theme.name, #selector(Options.chooseTheme(_:)), t.key == themeKey(), t.key, in: themeMenu) }
    let sizeMenu = submenu("Size")
    for s in sizes { item(s.label, #selector(Options.chooseSize(_:)), s.key == sizeKey(), s.key, in: sizeMenu) }
    menu.addItem(.separator())
    item("Show usage", #selector(Options.toggleUsage(_:)), config.usage)
    item("Show subagents", #selector(Options.toggleSubagents(_:)), config.subagents)
    item("Window sound", #selector(Options.toggleSound(_:)), config.sound)
    menu.addItem(options.sliderItem("Opacity", 20, config.opacity * 100, #selector(Options.opacityChanged(_:))))
    menu.addItem(options.sliderItem("Volume", 0, config.volume * 100, #selector(Options.volumeChanged(_:))))
    menu.addItem(.separator())
    let close = NSMenuItem(title: "Close", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    close.target = NSApp
    menu.addItem(close)
    return menu
}

// The menu as one line, for the snapshot report: items by title ("*" when checked), "-" for a
// separator, "Theme > Dark*, Light" for a submenu, and the sliders by their label.
func menuOutline(_ menu: NSMenu) -> String {
    func label(_ i: NSMenuItem) -> String { i.title + (i.state == .on ? "*" : "") }
    return menu.items.map { i -> String in
        if i.isSeparatorItem { return "-" }
        if let sub = i.submenu { return i.title + " > " + sub.items.map(label).joined(separator: ", ") }
        return label(i)
    }.joined(separator: " | ")
}

// rectangles of the same color in one path: no seams between neighboring pixels
func shape(_ m: Mascot, _ picks: (Character) -> Bool) -> CGPath {
    let path = CGMutablePath()
    let dx = -CGFloat(m.sprite[0].count / 2)
    let dy = -CGFloat(m.sprite.count)
    for (line, text) in m.sprite.enumerated() {
        let cells = Array(text)
        var column = 0
        while column < cells.count {
            if !picks(cells[column]) { column += 1; continue }
            var end = column
            while end + 1 < cells.count && picks(cells[end + 1]) { end += 1 }
            path.addRect(CGRect(x: (CGFloat(column) + dx) * m.pw, y: (CGFloat(line) + dy) * m.ph,
                                width: CGFloat(end - column + 1) * m.pw, height: m.ph))
            column = end + 1
        }
    }
    return path
}
struct Figure {
    let m: Mascot
    let body: CGPath
    let face: CGPath
    let feetA: CGPath
    let feetB: CGPath
    init(_ m: Mascot) {
        self.m = m
        body = shape(m) { "#ou".contains($0) }
        face = shape(m) { "ou".contains($0) }
        feetA = shape(m) { $0 == "A" }
        feetB = shape(m) { $0 == "B" }
    }
}
var figures: [String: Figure] = [:]
func buildFigures() {
    figures = [:]
    for m in mascots { figures[m.key] = Figure(m.mascot) }
}
buildFigures()
func outline(_ ctx: CGContext, _ path: CGPath, _ color: NSColor, _ pw: CGFloat) {
    ctx.addPath(path)
    ctx.setFillColor(color.cgColor)
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(pw * 2)
    ctx.setLineJoin(.miter)
    ctx.drawPath(using: .fillStroke)
}

// The path is the card's rounded border, clockwise; the mascot turns with the corners.
// Outside "walking" it stays in the middle of the top edge.
final class Stage: NSView {
    weak var card: Card?
    var mode = ""
    var fraction: CGFloat = 0  // how far around the card it is (0-1); survives the card resizing
    var last = ProcessInfo.processInfo.systemUptime
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // "walking" (a session works): walks, hops and steps. "jumping" (a question or
    // permission): hops on top of the card. "standing" (nothing runs): all feet down.
    func setMode(_ new: String) {
        if new == mode { return }
        if new == "walking", let c = card?.frame { fraction = (c.width / 2 - 8) / perimeter(c) }
        mode = new
        needsDisplay = true
    }

    func perimeter(_ c: NSRect) -> CGFloat { 2 * (c.width + c.height) - (8 - 2 * .pi) * 8 }

    // point and direction at a distance d from the start of the top edge (y grows downwards)
    func onBorder(_ c: NSRect, _ distance: CGFloat) -> (CGPoint, CGFloat) {
        let r: CGFloat = 8
        let straight = c.width - 2 * r, side = c.height - 2 * r, corner = CGFloat.pi * r / 2
        let pieces: [CGFloat] = [straight, corner, side, corner, straight, corner, side, corner]
        var d = distance
        var i = 0
        while i < 7 && d > pieces[i] {
            d -= pieces[i]
            i += 1
        }
        switch i {
        case 0: return (CGPoint(x: c.minX + r + d, y: c.minY), 0)
        case 1: return arc(CGPoint(x: c.maxX - r, y: c.minY + r), -.pi / 2, d / r)
        case 2: return (CGPoint(x: c.maxX, y: c.minY + r + d), .pi / 2)
        case 3: return arc(CGPoint(x: c.maxX - r, y: c.maxY - r), 0, d / r)
        case 4: return (CGPoint(x: c.maxX - r - d, y: c.maxY), .pi)
        case 5: return arc(CGPoint(x: c.minX + r, y: c.maxY - r), .pi / 2, d / r)
        case 6: return (CGPoint(x: c.minX, y: c.maxY - r - d), -.pi / 2)
        default: return arc(CGPoint(x: c.minX + r, y: c.minY + r), .pi, d / r)
        }
    }
    func arc(_ center: CGPoint, _ start: CGFloat, _ travelled: CGFloat) -> (CGPoint, CGFloat) {
        let a = start + travelled
        return (CGPoint(x: center.x + 8 * cos(a), y: center.y + 8 * sin(a)), a + .pi / 2)
    }

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = CGFloat(min(now - last, 0.1))
        last = now
        guard mode != "standing", let c = card?.frame, c.width > 0 else { return }
        if mode == "walking" && snapshotFile == nil {
            fraction += 50 * dt / perimeter(c)  // about 50 px/s
            fraction -= fraction.rounded(.down)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = card?.frame, c.width > 0, let key = mascotKey(), let figure = figures[key],
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = ProcessInfo.processInfo.systemUptime
        var (point, angle) = (CGPoint(x: c.midX, y: c.minY), CGFloat(0))
        if mode == "walking" { (point, angle) = onBorder(c, fraction * perimeter(c)) }
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y)
        ctx.rotate(by: angle)
        if mode != "standing" && snapshotFile == nil {
            // hops: up fast, slowing at the top; the way down speeds up
            let u = t.truncatingRemainder(dividingBy: 0.32) / 0.16
            let p = CGFloat(u <= 1 ? u : 2 - u)
            ctx.translateBy(x: 0, y: -5 * (1 - (1 - p) * (1 - p)))
        }
        ctx.setShouldAntialias(false)  // no seams between the pixels
        // walking alternates the feet every half hop; otherwise all feet are down
        let step = Int(t / 0.16) % 2 == 0
        let walking = mode == "walking" && snapshotFile == nil
        if let color = figure.m.outline.map(hex) {
            outline(ctx, figure.body, color, figure.m.pw)
            if !walking || step { outline(ctx, figure.feetA, color, figure.m.pw) }
            if !walking || !step { outline(ctx, figure.feetB, color, figure.m.pw) }
        }
        for (path, color) in [(figure.body, figure.m.body), (figure.face, figure.m.face)] {
            ctx.addPath(path)
            ctx.setFillColor(hex(color).cgColor)
            ctx.fillPath()
        }
        ctx.setFillColor(hex(figure.m.feet).cgColor)
        if !walking || step { ctx.addPath(figure.feetA) }
        if !walking || !step { ctx.addPath(figure.feetB) }
        ctx.fillPath()
        ctx.restoreGState()
    }
}

// The window is tall and the card sits at its bottom. Without this override, macOS keeps the
// top of the window below the menu bar, and the card cannot go above the middle of the screen.
final class FloatingPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// --- Window
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon
let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = false
panel.level = .floating
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
panel.hidesOnDeactivate = false
panel.isReleasedWhenClosed = false
panel.allowsToolTipsWhenApplicationIsInactive = true
let root = Root(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
let card = Card(frame: .zero)
let stage = Stage(frame: root.bounds)
stage.card = card
root.addSubview(card)
root.addSubview(stage)
panel.contentView = root

// What the right-click menu changed. The opacity dims the card (Card.draw) and the mascot alike.
func applyConfig() {
    stage.isHidden = !config.mascot || mascotKey() == nil
    stage.alphaValue = CGFloat(config.opacity)
    stage.needsDisplay = true
    card.needsDisplay = true
}
// The size option scales the 320x440 layout: the view keeps its bounds and the window grows or
// shrinks around its bottom-right corner (in screen coordinates y grows upwards, so the bottom
// stays put on its own).
func applySize() {
    let s = scale()
    let size = NSSize(width: windowWidth * s, height: windowHeight * s)
    let right = panel.frame.maxX
    panel.setContentSize(size)
    root.setFrameSize(size)
    root.setBoundsSize(NSSize(width: windowWidth, height: windowHeight))
    panel.setFrameOrigin(NSPoint(x: right - size.width, y: panel.frame.minY))
    root.needsDisplay = true
}
applyConfig()
// born in the bottom-right corner (the margin keeps the card off the edge)
if let screen = NSScreen.main?.visibleFrame { panel.setFrameOrigin(NSPoint(x: screen.maxX - windowWidth, y: screen.minY)) }
applySize()

// Edited mascot or theme files apply within 2 s, without reopening the window.
func reloadAssetsIfChanged() {
    guard currentAssetStamps() != assetStamps else { return }
    loadAssets()
    buildFigures()
    applyConfig()
}

// The binary was replaced by a newer build: exit, so the window that was just opened takes
// over. The window never relaunches itself.
func exitIfUpdated() {
    guard snapshotFile == nil, let v = version, let now = modificationDate(binary), now != v else { return }
    exit(0)
}

var lastSessions: [Session] = []
func update() {
    reloadAssetsIfChanged()
    let now = Date().timeIntervalSince1970
    let sessions = readSessions(now: now)
    lastSessions = sessions
    notice(sessions)
    card.rows = sessions.map {
        Row(id: $0.id, situation: $0.situation, name: $0.name, elapsed: elapsed((now - $0.since) / 60),
            tooltip: tooltips[$0.situation] ?? $0.situation)
    }
    refreshUsage()
    var children: [String: [ChildRow]] = [:]
    if config.subagents {
        for s in sessions {
            children[s.id] = s.subagents.map { ChildRow(type: $0.type, text: $0.desc.isEmpty ? $0.type : $0.desc,
                                                       elapsed: elapsed((now - $0.since) / 60)) }
        }
    }
    card.children = children
    card.arrange()  // every 2 s, so the time to reset keeps counting between reads
    // waiting for you beats working, which beats idle. After arrange: on the first run the card
    // has no width yet and the mascot would land below it
    let situations = Set(sessions.map { $0.situation })
    stage.setMode(situations.contains("question") || situations.contains("permission") ? "jumping"
                  : situations.contains("working") ? "walking" : "standing")
    stage.needsDisplay = true
    exitIfUpdated()
}

func repeatEvery(_ interval: TimeInterval, _ block: @escaping () -> Void) {
    let timer = Timer(timeInterval: interval, repeats: true) { _ in block() }
    RunLoop.main.add(timer, forMode: .common)  // keeps running while dragging and in the menu
}

update()
panel.orderFrontRegardless()
repeatEvery(2) { update() }
repeatEvery(1.0 / 30) {
    stage.tick()
    // the working dot's pulse: only the dot column
    if card.rows.contains(where: { $0.situation == "working" }) {
        card.setNeedsDisplay(NSRect(x: 8, y: 0, width: 12, height: card.bounds.height))
    }
}

if let snapshot = snapshotFile {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        update()
        // pixels at the scaled size, whatever the screen's backing scale
        let s = scale()
        if let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(windowWidth * s), pixelsHigh: Int(windowHeight * s),
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            image.size = NSSize(width: windowWidth, height: windowHeight)
            root.cacheDisplay(in: root.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapshot))
        }
        var report = lastSessions.map { "session: \($0.name) | hook=\($0.state) | window=\($0.situation) | subagents=\($0.subagents.count)" }
        let shown = config.mascot ? mascotKey() : nil
        report.append("mascot: " + (shown.map { "\($0) \(stage.mode)" } ?? "off"))
        report.append("look: \(themeKey()) \(sizeKey())")
        report.append("usage: " + (usage.map { $0.map { "\($0.label)=\(String(format: "%.0f", $0.percent))" }.joined(separator: " ") } ?? "unavailable"))
        report.append("sound: " + (soundChosen ?? "none"))
        report.append("menu: " + menuOutline(buildMenu(removeId: nil)))
        try? (report.joined(separator: "\n") + "\n").write(toFile: snapshot + ".txt", atomically: true, encoding: .utf8)
        exit(0)
    }
}
app.run()
