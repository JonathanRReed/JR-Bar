import AppKit
import JRBarCore

/// Binds the palette's row builders to the stores that already own
/// each write, so the app delegate registers the whole palette in one
/// call. Every verb here is a path some other surface already uses —
/// the panel's guarded answer, `quiet`, the Effect Studio's scene, the
/// notch card's toggle strip, the Usage Center's focus — so the palette
/// adds a way in, never a second implementation.
@MainActor
enum PaletteWiring {
    /// The windows and Settings pages, as the delegate opens them.
    struct Windows {
        var overview: @MainActor () -> Void
        var usageCenter: @MainActor (String?) -> Void
        var history: @MainActor () -> Void
        var effects: @MainActor () -> Void
        var deck: @MainActor () -> Void
        var replay: @MainActor () -> Void
        var panel: @MainActor () -> Void
        var checkForUpdates: @MainActor () -> Void
        var settings: @MainActor (SettingsStore.Page) -> Void
    }

    static func sources(panel: PanelStore,
                        effects: EffectStudioStore,
                        toggles: @escaping @MainActor () -> SystemTogglesStore?,
                        aquarium: @escaping @MainActor () -> AquariumToy?,
                        confetti: @escaping @MainActor () -> ConfettiToy? = { nil },
                        hoarder: DataHoarderUtility,
                        history: HistoryStore? = nil,
                        windows: Windows) -> [any PaletteSource] {
        [
            agents(panel: panel, openPanel: windows.panel),
            quiet(panel: panel),
            lights(panel: panel, effects: effects),
            controlCenter(toggles: toggles),
            usage(panel: panel, windows: windows),
            tank(aquarium: aquarium),
            confettiSource(confetti),
            AppMenuPaletteSource(),
            archive(hoarder: hoarder),
        ] + (history.map { [historySource($0, windows: windows)] } ?? []) + [
            open(hoarder: hoarder, windows: windows),
        ]
    }

    /// History's rows through the daemon's `list_history`, matched by the
    /// window's own filter; a pick raises the window with the query as
    /// its filter and the row selected, and a live session opens as the
    /// window would open it.
    static func historySource(_ store: HistoryStore, windows: Windows) -> HistoryPaletteSource {
        HistoryPaletteSource(
            load: {
                guard store.core.isLive else { return nil }
                return (try? await store.core.listHistory()) ?? []
            },
            verbs: HistoryPaletteVerbs(
                show: { row, query in
                    store.filter = HistoryFilter(text: query)
                    windows.history()
                    store.selectedID = row.id
                },
                search: { query in
                    store.filter = HistoryFilter(text: query)
                    windows.history()
                },
                isLive: { store.isLiveSession($0) },
                openSession: { store.core.openSession($0) },
                canResume: { store.canResume($0) },
                // History's notice is the HUD's line: it reports through
                // the verb's ticket like the panel's toast.
                resume: { store.resume($0) }))
    }

    /// Asks and sessions, through the panel's own verbs — `approve` and
    /// `deny` re-check `canAnswer`, remote rows and a pending answer,
    /// and pin the request, exactly as the panel's buttons do.
    static func agents(panel: PanelStore, openPanel: @escaping @MainActor () -> Void) -> PaletteClosureSource {
        PaletteClosureSource(build: { agentItems(panel: panel, openPanel: openPanel) })
    }

