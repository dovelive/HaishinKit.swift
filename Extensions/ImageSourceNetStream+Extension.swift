#if os(iOS)

import AVFoundation
import Foundation

extension NetStream {
    open func attachImage(_ imageSession: ImageSourceCaptureSession?, useImageSize: Bool = true) {
        lockQueue.async {
            self.mixer.videoIO.attachImage(imageSession, useImageSize: useImageSize)
        }
    }
    open func attachPlayer(_ imageSession: ImageSourceCaptureSession?, useImageSize: Bool = true) {
        lockQueue.async {
            self.mixer.videoIO.attachImage(imageSession, useImageSize: useImageSize)
        }
    }
}

#endif
