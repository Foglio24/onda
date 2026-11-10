import AVFoundation
import CoreMedia

/// Reads what a file or a stream really holds, from its audio track's own description: the codec,
/// sample rate, bit depth (the source's, for FLAC and ALAC) and channels. What the player shows as
/// the format comes from here once the song plays, not from what a source claims.
enum AudioFormatProbe {
    static func probe(_ asset: AVAsset) async -> AudioFormatInfo? {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let description = try? await track.load(.formatDescriptions).first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return nil }
        let rate = try? await track.load(.estimatedDataRate)
        return info(basic, estimatedRate: rate.map(Double.init))
    }

    static func probe(_ url: URL) async -> AudioFormatInfo? {
        await probe(AVURLAsset(url: url))
    }

    /// The format a stream description stands for.
    static func info(_ basic: AudioStreamBasicDescription, estimatedRate: Double?) -> AudioFormatInfo {
        let codec: AudioFormatInfo.Codec
        var bitDepth: Int?
        switch basic.mFormatID {
        case kAudioFormatFLAC:
            codec = .flac
            bitDepth = sourceBits(basic.mFormatFlags)
        case kAudioFormatAppleLossless:
            codec = .alac
            bitDepth = sourceBits(basic.mFormatFlags)
        case kAudioFormatLinearPCM:
            codec = .wav
            bitDepth = basic.mBitsPerChannel > 0 ? Int(basic.mBitsPerChannel) : nil
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD:
            codec = .aac
        case kAudioFormatOpus:
            codec = .opus
        case kAudioFormatMPEGLayer3:
            codec = .mp3
        case kAudioFormatAC3, kAudioFormatEnhancedAC3:
            codec = .dolby
        default:
            codec = .other
        }
        let bitrate = codec.isLossless ? nil : estimatedRate.flatMap { $0 > 0 ? Int($0) : nil }
        return AudioFormatInfo(codec: codec, sampleRate: basic.mSampleRate > 0 ? basic.mSampleRate : nil,
                               bitDepth: bitDepth, channels: basic.mChannelsPerFrame > 0 ? Int(basic.mChannelsPerFrame) : nil,
                               bitrate: bitrate)
    }

    /// FLAC and ALAC state the bit depth of the audio they were made from in their flags (the same
    /// values for both: 1 = 16, 2 = 20, 3 = 24, 4 = 32 bits).
    private static func sourceBits(_ flags: AudioFormatFlags) -> Int? {
        switch flags {
        case 1: return 16
        case 2: return 20
        case 3: return 24
        case 4: return 32
        default: return nil
        }
    }
}

/// Where the sound goes out now: the route's name and the rate the device runs at. Shown beside the
/// source's format, as the two can differ (a 96 kHz file through a 48 kHz output is resampled), and
/// AutoMix, the equalizer and the other effects process the samples: never claimed as bit-perfect.
enum AudioOutputInfo {
    static var current: String {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs.first?.portName
        let rate = AudioFormatInfo.kilohertz(session.sampleRate)
        return [route, rate].compactMap { $0 }.joined(separator: " · ")
    }
}
