import Foundation

/// How AutoMix mixes (Settings › Riproduzione › AutoMix › Stile): as it judges best, or one family
/// of transitions only. When none of that family fits a pair, a plain fade is the fallback (and,
/// failing that too, the songs simply follow each other).
enum AutoMixStyle: String, CaseIterable, Identifiable {
    /// Beat-matched when the tempos allow it, then filtered, cut, faded: the best that fits.
    case automatic
    /// Overlapping on the beat (beat-matched or filtered), never a cut.
    case blend
    /// A cut on the downbeat.
    case cut
    /// An equal-power fade.
    case fade

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: return String(localized: "Automatico")
        case .blend: return String(localized: "Blend")
        case .cut: return String(localized: "Taglio")
        case .fade: return String(localized: "Dissolvenza")
        }
    }

    /// The planner's families allowed (nil: all of them, in their order).
    var families: Set<SegueFamily>? {
        switch self {
        case .automatic: return nil
        case .blend: return [.locked, .filtered, .fade]
        case .cut: return [.hard, .fade]
        case .fade: return [.fade]
        }
    }
}

/// How far AutoMix may bend the next song's tempo to lock the beats (it keeps its pitch).
enum AutoMixTempoBend: String, CaseIterable, Identifiable {
    case gentle, normal, wide

    var id: Self { self }

    var title: String {
        switch self {
        case .gentle: return String(localized: "Delicata")
        case .normal: return String(localized: "Normale")
        case .wide: return String(localized: "Ampia")
        }
    }

    /// The largest speed change of the next song (4, 8 or 12 %).
    var maxRateChange: Double {
        switch self {
        case .gentle: return 0.04
        case .normal: return 0.08
        case .wide: return 0.12
        }
    }
}

/// What "Avanti" does with transitions on: cut to the next song at once, mix into it quickly, or
/// mix into it from the playing song's next downbeat over a bar.
enum SkipMix: String, CaseIterable, Identifiable {
    case cut, quick, onBeat

    var id: Self { self }

    var title: String {
        switch self {
        case .cut: return String(localized: "Taglio")
        case .quick: return String(localized: "Mix veloce")
        case .onBeat: return String(localized: "Mix a tempo")
        }
    }
}