    static func agentItems(panel: PanelStore, openPanel: @escaping @MainActor () -> Void) -> [PaletteItem] {
        let now = Date()
        let rows = AgentPaletteRows.items(rows: panel.rows, now: now, verbs: AgentPaletteVerbs(
            open: { panel.open($0) },
            approve: { panel.approve($0) },
            deny: { panel.deny($0) },
            snooze: { panel.snooze($0, seconds: $1) },
            copyPath: { panel.copyPath($0) },
            reveal: { panel.reveal($0) },
            dismiss: { panel.dismiss($0) },
            clear: { panel.clear($0) },
            reply: { panel.reply($0, text: $1) },
            replyDraft: { panel.replyDraft(for: $0) },
            setReplyDraft: { panel.setReplyDraft($1, for: $0) },
            alwaysAllow: { panel.alwaysAllow($0) },
            pick: { panel.pick($0, in: $1, of: $2) },
            picks: { panel.picks(for: $0) },
            sendPicks: { panel.sendPicks($0) }))
        // The panel's own `canUndoClear` reads a clock that only ticks
        // while the panel is open; the palette asks the real one.
        let undoable = panel.undoOffer.flatMap { offer in
            now.timeIntervalSince(offer.at) < EventPolicy.undoWindow ? offer.cleared : nil
        }
        let state = AgentPaletteRows.Commands(
            live: panel.core.isLive, connection: panel.connectionDescription,
            canRestart: panel.supervisorState != nil, completed: panel.completedCount,
            undoable: undoable)
        let commands = AgentPaletteRows.commandItems(state, verbs: AgentPaletteRows.CommandVerbs(
            restart: { panel.restartCore() },
            openPanel: openPanel,
            clearFinished: { panel.clearCompleted() },
            undoClear: { panel.undoClear() }))
        return rows + commands
    }

    /// The panel's quiet presets; picking a mode remembers it, as the
    /// footer's Mode menu does. Nothing to offer before the daemon is
    /// live — `quiet` would go nowhere.
    static func quiet(panel: PanelStore) -> PaletteClosureSource {
        let verbs = QuietPaletteVerbs(
            quiet: { mode, seconds in
                panel.quietMode = mode
                panel.quietFor(seconds: seconds)
            },
            end: { panel.endQuiet() })
        return PaletteClosureSource(build: {
            guard panel.core.isLive else { return [] }
            return QuietPaletteRows.items(
                mode: panel.quietMode, quietLabel: panel.quietLabel, quietIsOurs: panel.quietIsOurs,
                now: Date(), verbs: verbs)
        }, typed: { query in
            // "quiet 45m", "dim for 2h" — any length, not just a preset's.
            guard panel.core.isLive else { return [] }
            return QuietPaletteRows.typedItems(query: query, mode: panel.quietMode, now: Date(), verbs: verbs)
        })
    }

