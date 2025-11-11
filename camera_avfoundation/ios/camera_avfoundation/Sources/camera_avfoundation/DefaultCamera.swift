// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import CoreMotion
import UIKit
import ImageIO
import MobileCoreServices

// Import Objectice-C part of the implementation when SwiftPM is used.
#if canImport(camera_avfoundation_objc)
  import camera_avfoundation_objc
#endif

final class DefaultCamera: FLTCam, Camera {
  /// The queue on which `latestPixelBuffer` property is accessed.
  /// To avoid unnecessary contention, do not access `latestPixelBuffer` on the `captureSessionQueue`.
  private let pixelBufferSynchronizationQueue = DispatchQueue(
    label: "io.flutter.camera.pixelBufferSynchronizationQueue")

  /// Tracks the latest pixel buffer sent from AVFoundation's sample buffer delegate callback.
  /// Used to deliver the latest pixel buffer to the flutter engine via the `copyPixelBuffer` API.
  private var latestPixelBuffer: CVPixelBuffer?
  private var lastVideoSampleTime = CMTime.zero
  private var lastAudioSampleTime = CMTime.zero

  /// Maximum number of frames pending processing.
  /// To limit memory consumption, limit the number of frames pending processing.
  /// After some testing, 4 was determined to be the best maximum value.
  /// https://github.com/flutter/plugins/pull/4520#discussion_r766335637
  private var maxStreamingPendingFramesCount = 4

  private var exposureMode = FCPPlatformExposureMode.auto
  private var focusMode = FCPPlatformFocusMode.auto

  func reportInitializationState() {
    // Get all the state on the current thread, not the main thread.
    let state = FCPPlatformCameraState.make(
      withPreviewSize: FCPPlatformSize.make(
        withWidth: Double(previewSize.width),
        height: Double(previewSize.height)
      ),
      exposureMode: exposureMode,
      focusMode: focusMode,
      exposurePointSupported: captureDevice.isExposurePointOfInterestSupported,
      focusPointSupported: captureDevice.isFocusPointOfInterestSupported
    )

    FLTEnsureToRunOnMainQueue { [weak self] in
      self?.dartAPI?.initialized(with: state) { _ in
        // Ignore any errors, as this is just an event broadcast.
      }
    }
  }

  func receivedImageStreamData() {
    streamingPendingFramesCount -= 1
  }

  func start() {
    videoCaptureSession.startRunning()
    audioCaptureSession.startRunning()
  }

  func stop() {
    videoCaptureSession.stopRunning()
    audioCaptureSession.stopRunning()
  }

  func setExposureMode(_ mode: FCPPlatformExposureMode) {
    exposureMode = mode
    applyExposureMode()
  }

  private func applyExposureMode() {
    try? captureDevice.lockForConfiguration()
    switch exposureMode {
    case .locked:
      // AVCaptureExposureMode.autoExpose automatically adjusts the exposure one time, and then locks exposure for the device
      captureDevice.setExposureMode(.autoExpose)
    case .auto:
      if captureDevice.isExposureModeSupported(.continuousAutoExposure) {
        captureDevice.setExposureMode(.continuousAutoExposure)
      } else {
        captureDevice.setExposureMode(.autoExpose)
      }
    @unknown default:
      assertionFailure("Unknown exposure mode")
    }
    captureDevice.unlockForConfiguration()
  }

  func setExposureOffset(_ offset: Double) {
    try? captureDevice.lockForConfiguration()
    captureDevice.setExposureTargetBias(Float(offset), completionHandler: nil)
    captureDevice.unlockForConfiguration()
  }

  func setExposurePoint(
    _ point: FCPPlatformPoint?, withCompletion completion: @escaping (FlutterError?) -> Void
  ) {
    guard captureDevice.isExposurePointOfInterestSupported else {
      completion(
        FlutterError(
          code: "setExposurePointFailed",
          message: "Device does not have exposure point capabilities",
          details: nil))
      return
    }

    let orientation = UIDevice.current.orientation
    try? captureDevice.lockForConfiguration()
    // A nil point resets to the center.
    let exposurePoint = cgPoint(
      for: point ?? FCPPlatformPoint.makeWith(x: 0.5, y: 0.5), withOrientation: orientation)
    captureDevice.setExposurePointOfInterest(exposurePoint)
    captureDevice.unlockForConfiguration()
    // Retrigger auto exposure
    applyExposureMode()
    completion(nil)
  }

  func setFocusMode(_ mode: FCPPlatformFocusMode) {
    focusMode = mode
    applyFocusMode()
  }

