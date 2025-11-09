# PERFORMANCE & DISPLAY FIXES NEEDED

**Date**: 2025-01-07  
**Status**: 🔴 Issues Found - Fixes Required

---

## 📊 Current Performance Results

```
✅ Camera capture time: 795ms
🔄 Board merge time: 550ms
⏱️ TOTAL TIME: 1346ms
```

**Problems:**
- ❌ Total 1346ms > Target 500ms (chậm gấp 2.7x)
- ❌ Board không hiển thị trong ảnh preview

---

## 🐛 Issue 1: Board Không Hiển Thị

### Root Cause Analysis

**Board size:** 563x844 (screen pixels)  
**Image size:** 3840x2160 (4K resolution)

**Board chỉ chiếm:**
- Width: 563/3840 = 14.6% của image width
- Height: 844/2160 = 39% của image height

**Vị trí merge:** (960, 540) - center-ish
- Tương đối nhỏ so với toàn bộ ảnh 4K

### Fix 1: Scale Board Size

Board cần được scale up để hiển thị rõ trên ảnh 4K:

```dart
// Current: Board size giữ nguyên 563x844
final boardWidth = boardSize[0];  // 563
final boardHeight = boardSize[1]; // 844

// Fix: Scale board lên 2-3 lần
final scaleFactor = 2.5; // Adjust based on testing
final targetBoardWidth = (boardWidth * scaleFactor).toInt();
final targetBoardHeight = (boardHeight * scaleFactor).toInt();

// Resize board before merging
cv.Mat resizedBoard = cv.resize(
  boardBGR,
  (targetBoardWidth, targetBoardHeight),
  interpolation: cv.INTER_LINEAR,
);
```

### Fix 2: Better Position Calculation

```dart
// Current: Fixed position
final x = (cameraWidth / 4).toInt(); // 960
final y = (cameraHeight / 4).toInt(); // 540

// Fix: Use board screen position scaled to image coordinates
// Get preview size
final previewWidth = _controller!.value.previewSize!.width;
final previewHeight = _controller!.value.previewSize!.height;

// Calculate scale factors
final scaleX = cameraWidth / previewWidth;
final scaleY = cameraHeight / previewHeight;

// Map board position to image coordinates
final x = (boardPos.dx * scaleX).toInt();
final y = (boardPos.dy * scaleY).toInt();
```

### Fix 3: Verify Preview Shows Merged Image

Check `_buildImagePreview()`:

```dart
Widget _buildImagePreview() {
  return Stack(
    fit: StackFit.expand,
    children: [
      Image.file(
        File(_capturedImage!.path), // ✅ Should show merged image
        fit: BoxFit.contain,
      ),
      // ...
    ],
  );
}
```

**Verify:** `_capturedImage.path` points to merged image, not original.

---

## ⚡ Issue 2: Performance Too Slow

### Breakdown

```
Camera capture:    795ms   (59%)
Board merge:       550ms   (41%)
  ├─ Load camera:  310ms   (56%)
  ├─ Decode board: 323ms   (59%)
  ├─ Convert RGBA: 330ms   (60%)
  ├─ Copy ROI:     336ms   (61%)
  └─ Encode JPEG:  549ms   (100%)
──────────────────────────────────
TOTAL:            1346ms
```

### Performance Issues

1. **Image size too large: 3840x2160 (4K)**
   - 8.3 megapixels
   - Too much data to process

2. **Multiple decode/encode cycles**
   - Camera → save → load → merge → save
   - 2x file I/O operations

3. **RGBA → BGR conversion slow**
   - Board screenshot is PNG (RGBA)
   - Conversion takes 30ms+

### Fix 1: Reduce Camera Resolution

Change from `ResolutionPreset.veryHigh` (4K) to `ResolutionPreset.high` (720p):

```dart
ResolutionPreset _currentResolution = ResolutionPreset.high; // 720p
```

**Expected improvement:**
- Image size: 3840x2160 → 1280x720
- Pixels: 8.3MP → 0.9MP (91% reduction)
- Processing time: 550ms → 150ms (73% faster)

### Fix 2: Optimize Board Screenshot

Capture board at lower resolution:

