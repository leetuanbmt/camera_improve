// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';
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

  final GlobalKey _boardKey = GlobalKey();

  Rect getBoundingRect(GlobalKey key) {
    final renderBox = key.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      throw Exception('Cannot get render size for key');
    }

    final size = renderBox.size;
    final localCorners = [
      Offset.zero,
      Offset(size.width, 0),
      Offset(size.width, size.height),
      Offset(0, size.height),
    ];

    final globalCorners =
        localCorners.map((c) => renderBox.localToGlobal(c)).toList();

    final minX = globalCorners.map((p) => p.dx).reduce(math.min);
    final minY = globalCorners.map((p) => p.dy).reduce(math.min);
    final maxX = globalCorners.map((p) => p.dx).reduce(math.max);
    final maxY = globalCorners.map((p) => p.dy).reduce(math.max);

    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  @override
  void initState() {
    super.initState();
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

  Future<Uint8List> rotateBoard(Uint8List boardBytes, int quarterTurns) async {
    final turns = quarterTurns % 4;
    int rotateCode;
    switch (turns) {
      case 0:
        return boardBytes;
      case 1:
        rotateCode = cv.ROTATE_90_CLOCKWISE;
        break;
      case 2:
        rotateCode = cv.ROTATE_180;
        break;
      case 3:
        rotateCode = cv.ROTATE_90_COUNTERCLOCKWISE;
        break;
      default:
        return boardBytes;
    }

    final boardMat = cv.imdecode(boardBytes, cv.IMREAD_UNCHANGED);
    final rotatedMat = cv.rotate(boardMat, rotateCode);
    final (success, encoded) = cv.imencode('.jpg', rotatedMat);
    if (!success) {
      throw Exception('Failed to encode rotated board');
    }
    return encoded;
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

      if (_isBoardVisible) {
        await _captureBoardScreenshot();
        Logger.log('📊 Board capture time: ${stopwatch.elapsedMilliseconds}ms');
      }

      String? finalImagePath;

      // Try native processing first (if board visible)
      if (_isBoardVisible && _boardScreenshotBytes != null) {
        Logger.log('⚡ Attempting native board processing...');

        try {
          final stopWatch = Stopwatch()..start();
          final quarterTurns = (_currentTurns * 4).round();

          /// Sử dụng bounding rect để lấy rect đã điều chỉnh sau rotation
          final boardBoundingRect = getBoundingRect(_boardKey);
          final previewBoundingRect = getBoundingRect(_previewKey);

          final relativeLeft =
              boardBoundingRect.left - previewBoundingRect.left;
          final relativeTop = boardBoundingRect.top - previewBoundingRect.top;
          final adjustedRect = Rect.fromLTWH(
            relativeLeft,
            relativeTop,
            boardBoundingRect.width,
            boardBoundingRect.height,
          );

          final pixelRatio = MediaQuery.of(context).devicePixelRatio;
          final targetResolution = resolutions[_selectedResolutionIndex];

          final boardBytes =
              await rotateBoard(_boardScreenshotBytes!, quarterTurns);

          final boardData = BoardOverlayData(
            boardImageBytes: boardBytes,
            boardScreenX: adjustedRect.left,
            boardScreenY: adjustedRect.top,
            boardScreenWidth: adjustedRect.width,
            boardScreenHeight: adjustedRect.height,
            previewWidth: previewBoundingRect.width,
            previewHeight: previewBoundingRect.height,
            devicePixelRatio: pixelRatio,
            targetWidth: targetResolution.width.toInt(),
            targetHeight: targetResolution.height.toInt(),
            deviceOrientationDegrees:
                _getOrientationDegrees(_currentOrientation),
          );

          final image = await _controller!.captureToMemory(
            boardOverlayData: boardData,
          );

          // Save processed image
          final tempDir = await getTemporaryDirectory();
          finalImagePath =
              '${tempDir.path}/native_${DateTime.now().millisecondsSinceEpoch}.jpg';
          await File(finalImagePath).writeAsBytes(image.bytes);
        } catch (e) {
          Logger.e('Error');
        } finally {
          Logger.log(
              'Native board processing time: ${stopwatch.elapsedMilliseconds}ms');
        }
      }

      if (finalImagePath == null) {
        setState(() {
          _isProcessing = false;
        });
        return;
      }

      // finalImagePath is non-null after check
      final String imagePath = finalImagePath;

      setState(() {
        _capturedImage = XFile(imagePath);
        _isProcessing = false;
      });
    } catch (e) {
      Logger.log('Error capturing image: $e');
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _confirmImage() async {
    if (_capturedImage == null) return;

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
          // Adjust board size on orientation change
          _boardSize = _getSizeBoard(newOrientation);
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

  Size _getSizeBoard(DeviceOrientation orientation) {
    final currentSize = _boardSize;
    switch (orientation) {
      case DeviceOrientation.portraitUp:
      case DeviceOrientation.portraitDown:
        return currentSize.width > currentSize.height
            ? currentSize.flipped
            : currentSize;
      case DeviceOrientation.landscapeLeft:
      case DeviceOrientation.landscapeRight:
        return currentSize.width < currentSize.height
            ? currentSize.flipped
            : currentSize;
    }
  }

  int _getOrientationDegrees(DeviceOrientation orientation) {
    Logger.log('Orientation: $orientation');
    switch (orientation) {
      case DeviceOrientation.portraitUp:
        return 0;
      case DeviceOrientation.landscapeLeft:
        return 90;
      case DeviceOrientation.portraitDown:
        return 180;
      case DeviceOrientation.landscapeRight:
        return 270;
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
      final image =
          await _boardScreenshotController.capture(delay: Duration.zero);
      _boardScreenshotBytes = image;
    } catch (e, stack) {
      Logger.log('❌ Error capturing board: $e');
      Logger.log('Stack trace: $stack');
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
                  : LayoutBuilder(builder: (context, constraints) {
                      return _buildCameraPreview(constraints);
                    }),
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
  double cameraPreviewAspectRatio = 4 / 3;
  Size calcPreviewCamera(
    BoxConstraints constraints,
    Orientation orientation,
  ) {
    double width, height;
    final minSize = math.min(constraints.maxWidth, constraints.maxHeight);
    final maxSize = math.max(constraints.maxWidth, constraints.maxHeight);

    width = minSize;
    height = width * cameraPreviewAspectRatio;

    if (height > maxSize) {
      height = maxSize;
      width = height / cameraPreviewAspectRatio;
    }

    final calcSize = Size(width, height);

    if (orientation == Orientation.landscape) {
      return calcSize.flipped;
    }

    return calcSize;
  }

  Widget _buildCameraPreview(BoxConstraints constraints) {
    if (!_isInitialized || _controller == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    final cameraPreviewSize = _controller!.value.previewSize!;
    final calcSizePreview = calcPreviewCamera(
      constraints,
      Orientation.portrait,
    );

    return Center(
      child: SizedBox.fromSize(
        size: calcSizePreview,
        key: _previewKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Camera Preview with Pinch to Zoom (always full screen, no rotation)
            Positioned.fill(
              child: ClipRect(
                  child: AspectRatio(
                aspectRatio: cameraPreviewAspectRatio,
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox.fromSize(
                    size: cameraPreviewSize.flipped,
                    child: Listener(
                      onPointerDown: (_) => setState(() => _pointers++),
                      onPointerUp: (_) => setState(() => _pointers--),
                      child: GestureDetector(
                        onScaleStart: _handleScaleStart,
                        onScaleUpdate: _handleScaleUpdate,
                        child: CameraPreview(_controller!),
                      ),
                    ),
                  ),
                ),
              )),
            ),

            // Board overlay
            if (_isBoardVisible)
              RotatedBox(
                quarterTurns: (_currentTurns * 4).round(),
                child: Stack(
                  children: [
                    BoardWidget(
                      boardKey: _boardKey,
                      screenshotController: _boardScreenshotController,
                      initialPosition: _boardPosition,
                      initialSize: _boardSize,
                      onPositionChanged: (position) {
                        _boardPosition = position;
                      },
                      onSizeChanged: (size) {
                        _boardSize = size;
                      },
                    ),
                  ],
                ),
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
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
        ),
      ),
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
