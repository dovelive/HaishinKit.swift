//
//  AudioFileAudioIOComponent+Extension.swift
//  HaishinKit iOS
//
//  Created by miracle on 2021/07/10.
//  Copyright © 2021 Shogo Endo. All rights reserved.
//

import Foundation
import AVFoundation

public protocol AudioFileOutputBufferDelegate: AnyObject {
    func outputAudioFrame(sampleBuffer: CMSampleBuffer)
}

public protocol AudioFileCaptureSession: Running {
//    var attributes: [NSString: NSObject] { get }
    var delegate: AudioFileOutputBufferDelegate? { get set }
}

// MARK: -
open class AudioFileSession: NSObject, AudioFileCaptureSession {
    private var displayLink: CADisplayLink!

    public internal(set) var isRunning: Atomic<Bool> = .init(false)
    private let lockQueue = DispatchQueue(
        label: "com.haishinkit.HaishinKit.AudioFileSession.lock", qos: .userInteractive, attributes: []
    )
    
    private let semaphore = DispatchSemaphore(value: 1)
    
    public weak var delegate: AudioFileOutputBufferDelegate?
    
    public var frameInterval: Int = 6
    public var timeInterval: Double = 0.1
    
    var audioFile: AVAudioFile?
    var audioFileBuffer: AVAudioPCMBuffer?
    var cmSampleBuffer: CMSampleBuffer?
    var audioDuration: Double = 0
    var currentAudioTime: Double = 0
    
#if AVBUFFEROUTPUT_TEST
    var avEngine = AVAudioEngine()
    var avAudioPlayerNode = AVAudioPlayerNode()
    var avPitch = AVAudioUnitTimePitch()
    var avSpeed = AVAudioUnitVarispeed()
#endif
    
