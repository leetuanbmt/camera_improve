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
      byte[] boardBytes = (byte[]) boardData.get("boardImageBytes");
      double boardScreenX = (Double) boardData.get("boardScreenX");
      double boardScreenY = (Double) boardData.get("boardScreenY");
      double boardScreenWidth = (Double) boardData.get("boardScreenWidth");
      double boardScreenHeight = (Double) boardData.get("boardScreenHeight");
      double previewWidth = (Double) boardData.get("previewWidth");
      double previewHeight = (Double) boardData.get("previewHeight");
      double devicePixelRatio = (Double) boardData.get("devicePixelRatio");
      long targetWidth = (Long) boardData.get("targetWidth");
      long targetHeight = (Long) boardData.get("targetHeight");
      int deviceOrientationDegrees = 0;
      Object orientationObj = boardData.get("deviceOrientationDegrees");
      if (orientationObj instanceof Long) {
        deviceOrientationDegrees = (int) ((Long) orientationObj).longValue();
      } else if (orientationObj instanceof Double) {
        deviceOrientationDegrees = (int) Math.round((Double) orientationObj);
      }

      Log.d(TAG, "📐 Camera (actual): " + image.getWidth() + "x" + image.getHeight());
      Log.d(TAG, "📐 Target: " + targetWidth + "x" + targetHeight);
      Log.d(TAG, "📍 Board screen: pos=(" + boardScreenX + ", " + boardScreenY + "), size=" + boardScreenWidth + "x" + boardScreenHeight);
      Log.d(TAG, "📱 Preview: " + previewWidth + "x" + previewHeight + ", pixelRatio=" + devicePixelRatio);
      Log.d(TAG, "📱 Device orientation: " + deviceOrientationDegrees + "°");

      // 3. Decode camera image (hardware accelerated)
      BitmapFactory.Options options = new BitmapFactory.Options();
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

      // 4. Decode board image
      Bitmap boardBitmap = BitmapFactory.decodeByteArray(boardBytes, 0, boardBytes.length, options);
      if (boardBitmap == null) {
        Log.w(TAG, "⚠️ Failed to decode board image, continuing without board");
        boardBitmap = null;
      } else {
        Log.d(TAG, "✅ Board decoded: " + (System.currentTimeMillis() - startTime) + "ms");
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

      // 6. Detect rotation (but DON'T rotate yet - optimize by rotating after resize)
      int actualCameraWidth = cameraBitmap.getWidth();
      int actualCameraHeight = cameraBitmap.getHeight();
      boolean isCameraLandscape = actualCameraWidth > actualCameraHeight;
      boolean isPreviewPortrait = previewHeight > previewWidth;
      boolean needsRotation = isCameraLandscape && isPreviewPortrait;
      
      Log.d(TAG, "📐 Camera size: " + actualCameraWidth + "x" + actualCameraHeight);
      Log.d(TAG, "📱 Preview: " + previewWidth + "x" + previewHeight);
      Log.d(TAG, "📐 Target: " + targetWidth + "x" + targetHeight);
      
      if (needsRotation) {
        Log.d(TAG, "🔄 Rotation detected - will resize first, then rotate (optimization)");
      }

      // 7. Resize camera to target resolution FIRST (before rotation - much faster!)
      float scaleToFillW = (float) targetWidth / cameraBitmap.getWidth();
      float scaleToFillH = (float) targetHeight / cameraBitmap.getHeight();
      float fillScale = Math.max(scaleToFillW, scaleToFillH);

      int resizedW = (int) (cameraBitmap.getWidth() * fillScale);
      int resizedH = (int) (cameraBitmap.getHeight() * fillScale);

      Log.d(TAG, "🔧 Resizing: " + cameraBitmap.getWidth() + "x" + cameraBitmap.getHeight() + " → " + resizedW + "x" + resizedH);

      Bitmap resizedBitmap = Bitmap.createScaledBitmap(cameraBitmap, resizedW, resizedH, true);
      cameraBitmap.recycle();

      // 8. Center crop to target size (still landscape orientation)
      Bitmap croppedBitmap;
      int cropOffsetX = 0;
      int cropOffsetY = 0;
      
      if (resizedW > targetWidth || resizedH > targetHeight) {
        cropOffsetX = Math.max(0, (resizedW - (int) targetWidth) / 2);
        cropOffsetY = Math.max(0, (resizedH - (int) targetHeight) / 2);

        Log.d(TAG, "✂️ Cropping: " + resizedW + "x" + resizedH + " → " + targetWidth + "x" + targetHeight);
        Log.d(TAG, "✂️ Crop offset: X=" + cropOffsetX + ", Y=" + cropOffsetY);

        croppedBitmap = Bitmap.createBitmap(resizedBitmap, cropOffsetX, cropOffsetY, (int) targetWidth, (int) targetHeight);
        resizedBitmap.recycle();
      } else {
        croppedBitmap = resizedBitmap;
      }

      Log.d(TAG, "✅ Resize complete: " + (System.currentTimeMillis() - startTime) + "ms");

      // 9. Rotate if needed (BEFORE merging board - so board stays correct orientation!)
      Bitmap orientedBitmap;
      if (needsRotation) {
        Log.d(TAG, "🔄 Rotating resized image 90° CW: " + croppedBitmap.getWidth() + "x" + croppedBitmap.getHeight());
        
        Matrix matrix = new Matrix();
        matrix.postRotate(90);
        
        orientedBitmap = Bitmap.createBitmap(croppedBitmap, 0, 0,
            croppedBitmap.getWidth(), croppedBitmap.getHeight(), matrix, true);
        
        croppedBitmap.recycle();
        Log.d(TAG, "✅ Rotated: " + orientedBitmap.getWidth() + "x" + orientedBitmap.getHeight() + 
            " (" + (System.currentTimeMillis() - startTime) + "ms)");
      } else {
        orientedBitmap = croppedBitmap;
      }

      // 10. Merge board
      Bitmap finalBitmap = orientedBitmap;

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