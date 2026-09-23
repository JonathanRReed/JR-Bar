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
                        hoarder: DataHoarderUtility,
                        windows: Windows) -> [any PaletteSource] {
        [
            agents(panel: panel),
            quiet(panel: panel),
            lights(panel: panel, effects: effects),
            controlCenter(toggles: toggles),
            usage(panel: panel, windows: windows),
            tank(aquarium: aquarium),
            archive(hoarder: hoarder),
            open(hoarder: hoarder, windows: windows),
        ]
    }

    /// Asks and sessions, through the panel's own verbs — `approve` and
    /// `deny` re-check `canAnswer`, remote rows and a pending answer,
    /// and pin the request, exactly as the panel's buttons do.
    static func agents(panel: PanelStore) -> PaletteClosureSource {
        PaletteClosureSource {
            AgentPaletteRows.items(rows: panel.rows, now: Date(), verbs: AgentPaletteVerbs(
                open: { panel.open($0) },
                approve: { panel.approve($0) },
                deny: { panel.deny($0) },
                snooze: { panel.snooze($0, seconds: $1) },
                copyPath: { panel.copyPath($0) },
                reveal: { panel.reveal($0) },
                dismiss: { panel.dismiss($0) },
                clear: { panel.clear($0) }))
        }
    }

    /// The panel's quiet presets; picking a mode remembers it, as the
    /// footer's Mode menu does. Nothing to offer before the daemon is
    /// live — `quiet` would go nowhere.
    static func quiet(panel: PanelStore) -> PaletteClosureSource {
        PaletteClosureSource {
            guard panel.core.isLive else { return [] }
            return QuietPaletteRows.items(
                mode: panel.quietMode, quietLabel: panel.quietLabel, quietIsOurs: panel.quietIsOurs,
                now: Date(),
                verbs: QuietPaletteVerbs(
                    quiet: { mode, seconds in
                        panel.quietMode = mode
                        panel.quietFor(seconds: seconds)
                    },
                    end: { panel.endQuiet() }))
        }
    }

    /// Scenes through the Effect Studio's store (which re-reads the
    /// assignments after the write); brightness through the panel's
    /// slider path, only while a strip or Dot is attached; the Screen
    /// Bar through the delegate's own switch.
    static func lights(panel: PanelStore, effects: EffectStudioStore) -> PaletteClosureSource {
        PaletteClosureSource {
            guard panel.core.isLive else { return [] }
            return LightsPaletteRows.items(
                activeScene: effects.activeScene,
                brightness: panel.hasHardware ? panel.brightness : nil,
                screenBarShown: panel.screenBarShown,
                verbs: LightsPaletteVerbs(
                    setScene: { effects.setActiveScene($0) },
                    setBrightness: { panel.setBrightness($0, final: true) },
                    setScreenBar: { shown in
                        if panel.screenBarShown != shown { panel.toggleScreenBar() }
                    }))
        }
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
