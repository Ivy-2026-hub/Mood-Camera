import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Metal
import MetalKit
import SwiftUI
import UIKit

/// 产品中原相机的内置 CameraSkin 配置；它没有图片机身，也不添加任何滤镜。
extension CameraSkins {
    static var selectable: [CameraSkin] {
        let preferredOrder = ["mood_camera", "ccd"]
        let generated = preferredOrder.compactMap(named)
        return [original] + generated
    }

    static func selectableNamed(_ id: String?) -> CameraSkin? {
        guard let id else { return nil }
        return selectable.first { $0.id == id }
    }

    static var original: CameraSkin {
        CameraSkin(
            id: "original",
            displayName: "原相机",
            thumbnailImage: "",
            bodyImage: "",
            pixelWidth: 1,
            pixelHeight: 1,
            canvasColor: Color(red: 0.956863, green: 0.956863, blue: 0.956863),
            viewfinderRect: CameraSkinViewfinderRect(
                x: 0,
                y: 0,
                width: 1,
                height: 1,
                cornerRadiusWidth: 0
            ),
            hotspots: [],
            controls: [],
            filter: CameraSkinFilterParameters(
                saturation: 1,
                contrast: 1,
                brightness: 0,
                temperatureShift: 0,
                fade: 0,
                vignetteIntensity: 0,
                vignetteRadius: 1,
                grainIntensity: 0,
                grainSize: 1,
                bloomIntensity: 0,
                bloomRadiusFraction: 0
            ),
            papers: []
        )
    }
}

/// 产品中实时取景采用的轻量参数；色调保持一致，昂贵的动态颗粒留给最终成片。
private extension CameraSkinFilterParameters {
    var optimizedForLivePreview: CameraSkinFilterParameters {
        CameraSkinFilterParameters(
            saturation: saturation,
            contrast: contrast,
            brightness: brightness,
            temperatureShift: temperatureShift,
            fade: fade,
            vignetteIntensity: vignetteIntensity,
            vignetteRadius: vignetteRadius,
            grainIntensity: 0,
            grainSize: grainSize,
            bloomIntensity: min(bloomIntensity, 0.10),
            bloomRadiusFraction: min(bloomRadiusFraction, 0.008)
        )
    }
}

/// 产品中实时预览和最终成片共用的 Core Image 滤镜流水线。
enum CameraFilterPipeline {
    static let metalDevice = MTLCreateSystemDefaultDevice()
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context: CIContext = {
        if let metalDevice {
            return CIContext(
                mtlDevice: metalDevice,
                options: [
                    .cacheIntermediates: false,
                    .workingColorSpace: colorSpace,
                    .outputColorSpace: colorSpace
                ]
            )
        }
        return CIContext(
            options: [
                .useSoftwareRenderer: false,
                .workingColorSpace: colorSpace,
                .outputColorSpace: colorSpace
            ]
        )
    }()

    /// 按 CameraSkin 配置创建同一条非破坏式 CIFilter 链。
    static func filteredImage(
        _ inputImage: CIImage,
        parameters: CameraSkinFilterParameters
    ) -> CIImage {
        let isIdentity = abs(parameters.saturation - 1) < 0.0001
            && abs(parameters.contrast - 1) < 0.0001
            && abs(parameters.brightness) < 0.0001
            && abs(parameters.temperatureShift) < 0.0001
            && abs(parameters.fade) < 0.0001
            && abs(parameters.vignetteIntensity) < 0.0001
            && abs(parameters.grainIntensity) < 0.0001
            && abs(parameters.bloomIntensity) < 0.0001
        if isIdentity {
            return inputImage
        }

        let originalExtent = inputImage.extent
        var image = inputImage

        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(image, forKey: kCIInputImageKey)
            controls.setValue(parameters.saturation, forKey: kCIInputSaturationKey)
            controls.setValue(parameters.contrast, forKey: kCIInputContrastKey)
            controls.setValue(parameters.brightness, forKey: kCIInputBrightnessKey)
            image = controls.outputImage ?? image
        }

