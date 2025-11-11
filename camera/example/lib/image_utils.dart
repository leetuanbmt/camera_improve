import 'dart:io';
import 'dart:math' as math;
import 'package:image/image.dart' as img;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';

import 'logger.dart';

/// Chụp widget `board` (dùng key) và xoay ngược về portrait chuẩn.
/// quarterTurns: số vòng xoay của RotatedBox (0–3)
Future<Uint8List?> captureBoardWithRotation({
  required GlobalKey boardKey,
  required int quarterTurns,
  double pixelRatio = 1.0,
}) async {
  final boundary =
      boardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
  if (boundary == null) {
    Logger.log('⚠️ Board boundary not found');
    return null;
  }

  // Ghi lại nội dung widget thành ui.Image
  final ui.Image originalImage = await boundary.toImage(pixelRatio: pixelRatio);

  // Nếu không cần xoay, encode luôn cho nhanh
  if (quarterTurns % 4 == 0) {
    final byteData =
        await originalImage.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  // Tính toán xoay bằng PictureRecorder (hiệu năng cao)
  final recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final double width = originalImage.width.toDouble();
  final double height = originalImage.height.toDouble();

  // Chuẩn bị transform xoay quanh tâm ảnh
  canvas.translate(width / 2, height / 2);
  canvas.rotate(-quarterTurns * math.pi / 2); // Xoay ngược hướng RotatedBox
  canvas.translate(-width / 2, -height / 2);

  // Vẽ lại ảnh
  final paint = Paint();
  canvas.drawImage(originalImage, Offset.zero, paint);

  // Hoàn tất ghi hình
  final picture = recorder.endRecording();
  final ui.Image rotatedImage = await picture.toImage(
    width.toInt(),
    height.toInt(),
  );

  final byteData =
      await rotatedImage.toByteData(format: ui.ImageByteFormat.png);
  return byteData?.buffer.asUint8List();
}

/// Đo thời gian thực thi một hàm async, trả về (result, ms)
Future<TimedResult<T>> measureExecutionTime<T>(
    Future<T> Function() func) async {
  final stopwatch = Stopwatch()..start();
  final result = await func();
  stopwatch.stop();
  return TimedResult<T>(
      result: result, milliseconds: stopwatch.elapsedMilliseconds);
}

/// Kết quả đo thời gian thực thi
class TimedResult<T> {
  TimedResult({required this.result, required this.milliseconds});
  final T result;
  final int milliseconds;
}

/// Saves image bytes as a JPEG file to a temporary directory with a unique timestamp name.
///
/// Returns the file path of the saved image.
///
/// [imageBytes]: The byte data of the image to be saved (should be in JPEG format).
///
/// Example:
/// ```dart
/// final path = await saveImage(myImageBytes);
/// print('Saved image to $path');
/// ```
Future<String> saveImage(Uint8List imageBytes) async {
  final tempDir = await getTemporaryDirectory();
  final finalImagePath =
      '${tempDir.path}/native_${DateTime.now().millisecondsSinceEpoch}.jpg';
  await File(finalImagePath).writeAsBytes(imageBytes, flush: true);
  return finalImagePath;
}

/// Returns the global bounding [Rect] of a widget associated with the given [GlobalKey].
///
/// This function calculates the rectangle in global coordinates that tightly encloses
/// the widget corresponding to [key]. It is useful for getting the absolute position
/// and size of a widget on the screen, e.g., for taking screenshots, overlaying graphics,
/// or mapping widget locations onto native camera images.
///
/// Throws an [Exception] if the widget associated with [key] cannot be found or has
/// no render size (e.g., if it is not rendered in the widget tree).
///
/// Example usage:
/// ```dart
/// final rect = getBoundingRect(myGlobalKey);
/// print('Widget position: ${rect.left}, ${rect.top}');
/// print('Widget size: ${rect.width}x${rect.height}');
/// ```
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

(double width, double height) getSizeWithImage(Uint8List data) {
  final img.Image image = img.decodeImage(data)!;
  final size = Size(image.width.toDouble(), image.height.toDouble());
  return (size.width, size.height);
}
