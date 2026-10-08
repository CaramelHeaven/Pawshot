import Foundation
import os

/// What the window after an update says (`WhatsNewView`): every version the person skipped, not
/// just the last one — updating from 0.4.6 to 0.4.9 tells about 0.4.7, 0.4.8 and 0.4.9. A new
/// entry goes on top with every raise of `MARKETING_VERSION` — AGENTS.md, Releasing — and
/// `WhatsNewTests` fails until it does. Older entries stay, translations and all.
enum WhatsNew {
    struct Entry: Equatable {
        let version: String
        /// Plain words for a person, not a changelog. Empty for a release with nothing to tell.
        let text: String
    }

    /// Newest first. The history starts at 0.4.7, the first version with this window.
    static var history: [Entry] {
        [
            Entry(version: "0.6.13", text: String(localized: """
            Choose a starting colour for shapes and lines, the pencil, and text in Settings → \
            Screenshots → Editor. Each has its own custom colour. New marks in open editors take \
            the new colour straight away; marks already on the shot keep theirs.
            """)),
            Entry(version: "0.6.12", text: String(localized: """
            Pinch with two fingers in the screenshot editor to zoom from 100% to 400%. Move around \
            the enlarged shot with two fingers. The scale appears only while you pinch. Marks stay \
            in place when you zoom back out, and the file keeps its original size.
            """)),
            Entry(version: "0.6.11", text: String(localized: """
            The bar under a recording region can be moved: drag it by its edge, and it stays \
            where you left it. Near the top of the screen, Options open downwards.

            Pick how many frames a second a recording takes — 15, 24, 30 or 60 — in Settings → \
            Recording or in Options before a take. Fewer frames make a lighter file. Bug report \
            now records at 30.

            Saving and copying a video is quicker: clicks are no longer drawn into it unless you \
            turn them on, and a GIF with effects is made faster.
            """)),
            Entry(version: "0.6.10", text: String(localized: """
            Picking a region to record no longer freezes the screen: a video under it keeps \
            playing while you choose.

            Copy Text says "Reading…" when the text takes a while — the first time after an \
            install it can take up to half a minute.

            If one of the recording shortcuts didn't work during a take, Settings → Shortcuts \
            says which. And the paw's menu tells you when macOS still takes one of your shortcuts.

            Recording is lighter on your Mac.
            """)),
            Entry(version: "0.6.9", text: String(localized: """
            When you record a region, it now comes back where you left it, even if you closed \
            without recording.

            Zoom is gone from recordings: ⇧⌘6, the magnifier on the pill and Settings → Recording → \
            Zoom. Older recordings still open; their zooms are just left out.

            A region dragged across windows no longer snaps to them by itself. While you drag it, a \
            target shows in the middle of each window: let go with the cursor on one, and the region \
            takes that window's size.
            """)),
            Entry(version: "0.6.8", text: String(localized: """
            Your headphones keep playing while you record. With the microphone off, Pawshot used \
            to listen to it anyway, to tell you when you talked — and Bluetooth headphones switched \
            to their call mode for it, cutting the Mac's sound. That hint is gone: with the \
            microphone off, Pawshot doesn't touch it.

            Zoom takes one or two clicks now — Settings → Recording → Zoom. With two, the first \
            click zooms in there and the second moves the zoom over to the new place. A quick \
            double click in an app doesn't count as the second.
            """)),
            Entry(version: "0.6.7", text: String(localized: """
            Zoom works by a click now. Press ⇧⌘6, or the magnifier on the pill: a halo follows the \
            cursor, and every click zooms the video there, with rings spreading so you see it \
            took. The halo goes after five clicks — Settings → Recording → Zoom changes that. The \
            orange outline and holding the key to zoom are gone, and so is ⇧⌘K.

            In the screenshot editor, the window's edge is easy to grab again for growing or \
            cropping the shot.
            """)),
            Entry(version: "0.6.6", text: String(localized: """
            A halo round the cursor while you record: press ⇧⌘K, or the new button on the pill \
            after the pen. It follows the mouse, and every click spreads rings like water. Only \
            you see it — it is never in the video.

            It goes by itself after five clicks. Settings → Recording → Shown on the screen \
            changes that to 1, 3 or 4 clicks, or keeps it until you switch it off. The contact \
            address for sending logs is now capi.hev@gmail.com.
            """)),
            Entry(version: "0.6.5", text: String(localized: """
            Fixes for recording.

            A part hidden with ⌃⌘B now stays hidden right up to a cut and to the start and the end \
            of the video: at the edge of a piece it used to turn sharp for a moment.

            A zone to hide stays over the same part of the screen when the region is moved on a \
            pause, and a zone at the edge of the picture no longer gets a dark rim. With zones \
            drawn and a window or the whole screen picked, a line above the toolbar says they \
            won't be hidden.

            The recording screen no longer has a badge with the coordinates by the cursor; it shows \
            up only while you type a size.

            With a region on more than one display, Record and ↩ take the one you last touched. \
            Esc while drawing a zone no longer wipes the region.

            If the effects of a recording can't be read, the video editor says so rather than \
            saving it without them quietly.

            ⇧⌘2 sometimes showed nothing after the Mac had slept or its displays had changed, until \
            Pawshot was restarted. It shows the dimming now.
            """)),
            Entry(version: "0.6.4", text: String(localized: """
            A recording on pause can be moved: a thin frame appears round the region, drag it to \
            another window and carry on. The size stays the same, and clicks inside the region \
            still go to the app you are recording.

            Zones to hide. On the recording screen press H and draw over what must not be seen: \
            a tab bar, a mailbox, a token. The zone is blurred in the video from the first frame \
            to the last; the recording itself stays sharp, and the editor has a switch for it. \
            ⌫ removes the last zone, Esc stops drawing.
            """)),
            Entry(version: "0.6.3", text: String(localized: """
            Before you start recording, Pawshot now says what is about to go wrong. A line above \
            the toolbar appears when the microphone is on but hears nothing, when macOS still \
            holds one of the recording shortcuts (it names the item to untick in Keyboard \
            Shortcuts), and when the disk has under 5 GB free.

            Options has a new Check the microphone: say something for three seconds, then hear \
            it played back.

            Recording profiles set the sound, clicks, zooms, resolution and format in one move: \
            Bug report is a GIF with clicks and no sound, Demo is full resolution with your \
            voice and zooms. P on the recording screen switches between them; they are also in \
            Options and in Settings → Recording.
            """)),
            Entry(version: "0.6.2", text: String(localized: """
            Three keys to hold while a recording runs, all under the left hand.

            ⌃⌘A — a spotlight: everything but a circle around the cursor goes dim in the video.

            ⌃⌘B — hide the picture: the video is blurred for as long as you hold, for a password \
            or a private message. The recording itself stays sharp, so the editor can show that \
            stretch again.

            ⌃⌘V — mute: the microphone records silence while you cough or answer someone.

            Cutting the last 10 seconds moved from ⇧⌘8 to ⌃⌘X. All four are changed in \
            Settings → Shortcuts.

            When you record with the microphone off and start talking, the pill says so once and \
            offers to start over with the microphone on. For that Pawshot listens during such a \
            recording and keeps nothing; macOS shows its orange microphone dot meanwhile. \
            Settings → Recording → Sound switches it off.
            """)),
            Entry(version: "0.6.1", text: String(localized: """
            New while a recording runs.

            Hold the zoom shortcut instead of tapping it, and the video stays zoomed in for as \
            long as you hold, following the cursor. A tap still marks a short zoom.

            Said something wrong? ⇧⌘8, or the scissors on the pill, marks the last 10 seconds as \
            a bad take: the recording goes on, and the editor opens with them already cut. ⌘Z \
            there brings them back.

            ⇧⌘2 during a recording copies the picture being recorded to the clipboard, without \
            stopping.

            The pill shows how much the recording weighs, and warns when the disk has about five \
            minutes of room left. In Settings → Recording, Aim for picks a length to fit into: \
            the pill then shows the time against it.
            """)),
            Entry(version: "0.6", text: String(localized: """
            Recording a region works the way ⇧⌘5 does. After ⇧⌘3 the region you recorded last \
            time is there at once: drag it by its middle to move it, by an edge or a corner to \
            resize it, or draw a new one beside it. A click beside the region no longer wipes it.

            Pills appear on the edges as the cursor comes near, and the part under the cursor \
            lights up. A dragged region sticks to the edges of windows and of the screen; hold ⌘ \
            to switch that off. Arrows move the region by a point, ten with ⇧.

            Drag the region by its middle onto the middle of a window: the window lights up, and \
            dropped there the region takes its size. Move it again and it is the size it was.

            The bar under the region became a toolbar at the bottom of the screen: region, window \
            or the whole screen, then Options and Record. Options has the microphone — pick which \
            one to record — the system sound and what is shown in the video.

            The buttons of the pill shown during a recording light up under the cursor.
            """)),
            Entry(version: "0.5.3", text: String(localized: """
            About Pawshot, Settings and Open Pawshot from the paw's menu now open in front of \
            other apps, even when the window was already open behind them.

            The log saved from Settings → General → Diagnostics tells much more about what \
            happened, so a problem you send is easier to find.
            """)),
            Entry(version: "0.5.2", text: String(localized: """
            Dragging the edge of the editor window adds the neighbouring part of the screen to the \
            shot again. On some Macs the window grew with grey around the shot instead.
            """)),
            Entry(version: "0.5.1", text: String(localized: """
            Settings are rearranged. Saving and the labels' font have a tab of their own, \
            Screenshots, and General keeps launching, quitting, the language and the logs. On \
            Recording each switch shows the key that changes it for one take. Shortcuts is a cheat \
            sheet: click a shortcut to change it; one that macOS takes first says so on its card, \
            with Fix… next to it.

            Closing a shot or a video now gives the keyboard back to the app you were in, so typing \
            no longer goes nowhere.
            """)),
            Entry(version: "0.5", text: String(localized: """
            Pick where ⌘S saves and in what format — PNG, JPEG or HEIC — in Settings → General → \
            Saving. Videos go to the same folder. ⇧⌘S asks for a name, a folder and a format just \
            once.

            ⌘D now reads QR codes and barcodes too: what they hold goes to the clipboard first, then \
            the text.

            In a narrow editor window the tools stay in one row, and the colours and widths open \
            from the chip next to them.

            The toolbar is rearranged: undo, turns and Clear All on the left, the size of the shot \
            in the middle, saving and copying on the right.

            ⌘Q no longer asks before closing a shot you only resized or turned — only one with \
            something drawn on it.
            """)),
            Entry(version: "0.4.10", text: String(localized: """
            A shortcut you change or remove in Settings during a recording now takes effect at \
            once. Until now the old one kept working until the recording ended, so pressing \
            Restart from habit could still throw the take away.

            The R button now shows the shape it will draw, even when a line is selected.

            When the region recording shortcut is removed, Stop Recording in the paw's menu \
            shows the full-screen one instead.

            A shortcut field says "Didn't reach Pawshot" even when you first pressed a key without \
            ⌘, ⌥ or ⌃ — until now it stayed silent then.
            """)),
            Entry(version: "0.4.9", text: String(localized: """
            R now draws a circle, a triangle and a diamond as well: pick one next to the line \
            widths, or press R again. A drawn shape switches the same way.

            The fill follows the opacity slider while you drag it, not only when you let go.

            Every shortcut in Settings now has a cross on its right: remove the shortcut \
            altogether, and the action stays in the paw's menu.

            If a shortcut never reaches Pawshot — macOS or another app takes it first — the field \
            now says so instead of staying silent.

            A shortcut field waiting for keys now lets go when you switch to another window. Until \
            now, Pawshot's shortcuts stopped working meanwhile.
            """)),
            Entry(version: "0.4.8", text: String(localized: """
            This window now opens in front of your other windows. After the last update it could hide \
            behind them.
            """)),
            Entry(version: "0.4.7", text: String(localized: """
            Settings now has a Statistics tab: how many shots you've taken, what you draw with most, \
            how many days in a row. It's all counted on this Mac only.

            Collect Logs can now be switched off — in the welcome window and in Settings → General → \
            Diagnostics.

            If something breaks, the logs reach the developer with one button: Send by Email…, in the \
            same place.
            """)),
        ]
    }

