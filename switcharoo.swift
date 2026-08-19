import AppKit
import Carbon.HIToolbox
import ApplicationServices
import ServiceManagement

// MARK: - Private AX bridge ----------------------------------------------------
// _AXUIElementGetWindow: undocumented but stable since 10.5. Used to match a
// CGWindowID (what CGWindowListCopyWindowInfo gives us) to an AXUIElement
// (what we need to raise via Accessibility). Without this we can only activate
// apps, not specific windows.
private typealias AXGetWindowFn =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

private let axGetWindow: AXGetWindowFn? = {
    // Try RTLD_DEFAULT (already-loaded libraries) first.
    let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
    if let p = dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow") {
        return unsafeBitCast(p, to: AXGetWindowFn.self)
    }
    // Fallback: explicitly dlopen HIServices where the symbol lives.
    let path = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
    if let handle = dlopen(path, RTLD_LAZY),
       let p = dlsym(handle, "_AXUIElementGetWindow") {
        return unsafeBitCast(p, to: AXGetWindowFn.self)
    }
    return nil
}()

/// Per-app AX element with a short messaging timeout. The default AX timeout
/// is ~6 seconds per request; one hung or busy app would otherwise stall
/// every listWindows() / title poll for seconds at a time.
func axApp(_ pid: pid_t) -> AXUIElement {
    let elem = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(elem, 0.25)
    return elem
}

// MARK: - Debug log -----------------------------------------------------------
// Writes to /tmp/switcharoo.log so we can diagnose issues without running from a
// terminal. Inspect with: tail -f /tmp/switcharoo.log
func switcharooLog(_ s: String) {
    let line = "[\(Date())] \(s)\n"
    let path = "/tmp/switcharoo.log"
    if !FileManager.default.fileExists(atPath: path) {
        try? "".write(toFile: path, atomically: false, encoding: .utf8)
    }
    if let f = FileHandle(forWritingAtPath: path) {
        f.seekToEndOfFile()
        if let data = line.data(using: .utf8) { f.write(data) }
        try? f.close()
    }
}

// MARK: - AX window cache ------------------------------------------------------
// An AX request into an app that is busy, throttled by App Nap, or sitting on
// another Space can blow past our 0.25s messaging timeout. When that happens
// loadAXTitles() gets nothing, the pid never lands in axFunctionalPids, and the
// AX-confirmation filter below is skipped — so the app's raw CoreGraphics
// windows survive instead. For most apps those include untitled helper/overlay
// windows, so the row loses its title AND ends up carrying a windowID that AX
// doesn't recognise, which means raise() can't target it either. Reusing the
// last good answer keeps both the title and the raisable windowID stable across
// a transient timeout. Entries are always intersected with the live CG list
// before use, so a cached window that has since closed can never resurrect.
private struct AXWindowSnapshot {
    var confirmed: Set<CGWindowID>
    var titles: [CGWindowID: String]
    var stamp: CFTimeInterval
}
private var axSnapshotByPid: [pid_t: AXWindowSnapshot] = [:]
/// Generous: a slightly stale title is far better than a blank row, and the
/// live-refresh timer corrects titles within 0.4s of the panel opening.
private let axSnapshotTTL: CFTimeInterval = 600

// MARK: - Cross-Space activation MRU -------------------------------------------
// CGWindowList's z-order is only usable for the *current* Space:
// .optionOnScreenOnly is scoped to the active Space, not to "not covered up".
// On a normal Space that's fine — everything the user can switch to is right
// there, correctly z-ordered. Inside a fullscreen Space it collapses: exactly
// one window (the fullscreen app's own) carries usable MRU and every other
// window in the system falls into the unordered bucket, so the switcher loses
// its ordering precisely when you're in a fullscreen app. CoreGraphics has no
// cross-Space MRU to recover, so we track app activation ourselves and use it
// to rank anything that isn't on the current Space.
final class ActivationMRU {
    static let shared = ActivationMRU()
    /// Most-recently-activated first.
    private var pids: [pid_t] = []
    private let selfPid = ProcessInfo.processInfo.processIdentifier