  func setFocusPoint(_ point: FCPPlatformPoint?, completion: @escaping (FlutterError?) -> Void) {
    guard captureDevice.isFocusPointOfInterestSupported else {
      completion(
        FlutterError(
          code: "setFocusPointFailed",
          message: "Device does not have focus point capabilities",
          details: nil))
      return
    }

    let orientation = deviceOrientationProvider.orientation()
    try? captureDevice.lockForConfiguration()
    // A nil point resets to the center.
    captureDevice.setFocusPointOfInterest(
      cgPoint(
        for: point ?? .makeWith(x: 0.5, y: 0.5),
        withOrientation: orientation)
    )
    captureDevice.unlockForConfiguration()
    // Retrigger auto focus
    applyFocusMode()
    completion(nil)
  }

  private func applyFocusMode() {
    applyFocusMode(focusMode, onDevice: captureDevice)
  }

  private func applyFocusMode(
    _ focusMode: FCPPlatformFocusMode, onDevice captureDevice: FLTCaptureDevice
  ) {
    try? captureDevice.lockForConfiguration()
    switch focusMode {
    case .locked:
      // AVCaptureFocusMode.autoFocus automatically adjusts the focus one time, and then locks focus
      if captureDevice.isFocusModeSupported(.autoFocus) {
        captureDevice.setFocusMode(.autoFocus)
      }
    case .auto:
      if captureDevice.isFocusModeSupported(.continuousAutoFocus) {
        captureDevice.setFocusMode(.continuousAutoFocus)
      } else if captureDevice.isFocusModeSupported(.autoFocus) {
        captureDevice.setFocusMode(.autoFocus)
      }
    @unknown default:
      assertionFailure("Unknown focus mode")
    }
    captureDevice.unlockForConfiguration()
  }

  private func cgPoint(
    for point: FCPPlatformPoint, withOrientation orientation: UIDeviceOrientation
  )
    -> CGPoint
  {
    var x = point.x
    var y = point.y
    switch orientation {
    case .portrait:  // 90 ccw
      y = 1 - point.x
      x = point.y
    case .portraitUpsideDown:  // 90 cw
      x = 1 - point.y
      y = point.x
    case .landscapeRight:  // 180
      x = 1 - point.x
      y = 1 - point.y
    case .landscapeLeft:
      // No rotation required
      break
    default:
      // No rotation required
      break
    }
    return CGPoint(x: x, y: y)
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    if output == captureVideoOutput.avOutput {
      if let newBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {

        pixelBufferSynchronizationQueue.sync {
          latestPixelBuffer = newBuffer
        }

        onFrameAvailable?()
      }
    }

    guard CMSampleBufferDataIsReady(sampleBuffer) else {
      reportErrorMessage("sample buffer is not ready. Skipping sample")
      return
    }

    if isStreamingImages {
      if let eventSink = imageStreamHandler?.eventSink,
        streamingPendingFramesCount < maxStreamingPendingFramesCount
      {
        streamingPendingFramesCount += 1

        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!
        // Must lock base address before accessing the pixel data
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)

        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)

        var planes: [[String: Any]] = []

        let isPlanar = CVPixelBufferIsPlanar(pixelBuffer)
        let planeCount = isPlanar ? CVPixelBufferGetPlaneCount(pixelBuffer) : 1

        for i in 0..<planeCount {
          let planeAddress: UnsafeMutableRawPointer?
          let bytesPerRow: Int
          let height: Int
          let width: Int

          if isPlanar {
            planeAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, i)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, i)
            height = CVPixelBufferGetHeightOfPlane(pixelBuffer, i)
            width = CVPixelBufferGetWidthOfPlane(pixelBuffer, i)
          } else {
            planeAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
            width = CVPixelBufferGetWidth(pixelBuffer)
          }

          let length = bytesPerRow * height
          let bytes = Data(bytes: planeAddress!, count: length)

