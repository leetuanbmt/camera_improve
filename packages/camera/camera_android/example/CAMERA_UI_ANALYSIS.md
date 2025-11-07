# PHÂN TÍCH UI VÀ CHỨC NĂNG CAMERA PAGE

**File**: `/packages/kansuke_camera/lib/src/views/camera_page.dart`  
**Ngày phân tích**: 2025-01-07

---

## 📱 TỔNG QUAN UI LAYOUT

### Structure Layout (Column - 3 phần)

```
┌─────────────────────────────────────────┐
│  [HEADER - 80px height]                 │  ← Top Bar
│  • Close Button (Left)                  │
│  • Flash Control / Confirm (Right)      │
├─────────────────────────────────────────┤
│                                         │
│                                         │
│  [MAIN CONTENT - Expanded]              │  ← Camera/Image Preview
│  • Camera Preview hoặc                  │
│  • Image Preview                        │
│  • Blackboard Overlay                   │
│  • Wipe Area (nếu có)                   │
│  • Portrait Warning (nếu portrait)      │
│                                         │
│                                         │
├─────────────────────────────────────────┤
│  [CONTROLS - 80px height]               │  ← Bottom Control Bar
│  • Capture Button (Center)              │
│  • Resolution Button                    │
│  • Board Visibility Toggle              │
│  • Wipe Area Switch (nếu có)            │
└─────────────────────────────────────────┘
```

---

## 🎯 CHỨC NĂNG CHI TIẾT

### 1️⃣ HEADER BAR (Line 707-736)

#### A. Close Button

**Location**: Left side  
**Function**: Đóng camera page, trở về màn hình trước  
**Code**: Line 712

```dart
const CloseButton(color: Colors.white)
```

#### B. Right Action (Dynamic)

**Mode 1: Camera Mode (isImagePreview = false)**

- **Widget**: `FlashControl` (Line 727-733)
- **Function**: Điều khiển flash của camera
- **States**:
  - `FlashMode.auto` (Auto)
  - `FlashMode.on` (Always On)
  - `FlashMode.off` (Always Off)
  - `FlashMode.torch` (Torch mode)
- **Rotation**: Tự động rotate theo device orientation (`_currentTurns`)

**Mode 2: Image Preview Mode (isImagePreview = true)**

- **Widget**: Check/Confirm Button (Line 714-724)
- **Icon**: `Icons.check` (checkmark)
- **Function**: Confirm và xử lý ảnh preview
- **Action**: `_captureImage()` - Hiện tại bị comment out (line 568-593)

---

### 2️⃣ MAIN CONTENT AREA (Line 738-746)

#### Dynamic Content dựa trên Mode:

```dart
// Line 741-743
!isImagePreview
  ? _buildCameraPreview()  // Camera realtime
  : _imageView()           // Static image preview
```

---

### 3️⃣ CAMERA PREVIEW MODE (Line 804-866)

#### A. Camera Preview Core

**Widget**: `CameraPreview(_controller!)` (Line 842)
**Features**:

1. **Pinch to Zoom** (Line 836-842)

   - Gesture: 2 fingers pinch
   - Handler: `_handleScaleStart()` + `_handleScaleUpdate()`
   - Range: `minAvailableZoom` (1.0) to `maxAvailableZoom` (5.0)
   - Current zoom level: `_currentZoom`

2. **AspectRatio Management** (Line 830-831)

   - Tính toán: `cameraPreviewAspectRatio`
   - FittedBox: `BoxFit.cover` (full screen, crop edges nếu cần)

3. **Pointer Tracking** (Line 836-838)
   - Count số fingers trên screen
   - Cần 2 fingers mới zoom được

#### B. Board Overlay on Camera (Line 855-858)

**Widget**: `_boardView()` (Line 868-920)
**Components**:

1. **Wipe Area Image** (Line 894-902)

   - **Vị trí**: Right-top corner (right: 10, top: 10)
   - **Size**: 100x100
   - **Condition**: Chỉ hiện khi `widget.args.wipeAreaPaths.isNotEmpty`
   - **Widget**: `_WipeAreaImage` (Line 999-1041)
   - **Function**: Hiển thị ảnh tham khảo vùng cần chụp (e.g. sơ đồ vị trí)
   - **Types**:
     - `PhtType.none` - Không hiện
     - `PhtType.wipeArea1`, `wipeArea2`, etc.

