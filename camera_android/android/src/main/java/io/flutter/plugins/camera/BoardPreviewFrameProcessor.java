package io.flutter.plugins.camera;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.ImageFormat;
import android.graphics.Matrix;
import android.graphics.Rect;
import android.graphics.YuvImage;
import android.media.Image;
import android.util.Log;
import androidx.annotation.NonNull;
import io.flutter.plugins.camera.media.ImageStreamReaderUtils;
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.util.Map;

class BoardPreviewFrameProcessor implements Runnable {
  private static final String TAG = "BoardPreviewProcessor";

  private final Image image;
  private final Map<String, Object> boardData;
  private final BoardImageMemoryProcessor.Callback callback;
  private final ImageStreamReaderUtils imageStreamReaderUtils = new ImageStreamReaderUtils();

  BoardPreviewFrameProcessor(
      @NonNull Image image,
      @NonNull Map<String, Object> boardData,
      @NonNull BoardImageMemoryProcessor.Callback callback) {
    this.image = image;
    this.boardData = boardData;
    this.callback = callback;
  }

  @Override
  public void run() {
    long startTime = System.currentTimeMillis();
    try {
      Log.d(TAG, "⚡ Processing preview frame");

      int previewWidth = image.getWidth();
      int previewHeight = image.getHeight();

      ByteBuffer nv21Buffer =
          imageStreamReaderUtils.yuv420ThreePlanesToNV21(image.getPlanes(), previewWidth, previewHeight);

      YuvImage yuvImage = new YuvImage(nv21Buffer.array(), ImageFormat.NV21, previewWidth, previewHeight, null);
      ByteArrayOutputStream jpegOutput = new ByteArrayOutputStream();
      yuvImage.compressToJpeg(new Rect(0, 0, previewWidth, previewHeight), 90, jpegOutput);
      byte[] cameraBytes = jpegOutput.toByteArray();

      BitmapFactory.Options options = new BitmapFactory.Options();
      options.inMutable = true;
      options.inPreferredConfig = Bitmap.Config.ARGB_8888;
      options.inScaled = false;

      Bitmap cameraBitmap = BitmapFactory.decodeByteArray(cameraBytes, 0, cameraBytes.length, options);
      if (cameraBitmap == null) {
        callback.onError("decodeError", "Failed to decode preview frame");
        return;
      }

      Log.d(TAG, "✅ Preview frame decoded: " + (System.currentTimeMillis() - startTime) + "ms");

      byte[] boardBytes = (byte[]) boardData.get("boardImageBytes");
      Bitmap boardBitmap = BitmapFactory.decodeByteArray(boardBytes, 0, boardBytes.length, options);
      if (boardBitmap == null) {
        Log.w(TAG, "⚠️ Failed to decode board image, returning preview only");
      } else {
        Log.d(TAG, "✅ Board decoded: " + (System.currentTimeMillis() - startTime) + "ms");
      }

      double boardScreenX = (Double) boardData.get("boardScreenX");
      double boardScreenY = (Double) boardData.get("boardScreenY");
      double boardScreenWidth = (Double) boardData.get("boardScreenWidth");
      double boardScreenHeight = (Double) boardData.get("boardScreenHeight");
      double previewLogicalWidth = (Double) boardData.get("previewWidth");
      double previewLogicalHeight = (Double) boardData.get("previewHeight");
      long targetWidth = (Long) boardData.get("targetWidth");
      long targetHeight = (Long) boardData.get("targetHeight");

      boolean needsRotation = previewWidth > previewHeight && previewLogicalHeight > previewLogicalWidth;
      Log.d(TAG, "📐 Preview frame size: " + previewWidth + "x" + previewHeight);
      Log.d(TAG, "📱 Preview logical: " + previewLogicalWidth + "x" + previewLogicalHeight);
      Log.d(TAG, "📐 Target: " + targetWidth + "x" + targetHeight);

      if (needsRotation) {
        Log.d(TAG, "🔄 Rotation detected - resize before rotate");
      }

      float scaleToFillW = (float) targetWidth / cameraBitmap.getWidth();
      float scaleToFillH = (float) targetHeight / cameraBitmap.getHeight();
      float fillScale = Math.max(scaleToFillW, scaleToFillH);

      int resizedW = (int) (cameraBitmap.getWidth() * fillScale);
      int resizedH = (int) (cameraBitmap.getHeight() * fillScale);

      Log.d(TAG, "🔧 Resizing preview: " + cameraBitmap.getWidth() + "x" + cameraBitmap.getHeight() +
          " → " + resizedW + "x" + resizedH);

      Bitmap resizedBitmap = Bitmap.createScaledBitmap(cameraBitmap, resizedW, resizedH, true);
      cameraBitmap.recycle();

      Bitmap croppedBitmap;
      if (resizedW > targetWidth || resizedH > targetHeight) {
        int cropX = Math.max(0, (resizedW - (int) targetWidth) / 2);
        int cropY = Math.max(0, (resizedH - (int) targetHeight) / 2);

        Log.d(TAG, "✂️ Cropping preview: " + resizedW + "x" + resizedH +
            " → " + targetWidth + "x" + targetHeight);

        croppedBitmap = Bitmap.createBitmap(resizedBitmap, cropX, cropY, (int) targetWidth, (int) targetHeight);
        resizedBitmap.recycle();
      } else {
        croppedBitmap = resizedBitmap;
      }

      Log.d(TAG, "✅ Resize (preview) complete: " + (System.currentTimeMillis() - startTime) + "ms");

      Bitmap orientedBitmap;
      if (needsRotation) {
        Log.d(TAG, "🔄 Rotating preview 90° CW");
        Matrix matrix = new Matrix();
        matrix.postRotate(90);
        orientedBitmap = Bitmap.createBitmap(croppedBitmap, 0, 0,
            croppedBitmap.getWidth(), croppedBitmap.getHeight(), matrix, true);
        croppedBitmap.recycle();
      } else {
        orientedBitmap = croppedBitmap;
      }

      Bitmap finalBitmap = orientedBitmap;

      if (boardBitmap != null) {
        Log.d(TAG, "📐 Board screenshot: " + boardBitmap.getWidth() + "x" + boardBitmap.getHeight());

        int finalWidth = finalBitmap.getWidth();
        int finalHeight = finalBitmap.getHeight();

        float scale = Math.max(
            finalWidth / (float) previewLogicalWidth,
            finalHeight / (float) previewLogicalHeight);

        float scaledPreviewWidth = (float) previewLogicalWidth * scale;
        float scaledPreviewHeight = (float) previewLogicalHeight * scale;
        float offsetX = (scaledPreviewWidth - finalWidth) / 2f;
        float offsetY = (scaledPreviewHeight - finalHeight) / 2f;

        int desiredBoardW = Math.round((float) boardScreenWidth * scale);
        int desiredBoardH = Math.round((float) boardScreenHeight * scale);
        int desiredBoardX = Math.round((float) boardScreenX * scale - offsetX);
        int desiredBoardY = Math.round((float) boardScreenY * scale - offsetY);

        Log.d(TAG, "🎯 Board (requested): pos=(" + desiredBoardX + ", " + desiredBoardY + "), size=" + desiredBoardW + "x" + desiredBoardH);
        Log.d(TAG, "📊 Scale (cover): " + scale + ", offsetX=" + offsetX + ", offsetY=" + offsetY);

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

        Log.d(TAG, "✅ Board merged on preview frame");

        boardBitmap.recycle();
      }

      ByteArrayOutputStream outputStream =
          new ByteArrayOutputStream(finalBitmap.getWidth() * finalBitmap.getHeight() / 10);
      boolean compressed = finalBitmap.compress(Bitmap.CompressFormat.JPEG, 90, outputStream);
      byte[] resultBytes = outputStream.toByteArray();

      if (!compressed) {
        callback.onError("compressError", "Failed to compress preview result");
        finalBitmap.recycle();
        return;
      }

      int finalWidth = finalBitmap.getWidth();
      int finalHeight = finalBitmap.getHeight();
      finalBitmap.recycle();

      Log.d(TAG, "✅ Preview capture complete: " + (System.currentTimeMillis() - startTime) + "ms");

      callback.onComplete(resultBytes, finalWidth, finalHeight);

    } catch (Exception e) {
      Log.e(TAG, "❌ Preview processing failed", e);
      callback.onError("previewProcessError", e.getMessage() == null ? "Unknown" : e.getMessage());
    } finally {
      image.close();
    }
  }
}
