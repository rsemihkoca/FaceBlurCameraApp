import Foundation
import AVFoundation
import VideoToolbox
import Network
import os.log

class RTSPStreamer {
    private let port: UInt16 = 8554
    private let username = "admin"
    private let password = "admin"
    private var isStreaming = false
    private var serverSocket: Int32 = -1
    
    private var videoEncoder: VTCompressionSession?
    private let videoQueue = DispatchQueue(label: "com.faceblurcamera.rtsp.video", qos: .userInitiated)
    private var clients: [Int32: RTSPClient] = [:]
    private var networkMonitor: NWPathMonitor?
    
    // Logger for better debugging
    private let logger = Logger(subsystem: "com.faceblurcamera", category: "RTSPStreamer")
    
    // RTP settings
    private let rtpPayloadType: UInt8 = 96 // H.264
    private var rtpSequenceNumber: UInt16 = 0
    private var rtpTimestamp: UInt32 = 0
    private let rtpSsrc: UInt32 = UInt32.random(in: 0..<UInt32.max)
    
    // Stream quality settings with iOS 15 compatible bitrates
    private var targetBitrate: Int32 = 2_000_000 // 2 Mbps
    private var adaptiveBitrateEnabled = true
    private let minBitrate: Int32 = 500_000 // 500 Kbps
    private let maxBitrate: Int32 = 4_000_000 // 4 Mbps
    
    // Error handling
    enum RTSPError: Error {
        case socketCreationFailed
        case socketBindFailed
        case socketListenFailed
        case encoderCreationFailed
        case encoderConfigurationFailed
    }
    
    init() {
        setupVideoEncoder()
        setupNetworkMonitoring()
    }
    