    func start() {
        // Seed so ordering is sane before the user has switched at all. Only
        // the current frontmost app is known for certain; the rest self-corrects
        // as soon as the user starts switching.
        if let front = NSWorkspace.shared.frontmostApplication {
            touch(front.processIdentifier)
        }
        for a in NSWorkspace.shared.runningApplications
        where a.activationPolicy == .regular {
            let pid = a.processIdentifier
            if pid != selfPid, !pids.contains(pid) { pids.append(pid) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            self?.touch(app.processIdentifier)
        }
    }

    /// Move a pid to the front of the MRU. Our own pid is never recorded —
    /// showing the panel activates switcharoo, and that must not displace the
    /// app the user was actually in.
    func touch(_ pid: pid_t) {
        guard pid != selfPid else { return }
        pids.removeAll { $0 == pid }
        pids.insert(pid, at: 0)
    }

    /// Lower is more recent. Unknown pids sort last.
    func rank(_ pid: pid_t) -> Int { pids.firstIndex(of: pid) ?? Int.max }
}

// MARK: - Window enumeration ---------------------------------------------------
struct WindowRecord {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let icon: NSImage?
}

private func isSystemHelperPath(_ path: String) -> Bool {
    // XPC services, app extensions, and PrivateFrameworks-hosted helpers
    // (e.g. WebThumbnailExtension) sometimes leak through the activation-policy
    // filter. These aren't user-switchable apps.
    return path.contains("/PrivateFrameworks/")
        || path.hasSuffix(".appex")
        || path.hasSuffix(".xpc")
        || path.contains(".xpc/")
        || path.contains(".appex/")
}

func listWindows() -> [WindowRecord] {
    switcharooLog("listWindows: AX trusted=\(AXIsProcessTrusted()), axGetWindow=\(axGetWindow != nil)")
    // CGWindowList only returns true front-to-back z-order when
    // .optionOnScreenOnly is set. Without it, you get creation order — same
    // sequence every time, which kills per-window MRU. We do two queries:
    //   1. on-screen windows, z-ordered (MRU, but ONLY for the current Space —
    //      .optionOnScreenOnly is Space-scoped, so in a fullscreen Space this
    //      is just the fullscreen app itself)
    //   2. all windows, to recover everything not in #1: minimized/hidden
    //      windows, and — when the user is in a fullscreen Space — literally
    //      every other app. CG hands these back in creation order, which is
    //      useless for switching, so we re-rank them by our own activation MRU.
    let onScreenInfos = (CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]]) ?? []
    let onScreenIDs = Set(onScreenInfos.compactMap {
        $0[kCGWindowNumber as String] as? CGWindowID
    })
    let allInfos = (CGWindowListCopyWindowInfo(
        [.excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]]) ?? []
    // Decorated with the original index so equal ranks keep CG's order —
    // Swift's sort is not stable on its own.
    let offScreenInfos = allInfos
        .filter {
            guard let id = $0[kCGWindowNumber as String] as? CGWindowID
            else { return false }
            return !onScreenIDs.contains(id)
        }
        .enumerated()
        .sorted { a, b in
            let ra = ActivationMRU.shared.rank(
                a.element[kCGWindowOwnerPID as String] as? pid_t ?? 0)
            let rb = ActivationMRU.shared.rank(
                b.element[kCGWindowOwnerPID as String] as? pid_t ?? 0)
            if ra != rb { return ra < rb }
            return a.offset < b.offset
        }
        .map(\.element)
    let infos = onScreenInfos + offScreenInfos

    // CG window titles require Screen Recording permission and otherwise come
    // back empty. We pull titles via AX (which we already have permission for)
    // and index them by CGWindowID using _AXUIElementGetWindow.
    var titlesByWindowID: [CGWindowID: String] = [:]
    var axConfirmedWindowIDs = Set<CGWindowID>()   // AX agrees these are real
    var axFunctionalPids = Set<pid_t>()             // axGet works for this pid
    var fetchedPids = Set<pid_t>()
    // Which CGWindowIDs each pid currently owns — used to validate cache hits.
    var cgWidsByPid: [pid_t: Set<CGWindowID>] = [:]
    for d in infos {
        guard let pid = d[kCGWindowOwnerPID as String] as? pid_t,
              let wid = d[kCGWindowNumber as String] as? CGWindowID else { continue }
        cgWidsByPid[pid, default: []].insert(wid)
    }

    /// Fall back to the last good AX answer for this pid, if we have one that
    /// is still fresh and still refers to windows CoreGraphics reports today.
    func useCachedAX(for pid: pid_t, because reason: String) {
        guard let snap = axSnapshotByPid[pid],
              CACurrentMediaTime() - snap.stamp < axSnapshotTTL
        else {
            switcharooLog("listWindows: AX \(reason) pid=\(pid) — no usable cache; row falls back to raw CG windows (untitled, unraisable)")
            return
        }
        let live = snap.confirmed.intersection(cgWidsByPid[pid] ?? [])
        guard !live.isEmpty else {
            switcharooLog("listWindows: AX \(reason) pid=\(pid) — cached windows all gone; row falls back to raw CG windows")
            return
        }
        axFunctionalPids.insert(pid)
        axConfirmedWindowIDs.formUnion(live)
        for wid in live where titlesByWindowID[wid] == nil {
            if let t = snap.titles[wid] { titlesByWindowID[wid] = t }
        }
        switcharooLog("listWindows: AX \(reason) pid=\(pid) — reused \(live.count) cached window(s), age=\(Int(CACurrentMediaTime() - snap.stamp))s")
    }

    func loadAXTitles(for pid: pid_t) {
        if fetchedPids.contains(pid) { return }
        fetchedPids.insert(pid)
        guard let axGet = axGetWindow else { return }
        let appElem = axApp(pid)
        var raw: AnyObject?
        let err = AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &raw)
        guard err == .success, let axWindows = raw as? [AXUIElement], !axWindows.isEmpty
        else {
            // err -25204 (cannotComplete) is the messaging timeout.
            useCachedAX(for: pid, because: "miss(err=\(err.rawValue))")
            return
        }
        var confirmed = Set<CGWindowID>()
        var titles: [CGWindowID: String] = [:]
        for axWin in axWindows {
            var wid: CGWindowID = 0
            guard axGet(axWin, &wid) == .success else { continue }
            confirmed.insert(wid)
            var titleRaw: AnyObject?
            if AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRaw) == .success,
               let s = titleRaw as? String {
                titles[wid] = s
            }
        }
        // AX answered but no window resolved to a CGWindowID — same blind spot.
        guard !confirmed.isEmpty else {
            useCachedAX(for: pid, because: "no-resolvable-windows")
            return
        }
        axFunctionalPids.insert(pid)
        axConfirmedWindowIDs.formUnion(confirmed)
        titlesByWindowID.merge(titles) { _, new in new }
        // Only remember titles we actually got; a window whose title fetch timed
        // out must not overwrite a good cached title with an empty string.
        var merged = axSnapshotByPid[pid]?.titles ?? [:]
        for (wid, t) in titles where !t.isEmpty { merged[wid] = t }
        for wid in confirmed where merged[wid] == nil { merged[wid] = titles[wid] ?? "" }
        axSnapshotByPid[pid] = AXWindowSnapshot(
            confirmed: confirmed,
            titles: merged.filter { confirmed.contains($0.key) },
            stamp: CACurrentMediaTime())
    }

    // CGWindowList returns windows in front-to-back z-order, which is itself
    // per-window MRU (raising a window puts it at the front). We rely on that
    // ordering directly — no further sort needed.
    var out: [WindowRecord] = []
    var seenIDs = Set<CGWindowID>()
    for d in infos {
        let layer = d[kCGWindowLayer as String] as? Int ?? -1
        let pid = d[kCGWindowOwnerPID as String] as? pid_t ?? 0
        let app = d[kCGWindowOwnerName as String] as? String ?? "?"
        let wid = d[kCGWindowNumber as String] as? CGWindowID ?? 0
        let cgTitle = (d[kCGWindowName as String] as? String) ?? ""

        guard layer == 0, pid != 0, wid != 0 else { continue }
        if seenIDs.contains(wid) { continue }
        seenIDs.insert(wid)
        guard let ra = NSRunningApplication(processIdentifier: pid),
              ra.activationPolicy == .regular
        else { continue }
        if let path = ra.bundleURL?.path, isSystemHelperPath(path) { continue }
        loadAXTitles(for: pid)

        // Transient CG window? If AX works for this pid but didn't confirm
        // this windowID, it's a helper/HUD/overlay and we drop it. If AX is
        // *broken* for the pid (Finder sometimes), we keep CG windows as a
        // fallback so the app is still switchable.
        if axFunctionalPids.contains(pid),
           !axConfirmedWindowIDs.contains(wid) { continue }

        let title = !cgTitle.isEmpty ? cgTitle : (titlesByWindowID[wid] ?? "")
        out.append(WindowRecord(
            windowID: wid, pid: pid,
            appName: app, title: title,
            icon: ra.icon))
    }

    // Final dedup: if an app has any titled window, drop its empty-titled
    // entries (those are noise). If all of an app's windows are untitled,
    // keep just one so the app stays switchable.
    let pidsWithTitled: Set<pid_t> = Set(out.lazy.filter { !$0.title.isEmpty }.map(\.pid))
    var keptEmpty = Set<pid_t>()
    return out.filter { r in
        if !r.title.isEmpty { return true }
        if pidsWithTitled.contains(r.pid) { return false }
        if keptEmpty.contains(r.pid) { return false }
        keptEmpty.insert(r.pid)
        return true
    }
}

