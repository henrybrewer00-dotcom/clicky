//
//  CursorStyle.swift
//  leanring-buddy
//
//  The blue triangle that follows the cursor is now one of several selectable
//  "cursor styles," each with its own glyph, and an independent color theme.
//  This file holds the pure data model (styles, themes, persistence) plus the
//  SwiftUI glyph view that OverlayWindow renders. Keeping the model pure makes
//  it straightforward to unit test selection and persistence behavior.
//

import SwiftUI

// MARK: - Cursor Style

/// The visual form of the companion cursor. Selected by the user and persisted
/// to UserDefaults. The `.classic` triangle preserves the original Clicky look.
enum ClickyCursorStyle: String, CaseIterable, Identifiable {
    /// The original blue triangle — points like a real cursor and rotates to
    /// face its direction of travel during flight.
    case classic
    /// A glowing orb that leaves a fading particle trail while it flies.
    case comet
    /// A sleek paper-plane that banks toward its direction of travel.
    case rocket
    /// A twinkling cluster of sparkles. Symmetric, so it never rotates.
    case sparkle

    var id: String { rawValue }

    /// Human-readable name shown in the cursor picker.
    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .comet: return "Comet"
        case .rocket: return "Rocket"
        case .sparkle: return "Sparkle"
        }
    }

    /// SF Symbol used to preview the style in the picker. The `.classic` style
    /// renders a custom Triangle shape rather than a symbol, but we still need
    /// an icon for its picker chip.
    var pickerSymbolName: String {
        switch self {
        case .classic: return "cursorarrow"
        case .comet: return "circle.fill"
        case .rocket: return "paperplane.fill"
        case .sparkle: return "sparkles"
        }
    }

    /// Whether this style should leave a fading particle trail during flight.
    var hasParticleTrail: Bool {
        self == .comet
    }

    /// The default style used when nothing has been persisted yet. Keeping this
    /// `.classic` means existing users see no change unless they opt in.
    static let defaultStyle: ClickyCursorStyle = .classic

    /// Resolves a persisted raw value back into a style, falling back to the
    /// default when the value is missing or unrecognized.
    static func from(rawValue: String?) -> ClickyCursorStyle {
        guard let rawValue, let style = ClickyCursorStyle(rawValue: rawValue) else {
            return defaultStyle
        }
        return style
    }
}

// MARK: - Cursor Theme

/// The color theme applied to the cursor glyph, its glow, the waveform, the
/// spinner, and the speech bubbles — so the whole companion feels cohesive.
enum ClickyCursorTheme: String, CaseIterable, Identifiable {
    case blue
    case violet
    case emerald
    case sunset
    case rose
    case mono

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blue: return "Blue"
        case .violet: return "Violet"
        case .emerald: return "Emerald"
        case .sunset: return "Sunset"
        case .rose: return "Rose"
        case .mono: return "Mono"
        }
    }

    /// The main fill color of the cursor glyph and accents.
    /// `.blue` intentionally matches the original `overlayCursorBlue` (#3380FF)
    /// so the default look is unchanged.
    var primaryColorHex: String {
        switch self {
        case .blue: return "#3380FF"
        case .violet: return "#9B5DE5"
        case .emerald: return "#2BD9A8"
        case .sunset: return "#FF8C42"
        case .rose: return "#FF5D8F"
        case .mono: return "#E8ECEF"
        }
    }

    /// The glow/shadow color. Usually a slightly lighter, softer companion to
    /// the primary color so the bloom reads as light rather than a hard edge.
    var glowColorHex: String {
        switch self {
        case .blue: return "#5B9BFF"
        case .violet: return "#B98AF0"
        case .emerald: return "#5FE8C2"
        case .sunset: return "#FFB066"
        case .rose: return "#FF89AE"
        case .mono: return "#FFFFFF"
        }
    }

    var primaryColor: Color { Color(hex: primaryColorHex) }
    var glowColor: Color { Color(hex: glowColorHex) }

    static let defaultTheme: ClickyCursorTheme = .blue

    static func from(rawValue: String?) -> ClickyCursorTheme {
        guard let rawValue, let theme = ClickyCursorTheme(rawValue: rawValue) else {
            return defaultTheme
        }
        return theme
    }
}

// MARK: - Cursor Glyph View

/// Renders the selected cursor style's glyph at a fixed 16pt size. Rotation,
/// scale, glow, opacity, and positioning are all applied by the caller
/// (BlueCursorView) so the flight animation and cross-fade behavior stay in one
/// place and work identically across every style.
struct CursorGlyphView: View {
    let style: ClickyCursorStyle
    let primaryColor: Color

    /// The shared triangle-coordinate rotation BlueCursorView computes during
    /// flight (0° = glyph points straight up; increases clockwise). Each style
    /// decides how much of this to honor.
    let travelRotationDegrees: Double

    /// True while the buddy is flying to or pointing at a target. Used so glyphs
    /// that only face their direction of travel during flight (the rocket) can
    /// fall back to a pleasant resting pose while simply following the cursor.
    let isNavigating: Bool

    var body: some View {
        switch style {
        case .classic:
            Triangle()
                .fill(primaryColor)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(travelRotationDegrees))

        case .comet:
            // A bright core with a soft halo. Symmetric, so rotation is ignored —
            // the fading trail (rendered separately by BlueCursorView) conveys motion.
            ZStack {
                Circle()
                    .fill(primaryColor.opacity(0.35))
                    .frame(width: 16, height: 16)
                Circle()
                    .fill(primaryColor)
                    .frame(width: 9, height: 9)
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3.5, height: 3.5)
                    .offset(x: -1, y: -1)
            }

        case .rocket:
            // The paper-plane points up-and-to-the-right at 0°, so we subtract 45°
            // to align its nose with the shared "points straight up" convention.
            // While merely following the cursor it rests pointing gently upward.
            Image(systemName: "paperplane.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(primaryColor)
                .rotationEffect(.degrees(isNavigating ? travelRotationDegrees - 45 : -45))

        case .sparkle:
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(primaryColor)
        }
    }
}
