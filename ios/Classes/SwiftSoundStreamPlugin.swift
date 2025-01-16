import Flutter
import UIKit
import AVFoundation
import SoundAnalysis

public enum SoundStreamErrors: String {
    case FailedToRecord
    case FailedToPlay
    case FailedToStop
    case FailedToWriteBuffer
    case Unknown
}

public enum SoundStreamStatus: String {
    case Unset
    case Initialized
    case Playing
    case Done
    case Stopped
}

private class ResultsObserver: NSObject, SNResultsObserving {
    public var process: ((CMTimeRange) -> Void)? =  nil

    override init() {
        super.init()
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else  { return }
        guard let classification = result.classifications.first else { return }

        if (classification.confidence > 0.1 && classification.identifier == "speech") {
            self.process?(result.timeRange)
        } else {

        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        print("The analysis failed: \(error.localizedDescription)")
    }

    func requestDidComplete(_ request: SNRequest) {
        print("The request completed successfully!")
    }
}

private class AudioPayload: Hashable {
    // This is the low pass filter to prevent
    // whether this buffer is "loud enough"
    private static let minVolume: Float = 0.02

    public let buffer: AVAudioPCMBuffer
    public let recordedTime: UInt64
    public let timeRange: AVAudioTime
    public let cmTime: CMTime
    public let volume: Float
    public let isEmpty: Bool

    static func == (lhs: AudioPayload, rhs: AudioPayload) -> Bool {
        return lhs.timeRange.sampleTime == rhs.timeRange.sampleTime
    }

    func hash(into hasher: inout Hasher) {
        return hasher.combine(timeRange.sampleTime)
    }

    private static func getVolume(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else {
            return 0
        }

        let channelDataArray = Array(UnsafeBufferPointer(start:channelData, count: Int(buffer.frameLength)))

        var outEnvelope = [Float]()
        var envelopeState:Float = 0
        let envConstantAtk:Float = 0.16
        let envConstantDec:Float = 0.003

        for sample in channelDataArray {
            let rectified = abs(sample)

            if envelopeState < rectified {
                envelopeState += envConstantAtk * (rectified - envelopeState)
            } else {
                envelopeState += envConstantDec * (rectified - envelopeState)
            }
            outEnvelope.append(envelopeState)
        }

        return outEnvelope.max() ?? 0
    }

    init(buffer: AVAudioPCMBuffer, timeRange: AVAudioTime) {
        self.buffer = buffer
        self.timeRange = timeRange
        self.recordedTime = UInt64(Date.now.timeIntervalSince1970 * 1000)
        let seconds: TimeInterval = Double(timeRange.sampleTime) / timeRange.sampleRate
        self.cmTime = CMTimeMakeWithSeconds(seconds, preferredTimescale: Int32(timeRange.sampleRate))
        self.volume = AudioPayload.getVolume(buffer: buffer)
        self.isEmpty = self.volume <= AudioPayload.minVolume
    }
}

private class PayloadsRange: CustomStringConvertible {
    private var _startIndex: Int
    private var _endIndex: Int

    init(startIndex: Int, endIndex: Int) {
        self._startIndex = startIndex
        self._endIndex = endIndex
    }

    public var startIndex: Int {
        get {
            return _startIndex
        }
    }

    public var endIndex: Int {
        get {
            return _endIndex
        }
    }

    public var amount: Int {
        get {
            return _endIndex - _startIndex + 1
        }
    }

    public func setRange(startIndex: Int, endIndex: Int) {
        self._startIndex = startIndex
        self._endIndex = endIndex
    }

    public func setStart(startIndex: Int) {
        self._startIndex = startIndex
    }

    public func setEnd(endIndex: Int) {
        self._endIndex = endIndex
    }

    public func reSet() {
        self._startIndex = 0
        self._endIndex = 0
    }

    var unSet: Bool {
        get {
            return _startIndex == 0 && _endIndex == 0
        }
    }