// MARK: - Raise a specific window ----------------------------------------------
func raise(_ w: WindowRecord) {
    let t0 = CACurrentMediaTime()
    let app = axApp(w.pid)
    var raw: AnyObject?
    var axMatched = false
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
       let axWindows = raw as? [AXUIElement],
       let axGet = axGetWindow
    {
        for axWin in axWindows {
            var wid: CGWindowID = 0
            if axGet(axWin, &wid) == .success, wid == w.windowID {
                AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
                _ = AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, kCFBooleanTrue)
                axMatched = true
                break
            }
        }
    }
    let axMs = (CACurrentMediaTime() - t0) * 1000
    // Activation is a *request* under macOS 14+ cooperative activation, and it
    // is refused unless we are still the active app. Caught in the wild:
    //   raise: Emacs wid=1540 axMatched=Y activate()=N  → targetIsFrontmost=N
    // The AX raise had already matched the right window; only the app-level
    // activation was denied, so the switch silently did nothing and the user
    // had to invoke switcharoo a second time. commit() now raises before
    // dismissing the panel so we still hold activation here, and if the
    // cooperative form is still refused we fall back to the deprecated
    // ignoringOtherApps form, which is not subject to that arbitration.
    let target = NSRunningApplication(processIdentifier: w.pid)
    var activated = target?.activate(options: [.activateAllWindows]) ?? false
    var forced = false
    if !activated {
        forced = true
        activated = target?.activate(
            options: [.activateAllWindows, .activateIgnoringOtherApps]) ?? false
    }
    switcharooLog(String(
        format: "raise: %@ wid=%u pid=%d axMatched=%@ activate()=%@%@ ax=%.0fms",
        w.appName, w.windowID, w.pid,
        axMatched ? "Y" : "**N**",
        activated ? "Y" : "**N**",
        forced ? (activated ? " (via forced fallback)" : " (fallback also refused)") : "",
        axMs))
}

// MARK: - Filtering ------------------------------------------------------------
func filterWindows(_ rows: [WindowRecord], query: String) -> [WindowRecord] {
    if query.isEmpty { return rows }
    let q = query.lowercased()
    return rows.filter { ($0.appName + " " + $0.title).lowercased().contains(q) }
}

// MARK: - Theme ----------------------------------------------------------------
// Pure white in light mode, pure black in dark mode. Text inverts.
enum Theme {
    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    static var bg: NSColor    { isDark ? .black : .white }
    static var fg: NSColor    { isDark ? .white : .black }
    static var dim: NSColor   { isDark ? NSColor(white: 1.0, alpha: 0.55)
                                        : NSColor(white: 0.0, alpha: 0.55) }
    static var muted: NSColor { isDark ? NSColor(white: 1.0, alpha: 0.35)
                                        : NSColor(white: 0.0, alpha: 0.35) }
    static var sel: NSColor   { isDark ? NSColor(white: 1.0, alpha: 0.12)
                                        : NSColor(white: 0.0, alpha: 0.08) }
}

// MARK: - Search field ---------------------------------------------------------
// NSTextField subclass that tints the native caret to the theme foreground.
final class SearchField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = Theme.fg
            editor.selectedTextAttributes = [
                .backgroundColor: Theme.fg.withAlphaComponent(0.18)
            ]
        }
        return ok
    }
}

// MARK: - Switcher UI ----------------------------------------------------------
final class SwitcherView: NSView {
    // Layout constants — change here to scale the whole UI. A future version
    // will read these from a config file.
    let panelWidth: CGFloat = 720
    let rowHeight: CGFloat = 36
    let pad: CGFloat = 14
    private let baseSearchHeight: CGFloat = 60
    /// Effective search-bar height. In quick mode the search bar is hidden
    /// entirely so the panel collapses up against the rows.
    var searchHeight: CGFloat { quickMode ? 0 : baseSearchHeight }
    let appColumnWidth: CGFloat = 130
    let iconSize: CGFloat = 22
    let textFontSize: CGFloat = 14
    let searchFontSize: CGFloat = 20

    var rows: [WindowRecord] = []
    var selected: Int = 0
    var query: String = ""
    var axTrusted: Bool = true
    /// Per-windowID flash deadlines (mach time). While in window, a highlight
    /// fades over the row to signal "this row just updated".
    var rowFlashUntil: [CGWindowID: TimeInterval] = [:]
    let flashDuration: TimeInterval = 0.35
    var quickMode: Bool = false {
        didSet {
            searchField.isHidden = quickMode
            needsLayout = true
            needsDisplay = true
        }
    }

    var queryIsEmpty: Bool { query.isEmpty }

    let searchField = SearchField()

