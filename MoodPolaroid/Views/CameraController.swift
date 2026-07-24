import AVFoundation
import AudioToolbox
import CoreVideo
import ImageIO
import SwiftUI
import UIKit

/// 产品中对应设备原生物理镜头切换点的可选焦段。
struct CameraZoomOption: Identifiable, Equatable {
    let factor: CGFloat
    let displayFactor: CGFloat

    var id: String {
        String(format: "%.2f", factor)
    }

    var displayName: String {
        if displayFactor.rounded() == displayFactor {
            return "\(Int(displayFactor))×"
        }
        return String(format: "%.1f×", displayFactor)
    }
}

/// 产品中负责配置原生相机会话、焦段、闪光灯、前后摄与静态照片拍摄的控制器。
final class CameraController: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back
    @Published private(set) var zoomOptions: [CameraZoomOption] = []
    @Published private(set) var currentZoomFactor: CGFloat = 1
    @Published private(set) var isFlashAvailable = false
    @Published private(set) var isFlashEnabled = false
    @Published private(set) var isSwitchingCamera = false

    var usesScreenFlash: Bool {
        cameraPosition == .front && isFlashEnabled
    }

    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "MoodPolaroid.camera.session")
    private let videoOutputQueue = DispatchQueue(
        label: "MoodPolaroid.camera.filtered-preview",
        qos: .userInteractive
    )
    private var isConfigured = false
    private var currentInput: AVCaptureDeviceInput?
    private var photoProcessor: PhotoCaptureProcessor?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationDeviceUniqueID: String?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var captureRotationObservation: NSKeyValueObservation?
    private var captureRotationAngle: CGFloat = 0
    private weak var filteredPreview: CameraPreviewFrameConsumer?
    private var cachedCameras: [Int: AVCaptureDevice] = [:]

    func prepare() {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

        switch authorizationStatus {
        case .authorized:
            configureIfNeeded()
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                await MainActor.run {
                    self.authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
                    if granted {
                        self.configureIfNeeded()
                    }
                }
            }
        case .denied, .restricted:
            isReady = false
        @unknown default:
            errorMessage = "暂时无法确认相机权限状态。"
        }
    }

    func start() {
        guard authorizationStatus == .authorized, isConfigured else { return }
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func toggleFlash() {
        guard isFlashAvailable else { return }
        isFlashEnabled.toggle()
    }

    /// 把 SwiftUI 取景层交给相机控制器，用 iOS 17 的旋转协调器同步预览与照片输出。
    @MainActor
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        if previewLayer === layer,
           rotationDeviceUniqueID == currentInput?.device.uniqueID,
           rotationCoordinator != nil {
            layer.connection?.automaticallyAdjustsVideoMirroring = false
            layer.connection?.isVideoMirrored = cameraPosition == .front
            return
        }
        previewLayer = layer
        guard let device = currentInput?.device else { return }
        configureRotationCoordinator(for: device, position: cameraPosition)
    }

    /// 把 GPU 滤镜取景渲染器接到相机视频帧输出。
    @MainActor
    func attachFilteredPreview(_ preview: CameraPreviewFrameConsumer) {
        filteredPreview = preview
    }

    func setZoom(_ option: CameraZoomOption) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            let zoomFactor = min(
                max(option.factor, device.minAvailableVideoZoomFactor),
                device.maxAvailableVideoZoomFactor
            )

            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = zoomFactor
                device.unlockForConfiguration()

                DispatchQueue.main.async {
                    self.currentZoomFactor = zoomFactor
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "无法切换焦段：\(error.localizedDescription)"
                }
            }
        }
    }

    @MainActor
    func switchCamera() {
        guard isConfigured, !isSwitchingCamera else { return }
        isSwitchingCamera = true
        let targetPosition: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let newDevice = self.bestCamera(for: targetPosition),
                  let oldInput = self.currentInput else {
                DispatchQueue.main.async {
                    self.errorMessage = "当前设备没有可切换的摄像头。"
                    self.isSwitchingCamera = false
                }
                return
            }

            do {
                let newInput = try AVCaptureDeviceInput(device: newDevice)
                self.session.beginConfiguration()
                self.session.removeInput(oldInput)

                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.currentInput = newInput
                    self.session.commitConfiguration()
                    self.publishCapabilities(for: newDevice, position: targetPosition)
                } else {
                    self.session.addInput(oldInput)
                    self.session.commitConfiguration()
                    throw CameraControllerError.cannotSwitchCamera
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "无法切换摄像头：\(error.localizedDescription)"
                    self.isSwitchingCamera = false
                }
            }
        }
    }

    func capture(
        filterParameters: CameraSkinFilterParameters,
        completion: @escaping (Result<UIImage, Error>) -> Void
    ) {
        guard isReady else {
            completion(.failure(CameraControllerError.notReady))
            return
        }

        let settings = AVCapturePhotoSettings()
        settings.flashMode = isFlashEnabled && cameraPosition == .back ? .on : .off

        if let connection = photoOutput.connection(with: .video) {
            let angle = captureRotationAngle
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = cameraPosition == .front
        }

        // “胶片方向”：取景框比例始终参与裁切，但不根据设备姿态自动转正像素。
        // AVCaptureConnection 继续负责既有的前摄镜像；照片代理会忽略 EXIF 方向。
        let previewAspectRatio = previewLayer.flatMap { layer -> CGFloat? in
            guard layer.bounds.width > 0, layer.bounds.height > 0 else { return nil }
            return layer.bounds.width / layer.bounds.height
        }
        let processor = PhotoCaptureProcessor(
            previewAspectRatio: previewAspectRatio,
            filterParameters: filterParameters
        ) { [weak self] result in
            DispatchQueue.main.async {
                completion(result)
                self?.photoProcessor = nil
            }
        }
        photoProcessor = processor
        photoOutput.capturePhoto(with: settings, delegate: processor)
    }

    private func configureIfNeeded() {
        guard !isConfigured else {
            start()
            return
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            defer { self.session.commitConfiguration() }

            guard let camera = self.bestCamera(for: .back) else {
                DispatchQueue.main.async {
                    self.errorMessage = "当前设备没有可用相机。你仍然可以从系统相册导入。"
                }
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: camera)
                guard self.session.canAddInput(input),
                      self.session.canAddOutput(self.photoOutput),
                      self.session.canAddOutput(self.videoOutput) else {
                    throw CameraControllerError.cannotConfigure
                }

                self.session.addInput(input)
                self.session.addOutput(self.photoOutput)
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_32BGRA
                ]
                self.videoOutput.setSampleBufferDelegate(
                    self,
                    queue: self.videoOutputQueue
                )
                self.session.addOutput(self.videoOutput)
                self.currentInput = input
                self.isConfigured = true
                self.publishCapabilities(for: camera, position: .back)

                DispatchQueue.main.async {
                    self.errorMessage = nil
                    self.isReady = true
                    self.start()
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "相机启动失败：\(error.localizedDescription)"
                    self.isReady = false
                }
            }
        }
    }

    private func bestCamera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if let cached = cachedCameras[position.rawValue] {
            return cached
        }
        let deviceTypes: [AVCaptureDevice.DeviceType]

        if position == .back {
            deviceTypes = [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInWideAngleCamera
            ]
        } else {
            deviceTypes = [
                .builtInWideAngleCamera,
                .builtInTrueDepthCamera
            ]
        }

        let device = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: position
        ).devices.first
        cachedCameras[position.rawValue] = device
        return device
    }

    private func publishCapabilities(
        for device: AVCaptureDevice,
        position: AVCaptureDevice.Position
    ) {
        let options = nativeZoomOptions(for: device, position: position)
        let initialZoom = options.first?.factor ?? 1

        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = min(
                max(initialZoom, device.minAvailableVideoZoomFactor),
                device.maxAvailableVideoZoomFactor
            )
            device.unlockForConfiguration()
        } catch {
            // 保留系统当前焦段，不阻断摄像头切换。
        }

        DispatchQueue.main.async {
            self.cameraPosition = position
            self.zoomOptions = options
            self.currentZoomFactor = initialZoom
            self.isFlashAvailable = position == .front || device.hasFlash
            if !self.isFlashAvailable {
                self.isFlashEnabled = false
            }
            self.configureRotationCoordinator(for: device, position: position)

            // 旋转与镜像已在同一主线程周期完成，下一帧即可直接显示。
            self.isSwitchingCamera = false
        }
    }

    @MainActor
    private func configureRotationCoordinator(
        for device: AVCaptureDevice,
        position: AVCaptureDevice.Position
    ) {
        previewRotationObservation = nil
        captureRotationObservation = nil

        guard let previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: device,
            previewLayer: previewLayer
        )
        rotationCoordinator = coordinator
        rotationDeviceUniqueID = device.uniqueID

        // “胶片方向”：成片角度必须与取景角度完全一致，取景看到什么就拍到什么。
        // 不能用 videoRotationAngleForHorizonLevelCapture——它会把横持拍到的画面
        // 自动转正，于是卡片里变成正着的横图，和侧躺的取景框对不上。
        let previewAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        let captureAngle = previewAngle
        UIView.performWithoutAnimation {
            guard let connection = previewLayer.connection else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = position == .front
            if connection.isVideoRotationAngleSupported(previewAngle) {
                connection.videoRotationAngle = previewAngle
            }
        }
        captureRotationAngle = captureAngle
        configureVideoOutputConnection(
            position: position,
            rotationAngle: previewAngle
        )

        previewRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self, weak previewLayer] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                guard let connection = previewLayer?.connection,
                      connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
                self?.configureVideoOutputConnection(
                    position: position,
                    rotationAngle: angle
                )
            }
        }

        // 成片角度跟随取景角度，而不是自动转正角度，保证所见即所得。
        captureRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            DispatchQueue.main.async {
                self?.captureRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
            }
        }
    }

    @MainActor
    private func configureVideoOutputConnection(
        position: AVCaptureDevice.Position,
        rotationAngle: CGFloat
    ) {
        guard let connection = videoOutput.connection(with: .video) else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = position == .front
        }
        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
    }

    private func nativeZoomOptions(
        for device: AVCaptureDevice,
        position: AVCaptureDevice.Position
    ) -> [CameraZoomOption] {
        guard position == .back else {
            return [CameraZoomOption(factor: 1, displayFactor: 1)]
        }

        let usesUltraWideBase = device.deviceType == .builtInTripleCamera
            || device.deviceType == .builtInDualWideCamera
        let displayMultiplier: CGFloat = usesUltraWideBase ? 0.5 : 1
        let switchFactors = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let rawFactors = [CGFloat(1)] + switchFactors

        var uniqueFactors: [CGFloat] = []
        for factor in rawFactors where factor <= device.maxAvailableVideoZoomFactor {
            if !uniqueFactors.contains(where: { abs($0 - factor) < 0.01 }) {
                uniqueFactors.append(factor)
            }
        }

        return uniqueFactors.map {
            CameraZoomOption(factor: $0, displayFactor: $0 * displayMultiplier)
        }
    }
}

