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
        guard !isStreaming else {
            logger.info("RTSP server is already running")
            return
        }
        
        logger.info("Starting RTSP server on port \(self.port)")
        
        // Initialize server socket with error handling
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            let error = errno
            logger.error("Failed to create server socket: \(error)")
            throw RTSPError.socketCreationFailed
        }
        
        // Enable socket reuse with error handling
        var reuse: Int32 = 1
        let sockoptResult = setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        guard sockoptResult >= 0 else {
            let error = errno
            logger.error("Failed to set SO_REUSEADDR: \(error)")
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
            let error = errno
            logger.error("Failed to bind server socket: \(error)")
            close(serverSocket)
            throw RTSPError.socketBindFailed
        }
        
        guard listen(serverSocket, 5) == 0 else {
            let error = errno
            logger.error("Failed to listen on server socket: \(error)")
            close(serverSocket)
            throw RTSPError.socketListenFailed
        }
        
        isStreaming = true
        logger.info("RTSP server started successfully on port \(self.port)")
        
        // Start accepting connections in background
        DispatchQueue.global(qos: .userInitiated).async {
            self.acceptConnections()
        }
    }
    
    private func acceptConnections() {
        logger.info("Starting to accept RTSP connections")
        while isStreaming {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let clientSocket = accept(serverSocket, &addr, &len)
            
            if clientSocket >= 0 {
                logger.info("Accepted new RTSP connection: \(clientSocket)")
                DispatchQueue.global(qos: .userInitiated).async {
                    self.handleClient(socket: clientSocket)
                }
            } else if errno != EAGAIN {
                logger.error("Accept failed: \(errno)")
            }
        }
        logger.info("Stopped accepting RTSP connections")
    }
    
    private func handleClient(socket: Int32) {
        let client = RTSPClient(socket: socket, username: username, password: password)
        clients[socket] = client
        logger.info("New client connected: \(socket)")
        
        var buffer = [UInt8](repeating: 0, count: 4096)
        
        while isStreaming {
            let bytesRead = recv(socket, &buffer, buffer.count, 0)
            if bytesRead <= 0 {
                if bytesRead < 0 {
                    logger.error("Read error on socket \(socket): \(errno)")
                } else {
                    logger.info("Client disconnected: \(socket)")
                }
                break
            }
            
            let data = Data(bytes: buffer, count: bytesRead)
            if let request = String(data: data, encoding: .utf8) {
                logger.debug("Received RTSP request from \(socket): \(request)")
                handleRTSPRequest(request, client: client)
            } else {
                logger.error("Failed to decode RTSP request from \(socket)")
            }
        }
        
        clients.removeValue(forKey: socket)
        close(socket)
        logger.info("Client connection closed: \(socket)")
    }
    
    private func handleRTSPRequest(_ request: String, client: RTSPClient) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        
        let components = requestLine.components(separatedBy: " ")
        guard components.count >= 2 else { return }
        
        let method = components[0]
        let url = components[1]
        
        // Update CSeq from request headers
        for line in lines {
            if line.starts(with: "CSeq:") {
                if let cseqStr = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
                   let cseq = Int(cseqStr) {
                    client.cseq = cseq
                }
            } else if line.starts(with: "Transport:") {
                if let transportStr = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) {
                    parseTransportHeader(transportStr, for: client)
                }
            }
        }
        
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
    
    private func parseTransportHeader(_ transport: String, for client: RTSPClient) {
        let components = transport.components(separatedBy: ";")
        for component in components {
            if component.contains("client_port=") {
                let ports = component.split(separator: "=")[1].split(separator: "-")
                if ports.count == 2,
                   let rtpPort = UInt16(ports[0]),
                   let rtcpPort = UInt16(ports[1]) {
                    client.clientRTPPort = rtpPort
                    client.clientRTCPPort = rtcpPort
                    logger.info("Client ports set - RTP: \(rtpPort), RTCP: \(rtcpPort)")
                }
            }
        }
    }
    
    private func respondToOptions(client: RTSPClient) {
        let response = """
        RTSP/1.0 200 OK\r
        CSeq: \(client.cseq)\r
        Public: OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN\r
        \r
        """
        if !client.send(response) {
            logger.error("Failed to send OPTIONS response to client \(client.socket)")
            clients.removeValue(forKey: client.socket)
            close(client.socket)
        }
    }
    
    private func respondToDescribe(url: String, client: RTSPClient) {
        let sdp = """
        v=0
        o=- \(Date().timeIntervalSince1970) 1 IN IP4 0.0.0.0
        s=FaceBlurCamera Stream
        c=IN IP4 0.0.0.0
        t=0 0
        m=video \(self.port) RTP/AVP \(rtpPayloadType)
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
        if !client.send(response) {
            logger.error("Failed to send DESCRIBE response to client \(client.socket)")
            clients.removeValue(forKey: client.socket)
            close(client.socket)
        }
    }
    
    private func respondToSetup(client: RTSPClient) {
        // Only respond if we have valid client ports
        guard client.clientRTPPort > 0 && client.clientRTCPPort > 0 else {
            respondWithError(client: client, code: 400, message: "Bad Request - Invalid Transport")
            return
        }
        
        let response = """
        RTSP/1.0 200 OK\r
        CSeq: \(client.cseq)\r
        Session: \(client.sessionId)\r
        Transport: RTP/AVP;unicast;client_port=\(client.clientRTPPort)-\(client.clientRTCPPort);server_port=\(self.port)-\(self.port+1)\r
        \r
        """
        if !client.send(response) {
            logger.error("Failed to send SETUP response to client \(client.socket)")
            clients.removeValue(forKey: client.socket)
            close(client.socket)
        }
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
        if !client.send(response) {
            logger.error("Failed to send PLAY response to client \(client.socket)")
            clients.removeValue(forKey: client.socket)
            close(client.socket)
        }
    }
    
    private func respondToPause(client: RTSPClient) {
        client.isPlaying = false
        let response = """
        RTSP/1.0 200 OK\r
        CSeq: \(client.cseq)\r
        Session: \(client.sessionId)\r
        \r
        """
        if !client.send(response) {
            logger.error("Failed to send PAUSE response to client \(client.socket)")
            clients.removeValue(forKey: client.socket)
            close(client.socket)
        }
    }
    
    private func respondToTeardown(client: RTSPClient) {
        client.isPlaying = false
        let response = """
        RTSP/1.0 200 OK\r
        CSeq: \(client.cseq)\r
        Session: \(client.sessionId)\r
        \r
        """
        if !client.send(response) {
            logger.error("Failed to send TEARDOWN response to client \(client.socket)")
        }
        
        clients.removeValue(forKey: client.socket)
        close(client.socket)
    }
    
    private func respondWithError(client: RTSPClient, code: Int, message: String) {
        let response = """
        RTSP/1.0 \(code) \(message)\r
        CSeq: \(client.cseq)\r
        \r
        """
        if !client.send(response) {
            logger.error("Failed to send error response to client \(client.socket)")
        }
    }
    
    private func broadcastToClients(_ packet: Data) {
        var failedSockets: [Int32] = []
        
        for (socket, client) in clients where client.isPlaying {
            if !client.send(packet) {
                logger.error("Failed to send RTP packet to client \(socket)")
                failedSockets.append(socket)
            }
        }
        
        // Clean up failed clients
        for socket in failedSockets {
            clients.removeValue(forKey: socket)
            close(socket)
        }
    }
    
    func processVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isStreaming,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        guard let encoder = videoEncoder else {
            logger.error("Video encoder not initialized")
            return
        }
        
        let status = VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: imageBuffer,
            presentationTimeStamp: timestamp,
            duration: CMTime.invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        
        if status != noErr {
            logger.error("Failed to encode video frame: \(status)")
        }
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
    
    func send(_ data: String) -> Bool {
        let result = data.withCString { ptr in
            Darwin.send(socket, ptr, strlen(ptr), 0)
        }
        return result != -1
    }
    
    func send(_ data: Data) -> Bool {
        let result = data.withUnsafeBytes { ptr in
            Darwin.send(socket, ptr.baseAddress, data.count, 0)
        }
        return result != -1
    }
} 