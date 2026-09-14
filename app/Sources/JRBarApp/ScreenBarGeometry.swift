import JRBarUI

/// The geometry helpers moved to JRBarUI so their pure halves are
/// unit-tested (`ScreenBarGeometryTests`); the aliases keep every call
/// site — including Toys, which imports only JRBarCore — unqualified.
typealias ScreenBarDesign = JRBarUI.ScreenBarDesign
typealias ScreenBarGeometry = JRBarUI.ScreenBarGeometry
typealias ScreenBarWingGeometry = JRBarUI.ScreenBarWingGeometry
typealias ScreenBarWingSide = JRBarUI.ScreenBarWingSide
typealias NotchProfile = JRBarUI.NotchProfile
