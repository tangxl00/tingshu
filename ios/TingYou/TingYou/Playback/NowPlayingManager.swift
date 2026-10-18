import Foundation
import MediaPlayer

final class NowPlayingManager {
    static let shared = NowPlayingManager()
    private init() {}

    func update(title: String, artist: String, coverURL: String?, duration: Double, position: Double, rate: Float) {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = artist
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