2. **Portrait Warning** (Line 903-909)

   - **Condition**: Chỉ hiện khi `isPortrait = true`
   - **Message**: "撮影は横向きをおすすめします" (Nên chụp ở chế độ ngang)
   - **Style**: Red background với alpha 0.5
   - **Position**: Top center hoặc Bottom center (tùy orientation)
   - **Widget**: `PortraitWarning` (Line 979-997)

3. **Blackboard Widget** (Line 910-914)
   - **Widget**: `BoardWidget` (Line 932-970)
   - **Draggable**: User có thể drag và resize
   - **Features**:
     - Display blackboard background image
     - Display labels (text fields)
     - Edit button → mở `BoardInformationPage`
     - Position/Size được save vào storage
     - Screenshot controller để capture board
     - Opacity control
   - **Storage**: Save vị trí và size theo orientation (Portrait/Landscape)

---

### 4️⃣ IMAGE PREVIEW MODE (Line 769-802)

#### A. Static Image Display

**Widget**: `OptimizedImageWidget` (Line 785-791)
**Features**:

- Load image từ `widget.image!.path`
- Optimized caching với `cacheKey`
- `BoxFit.contain` - giữ nguyên aspect ratio

#### B. Board Overlay on Image

**Same as camera mode** nhưng position tính toán khác:

- Camera mode: Tính theo camera preview size
- Image mode: Tính theo actual image size

---

### 5️⃣ BOTTOM CONTROL BAR (Line 748-767)

**Widget**: `CameraControl` (custom widget)

#### Available Controls:

**A. Capture Button** (Center, Primary action)

- **Function**: `onCapture: _takePicture` (Line 758)
- **Action**:
  1. Capture camera image to memory
  2. Process với OpenCV (rotate, crop, resize)
  3. Merge blackboard overlay
  4. Save file
  5. Navigate to ImageDrawingPage
- **Thời gian**: ~1.5-2s (theo test của bạn)

**B. Resolution Button** (nếu `!widget.args.disableResolution`)

- **Function**: `onChangeResolution: _showResolutionOverlay` (Line 756-757)
- **Action**: Hiện overlay chọn resolution (Line 652-663)
- **Options** (từ `resolutions` constant):
  - 640 x 480 (VGA)
  - 1280 x 960 (1.2MP)
  - 1920 x 1440 (2.8MP) - Default
  - 2560 x 1920 (4.9MP)
- **Storage**: Save user preference

**C. Board Visibility Toggle**

- **Function**: `onVisibilityBoard` (Line 753-755)
- **Action**: Toggle `_visibilityBoard.value` (true/false)
- **Effect**: Show/Hide blackboard overlay
- **Note**: Khi capture, nếu board hidden → không merge board vào ảnh

**D. Wipe Area Switch** (nếu `widget.args.wipeAreaPaths.isNotEmpty`)

- **Function**: `onWipeAreaChanged` (Line 759-765)
- **Action**: Cycle through wipe area images
- **Types**: `PhtType.none` → `wipeArea1` → `wipeArea2` → ... → `none`

---

## 🔄 LUỒNG TƯƠNG TÁC

### Flow 1: Camera Mode - Normal Capture

```
[User opens Camera]
    ↓
[Camera initializes - ResolutionPreset.max]
    ↓
[User thấy camera preview + blackboard overlay]
    ↓
[User có thể:]
    • Pinch to zoom (1x - 5x)
    • Toggle flash mode
    • Toggle board visibility
    • Adjust board position/size (drag)
    • Change resolution
    • Edit board info (tap board edit button)
    • Switch wipe area (nếu có)
    ↓
[User tap Capture button]
    ↓
[Processing ~1.5-2s:]
    1. captureToMemory() (~100-500ms?)
    2. Pause preview
    3. processImageAndCombineWithBoard() (~1-1.5s?)
       • Rotate theo orientation
       • Crop theo preview rect
       • Resize theo target resolution
       • Screenshot board (nếu visible)
       • Merge board overlay
       • Save file
    ↓
[Navigate to ImageDrawingPage với image path]
    ↓
[User có thể vẽ thêm trên ảnh]
    ↓
[User tap 決定 (Done)]
    ↓
[Image được save vào focused inspect]
```

### Flow 2: Image Preview Mode (từ gallery)

```
[User picks image from gallery]
    ↓
[InspectionUtil.openImagePreview()]
    ↓
[CameraPage opens với widget.image != null]
    ↓
[User thấy static image + blackboard overlay]
    ↓
[User có thể:]
    • Toggle board visibility
    • Adjust board position/size
    • Edit board info
    ↓
[User tap Confirm (checkmark)]
    ↓
[_captureImage() - CURRENTLY DISABLED]
    • Code bị comment out (line 568-593)
    • Nên không có processing
    ↓
[Navigate to ImageDrawingPage]
```