    /// What someone coming from `since` hasn't been told, newest first. `nil` is an update from
    /// 0.4.6 or older, which stored no version: everything there is. Versions compare as numbers,
    /// so 0.4.10 comes after 0.4.9.
    static func entries(in history: [Entry], since: String?) -> [Entry] {
        history.filter { entry in
            !entry.text.isEmpty && isNewer(entry.version, than: since)
        }
    }

    /// As numbers, so 0.4.10 comes after 0.4.9; anything is newer than no stored version. Also
    /// what keeps an older build run after a newer one from lowering the version seen — going
    /// back up would then tell the same news twice.
    static func isNewer(_ version: String, than seen: String?) -> Bool {
        seen.map { version.compare($0, options: .numeric) == .orderedDescending } ?? true
    }

    /// Once per version, and only after an update: a fresh install hasn't pressed "Get Started"
    /// yet and hears from the welcome window instead. No stored version with the welcome done is
    /// an update from 0.4.6, which stored none.
    static func shouldShow(lastSeen: String?, welcomeCompleted: Bool, current: String, history: [Entry]) -> Bool {
        welcomeCompleted && lastSeen != current && !entries(in: history, since: lastSeen).isEmpty
    }

    @MainActor
    static var showsAtLaunch: Bool {
        let settings = Settings.shared
        let lastSeen = settings.lastSeenVersion
        let welcomeCompleted = settings.welcomeCompleted
        let current = AboutPanel.version
        let history = Self.history
        let shows = shouldShow(lastSeen: lastSeen, welcomeCompleted: welcomeCompleted, current: current, history: history)
        logDecision(shows, lastSeen: lastSeen, welcomeCompleted: welcomeCompleted, current: current, history: history)
        return shows
    }

    /// Asked more than once per launch (the scene and the delegate), so a decision is logged
    /// only when it differs from the last one.
    @MainActor
    private static func logDecision(_ shows: Bool, lastSeen: String?, welcomeCompleted: Bool, current: String, history: [Entry]) {
        let unseen = entries(in: history, since: lastSeen).count
        let skippedEmpty = history.count(where: { $0.text.isEmpty && isNewer($0.version, than: lastSeen) })
        let reason = if !welcomeCompleted {
            "fresh install, Get Started not pressed"
        } else if lastSeen == current {
            "this version already seen"
        } else if unseen == 0 {
            "nothing to tell (\(skippedEmpty) newer entries with no text)"
        } else {
            "\(unseen) entries to tell"
        }
        let line = "what's new: \(shows ? "show" : "don't show") — \(reason), last seen \(lastSeen ?? "none"), now \(current)"
        guard line != lastLoggedDecision else { return }
        lastLoggedDecision = line
        logger.notice("\(line, privacy: .public)")
    }

    @MainActor private static var lastLoggedDecision: String?

    private static var logger: Logger {
        .pawshot("app")
    }
}
