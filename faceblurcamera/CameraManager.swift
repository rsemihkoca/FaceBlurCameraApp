import AVFoundation
import CoreMedia
import SwiftUI

class CameraManager: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    
    private let captureSession = AVCaptureSession()
    private var videoDevice: AVCaptureDevice?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var rtspStreamer: RTSPStreamer?
    
    // Camera settings
    @Published var currentFPS: Double = 30.0 {
        didSet {
            setFPS(currentFPS)
        }
    }
    @Published var currentResolution: CGSize = CGSize(width: 2048, height: 1080) // 2K
    @Published var isAutoFocusEnabled = true
    @Published var isAutoExposureEnabled = true
    @Published var isAutoWhiteBalanceEnabled = true
    @Published var zoomFactor: CGFloat = 1.0
    @Published var focusPoint: CGFloat = 0.5
    @Published var exposureValue: Float = 0.5
    @Published var isFlashEnabled = false
    
    override init() {
        super.init()
        rtspStreamer = RTSPStreamer()
        setupCamera()
    }
    
    private func setupCamera() {
        captureSession.sessionPreset = .hd1920x1080 // Close to 2K resolution (1920x1080)
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                 for: .video,
                                                 position: .back) else {
            print("Failed to get back camera")
            return
        }
        
        self.videoDevice = device
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
            
            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
            
            if captureSession.canAddOutput(videoOutput) {
                captureSession.addOutput(videoOutput)
            }
            
            self.videoOutput = videoOutput
            
            let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
            previewLayer.videoGravity = .resizeAspectFill
            self.previewLayer = previewLayer
            
        } catch {
            print("Error setting up camera: \(error.localizedDescription)")
        }
    }
    
    func startCamera() {
        guard !captureSession.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.startRunning()
            do {
                try self.rtspStreamer?.startStreaming()
            } catch {
                print("Failed to start RTSP streaming: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                self.isRunning = true
            }
        }
    }
    
    func stopCamera() {
        guard captureSession.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.stopRunning()
            self.rtspStreamer?.stopStreaming()
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }
    
    // Camera configuration methods
    func setFPS(_ fps: Double) {
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.unlockForConfiguration()
        } catch {
            print("Error setting FPS: \(error.localizedDescription)")
        }
    }
    
    func setAutoFocus(_ enabled: Bool) {
        guard let device = videoDevice,
              device.isFocusModeSupported(.autoFocus) else { return }
        
        do {
            try device.lockForConfiguration()
            device.focusMode = enabled ? .autoFocus : .locked
            device.unlockForConfiguration()
        } catch {
            print("Error setting auto focus: \(error.localizedDescription)")
        }
    }
    
    func setAutoExposure(_ enabled: Bool) {
        guard let device = videoDevice,
              device.isExposureModeSupported(.autoExpose) else { return }
        
        do {
            try device.lockForConfiguration()
            device.exposureMode = enabled ? .autoExpose : .locked
            device.unlockForConfiguration()
        } catch {
            print("Error setting auto exposure: \(error.localizedDescription)")
        }
    }
    
    func setAutoWhiteBalance(_ enabled: Bool) {
        guard let device = videoDevice,
              device.isWhiteBalanceModeSupported(.autoWhiteBalance) else { return }
        
        do {
            try device.lockForConfiguration()
            device.whiteBalanceMode = enabled ? .autoWhiteBalance : .locked
            device.unlockForConfiguration()
        } catch {
            print("Error setting auto white balance: \(error.localizedDescription)")
        }
    }
    
    func setZoom(_ factor: CGFloat) {
        guard let device = videoDevice else { return }
        
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = max(1.0, min(factor, device.maxAvailableVideoZoomFactor))
            device.unlockForConfiguration()
        } catch {
            print("Error setting zoom: \(error.localizedDescription)")
        }
    }
    
    func toggleFlash() {
        guard let device = videoDevice else { return }
        
        do {
            try device.lockForConfiguration()
            if device.hasTorch {
                device.torchMode = isFlashEnabled ? .off : .on
                isFlashEnabled.toggle()
            }
            device.unlockForConfiguration()
        } catch {
            print("Error toggling flash: \(error.localizedDescription)")
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Forward the frame to RTSP streamer
        rtspStreamer?.processVideoFrame(sampleBuffer)
    }
}
