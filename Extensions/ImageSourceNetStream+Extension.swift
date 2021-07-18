#if os(iOS)

import AVFoundation
import Foundation

extension NetStream {
    open func attachVideoSource(_ imageSession: ImageSourceCaptureSession?, useImageSize: Bool = true) {
        lockQueue.async {
            self.mixer.videoIO.attachVideoSource(imageSession, useImageSize: useImageSize)
        }
    }
}

#endif