          let planeBuffer: [String: Any] = [
            "bytesPerRow": bytesPerRow,
            "width": width,
            "height": height,
            "bytes": FlutterStandardTypedData(bytes: bytes),
          ]
          planes.append(planeBuffer)
        }

        // Lock the base address before accessing pixel data, and unlock it afterwards.
        // Done accessing the `pixelBuffer` at this point.
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        let imageBuffer: [String: Any] = [
          "width": imageWidth,
          "height": imageHeight,
          "format": videoFormat,
          "planes": planes,
          "lensAperture": Double(captureDevice.lensAperture()),
          "sensorExposureTime": Int(captureDevice.exposureDuration().seconds * 1_000_000_000),
          "sensorSensitivity": Double(captureDevice.iso()),
        ]

        DispatchQueue.main.async {
          eventSink(imageBuffer)
        }
      }
    }

    if isRecording && !isRecordingPaused {
      if videoWriter?.status == .failed, let error = videoWriter?.error {
        reportErrorMessage("\(error)")
        return
      }

      // ignore audio samples until the first video sample arrives to avoid black frames
      // https://github.com/flutter/flutter/issues/57831
      if isFirstVideoSample && output != captureVideoOutput.avOutput {
        return
      }

      var currentSampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

      if isFirstVideoSample {
        videoWriter?.startSession(atSourceTime: currentSampleTime)
        // fix sample times not being numeric when pause/resume happens before first sample buffer
        // arrives
        // https://github.com/flutter/flutter/issues/132014
        lastVideoSampleTime = currentSampleTime
        lastAudioSampleTime = currentSampleTime
        isFirstVideoSample = false
      }

      if output == captureVideoOutput.avOutput {
        if videoIsDisconnected {
          videoIsDisconnected = false

          videoTimeOffset =
            videoTimeOffset.value == 0
            ? CMTimeSubtract(currentSampleTime, lastVideoSampleTime)
            : CMTimeAdd(videoTimeOffset, CMTimeSubtract(currentSampleTime, lastVideoSampleTime))

          return
        }

        lastVideoSampleTime = currentSampleTime

        let nextBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        let nextSampleTime = CMTimeSubtract(lastVideoSampleTime, videoTimeOffset)
        // do not append sample buffer when readyForMoreMediaData is NO to avoid crash
        // https://github.com/flutter/flutter/issues/132073
        if videoWriterInput?.readyForMoreMediaData ?? false {
          videoAdaptor?.append(nextBuffer!, withPresentationTime: nextSampleTime)
        }
      } else {
        let dur = CMSampleBufferGetDuration(sampleBuffer)

        if dur.value > 0 {
          currentSampleTime = CMTimeAdd(currentSampleTime, dur)
        }

        if audioIsDisconnected {
          audioIsDisconnected = false

          audioTimeOffset =
            audioTimeOffset.value == 0
            ? CMTimeSubtract(currentSampleTime, lastAudioSampleTime)
            : CMTimeAdd(audioTimeOffset, CMTimeSubtract(currentSampleTime, lastAudioSampleTime))

          return
        }

        lastAudioSampleTime = currentSampleTime

        if audioTimeOffset.value != 0 {
          if let adjustedSampleBuffer = copySampleBufferWithAdjustedTime(
            sampleBuffer,
            by: audioTimeOffset)
          {
            newAudioSample(adjustedSampleBuffer)
          }
        } else {
          newAudioSample(sampleBuffer)
        }
      }
    }
  }

  private func copySampleBufferWithAdjustedTime(_ sample: CMSampleBuffer, by offset: CMTime)
    -> CMSampleBuffer?
  {
    var count: CMItemCount = 0
    CMSampleBufferGetSampleTimingInfoArray(
      sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)

    let timingInfo = UnsafeMutablePointer<CMSampleTimingInfo>.allocate(capacity: Int(count))
    defer { timingInfo.deallocate() }

    CMSampleBufferGetSampleTimingInfoArray(
      sample, entryCount: count, arrayToFill: timingInfo, entriesNeededOut: &count)

    for i in 0..<count {
      timingInfo[Int(i)].decodeTimeStamp = CMTimeSubtract(
        timingInfo[Int(i)].decodeTimeStamp, offset)
      timingInfo[Int(i)].presentationTimeStamp = CMTimeSubtract(
        timingInfo[Int(i)].presentationTimeStamp, offset)
    }

    var adjustedSampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(
      allocator: nil,
      sampleBuffer: sample,
      sampleTimingEntryCount: count,
      sampleTimingArray: timingInfo,
      sampleBufferOut: &adjustedSampleBuffer)

    return adjustedSampleBuffer
  }

  private func newAudioSample(_ sampleBuffer: CMSampleBuffer) {
    guard videoWriter?.status == .writing else {
      if videoWriter?.status == .failed, let error = videoWriter?.error {
        reportErrorMessage("\(error)")
      }
      return
    }
    if audioWriterInput?.readyForMoreMediaData ?? false {
      if !(audioWriterInput?.append(sampleBuffer) ?? false) {
        reportErrorMessage("Unable to write to audio input")
      }
    }
  }

  func close() {
    stop()
    for input in videoCaptureSession.inputs {
      videoCaptureSession.removeInput(FLTDefaultCaptureInput(input: input))
    }
    for output in videoCaptureSession.outputs {
      videoCaptureSession.removeOutput(output)
    }
    for input in audioCaptureSession.inputs {
      audioCaptureSession.removeInput(FLTDefaultCaptureInput(input: input))
    }
    for output in audioCaptureSession.outputs {
      audioCaptureSession.removeOutput(output)
    }
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    var pixelBuffer: CVPixelBuffer?
    pixelBufferSynchronizationQueue.sync {
      pixelBuffer = latestPixelBuffer
      latestPixelBuffer = nil
    }

    if let buffer = pixelBuffer {
      return Unmanaged.passRetained(buffer)
    } else {
      return nil
    }
  }

  private func reportErrorMessage(_ errorMessage: String) {
    FLTEnsureToRunOnMainQueue { [weak self] in
      self?.dartAPI?.reportError(errorMessage) { _ in
        // Ignore any errors, as this is just an event broadcast.
      }
    }
  }

  // Fast capture from preview buffer (no high-res capture needed)
  private func capturePreviewBuffer() -> (CVPixelBuffer, Int, Int)? {
    var pixelBuffer: CVPixelBuffer?
    pixelBufferSynchronizationQueue.sync {
      pixelBuffer = latestPixelBuffer
    }
    
    guard let buffer = pixelBuffer else {
      print("[capturePreviewBuffer] ❌ No preview buffer available - latestPixelBuffer is nil")
      return nil
    }
    
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    
    print("[capturePreviewBuffer] ✅ Preview buffer captured: \(width)x\(height)")
    return (buffer, width, height)
  }
  
  // Convert CVPixelBuffer to JPEG Data
  private func pixelBufferToJPEG(_ pixelBuffer: CVPixelBuffer, quality: CGFloat = 0.85) -> Data? {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = sharedCIContext
    
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
      return nil
    }
    
    let uiImage = UIImage(cgImage: cgImage)
    return uiImage.jpegData(compressionQuality: quality)
  }

  func captureToMemory(
    _ options: FCPPlatformCaptureOptions,
    completion: @escaping (_ data: Data?, _ width: Int, _ height: Int, _ error: FlutterError?) -> Void
  ) {
    let startTime = CFAbsoluteTimeGetCurrent()
    
    // Try to capture from preview buffer first (much faster!)
    // Retry a few times if preview buffer not available yet
    var retryCount = 0
    let maxRetries = 3
    
    func attemptPreviewCapture() {
      if let (pixelBuffer, bufferWidth, bufferHeight) = capturePreviewBuffer() {
        let captureTime = CFAbsoluteTimeGetCurrent()
        print("[Performance] Preview buffer capture took: \(Int((captureTime - startTime) * 1000))ms (retries: \(retryCount))")
        
        // Convert CVPixelBuffer to CIImage directly (no decode needed!)
        let baseCIImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        print("[captureToMemory] preview buffer size: \(bufferWidth)x\(bufferHeight)")
        
        // Continue with processing pipeline...
        self.processImage(
          ciImage: baseCIImage,
          originalWidth: bufferWidth,
          originalHeight: bufferHeight,
          options: options,
          captureTime: captureTime,
          completion: completion)
        
      } else {
        // Retry if preview buffer not available yet (max 3 times with 10ms delay)
        retryCount += 1
        if retryCount < maxRetries {
          print("[captureToMemory] Preview buffer not ready, retrying (\(retryCount)/\(maxRetries))...")
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            attemptPreviewCapture()
          }
        } else {
          // Fallback to full-res capture after retries exhausted
          print("[Performance] Preview buffer not available after \(maxRetries) retries, using full-res capture")
          (self as FLTCam).captureToMemory { data, width, height, error in
            let captureTime = CFAbsoluteTimeGetCurrent()
            print("[Performance] Full-res capture took: \(Int((captureTime - startTime) * 1000))ms")
            
            if let error = error {
              completion(nil, Int(width), Int(height), error)
              return
            }
            guard let baseData = data,
                  let rawImage = UIImage(data: baseData) else {
              completion(data, Int(width), Int(height), nil)
              return
            }
            let baseImage = rawImage.fixedOrientation()
            guard var baseCIImage = makeCIImage(from: baseImage) else {
              completion(data, Int(baseImage.size.width), Int(baseImage.size.height), nil)
              return
            }
            baseCIImage = normalizedCIImage(baseCIImage)
            
            self.processImage(
              ciImage: baseCIImage,
              originalWidth: Int(baseImage.size.width),
              originalHeight: Int(baseImage.size.height),
              options: options,
              captureTime: captureTime,
              completion: completion)
          }
        }
      }
    }
    
    attemptPreviewCapture()
  }
  
  private func processImage(
    ciImage: CIImage,
    originalWidth: Int,
    originalHeight: Int,
    options: FCPPlatformCaptureOptions,
    captureTime: CFAbsoluteTime,
    completion: @escaping (_ data: Data?, _ width: Int, _ height: Int, _ error: FlutterError?) -> Void
  ) {
    var processingCIImage = ciImage
    let imageScale: CGFloat = 1.0
    
    print("[captureToMemory] base image size: \(originalWidth)x\(originalHeight)")

    var targetWidth = Int(options.targetResolution.width)
    var targetHeight = Int(options.targetResolution.height)

    // Extract board parameters (screen coordinates from Flutter)
    var boardImage: UIImage?
    var boardScreenX: Double = 0
    var boardScreenY: Double = 0
    var boardScreenWidth: Double = 0
    var boardScreenHeight: Double = 0
    var previewWidth: Double = Double(originalWidth)
    var previewHeight: Double = Double(originalHeight)
    var deviceOrientationDegrees: Int = 0

    if let boardData = options.boardData {
      let boardImageData = boardData.boardImageBytes.data as Data
      boardImage = UIImage(data: boardImageData)?.fixedOrientation()
      boardScreenX = Double(boardData.boardScreenX)
      boardScreenY = Double(boardData.boardScreenY)
      boardScreenWidth = Double(boardData.boardScreenWidth)
      boardScreenHeight = Double(boardData.boardScreenHeight)
      previewWidth = Double(boardData.previewWidth)
      previewHeight = Double(boardData.previewHeight)
      deviceOrientationDegrees = Int(boardData.deviceOrientationDegrees)
      print("[captureToMemory] board data: position=(\(boardScreenX), \(boardScreenY)) size=\(boardScreenWidth)x\(boardScreenHeight) preview=\(previewWidth)x\(previewHeight) deviceOrientationDegrees=\(deviceOrientationDegrees)")
    } else {
      print("[captureToMemory] no board data supplied, using camera defaults")
    }

    var cameraRotationApplied: CGFloat = 0
    let initialExtent = processingCIImage.extent.integral
    let initialCameraWidth = Double(initialExtent.width)
      let initialCameraHeight = Double(initialExtent.height)

      // Ensure the processing target orientation matches the expected output orientation
      let cameraIsPortrait = initialCameraHeight >= initialCameraWidth
      let expectedPortrait: Bool
      if options.boardData != nil {
        expectedPortrait = deviceOrientationDegrees == 0 || deviceOrientationDegrees == 180
      } else {
        expectedPortrait = cameraIsPortrait
      }

      if expectedPortrait && targetWidth > targetHeight {
        swap(&targetWidth, &targetHeight)
      } else if !expectedPortrait && targetHeight > targetWidth {
        swap(&targetWidth, &targetHeight)
      }
      print("[captureToMemory] cameraIsPortrait=\(cameraIsPortrait) expectedPortrait=\(expectedPortrait) targetResolution=\(targetWidth)x\(targetHeight)")

      // Rotate camera image when its orientation does not match the expected output
      if cameraIsPortrait != expectedPortrait {
        let normalizedOrientation = ((deviceOrientationDegrees % 360) + 360) % 360
        var rotationDegrees: CGFloat = 0

        if cameraIsPortrait {
          // Camera output is portrait, but we expect landscape.
          switch normalizedOrientation {
          case 90:
            rotationDegrees = -90  // landscapeLeft
          case 270:
            rotationDegrees = 90  // landscapeRight
          case 180:
            rotationDegrees = 180
          default:
            rotationDegrees = -90
          }
        } else {
          // Camera output is landscape, but we expect portrait.
          switch normalizedOrientation {
          case 90:
            rotationDegrees = 90
          case 270:
            rotationDegrees = -90
          case 180:
            rotationDegrees = 180
          default:
            rotationDegrees = 90
          }
        }

        print("[captureToMemory] rotation decision -> normalizedOrientation=\(normalizedOrientation), rotationDegrees=\(rotationDegrees)")
        cameraRotationApplied = rotationDegrees
        if rotationDegrees != 0 {
          processingCIImage = rotateCIImage(processingCIImage, degrees: rotationDegrees)
        }
      } else {
        print("[captureToMemory] orientations already aligned, no camera rotation needed")
      }

      let actualExtent = processingCIImage.extent.integral
      let actualCameraWidth = Double(actualExtent.width)
      let actualCameraHeight = Double(actualExtent.height)
      print("[captureToMemory] processing image size: \(Int(actualCameraWidth))x\(Int(actualCameraHeight)), cameraRotationApplied=\(cameraRotationApplied)")

      // Rotate board bitmap in native based on orientation
      var rotatedBoardCIImage: CIImage?
      if let boardImage = boardImage,
        var boardCIImage = makeCIImage(from: boardImage) {
        boardCIImage = normalizedCIImage(boardCIImage)
        print("[captureToMemory] board image size before rotation: \(Int(boardCIImage.extent.width))x\(Int(boardCIImage.extent.height))")
        // Skip rotation for portrait (0°) and upside down (180°)
        // For landscape orientations, rotate in opposite direction to compensate
        let shouldRotateBoard = deviceOrientationDegrees == 90 || deviceOrientationDegrees == 270
        if shouldRotateBoard {
          // Rotate opposite direction: 90° -> -90° (270°), 270° -> -270° (90°)
          let boardRotationDegrees = CGFloat(deviceOrientationDegrees == 90 ? -90 : 90)
          let rotated = rotateCIImage(boardCIImage, degrees: boardRotationDegrees)
          rotatedBoardCIImage = rotated
          print("[captureToMemory] rotated board image by \(boardRotationDegrees)° -> size: \(Int(rotated.extent.width))x\(Int(rotated.extent.height))")
        } else {
          rotatedBoardCIImage = boardCIImage
          print("[captureToMemory] board rotation skipped (deviceOrientationDegrees=\(deviceOrientationDegrees))")
        }
      }
      
      let boardRotateTime = CFAbsoluteTimeGetCurrent()
      print("[Performance] Board rotation took: \(Int((boardRotateTime - captureTime) * 1000))ms")
      
      // Resize camera to target resolution using GPU (much faster!)
      let scaleToFillW = Double(targetWidth) / actualCameraWidth
      let scaleToFillH = Double(targetHeight) / actualCameraHeight
      let fillScale = max(scaleToFillW, scaleToFillH)

      let resizedW = Int(actualCameraWidth * fillScale)
      let resizedH = Int(actualCameraHeight * fillScale)

      if resizedW > 0, resizedH > 0, abs(fillScale - 1.0) > Double.ulpOfOne {
        processingCIImage = scaleCIImage(processingCIImage, scaleX: CGFloat(fillScale), scaleY: CGFloat(fillScale))
      }
      
      let resizeTime = CFAbsoluteTimeGetCurrent()
      print("[Performance] Resize took: \(Int((resizeTime - boardRotateTime) * 1000))ms")

      // Center crop to target size using GPU
      let scaledExtent = processingCIImage.extent.integral
      let scaledWidth = Int(scaledExtent.width)
      let scaledHeight = Int(scaledExtent.height)
      
      if scaledWidth > targetWidth || scaledHeight > targetHeight {
        processingCIImage = centerCropCIImage(processingCIImage, to: CGSize(width: targetWidth, height: targetHeight))
      }
      
      let cropTime = CFAbsoluteTimeGetCurrent()
      print("[Performance] Crop took: \(Int((cropTime - resizeTime) * 1000))ms")

      let orientedCIImage = processingCIImage

      // Rotate camera bitmap to match final device orientation before merging board
      let orientedRenderCIImage: CIImage
      if deviceOrientationDegrees != 0 {
        let rotationDegrees = CGFloat(deviceOrientationDegrees)
        orientedRenderCIImage = rotateCIImage(orientedCIImage, degrees: rotationDegrees)
        let renderedExtent = orientedRenderCIImage.extent.integral
        print("[captureToMemory] rotated base image by \(rotationDegrees)° -> size: \(Int(renderedExtent.width))x\(Int(renderedExtent.height))")
      } else {
        orientedRenderCIImage = orientedCIImage
      }
      
      let rotateTime = CFAbsoluteTimeGetCurrent()
      print("[Performance] Camera rotation took: \(Int((rotateTime - cropTime) * 1000))ms")

      // Merge board using GPU compositing
      var finalCIImage = orientedRenderCIImage

      if let boardCIImage = rotatedBoardCIImage {
        let finalExtent = orientedRenderCIImage.extent.integral
        let finalWidth = Double(finalExtent.width)
        let finalHeight = Double(finalExtent.height)

        let scaleX = finalWidth / previewWidth
        let scaleY = finalHeight / previewHeight
        let scale = max(scaleX, scaleY)

        let scaledPreviewWidth = previewWidth * scale
        let scaledPreviewHeight = previewHeight * scale
        let offsetX = (scaledPreviewWidth - finalWidth) / 2.0
        let offsetY = (scaledPreviewHeight - finalHeight) / 2.0

        var mappedBoardScreenWidth = boardScreenWidth
        var mappedBoardScreenHeight = boardScreenHeight
        let boardExtent = boardCIImage.extent.integral
        let boardImageIsLandscape = boardExtent.width >= boardExtent.height
        let boardScreenIsLandscape = boardScreenWidth >= boardScreenHeight
        if boardImageIsLandscape != boardScreenIsLandscape {
          print("[captureToMemory] board aspect mismatch detected - swapping width/height for mapping")
          swap(&mappedBoardScreenWidth, &mappedBoardScreenHeight)
        }

        // Transform board position for upside down orientation only
        var transformedBoardX = boardScreenX
        var transformedBoardY = boardScreenY
        
        if deviceOrientationDegrees == 180 {
          // Upside down - flip both coordinates
          transformedBoardX = previewWidth - (boardScreenX + boardScreenWidth)
          transformedBoardY = previewHeight - (boardScreenY + boardScreenHeight)
          print("[captureToMemory] board position transform for upside down: original=(\(boardScreenX), \(boardScreenY)) transformed=(\(transformedBoardX), \(transformedBoardY))")
        }

        let desiredBoardW = Int(round(mappedBoardScreenWidth * scale))
        let desiredBoardH = Int(round(mappedBoardScreenHeight * scale))
        let desiredBoardX = Int(round(transformedBoardX * scale - offsetX))
        let desiredBoardY = Int(round(transformedBoardY * scale - offsetY))

        print("[captureToMemory] board mapping -> desired size=\(desiredBoardW)x\(desiredBoardH) position=(\(desiredBoardX), \(desiredBoardY)) scale=\(scale) offsets=(\(offsetX), \(offsetY))")

        let clampedBoardW = max(1, min(desiredBoardW, Int(finalWidth)))
        let clampedBoardH = max(1, min(desiredBoardH, Int(finalHeight)))
        let clampedBoardX = max(0, min(desiredBoardX, Int(finalWidth) - clampedBoardW))
        let clampedBoardY = max(0, min(desiredBoardY, Int(finalHeight) - clampedBoardH))
        if clampedBoardW != desiredBoardW || clampedBoardH != desiredBoardH || clampedBoardX != desiredBoardX || clampedBoardY != desiredBoardY {
          print("[captureToMemory] board clamped to size=\(clampedBoardW)x\(clampedBoardH) position=(\(clampedBoardX), \(clampedBoardY))")
        }

        // Resize board using GPU
        var boardToDraw = boardCIImage
        if boardExtent.width > 0, boardExtent.height > 0,
          (boardExtent.width != CGFloat(clampedBoardW) || boardExtent.height != CGFloat(clampedBoardH)) {
          boardToDraw = resizeCIImage(boardToDraw, to: CGSize(width: clampedBoardW, height: clampedBoardH))
        }

        // Composite board over camera using GPU (Core Image blend)
        let translatedBoard = boardToDraw.transformed(
          by: CGAffineTransform(
            translationX: CGFloat(clampedBoardX),
            y: CGFloat(finalHeight) - CGFloat(clampedBoardY) - CGFloat(clampedBoardH)))
        
        finalCIImage = translatedBoard.composited(over: finalCIImage)
        finalCIImage = normalizedCIImage(finalCIImage)
        let finalExtentAfterMerge = finalCIImage.extent.integral
        print("[captureToMemory] final bitmap size: \(Int(finalExtentAfterMerge.width))x\(Int(finalExtentAfterMerge.height))")
      }
      
    let mergeTime = CFAbsoluteTimeGetCurrent()
    print("[Performance] Board merge took: \(Int((mergeTime - rotateTime) * 1000))ms")

    // Render CIImage to UIImage
    let renderedUIImage = renderCIImage(finalCIImage, scale: imageScale, orientation: .up)
    let uprightBitmap = renderedUIImage.fixedOrientation()
    
    let orientTime = CFAbsoluteTimeGetCurrent()
    print("[Performance] Render & fix orientation took: \(Int((orientTime - mergeTime) * 1000))ms")

    // Encode to JPEG with EXIF orientation
    guard let cgImage = uprightBitmap.cgImage,
          let resultBytes = encodeJPEGWithEXIF(cgImage: cgImage, deviceOrientationDegrees: deviceOrientationDegrees, quality: 0.85) else {
      completion(
        nil,
        Int(uprightBitmap.size.width),
        Int(uprightBitmap.size.height),
        FlutterError(code: "compressError", message: "Failed to compress final image", details: nil))
      return
    }
    
    let encodeTime = CFAbsoluteTimeGetCurrent()
    print("[Performance] JPEG encode took: \(Int((encodeTime - orientTime) * 1000))ms")
    print("[Performance] TOTAL processing took: \(Int((encodeTime - captureTime) * 1000))ms")

    completion(
      resultBytes,
      Int(uprightBitmap.size.width),
      Int(uprightBitmap.size.height),
      nil)
  }

}

