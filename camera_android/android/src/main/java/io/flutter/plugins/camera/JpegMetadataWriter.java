package io.flutter.plugins.camera;
import com.drew.metadata.exif.ExifIFD0Directory;
import com.drew.metadata.Metadata;
import com.drew.metadata.MetadataException;
import java.io.ByteArrayOutputStream;
import java.io.IOException;

public class JpegMetadataWriter {
    public static byte[] writeMetadata(byte[] jpegData, Metadata metadata) throws IOException {
        // Simple: chỉ ghi orientation, không cần full rewrite
        // Dùng cách đơn giản: thêm APP1 segment
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(jpegData, 0, 2); // SOI

        int offset = 2;
        while (offset + 1 < jpegData.length) {
            int marker = jpegData[offset] & 0xFF;
            if (marker == 0xFF) {
                int markerType = jpegData[offset + 1] & 0xFF;
                marker = markerType;
                if (marker == 0xD8) { // SOI
                    offset += 2;
                    continue;
                }
                if (marker == 0xE1) { // APP1 (EXIF) → skip cũ
                    if (offset + 3 >= jpegData.length) {
                        break;
                    }
                    int len =
                        ((jpegData[offset + 2] & 0xFF) << 8)
                            | (jpegData[offset + 3] & 0xFF);
                    offset += len + 2;
                    continue;
                }
            }
            break;
        }

        // Ghi APP1 mới
        ByteArrayOutputStream app1 = new ByteArrayOutputStream();
        app1.write("Exif\0\0".getBytes());
        app1.write(new byte[] {0x4D, 0x4D, 0x00, 0x2A}); // TIFF header
        app1.write(new byte[] {0x00, 0x00, 0x00, 0x08}); // IFD offset

        int orientationValue = 1;
        if (metadata != null) {
            ExifIFD0Directory exifDirectory =
                metadata.getFirstDirectoryOfType(ExifIFD0Directory.class);
            if (exifDirectory != null && exifDirectory.containsTag(ExifIFD0Directory.TAG_ORIENTATION)) {
                try {
                    orientationValue = exifDirectory.getInt(ExifIFD0Directory.TAG_ORIENTATION);
                } catch (MetadataException ignored) {
                    orientationValue = 1;
                }
            }
        }
        if (orientationValue < 1 || orientationValue > 8) {
            orientationValue = 1;
        }

        // 1 entry: Orientation
        app1.write(new byte[] {0x00, 0x01}); // entry count = 1
        app1.write(new byte[] {0x01, 0x12, 0x00, 0x03}); // Tag 0x0112, SHORT
        app1.write(new byte[] {0x00, 0x00, 0x00, 0x01}); // Count = 1
        app1.write(
            new byte[] {
                (byte) ((orientationValue >> 8) & 0xFF),
                (byte) (orientationValue & 0xFF),
                0x00,
                0x00
            }); // Value (big endian) + padding
        app1.write(new byte[] {0x00, 0x00, 0x00, 0x00}); // Next IFD offset

        byte[] app1Data = app1.toByteArray();
        int app1Len = app1Data.length + 2;

        out.write(0xFF);
        out.write(0xE1);
        out.write((app1Len >> 8) & 0xFF);
        out.write(app1Len & 0xFF);
        out.write(app1Data);

        // Ghi phần còn lại
        out.write(jpegData, offset, jpegData.length - offset);
        return out.toByteArray();
    }
}