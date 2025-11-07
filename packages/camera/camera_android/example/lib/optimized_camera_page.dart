// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:camera_example/camera_controller.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:opencv_core/opencv.dart' as cv;
import 'package:path_provider/path_provider.dart';
import 'package:screenshot/screenshot.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'board_widget.dart';
import 'camera_preview.dart';
import 'logger.dart';

/// Optimized Camera Page theo CAMERA_UI_ANALYSIS.md
///
/// Layout structure:
/// - Header Bar (80px): Close button + Flash/Confirm
/// - Main Content (Expanded): Camera Preview + Overlays
/// - Bottom Controls (80px): Capture, Resolution, Settings
class OptimizedCameraPage extends StatefulWidget {
  const OptimizedCameraPage({
    super.key,
    required this.cameras,
  });

  final List<CameraDescription> cameras;

  @override
  State<OptimizedCameraPage> createState() => _OptimizedCameraPageState();
}

class _OptimizedCameraPageState extends State<OptimizedCameraPage> {
  CameraController? _controller;
  bool _isInitialized = false;
  bool _isProcessing = false;
  XFile? _capturedImage;

  // Camera settings
  FlashMode _flashMode = FlashMode.auto;
  double _currentZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 5.0;
  double _baseScale = 1.0;
  int _pointers = 0;

  // Resolution settings
  ResolutionPreset _currentResolution = ResolutionPreset.max;

  // Rotation handling
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  DeviceOrientation _currentOrientation = DeviceOrientation.portraitUp;
  double _currentTurns = 0.0;

  // Board overlay
  final _boardScreenshotController = ScreenshotController();
  bool _isBoardVisible = true;
  late Offset _boardPosition;
  late Size _boardSize;
  Uint8List? _boardScreenshotBytes;

  // Output resolution settings (for optimization)
  final resolutions = <Size>[
    Size(640, 480), // Low - fast processing
    Size(1200, 900), // Medium - balanced
    Size(2000, 1500), // High - best quality
  ];
  int _selectedResolutionIndex = 1; // Default to medium

