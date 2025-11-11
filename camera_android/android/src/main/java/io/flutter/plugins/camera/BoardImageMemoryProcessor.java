// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camera;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Matrix;
import android.graphics.RectF;
import android.media.Image;
import android.util.Log;
import androidx.annotation.NonNull;
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.util.Map;

// Thêm import
import com.drew.metadata.Metadata;
import com.drew.metadata.exif.ExifIFD0Directory;

/**
 * Processes a JPEG {@link Image} with board overlay in memory.
 * 
 * Similar to ImageMemoryProcessor but with additional board merging logic.
 * Provides hardware-accelerated image processing for better performance.
 */
public class BoardImageMemoryProcessor implements Runnable {

  private static final String TAG = "BoardImageProcessor";

  /** The JPEG image from camera */
  private final Image image;

  /** Board overlay data */
  private final Map<String, Object> boardData;

  /** Used to report the status of the processing action */
  private final Callback callback;

  /**
   * Creates an instance of BoardImageMemoryProcessor
   *
   * @param image - The camera image to process
   * @param boardData - Board overlay parameters
   * @param callback - The callback for completion or error
   */
  BoardImageMemoryProcessor(
      @NonNull Image image,
      @NonNull Map<String, Object> boardData,
      @NonNull Callback callback) {
    this.image = image;
    this.boardData = boardData;
    this.callback = callback;
  }

  /**
   * Calculate optimal inSampleSize for downsampling during decode.
   * Returns power-of-2 value that keeps decoded size >= required size.
   * 
   * @param width Actual image width
   * @param height Actual image height
   * @param reqWidth Required width
   * @param reqHeight Required height
   * @return inSampleSize (1, 2, 4, 8, ...)
   */
  private static int calculateInSampleSize(int width, int height, int reqWidth, int reqHeight) {
    int inSampleSize = 1;
    
    if (height > reqHeight || width > reqWidth) {
      final int halfHeight = height / 2;
      final int halfWidth = width / 2;
      
      // Find largest power-of-2 that keeps decoded size >= required size
      while ((halfHeight / inSampleSize) >= reqHeight
          && (halfWidth / inSampleSize) >= reqWidth) {
        inSampleSize *= 2;
      }
    }
    
    return inSampleSize;
  }