    private func setupNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            self?.handleNetworkPathUpdate(path)
        }
        networkMonitor?.start(queue: videoQueue)
    }
    
    private func handleNetworkPathUpdate(_ path: NWPath) {
        guard adaptiveBitrateEnabled else { return }
        
        switch path.status {
        case .satisfied:
            if path.isConstrained {
                adjustBitrate(factor: 0.7) // Reduce bitrate by 30%
            } else {
                adjustBitrate(factor: 1.3) // Increase bitrate by 30%
            }
        case .unsatisfied:
            adjustBitrate(factor: 0.5) // Reduce bitrate by 50%
        default:
            break
        }
    }
    
    private func adjustBitrate(factor: Double) {
        let newBitrate = Int32(Double(targetBitrate) * factor)
        targetBitrate = min(maxBitrate, max(minBitrate, newBitrate))
        
        guard let session = videoEncoder else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                           value: NSNumber(value: targetBitrate))
    }
    
    private func setupVideoEncoder() {
        let width = 2048
        let height = 1080
        var encoderSession: VTCompressionSession?
        
        let encoderSpecification: [String: Any] = [
            kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_H264_Baseline_AutoLevel // More compatible with iOS 15
        ]
        
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressedFrameHandler,
            refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            compressionSessionOut: &encoderSession)
        
        guard status == noErr, let session = encoderSession else {
            logger.error("Failed to create video encoder: \(status)")
            return
        }
        
        videoEncoder = session
        
        // Configure encoder settings for iOS 15 compatibility
        let encoderConfig: [(CFString, Any)] = [
            (kVTCompressionPropertyKey_RealTime, true as CFBoolean),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: targetBitrate)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 30)),
            (kVTCompressionPropertyKey_AllowFrameReordering, false as CFBoolean),
            (kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CAVLC), // More compatible than CABAC
            (kVTCompressionPropertyKey_MaxH264SliceBytes, NSNumber(value: 1500)) // Better network packet handling
        ]
        
        for (key, value) in encoderConfig {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        
        VTCompressionSessionPrepareToEncodeFrames(session)
    }
    
    private let compressedFrameHandler: VTCompressionOutputCallback = { outputCallbackRefCon, sourceFrameRefCon, status, flags, sampleBuffer in
        guard let context = outputCallbackRefCon else { return }
        let streamer = Unmanaged<RTSPStreamer>.fromOpaque(context).takeUnretainedValue()
        streamer.handleEncodedFrame(status: status, flags: flags, sampleBuffer: sampleBuffer)
    }
    
    private func handleEncodedFrame(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr,
              let sampleBuffer = sampleBuffer,
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }
        
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(dataBuffer,
                                               atOffset: 0,
                                               lengthAtOffsetOut: nil,
                                               totalLengthOut: &length,
                                               dataPointerOut: &dataPointer)
        
        guard status == kCMBlockBufferNoErr,
              let dataPointer = dataPointer else {
            return
        }
        
        let data = Data(bytes: dataPointer, count: length)
        sendRTPPackets(videoData: data)
    }
    
    private func sendRTPPackets(videoData: Data) {
        let maxPayloadSize = 1400 // Standard RTP payload size
        var offset = 0
        
        while offset < videoData.count {
            let remainingBytes = videoData.count - offset
            let payloadSize = min(maxPayloadSize, remainingBytes)
            let isLastPacket = (offset + payloadSize) >= videoData.count
            
            let rtpHeader = createRTPHeader(isLastPacket: isLastPacket)
            let payload = videoData.subdata(in: offset..<(offset + payloadSize))
            
            let packet = rtpHeader + payload
            broadcastToClients(packet)
            
            rtpSequenceNumber &+= 1
            offset += payloadSize
        }
        
        rtpTimestamp &+= 90000 / 30 // 90kHz clock rate, 30fps
    }
    
    private func createRTPHeader(isLastPacket: Bool) -> Data {
        var header = Data(count: 12) // Standard RTP header size
        
        // Version(2), Padding(0), Extension(0), CSRC Count(0)
        header[0] = 0x80
        
        // Marker(isLastPacket), Payload Type
        header[1] = rtpPayloadType | (isLastPacket ? 0x80 : 0x00)
        
        // Sequence Number
        header[2] = UInt8(rtpSequenceNumber >> 8)
        header[3] = UInt8(rtpSequenceNumber & 0xFF)
        
        // Timestamp
        header[4] = UInt8(rtpTimestamp >> 24)
        header[5] = UInt8((rtpTimestamp >> 16) & 0xFF)
        header[6] = UInt8((rtpTimestamp >> 8) & 0xFF)
        header[7] = UInt8(rtpTimestamp & 0xFF)
        
        // SSRC
        header[8] = UInt8(rtpSsrc >> 24)
        header[9] = UInt8((rtpSsrc >> 16) & 0xFF)
        header[10] = UInt8((rtpSsrc >> 8) & 0xFF)
        header[11] = UInt8(rtpSsrc & 0xFF)
        
        return header
    }
    
    func startStreaming() throws {
        guard !isStreaming else { return }
        
        // Initialize server socket with error handling
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create server socket: \(errno)")
            throw RTSPError.socketCreationFailed
        }
        
        // Enable socket reuse with error handling
        var reuse: Int32 = 1
        let sockoptResult = setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        guard sockoptResult >= 0 else {
            logger.error("Failed to set SO_REUSEADDR: \(errno)")
            close(serverSocket)
            throw RTSPError.socketCreationFailed
        }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        guard bindResult == 0 else {
            print("Failed to bind server socket: \(errno)")
            close(serverSocket)
            return
        }
        
        guard listen(serverSocket, 5) == 0 else {
            print("Failed to listen on server socket: \(errno)")
            close(serverSocket)
            return
        }
        
        isStreaming = true
        print("RTSP server started on port \(port)")
        
        // Start accepting connections in background
        DispatchQueue.global(qos: .userInitiated).async {
            self.acceptConnections()
        }
    }
    
    private func acceptConnections() {
        while isStreaming {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let clientSocket = accept(serverSocket, &addr, &len)
            
            if clientSocket >= 0 {
                DispatchQueue.global(qos: .userInitiated).async {
                    self.handleClient(socket: clientSocket)
                }
            } else if errno != EAGAIN {
                print("Accept failed: \(errno)")
            }
        }
    }
    
    private func handleClient(socket: Int32) {
        let client = RTSPClient(socket: socket, username: username, password: password)
        clients[socket] = client
        
        var buffer = [UInt8](repeating: 0, count: 4096)
        
        while isStreaming {
            let bytesRead = recv(socket, &buffer, buffer.count, 0)
            if bytesRead <= 0 {
                if bytesRead < 0 {
                    print("Read error: \(errno)")
                }
                break
            }
            
            let data = Data(bytes: buffer, count: bytesRead)
            if let request = String(data: data, encoding: .utf8) {
                handleRTSPRequest(request, client: client)
            }
        }
        
        clients.removeValue(forKey: socket)
        close(socket)
    }
    
    private func handleRTSPRequest(_ request: String, client: RTSPClient) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        
        let components = requestLine.components(separatedBy: " ")
        guard components.count >= 2 else { return }
        
        let method = components[0]
        let url = components[1]
        
        switch method {
        case "OPTIONS":
            respondToOptions(client: client)
        case "DESCRIBE":
            respondToDescribe(url: url, client: client)
        case "SETUP":
            respondToSetup(client: client)
        case "PLAY":
            respondToPlay(client: client)
        case "PAUSE":
            respondToPause(client: client)
        case "TEARDOWN":
            respondToTeardown(client: client)
        default:
            respondWithError(client: client, code: 405, message: "Method Not Allowed")
        }
    }
    
    private func respondToOptions(client: RTSPClient) {
        let response = """
        RTSP/1.0 200 OK\r
        CSeq: \(client.cseq)\r
        Public: OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN\r
        \r
        """
        client.send(response)
    }
    
    private func respondToDescribe(url: String, client: RTSPClient) {
        let sdp = """
        v=0
        o=- \(Date().timeIntervalSince1970) 1 IN IP4 0.0.0.0
        s=FaceBlurCamera Stream
        c=IN IP4 0.0.0.0
        t=0 0
        m=video \(port) RTP/AVP \(rtpPayloadType)
        a=rtpmap:\(rtpPayloadType) H264/90000
        a=fmtp:\(rtpPayloadType) profile-level-id=42e01f;packetization-mode=1
        """
        
        let response = """
        RTSP/1.0 200 OK\r
        CSeq: \(client.cseq)\r
        Content-Type: application/sdp\r
        Content-Length: \(sdp.count)\r
        \r
        \(sdp)
        """
        client.send(response)
    }
    
    private func respondToSetup(client: RTSPClient) {
        let response = """
        RTSP/1.0 200 OK\r
        CSeq: \(client.cseq)\r
        Session: \(client.sessionId)\r
        Transport: RTP/AVP;unicast;client_port=\(client.clientRTPPort)-\(client.clientRTCPPort);server_port=\(port)-\(port+1)\r
        \r
        """
        client.send(response)
    }
    
    private func respondToPlay(client: RTSPClient) {
        client.isPlaying = true
        let response = """
        RTSP/1.0 200 OK\r
        CSeq: \(client.cseq)\r
        Session: \(client.sessionId)\r
        Range: npt=0.000-\r
        \r
        """
        client.send(response)
    }
    
    private func respondToPause(client: RTSPClient) {
        client.isPlaying = false
        let response = """
        RTSP/1.0 200 OK\r
        CSeq: \(client.cseq)\r
        Session: \(client.sessionId)\r
        \r
        """
        client.send(response)
    }
    
    private func respondToTeardown(client: RTSPClient) {
        client.isPlaying = false
        let response = """
        RTSP/1.0 200 OK\r
        CSeq: \(client.cseq)\r
        Session: \(client.sessionId)\r
        \r
        """
        client.send(response)
        
        clients.removeValue(forKey: client.socket)
        close(client.socket)
    }
    
    private func respondWithError(client: RTSPClient, code: Int, message: String) {
        let response = """
        RTSP/1.0 \(code) \(message)\r
        CSeq: \(client.cseq)\r
        \r
        """
        client.send(response)
    }
    
    private func broadcastToClients(_ packet: Data) {
        for client in clients.values where client.isPlaying {
            client.send(packet)
        }
    }
    
    func processVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isStreaming,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        guard let encoder = videoEncoder else { return }
        
        VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: imageBuffer,
            presentationTimeStamp: timestamp,
            duration: CMTime.invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }
    
    func stopStreaming() {
        guard isStreaming else { return }
        
        isStreaming = false
        
        // Close all client connections
        for client in clients.values {
            close(client.socket)
        }
        clients.removeAll()
        
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        
        // Clean up video encoder
        if let session = videoEncoder {
            VTCompressionSessionInvalidate(session)
            videoEncoder = nil
        }
        
        // Stop network monitoring
        networkMonitor?.cancel()
        
        print("RTSP server stopped")
    }
}

class RTSPClient {
    let socket: Int32
    let username: String
    let password: String
    let sessionId: String
    var cseq: Int = 0
    var isPlaying = false
    var clientRTPPort: UInt16 = 0
    var clientRTCPPort: UInt16 = 0
    
    init(socket: Int32, username: String, password: String) {
        self.socket = socket
        self.username = username
        self.password = password
        self.sessionId = UUID().uuidString
    }
    
    func send(_ data: String) {
        _ = data.withCString { ptr in
            Darwin.send(socket, ptr, strlen(ptr), 0)
        }
    }
    
    func send(_ data: Data) {
        data.withUnsafeBytes { ptr in
            _ = Darwin.send(socket, ptr.baseAddress, data.count, 0)
        }
    }
} 