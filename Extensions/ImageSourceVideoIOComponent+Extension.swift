#if os(iOS)

import AVFoundation
import CoreImage

extension VideoIOComponent {
    func attachVideoSource(_ imageSession: ImageSourceCaptureSession?, useImageSize: Bool = true) {
        guard let imageSession: ImageSourceCaptureSession = imageSession else {
            return
        }
        if self.imageSession != nil {
            self.imageSession?.stopRunning()
            self.imageSession = nil
        }
        input = nil
        output = nil
        if useImageSize {
            encoder.width = imageSession.attributes["Width"] as! Int32
            encoder.height = imageSession.attributes["Height"] as! Int32
        }
        self.imageSession = imageSession
        self.imageSession?.startRunning()
    }
}

extension VideoIOComponent: ImageSourceOutputPixelBufferDelegate {
    // MARK: ImageSourceOutputPixelBufferDelegate
    func didSetSize(size: CGSize) {
        lockQueue.async {
            self.encoder.width = Int32(size.width)
            self.encoder.height = Int32(size.height)
        }
    }

    func outputImage(pixelBuffer: CVPixelBuffer, withPresentationTime: CMTime) {
        if renderer != nil || !effects.isEmpty {
            let image: CIImage = effect(pixelBuffer, info: nil)
            
            if !effects.isEmpty {
                // usually the context comes from HKView or MTLHKView
                // but if you have not attached a view then the context is nil
                if context == nil {
                    logger.info("no ci context, creating one to render effect")
                    context = CIContext()
                }
                context?.render(image, to: pixelBuffer)
            }
            renderer?.render(image: image)
        }
        
        encoder.encodeImageBuffer(
            pixelBuffer,
            presentationTimeStamp: withPresentationTime,
            duration: CMTime.invalid
        )
        mixer?.recorder.appendPixelBuffer(pixelBuffer, withPresentationTime: withPresentationTime)
    }
}

#endif
