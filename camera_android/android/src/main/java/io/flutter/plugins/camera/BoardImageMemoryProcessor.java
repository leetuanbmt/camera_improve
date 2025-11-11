// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camera;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Matrix;
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

      // 1. Extract JPEG bytes from camera image
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
      double previewWidth = boardData.containsKey("previewWidth") ? (Double) boardData.get("previewWidth") : (double) image.getWidth(); // Default to actual image size if no preview info
      double previewHeight = boardData.containsKey("previewHeight") ? (Double) boardData.get("previewHeight") : (double) image.getHeight();
      double devicePixelRatio = boardData.containsKey("devicePixelRatio") ? (Double) boardData.get("devicePixelRatio") : 1.0;
      int deviceOrientationDegrees = boardData.containsKey("deviceOrientationDegrees") ? ((Long) boardData.get("deviceOrientationDegrees")).intValue() : 0;

      Log.d(TAG, "📐 Camera (actual): " + image.getWidth() + "x" + image.getHeight());
      Log.d(TAG, "📐 Target: " + targetWidth + "x" + targetHeight);
      Log.d(TAG, "📍 Board screen: pos=(" + boardScreenX + ", " + boardScreenY + "), size=" + boardScreenWidth + "x" + boardScreenHeight);
      Log.d(TAG, "📱 Preview: " + previewWidth + "x" + previewHeight + ", pixelRatio=" + devicePixelRatio);
      Log.d(TAG, "📱 Device orientation: " + deviceOrientationDegrees + "°");

      // 3. Decode camera image (hardware accelerated with optimal downsampling)
      BitmapFactory.Options options = new BitmapFactory.Options();
      
      // First pass: get actual image dimensions without decoding pixels
      options.inJustDecodeBounds = true;
      BitmapFactory.decodeByteArray(cameraBytes, 0, cameraBytes.length, options);
      int cameraWidth = options.outWidth;
      int cameraHeight = options.outHeight;
      
      // Calculate optimal inSampleSize for performance
      // Target dimensions (may need rotation later, but decode at landscape size first)
      int reqWidth = (int) targetWidth;
      int reqHeight = (int) targetHeight;
      options.inSampleSize = calculateInSampleSize(cameraWidth, cameraHeight, reqWidth, reqHeight);
      
      Log.d(TAG, "📊 Camera actual: " + cameraWidth + "x" + cameraHeight);
      Log.d(TAG, "📊 inSampleSize: " + options.inSampleSize + 
          " → decode at ~" + (cameraWidth/options.inSampleSize) + "x" + (cameraHeight/options.inSampleSize));
      
      // Second pass: decode with downsampling for better performance
      options.inJustDecodeBounds = false;
      options.inMutable = true;
      options.inPreferredConfig = Bitmap.Config.ARGB_8888;
      options.inTempStorage = new byte[32 * 1024];
      options.inScaled = false;

      Bitmap cameraBitmap = BitmapFactory.decodeByteArray(cameraBytes, 0, cameraBytes.length, options);
      if (cameraBitmap == null) {
        callback.onError("decodeError", "Failed to decode camera image");
        return;
      }

      Log.d(TAG, "✅ Camera decoded: " + (System.currentTimeMillis() - startTime) + "ms");

      // 4. Decode board image (with separate options - no downsampling)
      Bitmap boardBitmap = null;
      if (boardBytes != null) {
        BitmapFactory.Options boardOptions = new BitmapFactory.Options();
        boardOptions.inMutable = true;
        boardOptions.inPreferredConfig = Bitmap.Config.ARGB_8888;
        boardOptions.inScaled = false;
        
        boardBitmap = BitmapFactory.decodeByteArray(boardBytes, 0, boardBytes.length, boardOptions);
        if (boardBitmap == null) {
          Log.w(TAG, "⚠️ Failed to decode board image, continuing without board");
        } else {
          Log.d(TAG, "✅ Board decoded: " + (System.currentTimeMillis() - startTime) + "ms");
        }
      }

      // 5. Rotate board bitmap in native based on orientation
      if (boardBitmap != null) {
        Matrix matrix = new Matrix();
        matrix.postRotate(deviceOrientationDegrees);
        Bitmap rotatedBoard = Bitmap.createBitmap(boardBitmap, 0, 0, boardBitmap.getWidth(), boardBitmap.getHeight(), matrix, true);
        boardBitmap.recycle();
        boardBitmap = rotatedBoard;
        Log.d(TAG, "🔄 Board rotated " + deviceOrientationDegrees + "°: " + boardBitmap.getWidth() + "x" + boardBitmap.getHeight());
      }

      // 6. Tính toán xoay và thực hiện gộp (resize + crop + rotate) trong một lần vẽ bằng Canvas
      int actualCameraWidth = cameraBitmap.getWidth();
      int actualCameraHeight = cameraBitmap.getHeight();
      boolean isCameraLandscape = actualCameraWidth > actualCameraHeight;
      boolean isPreviewPortrait = previewHeight > previewWidth;
      boolean needsRotation = isCameraLandscape && isPreviewPortrait;

      Log.d(TAG, "📐 Camera size: " + actualCameraWidth + "x" + actualCameraHeight);
      Log.d(TAG, "📱 Preview: " + previewWidth + "x" + previewHeight);
      Log.d(TAG, "📐 Target: " + targetWidth + "x" + targetHeight);

      // Kích thước đầu ra cuối cùng (đổi chiều nếu cần xoay)
      int outW = (int) (needsRotation ? targetHeight : targetWidth);
      int outH = (int) (needsRotation ? targetWidth : targetHeight);

  Bitmap finalBitmap = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888);
  Canvas transformCanvas = new Canvas(finalBitmap);

      // Dịch tọa độ về tâm để dễ xoay/scale/crop
  transformCanvas.translate(outW / 2f, outH / 2f);

      // Tính scale theo chiến lược fill (center-crop)
      float imageScale;
      if (needsRotation) {
        // Sau khi xoay 90°, chiều rộng/chiều cao của ảnh nguồn sẽ hoán đổi
        imageScale = Math.max(outW / (float) actualCameraHeight, outH / (float) actualCameraWidth);
      } else {
        imageScale = Math.max(outW / (float) actualCameraWidth, outH / (float) actualCameraHeight);
      }

      if (needsRotation) {
        Log.d(TAG, "🔄 Apply single-pass rotate 90° CW with scale");
        transformCanvas.rotate(90f);
      }
      transformCanvas.scale(imageScale, imageScale);

      // Vẽ ảnh gốc vào tâm canvas (center-crop tự nhiên do phần vượt ra ngoài bị cắt)
  transformCanvas.drawBitmap(cameraBitmap, -actualCameraWidth / 2f, -actualCameraHeight / 2f, null);

      // Giải phóng bitmap gốc sau khi đã vẽ xong
      cameraBitmap.recycle();
      Log.d(TAG, "✅ Single-pass transform done: " + (System.currentTimeMillis() - startTime) + "ms");

      // 10. Merge board (vẫn giữ logic tính toạ độ như cũ, dựa trên finalWidth/Height)

      if (boardBitmap != null) {
        Log.d(TAG, "📐 Board screenshot: " + boardBitmap.getWidth() + "x" + boardBitmap.getHeight());
        Log.d(TAG, "📐 Board widget (logical): " + boardScreenWidth + "x" + boardScreenHeight);

        int finalWidth = finalBitmap.getWidth();
        int finalHeight = finalBitmap.getHeight();

        float scaleX = finalWidth / (float) previewWidth;
        float scaleY = finalHeight / (float) previewHeight;
        float scale = Math.max(scaleX, scaleY);

        float scaledPreviewWidth = (float) previewWidth * scale;
        float scaledPreviewHeight = (float) previewHeight * scale;
        float offsetX = (scaledPreviewWidth - finalWidth) / 2f;
        float offsetY = (scaledPreviewHeight - finalHeight) / 2f;

        int desiredBoardW = Math.round((float) boardScreenWidth * scale);
        int desiredBoardH = Math.round((float) boardScreenHeight * scale);
        int desiredBoardX = Math.round((float) boardScreenX * scale - offsetX);
        int desiredBoardY = Math.round((float) boardScreenY * scale - offsetY);

        Log.d(
            TAG,
            "🎯 Board (requested): pos=("
                + desiredBoardX
                + ", "
                + desiredBoardY
                + "), size="
                + desiredBoardW
                + "x"
                + desiredBoardH);
        Log.d(TAG, "📊 Scale: " + scale + ", offsetX=" + offsetX + ", offsetY=" + offsetY);

        int clampedBoardW = Math.min(Math.max(desiredBoardW, 1), finalWidth);
        int clampedBoardH = Math.min(Math.max(desiredBoardH, 1), finalHeight);
        int clampedBoardX = Math.max(0, Math.min(desiredBoardX, finalWidth - clampedBoardW));
        int clampedBoardY = Math.max(0, Math.min(desiredBoardY, finalHeight - clampedBoardH));

        if (clampedBoardW != desiredBoardW
            || clampedBoardH != desiredBoardH
            || clampedBoardX != desiredBoardX
            || clampedBoardY != desiredBoardY) {
          Log.w(
              TAG,
              "⚠️ Board adjusted to stay in bounds: pos=("
                  + clampedBoardX
                  + ", "
                  + clampedBoardY
                  + "), size="
                  + clampedBoardW
                  + "x"
                  + clampedBoardH);
        }

        Bitmap boardToDraw = boardBitmap;
        if (boardBitmap.getWidth() != clampedBoardW
            || boardBitmap.getHeight() != clampedBoardH) {
          boardToDraw =
              Bitmap.createScaledBitmap(boardBitmap, clampedBoardW, clampedBoardH, true);
          Log.d(
              TAG,
              "🔧 Scaled board bitmap: "
                  + boardBitmap.getWidth()
                  + "x"
                  + boardBitmap.getHeight()
                  + " → "
                  + clampedBoardW
                  + "x"
                  + clampedBoardH);
        }

        Canvas canvas = new Canvas(finalBitmap);
        canvas.drawBitmap(boardToDraw, clampedBoardX, clampedBoardY, null);

        if (boardToDraw != boardBitmap) {
          boardToDraw.recycle();
        }

        Log.d(TAG, "✅ Board merged: " + (System.currentTimeMillis() - startTime) + "ms");

        boardBitmap.recycle();
      }

      // 11. Encode to JPEG
      int estimatedCapacity = finalBitmap.getWidth() * finalBitmap.getHeight() / 10;
      ByteArrayOutputStream outputStream = new ByteArrayOutputStream(estimatedCapacity);
      boolean compressed = finalBitmap.compress(Bitmap.CompressFormat.JPEG, 90, outputStream);
      byte[] resultBytes = outputStream.toByteArray();

      if (!compressed) {
        Log.e(TAG, "❌ JPEG compression failed");
        callback.onError("compressError", "Failed to compress final image");
        return;
      }

      byte[] jpegBytes = outputStream.toByteArray();

      // Set EXIF orientation based on device orientation for PDF compatibility
      // Android camera outputs portrait images, but when device is landscape,
      // we rotated the image 90° CW, so we need EXIF to tell PDF to rotate back
      int exifOrientation = 1; // Default: top-left (normal)
      
      if (needsRotation) {
          // Image was rotated 90° CW (landscape → portrait)
          // PDF reader should rotate -90° (=270° CW) to view correctly
          // EXIF 8 = rotate 270° CW = rotate -90°
          exifOrientation = 8;
          Log.d(TAG, "📐 Setting EXIF 8 (rotate 270° CW) because image was rotated 90° CW");
      } else {
          // No rotation applied, image is normal portrait
          exifOrientation = 1;
          Log.d(TAG, "📐 Setting EXIF 1 (normal) - no rotation");
      }

      try {
          Metadata metadata = new Metadata();
          ExifIFD0Directory exifDir = new ExifIFD0Directory();
          exifDir.setInt(ExifIFD0Directory.TAG_ORIENTATION, exifOrientation);
          metadata.addDirectory(exifDir);

          // Ghi metadata vào JPEG
          byte[] finalBytes = JpegMetadataWriter.writeMetadata(jpegBytes, metadata);
          resultBytes = finalBytes;

          Log.d(TAG, "✅ EXIF orientation set to: " + exifOrientation);
      } catch (Exception e) {
          Log.w(TAG, "Failed to write EXIF, using raw JPEG", e);
          resultBytes = jpegBytes; // Fallback
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