---

## 🎨 BLACKBOARD WIDGET DETAILS

### Components (Line 922-973)

#### 1. Background Image

- Load từ `_backgroundFile` (path)
- Có thể là các template khác nhau (板 1, 板 2, etc.)

#### 2. Labels (Text Fields)

- Data: `List<BoardData> _labels`
- Populated từ `widget.args.labelValueArgs`:
  - `workName` (Tên công trình)
  - `reportName` (Tên báo cáo)
  - `remarks` (Ghi chú: place, bui, fgai, zsicmt)
- User có thể edit bằng cách tap vào board

#### 3. Draggable & Resizable

- User có thể drag board
- User có thể resize board (pinch?)
- Position & size được save theo:
  - `widget.args.kinoKn` (Type của board)
  - `Orientation` (Portrait/Landscape)

#### 4. Screenshot Controller

- `_boardScreenshotController` (Line 110)
- Package: `screenshot`
- Dùng để capture board thành image khi merge

#### 5. Edit Board Button

- Tap → Navigate to `BoardInformationPage`
- User có thể:
  - Edit labels
  - Change background template
  - Preview changes

---

## ⚡ DEVICE ORIENTATION HANDLING

### Auto-rotation System (Line 207-237)

#### Sensor Tracking

**Package**: `sensors_plus`  
**Subscription**: `_orientationStreamSubscription` (Line 149)

**Supported Orientations**:

```dart
DeviceOrientation.portraitUp      // 0°
DeviceOrientation.landscapeLeft   // 90° CCW (Home button right)
DeviceOrientation.landscapeRight  // 90° CW (Home button left)
DeviceOrientation.portraitDown     // 180°
```

#### Rotation Calculation

**Method**: `shortestTurnsToReachTarget()` (Line 227-232)

- Tính góc quay ngắn nhất để đạt target orientation
- Smooth animation (không nhảy cóc 180°)

#### UI Elements Rotate:

1. **Flash Control** (Line 728)
2. **Confirm Button** (Line 714)
3. **Bottom Controls** (Line 749)
4. **Board Widget** (Line 887)

#### Camera Lock

**Line 345**: `_controller?.lockCaptureOrientation(DeviceOrientation.portraitUp)`

- Camera LUÔN capture ở portrait mode
- UI rotate để match user orientation
- Processing sau đó rotate image về đúng orientation

---

## 🔧 TECHNICAL IMPLEMENTATION DETAILS

### 1. Camera Initialization (Line 326-360)

```dart
_controller = CameraController(
  descriptionCameraBack,           // Back camera
  ResolutionPreset.max,             // Highest available
  enableAudio: false,               // No audio
  imageFormatGroup: ImageFormatGroup.yuv420, // YUV format
);
```

**Settings**:

- Focus mode: `FocusMode.auto`
- Exposure mode: `ExposureMode.auto`
- Flash mode: `_flashMode` (user selected)
- Zoom level: `_currentZoom` (1.0 - 5.0)

### 2. Memory Management (Line 257-293)

**Dispose Resources**:

- Close overlay entry
- Cancel orientation subscription
- Dispose camera controller
- Clear value notifiers
- Clear image cache
- Force memory cleanup (`MemoryManager.forceCleanupIfNeeded()`)

### 3. State Management

**ValueNotifiers**:

- `_isInitialize` (Line 98) - Camera ready state
- `_visibilityBoard` (Line 129) - Board show/hide

**State Variables**:

- `_currentResolution` (Line 104) - Selected resolution
- `_currentZoom` (Line 125) - Zoom level
- `_currentWipeArea` (Line 127) - Active wipe area
- `_currentOrientation` (Line 145) - Device orientation
- `_currentTurns` (Line 147) - UI rotation value
- `_flashMode` (Line 133) - Flash setting

### 4. Keys & Controllers

**GlobalKeys**:

- `_parentKey` (Line 106) - Camera/Image container
- `_boardKey` (Line 108) - Board widget

**Controllers**:

- `_controller` (Line 131) - CameraController
- `_boardScreenshotController` (Line 110) - Board screenshot
- `_orientationStreamController` (Line 139) - Orientation stream

---

## 📊 PERFORMANCE BOTTLENECKS (Theo phân tích trước)

### Current Issues:

#### 1. Capture Process (Line 460-534)

**Total time**: ~1.5-2s