/// 产品中拍摄、吐纸完成与翻卡时使用的轻量系统音效和触感反馈。
enum MoodSoundEffect {
    static func capture() {
        // 系统在 AVCapturePhotoOutput 拍照时已经会播放一次快门声，
        // 这里再播 1108 会变成“咔嚓咔嚓”两声、听起来像连拍两张，故只保留触感。
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    static func printStart() {
        AudioServicesPlaySystemSound(1057)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func developmentComplete() {
        AudioServicesPlaySystemSound(1054)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func cardFlip() {
        AudioServicesPlaySystemSound(1104)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// 产品中把 AVCaptureSession 的实时画面显示进 SwiftUI 取景框的原生预览视图。
struct CameraPreview: UIViewRepresentable {
    let camera: CameraController

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attachPreviewLayer(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        uiView.previewLayer.session = camera.session
        camera.attachPreviewLayer(uiView.previewLayer)
    }
}

/// 产品中承载系统相机预览图层，并让图层自动匹配取景框尺寸的 UIKit 视图。
final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

/// 产品中把相机实时视频帧转发给 Metal-backed Core Image 预览器。
extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isSwitchingCamera else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        filteredPreview?.consume(pixelBuffer: pixelBuffer)
    }
}

/// 产品中接收一张系统相机照片数据并转换为 UIImage 的拍摄代理。
private final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let previewAspectRatio: CGFloat?
    private let filterParameters: CameraSkinFilterParameters
    private let completion: (Result<UIImage, Error>) -> Void

    init(
        previewAspectRatio: CGFloat?,
        filterParameters: CameraSkinFilterParameters,
        completion: @escaping (Result<UIImage, Error>) -> Void
    ) {
        self.previewAspectRatio = previewAspectRatio
        self.filterParameters = filterParameters
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            completion(.failure(error))
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let rawPixels = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            completion(.failure(CameraControllerError.cannotCreateImage))
            return
        }

        // 不让 UIImage 自动套用 EXIF orientation：传感器像素以预览中的方向进入相纸。
        // 从这里开始 orientation 永远为 .up，后续页面无需再判断方向。
        let filmImage = UIImage(cgImage: rawPixels, scale: 1, orientation: .up)
        let preparedImage: UIImage
        if let previewAspectRatio,
           let croppedImage = filmImage.croppedToPreview(
               aspectRatio: previewAspectRatio
           ) {
            preparedImage = croppedImage
        } else {
            preparedImage = filmImage
        }

        guard let filteredImage = CameraFilterPipeline.render(
            image: preparedImage,
            parameters: filterParameters
        ) else {
            completion(.failure(CameraControllerError.cannotCreateImage))
            return
        }
        completion(.success(filteredImage))
    }
}

/// 产品中按实时取景框宽高比裁切已经处于“胶片方向”的原始像素。
private extension UIImage {
    func croppedToPreview(aspectRatio targetAspectRatio: CGFloat) -> UIImage? {
        guard let source = cgImage else { return nil }
        guard targetAspectRatio.isFinite, targetAspectRatio > 0 else { return nil }

        let sourceWidth = CGFloat(source.width)
        let sourceHeight = CGFloat(source.height)
        let sourceAspectRatio = sourceWidth / sourceHeight
        let pixelRect: CGRect

        if sourceAspectRatio > targetAspectRatio {
            let croppedWidth = sourceHeight * targetAspectRatio
            pixelRect = CGRect(
                x: (sourceWidth - croppedWidth) / 2,
                y: 0,
                width: croppedWidth,
                height: sourceHeight
            )
        } else {
            let croppedHeight = sourceWidth / targetAspectRatio
            pixelRect = CGRect(
                x: 0,
                y: (sourceHeight - croppedHeight) / 2,
                width: sourceWidth,
                height: croppedHeight
            )
        }

        let integralRect = pixelRect.integral.intersection(
            CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        )
        guard let cropped = source.cropping(to: integralRect) else { return nil }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }
}

/// 产品中原生相机尚未就绪、无法配置、切换或生成照片时使用的相机错误。
private enum CameraControllerError: LocalizedError {
    case notReady
    case cannotConfigure
    case cannotSwitchCamera
    case cannotCreateImage

    var errorDescription: String? {
        switch self {
        case .notReady: "相机还没有准备好。"
        case .cannotConfigure: "无法配置当前设备的相机。"
        case .cannotSwitchCamera: "当前设备不支持切换到该摄像头。"
        case .cannotCreateImage: "无法读取刚刚拍摄的照片。"
        }
    }
}
