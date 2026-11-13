import AVFoundation

/// Builds the two-track item played by AutoMix: the rendered transition followed by the next song.
/// Shared with the playback check so it exercises the same composition and volume ramps.
enum AutoMixPlayback {
    static let handoverFade = 0.25

    struct Parts {
        let composition: AVMutableComposition
        let mixPart: AVMutableAudioMixInputParameters
        let songPart: AVMutableAudioMixInputParameters
    }

    /// `timescale`: the times' grid (a rendered Segue's sample rate, so its length and join fall on
    /// whole frames). `songLead`: seconds the song's own part plays, silent, before the seam, so its
    /// decoder and its audio processing (the equalizer's filters) are already running on the same
    /// music when it comes in: started at the seam itself, their first milliseconds were heard there.
    static func compose(mixURL: URL, songURL: URL, length: Double, join: Double,
                        incomingGain: Float, crossing: Double, fade: Double,
                        timescale: CMTimeScale = 44_100, songLead: Double = 0) async -> Parts? {
        let overlapSeconds = 0.03
        guard length.isFinite, join.isFinite, crossing.isFinite, fade.isFinite,
              length > overlapSeconds, join >= overlapSeconds, crossing >= 0, fade > 0,
              crossing + fade <= length - overlapSeconds else { return nil }
        let mixAsset = AVURLAsset(url: mixURL), songAsset = AVURLAsset(url: songURL)
        guard let mixTrack = try? await mixAsset.loadTracks(withMediaType: .audio).first,
              let songTrack = try? await songAsset.loadTracks(withMediaType: .audio).first,
              let songDuration = try? await songAsset.load(.duration) else { return nil }
        let composition = AVMutableComposition()
        guard let first = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let second = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        let scale: CMTimeScale = timescale > 0 ? timescale : 44_100
        let overlap = CMTime(seconds: overlapSeconds, preferredTimescale: scale)
        let duration = CMTime(seconds: length, preferredTimescale: scale)
        let joinTime = CMTime(seconds: join, preferredTimescale: scale)
        guard CMTimeCompare(songDuration, joinTime) > 0 else { return nil }
        // The song's part from `songLead` before the seam (as much as there is of it before `join`).
        let leadSeconds = max(0, min(songLead, join - overlapSeconds, length - overlapSeconds - crossing - fade))
        let lead = CMTime(seconds: leadSeconds, preferredTimescale: scale)
        let songStart = CMTimeSubtract(CMTimeSubtract(duration, overlap), lead)
        do {
            try first.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: mixTrack, at: .zero)
            try second.insertTimeRange(CMTimeRange(start: CMTimeSubtract(CMTimeSubtract(joinTime, overlap), lead), end: songDuration),
                                       of: songTrack, at: songStart)
        } catch { return nil }
        let seam = CMTimeRange(start: CMTimeSubtract(duration, overlap), duration: overlap)
        let mixPart = AVMutableAudioMixInputParameters(track: first)
        if crossing > 0 { mixPart.setVolume(0, at: .zero) }
        mixPart.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                              timeRange: CMTimeRange(start: CMTime(seconds: crossing, preferredTimescale: scale),
                                                     duration: CMTime(seconds: fade, preferredTimescale: scale)))
        mixPart.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: seam)
        let songPart = AVMutableAudioMixInputParameters(track: second)
        if leadSeconds > 0 { songPart.setVolume(0, at: songStart) }
        songPart.setVolumeRamp(fromStartVolume: 0, toEndVolume: incomingGain, timeRange: seam)
        return Parts(composition: composition, mixPart: mixPart, songPart: songPart)
    }
}
