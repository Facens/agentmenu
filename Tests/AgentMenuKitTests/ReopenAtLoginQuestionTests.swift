// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

private let sessionOne = "0b6f3a52-7c1e-4d0a-9a43-5f1e2c7d8b90"
private let sessionTwo = "1c7a4b63-8d2f-4e1b-8b54-6a2f3d8e9ca1"

private func offer(_ cause: EndCause?, sessions: Int = 2) -> RestoreOffer {
    guard let cause, sessions > 0 else { return RestoreOffer() }
    let ids = [sessionOne, sessionTwo].prefix(sessions)
    let pending = ids.map {
        RestorableSession(
            sessionID: $0, launchID: "launch-" + $0.prefix(8), cwd: "/p/\($0.prefix(4))", terminalID: "terminal-app",
            endedAt: Date(timeIntervalSince1970: 1_000_000), cause: cause
        )
    }
    return RestoreOffer(pending: pending, pendingCause: cause, pendingFormedAt: Date(timeIntervalSince1970: 1_000_005))
}

/// R25, U15: the once-only "reopen sessions at login?" question and the startup
/// restore it turns on. Both decisions are pure, so everything that matters is
/// here; the banner and the General pane only draw what they say.
func runReopenAtLoginQuestionTests(_ t: TestRunner) {
    t.suite("ReopenAtLoginQuestion")

    // MARK: Where the question surfaces

    do {
        let config = Config()
        t.expectEqual(ReopenAtLoginQuestion.surface(for: config, offer: RestoreOffer()), .notOffered, "no pending set: the question never surfaces")
        t.expectEqual(ReopenAtLoginQuestion.surface(for: config, offer: offer(.powerOff, sessions: 0)), .notOffered, "an empty set is no set")
        t.expectEqual(ReopenAtLoginQuestion.surface(for: config, offer: offer(.powerOff)), .inBanner, "the first pending set after a restart asks, inside the banner")
        t.expectEqual(ReopenAtLoginQuestion.surface(for: config, offer: offer(.powerOff, sessions: 1)), .inBanner, "one session is enough of a set")
        t.expectEqual(ReopenAtLoginQuestion.surface(for: config, offer: offer(.hostDied)), .notOffered, "a crashed host is not a restart: nothing to ask")
        t.expectEqual(ReopenAtLoginQuestion.surface(for: config, offer: offer(.together)), .notOffered, "a Quit all is the user's own act: nothing to ask")
        t.expectEqual(ReopenAtLoginQuestion.surface(for: config, offer: offer(.unexplained)), .notOffered, "an unexplained ending is not a restart either")
    }

    // MARK: Answering, either way, is the end of the question

    do {
        var yes = Config()
        ReopenAtLoginQuestion.record(answer: true, in: &yes)
        t.expect(yes.reopenAtLoginAsked, "yes sets the asked flag")
        t.expect(yes.reopenAtLogin, "and turns the setting on")
        t.expectEqual(ReopenAtLoginQuestion.surface(for: yes, offer: offer(.powerOff)), .alreadyAsked, "and the next restart does not ask again")

        var no = Config()
        ReopenAtLoginQuestion.record(answer: false, in: &no)
        t.expect(no.reopenAtLoginAsked, "no sets the asked flag too")
        t.expect(!no.reopenAtLogin, "and leaves the setting off")
        t.expectEqual(ReopenAtLoginQuestion.surface(for: no, offer: offer(.powerOff)), .alreadyAsked, "a no is an answer: nobody sees the question twice")

        var settings = Config()
        settings.setReopenAtLogin(true)
        t.expect(settings.reopenAtLogin && settings.reopenAtLoginAsked, "the Settings toggle, turned on, answers the question")
        settings.setReopenAtLogin(false)
        t.expect(!settings.reopenAtLogin && settings.reopenAtLoginAsked, "and turned off again it stays answered")

        var byHand = Config()
        byHand.reopenAtLogin = true
        t.expectEqual(ReopenAtLoginQuestion.surface(for: byHand, offer: offer(.powerOff)), .alreadyAsked, "a setting turned on in the file is not asked about either")
    }

    // MARK: Off until answered

    do {
        let config = Config()
        t.expect(!config.reopenAtLogin && !config.reopenAtLoginAsked, "a fresh config has neither: the setting is off and nobody has been asked")
        t.expect(
            !ReopenAtLoginStartup.shouldRestore(setting: config.reopenAtLogin, bootChangedAtLaunch: true, launchPassDone: true, offer: offer(.powerOff)),
            "unanswered, a restart only offers: nothing starts on its own"
        )
    }

    // MARK: The startup restore

    t.expect(
        ReopenAtLoginStartup.shouldRestore(setting: true, bootChangedAtLaunch: true, launchPassDone: true, offer: offer(.powerOff)),
        "setting on, the boot id changed, a restart's set pending: the restore starts at startup"
    )
    t.expect(
        !ReopenAtLoginStartup.shouldRestore(setting: true, bootChangedAtLaunch: false, launchPassDone: true, offer: offer(.powerOff)),
        "setting on without a boot id change: nothing starts (AgentMenu was only restarted)"
    )
    t.expect(
        !ReopenAtLoginStartup.shouldRestore(setting: false, bootChangedAtLaunch: true, launchPassDone: true, offer: offer(.powerOff)),
        "setting off: nothing starts, whatever the boot id did"
    )
    t.expect(
        !ReopenAtLoginStartup.shouldRestore(setting: true, bootChangedAtLaunch: true, launchPassDone: true, offer: RestoreOffer()),
        "setting on, boot id changed, nothing pending: nothing to start"
    )
    t.expect(
        !ReopenAtLoginStartup.shouldRestore(setting: true, bootChangedAtLaunch: true, launchPassDone: false, offer: offer(.powerOff)),
        "before the relaunch pass has run, a set is an earlier run's, not this restart's: wait"
    )
    t.expect(
        !ReopenAtLoginStartup.shouldRestore(setting: true, bootChangedAtLaunch: true, launchPassDone: true, offer: offer(.hostDied)),
        "a host-death set is never restored automatically, even with the setting on and the boot id changed"
    )
    t.expect(
        !ReopenAtLoginStartup.shouldRestore(setting: true, bootChangedAtLaunch: true, launchPassDone: true, offer: offer(.together)),
        "nor is a Quit all's set: the user ended those themselves"
    )
    t.expect(
        !ReopenAtLoginStartup.shouldRestore(setting: true, bootChangedAtLaunch: true, launchPassDone: true, offer: offer(.unexplained)),
        "nor one nothing explains"
    )

    // MARK: A real relaunch classification feeds it: boot id changed -> powerOff set

    do {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let row = { () -> LedgerRow in
            var row = LedgerRow(
                launchID: "launch-" + sessionOne.prefix(8), kind: .restore(resumedSessionID: sessionOne), cwd: "/p/a",
                terminalID: "terminal-app", startedAt: t0
            )
            row.endedAt = t0.addingTimeInterval(10)
            return row
        }()
        func classified(storedBoot: String, currentBoot: String) -> RestoreOffer {
            var data = SessionStoreData()
            data.ledger = LaunchLedger(rows: [row])
            data.restore = RestoreState(bootID: storedBoot)
            RestorePlanner.classify(&data, context: RestoreContext(
                now: t0.addingTimeInterval(1000), isRelaunchPass: true, currentBootID: currentBoot
            ))
            return RestoreActions.offer(state: data.restore, starting: [])
        }
        let afterRestart = classified(storedBoot: "uuid:AAAA", currentBoot: "uuid:BBBB")
        t.expectEqual(afterRestart.pendingCause, .powerOff, "a relaunch on a different boot classifies what ended as a restart's set")
        t.expectEqual(ReopenAtLoginQuestion.surface(for: Config(), offer: afterRestart), .inBanner, "which is where the question first surfaces")
        t.expect(
            ReopenAtLoginStartup.shouldRestore(
                setting: true, bootChangedAtLaunch: BootID.hasChanged(from: "uuid:AAAA", to: "uuid:BBBB"), launchPassDone: true, offer: afterRestart
            ),
            "and with the setting on it is restored at startup"
        )
        let sameBoot = classified(storedBoot: "uuid:AAAA", currentBoot: "uuid:AAAA")
        t.expectEqual(sameBoot.pendingCause, .unexplained, "a relaunch on the same boot is an unexplained ending")
        t.expectEqual(ReopenAtLoginQuestion.surface(for: Config(), offer: sameBoot), .notOffered, "which is not a restart: no question")
        t.expect(
            !ReopenAtLoginStartup.shouldRestore(
                setting: true, bootChangedAtLaunch: BootID.hasChanged(from: "uuid:AAAA", to: "uuid:AAAA"), launchPassDone: true, offer: sameBoot
            ),
            "and nothing starts on its own"
        )
    }
}