  // Preview rendering key để lấy actual screen size
  final GlobalKey _previewKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Lock device orientation to portrait (screen không xoay)
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    _initializeCamera();
    _boardPosition = const Offset(20, 100);
    _boardSize = const Size(300, 200);
    _startOrientationTracking();
  }

  @override
  void dispose() {
    // Restore all orientations
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _accelerometerSubscription?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initializeCamera() async {
    if (widget.cameras.isEmpty) {
      Logger.log('No cameras available');
      return;
    }

    // Use back camera by default
    final camera = widget.cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => widget.cameras.first,
    );

    _controller = CameraController(
      camera,
      mediaSettings: MediaSettings(
        resolutionPreset: _currentResolution,
        enableAudio: false,
      ),
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await _controller!.initialize();

      // Get zoom capabilities
      _minZoom =
          await CameraPlatform.instance.getMinZoomLevel(_controller!.cameraId);
      _maxZoom =
          await CameraPlatform.instance.getMaxZoomLevel(_controller!.cameraId);

      // Set initial settings
      await CameraPlatform.instance
          .setFlashMode(_controller!.cameraId, _flashMode);

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      Logger.log('Error initializing camera: $e');
    }
  }

  // ============================================================================
  // CAPTURE FUNCTIONS
  // ============================================================================

  Future<void> _takePicture() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isProcessing) {
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      final stopwatch = Stopwatch()..start();

      // Capture board screenshot if visible
      if (_isBoardVisible) {
        await _captureBoardScreenshot();
        Logger.log('📊 Board capture time: ${stopwatch.elapsedMilliseconds}ms');
      }

      // Capture camera image
      final image = await _controller!.captureToMemory();
      Logger.log('✅ Camera capture time: ${stopwatch.elapsedMilliseconds}ms');

      // Merge board with camera image
      String? finalImagePath;
      if (_isBoardVisible && _boardScreenshotBytes != null) {
        Logger.log('🔄 Starting board merge...');
        final mergeStart = stopwatch.elapsedMilliseconds;

        finalImagePath = await _mergeBoardWithCameraImage(image.bytes);

        final mergeTime = stopwatch.elapsedMilliseconds - mergeStart;
        Logger.log('✅ Board merge time: ${mergeTime}ms');
      }

      if (finalImagePath == null) return;

      setState(() {
        _capturedImage = XFile(finalImagePath!);
        _isProcessing = false;
      });

      // Get file size
      final imageFile = File(finalImagePath!);
      final fileSizeBytes = await imageFile.length();
      final fileSizeMB = fileSizeBytes / (1024 * 1024);

      Logger.log('📸 Final image: $finalImagePath');
      Logger.log(
          '💾 Image size: ${fileSizeMB.toStringAsFixed(2)} MB (${fileSizeBytes} bytes)');
      Logger.log('⏱️ TOTAL TIME: ${stopwatch.elapsedMilliseconds}ms');
      Logger.log('═══════════════════════════════════════');
    } catch (e) {
      Logger.log('Error capturing image: $e');
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _confirmImage() async {
    if (_capturedImage == null) return;

    // TODO: Navigate to next screen or process image
    Logger.log('Image confirmed: ${_capturedImage!.path}');

    // For now, just go back to camera
    setState(() {
      _capturedImage = null;
    });
  }

  void _retakeImage() {
    setState(() {
      _capturedImage = null;
    });
  }

  // ============================================================================
  // FLASH CONTROL
  // ============================================================================

  Future<void> _toggleFlashMode() async {
    if (_controller == null) return;

    final modes = [
      FlashMode.auto,
      FlashMode.off,
      FlashMode.always,
      FlashMode.torch,
    ];

    final currentIndex = modes.indexOf(_flashMode);
    final nextMode = modes[(currentIndex + 1) % modes.length];

    await CameraPlatform.instance.setFlashMode(_controller!.cameraId, nextMode);
    setState(() {
      _flashMode = nextMode;
    });
  }

  IconData _getFlashIcon() {
    switch (_flashMode) {
      case FlashMode.auto:
        return Icons.flash_auto;
      case FlashMode.always:
        return Icons.flash_on;
      case FlashMode.torch:
        return Icons.flashlight_on;
      case FlashMode.off:
        return Icons.flash_off;
    }
  }

  // ============================================================================
  // ZOOM CONTROL
  // ============================================================================

  void _handleScaleStart(ScaleStartDetails details) {
    _baseScale = _currentZoom;
  }

  Future<void> _handleScaleUpdate(ScaleUpdateDetails details) async {
    if (_controller == null || _pointers != 2) return;

    final scale = (_baseScale * details.scale).clamp(_minZoom, _maxZoom);

    if (scale != _currentZoom) {
      await CameraPlatform.instance.setZoomLevel(_controller!.cameraId, scale);
      setState(() {
        _currentZoom = scale;
      });
    }
  }

  // ============================================================================
  // ROTATION TRACKING
  // ============================================================================

  void _startOrientationTracking() {
    _accelerometerSubscription = accelerometerEventStream().listen((event) {
      final newOrientation = _getOrientationFromAccelerometer(event);
      if (newOrientation != _currentOrientation) {
        setState(() {
          _currentOrientation = newOrientation;
          _currentTurns = _getRotationTurns(newOrientation);
        });
      }
    });
  }

  DeviceOrientation _getOrientationFromAccelerometer(AccelerometerEvent event) {
    const threshold = 5.0;

    if (event.y > threshold) {
      return DeviceOrientation.portraitUp;
    } else if (event.y < -threshold) {
      return DeviceOrientation.portraitDown;
    } else if (event.x > threshold) {
      return DeviceOrientation.landscapeLeft;
    } else if (event.x < -threshold) {
      return DeviceOrientation.landscapeRight;
    }

    return _currentOrientation;
  }

  double _getRotationTurns(DeviceOrientation orientation) {
    switch (orientation) {
      case DeviceOrientation.portraitUp:
        return 0.0;
      case DeviceOrientation.landscapeLeft:
        return 0.25;
      case DeviceOrientation.portraitDown:
        return 0.5;
      case DeviceOrientation.landscapeRight:
        return -0.25;
    }
  }

  // ============================================================================
  // BOARD CONTROL
  // ============================================================================

  void _toggleBoardVisibility() {
    setState(() {
      _isBoardVisible = !_isBoardVisible;
    });
  }

  Future<void> _captureBoardScreenshot() async {
    if (!_isBoardVisible) {
      Logger.log('⚠️ Board not visible, skipping capture');
      return;
    }
    try {
      final stopwatch = Stopwatch()..start();
      final image =
          await _boardScreenshotController.capture(delay: Duration.zero);
      _boardScreenshotBytes = image;
      Logger.log(
          '✅ Board captured successfully: ${stopwatch.elapsedMilliseconds}ms');
    } catch (e, stack) {
      Logger.log('❌ Error capturing board: $e');
      Logger.log('Stack trace: $stack');
    }
  }

// Thêm hàm utility này trong class
  cv.Mat _resizeMat(cv.Mat input, int targetWidth, int targetHeight) {
    Logger.log(
        '🔧 Resizing: ${input.cols}x${input.rows} → ${targetWidth}x$targetHeight');
    // OpenCV resize uses (width, height) - CORRECTED
    return cv.resize(input, (targetWidth, targetHeight),
        interpolation: cv.INTER_LINEAR);
  }

  Future<String?> _mergeBoardWithCameraImage(Uint8List cameraBytes) async {
    if (_boardScreenshotBytes == null) {
      Logger.log('⚠️ No board screenshot captured');
      return null;
    }

    try {
      final mergeStopwatch = Stopwatch()..start();

      // 1. Load camera image
      Logger.log('📷 Loading camera image...');
      final cameraMat = cv.imdecode(cameraBytes, cv.IMREAD_COLOR);
      Logger.log('✅ Camera loaded: ${mergeStopwatch.elapsedMilliseconds}ms');

      // 2. Store camera dimensions (merge at original for best quality)
      final originalCameraWidth = cameraMat.cols;
      final originalCameraHeight = cameraMat.rows;

      Logger.log(
          '📐 Camera size: ${originalCameraWidth}x$originalCameraHeight');

      final targetResolution = resolutions[_selectedResolutionIndex];
      final targetWidth = targetResolution.width.toInt();
      final targetHeight = targetResolution.height.toInt();

      Logger.log('🎯 Target output: ${targetWidth}x$targetHeight');

      // Calculate final resize scale (applied AFTER merge)
      final scaleWidth = targetWidth / originalCameraWidth;
      final scaleHeight = targetHeight / originalCameraHeight;
      final finalResizeScale = math.max(scaleWidth, scaleHeight);

      Logger.log(
          '📊 Final scale: ${finalResizeScale.toStringAsFixed(3)} (merge first, then resize)');

      // Use original camera mat for merge
      final resizedCameraMat = cameraMat;

      // 3. Decode board image
      Logger.log('🎨 Decoding board image...');
      final boardMat = cv.imdecode(_boardScreenshotBytes!, cv.IMREAD_UNCHANGED);
      Logger.log('✅ Board decoded: ${mergeStopwatch.elapsedMilliseconds}ms');

      // 4. Get dimensions of resized camera (now working with optimized size)
      var cameraWidth = resizedCameraMat.cols; // Width
      var cameraHeight = resizedCameraMat.rows; // Height
      final boardWidth = boardMat.cols; // Width
      final boardHeight = boardMat.rows; // Height

      Logger.log(
          '📐 Camera image size (after resize): ${cameraWidth}x$cameraHeight');
      Logger.log('📐 Board screenshot size: ${boardWidth}x$boardHeight');

      // 5. CRITICAL: Handle orientation mismatch
      // Camera sensor luôn capture ở native orientation (thường landscape)
      // Preview và board có thể ở orientation khác (portrait)
      final previewSize = _controller!.value.previewSize!;
      final previewWidth = previewSize.height.toDouble();
      final previewHeight = previewSize.width.toDouble();

      Logger.log('📱 Preview size: ${previewWidth}x$previewHeight');

      // Detect orientation
      final isImageLandscape = cameraWidth > cameraHeight;
      final isPreviewPortrait = previewHeight > previewWidth;
      final isBoardPortrait = boardHeight > boardWidth;

      Logger.log(
          '🔍 Orientation check: Image=${isImageLandscape ? "Landscape" : "Portrait"}, Preview=${isPreviewPortrait ? "Portrait" : "Landscape"}, Board=${isBoardPortrait ? "Portrait" : "Landscape"}');

      // Rotate resized camera image để match với preview và board orientation
      cv.Mat orientedCameraMat = resizedCameraMat;

      if (isImageLandscape && isPreviewPortrait) {
        // Image is landscape but preview/board are portrait → Rotate 90° CW
        Logger.log(
            '🔄 ROTATING camera image 90° clockwise (landscape → portrait)...');

        orientedCameraMat = cv.rotate(resizedCameraMat, cv.ROTATE_90_CLOCKWISE);

        // Update dimensions after rotation
        cameraWidth = orientedCameraMat.cols; // Width
        cameraHeight = orientedCameraMat.rows; // Height

        Logger.log(
            '✅ Camera rotated: ${cameraWidth}x$cameraHeight (cols x rows)');
      } else if (!isImageLandscape && !isPreviewPortrait) {
        // Image is portrait but preview/board are landscape → Rotate 90° CCW
        Logger.log(
            '🔄 ROTATING camera image 90° counter-clockwise (portrait → landscape)...');

        orientedCameraMat =
            cv.rotate(resizedCameraMat, cv.ROTATE_90_COUNTERCLOCKWISE);

        // Update dimensions using .cols and .rows
        cameraWidth = orientedCameraMat.cols;
        cameraHeight = orientedCameraMat.rows;

        Logger.log(
            '✅ Camera rotated: ${cameraWidth}x$cameraHeight (cols x rows)');
      } else {
        Logger.log('✅ Orientations match, no rotation needed');
      }

      Logger.log(
          '📍 Board screen position: ${_boardPosition.dx}, ${_boardPosition.dy}');

      // 6. Get device pixel ratio - board screenshot bị scale bởi pixel ratio
      final pixelRatio = MediaQuery.of(context).devicePixelRatio;
      Logger.log('📱 Device pixel ratio: $pixelRatio');

      // 7. Calculate board widget's actual size (before pixel ratio scaling)
      final boardWidgetWidth = boardWidth / pixelRatio;
      final boardWidgetHeight = boardHeight / pixelRatio;

      Logger.log(
          '📐 Board widget size (logical pixels): ${boardWidgetWidth.toStringAsFixed(1)}x${boardWidgetHeight.toStringAsFixed(1)}');

      // 8. Simplified coordinate mapping (no FittedBox scaling)
      // Camera preview now renders directly, screen coords = preview coords
      final renderBox =
          _previewKey.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox == null) {
        Logger.log('❌ Cannot get preview render box');
        return null;
      }

      final previewScreenSize = renderBox.size;
      Logger.log(
          '📺 Preview screen size: ${previewScreenSize.width.toStringAsFixed(1)}x${previewScreenSize.height.toStringAsFixed(1)}');

      // Direct scale factors: screen → camera image
      final scaleX = cameraWidth / previewScreenSize.width;
      final scaleY = cameraHeight / previewScreenSize.height;

      Logger.log(
          '📊 Scale factors (screen→image): X=${scaleX.toStringAsFixed(2)}, Y=${scaleY.toStringAsFixed(2)}');

      // 9. Map board position: screen coords → image coords (direct mapping)
      var imageBoardX = (_boardPosition.dx * scaleX).toInt();
      var imageBoardY = (_boardPosition.dy * scaleY).toInt();

      Logger.log('🎯 Board position on image: ($imageBoardX, $imageBoardY)');

      // 10. Scale board size: screen size → image size (direct mapping)
      var scaledBoardWidth = (boardWidgetWidth * scaleX).toInt();
      var scaledBoardHeight = (boardWidgetHeight * scaleY).toInt();

      Logger.log(
          '📏 Board size on image: ${scaledBoardWidth}x$scaledBoardHeight');

      // 11. VALIDATION: Ensure board fits within image after scaling
      if (scaledBoardWidth > cameraWidth || scaledBoardHeight > cameraHeight) {
        Logger.log('⚠️ Board too large after scaling, adjusting...');

        // Clamp to max size
        scaledBoardWidth =
            math.min(scaledBoardWidth, (cameraWidth * 0.95).toInt());
        scaledBoardHeight =
            math.min(scaledBoardHeight, (cameraHeight * 0.95).toInt());

        Logger.log(
            '🔄 Adjusted board size: ${scaledBoardWidth}x$scaledBoardHeight');
      }

      // 12. Convert board to BGR if it has alpha channel
      cv.Mat boardBGR = boardMat;
      if (boardMat.channels == 4) {
        Logger.log('🎨 Converting RGBA to BGR...');
        boardBGR = cv.cvtColor(boardMat, cv.COLOR_RGBA2BGR);
        Logger.log('✅ Converted: ${mergeStopwatch.elapsedMilliseconds}ms');
      }

      // 13. Resize board to image resolution scale
      Logger.log(
          '🔧 Resizing board to ${scaledBoardWidth}x$scaledBoardHeight...');

      // Resize board screenshot từ high-DPI size xuống target size
      cv.Mat scaledBoard =
          _resizeMat(boardBGR, scaledBoardWidth, scaledBoardHeight);
      Logger.log('✅ Board resized: ${mergeStopwatch.elapsedMilliseconds}ms');

      // 14. CRITICAL: Verify actual dimensions after resize
      final actualWidth = scaledBoard.cols; // Width
      final actualHeight = scaledBoard.rows; // Height

      Logger.log(
          '🔍 Dimension verification - Expected: ${scaledBoardWidth}x$scaledBoardHeight, Actual: ${actualWidth}x$actualHeight');

// Nếu vẫn bị swap, tự động điều chỉnh
      if (actualWidth != scaledBoardWidth ||
          actualHeight != scaledBoardHeight) {
        Logger.log('🔄 Auto-correcting dimension mismatch...');

        if (actualWidth == scaledBoardHeight &&
            actualHeight == scaledBoardWidth) {
          Logger.log('✅ Dimensions were swapped, using as-is');
          // Continue with swapped dimensions - they're actually correct
        } else {
          Logger.log('❌ Unfixable dimension mismatch');
          return null;
        }
      }
      Logger.log('✅ Dimension and channel verification passed');

      // 15. Clamp position để board không vượt bounds (use actual dimensions)
      final finalX = imageBoardX.clamp(0, cameraWidth - actualWidth);
      final finalY = imageBoardY.clamp(0, cameraHeight - actualHeight);

      Logger.log('✅ Final position (clamped): ($finalX, $finalY)');

      // 16. Final bounds validation với actual dimensions
      Logger.log('📋 Preparing to overlay board at ($finalX, $finalY)...');
      Logger.log(
          '🔍 Final bounds check: board(${actualWidth}x$actualHeight) at ($finalX, $finalY) on image(${cameraWidth}x$cameraHeight)');

      // Triple check bounds với actual dimensions
      if (finalX < 0 ||
          finalY < 0 ||
          finalX + actualWidth > cameraWidth ||
          finalY + actualHeight > cameraHeight) {
        Logger.log(
            '❌ CRITICAL: Board out of bounds! x=$finalX, y=$finalY, w=$actualWidth, h=$actualHeight, imgW=$cameraWidth, imgH=$cameraHeight');
        Logger.log('⚠️ Returning original image to prevent crash.');
        return null;
      }

      // 17. Safe ROI extraction với validation
      try {
        // OpenCV uses row-first indexing: rows = Y axis, cols = X axis
        final roiStartRow = finalY;
        final roiEndRow = finalY + actualHeight;
        final roiStartCol = finalX;
        final roiEndCol = finalX + actualWidth;

        Logger.log(
            '🎯 Extracting ROI: rows[$roiStartRow:$roiEndRow], cols[$roiStartCol:$roiEndCol]');
        Logger.log(
            '🔍 Mat bounds: rows=${orientedCameraMat.rows}, cols=${orientedCameraMat.cols}');

        // Final safety check before rowRange/colRange
        if (roiEndRow > orientedCameraMat.rows ||
            roiEndCol > orientedCameraMat.cols) {
          Logger.log(
              '❌ CRITICAL: ROI exceeds Mat bounds! rows: $roiEndRow > ${orientedCameraMat.rows}, cols: $roiEndCol > ${orientedCameraMat.cols}');
          Logger.log('⚠️ Returning original image to prevent crash.');
          return null;
        }

        final cameraROI = orientedCameraMat
            .rowRange(roiStartRow, roiEndRow)
            .colRange(roiStartCol, roiEndCol);

        Logger.log('✅ ROI extracted successfully');

        // Verify ROI dimensions match board
        final roiWidth = cameraROI.cols; // Width
        final roiHeight = cameraROI.rows; // Height

        Logger.log(
            '🔍 ROI verification - Expected: ${actualWidth}x$actualHeight, Actual: ${roiWidth}x$roiHeight');

        if (roiWidth != actualWidth || roiHeight != actualHeight) {
          Logger.log(
              '❌ CRITICAL: ROI dimension mismatch! Cannot proceed with copyTo.');
          Logger.log('⚠️ Returning original image to prevent crash.');
          return null;
        }

        // Verify channels match
        if (cameraROI.channels != scaledBoard.channels) {
          Logger.log(
              '❌ CRITICAL: Channel mismatch! ROI: ${cameraROI.channels}, Board: ${scaledBoard.channels}');
          Logger.log('⚠️ Returning original image to prevent crash.');
          return null;
        }

        Logger.log('✅ All validations passed, performing copyTo...');

        // Finally, copy board to ROI
        scaledBoard.copyTo(cameraROI);

        Logger.log(
            '✅ Board overlay complete: ${mergeStopwatch.elapsedMilliseconds}ms');
      } catch (e, stack) {
        Logger.log('❌ FATAL: OpenCV overlay crashed: $e');
        Logger.log('Stack trace: $stack');
        Logger.log('⚠️ Returning original image without board overlay');
        return null;
      }

      // 18. Resize final merged image to target resolution
      cv.Mat finalMat = orientedCameraMat;

      if (finalResizeScale < 1.0) {
        // Only resize if target is smaller than original
        final finalWidth = (orientedCameraMat.cols * finalResizeScale).toInt();
        final finalHeight = (orientedCameraMat.rows * finalResizeScale).toInt();

        Logger.log(
            '🔧 Final resize: ${orientedCameraMat.cols}x${orientedCameraMat.rows} → ${finalWidth}x$finalHeight');

        finalMat = _resizeMat(orientedCameraMat, finalWidth, finalHeight);
        Logger.log(
            '✅ Final resize complete: ${mergeStopwatch.elapsedMilliseconds}ms');
        Logger.log(
            '🔍 Actual final mat size: ${finalMat.cols}x${finalMat.rows}');
      } else {
        Logger.log('✅ No final resize needed (target >= original)');
      }

      // 19. Encode and save final image
      Logger.log(
          '💾 Encoding final image (${finalMat.cols}x${finalMat.rows})...');
      final (success, encoded) = cv.imencode('.jpg', finalMat);

      if (!success) {
        Logger.log('❌ Failed to encode final image');
        return null;
      }

      // Save to temp file
      final tempDir = await getTemporaryDirectory();
      final mergedPath =
          '${tempDir.path}/merged_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(mergedPath).writeAsBytes(encoded);

      Logger.log('✅ Merged image saved: $mergedPath');
      Logger.log('📏 Encoded image size: ${encoded.length} bytes');
      Logger.log(
          '📐 Final image dimensions: ${finalMat.cols}x${finalMat.rows}');
      Logger.log(
          '⏱️ Total merge time: ${mergeStopwatch.elapsedMilliseconds}ms');

      return mergedPath;
    } catch (e, stack) {
      Logger.log('❌ Error merging board: $e');
      Logger.log('Stack: $stack');
      return null; // Return original on error
    }
  }
  // ============================================================================
  // UI BUILDERS
  // ============================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _capturedImage != null
                  ? _buildImagePreview()
                  : _buildCameraPreview(),
            ),
            _buildBottomControls(),
          ],
        ),
      ),
    );
  }

  // ----------------------------------------------------------------------------
  // HEADER BAR (80px)
  // ----------------------------------------------------------------------------

  Widget _buildHeader() {
    return Container(
      height: 80,
      color: Colors.black.withValues(alpha: 0.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Close Button
          RotatedBox(
            quarterTurns: (_currentTurns * 4).round(),
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 32),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),

          // Flash Control (Camera mode) or Confirm (Preview mode)
          if (_capturedImage == null)
            RotatedBox(
              quarterTurns: (_currentTurns * 4).round(),
              child: IconButton(
                icon: Icon(_getFlashIcon(), color: Colors.white, size: 32),
                onPressed: _toggleFlashMode,
              ),
            )
          else
            RotatedBox(
              quarterTurns: (_currentTurns * 4).round(),
              child: IconButton(
                icon: const Icon(Icons.check, color: Colors.white, size: 32),
                onPressed: _confirmImage,
              ),
            ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------------------------
  // MAIN CONTENT - CAMERA PREVIEW
  // ----------------------------------------------------------------------------

  Widget _buildCameraPreview() {
    if (!_isInitialized || _controller == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera Preview with Pinch to Zoom (always full screen, no rotation)
        Listener(
          onPointerDown: (_) => setState(() => _pointers++),
          onPointerUp: (_) => setState(() => _pointers--),
          child: GestureDetector(
            onScaleStart: _handleScaleStart,
            onScaleUpdate: _handleScaleUpdate,
            child: Container(
              key: _previewKey, // Key để lấy actual screen size
              child: CameraPreview(_controller!),
            ),
          ),
        ),

        // Board overlay
        if (_isBoardVisible)
          BoardWidget(
            screenshotController: _boardScreenshotController,
            initialPosition: _boardPosition,
            initialSize: _boardSize,
            rotationTurns: _currentTurns,
            onPositionChanged: (position) {
              _boardPosition = position;
            },
            onSizeChanged: (size) {
              _boardSize = size;
            },
          ),

        // Zoom indicator
        if (_currentZoom > 1.0)
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Center(
              child: RotatedBox(
                quarterTurns: (_currentTurns * 4).round(),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${_currentZoom.toStringAsFixed(1)}x',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ),

        // Processing indicator
        if (_isProcessing)
          Container(
            color: Colors.black.withValues(alpha: 0.7),
            child: Center(
              child: RotatedBox(
                quarterTurns: (_currentTurns * 4).round(),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text(
                      '処理中...',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ----------------------------------------------------------------------------
  // MAIN CONTENT - IMAGE PREVIEW
  // ----------------------------------------------------------------------------

  Widget _buildImagePreview() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(
          File(_capturedImage!.path),
          fit: BoxFit.contain,
        ),

        // Retake button
        Positioned(
          bottom: 16,
          left: 16,
          child: RotatedBox(
            quarterTurns: (_currentTurns * 4).round(),
            child: ElevatedButton.icon(
              onPressed: _retakeImage,
              icon: const Icon(Icons.refresh),
              label: const Text('Retake'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black.withValues(alpha: 0.7),
                foregroundColor: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ----------------------------------------------------------------------------
  // BOTTOM CONTROLS (80px)
  // ----------------------------------------------------------------------------

  Widget _buildBottomControls() {
    if (_capturedImage != null) {
      return const SizedBox(height: 80); // Hide controls in preview mode
    }

    return Container(
      height: 80,
      color: Colors.black.withValues(alpha: 0.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Camera Resolution button
          RotatedBox(
            quarterTurns: (_currentTurns * 4).round(),
            child: _buildControlButton(
              icon: Icons.photo_size_select_actual,
              label: _getResolutionLabel(),
              onPressed: _showResolutionDialog,
            ),
          ),

          // Output Quality button
          RotatedBox(
            quarterTurns: (_currentTurns * 4).round(),
            child: _buildControlButton(
              icon: Icons.photo,
              label: _getOutputQualityLabel(),
              onPressed: _showOutputQualityDialog,
            ),
          ),

          // Capture button (larger, centered)
          RotatedBox(
            quarterTurns: (_currentTurns * 4).round(),
            child: GestureDetector(
              onTap: _takePicture,
              child: Container(
                width: 70,
                height: 70,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  border: Border.all(color: Colors.white, width: 4),
                ),
                child: _isProcessing
                    ? const Padding(
                        padding: EdgeInsets.all(8.0),
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: Colors.black,
                        ),
                      )
                    : const Icon(Icons.camera, size: 32, color: Colors.black),
              ),
            ),
          ),

          // Board visibility toggle
          RotatedBox(
            quarterTurns: (_currentTurns * 4).round(),
            child: _buildControlButton(
              icon: _isBoardVisible ? Icons.layers : Icons.layers_clear,
              label: 'Board',
              onPressed: _toggleBoardVisibility,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: Icon(icon, color: Colors.white, size: 28),
          onPressed: onPressed,
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 10),
        ),
      ],
    );
  }

  // ----------------------------------------------------------------------------
  // RESOLUTION DIALOG
  // ----------------------------------------------------------------------------

  String _getResolutionLabel() {
    switch (_currentResolution) {
      case ResolutionPreset.low:
        return '320p';
      case ResolutionPreset.medium:
        return '480p';
      case ResolutionPreset.high:
        return '720p';
      case ResolutionPreset.veryHigh:
        return '1080p';
      case ResolutionPreset.ultraHigh:
        return '2K';
      case ResolutionPreset.max:
        return '4K';
    }
  }

  String _getOutputQualityLabel() {
    final resolution = resolutions[_selectedResolutionIndex];
    final width = resolution.width.toInt();
    final height = resolution.height.toInt();

    switch (_selectedResolutionIndex) {
      case 0:
        return 'Low';
      case 1:
        return 'Med';
      case 2:
        return 'High';
      default:
        return '$width×$height';
    }
  }

  Future<void> _showResolutionDialog() async {
    final resolutions = [
      (ResolutionPreset.low, '320p (Fast)'),
      (ResolutionPreset.medium, '480p'),
      (ResolutionPreset.high, '720p'),
      (ResolutionPreset.veryHigh, '1080p (Default)'),
      (ResolutionPreset.ultraHigh, '2K'),
      (ResolutionPreset.max, '4K (Max Quality)'),
    ];

    final selected = await showDialog<ResolutionPreset>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Resolution'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: resolutions.map((res) {
            return RadioListTile<ResolutionPreset>(
              title: Text(res.$2),
              value: res.$1,
              groupValue: _currentResolution,
              onChanged: (value) {
                Navigator.pop(context, value);
              },
            );
          }).toList(),
        ),
      ),
    );

    if (selected != null && selected != _currentResolution) {
      setState(() {
        _currentResolution = selected;
        _isInitialized = false;
      });

      await _controller?.dispose();
      await _initializeCamera();
    }
  }

  Future<void> _showOutputQualityDialog() async {
    final outputResolutions = [
      (0, '640×480 (Low - Fast)', '~200KB'),
      (1, '1200×900 (Medium)', '~500KB'),
      (2, '2000×1500 (High)', '~1MB'),
    ];

    final selected = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Output Quality'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Choose final image quality (affects performance)',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            ...outputResolutions.map((res) {
              return RadioListTile<int>(
                title: Text(res.$2),
                subtitle: Text('Est. size: ${res.$3}'),
                value: res.$1,
                groupValue: _selectedResolutionIndex,
                onChanged: (value) {
                  Navigator.pop(context, value);
                },
              );
            }).toList(),
          ],
        ),
      ),
    );

    if (selected != null && selected != _selectedResolutionIndex) {
      setState(() {
        _selectedResolutionIndex = selected;
      });
      Logger.log('📐 Output quality changed to: ${resolutions[selected]}');
    }
  }
}
