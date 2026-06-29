// Generates a compressed link-preview image (og:image) from the brand logo.
// WhatsApp/Telegram only render preview images under ~300KB, so we downscale.
import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  final src = img.decodeImage(File('assets/logo.jpg').readAsBytesSync())!;
  final resized = img.copyResize(src, width: 600, height: 600,
      interpolation: img.Interpolation.average);
  final out = img.encodeJpg(resized, quality: 82);
  File('web/og-image.jpg').writeAsBytesSync(out);
  stdout.writeln('web/og-image.jpg: ${(out.length / 1024).toStringAsFixed(0)} KB (${resized.width}x${resized.height})');
}