    public init(fileURL: URL) {
        super.init()
        
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
            audioFileBuffer = AVAudioPCMBuffer(pcmFormat: audioFile!.processingFormat, frameCapacity: UInt32(audioFile!.length))
            try audioFile!.read(into: audioFileBuffer!)
            
            cmSampleBuffer = createCMSampleBufferFromAudioBuffer(pcmBuffer: audioFileBuffer!, withPresentationTime: CMTime.zero)
            
            let item = AVPlayerItem(url: fileURL)
            self.audioDuration = Double(item.asset.duration.value) / Double(item.asset.duration.timescale)

#if AVBUFFEROUTPUT_TEST
            do {
                avEngine.attach(avAudioPlayerNode)
                avEngine.attach(avPitch)
                avEngine.attach(avSpeed)
                
                avEngine.connect(avAudioPlayerNode, to: avSpeed, format: audioFileBuffer?.format)
                avEngine.connect(avSpeed, to: avPitch, format: audioFileBuffer?.format)
                avEngine.connect(avPitch, to: avEngine.mainMixerNode, format: audioFileBuffer?.format)
                avEngine.prepare()
                try avEngine.start()
                
//                avAudioPlayerNode.scheduleBuffer(audioFileBuffer!, at: nil, completionHandler: nil)
//                avAudioPlayerNode.play()
            } catch {
                print("avEngine not started")
            }
#endif
        } catch {
            logger.warn(error)
        }
    }
    
    @objc
    public func onAudioFrameCapture(_ displayLink: CADisplayLink) {
        guard semaphore.wait(timeout: .now()) == .success else {
            return
        }

        lockQueue.async {
            autoreleasepool {
                self.onAudioFrameCaptureProcess(displayLink)
            }
            self.semaphore.signal()
        }
    }
    
    func createCMSampleBuffer(withPresentationTime: CMTime, sampleRate: Double = 44100, numSamples: Int = 1024) -> CMSampleBuffer? {
        var status: OSStatus = noErr
        var sampleBuffer: CMSampleBuffer?
        var formatDescription: CMAudioFormatDescription? = nil

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: 0xc,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var timing: CMSampleTimingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: CMTime.zero,
            decodeTimeStamp: CMTime.invalid
        )

        status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription
        )

        guard status == noErr else {
            return nil
        }

        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: numSamples,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr else {
            return nil
        }

        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription!)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples))!
        buffer.frameLength = buffer.frameCapacity
        let channels = Int(format.channelCount)
        for ch in (0..<channels) {
            let samples = buffer.int16ChannelData![ch]
            for n in 0..<Int(buffer.frameLength) {
                samples[n] = Int16(sinf(Float(2.0 * .pi) * 440.0 * Float(n) / Float(sampleRate)) * 16383.0)
            }
        }

        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer!,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        )

        guard status == noErr else {
            return nil
        }

        return sampleBuffer
    }

    func createAudioSampleBufferFromCMBuffer(cmBuffer: CMSampleBuffer, startTimeOffset: Double, timeInterval: Double) -> AVAudioPCMBuffer? {
        var status: OSStatus = noErr

        let format = AVAudioFormat(cmAudioFormatDescription: cmBuffer.formatDescription!)

        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * timeInterval))
        pcmBuffer?.frameLength = pcmBuffer!.frameCapacity
        
        status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            cmBuffer,
            at: Int32(format.sampleRate * startTimeOffset),
            frameCount: Int32(format.sampleRate * timeInterval),
            into: pcmBuffer!.mutableAudioBufferList)

        guard status == noErr else {
            print("CMSampleBufferCopyPCMDataIntoAudioBufferList returned status: %d", status, NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil))
            return nil
        }

        return pcmBuffer
    }

    func createCMSampleBufferFromAudioBuffer(pcmBuffer: AVAudioPCMBuffer, withPresentationTime: CMTime) -> CMSampleBuffer? {
        var status: OSStatus = noErr
        var sampleBuffer: CMSampleBuffer?
        var formatDescription: CMAudioFormatDescription? = nil

        let asbd: UnsafePointer<AudioStreamBasicDescription>  = pcmBuffer.format.streamDescription
        var timing: CMSampleTimingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(asbd.pointee.mSampleRate)),
            presentationTimeStamp: withPresentationTime,
            decodeTimeStamp: CMTime.invalid
        )

        status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription
        )

        guard status == noErr else {
            return nil
        }
        
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(pcmBuffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr else {
            print("CMSampleBufferCreate returned status: %d", status);
            return nil
        }

        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer!,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcmBuffer.mutableAudioBufferList
        )

        guard status == noErr else {
            print("CMSampleBufferSetDataBufferFromAudioBufferList returned status: %d", status);
            return nil
        }

        return sampleBuffer
    }

    open func onAudioFrameCaptureProcess(_ displayLink: CADisplayLink) {
        guard let audioFileBuffer: AVAudioPCMBuffer = self.audioFileBuffer else {
            return
        }
        
//        delegate?.outputAudioFrame(sampleBuffer: createCMSampleBuffer(withPresentationTime: CMTimeMakeWithSeconds(displayLink.timestamp, preferredTimescale: Int32(22050)), sampleRate: 22050, numSamples: 2205)!)
        
        let timeScale = audioFileBuffer.format.streamDescription.pointee.mSampleRate
        
        guard let audioBufferTmp: AVAudioPCMBuffer = createAudioSampleBufferFromCMBuffer(cmBuffer: cmSampleBuffer!, startTimeOffset: self.currentAudioTime, timeInterval: self.timeInterval) else {
            return
        }
        
#if AVBUFFEROUTPUT_TEST
        avAudioPlayerNode.scheduleBuffer(audioBufferTmp, completionHandler: nil)
        avAudioPlayerNode.play()
#endif

        guard let cmSampleBuffer2: CMSampleBuffer = createCMSampleBufferFromAudioBuffer(pcmBuffer: audioBufferTmp, withPresentationTime: CMTimeMakeWithSeconds(displayLink.timestamp, preferredTimescale: Int32(timeScale))) else {
            return
        }
        delegate?.outputAudioFrame(sampleBuffer: cmSampleBuffer2)
        
        // Loop
        self.currentAudioTime += self.timeInterval
        if (self.currentAudioTime + self.timeInterval - self.audioDuration > 0.001) {
            self.currentAudioTime = 0
        }
    }
}

extension AudioFileSession: Running {
    // MARK: Running
    public func startRunning() {
        lockQueue.sync {
            guard !self.isRunning.value else {
                return
            }
            self.isRunning.mutate { $0 = true }
            self.displayLink = CADisplayLink(target: self, selector: #selector(onAudioFrameCapture))
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