        if abs(parameters.temperatureShift) > 0.001,
           let temperature = CIFilter(name: "CITemperatureAndTint") {
            temperature.setValue(image, forKey: kCIInputImageKey)
            temperature.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            // 参数正值定义为偏暖，因此目标白点向较低色温移动。
            let targetTemperature = min(
                12000,
                max(2500, 6500 - parameters.temperatureShift)
            )
            temperature.setValue(
                CIVector(x: targetTemperature, y: 0),
                forKey: "inputTargetNeutral"
            )
            image = temperature.outputImage ?? image
        }

        if parameters.fade > 0.001,
           let fade = CIFilter(name: "CIColorMatrix") {
            let amount = min(0.25, max(0, parameters.fade))
            let channelScale = 1 - amount * 0.20
            let blackLift = amount * 0.40
            fade.setValue(image, forKey: kCIInputImageKey)
            fade.setValue(CIVector(x: channelScale, y: 0, z: 0, w: 0), forKey: "inputRVector")
            fade.setValue(CIVector(x: 0, y: channelScale, z: 0, w: 0), forKey: "inputGVector")
            fade.setValue(CIVector(x: 0, y: 0, z: channelScale, w: 0), forKey: "inputBVector")
            fade.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            fade.setValue(
                CIVector(x: blackLift, y: blackLift, z: blackLift, w: 0),
                forKey: "inputBiasVector"
            )
            image = fade.outputImage ?? image
        }

        if parameters.bloomIntensity > 0.001,
           let bloom = CIFilter(name: "CIBloom") {
            let shortEdge = min(originalExtent.width, originalExtent.height)
            bloom.setValue(image, forKey: kCIInputImageKey)
            bloom.setValue(
                min(1, max(0, parameters.bloomIntensity)),
                forKey: kCIInputIntensityKey
            )
            bloom.setValue(
                max(0, shortEdge * parameters.bloomRadiusFraction),
                forKey: kCIInputRadiusKey
            )
            image = (bloom.outputImage ?? image).cropped(to: originalExtent)
        }

        if parameters.grainIntensity > 0.001,
           let random = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let grainSize = min(3, max(0.5, parameters.grainSize))
            var noise = random.transformed(
                by: CGAffineTransform(scaleX: grainSize, y: grainSize)
            )
            if let monochrome = CIFilter(name: "CIColorControls") {
                monochrome.setValue(noise, forKey: kCIInputImageKey)
                monochrome.setValue(0, forKey: kCIInputSaturationKey)
                noise = monochrome.outputImage ?? noise
            }
            if let grainMatrix = CIFilter(name: "CIColorMatrix") {
                grainMatrix.setValue(noise, forKey: kCIInputImageKey)
                let rgb = CIVector(x: 0.34, y: 0, z: 0, w: 0)
                grainMatrix.setValue(rgb, forKey: "inputRVector")
                grainMatrix.setValue(
                    CIVector(x: 0, y: 0.34, z: 0, w: 0),
                    forKey: "inputGVector"
                )
                grainMatrix.setValue(
                    CIVector(x: 0, y: 0, z: 0.34, w: 0),
                    forKey: "inputBVector"
                )
                grainMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputAVector")
                grainMatrix.setValue(
                    CIVector(
                        x: 0.33,
                        y: 0.33,
                        z: 0.33,
                        w: min(0.15, max(0, parameters.grainIntensity))
                    ),
                    forKey: "inputBiasVector"
                )
                noise = grainMatrix.outputImage ?? noise
            }
            if let blend = CIFilter(name: "CISoftLightBlendMode") {
                blend.setValue(noise.cropped(to: originalExtent), forKey: kCIInputImageKey)
                blend.setValue(image, forKey: kCIInputBackgroundImageKey)
                image = (blend.outputImage ?? image).cropped(to: originalExtent)
            }
        }

        if parameters.vignetteIntensity > 0.001,
           let vignette = CIFilter(name: "CIVignette") {
            vignette.setValue(image, forKey: kCIInputImageKey)
            vignette.setValue(
                min(2, max(0, parameters.vignetteIntensity)),
                forKey: kCIInputIntensityKey
            )
            vignette.setValue(
                min(2, max(0, parameters.vignetteRadius)),
                forKey: kCIInputRadiusKey
            )
            image = vignette.outputImage ?? image
        }

        return image.cropped(to: originalExtent)
    }

    /// 使用同一个 GPU CIContext 渲染最终成片。
    static func render(
        image: UIImage,
        parameters: CameraSkinFilterParameters
    ) -> UIImage? {
        guard let inputImage = CIImage(
            image: image,
            options: [.applyOrientationProperty: true]
        ) else {
            return nil
        }
        let outputImage = filteredImage(inputImage, parameters: parameters)
        guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
    }
}