**Breakdown cần xác định**:

- `captureToMemory()`: ???ms
- `processImageAndCombineWithBoard()`: ???ms
  - Board screenshot: ???ms
  - OpenCV decode: ???ms
  - OpenCV rotate: ???ms
  - OpenCV crop: ???ms
  - OpenCV resize: ???ms
  - OpenCV overlay: ???ms
  - File write: ???ms

#### 2. Resolution Setting

**Current**: `ResolutionPreset.max`

- Có thể quá cao cho một số devices
- Trade-off: Quality vs Speed

#### 3. Board Screenshot

**pixelRatio**: 2.0 (Line 427 in camera_util.dart)

- Có thể giảm xuống 1.5 hoặc 1.0 để nhanh hơn
- Trade-off: Board quality vs Speed

---

## 🎯 UI/UX OBSERVATIONS

### ✅ Strengths:

1. **Clean Layout**: 3-part structure rõ ràng
2. **Auto-rotation**: Smooth rotation animation
3. **Board Draggable**: User có thể adjust position dễ dàng
4. **Multiple Features**: Flash, Zoom, Resolution, Board, Wipe area
5. **Portrait Warning**: Helpful reminder cho user
6. **Memory Management**: Comprehensive cleanup

### ⚠️ Weaknesses:

1. **Slow Capture**: 1.5-2s quá chậm (target: <500ms)
2. **No Progress Indicator**: User không biết đang xử lý gì
3. **Image Preview Mode Broken**: `_captureImage()` disabled
4. **No Cancel During Processing**: User phải đợi hết 2s
5. **No Feedback**: Không có sound/vibration khi capture

### 💡 Suggestions:

1. **Add Progress Indicator**:

   - Show "処理中..." (Processing...)
   - Progress bar: Capture → Process → Merge → Save

2. **Optimize Performance**:

   - Lower `ResolutionPreset` option
   - Lower board `pixelRatio`
   - Cache board screenshot nếu không thay đổi

3. **Add Haptic Feedback**:

   - Vibrate khi tap capture
   - Sound effect (optional)

4. **Fix Image Preview Mode**:

   - Uncomment và implement `_captureImage()`
   - Hoặc remove feature nếu không cần

5. **Add Cancel Button**:
   - Cho phép user cancel trong quá trình xử lý

---

## 📝 CODE QUALITY

### ✅ Good Practices:

1. **State Management**: Clear separation với ValueNotifier
2. **Memory Cleanup**: Comprehensive dispose
3. **Error Handling**: Try-catch blocks
4. **Logging**: Stopwatch timing logs
5. **Widget Separation**: Header, Main, Controls riêng biệt
6. **Comments**: Có comments giải thích logic

### ⚠️ Areas for Improvement:

1. **Magic Numbers**:

   - `height: 80` (line 686, 698) → const
   - `pixelRatio: 2` → configurable
   - `dimension: 50` (line 717) → const

2. **Long Methods**:

   - `_takePicture()` quá dài (74 lines)
   - Nên split thành smaller methods

3. **Commented Code**:

   - `_captureImage()` body disabled (line 569-592)
   - Nên remove hoặc implement

4. **Hardcoded Strings**:

   - "処理中..." → localization
   - Error messages → localization

5. **Complex Calculations**:
   - Board position logic (line 392-420) → extract to helper
   - Rotation logic → extract to helper

---

## 🔗 DEPENDENCIES

### External Packages:

- `camera` - Camera access
- `sensors_plus` - Device orientation
- `screenshot` - Board screenshot
- `opencv_core` - Image processing
- `common` - Shared utilities

### Internal Dependencies:

- `BoardWidget` - Blackboard overlay
- `CameraControl` - Bottom controls
- `FlashControl` - Flash toggle
- `BBStorage` - Board position storage
- `BlackboardService` - Board data management
- `CameraUtil` - Image processing utilities

---

## 📌 SUMMARY

**CameraPage** là một camera UI phức tạp với nhiều features:

- ✅ Realtime camera preview với zoom
- ✅ Blackboard overlay draggable
- ✅ Auto-rotation handling
- ✅ Multiple resolution options
- ✅ Wipe area reference images
- ✅ Flash control
- ⚠️ Performance issue: 1.5-2s capture time (cần optimize)
- ⚠️ Image preview mode incomplete

**Next steps để optimize**:

1. Profile chi tiết timing breakdown
2. Reduce resolution preset hoặc cho phép user chọn
3. Cache board screenshot
4. Add progress indicators
5. Fix image preview mode