```dart
await _boardScreenshotController.capture(
  pixelRatio: 1.0, // Default is 2.0
);
```

**Expected improvement:**
- Board size: 563x844 → 281x422
- Decode time: 323ms → 80ms (75% faster)

### Fix 3: Skip Intermediate Save

Don't save camera image to file first:

```dart
// Current flow:
// 1. takePicture() → saves to file
// 2. Load from file
// 3. Merge
// 4. Save merged

// Optimized flow:
// 1. takePicture() → get bytes directly
// 2. Decode bytes
// 3. Merge
// 4. Save merged
```

**Expected improvement:**
- Save 1 I/O operation (~100-200ms)

---

## 🎯 Expected Results After Fixes

### With Resolution Reduction

```
Camera capture (720p):   200ms   ✅
Board merge:
  ├─ Load camera:         50ms
  ├─ Decode board:        40ms
  ├─ Scale board:         20ms
  ├─ Convert RGBA:        15ms
  ├─ Copy ROI:            10ms
  └─ Encode JPEG:         80ms
──────────────────────────────────
TOTAL:                  ~415ms   ✅ (within target!)
```

### Performance Gains

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Camera capture | 795ms | 200ms | -75% ⬇️ |
| Board merge | 550ms | 215ms | -61% ⬇️ |
| **TOTAL** | **1346ms** | **415ms** | **-69% ⬇️** |

---

## 🔧 Implementation Priority

### Priority 1: Fix Display (CRITICAL)

1. ✅ **Scale board size** (2-3x larger)
   ```dart
   final scaleFactor = 2.5;
   cv.resize(boardBGR, (width * scale, height * scale));
   ```

2. ✅ **Verify preview shows merged image**
   ```dart
   setState(() {
     _capturedImage = XFile(finalImagePath!); // Merged path
   });
   ```

### Priority 2: Fix Performance (HIGH)

1. ✅ **Reduce resolution to 720p**
   ```dart
   ResolutionPreset _currentResolution = ResolutionPreset.high;
   ```

2. ✅ **Reduce board screenshot quality**
   ```dart
   pixelRatio: 1.0
   ```

### Priority 3: Advanced Optimizations (MEDIUM)

1. **Better position mapping**
   - Map screen coords → image coords

2. **Skip intermediate I/O**
   - Process bytes directly

3. **Parallel processing**
   - Capture camera + board simultaneously

---

## 📝 Quick Fix Code

### Fix Board Display

```dart
// In _mergeBoardWithCameraImage()

// After decoding board:
final boardSize = boardMat.size;
final boardWidth = boardSize[0];
final boardHeight = boardSize[1];

// Scale board up for visibility
final scaleFactor = 2.5;
final targetWidth = (boardWidth * scaleFactor).toInt();
final targetHeight = (boardHeight * scaleFactor).toInt();

Logger.log('🔧 Scaling board from ${boardWidth}x${boardHeight} to ${targetWidth}x$targetHeight');

// Resize board
cv.Mat scaledBoard = cv.resize(
  boardBGR,
  (targetWidth, targetHeight),
  interpolation: cv.INTER_LINEAR,
);

// Use scaledBoard instead of boardBGR for merging
```

### Fix Performance

```dart
// In initState() or resolution selector:
ResolutionPreset _currentResolution = ResolutionPreset.high; // 720p instead of veryHigh
```

---

## ✅ Testing Checklist

After implementing fixes:

- [ ] Board hiển thị rõ ràng trong ảnh preview
- [ ] Board position đúng chỗ
- [ ] Board size hợp lý (không quá nhỏ/lớn)
- [ ] Total time < 500ms
- [ ] Camera capture < 200ms
- [ ] Board merge < 300ms
- [ ] Image quality acceptable

---

## 📊 Success Criteria

### Display

- ✅ Board visible và clear
- ✅ Board position correct
- ✅ Board size appropriate (~20-30% of image)

### Performance

- ✅ Total time: < 500ms
- ✅ Camera: < 200ms
- ✅ Merge: < 300ms
- ✅ Quality: Good enough for document

---

**Action Required**: Implement Priority 1 & 2 fixes now!  
**Expected Result**: Board visible + Performance ~400ms ✅

