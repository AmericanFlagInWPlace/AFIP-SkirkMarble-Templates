import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:image/image.dart';

Future<void> processImages() async {
  final projectRoot = Directory.current;
  final pngsDir = Directory('${projectRoot.path}/input/pngs');
  final templatesDir = Directory('${projectRoot.path}/output/templates');
  final processedPngsDir = Directory('${projectRoot.path}/output/pngs');

  await pngsDir.create(recursive: true);
  if (await pngsDir.list().isEmpty) {
    print('Error: PNG directory empty\n'
        'Please add your pngs to ${pngsDir.path}');
    _exitOnKeypress();
  }

  await templatesDir.delete(recursive: true);
  await templatesDir.create(recursive: true);

  await processedPngsDir.delete(recursive: true);
  await processedPngsDir.create(recursive: true);

  final Map<String, dynamic> allTemplates = {};
  final palette = _hexPalette.map((hex) => _hexToColor(hex)).toList();

  await for (var entity in pngsDir.list()) {
    if (entity is File && entity.path.endsWith('.png')) {
      final templateData =
          await _processImage(entity, templatesDir, processedPngsDir, palette);
      if (templateData != null) {
        allTemplates[templateData['name']] = templateData;
      }
    }
  }

  if (allTemplates.length > 1) {
    final allFileData = {'templates': allTemplates};
    final allJsonFile = File('${templatesDir.path}/ALL.json');
    final encoder = JsonEncoder.withIndent('  ');
    await allJsonFile.writeAsString(encoder.convert(allFileData));
    print(
        '\nSuccessfully created ALL.json with ${allTemplates.length} templates.');
  } else {
    print('\nNo images were processed.');
  }
  _exitOnKeypress();
}

Future<Map<String, dynamic>?> _processImage(
    File imageFile,
    Directory templatesDir,
    Directory processedPngsDir,
    List<Color> palette) async {
  final filename = imageFile.path.split(Platform.pathSeparator).last;
  final image = decodeImage(await imageFile.readAsBytes());
  if (image == null) {
    print('Could not decode image: $filename');
    return null;
  }

  final fullColorMatchedImage = Image(
      width: image.width,
      height: image.height,
      numChannels: 4,
      backgroundColor: ColorRgba8(0, 0, 0, 0));
  for (final pixel in image) {
    if (pixel.r == 222 && pixel.g == 250 && pixel.b == 206) {
      // Color is #deface, skip
      continue;
    }
    if (pixel.a > 0) {
      final finalColor = _findClosestColor(pixel, palette);
      fullColorMatchedImage.setPixel(pixel.x, pixel.y, finalColor);
    }
  }
  await File('${processedPngsDir.path}/$filename')
      .writeAsBytes(encodePng(fullColorMatchedImage));

  final parts = filename.substring(0, filename.length - 4).split('-');
  if (parts.length != 5) {
    print('Invalid filename format: $filename. Skipping json template creation'
        ' (expected name-tileX-tileY-pixelX-pixelY.png)');
    return null;
  }

  final name = parts[0];
  final origTileX = int.parse(parts[1]);
  final origTileY = int.parse(parts[2]);
  final origPixelX = int.parse(parts[3]);
  final origPixelY = int.parse(parts[4]);

  final tiles = <String, String>{};
  final tileSize = 1000;
  final shreadSize = 3;
  int validPixelCount = 0;

  for (final pixel in fullColorMatchedImage) {
    if (pixel.a > 0) {
      validPixelCount++;
    }
  }

  int currentY = 0;
  while (currentY < fullColorMatchedImage.height) {
    int currentX = 0;
    final globalYStart = origPixelY + currentY;
    final drawSizeY = min(tileSize - (globalYStart % tileSize),
        fullColorMatchedImage.height - currentY);

    while (currentX < fullColorMatchedImage.width) {
      final globalXStart = origPixelX + currentX;
      final drawSizeX = min(tileSize - (globalXStart % tileSize),
          fullColorMatchedImage.width - currentX);

      final segment = copyCrop(fullColorMatchedImage,
          x: currentX, y: currentY, width: drawSizeX, height: drawSizeY);

      final chunkCanvas = Image(
          width: drawSizeX * shreadSize,
          height: drawSizeY * shreadSize,
          numChannels: 4,
          backgroundColor: ColorRgba8(0, 0, 0, 0));

      for (final pixel in segment) {
        final targetX = pixel.x * shreadSize;
        final targetY = pixel.y * shreadSize;

        if (pixel.r == 222 && pixel.g == 250 && pixel.b == 206) {
          for (int i = 0; i < shreadSize; i++) {
            for (int j = 0; j < shreadSize; j++) {
              if ((targetX + i + targetY + j) % 2 == 0) {
                chunkCanvas.setPixelRgba(targetX + i, targetY + j, 0, 0, 0, 32);
              }
            }
          }
        } else if (pixel.a > 0) {
          chunkCanvas.setPixel(targetX + 1, targetY + 1, pixel);
        }
      }

      final segmentGlobalX = origTileX * tileSize + globalXStart;
      final segmentGlobalY = origTileY * tileSize + globalYStart;

      final tileKey =
          '${(segmentGlobalX ~/ tileSize).toString().padLeft(4, '0')},'
          '${(segmentGlobalY ~/ tileSize).toString().padLeft(4, '0')},'
          '${(segmentGlobalX % tileSize).toString().padLeft(3, '0')},'
          '${(segmentGlobalY % tileSize).toString().padLeft(3, '0')}';

      final pngBytes = encodePng(chunkCanvas);
      tiles[tileKey] = base64Encode(pngBytes);

      currentX += drawSizeX;
    }
    currentY += drawSizeY;
  }

  final template = {
    'name': name,
    'coords': '$origTileX, $origTileY, $origPixelX, $origPixelY',
    'pixelCount': validPixelCount,
    'tiles': tiles,
  };

  final fileData = {
    'templates': {
      name: template,
    },
  };

  final jsonFile = File('${templatesDir.path}/$name.json');
  final encoder = JsonEncoder.withIndent('  ');
  await jsonFile.writeAsString(encoder.convert(fileData));

  print('Processed $filename');

  return template;
}

