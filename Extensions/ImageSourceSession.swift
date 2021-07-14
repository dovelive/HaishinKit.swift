#if os(iOS)

import AVFoundation
import CoreImage

#if os(iOS)
import UIKit
#endif

public protocol ImageSourceOutputPixelBufferDelegate: AnyObject {
    func didSetSize(size: CGSize)
    func outputImage(pixelBuffer: CVPixelBuffer, withPresentationTime: CMTime)
}

public protocol ImageSourceCaptureSession: Running {
    var attributes: [NSString: NSObject] { get }
    var delegate: ImageSourceOutputPixelBufferDelegate? { get set }
}

// MARK: -
open class ImageSourceSession: NSObject, ImageSourceCaptureSession {
    static let defaultFrameInterval: Int = 2
    static let defaultAttributes: [NSString: NSObject] = [
        kCVPixelBufferPixelFormatTypeKey: NSNumber(value: kCVPixelFormatType_32BGRA),
        kCVPixelBufferCGBitmapContextCompatibilityKey: true as NSObject
    ]

    public var enabledScale = false
    public var frameInterval: Int = ImageSourceSession.defaultFrameInterval
    public var attributes: [NSString: NSObject] {
        var attributes: [NSString: NSObject] = ImageSourceSession.defaultAttributes
        attributes[kCVPixelBufferWidthKey] = NSNumber(value: Float(size.width * scale))
        attributes[kCVPixelBufferHeightKey] = NSNumber(value: Float(size.height * scale))
        attributes[kCVPixelBufferBytesPerRowAlignmentKey] = NSNumber(value: Float(size.width * scale * 4))
        return attributes
    }
    public weak var delegate: ImageSourceOutputPixelBufferDelegate?
    public internal(set) var isRunning: Atomic<Bool> = .init(false)
    
    private var imageToCapture: UIImage?
    private var avPlayerItem: AVPlayerItem?
    private var avPlayerItemOutput: AVPlayerItemVideoOutput?
    public var afterImageUpdates = false
    private var context = CIContext(options: [.useSoftwareRenderer: NSNumber(value: false)])
    private let semaphore = DispatchSemaphore(value: 1)
    private let lockQueue = DispatchQueue(
        label: "com.haishinkit.HaishinKit.ImageSourceSession.lock", qos: .userInteractive, attributes: []
    )
    private var displayLink: CADisplayLink!

    private var size: CGSize = .zero {
        didSet {
            guard size != oldValue else {
                return
            }
            delegate?.didSetSize(size: CGSize(width: size.width * scale, height: size.height * scale))
            pixelBufferPool = nil
        }
    }
    private var scale: CGFloat {
        1.0
    }

    private var _pixelBufferPool: CVPixelBufferPool?
    private var pixelBufferPool: CVPixelBufferPool! {
        get {
            if _pixelBufferPool == nil {
                var pixelBufferPool: CVPixelBufferPool?
                CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary?, &pixelBufferPool)
                _pixelBufferPool = pixelBufferPool
            }
            return _pixelBufferPool!
        }
        set {
            _pixelBufferPool = newValue
        }
    }

    public init(imageToCapture: UIImage) {
        self.imageToCapture = imageToCapture
        size = imageToCapture.size
        afterImageUpdates = true
        super.init()
    }
    
    public init(avPlayerItem: AVPlayerItem?, avPlayerItemOutput: AVPlayerItemVideoOutput?, size: CGSize) {
        self.avPlayerItem = avPlayerItem
        self.avPlayerItemOutput = avPlayerItemOutput
        self.size = size
        afterImageUpdates = true
        super.init()
    }

    @objc
    public func onImageCapture(_ displayLink: CADisplayLink) {
        guard semaphore.wait(timeout: .now()) == .success else {
            return
        }

        if let imageToCapture = self.imageToCapture {
            size = imageToCapture.size
        }

        lockQueue.async {
            autoreleasepool {
                self.onImageCaptureProcess(displayLink)
            }
            self.semaphore.signal()
        }
    }

    open func onImageCaptureProcess(_ displayLink: CADisplayLink) {
        var pixelBuffer: CVPixelBuffer?

        CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer!, [])

        if (self.avPlayerItem != nil) {
            let buffer = avPlayerItemOutput!.copyPixelBuffer(forItemTime: (avPlayerItem?.currentTime())!, itemTimeForDisplay: nil)
            if (buffer != nil) {
                context.render(CIImage(cvPixelBuffer: buffer!), to: pixelBuffer!)
            }
        } else if self.imageToCapture != nil {
            context.render(CIImage(cgImage: (imageToCapture?.cgImage!)!), to: pixelBuffer!)
        }
        
        delegate?.outputImage(pixelBuffer: pixelBuffer!, withPresentationTime: CMTimeMakeWithSeconds(displayLink.timestamp, preferredTimescale: 1000))
        CVPixelBufferUnlockBaseAddress(pixelBuffer!, [])
    }
}

extension ImageSourceSession: Running {
    // MARK: Running
    public func startRunning() {
        lockQueue.sync {
            guard !self.isRunning.value else {
                return
            }
            self.isRunning.mutate { $0 = true }
            self.pixelBufferPool = nil
            self.displayLink = CADisplayLink(target: self, selector: #selector(onImageCapture))
            self.displayLink.frameInterval = self.frameInterval
            self.displayLink.add(to: .main, forMode: RunLoop.Mode.common)
        }
    }

    public func stopRunning() {
        lockQueue.sync {
            guard self.isRunning.value else {
                return
            }
            self.displayLink.remove(from: .main, forMode: RunLoop.Mode.common)
            self.displayLink.invalidate()
            self.displayLink = nil
            self.isRunning.mutate { $0 = false }
        }
    }
}

#endif
