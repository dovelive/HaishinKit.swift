import AVFoundation

protocol MP4SamplerDelegate: AnyObject {
    func didSet(config: Data, withID: Int, type: AVMediaType)
    func output(data: Data, withID: Int, currentTime: Double, keyframe: Bool)
}

// MARK: -
final class MP4TrakReader {
    static let defaultBufferTime: Double = 500

    var file: MP4FileReader
    var bufferTime: Double = MP4TrakReader.defaultBufferTime
    weak var delegate: MP4SamplerDelegate?

    private var id: Int = 0
    private var handle: FileHandle?
    private lazy var timerDriver: TimerDriver = {
        var timerDriver = TimerDriver()
        timerDriver.delegate = self
        return timerDriver
    }()
    private var currentOffset: UInt64 {
        UInt64(offset[cursor])
    }
    private var currentIsKeyframe: Bool {
        keyframe[cursor] != nil
    }
    private var currentDuration: Double {
        Double(totalTimeToSample) * 1000 / Double(timeScale)
    }
    private var currentTimeToSample: Double {
        Double(timeToSample[cursor]) * 1000 / Double(timeScale)
    }
    private var currentSampleSize: Int {
        Int((sampleSize.count == 1) ? sampleSize[0] : sampleSize[cursor])
    }
    private var cursor: Int = 0
    private var offset: [UInt32] = []
    private var keyframe: [Int: Bool] = [:]
    private var timeScale: UInt32 = 0
    private var sampleSize: [UInt32] = []
    private var timeToSample: [UInt32] = []
    private var totalTimeToSample: UInt32 = 0

    init(id: Int, file: MP4FileReader) {
        self.id = id
        self.file = file

        let mdhd = file.getBoxes(by: .mdhd).first
        timeScale = mdhd!.timeScale

        let stss = file.getBoxes(by: .stss).first
        let keyframes: [UInt32] = stss!.entries
        for i in 0..<keyframes.count {
            keyframe[Int(keyframes[i]) - 1] = true
        }

        let stts = file.getBoxes(by: .stts).first
        let timeToSample = stts!.entries
        for i in 0..<timeToSample.count {
            let entry = timeToSample[i]
            for _ in 0..<entry.sampleCount {
                self.timeToSample.append(entry.sampleDelta)
            }
        }

        let stsz = file.getBoxes(by: .stsz).first
        if let stsz: MP4SampleSizeBox = stsz {
            sampleSize = stsz.entries
        }

        let stco = file.getBoxes(by: .stco).first!
        let stsc = file.getBoxes(by: .stsc).first!
        let offsets: [UInt32] = stco.entries
        let sampleToChunk: [MP4SampleToChunkBox.Entry] = stsc.entries

        var index: Int = 0
        let count: Int = sampleToChunk.count
        for i in 0..<count {
            let m: Int = (i + 1 < count) ? Int(sampleToChunk[i + 1].firstChunk) - 1 : offsets.count
            for j in (Int(sampleToChunk[i].firstChunk) - 1)..<m {
                var offset: UInt32 = offsets[j]
                for _ in 0..<sampleToChunk[i].samplesPerChunk {
                    self.offset.append(offset)
                    offset += sampleSize[index]
                    index += 1
                }
            }
        }
        totalTimeToSample = self.timeToSample[cursor]
    }

    func execute(url: URL) {
        do {
            handle = try FileHandle(forReadingFrom: url)

            if let avcC = file.getBoxes(by: .avcC).first {
                delegate?.didSet(config: avcC.data, withID: id, type: .video)
            }
            if let esds = file.getBoxes(by: .esds).first {
                delegate?.didSet(config: esds.data, withID: id, type: .audio)
            }

            timerDriver.interval = MachUtil.nanosToAbs(UInt64(currentTimeToSample * 1000 * 1000))
            print(timerDriver.interval, currentDuration, bufferTime)
            while currentDuration <= bufferTime {
                tick(timerDriver)
            }
            timerDriver.startRunning()
        } catch {
            logger.warn("file open error : \(url)")
        }
    }

    private func hasNext() -> Bool {
        cursor + 1 < offset.count
    }

    private func next() {
        defer {
            cursor += 1
        }
        totalTimeToSample += timeToSample[cursor]
    }
}

extension MP4TrakReader: TimerDriverDelegate {
    // MARK: TimerDriverDelegate
    func tick(_ driver: TimerDriver) {
        guard let handle: FileHandle = handle else {
            driver.stopRunning()
            return
        }
        driver.interval = MachUtil.nanosToAbs(UInt64(currentTimeToSample * 1000 * 1000))
        handle.seek(toFileOffset: currentOffset)
        print("currentOffset", id, currentSampleSize, currentOffset)
        autoreleasepool {
            delegate?.output(
                data: handle.readData(ofLength: currentSampleSize),
                withID: id,
                currentTime: currentTimeToSample,
                keyframe: currentIsKeyframe
            )
        }
        if hasNext() {
            next()
        } else {
            driver.stopRunning()
        }
    }
}

extension MP4TrakReader: CustomDebugStringConvertible {
    // MARK: CustomDebugStringConvertible
    var debugDescription: String {
        Mirror(reflecting: self).debugDescription
    }
}

// MARK: -
public class MP4Sampler {
    public typealias Handler = () -> Void

    weak var delegate: MP4SamplerDelegate?

    private var files: [URL] = []
    private var handlers: [URL: Handler?] = [:]
    private let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.MP4Sampler.lock")
    private let loopQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.MP4Sampler.loop")
    public private(set) var isRunning: Atomic<Bool> = .init(false)

    func appendFile(_ file: URL, completionHandler: Handler? = nil) {
        lockQueue.async {
            self.handlers[file] = completionHandler
            self.files.append(file)
        }
    }

    private func execute(url: URL) {
        do {
            let file = try MP4FileReader(forReadingFrom: url).execute()
            
            let traks = file.getBoxes(by: .trak)
            for i in 0..<traks.count {
                let trakReader = MP4TrakReader(id: i, file: file)
                trakReader.delegate = delegate
                trakReader.execute(url: url)
            }
            var traks2 = 1
        } catch {
            logger.warn("")
            return
        }
    }

    private func run() {
        if files.isEmpty {
            return
        }
        let url: URL = files.first!
        let handler: Handler? = handlers[url]!
        files.remove(at: 0)
        handlers[url] = nil
        execute(url: url)
        handler?()
    }
}

extension MP4Sampler: Running {
    // MARK: Running
    public func startRunning() {
        loopQueue.async {
            self.isRunning.mutate { $0 = true }
            while self.isRunning.value {
                self.lockQueue.sync {
                    self.run()
                    if self.files.isEmpty {
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