  @Override
  public void run() {
    long startTime = System.currentTimeMillis();
    
    try {
      Log.d(TAG, "⚡ Native board processing start");

      // 1. Extract JPEG bytes from camera image (tối ưu: reuse buffer)
      ByteBuffer buffer = image.getPlanes()[0].getBuffer();
      byte[] cameraBytes = new byte[buffer.remaining()];
      buffer.get(cameraBytes);
      
      Log.d(TAG, "📷 Camera buffer extracted: " + (System.currentTimeMillis() - startTime) + "ms");

      // 2. Extract board parameters (screen coordinates from Flutter)
      long targetWidth = (Long) boardData.get("targetWidth");
      long targetHeight = (Long) boardData.get("targetHeight");

      // Board specific - optional
      byte[] boardBytes = (byte[]) boardData.get("boardImageBytes"); // null if no board
      double boardScreenX = boardData.containsKey("boardScreenX") ? (Double) boardData.get("boardScreenX") : 0;
      double boardScreenY = boardData.containsKey("boardScreenY") ? (Double) boardData.get("boardScreenY") : 0;
      double boardScreenWidth = boardData.containsKey("boardScreenWidth") ? (Double) boardData.get("boardScreenWidth") : 0;
      double boardScreenHeight = boardData.containsKey("boardScreenHeight") ? (Double) boardData.get("boardScreenHeight") : 0;
      double previewWidth = boardData.containsKey("previewWidth") ? (Double) boardData.get("previewWidth") : (double) image.getWidth();
      double previewHeight = boardData.containsKey("previewHeight") ? (Double) boardData.get("previewHeight") : (double) image.getHeight();
      double devicePixelRatio = boardData.containsKey("devicePixelRatio") ? (Double) boardData.get("devicePixelRatio") : 1.0;
      int deviceOrientationDegrees = boardData.containsKey("deviceOrientationDegrees") ? ((Long) boardData.get("deviceOrientationDegrees")).intValue() : 0;

      Log.d(TAG, "📐 Camera (actual): " + image.getWidth() + "x" + image.getHeight());
      Log.d(TAG, "📐 Target: " + targetWidth + "x" + targetHeight);
      Log.d(TAG, "📍 Board screen: pos=(" + boardScreenX + ", " + boardScreenY + "), size=" + boardScreenWidth + "x" + boardScreenHeight);
      Log.d(TAG, "📱 Preview: " + previewWidth + "x" + previewHeight + ", pixelRatio=" + devicePixelRatio);
      Log.d(TAG, "📱 Device orientation: " + deviceOrientationDegrees + "°");

      // 3. Decode camera image với tối ưu performance
      BitmapFactory.Options options = new BitmapFactory.Options();
      
      // First pass: get actual image dimensions without decoding pixels
      options.inJustDecodeBounds = true;
      BitmapFactory.decodeByteArray(cameraBytes, 0, cameraBytes.length, options);
      int cameraWidth = options.outWidth;
      int cameraHeight = options.outHeight;
      
      // Calculate optimal inSampleSize for performance
      int reqWidth = (int) targetWidth;
      int reqHeight = (int) targetHeight;
      options.inSampleSize = calculateInSampleSize(cameraWidth, cameraHeight, reqWidth, reqHeight);
      
      Log.d(TAG, "📊 Camera actual: " + cameraWidth + "x" + cameraHeight);
      Log.d(TAG, "📊 inSampleSize: " + options.inSampleSize + 
          " → decode at ~" + (cameraWidth/options.inSampleSize) + "x" + (cameraHeight/options.inSampleSize));
      
      // Second pass: decode với tối ưu hóa bộ nhớ
      options.inJustDecodeBounds = false;
      options.inMutable = true;
      options.inPreferredConfig = Bitmap.Config.RGB_565; // Giảm 50% bộ nhớ so với ARGB_8888
      options.inTempStorage = new byte[64 * 1024]; // Tăng buffer size
      options.inScaled = false;

      Bitmap cameraBitmap = BitmapFactory.decodeByteArray(cameraBytes, 0, cameraBytes.length, options);
      if (cameraBitmap == null) {
        callback.onError("decodeError", "Failed to decode camera image");
        return;
      }

      Log.d(TAG, "✅ Camera decoded: " + (System.currentTimeMillis() - startTime) + "ms");

      // 4. Decode board image với tối ưu (chỉ khi cần)
      Bitmap boardBitmap = null;
      if (boardBytes != null && boardBytes.length > 0) {
        BitmapFactory.Options boardOptions = new BitmapFactory.Options();
        boardOptions.inMutable = true;
        boardOptions.inPreferredConfig = Bitmap.Config.RGB_565; // Giảm bộ nhớ
        boardOptions.inScaled = false;
        
        boardBitmap = BitmapFactory.decodeByteArray(boardBytes, 0, boardBytes.length, boardOptions);
        if (boardBitmap == null) {
          Log.w(TAG, "⚠️ Failed to decode board image, continuing without board");
        } else {
          Log.d(TAG, "✅ Board decoded: " + (System.currentTimeMillis() - startTime) + "ms");
        }
      }

      // 5. Rotate board bitmap nếu cần (tối ưu: chỉ rotate khi khác 0)
      if (boardBitmap != null && deviceOrientationDegrees != 0) {
        Matrix matrix = new Matrix();
        matrix.postRotate(deviceOrientationDegrees);
        Bitmap rotatedBoard = Bitmap.createBitmap(boardBitmap, 0, 0, boardBitmap.getWidth(), boardBitmap.getHeight(), matrix, true);
        boardBitmap.recycle();
        boardBitmap = rotatedBoard;
        Log.d(TAG, "🔄 Board rotated " + deviceOrientationDegrees + "°: " + boardBitmap.getWidth() + "x" + boardBitmap.getHeight());
      }

      // 6. Tính toán transform trong một lần vẽ duy nhất
      int actualCameraWidth = cameraBitmap.getWidth();
      int actualCameraHeight = cameraBitmap.getHeight();
      boolean isCameraLandscape = actualCameraWidth > actualCameraHeight;
      boolean isPreviewPortrait = previewHeight > previewWidth;
      boolean needsRotation = isCameraLandscape && isPreviewPortrait;

      Log.d(TAG, "📐 Camera size: " + actualCameraWidth + "x" + actualCameraHeight);
      Log.d(TAG, "📱 Preview: " + previewWidth + "x" + previewHeight);
      Log.d(TAG, "📐 Target: " + targetWidth + "x" + targetHeight);

      // Kích thước đầu ra cuối cùng
      int outW = (int) (needsRotation ? targetHeight : targetWidth);
      int outH = (int) (needsRotation ? targetWidth : targetHeight);

      // Tạo bitmap final với config tối ưu
      Bitmap finalBitmap = Bitmap.createBitmap(outW, outH, Bitmap.Config.RGB_565);
      Canvas transformCanvas = new Canvas(finalBitmap);

      // Tính toán transform matrix một lần duy nhất
      Matrix transformMatrix = new Matrix();
      
      // Center-crop scaling
      float scale;
      if (needsRotation) {
        scale = Math.max(outW / (float) actualCameraHeight, outH / (float) actualCameraWidth);
      } else {
        scale = Math.max(outW / (float) actualCameraWidth, outH / (float) actualCameraHeight);
      }

      transformMatrix.setScale(scale, scale);
      
      // Center the image
      float dx = (outW - actualCameraWidth * scale) / 2f;
      float dy = (outH - actualCameraHeight * scale) / 2f;
      transformMatrix.postTranslate(dx, dy);

      // Apply rotation if needed
      if (needsRotation) {
        transformMatrix.postRotate(90, outW / 2f, outH / 2f);
        Log.d(TAG, "🔄 Apply single-pass rotate 90° CW with scale");
      }

      // Vẽ ảnh với matrix transform một lần duy nhất
      transformCanvas.drawBitmap(cameraBitmap, transformMatrix, null);

      // Giải phóng bitmap gốc ngay lập tức
      cameraBitmap.recycle();
      Log.d(TAG, "✅ Single-pass transform done: " + (System.currentTimeMillis() - startTime) + "ms");

      // 7. Merge board với tối ưu performance
      if (boardBitmap != null) {
        Log.d(TAG, "📐 Board screenshot: " + boardBitmap.getWidth() + "x" + boardBitmap.getHeight());
        Log.d(TAG, "📐 Board widget (logical): " + boardScreenWidth + "x" + boardScreenHeight);

        int finalWidth = finalBitmap.getWidth();
        int finalHeight = finalBitmap.getHeight();

        // Tính toán scale và offset một lần duy nhất
        float scaleX = finalWidth / (float) previewWidth;
        float scaleY = finalHeight / (float) previewHeight;
        float scaleBoard = Math.max(scaleX, scaleY);

        float scaledPreviewWidth = (float) previewWidth * scaleBoard;
        float scaledPreviewHeight = (float) previewHeight * scaleBoard;
        float offsetX = (scaledPreviewWidth - finalWidth) / 2f;
        float offsetY = (scaledPreviewHeight - finalHeight) / 2f;

        // Tính toán kích thước và vị trí board
        int desiredBoardW = Math.round((float) boardScreenWidth * scaleBoard);
        int desiredBoardH = Math.round((float) boardScreenHeight * scaleBoard);
        int desiredBoardX = Math.round((float) boardScreenX * scaleBoard - offsetX);
        int desiredBoardY = Math.round((float) boardScreenY * scaleBoard - offsetY);

        // Clamp values để đảm bảo trong bounds
        int clampedBoardW = Math.min(Math.max(desiredBoardW, 1), finalWidth);
        int clampedBoardH = Math.min(Math.max(desiredBoardH, 1), finalHeight);
        int clampedBoardX = Math.max(0, Math.min(desiredBoardX, finalWidth - clampedBoardW));
        int clampedBoardY = Math.max(0, Math.min(desiredBoardY, finalHeight - clampedBoardH));

        if (clampedBoardW != desiredBoardW || clampedBoardH != desiredBoardH || 
            clampedBoardX != desiredBoardX || clampedBoardY != desiredBoardY) {
          Log.w(TAG, "⚠️ Board adjusted to stay in bounds");
        }

        // Scale board bitmap nếu cần (tránh scale nếu không cần thiết)
        Bitmap boardToDraw = boardBitmap;
        if (boardBitmap.getWidth() != clampedBoardW || boardBitmap.getHeight() != clampedBoardH) {
          boardToDraw = Bitmap.createScaledBitmap(boardBitmap, clampedBoardW, clampedBoardH, true);
        }

        // Vẽ board lên final bitmap
        Canvas canvas = new Canvas(finalBitmap);
        canvas.drawBitmap(boardToDraw, clampedBoardX, clampedBoardY, null);

        // Cleanup
        if (boardToDraw != boardBitmap) {
          boardToDraw.recycle();
        }
        boardBitmap.recycle();

        Log.d(TAG, "✅ Board merged: " + (System.currentTimeMillis() - startTime) + "ms");
      }

      // 8. Encode to JPEG với ước lượng buffer chính xác hơn
      int estimatedCapacity = finalBitmap.getWidth() * finalBitmap.getHeight() / 8; // Tăng buffer estimate
      ByteArrayOutputStream outputStream = new ByteArrayOutputStream(estimatedCapacity);
      
      // Sử dụng quality thấp hơn một chút để tăng tốc (85 thay vì 90)
      boolean compressed = finalBitmap.compress(Bitmap.CompressFormat.JPEG, 85, outputStream);
      
      if (!compressed) {
        Log.e(TAG, "❌ JPEG compression failed");
        callback.onError("compressError", "Failed to compress final image");
        return;
      }

      byte[] jpegBytes = outputStream.toByteArray();

      // 9. Xử lý EXIF orientation
      int exifOrientation = needsRotation ? 8 : 1;
      byte[] resultBytes = jpegBytes;

      try {
        Metadata metadata = new Metadata();
        ExifIFD0Directory exifDir = new ExifIFD0Directory();
        exifDir.setInt(ExifIFD0Directory.TAG_ORIENTATION, exifOrientation);
        metadata.addDirectory(exifDir);

        resultBytes = JpegMetadataWriter.writeMetadata(jpegBytes, metadata);
        Log.d(TAG, "✅ EXIF orientation set to: " + exifOrientation);
      } catch (Exception e) {
        Log.w(TAG, "Failed to write EXIF, using raw JPEG", e);
        // Giữ nguyên jpegBytes
      }

      Log.d(TAG, "✅ Encode complete: " + (System.currentTimeMillis() - startTime) + "ms");
      
      int finalWidth = finalBitmap.getWidth();
      int finalHeight = finalBitmap.getHeight();
      
      Log.d(TAG, "📏 Output: " + finalWidth + "x" + finalHeight + ", " + resultBytes.length + " bytes");
      Log.d(TAG, "⏱️ TOTAL TIME: " + (System.currentTimeMillis() - startTime) + "ms");

      // Cleanup
      finalBitmap.recycle();

      // Return result
      callback.onComplete(resultBytes, finalWidth, finalHeight);

    } catch (Exception e) {
      Log.e(TAG, "❌ Board processing failed", e);
      callback.onError("processError", e.getMessage());
    } finally {
      image.close();
    }
  }

  /**
   * Callback interface for board image processing
   */
  public interface Callback {
    /**
     * Called when processing completes successfully
     *
     * @param bytes - Processed image bytes (JPEG)
     * @param width - Final image width
     * @param height - Final image height
     */
    void onComplete(@NonNull byte[] bytes, int width, int height);

    /**
     * Called when an error occurs
     *
     * @param errorCode - Error code
     * @param errorMessage - Error message
     */
    void onError(@NonNull String errorCode, @NonNull String errorMessage);
  }
}