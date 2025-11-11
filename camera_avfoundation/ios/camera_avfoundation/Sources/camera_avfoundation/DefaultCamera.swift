// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import CoreMotion
import UIKit

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

  func captureToMemory(
    _ options: FCPPlatformCaptureOptions,
    completion: @escaping (_ data: Data?, _ width: Int, _ height: Int, _ error: FlutterError?) -> Void
  ) {
    (self as FLTCam).captureToMemory { data, width, height, error in
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
      print("[captureToMemory] base image size: \(Int(baseImage.size.width))x\(Int(baseImage.size.height))")

      var targetWidth = Int(options.targetResolution.width)
      var targetHeight = Int(options.targetResolution.height)

      // Extract board parameters (screen coordinates from Flutter)
      var boardImage: UIImage?
      var boardScreenX: Double = 0
      var boardScreenY: Double = 0
      var boardScreenWidth: Double = 0
      var boardScreenHeight: Double = 0
      var previewWidth: Double = Double(baseImage.size.width)
      var previewHeight: Double = Double(baseImage.size.height)
      var devicePixelRatio: Double = 1.0
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
        devicePixelRatio = Double(boardData.devicePixelRatio)
        deviceOrientationDegrees = Int(boardData.deviceOrientationDegrees)
        print("[captureToMemory] board data: position=(\(boardScreenX), \(boardScreenY)) size=\(boardScreenWidth)x\(boardScreenHeight) preview=\(previewWidth)x\(previewHeight) deviceOrientationDegrees=\(deviceOrientationDegrees)")
      } else {
        print("[captureToMemory] no board data supplied, using camera defaults")
      }

      // Get camera dimensions
      var processingImage = baseImage
      var cameraRotationApplied: CGFloat = 0
      let initialCameraWidth = Double(processingImage.size.width)
      let initialCameraHeight = Double(processingImage.size.height)

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
          processingImage = rotateImage(processingImage, degrees: rotationDegrees)
        }
      } else {
        print("[captureToMemory] orientations already aligned, no camera rotation needed")
      }

      let actualCameraWidth = Double(processingImage.size.width)
      let actualCameraHeight = Double(processingImage.size.height)
      print("[captureToMemory] processing image size: \(Int(actualCameraWidth))x\(Int(actualCameraHeight)), cameraRotationApplied=\(cameraRotationApplied)")

      // Rotate board bitmap in native based on orientation
      var rotatedBoardImage = boardImage
      if let boardImage = boardImage {
       print("[captureToMemory] board image size before rotation: \(Int(boardImage.size.width))x\(Int(boardImage.size.height))")
        // Skip rotation for portrait (0°) and upside down (180°)
        // Only rotate for landscape orientations (90° and 270°)
        let shouldRotateBoard = deviceOrientationDegrees == 90 || deviceOrientationDegrees == 270
        if shouldRotateBoard {
          let boardRotationDegrees = CGFloat(deviceOrientationDegrees)
          let rotated = rotateImage(boardImage, degrees: boardRotationDegrees)
          rotatedBoardImage = rotated
          print("[captureToMemory] rotated board image by \(boardRotationDegrees)° -> size: \(Int(rotated.size.width))x\(Int(rotated.size.height))")
        } else {
          print("[captureToMemory] board rotation skipped (deviceOrientationDegrees=\(deviceOrientationDegrees))")
        }
      }      // Resize camera to target resolution FIRST (before rotation - much faster!)
      let scaleToFillW = Double(targetWidth) / actualCameraWidth
      let scaleToFillH = Double(targetHeight) / actualCameraHeight
      let fillScale = max(scaleToFillW, scaleToFillH)

      let resizedW = Int(actualCameraWidth * fillScale)
      let resizedH = Int(actualCameraHeight * fillScale)

      let resizedBitmap = resizeImage(processingImage, to: CGSize(width: resizedW, height: resizedH))

      // Center crop to target size (still landscape orientation)
      var croppedBitmap = resizedBitmap
      if resizedW > targetWidth || resizedH > targetHeight {
        let cropOffsetX = max((resizedW - targetWidth) / 2, 0)
        let cropOffsetY = max((resizedH - targetHeight) / 2, 0)
        croppedBitmap = cropImage(resizedBitmap, to: CGSize(width: targetWidth, height: targetHeight), origin: CGPoint(x: cropOffsetX, y: cropOffsetY))
      }

      // Image is already oriented correctly, so no manual rotation is needed.
      let orientedBitmap = croppedBitmap

      // Rotate camera bitmap to match final device orientation before merging board
      let renderBitmap: UIImage
      if deviceOrientationDegrees != 0 {
        let rotationDegrees = CGFloat(deviceOrientationDegrees)
        renderBitmap = rotateImage(orientedBitmap, degrees: rotationDegrees)
        print("[captureToMemory] rotated base image by \(rotationDegrees)° -> size: \(Int(renderBitmap.size.width))x\(Int(renderBitmap.size.height))")
      } else {
        renderBitmap = orientedBitmap
      }

      // Merge board
      var finalBitmap = renderBitmap

      if rotatedBoardImage != nil {
        let finalWidth = Double(renderBitmap.size.width)
        let finalHeight = Double(renderBitmap.size.height)

        let scaleX = finalWidth / previewWidth
        let scaleY = finalHeight / previewHeight
        let scale = max(scaleX, scaleY)

        let scaledPreviewWidth = previewWidth * scale
        let scaledPreviewHeight = previewHeight * scale
        let offsetX = (scaledPreviewWidth - finalWidth) / 2.0
        let offsetY = (scaledPreviewHeight - finalHeight) / 2.0

        var mappedBoardScreenWidth = boardScreenWidth
        var mappedBoardScreenHeight = boardScreenHeight
        if let boardImage = rotatedBoardImage {
          let boardImageIsLandscape = boardImage.size.width >= boardImage.size.height
          let boardScreenIsLandscape = boardScreenWidth >= boardScreenHeight
          if boardImageIsLandscape != boardScreenIsLandscape {
            print("[captureToMemory] board aspect mismatch detected - swapping width/height for mapping")
            swap(&mappedBoardScreenWidth, &mappedBoardScreenHeight)
          }
        }

        let desiredBoardW = Int(round(mappedBoardScreenWidth * scale))
        let desiredBoardH = Int(round(mappedBoardScreenHeight * scale))
        let desiredBoardX = Int(round(boardScreenX * scale - offsetX))
        let desiredBoardY = Int(round(boardScreenY * scale - offsetY))

        print("[captureToMemory] board mapping -> desired size=\(desiredBoardW)x\(desiredBoardH) position=(\(desiredBoardX), \(desiredBoardY)) scale=\(scale) offsets=(\(offsetX), \(offsetY))")

        let clampedBoardW = max(1, min(desiredBoardW, Int(finalWidth)))
        let clampedBoardH = max(1, min(desiredBoardH, Int(finalHeight)))
        let clampedBoardX = max(0, min(desiredBoardX, Int(finalWidth) - clampedBoardW))
        let clampedBoardY = max(0, min(desiredBoardY, Int(finalHeight) - clampedBoardH))
        if clampedBoardW != desiredBoardW || clampedBoardH != desiredBoardH || clampedBoardX != desiredBoardX || clampedBoardY != desiredBoardY {
          print("[captureToMemory] board clamped to size=\(clampedBoardW)x\(clampedBoardH) position=(\(clampedBoardX), \(clampedBoardY))")
        }

      let boardToDraw = resizeImage(rotatedBoardImage!, to: CGSize(width: clampedBoardW, height: clampedBoardH))

        // Preserve orientation before merge
        let originalOrientation = renderBitmap.imageOrientation
        let mergedImage = mergeImage(renderBitmap, with: boardToDraw, at: CGPoint(x: clampedBoardX, y: clampedBoardY))
        // Restore original orientation after merge
        finalBitmap = UIImage(cgImage: mergedImage.cgImage!, scale: mergedImage.scale, orientation: originalOrientation)
        print("[captureToMemory] preserved orientation after merge: \(originalOrientation.rawValue)")
        print("[captureToMemory] final bitmap size: \(Int(finalBitmap.size.width))x\(Int(finalBitmap.size.height))")
      }

      let uprightBitmap = finalBitmap.fixedOrientation()

      // Encode to JPEG
      guard let resultBytes = uprightBitmap.jpegData(compressionQuality: 0.85) else {
        completion(
          nil,
          Int(uprightBitmap.size.width),
          Int(uprightBitmap.size.height),
          FlutterError(code: "compressError", message: "Failed to compress final image", details: nil))
        return
      }

      completion(
        resultBytes,
        Int(uprightBitmap.size.width),
        Int(uprightBitmap.size.height),
        nil)
    }
  }

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