    override init(frame: NSRect) {
        super.init(frame: frame)
        configureSearchField()
        // .inVisibleRect auto-resizes the tracking area with the view, so
        // we don't have to update it on each panel resize.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var isFlipped: Bool { true }

    /// Returns the row index under a local point, or nil if the point is over
    /// the search bar / outside the list.
    func rowIndex(at point: NSPoint) -> Int? {
        guard !rows.isEmpty, point.y >= searchHeight + pad else { return nil }
        let listY = point.y - (searchHeight + pad)
        let i = Int(listY / rowHeight)
        return (i >= 0 && i < rows.count) ? i : nil
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = rowIndex(at: p), i != selected else { return }
        (NSApp.delegate as? App)?.setSelected(i)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = rowIndex(at: p) else { return }
        (NSApp.delegate as? App)?.commit(atRow: i)
    }

    private func configureSearchField() {
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.usesSingleLineMode = true
        searchField.cell?.wraps = false
        searchField.cell?.isScrollable = true
        searchField.font = .systemFont(ofSize: searchFontSize, weight: .regular)
        searchField.textColor = Theme.fg
        // Typed text is always left-aligned; placeholder is centered via the
        // paragraphStyle baked into its attributes (NSTextField's placeholder
        // ignores the field's `alignment` property when a placeholderAttributed
        // String is set).
        searchField.alignment = .left
        refreshThemeColors()
        addSubview(searchField)
        layoutSearchField()
    }

    /// Re-resolve theme-dependent colors on the search field. These are baked
    /// into attributed strings / properties rather than being dynamic NSColors,
    /// so a system appearance switch after launch would otherwise leave e.g.
    /// a light-gray placeholder invisible on the dark panel. Called on every
    /// show().
    func refreshThemeColors() {
        searchField.textColor = Theme.fg
        let centerPara = NSMutableParagraphStyle()
        centerPara.alignment = .center
        searchField.placeholderAttributedString = NSAttributedString(
            string: "switcharoo",
            attributes: [
                .foregroundColor: Theme.muted,
                .font: NSFont.systemFont(ofSize: searchFontSize, weight: .regular),
                .paragraphStyle: centerPara,
            ])
    }

    private func layoutSearchField() {
        let h: CGFloat = 30
        searchField.frame = NSRect(
            x: pad + 4,
            y: (searchHeight - h) / 2,
            width: bounds.width - 2 * (pad + 4),
            height: h)
    }

    override func layout() {
        super.layout()
        layoutSearchField()
    }

    /// Empty-state message to render when there are no rows.
    /// Returns nil when the user is actively searching (we stay silent on
    /// no-match), which collapses the panel to just the search bar.
    var emptyMessage: String? {
        guard rows.isEmpty else { return nil }
        if !queryIsEmpty { return nil }
        if !axTrusted {
            return "Grant Accessibility in System Settings → Privacy & Security → Accessibility"
        }
        return "No windows"
    }

    /// Build an attributed string for `haystack`, with substrings matching
    /// `query` (case-insensitive) styled with `match` instead of `base`.
    private func highlighted(_ haystack: String,
                             base: [NSAttributedString.Key: Any],
                             match: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: haystack, attributes: base)
        guard !query.isEmpty else { return attr }
        let nsH = haystack as NSString
        var searchRange = NSRange(location: 0, length: nsH.length)
        while searchRange.length > 0 {
            let found = nsH.range(of: query, options: .caseInsensitive, range: searchRange)
            if found.location == NSNotFound { break }
            attr.addAttributes(match, range: found)
            let nextStart = found.location + found.length
            searchRange = NSRange(location: nextStart, length: nsH.length - nextStart)
        }
        return attr
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bg.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        path.fill()

        // If the panel collapsed to just the search bar, don't draw a divider
        // or any list area.
        let hasContent = !rows.isEmpty || emptyMessage != nil
        guard hasContent else { return }

        // Divider between search bar and rows. In quick mode the search bar
        // is hidden (searchHeight == 0) so there's nothing to divide.
        if searchHeight > 0 {
            Theme.muted.withAlphaComponent(0.18).setFill()
            NSRect(x: 0, y: searchHeight, width: bounds.width, height: 1).fill()
        }

        if rows.isEmpty, let msg = emptyMessage {
            let emptyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: textFontSize),
                .foregroundColor: Theme.dim,
            ]
            (msg as NSString).draw(at: NSPoint(x: pad + 4, y: searchHeight + 14),
                                   withAttributes: emptyAttrs)
            return
        }

        // Layout: [right-aligned app name | icon | left-aligned title]
        let appColRight = pad + 12 + appColumnWidth
        let iconX = appColRight + 14
        let titleX = iconX + iconSize + 12
        let textY: CGFloat = (rowHeight - 18) / 2

        // All regular weight; title now uses the same fg color as the app
        // name (was dim). Match emphasis = underline only.
        let nameParaStyle = NSMutableParagraphStyle()
        nameParaStyle.alignment = .right
        nameParaStyle.lineBreakMode = .byTruncatingTail

        let titleParaStyle = NSMutableParagraphStyle()
        titleParaStyle.alignment = .left
        titleParaStyle.lineBreakMode = .byTruncatingTail

        let nameBase: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: textFontSize),
            .foregroundColor: Theme.fg,
            .paragraphStyle: nameParaStyle,
        ]
        let nameMatch: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: Theme.fg.withAlphaComponent(0.5),
        ]
        let titleBase: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: textFontSize),
            .foregroundColor: Theme.fg,
            .paragraphStyle: titleParaStyle,
        ]
        let titleMatch: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: Theme.fg.withAlphaComponent(0.5),
        ]

        // Right padding inside each row (mirrors the pad + 12 on the left of
        // the app column, so left/right gutters look equal).
        let rightInset: CGFloat = 12

        let now = CACurrentMediaTime()
        for (i, r) in rows.enumerated() {
            let y = searchHeight + pad + CGFloat(i) * rowHeight
            let row = NSRect(x: pad, y: y, width: bounds.width - 2*pad, height: rowHeight)
            if i == selected {
                Theme.sel.setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 0, dy: 2),
                             xRadius: 8, yRadius: 8).fill()
            }
            // Zlip flash on live title change. Alpha eases from ~0.18 → 0.
            if let until = rowFlashUntil[r.windowID], until > now {
                let remaining = until - now
                let alpha = 0.18 * (remaining / flashDuration)
                Theme.fg.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 0, dy: 2),
                             xRadius: 8, yRadius: 8).fill()
            }
            // App name — right-aligned in its column, ellipsis-truncated if
            // longer than the column.
            let nameAttr = highlighted(r.appName, base: nameBase, match: nameMatch)
            let nameRect = NSRect(
                x: pad + 12, y: y + textY,
                width: appColumnWidth, height: rowHeight)
            nameAttr.draw(in: nameRect)

            // Icon
            if let icon = r.icon {
                let iconRect = NSRect(
                    x: iconX,
                    y: y + (rowHeight - iconSize) / 2,
                    width: iconSize, height: iconSize)
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver,
                          fraction: 1.0, respectFlipped: true, hints: nil)
            }

            // Title — ellipsis-truncated to stay inside the right gutter.
            let titleAttr = highlighted(r.title, base: titleBase, match: titleMatch)
            let titleRect = NSRect(
                x: titleX, y: y + textY,
                width: row.maxX - rightInset - titleX, height: rowHeight)
            titleAttr.draw(in: titleRect)
        }
    }
}