Color _findClosestColor(Color pixel, List<Color> palette) {
  Color closestColor = palette[0];
  num minDistance = double.infinity;

  if (palette.contains(pixel)) {
    // if pixel is already in the palette, return it
    return pixel;
  }

  if (pixel.a < 128) {
    // if pixel is mostly transparent, make it fully transparent
    return ColorRgba8(0, 0, 0, 0);
  }

  for (final color in palette) {
    final distance = sqrt(pow(pixel.r - color.r, 2) +
        pow(pixel.g - color.g, 2) +
        pow(pixel.b - color.b, 2));

    if (distance < minDistance) {
      minDistance = distance;
      closestColor = color;
    }
  }

  return closestColor;
}

void _exitOnKeypress({int exitCode = 0}) async {
  print('\nPress any key to exit...');

  if (stdin.hasTerminal) {
    final bool originalLineMode = stdin.lineMode;
    final bool originalEchoMode = stdin.echoMode;

    try {
      stdin.echoMode = false;
      stdin.lineMode = false;
      stdin.readByteSync();
    } finally {
      stdin.lineMode = originalLineMode;
      stdin.echoMode = originalEchoMode;
    }
  }
  exit(exitCode);
}

const List<String> _hexPalette = [
  '#000000',
  '#3c3c3c',
  '#787878',
  '#aaaaaa',
  '#d2d2d2',
  '#ffffff',
  '#600018',
  '#a50e1e',
  '#ed1c24',
  '#fa8072',
  '#e45c1a',
  '#ff7f27',
  '#f6aa09',
  '#f9dd3b',
  '#fffabc',
  '#9c8431',
  '#c5ad31',
  '#e8d45f',
  '#4a6b3a',
  '#5a944a',
  '#84c573',
  '#0eb968',
  '#13e67b',
  '#87ff5e',
  '#0c816e',
  '#10aea6',
  '#13e1be',
  '#0f799f',
  '#60f7f2',
  '#bbfaf2',
  '#28509e',
  '#4093e4',
  '#7dc7ff',
  '#4d31b8',
  '#6b50f6',
  '#99b1fb',
  '#4a4284',
  '#7a71c4',
  '#b5aef1',
  '#780c99',
  '#aa38b9',
  '#e09ff9',
  '#cb007a',
  '#ec1f80',
  '#f38da9',
  '#9b5249',
  '#d18078',
  '#fab6a4',
  '#684634',
  '#95682a',
  '#dba463',
  '#7b6352',
  '#9c846b',
  '#d6b594',
  '#d18051',
  '#f8b277',
  '#ffc5a5',
  '#6d643f',
  '#948c6b',
  '#cdc59e',
  '#333941',
  '#6d758d',
  '#b3b9d1'
];

Color _hexToColor(String hex) {
  final cleanHex = hex.startsWith('#') ? hex.substring(1) : hex;
  final r = int.parse(cleanHex.substring(0, 2), radix: 16);
  final g = int.parse(cleanHex.substring(2, 4), radix: 16);
  final b = int.parse(cleanHex.substring(4, 6), radix: 16);
  return ColorRgba8(r, g, b, 255);
}