    var invalid: Bool {
        get {
            return _startIndex >= _endIndex
        }
    }

    public var description: String { return "(\(_startIndex), \(_endIndex))" }
}

@available(iOS 9.0, *)
public class SwiftSoundStreamPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel
    private var registrar: FlutterPluginRegistrar
    private let soundAnalysisRequest: SNClassifySoundRequest?
    private let soundAnalysisQueue = DispatchQueue(label: "mitty.company.AnalysisQueue")
    private var streamAnalyzer: SNAudioStreamAnalyzer?
    private var soundAnalysisObserver: ResultsObserver
    private var hasPermission: Bool = false
    private var debugLogging: Bool = false
    private var soundAnalysisError: Bool = false
    private var payloadList: Array<AudioPayload> = []
    private let lastSpeechFound: PayloadsRange = PayloadsRange(startIndex: 0, endIndex: 0)

    //========= Recorder's vars
    private let mAudioEngine = AVAudioEngine()
    private let mRecordBus = 0
    private var mInputNode: AVAudioInputNode
    private var mRecordSampleRate: Double = 16000 // 16Khz
    private var mRecordBufferSize: AVAudioFrameCount = 8192
    private var mRecordChannel = 0
    private var mRecordSettings: [String:Int]!
    private var mRecordFormat: AVAudioFormat!

    //========= Player's vars
    private let PLAYER_OUTPUT_SAMPLE_RATE: Double = 32000   // 32Khz
    private let mPlayerBus = 0
    private let mPlayerNode = AVAudioPlayerNode()
    private var mPlayerSampleRate: Double = 16000 // 16Khz
    private var mPlayerBufferSize: AVAudioFrameCount = 8192
    private var mPlayerOutputFormat: AVAudioFormat!
    private var mPlayerInputFormat: AVAudioFormat!