final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// When the panel is key, intercept the management shortcuts directly
    /// (Cmd+M / Cmd+H / Cmd+Q / Cmd+Opt+Q) and dispatch to App. Both NSWindow
    /// defaults (miniaturize) and NSApplication defaults (Hide Application)
    /// can otherwise swallow these before our main-menu items see them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let app = NSApp.delegate as? App else {
            return super.performKeyEquivalent(with: event)
        }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == [.command, .option], chars == "q" {
            app.forceQuitHighlighted(nil); return true
        }
        if mods == .command {
            switch chars {
            case "m": app.minimizeHighlighted(nil); return true
            case "h": app.hideHighlighted(nil); return true
            case "q": app.handleQuit(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// In quick mode there's no NSTextField first responder, so arrow keys,
    /// Tab, Esc, and Enter come straight to the panel's keyDown.
    override func keyDown(with event: NSEvent) {
        if let app = NSApp.delegate as? App, app.quickMode {
            switch Int(event.keyCode) {
            case kVK_DownArrow:
                app.cycle(reverse: false); return
            case kVK_UpArrow:
                app.cycle(reverse: true); return
            case kVK_Tab:
                app.cycle(reverse: event.modifierFlags.contains(.shift)); return
            case kVK_Escape:
                app.cancel(); return
            case kVK_Return, kVK_ANSI_KeypadEnter:
                app.commit(); return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}

// MARK: - Config ---------------------------------------------------------------
// Live-readable knobs backed by UserDefaults. The Preferences window writes
// to the same keys.
enum SwitcharooConfig {
    /// Skip the dismissal fade-out — panel disappears instantly.
    static var fastMode: Bool { UserDefaults.standard.bool(forKey: "fastMode") }
    /// Duration of the dismissal fade when fastMode is off.
    static let dismissDuration: TimeInterval = 0.10
}

// MARK: - Preferences window ---------------------------------------------------
final class PreferencesController: NSObject {
    static let shared = PreferencesController()

    private let window: NSWindow

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        super.init()
        window.title = "switcharoo preferences"
        window.isReleasedWhenClosed = false
        window.contentView = makeContent()
        window.center()
    }

    private func makeContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        let fast = NSButton(
            checkboxWithTitle: "Fast mode (skip dismissal animation)",
            target: self, action: #selector(toggleFast(_:)))
        fast.state = UserDefaults.standard.bool(forKey: "fastMode") ? .on : .off
        stack.addArrangedSubview(fast)

        for line in [
            "",
            "Hotkey:  Cmd+Tab quick mode · Opt+Tab search mode · +Shift reverses",
            "Filter:   type to filter · matching characters underlined",
            "Move:    Up/Down · Ctrl+K/Ctrl+J · Tab/Shift+Tab to cycle",
            "Commit: Enter to switch · Esc to cancel",
            "Actions: Cmd+M minimize highlighted · Cmd+H hide highlighted app",
        ] {
            stack.addArrangedSubview(NSTextField(labelWithString: line))
        }
        return stack
    }

    @objc private func toggleFast(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "fastMode")
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

// MARK: - Hotkey plumbing ------------------------------------------------------
extension Notification.Name {
    static let switcharooHotkey = Notification.Name("switcharooHotkey")
}

/// Global Cmd+Tab interceptor. Carbon's RegisterEventHotKey can't claim
/// Cmd+Tab — the system app switcher consumes it first. CGEventTap at the
/// session level sees the keyDown *before* the system does and can swallow
/// it. Requires Accessibility permission (which we already require).
private var switcharooEventTap: CFMachPort?

func installCmdTabTap() {
    guard switcharooEventTap == nil else { return }   // already installed
    guard AXIsProcessTrusted() else {
        // The AX grant usually lands *after* first launch (the user is in
        // System Settings while we're already running). Poll until it
        // appears so Cmd+Tab starts working without a relaunch.
        switcharooLog("CGEventTap: AX not trusted yet; retrying in 3s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            installCmdTabTap()
        }
        return
    }
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, _ in
        // macOS can disable the tap if our callback is too slow; just re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = switcharooEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        guard kc == Int64(kVK_Tab),
              event.flags.contains(.maskCommand) else {
            return Unmanaged.passUnretained(event)
        }
        let shift = event.flags.contains(.maskShift)
        let id: UInt32 = shift ? HK_QUICK_REVERSE : HK_QUICK_FORWARD
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .switcharooHotkey, object: nil, userInfo: ["id": id])
        }
        return nil   // swallow — system app switcher never sees this
    }
    // The tap runs on its own thread with its own runloop. A session-level
    // tap sees EVERY keyDown in the login session; if its runloop lived on
    // the main thread, any main-thread stall (e.g. a slow AX call into a
    // busy app) would stall keyboard delivery system-wide until macOS
    // disables the tap — which the callback above then re-enables, freezing
    // input in waves. A dedicated thread keeps event delivery independent
    // of whatever the app is doing.
    let thread = Thread {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: nil)
        else {
            switcharooLog("CGEvent.tapCreate failed")
            return
        }
        switcharooEventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        switcharooLog("CGEventTap installed — Cmd+Tab now opens switcharoo")
        CFRunLoopRun()
    }
    thread.name = "switcharoo-eventtap"
    thread.qualityOfService = .userInteractive
    thread.start()
}

let HK_FORWARD: UInt32 = 1          // Opt+Tab — search mode forward
let HK_REVERSE: UInt32 = 2          // Opt+Shift+Tab — search mode reverse
let HK_QUICK_FORWARD: UInt32 = 3    // Cmd+Tab — quick mode forward
let HK_QUICK_REVERSE: UInt32 = 4    // Cmd+Shift+Tab — quick mode reverse
let DISPLAY_LIMIT = 12

// TODO: full-text search over window *contents*. Approach: walk each window's
// AX subtree (AXChildren recursively) collecting AXValue / AXTitle / AXValue
// of AXStaticText and AXTextArea elements; index the result; substring match.
// Caveats: many apps (especially Electron) expose poor AX trees; can be slow
// for many windows; needs cache + invalidation strategy.

// MARK: - App ------------------------------------------------------------------
final class App: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    var panel: SwitcherPanel!
    var view: SwitcherView!
    var allRows: [WindowRecord] = []
    var rows: [WindowRecord] = []
    var selected: Int = 0
    var isDismissing: Bool = false
    var quickMode: Bool = false       // true → "release Cmd to commit" flow
    var modifierMonitor: Any?
    var keyMonitor: Any?
    /// Polls AX titles while the panel is visible so e.g. Spotify track
    /// changes appear live in the row without dismissing/reopening.
    var liveRefreshTimer: Timer?
    /// Drives ~30fps redraws during a "zlip" flash on title change.
    var flashAnimationTimer: Timer?
    /// Windows the user explicitly dismissed via Cmd+M / Cmd+H from the
    /// switcher, in dismissal order (oldest first, newest last). These are
    /// sunk to the bottom of the listing — most-recently-dismissed at the
    /// very bottom, since they're the least likely target on the next press.
    var dismissedWindowIDs: [CGWindowID] = []
    /// Pids whose terminate() / forceTerminate() we just called. Filtered out
    /// of the row list optimistically so the dying app disappears instantly,
    /// without waiting for macOS to actually kill the process.
    private var terminatingPids: Set<pid_t> = []
    /// Mach-time deadline — ignore panel-resign-key dismissals until this
    /// passes. Set after hide/minimize/forceQuit so the panel stays open
    /// even though macOS shifts focus to the next .regular app.
    private var ignoreResignKeyUntil: TimeInterval = 0

    /// External invocation: `open "switcharoo://show"` or `switcharoo://quick`. Lets
    /// other tools (Raycast Quicklinks, Alfred, BTT, shell scripts) trigger
    /// the panel without owning a hotkey. `switcharoo://snap` shows the panel
    /// and renders it to /tmp/switcharoo-ui.png — self-rendering needs no
    /// Screen Recording permission, handy for README screenshots.
    func application(_ sender: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "switcharoo" {
            switch url.host {
            case "show":  show(startReversed: false, quick: false)
            case "quick": show(startReversed: false, quick: true)
            case "snap":  snapPanel()
            case "login-on":  setLaunchAtLogin(true)
            case "login-off": setLaunchAtLogin(false)
            default:      break
            }
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Default to fast mode on — the dismissal fade is the only animation,
        // and a switcher should feel instant.
        UserDefaults.standard.register(defaults: ["fastMode": true])
        ActivationMRU.shared.start()
        promptAX()
        installMenu()
        buildPanel()
        installHotkeys()
        installCmdTabTap()

        NotificationCenter.default.addObserver(
            forName: .switcharooHotkey, object: nil, queue: .main
        ) { [weak self] n in
            self?.onHotkey(n)
        }

        // Clean up terminatingPids when the OS confirms the app actually died,
        // and re-render so the panel is up-to-date instantly.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] n in
            guard let self,
                  let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.terminatingPids.remove(app.processIdentifier)
            if self.panel.isVisible { self.refresh() }
        }

        // In quick mode, releasing Command commits the current selection —
        // the canonical Cmd-Tab feel. Called synchronously on the main runloop
        // so a fast tap commits without an extra runloop hop.
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] ev in
            guard let self else { return ev }
            if self.panel.isVisible && self.quickMode
                && !ev.modifierFlags.contains(.command) {
                self.commit()
            }
            return ev
        }

        // Vim-style Ctrl+J / Ctrl+K to move down / up. Handled here rather
        // than via the text-field delegate so it works identically in search
        // mode (field editor has focus) and quick mode (panel has focus).
        // Returning nil swallows the event so Ctrl+J doesn't insert a newline
        // into the search field.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] ev in
            guard let self, self.panel.isVisible,
                  ev.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control
            else { return ev }
            switch ev.charactersIgnoringModifiers {
            case "j": self.cycle(reverse: false); return nil
            case "k": self.cycle(reverse: true);  return nil
            default:  return ev
            }
        }
    }

    func installMenu() {
        // Even though we're LSUIElement and have no visible menu bar, the main
        // menu is what wires standard key equivalents (Cmd+A, Cmd+C, Cmd+V,
        // Cmd+X, Cmd+M, Cmd+H) into the responder chain. Custom items below
        // set their target to `self` so they fire regardless of who's first
        // responder.
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let prefs = NSMenuItem(title: "Preferences…",
                               action: #selector(openPrefs(_:)),
                               keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)
        let launch = NSMenuItem(title: "Launch at Login",
                                action: #selector(toggleLaunchAtLogin(_:)),
                                keyEquivalent: "")
        launch.target = self
        launch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        appMenu.addItem(launch)
        appMenu.addItem(NSMenuItem.separator())
        // Cmd+Q: when the panel is up, quit the highlighted app (canonical
        // switcher behavior — matches Cmd+M and Cmd+H). When the panel is
        // hidden, quit switcharoo itself.
        let quit = NSMenuItem(title: "Quit",
                              action: #selector(handleQuit(_:)),
                              keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // Renamed from "Window" so AppKit doesn't auto-inject the standard
        // Minimize / Zoom / Bring All to Front items, which would shadow ours.
        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "Actions")
        let minItem = NSMenuItem(title: "Minimize Highlighted",
                                 action: #selector(minimizeHighlighted(_:)),
                                 keyEquivalent: "m")
        minItem.target = self
        winMenu.addItem(minItem)
        let hideItem = NSMenuItem(title: "Hide Highlighted App",
                                  action: #selector(hideHighlighted(_:)),
                                  keyEquivalent: "h")
        hideItem.target = self
        winMenu.addItem(hideItem)
        // Cmd+Opt+Q — same key as the system Force Quit dialog. Acts on the
        // highlighted app's process, not switcharoo itself.
        let forceQuit = NSMenuItem(title: "Force Quit Highlighted App",
                                   action: #selector(forceQuitHighlighted(_:)),
                                   keyEquivalent: "q")
        forceQuit.keyEquivalentModifierMask = [.command, .option]
        forceQuit.target = self
        winMenu.addItem(forceQuit)
        winItem.submenu = winMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: Window management actions ------------------------------------------

    private func axWindowFor(_ r: WindowRecord) -> AXUIElement? {
        let app = axApp(r.pid)
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let wins = raw as? [AXUIElement],
              let axGet = axGetWindow else { return nil }
        for w in wins {
            var wid: CGWindowID = 0
            if axGet(w, &wid) == .success, wid == r.windowID { return w }
        }
        return nil
    }

    private func selectedRecord() -> WindowRecord? {
        guard selected < rows.count else { return nil }
        return rows[selected]
    }

    /// Append a windowID to the dismissed list, removing any prior occurrence
    /// so it lands at the end (most-recently-dismissed).
    private func markDismissed(_ wid: CGWindowID) {
        dismissedWindowIDs.removeAll(where: { $0 == wid })
        dismissedWindowIDs.append(wid)
    }

    /// Move windows whose IDs are in dismissedWindowIDs to the end of the
    /// list, preserving dismissal order (oldest dismissed first, newest last).
    private func sortDismissedToBottom(_ rs: [WindowRecord]) -> [WindowRecord] {
        guard !dismissedWindowIDs.isEmpty else { return rs }
        let dismissedSet = Set(dismissedWindowIDs)
        var nondismissed: [WindowRecord] = []
        var dismissed: [WindowRecord] = []
        for r in rs {
            if dismissedSet.contains(r.windowID) { dismissed.append(r) }
            else                                 { nondismissed.append(r) }
        }
        // Sort the dismissed group by their position in dismissedWindowIDs —
        // earlier-dismissed first, so most-recently-dismissed lands at the very bottom.
        let order: [CGWindowID: Int] = Dictionary(
            uniqueKeysWithValues: dismissedWindowIDs.enumerated().map { ($0.element, $0.offset) })
        dismissed.sort { (order[$0.windowID] ?? .max) < (order[$1.windowID] ?? .max) }
        return nondismissed + dismissed
    }

    @objc func minimizeHighlighted(_ sender: Any?) {
        guard let r = selectedRecord(), let win = axWindowFor(r) else { return }
        AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        markDismissed(r.windowID)
        keepPanelOpen()
        refresh()
    }

    @objc func openPrefs(_ sender: Any?) {
        PreferencesController.shared.show()
    }

    @objc func handleQuit(_ sender: Any?) {
        if panel.isVisible, let r = selectedRecord() {
            markTerminating(r.pid)
            _ = NSRunningApplication(processIdentifier: r.pid)?.terminate()
            keepPanelOpen()
            refresh()
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Optimistically treat a pid as gone. If the actual terminate ends up
    /// refusing (e.g. unsaved-work prompt), we clear the mark after a few
    /// seconds so the app reappears in the list.
    private func markTerminating(_ pid: pid_t) {
        terminatingPids.insert(pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.terminatingPids.remove(pid)
            if self?.panel.isVisible == true { self?.refresh() }
        }
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        setLaunchAtLogin(SMAppService.mainApp.status != .enabled)
        sender.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    func setLaunchAtLogin(_ on: Bool) {
        let svc = SMAppService.mainApp
        do {
            if on {
                if svc.status != .enabled { try svc.register() }
            } else if svc.status == .enabled {
                try svc.unregister()
            }
            switcharooLog("Launch at Login → \(svc.status == .enabled ? "enabled" : "disabled")")
        } catch {
            switcharooLog("setLaunchAtLogin(\(on)) failed: \(error)")
        }
    }

    @objc func hideHighlighted(_ sender: Any?) {
        guard let r = selectedRecord() else { return }
        // Hide affects the entire app — mark every window for that pid.
        for wid in allRows.filter({ $0.pid == r.pid }).map(\.windowID) {
            markDismissed(wid)
        }
        _ = NSRunningApplication(processIdentifier: r.pid)?.hide()
        keepPanelOpen()
        refresh()
    }

    @objc func forceQuitHighlighted(_ sender: Any?) {
        guard let r = selectedRecord() else { return }
        markTerminating(r.pid)
        _ = NSRunningApplication(processIdentifier: r.pid)?.forceTerminate()
        keepPanelOpen()
        refresh()
    }

    /// Re-claim focus after an action that hides/minimizes another app. We
    /// (1) use the deprecated `ignoringOtherApps` activate — the modern API
    /// won't steal focus from a .regular app to an .accessory one — and
    /// (2) set a suppression window so the resignKey observer re-activates
    /// us if macOS yanks focus away again post-action.
    private func keepPanelOpen() {
        ignoreResignKeyUntil = CACurrentMediaTime() + 0.8
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if !quickMode { panel.makeFirstResponder(view.searchField) }
    }

    /// Re-fetch windows and re-apply the current query. Used after a window
    /// management action so the list reflects the new state.
    private func refresh() {
        let raw = listWindows().filter { !terminatingPids.contains($0.pid) }
        allRows = sortDismissedToBottom(raw)
        let q = view.searchField.stringValue
        let filtered = filterWindows(allRows, query: q)
        rows = Array(filtered.prefix(DISPLAY_LIMIT))
        selected = min(max(selected, 0), max(rows.count - 1, 0))
        view.rows = rows
        view.selected = selected
        sizeAndPosition()
        view.needsDisplay = true
    }

    func promptAX() {
        let opts: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func buildPanel() {
        view = SwitcherView(frame: NSRect(x: 0, y: 0, width: 720, height: 200))
        view.searchField.delegate = self
        panel = SwitcherPanel(
            contentRect: view.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true   // for hover-to-highlight

        // Dismiss when the panel loses key focus (user clicked outside, or
        // activated another app via the dock / Cmd-Tab / Spotlight). We do NOT
        // dismiss if our own app is still active — that means focus moved to
        // another window of ours (e.g. Preferences) or to a brief internal
        // field-editor shuffle, neither of which should kill the panel.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, !self.isDismissing, self.panel.isVisible else { return }
            // Defer one tick so NSApp.isActive reflects the post-event state.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDismissing, self.panel.isVisible else { return }
                // During the suppression window (right after a management
                // action), aggressively re-steal focus so keystrokes go
                // back to the panel, not the newly-frontmost app.
                if CACurrentMediaTime() < self.ignoreResignKeyUntil {
                    NSApp.activate(ignoringOtherApps: true)
                    self.panel.makeKeyAndOrderFront(nil)
                    if !self.quickMode {
                        self.panel.makeFirstResponder(self.view.searchField)
                    }
                    return
                }
                if NSApp.isActive { return }
                switcharooLog("resignKey: auto-dismissing panel — frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                self.dismissPanel()
            }
        }
    }

    func onHotkey(_ n: Notification) {
        let id = (n.userInfo?["id"] as? UInt32) ?? HK_FORWARD
        let quick = (id == HK_QUICK_FORWARD || id == HK_QUICK_REVERSE)
        let reverse = (id == HK_REVERSE || id == HK_QUICK_REVERSE)
        switcharooLog("onHotkey id=\(id) quick=\(quick) reverse=\(reverse) wasVisible=\(panel.isVisible)")
        if !panel.isVisible {
            show(startReversed: reverse, quick: quick)
        } else {
            cycle(reverse: reverse)
        }
    }

    func show(startReversed: Bool, quick: Bool = false) {
        quickMode = quick
        view.quickMode = quick
        view.refreshThemeColors()

        let raw = listWindows().filter { !terminatingPids.contains($0.pid) }
        allRows = sortDismissedToBottom(raw)
        rows = Array(allRows.prefix(DISPLAY_LIMIT))
        view.searchField.stringValue = ""
        view.query = ""
        view.axTrusted = AXIsProcessTrusted()
        if rows.isEmpty {
            selected = 0
        } else {
            selected = startReversed ? rows.count - 1 : min(1, rows.count - 1)
        }
        view.rows = rows
        view.selected = selected
        sizeAndPosition()
        view.needsDisplay = true
        let sourceApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // In search mode, focus the text field. In quick mode, don't — there's
        // no field to type into, and panel itself receives Tab via the hotkey.
        if !quick { panel.makeFirstResponder(view.searchField) }
        switcharooLog("show: quick=\(quick) rows=\(rows.count) selected=\(selected) sourceApp=\(sourceApp?.localizedName ?? "?") isActive=\(NSApp.isActive) panelKey=\(panel.isKeyWindow)")
        // The ordering itself is the evidence for MRU problems: index 1 should
        // be the app you were just in. Marked with * is the preselected row.
        switcharooLog("show rows: " + rows.enumerated().map {
            "\($0.offset)\($0.offset == selected ? "*" : "")=\($0.element.appName)#\($0.element.windowID)"
        }.joined(separator: " "))
        // Cooperative activation is asynchronous and can be silently denied:
        // NSApp.isActive/panelKey can both read true while the WindowServer
        // still has the previous app frontmost, which means keystrokes never
        // reach us. Sample the settled state to catch that split-brain.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let f = NSWorkspace.shared.frontmostApplication
            let ours = f?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            switcharooLog("show+150ms: frontmost=\(f?.localizedName ?? "?") panelOwnsFocus=\(ours ? "Y" : "**N**") isActive=\(NSApp.isActive) panelKey=\(self.panel.isKeyWindow) panelVisible=\(self.panel.isVisible)")
        }

        // Race: with a fast tap (press + release Cmd+Tab in <1 frame), the
        // user can release Cmd between the CGEventTap intercept and this
        // method actually running. The flagsChanged monitor missed the event
        // because the panel wasn't visible yet — catch it here.
        if quick && !NSEvent.modifierFlags.contains(.command) {
            commit()
            return
        }

        startLiveRefresh()
    }

    /// Begin polling AX for title changes on currently-listed rows. Cheap:
    /// a few AX attribute reads every 0.4s, only while the panel is up.
    func startLiveRefresh() {
        liveRefreshTimer?.invalidate()
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.refreshLiveTitles()
        }
        // .common so the timer fires while the user is typing in the field.
        RunLoop.main.add(t, forMode: .common)
        liveRefreshTimer = t
    }

    func stopLiveRefresh() {
        liveRefreshTimer?.invalidate()
        liveRefreshTimer = nil
    }

    private func refreshLiveTitles() {
        guard panel.isVisible, !rows.isEmpty, let axGet = axGetWindow else { return }
        var newRows = rows
        var changed = false
        // Group by pid so we only do one kAXWindowsAttribute fetch per app.
        let pids = Set(rows.map(\.pid))
        for pid in pids {
            let appElem = axApp(pid)
            var raw: AnyObject?
            guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &raw) == .success,
                  let axWindows = raw as? [AXUIElement] else { continue }
            for axWin in axWindows {
                var wid: CGWindowID = 0
                guard axGet(axWin, &wid) == .success else { continue }
                guard let idx = newRows.firstIndex(where: { $0.windowID == wid }) else { continue }
                var titleRaw: AnyObject?
                guard AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRaw) == .success,
                      let t = titleRaw as? String, !t.isEmpty,
                      t != newRows[idx].title
                else { continue }
                newRows[idx] = WindowRecord(
                    windowID: newRows[idx].windowID,
                    pid: newRows[idx].pid,
                    appName: newRows[idx].appName,
                    title: t,
                    icon: newRows[idx].icon)
                view.rowFlashUntil[newRows[idx].windowID] =
                    CACurrentMediaTime() + view.flashDuration
                changed = true
            }
        }
        if changed {
            rows = newRows
            view.rows = newRows
            view.needsDisplay = true
            startFlashAnimation()
        }
    }

    /// Briefly drive 30fps redraws so the per-row flash on title change
    /// actually animates instead of snapping. Stops once all flashes expire.
    private func startFlashAnimation() {
        flashAnimationTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] tm in
            guard let self else { tm.invalidate(); return }
            let now = CACurrentMediaTime()
            // Drop expired entries to keep the dict small.
            self.view.rowFlashUntil = self.view.rowFlashUntil.filter { $0.value > now }
            self.view.needsDisplay = true
            if self.view.rowFlashUntil.isEmpty {
                tm.invalidate()
                self.flashAnimationTimer = nil
            }
        }
        RunLoop.main.add(t, forMode: .common)
        flashAnimationTimer = t
    }

    func cycle(reverse: Bool) {
        guard !rows.isEmpty else { return }
        selected = reverse
            ? (selected - 1 + rows.count) % rows.count
            : (selected + 1) % rows.count
        view.selected = selected
        view.needsDisplay = true
    }

    /// Panel dismissal. In fast mode this is instant; otherwise a quick fade.
    func dismissPanel() {
        stopLiveRefresh()
        if SwitcharooConfig.fastMode {
            panel.orderOut(nil)
            return
        }
        isDismissing = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = SwitcharooConfig.dismissDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.isDismissing = false
        })
    }

    func commit() {
        let pick = (selected < rows.count) ? rows[selected] : nil
        let pickDesc = pick.map { "\($0.appName) wid=\($0.windowID) \"\($0.title)\"" }
            ?? "**none**"
        switcharooLog("commit: selected=\(selected)/\(rows.count) pick=\(pickDesc) query=\"\(view.searchField.stringValue)\" frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") isActive=\(NSApp.isActive) panelKey=\(panel.isKeyWindow)")
        // Raise BEFORE dismissing. Ordering the panel out drops our only
        // window, which starts macOS deactivating us — and an app that is no
        // longer active is refused when it asks to activate another one. Doing
        // it in this order means we still hold activation when we ask.
        if let pick {
            // Picking a previously-dismissed window cancels its "dismissed"
            // status so it returns to normal MRU position next time.
            dismissedWindowIDs.removeAll(where: { $0 == pick.windowID })
            raise(pick)
        }
        dismissPanel()
        if let pick {
            // Did the target actually end up frontmost? This is the line to
            // look at when a switch "didn't take".
            let pid = pick.pid, name = pick.appName
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let f = NSWorkspace.shared.frontmostApplication
                let ok = f?.processIdentifier == pid
                switcharooLog("commit+400ms: target=\(name) frontmost=\(f?.localizedName ?? "?") targetIsFrontmost=\(ok ? "Y" : "**N**")")
            }
        }
    }

    func cancel() {
        switcharooLog("cancel: panel cancelled (Esc / cancelOperation)")
        dismissPanel()
        NSApp.hide(nil)
    }

    /// Show the panel, then render its content view to /tmp/switcharoo-ui.png.
    /// Self-rendering (cacheDisplay) needs no Screen Recording permission.
    /// The 0.6s delay lets the live-title pass and first draw settle.
    func snapPanel() {
        show(startReversed: false, quick: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self,
                  let rep = self.view.bitmapImageRepForCachingDisplay(in: self.view.bounds)
            else { return }
            self.view.cacheDisplay(in: self.view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: "/tmp/switcharoo-ui.png"))
            switcharooLog("snap → /tmp/switcharoo-ui.png (\(data.count) bytes)")
        }
    }

    func applyQuery(_ q: String) {
        let filtered = filterWindows(allRows, query: q)
        rows = Array(filtered.prefix(DISPLAY_LIMIT))
        selected = 0
        view.query = q
        view.rows = rows
        view.selected = selected
        sizeAndPosition()
        view.needsDisplay = true
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        applyQuery(view.searchField.stringValue)
    }

    /// Mouse-driven: hover over a row sets it as the selection.
    func setSelected(_ i: Int) {
        guard i >= 0, i < rows.count, i != selected else { return }
        selected = i
        view.selected = i
        view.needsDisplay = true
    }

    /// Mouse-driven: click a row to commit immediately.
    func commit(atRow i: Int) {
        guard i >= 0, i < rows.count else { return }
        selected = i
        commit()
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancel(); return true
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertLineBreak(_:)):
            commit(); return true
        case #selector(NSResponder.moveDown(_:)):
            cycle(reverse: false); return true
        case #selector(NSResponder.moveUp(_:)):
            cycle(reverse: true); return true
        case #selector(NSResponder.insertTab(_:)):
            cycle(reverse: false); return true
        case #selector(NSResponder.insertBacktab(_:)):
            cycle(reverse: true); return true
        default:
            return false
        }
    }

    func sizeAndPosition() {
        let listHeight: CGFloat
        if !rows.isEmpty {
            listHeight = view.pad * 2 + CGFloat(rows.count) * view.rowHeight
        } else if view.emptyMessage != nil {
            listHeight = view.pad * 2 + view.rowHeight
        } else {
            listHeight = 0   // collapse to just the search bar
        }
        let h = view.searchHeight + listHeight
        let w = view.panelWidth
        guard let scr = NSScreen.main?.visibleFrame else { return }
        // Top of panel sits ~22% down from the top of the usable area, so the
        // whole panel lands roughly in the top third of the screen.
        let topY = scr.maxY - scr.height * 0.22
        let frame = NSRect(x: scr.midX - w/2, y: topY - h, width: w, height: h)
        panel.setFrame(frame, display: false)
        view.frame = NSRect(origin: .zero, size: frame.size)
    }

    func installHotkeys() {
        let sig: OSType = 0x5357524F // 'SWRO'
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, evt, _) -> OSStatus in
                var hkid = EventHotKeyID()
                let r = GetEventParameter(
                    evt, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hkid)
                if r == noErr {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .switcharooHotkey, object: nil,
                            userInfo: ["id": hkid.id])
                    }
                }
                return noErr
            },
            1, &spec, nil, nil)

        // Search mode: Opt+Tab forward, Opt+Shift+Tab reverse.
        let searchMods = UInt32(optionKey)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(kVK_Tab), searchMods,
            EventHotKeyID(signature: sig, id: HK_FORWARD),
            GetApplicationEventTarget(), 0, &ref)
        var refR: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(kVK_Tab), searchMods | UInt32(shiftKey),
            EventHotKeyID(signature: sig, id: HK_REVERSE),
            GetApplicationEventTarget(), 0, &refR)

        // Quick mode (Cmd-Tab-style) is now wired via CGEventTap, not Carbon
        // — see installCmdTabTap(). The tap intercepts Cmd+Tab itself.
    }
}

// MARK: - Bootstrap ------------------------------------------------------------
let nsApp = NSApplication.shared
let delegate = App()
nsApp.delegate = delegate
nsApp.setActivationPolicy(.accessory)
nsApp.run()
