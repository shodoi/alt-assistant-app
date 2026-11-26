import 'dart:typed_data';

/// Detects the image MIME type from leading magic bytes.
///
/// Supports JPEG (`image/jpeg`), PNG (`image/png`), WebP (`image/webp`), and
/// GIF (`image/gif`), falling back to `image/jpeg` when unrecognized.
String detectImageMimeType(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }

  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return 'image/png';
  }

  if (bytes.length >= 12 &&
      bytes[0] == 0x52 && // R
      bytes[1] == 0x49 && // I
      bytes[2] == 0x46 && // F
      bytes[3] == 0x46 && // F
      bytes[8] == 0x57 && // W
      bytes[9] == 0x45 && // E
      bytes[10] == 0x42 && // B
      bytes[11] == 0x50) { // P
    return 'image/webp';
  }

  if (bytes.length >= 6 &&
      bytes[0] == 0x47 && // G
      bytes[1] == 0x49 && // I
      bytes[2] == 0x46 && // F
      bytes[3] == 0x38 && // 8
      (bytes[4] == 0x37 || bytes[4] == 0x39) && // 7 or 9
      bytes[5] == 0x61) { // a
    return 'image/gif';
  }

  return 'image/jpeg';
}
