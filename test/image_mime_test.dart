import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_alt_generator/image_mime.dart';

void main() {
  group('detectImageMimeType', () {
    test('detects JPEG from magic bytes', () {
      final bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]);
      expect(detectImageMimeType(bytes), 'image/jpeg');
    });

    test('detects PNG including transparent PNG from magic bytes', () {
      final bytes = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D,
      ]);
      expect(detectImageMimeType(bytes), 'image/png');
    });

    test('detects WebP from RIFF...WEBP magic bytes', () {
      final bytes = Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46, // RIFF
        0x24, 0x00, 0x00, 0x00, // size
        0x57, 0x45, 0x42, 0x50, // WEBP
        0x56, 0x50, 0x38, 0x20,
      ]);
      expect(detectImageMimeType(bytes), 'image/webp');
    });

    test('detects GIF87a and GIF89a from magic bytes', () {
      final gif87a = Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x37, 0x61]);
      final gif89a = Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
      expect(detectImageMimeType(gif87a), 'image/gif');
      expect(detectImageMimeType(gif89a), 'image/gif');
    });

    test('falls back to image/jpeg for unknown, empty, or truncated bytes', () {
      expect(detectImageMimeType(Uint8List(0)), 'image/jpeg');
      expect(detectImageMimeType(Uint8List.fromList([0x01, 0x02])), 'image/jpeg');
      expect(
        detectImageMimeType(Uint8List.fromList([
          0x52, 0x49, 0x46, 0x46, // RIFF
          0x24, 0x00, 0x00, 0x00,
          0x57, 0x41, 0x56, 0x45, // WAVE (not WEBP)
        ])),
        'image/jpeg',
      );
      expect(
        detectImageMimeType(Uint8List.fromList([0x00, 0x11, 0x22, 0x33, 0x44])),
        'image/jpeg',
      );
    });
  });
}
