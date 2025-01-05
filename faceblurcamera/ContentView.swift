//
//  ContentView.swift
//  faceblurcamera
//
//  Created by Rıza Semih Koca on 5.01.2025.
//

import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var showSettings = false
    
    var body: some View {
        ZStack {
            // Camera preview
            CameraPreviewView(previewLayer: cameraManager.previewLayer)
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                Spacer()
                
                HStack {
                    Button(action: {
                        showSettings.toggle()
                    }) {
                        Image(systemName: "gear")
                            .font(.title)
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .padding()
                    
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(cameraManager: cameraManager)
        }
        .onAppear {
            cameraManager.startCamera()
        }
        .onDisappear {
            cameraManager.stopCamera()
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer?
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        if let layer = previewLayer {
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
        }
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        if let layer = previewLayer {
            layer.frame = uiView.bounds
        }
    }
}

struct CameraSettingsSection: View {
    @ObservedObject var cameraManager: CameraManager
    private let availableFPS = [15.0, 24.0, 30.0, 60.0]
    
    var body: some View {
        Section(header: Text("Camera Settings")) {
            Picker("FPS", selection: $cameraManager.currentFPS) {
                ForEach(availableFPS, id: \.self) { fps in
                    Text("\(Int(fps)) FPS")
                }
            }
            
            Toggle("Auto Focus", isOn: $cameraManager.isAutoFocusEnabled)
                .onChange(of: cameraManager.isAutoFocusEnabled) { newValue in
                    cameraManager.setAutoFocus(newValue)
                }
            
            if !cameraManager.isAutoFocusEnabled {
                Slider(value: $cameraManager.focusPoint, in: 0...1) {
                    Text("Focus")
                }
            }
            
            Toggle("Auto Exposure", isOn: $cameraManager.isAutoExposureEnabled)
                .onChange(of: cameraManager.isAutoExposureEnabled) { newValue in
                    cameraManager.setAutoExposure(newValue)
                }
            
            Toggle("Auto White Balance", isOn: $cameraManager.isAutoWhiteBalanceEnabled)
                .onChange(of: cameraManager.isAutoWhiteBalanceEnabled) { newValue in
                    cameraManager.setAutoWhiteBalance(newValue)
                }
            
            Slider(value: $cameraManager.zoomFactor, in: 1...5) {
                Text("Zoom")
            }
            .onChange(of: cameraManager.zoomFactor) { newValue in
                cameraManager.setZoom(newValue)
            }
            
            Button(action: {
                cameraManager.toggleFlash()
            }) {
                Text(cameraManager.isFlashEnabled ? "Disable Flash" : "Enable Flash")
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var cameraManager: CameraManager
    @Environment(\.presentationMode) var presentationMode
    @State private var ipAddress: String = NetworkUtils.getIPAddress() ?? "unknown"
    
    var body: some View {
        NavigationView {
            Form {
                CameraSettingsSection(cameraManager: cameraManager)
                
                Section(header: Text("Resolution")) {
                    Text("2K (2048 x 1080)")
                        .foregroundColor(.gray)
                }
                
                Section(header: Text("RTSP Stream")) {
                    Text("rtsp://admin:admin@\(ipAddress):8554")
                        .foregroundColor(.gray)
                }
            }
            .navigationTitle("Settings")
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

#Preview {
    if #available(iOS 15.0, *) {
        ContentView()
    } else {
        Text("Requires iOS 15.0 or later")
    }
}
