import AVFoundation

protocol MP4SamplerDelegate: AnyObject {
    func didOpen(_ reader: MP4Reader)
    func didSet(config: Data, withID: Int, type: AVMediaType)
    func output(data: Data, withID: Int, currentTime: Double, keyframe: Bool)
}

// MARK: -
public class MP4Sampler {
    public typealias Handler = () -> Void

    weak var delegate: MP4SamplerDelegate?

    private var fileOrg: URL? = nil
    private var file: URL? = nil
    private var handler: Handler? = nil
    private let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.MP4Sampler.lock")
    private let loopQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.MP4Sampler.loop")
    private let operations = OperationQueue()
    public private(set) var isRunning: Atomic<Bool> = .init(false)

    func appendFile(_ file: URL, completionHandler: Handler? = nil) {
        lockQueue.async {
            self.handler = completionHandler
            self.fileOrg = file
        }
    }

    private func execute(url: URL) {
        let reader = MP4Reader(url: url)

        do {
            _ = try reader.load()
        } catch {
            logger.warn("")
            return
        }

        delegate?.didOpen(reader)
        let traks: [MP4Box] = reader.getBoxes(byName: "trak")
        for i in 0..<traks.count {
            var callBackFunc: Handler? = nil
            if i == 0 {
                callBackFunc = rewindMP4File
            }
            let trakReader = MP4TrakReader(id: i, trak: traks[i], callbackFunc: callBackFunc)
            trakReader.delegate = delegate
            operations.addOperation {
                trakReader.execute(reader)
            }
        }
        operations.waitUntilAllOperationsAreFinished()

        reader.close()
    }
    
    public func rewindMP4File() {
        lockQueue.async {
            self.file = self.fileOrg
        }
    }

    private func run() {
        if (file == nil) {
            return
        }
        execute(url: file!)
        file = nil
        handler?()
    }
}

extension MP4Sampler: Running {
    // MARK: Running
    public func startRunning() {
        lockQueue.async {
            self.file = self.fileOrg
        }
        loopQueue.async {
            self.isRunning.mutate { $0 = true }
            while self.isRunning.value {
                self.lockQueue.sync {
                    self.run()
                    if self.file == nil {
                        sleep(1)
                    }
                }
            }
        }
    }

    public func stopRunning() {
        lockQueue.async {
            self.isRunning.mutate { $0 = false }
        }
    }
}