    /** ======== Basic Plugin initialization ======== **/

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "vn.casperpas.sound_stream:methods", binaryMessenger: registrar.messenger())
        let instance = SwiftSoundStreamPlugin( channel, registrar: registrar)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    init( _ channel: FlutterMethodChannel, registrar : FlutterPluginRegistrar ) {
        self.channel = channel
        self.registrar = registrar
        self.mInputNode = mAudioEngine.inputNode
        do {
            self.soundAnalysisRequest = try SNClassifySoundRequest(classifierIdentifier: SNClassifierIdentifier.version1)
        } catch {
            self.soundAnalysisRequest = nil
            self.soundAnalysisError = true
        }
        self.soundAnalysisObserver = ResultsObserver()
        super.init()
        self.attachPlayer()
        mAudioEngine.prepare()
    }

    private func startSoundAnalysis() {
        let inputFormat = mInputNode.inputFormat(forBus: mRecordBus)
        if (inputFormat.channelCount == 0 || inputFormat.sampleRate == 0) {
            self.soundAnalysisError = true
            return
        }
        if (self.streamAnalyzer == nil) {
            self.streamAnalyzer = SNAudioStreamAnalyzer(format: inputFormat)
        }
        self.soundAnalysisObserver.process = self.speechFound(_:)
        self.payloadList.removeAll()
        if (self.soundAnalysisRequest != nil && !self.soundAnalysisError) {
            do {
                try self.streamAnalyzer!.add(self.soundAnalysisRequest!, withObserver: self.soundAnalysisObserver)
            } catch {
                self.soundAnalysisError = true
            }
        }
    }

    private func stopSoundAnalysis() {
        self.streamAnalyzer?.completeAnalysis()
        self.streamAnalyzer?.removeAllRequests()
        self.streamAnalyzer = nil
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "hasPermission":
            hasPermission(result)
        case "initializeRecorder":
            initializeRecorder(call, result)
        case "startRecording":
            startRecording(result)
        case "stopRecording":
            stopRecording(result)
        case "initializePlayer":
            initializePlayer(call, result)
        case "startPlayer":
            startPlayer(result)
        case "stopPlayer":
            stopPlayer(result)
        case "writeChunk":
            writeChunk(call, result)
        default:
            print("Unrecognized method: \(call.method)")
            sendResult(result, FlutterMethodNotImplemented)
        }
    }

    private func sendResult(_ result: @escaping FlutterResult, _ arguments: Any?) {
        DispatchQueue.main.async {
            result( arguments )
        }
    }

    private func invokeFlutter( _ method: String, _ arguments: Any? ) {
        DispatchQueue.main.async {
            self.channel.invokeMethod( method, arguments: arguments )
        }
    }

    /** ======== Plugin methods ======== **/

    private func checkAndRequestPermission(completion callback: @escaping ((Bool) -> Void)) {
        if (hasPermission) {
            callback(hasPermission)
            return
        }
        // SoundAnalysis
        var permission: AVAudioSession.RecordPermission
#if swift(>=4.2)
        permission = AVAudioSession.sharedInstance().recordPermission
#else
        permission = AVAudioSession.sharedInstance().recordPermission()
#endif
        switch permission {
        case .granted:
            hasPermission = true
            callback(hasPermission)
            break
        case .denied:
            hasPermission = false
            callback(hasPermission)
            break
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission() { [unowned self] allowed in
                if allowed {
                    self.hasPermission = true
                    print("undetermined true")
                    callback(self.hasPermission)
                } else {
                    self.hasPermission = false
                    print("undetermined false")
                    callback(self.hasPermission)
                }
            }
            break
        default:
            callback(hasPermission)
            break
        }
    }

    private func hasPermission( _ result: @escaping FlutterResult) {
        checkAndRequestPermission { value in
            self.sendResult(result, value)
        }
    }

    private func startEngine() {
        guard !mAudioEngine.isRunning else {
            return
        }

        try? mAudioEngine.start()
    }

    private func stopEngine() {
        mAudioEngine.stop()
        mAudioEngine.reset()
    }

    private func sendEventMethod(_ name: String, _ data: Any) {
        var eventData: [String: Any] = [:]
        eventData["name"] = name
        eventData["data"] = data
        invokeFlutter("platformEvent", eventData)
    }

    private func initializeRecorder(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let argsArr = call.arguments as? Dictionary<String,AnyObject>
        else {
            sendResult(result, FlutterError( code: SoundStreamErrors.Unknown.rawValue,
                                             message:"Incorrect parameters",
                                             details: nil ))
            return
        }
        mRecordSampleRate = argsArr["sampleRate"] as? Double ?? mRecordSampleRate
        debugLogging = argsArr["showLogs"] as? Bool ?? debugLogging
        mRecordFormat = AVAudioFormat(commonFormat: AVAudioCommonFormat.pcmFormatInt16, sampleRate: mRecordSampleRate, channels: 1, interleaved: true)

        checkAndRequestPermission { isGranted in
            if isGranted {
                self.sendRecorderStatus(SoundStreamStatus.Initialized)
                self.sendResult(result, true)
            } else {
                self.sendResult(result, FlutterError( code: SoundStreamErrors.Unknown.rawValue,
                                                      message:"Incorrect parameters",
                                                      details: nil ))
            }
        }
    }

    private func tryTrimPayloadList() {
        if (!lastSpeechFound.unSet || payloadList.count < 100) {
            return
        }
        // trim the empty beginnning of patloadList
        for i in 10...50 {
            if (!payloadList[i].isEmpty) {
                payloadList = Array(payloadList.dropFirst(i))
                NSLog("Trim the frist \(i) paylaods. \(payloadList.count) left.")
                break
            }
        }
    }

    private func trySendLastSpeech() {
        if (lastSpeechFound.unSet) {
            tryTrimPayloadList()
            return
        }
        if (payloadList.count - 30 < lastSpeechFound.endIndex) {
            return
        }
        // send speech data
        sendSpeech(range: lastSpeechFound)
        // chop payloadList
        NSLog("Chopping \(lastSpeechFound) when paylaodList count is: \(payloadList.count)")
        payloadList = Array(payloadList.dropFirst(lastSpeechFound.endIndex))
        NSLog("lastSpeechFound reSet and payloadList count is: \(payloadList.count)")
        lastSpeechFound.reSet()
    }

    private func analyzeAudio(payload: AudioPayload) {
        trySendLastSpeech()
        payloadList.append(payload)
        self.soundAnalysisQueue.async {
            self.streamAnalyzer?.analyze(
                payload.buffer,
                atAudioFramePosition: payload.timeRange.sampleTime
            )
        }
    }

    private func resetEngineForRecord() {
        if (self.streamAnalyzer == nil) {
            self.soundAnalysisError = true
            return
        }
        let inputFormat = mInputNode.inputFormat(forBus: mRecordBus)
        let converter = AVAudioConverter(from: inputFormat, to: mRecordFormat!)!
        let ratio: Float = Float(inputFormat.sampleRate)/Float(mRecordFormat.sampleRate)
        let validFormat: Bool = mRecordFormat?.commonFormat == AVAudioCommonFormat.pcmFormatInt16

        mInputNode.installTap(onBus: mRecordBus, bufferSize: mRecordBufferSize, format: inputFormat) {
            (buffer, time) -> Void in
            let payload = AudioPayload(buffer: buffer, timeRange: time)
            self.analyzeAudio(payload: payload)
            if (!payload.isEmpty && validFormat) {
                // send rawData
                converter.reset()
                let newBuffer = AVAudioPCMBuffer(
                    pcmFormat: self.mRecordFormat!,
                    frameCapacity: UInt32(Float(buffer.frameCapacity) / ratio)
                )!
                var error: NSError?
                let status = converter.convert(
                    to: newBuffer, error: &error
                ) { (numPackets, status) -> AVAudioBuffer? in
                    status.pointee = .haveData
                    return buffer
                }
                assert(status != .error)
                let values = self.audioBufferToBytes(newBuffer)
                self.sendRawData(values, time: payload.recordedTime)
            }
        }
    }

    private func startRecording(_ result: @escaping FlutterResult) {
        mAudioEngine.reset()
        mInputNode.removeTap(onBus: mRecordBus)
        let inputFormat = mInputNode.inputFormat(forBus: mRecordBus)
        if (inputFormat.channelCount == 0) {
            NSLog("Input Node's channel count is 0")
            result(false)
            return
        }
        if (inputFormat.sampleRate == 0) {
            NSLog("Input Node's sample rate is 0")
            result(false)
            return
        }
        startSoundAnalysis()
        resetEngineForRecord()
        startEngine()
        sendRecorderStatus(SoundStreamStatus.Playing)
        result(true)
    }

    private func stopRecording(_ result: @escaping FlutterResult) {
        stopSoundAnalysis()
        stopEngine()
        mAudioEngine.inputNode.removeTap(onBus: mRecordBus)
        sendRecorderStatus(SoundStreamStatus.Stopped)
        result(true)
    }

    private func trimEmpty(range: PayloadsRange) -> PayloadsRange {
        var start: Int = range.startIndex
        var end: Int = range.endIndex

        // trim the empty part at the beginning
        for i in range.startIndex...range.endIndex {
            let payload = payloadList[i]
            if (payload.isEmpty) {
                start = i == range.endIndex ? i : i + 1
            } else {
                break
            }
        }
        // trim the empty part at the end
        for i in (start...range.endIndex).reversed() {
            let payload = payloadList[i]
            if (payload.isEmpty) {
                end = i == start ? i : i - 1
            } else {
                break
            }
        }
        let newRange = PayloadsRange(startIndex: start, endIndex: end)
        NSLog("trimEmpty() -> from \(range) to \(newRange)")
        return newRange
    }

    private func trySplitRange(range: PayloadsRange) -> Array<PayloadsRange> {
        let rangeTrim = trimEmpty(range: range)
        if (rangeTrim.invalid) {
            return []
        }
        if (rangeTrim.amount <= 3) {
            return [rangeTrim]
        }
        // 2 empty in a row: this is a gap
        var emptyStackAmount = 0
        var preStartIndex = rangeTrim.startIndex
        var nonEmptyPayloads: Array<PayloadsRange> =  []
        for i in rangeTrim.startIndex...rangeTrim.endIndex {
            let isEmpty = payloadList[i].isEmpty
            if (isEmpty) {
                emptyStackAmount += 1
            } else {
                if (emptyStackAmount >= 4) {
                    nonEmptyPayloads.append(
                        PayloadsRange(
                            startIndex: preStartIndex, endIndex: i - 1
                        )
                    )
                    preStartIndex = i
                    emptyStackAmount = 0
                } else {
                    // Reset stack amount
                    emptyStackAmount = 0
                }
            }
            if (i == rangeTrim.endIndex) {
                if (i - preStartIndex < 2) {
                    // Extend the last range to include this
                    if (nonEmptyPayloads.isEmpty) {
                        nonEmptyPayloads.append(
                            PayloadsRange(
                                startIndex: preStartIndex, endIndex: i
                            )
                        )
                    } else {
                        nonEmptyPayloads.last!.setEnd(endIndex: i)
                    }
                } else {
                    // Add a new range
                    nonEmptyPayloads.append(
                        PayloadsRange(
                            startIndex: preStartIndex, endIndex: i
                        )
                    )
                }
            }
        }
        return nonEmptyPayloads
    }

    private func sendSpeech(range: PayloadsRange) {
        if (self.mRecordFormat?.commonFormat != AVAudioCommonFormat.pcmFormatInt16) {
            NSLog("Fail on sending speech data due to unsupported format: \(String(describing: self.mRecordFormat))")
            return
        }
        let inputFormat = mInputNode.inputFormat(forBus: mRecordBus)
        let converter = AVAudioConverter(from: inputFormat, to: mRecordFormat!)!
        let ratio: Float = Float(inputFormat.sampleRate)/Float(mRecordFormat.sampleRate)
        let newRange = trimEmpty(range: range)

        if (newRange.invalid) {
            NSLog("sendSpeech but newRange is invalid: \(newRange)")
            return
        }

        let ranges = trySplitRange(range: newRange)
        for r in ranges {
            if (r.invalid) {
                NSLog("sendSpeech found one splitted range invalid \(r)")
                return
            }
            var allArray: Array<[UInt8]> = []
            for i in r.startIndex...r.endIndex {
                let payload = payloadList[i]
                // Data
                converter.reset()
                let newBuffer = AVAudioPCMBuffer(
                    pcmFormat: self.mRecordFormat!,
                    frameCapacity: UInt32(Float(payload.buffer.frameCapacity) / ratio)
                )!
                var error: NSError?
                let status = converter.convert(
                    to: newBuffer, error: &error
                ) { (numPackets, status) -> AVAudioBuffer? in
                    status.pointee = .haveData
                    return payload.buffer
                }
                assert(status != .error)
                allArray.append(self.audioBufferToBytes(newBuffer))
            }
            NSLog("Sending data \(r)")
            self.sendMicData(
                allArray.reduce([], +),
                time: payloadList[r.startIndex].recordedTime
            )
        }
    }

    private func secondsFromPayloads(range: PayloadsRange) -> Double {
        if (range.invalid) {
            NSLog("Try to get seconds from invalid range: \(range)")
            return 0
        }
        var gapSeconds: Double = 0
        for i in range.startIndex...range.endIndex {
            let payload = payloadList[i]
            gapSeconds += payload.cmTime.seconds
        }
        return gapSeconds
    }

    private func shouldSendSpeech(range: PayloadsRange) -> Bool {
        if (lastSpeechFound.unSet) {
            NSLog("lastSPeechFound init: \(range)")
            lastSpeechFound.setRange(startIndex: range.startIndex, endIndex: range.endIndex)
            return false
        }
        // Check whether the gap between lastSpeech and this range is big enough
        let rangeTrim = trimEmpty(range: range)
        let lastSpeechTrim = trimEmpty(range: lastSpeechFound)
        let preEnd = lastSpeechTrim.endIndex
        let newStart = rangeTrim.startIndex
        if (newStart > preEnd && (newStart - preEnd) > 2) {
            // There must be at least 2 empty payload as gap
            NSLog("should send lastSpeechFound: \(lastSpeechFound)")
            return true
        } else {
            NSLog("Setting end: \(range) for lastSpeechFound")
            lastSpeechFound.setEnd(endIndex: range.endIndex)
            return false
        }
    }

    private func speechFound(_ timeRange: CMTimeRange) {
        let range = PayloadsRange(startIndex: 0, endIndex: 0)
        for (idx, payload) in payloadList.enumerated() {
            if (timeRange.containsTime(payload.cmTime)) {
                if (range.startIndex == 0) {
                    range.setStart(startIndex: idx)
                    continue
                }
                range.setEnd(endIndex: idx)
            } else {
                if (!range.unSet) {
                    break;
                }
            }
        }
        if (range.unSet) {
            NSLog("Speech found but fail to locate payload range: \(timeRange)")
            return;
        }
        NSLog("speechFound: \(range)")
        let shouldSend = shouldSendSpeech(range: range)
        if (shouldSend == false) {
            return;
        }
        NSLog("Sending \(lastSpeechFound)")
        // send speech data
        sendSpeech(range: lastSpeechFound)
        // chop payloadList
        NSLog("Chopping \(range.startIndex)")
        payloadList = Array(payloadList.dropFirst(range.startIndex))
        NSLog("Remaining amount: \(payloadList.count)")
        lastSpeechFound.setRange(
            startIndex: 0,
            endIndex: range.endIndex - range.startIndex
        )
    }

    private func sendMicData(_ data: [UInt8], time: UInt64) {
        let channelData = FlutterStandardTypedData(bytes: NSData(bytes: data, length: data.count) as Data)
        sendEventMethod("dataPeriod", channelData)
        sendEventMethod("dataTime", time)
    }

    private func sendRawData(_ data: [UInt8], time: UInt64) {
        let channelData = FlutterStandardTypedData(bytes: NSData(bytes: data, length: data.count) as Data)
        sendEventMethod("rawPeriod", channelData)
        sendEventMethod("rawDataTime", time)
    }

    private func sendRecorderStatus(_ status: SoundStreamStatus) {
        sendEventMethod("recorderStatus", status.rawValue)
    }

    private func initializePlayer(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let argsArr = call.arguments as? Dictionary<String,AnyObject>
        else {
            sendResult(result, FlutterError( code: SoundStreamErrors.Unknown.rawValue,
                                             message:"Incorrect parameters",
                                             details: nil ))
            return
        }
        mPlayerSampleRate = argsArr["sampleRate"] as? Double ?? mPlayerSampleRate
        debugLogging = argsArr["showLogs"] as? Bool ?? debugLogging
        mPlayerInputFormat = AVAudioFormat(commonFormat: AVAudioCommonFormat.pcmFormatInt16, sampleRate: mPlayerSampleRate, channels: 1, interleaved: true)
        sendPlayerStatus(SoundStreamStatus.Initialized)
    }

    private func attachPlayer() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false)
        try! session.setCategory(
            .playAndRecord,
            options: [
                .defaultToSpeaker,
                .defaultToSpeaker,
                .allowBluetooth,
                .allowBluetoothA2DP,
                .allowAirPlay
            ])
        try! session.setActive(true)
        mPlayerOutputFormat = AVAudioFormat(commonFormat: AVAudioCommonFormat.pcmFormatFloat32, sampleRate: PLAYER_OUTPUT_SAMPLE_RATE, channels: 1, interleaved: true)

        mAudioEngine.attach(mPlayerNode)
        mAudioEngine.connect(mPlayerNode, to: mAudioEngine.outputNode, format: mPlayerOutputFormat)
    }

    private func startPlayer(_ result: @escaping FlutterResult) {
        startEngine()
        if !mPlayerNode.isPlaying {
            mPlayerNode.play()
        }
        sendPlayerStatus(SoundStreamStatus.Playing)
        result(true)
    }

    private func stopPlayer(_ result: @escaping FlutterResult) {
        if mPlayerNode.isPlaying {
            mPlayerNode.stop()
        }
        sendPlayerStatus(SoundStreamStatus.Stopped)
        result(true)
    }

    private func sendPlayerStatus(_ status: SoundStreamStatus) {
        sendEventMethod("playerStatus", status.rawValue)
    }

    private func writeChunk(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let argsArr = call.arguments as? Dictionary<String,AnyObject>,
              let data = argsArr["data"] as? FlutterStandardTypedData
        else {
            sendResult(result, FlutterError( code: SoundStreamErrors.FailedToWriteBuffer.rawValue,
                                             message:"Failed to write Player buffer",
                                             details: nil ))
            return
        }
        let byteData = [UInt8](data.data)
        pushPlayerChunk(byteData, result)
    }

    private func pushPlayerChunk(_ chunk: [UInt8], _ result: @escaping FlutterResult) {
        let buffer = bytesToAudioBuffer(chunk)
        mPlayerNode.scheduleBuffer(convertBufferFormat(
            buffer,
            from: mPlayerInputFormat,
            to: mPlayerOutputFormat
        ), completionCallbackType: .dataPlayedBack) {_ in
            self.sendPlayerStatus(SoundStreamStatus.Done)
        }
        result(true)
    }

    private func convertBufferFormat(_ buffer: AVAudioPCMBuffer, from: AVAudioFormat, to: AVAudioFormat) -> AVAudioPCMBuffer {

        let formatConverter =  AVAudioConverter(from: from, to: to)
        let ratio: Float = Float(from.sampleRate)/Float(to.sampleRate)
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: UInt32(Float(buffer.frameCapacity) / ratio))!

        var error: NSError? = nil
        let inputBlock: AVAudioConverterInputBlock = {inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        formatConverter?.convert(to: pcmBuffer, error: &error, withInputFrom: inputBlock)

        return pcmBuffer
    }

    private func audioBufferToBytes(_ audioBuffer: AVAudioPCMBuffer) -> [UInt8] {
        let srcLeft = audioBuffer.int16ChannelData![0]
        let bytesPerFrame = audioBuffer.format.streamDescription.pointee.mBytesPerFrame
        let numBytes = Int(bytesPerFrame * audioBuffer.frameLength)

        // initialize bytes by 0
        var audioByteArray = [UInt8](repeating: 0, count: numBytes)

        srcLeft.withMemoryRebound(to: UInt8.self, capacity: numBytes) { srcByteData in
            audioByteArray.withUnsafeMutableBufferPointer {
                $0.baseAddress!.initialize(from: srcByteData, count: numBytes)
            }
        }

        return audioByteArray
    }

    private func bytesToAudioBuffer(_ buf: [UInt8]) -> AVAudioPCMBuffer {
        let frameLength = UInt32(buf.count) / mPlayerInputFormat.streamDescription.pointee.mBytesPerFrame

        let audioBuffer = AVAudioPCMBuffer(pcmFormat: mPlayerInputFormat, frameCapacity: frameLength)!
        audioBuffer.frameLength = frameLength

        let dstLeft = audioBuffer.int16ChannelData![0]

        buf.withUnsafeBufferPointer {
            let src = UnsafeRawPointer($0.baseAddress!).bindMemory(to: Int16.self, capacity: Int(frameLength))
            dstLeft.initialize(from: src, count: Int(frameLength))
        }

        return audioBuffer
    }

}