// Helper function to encode JPEG with EXIF orientation
private func encodeJPEGWithEXIF(cgImage: CGImage, deviceOrientationDegrees: Int, quality: CGFloat) -> Data? {
  let mutableData = NSMutableData()
  
  guard let destination = CGImageDestinationCreateWithData(mutableData, kUTTypeJPEG, 1, nil) else {
    return nil
  }
  
  // Image HAS BEEN rotated by deviceOrientationDegrees (lines 707-713)
  // Need to set EXIF to tell PDF reader to rotate BACK to compensate
  // Example: Image rotated +90° → EXIF should say "rotate -90° to view" → EXIF 8
  let exifOrientation: Int
  switch deviceOrientationDegrees {
  case 0:
    exifOrientation = 1  // No rotation applied, normal orientation
  case 90:
    // Image rotated +90° → PDF needs to rotate -90° (=270° CW) to view → EXIF 8
    exifOrientation = 8
  case 180:
    // Image rotated 180° → PDF needs to rotate 180° to view → EXIF 3
    exifOrientation = 3
  case 270:
    // Image rotated +270° (=-90°) → PDF needs to rotate +90° CW to view → EXIF 6
    exifOrientation = 6
  default:
    exifOrientation = 1
  }
  
  let properties: [CFString: Any] = [
    kCGImagePropertyOrientation: exifOrientation,
    kCGImageDestinationLossyCompressionQuality: quality
  ]
  
  CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
  
  guard CGImageDestinationFinalize(destination) else {
    return nil
  }
  
  print("[captureToMemory] EXIF orientation set to \(exifOrientation) (compensating for \(deviceOrientationDegrees)° pixel rotation)")
  
  return mutableData as Data
}

