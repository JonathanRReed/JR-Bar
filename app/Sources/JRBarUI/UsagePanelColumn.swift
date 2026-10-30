import JRBarCore

/// Panel columns follow the account's reported windows, including retained readings.
public enum UsagePanelColumn: String, CaseIterable, Sendable {
    case short, cycle

    public func windows(in provider: CoreProviderUsage) -> [CoreUsageWindow] {
        let fiveHour = provider.windows.filter { $0.placement == .fiveHour }
        let daily = provider.windows.filter { UsageWindowLabel.windowSpan(id: $0.key, name: $0.name) == 86400 }
        if self == .short { return fiveHour.isEmpty ? daily : fiveHour }
        let weekly = provider.windows.filter { $0.placement == .weekly }
        if !weekly.isEmpty { return weekly }
        let monthly = provider.windows.filter { UsageWindowLabel.windowSpan(id: $0.key, name: $0.name) == 30 * 86400 }
        if !monthly.isEmpty { return monthly }
        return provider.windows.filter { window in
            window.placement != .fiveHour && UsageWindowLabel.windowSpan(id: window.key, name: window.name) != 86400
        }
    }
}

extension CoreProviderUsage {
    /// Use the existing headline rule within each cadence, without changing other surfaces.
    public func panelWindow(in column: UsagePanelColumn) -> CoreUsageWindow? {
        var candidate = self
        candidate.windows = column.windows(in: self)
        return candidate.headlineWindow
    }

    /// A single reported headline uses the entire meter area.
    public var panelColumns: [UsagePanelColumn] {
        UsagePanelColumn.allCases.filter { panelWindow(in: $0) != nil }
    }
}