/// 产品中接收相机会话 BGRA 帧并交给 Metal 预览渲染器的接口。
protocol CameraPreviewFrameConsumer: AnyObject {
    func consume(pixelBuffer: CVPixelBuffer)
}

/// 产品中使用 Metal-backed Core Image 实时显示 CameraSkin 滤镜的原生预览。
struct FilteredCameraPreview: UIViewRepresentable {
    let camera: CameraController
    let parameters: CameraSkinFilterParameters

    func makeUIView(context: Context) -> FilteredCameraPreviewView {
        let view = FilteredCameraPreviewView(
            parameters: parameters.optimizedForLivePreview
        )
        view.previewLayer.session = camera.session
        camera.attachPreviewLayer(view.previewLayer)
        camera.attachFilteredPreview(view)
        return view
    }

    func updateUIView(_ uiView: FilteredCameraPreviewView, context: Context) {
        uiView.previewLayer.session = camera.session
        uiView.update(parameters: parameters.optimizedForLivePreview)
        camera.attachPreviewLayer(uiView.previewLayer)
        camera.attachFilteredPreview(uiView)
    }
}

/// 产品中承载隐藏方向协调层和可见 Metal 取景画面的 UIKit 容器。
final class FilteredCameraPreviewView:
    UIView,
    CameraPreviewFrameConsumer,
    MTKViewDelegate {
    let previewLayer = AVCaptureVideoPreviewLayer()

    private let metalView: MTKView
    private let commandQueue: MTLCommandQueue?
    private let stateLock = NSLock()
    private var parameters: CameraSkinFilterParameters
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestFrameID: UInt64 = 0
    private var submittedFrameID: UInt64 = 0
    private var isRendering = false
    private var isDrawScheduled = false
    private var consecutiveGPUFailures = 0
    private var usesSystemPreviewFallback = false
    private var lastAcceptedFrameTime: CFTimeInterval = 0

    /// 实时取景最长边上限；最终照片仍按原始分辨率完整渲染。
    private static let maximumPreviewPixelEdge: CGFloat = 720
    /// 实时预览上限 30 fps，避免相机会话把过量帧堆到 GPU。
    private static let minimumFrameInterval: CFTimeInterval = 1.0 / 30.0

    init(parameters: CameraSkinFilterParameters) {
        self.parameters = parameters
        let device = CameraFilterPipeline.metalDevice
        metalView = MTKView(frame: .zero, device: device)
        commandQueue = device?.makeCommandQueue()
        super.init(frame: .zero)

        backgroundColor = .black
        clipsToBounds = true
        previewLayer.opacity = 0
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)

        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.framebufferOnly = false
        metalView.autoResizeDrawable = false
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.delegate = self
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        let screenScale = window?.screen.scale ?? traitCollection.displayScale
        let desiredSize = CGSize(
            width: max(1, bounds.width * screenScale),
            height: max(1, bounds.height * screenScale)
        )
        let longestEdge = max(desiredSize.width, desiredSize.height)
        let downsampleScale = min(
            1,
            Self.maximumPreviewPixelEdge / max(1, longestEdge)
        )
        metalView.drawableSize = CGSize(
            width: max(1, (desiredSize.width * downsampleScale).rounded()),
            height: max(1, (desiredSize.height * downsampleScale).rounded())
        )
    }

    func update(parameters: CameraSkinFilterParameters) {
        stateLock.lock()
        self.parameters = parameters
        stateLock.unlock()
    }

    func consume(pixelBuffer: CVPixelBuffer) {
        var shouldScheduleDraw = false
        let now = CACurrentMediaTime()
        stateLock.lock()
        guard !usesSystemPreviewFallback else {
            stateLock.unlock()
            return
        }
        guard now - lastAcceptedFrameTime >= Self.minimumFrameInterval else {
            stateLock.unlock()
            return
        }
        lastAcceptedFrameTime = now
        latestPixelBuffer = pixelBuffer
        latestFrameID &+= 1
        if !isRendering && !isDrawScheduled {
            isDrawScheduled = true
            shouldScheduleDraw = true
        }
        stateLock.unlock()

        guard shouldScheduleDraw else { return }
        DispatchQueue.main.async { [weak self] in
            self?.metalView.draw()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }

    /// drawable 只在主线程的 MTKView 绘制周期中获取，并限制为单帧在途。
    func draw(in view: MTKView) {
        autoreleasepool {
            stateLock.lock()
            guard let pixelBuffer = latestPixelBuffer else {
                isDrawScheduled = false
                stateLock.unlock()
                return
            }
            let frameID = latestFrameID
            let currentParameters = parameters
            isDrawScheduled = false
            isRendering = true
            submittedFrameID = frameID
            stateLock.unlock()

            guard let drawable = metalView.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer() else {
                finishRendering(frameID: frameID)
                return
            }

            let source = CIImage(cvPixelBuffer: pixelBuffer)
            let targetSize = CGSize(
                width: drawable.texture.width,
                height: drawable.texture.height
            )
            // 先缩放/裁切，再执行滤镜；避免在 4K 相机帧上运行 Bloom 等昂贵算子。
            let fittedSource = fittedForPreview(source, targetSize: targetSize)
            let filtered = CameraFilterPipeline.filteredImage(
                fittedSource,
                parameters: currentParameters
            )
            let targetBounds = CGRect(origin: .zero, size: targetSize)
            let composited = filtered.composited(
                over: CIImage(color: .black).cropped(to: targetBounds)
            )
            CameraFilterPipeline.context.render(
                composited,
                to: drawable.texture,
                commandBuffer: commandBuffer,
                bounds: targetBounds,
                colorSpace: CameraFilterPipeline.colorSpace
            )
            commandBuffer.present(drawable)
            commandBuffer.addCompletedHandler { [weak self] completedBuffer in
                self?.recordGPUResult(didFail: completedBuffer.status == .error)
                self?.finishRendering(frameID: frameID)
            }
            commandBuffer.commit()
        }
    }

    /// 连续 GPU 错误时停止继续冲击已失败的队列，退回系统预览保证相机可操作。
    private func recordGPUResult(didFail: Bool) {
        var shouldEnableFallback = false
        stateLock.lock()
        if didFail {
            consecutiveGPUFailures += 1
            if consecutiveGPUFailures >= 2 && !usesSystemPreviewFallback {
                usesSystemPreviewFallback = true
                shouldEnableFallback = true
            }
        } else {
            consecutiveGPUFailures = 0
        }
        stateLock.unlock()

        guard shouldEnableFallback else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            UIView.performWithoutAnimation {
                self.previewLayer.opacity = 1
                self.metalView.isHidden = true
            }
        }
    }

    private func finishRendering(frameID: UInt64) {
        var shouldScheduleDraw = false
        stateLock.lock()
        if submittedFrameID == frameID {
            isRendering = false
        }
        if latestFrameID > frameID && !isRendering && !isDrawScheduled {
            isDrawScheduled = true
            shouldScheduleDraw = true
        }
        stateLock.unlock()

        guard shouldScheduleDraw else { return }
        DispatchQueue.main.async { [weak self] in
            self?.metalView.draw()
        }
    }

    /// 横持设备时保留整幅横向画面；竖持时继续按取景框铺满。
    private func fittedForPreview(_ image: CIImage, targetSize: CGSize) -> CIImage {
        var normalized = image.transformed(
            by: CGAffineTransform(
                translationX: -image.extent.origin.x,
                y: -image.extent.origin.y
            )
        )
        let sourceSize = normalized.extent.size
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              targetSize.width > 0,
              targetSize.height > 0 else {
            return normalized
        }

        let sourceAspect = sourceSize.width / sourceSize.height
        let targetAspect = targetSize.width / targetSize.height
        let preservesLandscape = sourceAspect > 1 && targetAspect < 1
        let scale = preservesLandscape
            ? min(targetSize.width / sourceSize.width, targetSize.height / sourceSize.height)
            : max(targetSize.width / sourceSize.width, targetSize.height / sourceSize.height)
        normalized = normalized.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let scaledSize = normalized.extent.size
        return normalized.transformed(
            by: CGAffineTransform(
                translationX: (targetSize.width - scaledSize.width) / 2,
                y: (targetSize.height - scaledSize.height) / 2
            )
        )
    }
}