    /// Scenes through the Effect Studio's store (which re-reads the
    /// assignments after the write); brightness through the panel's
    /// slider path, only while a strip or Dot is attached — a menu of
    /// steps, or exactly what was typed ("brightness 40"); the Screen
    /// Bar through the delegate's own switch.
    static func lights(panel: PanelStore, effects: EffectStudioStore) -> PaletteClosureSource {
        let verbs = LightsPaletteVerbs(
            setScene: { effects.setActiveScene($0) },
            setBrightness: { panel.setBrightness($0, final: true) },
            setScreenBar: { shown in
                if panel.screenBarShown != shown { panel.toggleScreenBar() }
            })
        let why = WhyLightPaletteVerbs(
            openSession: { id in
                if let row = panel.rows.first(where: { $0.id == id }) {
                    panel.open(row)
                } else {
                    panel.openExplainedSession()
                }
            },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            })
        return PaletteClosureSource(build: {
            guard panel.core.isLive else { return [] }
            // The explainer on the real clock: the panel's own `now`
            // only ticks while the panel is open.
            let explanation = LightExplainer.explain(
                lights: panel.core.lights, state: panel.core.state,
                settings: panel.core.settings.map { SettingsDocument($0.document) }, now: Date())
            return WhyLightPaletteRows.items(explanation: explanation, verbs: why)
                + LightsPaletteRows.items(
                    activeScene: effects.activeScene,
                    brightness: panel.hasHardware ? panel.brightness : nil,
                    screenBarShown: panel.screenBarShown,
                    verbs: verbs)
        }, typed: { query in
            guard panel.core.isLive else { return [] }
            return LightsPaletteRows.typedItems(query: query,
                                                brightness: panel.hasHardware ? panel.brightness : nil,
                                                verbs: verbs)
        })
    }

    /// The notch card's strip. `prepare` asks it to re-read the system
    /// on open; the read-backs land while the palette is up and the rows
    /// re-gather with them.
    static func controlCenter(toggles: @escaping @MainActor () -> SystemTogglesStore?) -> PaletteClosureSource {
        PaletteClosureSource(prepare: { toggles()?.refresh() }) {
            guard let store = toggles() else { return [] }
            return ControlCenterPaletteRows.items(isOn: store.isOn, applying: store.applying) {
                store.apply($0)
            }
        }
    }

    static func usage(panel: PanelStore, windows: Windows) -> PaletteClosureSource {
        PaletteClosureSource {
            guard panel.core.isLive else { return [] }
            return UsagePaletteRows.items(usage: panel.core.state?.usage?.providers ?? [], now: Date()) {
                windows.usageCenter($0)
            }
        }
    }

    /// Feed the Tank: one pellet for every grown fish. Fry are a
    /// sub-agent's school and come and go with it — feeding them would
    /// let a busy hour of workers farm the game's pearls, so the round
    /// is for the residents. The game's daily cap decides what counts.
    static func tank(aquarium: @escaping @MainActor () -> AquariumToy?) -> PaletteClosureSource {
        PaletteClosureSource {
            guard let tank = aquarium() else { return [] }
            let grown = tank.fish.filter { !$0.isFry }
            return AquariumPaletteRows.items(fishCount: grown.count, isOn: tank.isOn, verbs: AquariumPaletteVerbs(
                feed: {
                    let fed = tank.fish.filter { !$0.isFry }
                    for fish in fed { tank.pelletEaten(by: fish.id) }
                    guard !fed.isEmpty else { return nil }
                    return fed.count == 1 ? "Fed the fish" : "Fed \(fed.count) fish"
                },
                setOpen: { tank.isOn = $0 }))
        }
    }

    /// Confetti on demand, through the Toys card's own Test burst and
    /// switch — the same tint, the same Reduce Motion flash.
    static func confettiSource(_ confetti: @escaping @MainActor () -> ConfettiToy?) -> PaletteClosureSource {
        PaletteClosureSource {
            guard let toy = confetti() else { return [] }
            return ConfettiPaletteRows.items(automatic: toy.isOn, verbs: ConfettiPaletteVerbs(
                fire: { toy.testBurst(providerColor: ConfettiView.toysTint) },
                setAutomatic: { toy.isOn = $0 }))
        }
    }

    /// Data Hoarder's full-text search, only while the hoarder is on —
    /// switched off, its archive is not something to search from a
    /// hotkey. Nothing leaves this Mac: the archive is a local SQLite
    /// file and the query never goes further than it.
    static func archive(hoarder: DataHoarderUtility) -> PaletteClosureSource {
        let verbs = ArchivePaletteVerbs(
            openRecord: { record, query in
                hoarder.model.query = query
                hoarder.model.selectedID = record.id
                hoarder.openArchive()
            },
            search: { query in
                hoarder.model.query = query
                hoarder.openArchive()
            },
            sessionFor: { hoarder.model.sessionResolver?($0) },
            openSession: { hoarder.model.sessionOpener?($0) })
        return PaletteClosureSource(build: { [] }, search: { query in
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard hoarder.model.enabled, trimmed.count >= ArchivePaletteRows.minimumQuery else { return [] }
            let hits = (try? await hoarder.model.archive.search(
                query: trimmed, limit: ArchivePaletteRows.limit)) ?? []
            return ArchivePaletteRows.items(query: trimmed, hits: hits, verbs: verbs)
        })
    }

    static func open(hoarder: DataHoarderUtility, windows: Windows) -> PaletteClosureSource {
        PaletteClosureSource(build: { openItems(hoarder: hoarder, windows: windows) })
    }

    /// The windows (the archive's only while the hoarder is on) and the
    /// Settings pages.
    static func openItems(hoarder: DataHoarderUtility, windows: Windows) -> [PaletteItem] {
        var archive: (@MainActor () -> Void)?
        if hoarder.model.enabled {
            archive = { hoarder.openArchive() }
        }
        let verbs = PaletteWindowVerbs(
            overview: windows.overview,
            usageCenter: { windows.usageCenter(nil) },
            history: windows.history,
            effects: windows.effects,
            deck: windows.deck,
            replay: windows.replay,
            archive: archive,
            panel: windows.panel,
            checkForUpdates: windows.checkForUpdates,
            settings: windows.settings)
        let rows = WindowPaletteRows.items(verbs: verbs)
        let pages = WindowPaletteRows.settingsItems(open: windows.settings)
        return rows + pages
    }
}