private extension UIImage {
  func fixedOrientation() -> UIImage {
    if imageOrientation == .up { return self }
    UIGraphicsBeginImageContextWithOptions(size, false, scale)
    draw(in: CGRect(origin: .zero, size: size))
    let normalized = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return normalized ?? self
  }
}

// Shared CIContext for better performance (reuse across calls)
private let sharedCIContext: CIContext = {
  CIContext(options: [.useSoftwareRenderer: false])
}()

// Core Image helpers - GPU accelerated, much faster than UIGraphics
private func makeCIImage(from image: UIImage) -> CIImage? {
  if let ciImage = image.ciImage {
    return ciImage
  }
  if let cgImage = image.cgImage {
    return CIImage(cgImage: cgImage)
  }
  return nil
}

private func normalizedCIImage(_ ciImage: CIImage) -> CIImage {
  let extent = ciImage.extent
  return ciImage.transformed(
    by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
}

private func scaleCIImage(_ ciImage: CIImage, scaleX: CGFloat, scaleY: CGFloat) -> CIImage {
  return ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
}

private func rotateCIImage(_ ciImage: CIImage, degrees: CGFloat) -> CIImage {
  let radians = degrees * .pi / 180
  let rotated = ciImage.transformed(by: CGAffineTransform(rotationAngle: radians))
  return normalizedCIImage(rotated)
}

private func centerCropCIImage(_ ciImage: CIImage, to targetSize: CGSize) -> CIImage {
  let extent = ciImage.extent
  let originX = (extent.width - targetSize.width) / 2
  let originY = (extent.height - targetSize.height) / 2
  let cropRect = CGRect(x: originX, y: originY, width: targetSize.width, height: targetSize.height)
  return ciImage.cropped(to: cropRect).transformed(
    by: CGAffineTransform(translationX: -originX, y: -originY))
}

private func resizeCIImage(_ ciImage: CIImage, to targetSize: CGSize) -> CIImage {
  let extent = ciImage.extent
  let scaleX = targetSize.width / extent.width
  let scaleY = targetSize.height / extent.height
  return scaleCIImage(ciImage, scaleX: scaleX, scaleY: scaleY)
}

private func renderCIImage(_ ciImage: CIImage, scale: CGFloat, orientation: UIImage.Orientation) -> UIImage {
  let integralExtent = ciImage.extent.integral
  if let cgImage = sharedCIContext.createCGImage(ciImage, from: integralExtent) {
    return UIImage(cgImage: cgImage, scale: scale, orientation: orientation)
  }
  return UIImage(ciImage: ciImage)
}

// Fallback UIGraphics-based functions (kept for compatibility)
private func resizeImage(_ image: UIImage, to targetSize: CGSize) -> UIImage {
  guard targetSize.width > 0, targetSize.height > 0 else { return image }
  guard let ciImage = makeCIImage(from: image) else { return image }
  
  let scaleX = targetSize.width / image.size.width
  let scaleY = targetSize.height / image.size.height
  
  if abs(scaleX - 1.0) <= .ulpOfOne, abs(scaleY - 1.0) <= .ulpOfOne {
    return image
  }
  
  let transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
  let scaledImage = ciImage.transformed(by: transform)
  return renderCIImage(scaledImage, scale: image.scale, orientation: .up)
}

private func cropImage(_ image: UIImage, to targetSize: CGSize, origin: CGPoint) -> UIImage {
  guard targetSize.width > 0, targetSize.height > 0 else { return image }
  guard let ciImage = makeCIImage(from: image) else { return image }
  
  let targetRect = CGRect(origin: .zero, size: targetSize)
  let translated = ciImage.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
  let cropped = translated.cropped(to: targetRect)
  return renderCIImage(cropped, scale: image.scale, orientation: .up)
}

private func rotateImage(_ image: UIImage, degrees: CGFloat) -> UIImage {
  let normalizedDegrees = degrees.truncatingRemainder(dividingBy: 360)
  if abs(normalizedDegrees) <= .ulpOfOne {
    return image
  }
  guard let ciImage = makeCIImage(from: image) else { return image }
  
  let radians = normalizedDegrees * .pi / 180
  let rotated = ciImage.transformed(by: CGAffineTransform(rotationAngle: radians))
  let extent = rotated.extent
  let normalized = rotated.transformed(
    by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
  
  return renderCIImage(normalized, scale: image.scale, orientation: .up)
}

private func mergeImage(_ baseImage: UIImage, with overlayImage: UIImage, at point: CGPoint) -> UIImage {
  let finalSize = baseImage.size
  UIGraphicsBeginImageContextWithOptions(finalSize, false, baseImage.scale)
  baseImage.draw(in: CGRect(origin: .zero, size: finalSize))
  overlayImage.draw(in: CGRect(origin: point, size: overlayImage.size))
  let merged = UIGraphicsGetImageFromCurrentImageContext() ?? baseImage
  UIGraphicsEndImageContext()
  return merged
}