private func resizeImage(_ image: UIImage, to targetSize: CGSize) -> UIImage {
  UIGraphicsBeginImageContextWithOptions(targetSize, false, image.scale)
  image.draw(
    in: CGRect(
      x: 0,
      y: 0,
      width: targetSize.width,
      height: targetSize.height))
  let resized = UIGraphicsGetImageFromCurrentImageContext() ?? image
  UIGraphicsEndImageContext()
  return resized
}

private func cropImage(_ image: UIImage, to targetSize: CGSize, origin: CGPoint) -> UIImage {
  UIGraphicsBeginImageContextWithOptions(targetSize, false, image.scale)
  image.draw(
    in: CGRect(
      x: -origin.x,
      y: -origin.y,
      width: image.size.width,
      height: image.size.height))
  let cropped = UIGraphicsGetImageFromCurrentImageContext() ?? image
  UIGraphicsEndImageContext()
  return cropped
}

private func rotateImage(_ image: UIImage, degrees: CGFloat) -> UIImage {
  let radians = degrees * .pi / 180
  var newRect = CGRect(origin: .zero, size: image.size)
    .applying(CGAffineTransform(rotationAngle: radians))
    .integral
  newRect.size.width = abs(newRect.size.width)
  newRect.size.height = abs(newRect.size.height)

  UIGraphicsBeginImageContextWithOptions(newRect.size, false, image.scale)
  guard let context = UIGraphicsGetCurrentContext() else {
    UIGraphicsEndImageContext()
    return image
  }

  context.translateBy(x: newRect.size.width / 2, y: newRect.size.height / 2)
  context.rotate(by: radians)
  image.draw(
    in: CGRect(
      x: -image.size.width / 2,
      y: -image.size.height / 2,
      width: image.size.width,
      height: image.size.height))

  let rotated = UIGraphicsGetImageFromCurrentImageContext() ?? image
  UIGraphicsEndImageContext()
  return rotated
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
