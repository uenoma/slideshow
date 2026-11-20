import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const SlideshowApp());
}

class SlideshowApp extends StatelessWidget {
  const SlideshowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Slideshow',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: const SlideshowHomePage(),
    );
  }
}

class SlideshowHomePage extends StatefulWidget {
  const SlideshowHomePage({super.key});

  @override
  State<SlideshowHomePage> createState() => _SlideshowHomePageState();
}

class _SlideshowHomePageState extends State<SlideshowHomePage> {
  final FocusNode _focusNode = FocusNode();
  final FocusNode _intervalFocusNode = FocusNode(canRequestFocus: false);
  final ScrollController _thumbnailScrollController = ScrollController();
  final TransformationController _previewTransformController =
      TransformationController();
  final Map<String, Uint8List> _imageBytesCache = {};
  String? _selectedDirectory;
  List<_SlideImage> _images = const [];
  int _currentIndex = 0;
  int _intervalSeconds = 5;
  bool _isPlaying = false;
  bool _isZoomed = false;
  bool _areControlsVisible = true;
  Timer? _timer;
  Timer? _controlsHideTimer;
  bool _isLoading = false;
  int? _lastScrolledThumbnailIndex;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _intervalFocusNode.dispose();
    _thumbnailScrollController.dispose();
    _imageBytesCache.clear();
    _timer?.cancel();
    _controlsHideTimer?.cancel();
    super.dispose();
  }

  void _restoreMainFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  void _onUserInteraction() {
    if (!_isPlaying || _isLoading || _images.isEmpty) {
      return;
    }

    setState(() {
      _areControlsVisible = true;
    });

    _controlsHideTimer?.cancel();
    _controlsHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) {
        return;
      }

      setState(() {
        _areControlsVisible = false;
      });
    });
  }

  ImageProvider<Object> _imageProviderFor(String path) {
    final bytes = _imageBytesCache[path];
    if (bytes == null) {
      return FileImage(File(path));
    }
    return MemoryImage(bytes);
  }

  Future<void> _pickFolder() async {
    final String? directoryPath = await getDirectoryPath();
    if (directoryPath == null) {
      return;
    }

    _imageBytesCache.clear();

    _previewTransformController.value = Matrix4.identity();

    setState(() {
      _selectedDirectory = directoryPath;
      _isLoading = true;
      _isPlaying = false;
      _isZoomed = false;
      _areControlsVisible = true;
      _timer?.cancel();
      _controlsHideTimer?.cancel();
      _currentIndex = 0;
      _lastScrolledThumbnailIndex = null;
    });

    final images = await _loadImageFiles(directoryPath);

    if (!mounted) {
      return;
    }

    setState(() {
      _images = images;
      _isLoading = false;
      _isPlaying = false;
      _areControlsVisible = images.isNotEmpty;
    });

    if (_images.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scrollThumbnailIntoView();
        }
      });
    }

    if (_isPlaying) {
      _controlsHideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _areControlsVisible = false;
          });
        }
      });
    }
    _restartTimer();
  }

  Future<List<_SlideImage>> _loadImageFiles(String directoryPath) async {
    final directory = Directory(directoryPath);
    if (!await directory.exists()) {
      return const [];
    }

    final files = directory
        .listSync(followLinks: false)
        .whereType<File>()
        .where((file) => _isImageFile(file.path))
        .toList();

    final imageFiles = <_SlideImage>[];

    for (final file in files) {
      try {
        final stat = await file.stat();
        final bytes = await file.readAsBytes();
        _imageBytesCache[file.path] = bytes;
        imageFiles.add(
          _SlideImage(path: file.path, lastModified: stat.modified),
        );
      } on FileSystemException {
        imageFiles.add(
          _SlideImage(path: file.path, lastModified: DateTime.now()),
        );
      }
    }

    imageFiles.sort((a, b) => a.lastModified.compareTo(b.lastModified));
    return imageFiles;
  }

  bool _isImageFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp');
  }

  void _restartTimer() {
    _timer?.cancel();

    if (!_isPlaying || _images.isEmpty) {
      return;
    }

    _timer = Timer.periodic(Duration(seconds: _intervalSeconds), (_) {
      if (!mounted || _images.isEmpty) {
        return;
      }

      setState(() {
        _currentIndex = (_currentIndex + 1) % _images.length;
      });
      _scrollThumbnailIntoView();
    });
  }

  void _togglePlayback() {
    _focusNode.requestFocus();
    setState(() {
      _isPlaying = !_isPlaying;
      _areControlsVisible = true;
    });
    _controlsHideTimer?.cancel();
    if (_isPlaying) {
      _controlsHideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _areControlsVisible = false;
          });
        }
      });
    }
    _restartTimer();
  }

  Future<Size> _getImageSize(String path) async {
    final bytes = _imageBytesCache[path];
    if (bytes == null) {
      return Size.zero;
    }

    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return Size(
      frame.image.width.toDouble(),
      frame.image.height.toDouble(),
    );
  }

  Future<void> _togglePreviewZoom([Offset? localPosition, Size? viewportSize]) async {
    if (_images.isEmpty) {
      return;
    }

    if (_isZoomed) {
      _previewTransformController.value = Matrix4.identity();
      setState(() {
        _isZoomed = false;
      });
      return;
    }

    if (localPosition == null || viewportSize == null) {
      setState(() {
        _isZoomed = true;
      });
      return;
    }

    final imageSize = await _getImageSize(_images[_currentIndex].path);
    if (!mounted || imageSize == Size.zero) {
      setState(() {
        _isZoomed = true;
      });
      return;
    }

    final fitScale = (viewportSize.width / imageSize.width)
        .clamp(0.0, 1.0)
        .toDouble();
    final fitScaleY = (viewportSize.height / imageSize.height)
        .clamp(0.0, 1.0)
        .toDouble();
    final scale = fitScale < fitScaleY ? fitScale : fitScaleY;
    final displayWidth = imageSize.width * scale;
    final displayHeight = imageSize.height * scale;
    final offsetX = (viewportSize.width - displayWidth) / 2;
    final offsetY = (viewportSize.height - displayHeight) / 2;

    final clickedX = (localPosition.dx - offsetX) / scale;
    final clickedY = (localPosition.dy - offsetY) / scale;
    final translateX = viewportSize.width / 2 - clickedX;
    final translateY = viewportSize.height / 2 - clickedY;

    _previewTransformController.value = Matrix4.identity()
      ..translate(translateX, translateY);

    setState(() {
      _isZoomed = true;
    });
  }

  void _toggleMarkCurrent() {
    if (_images.isEmpty) {
      return;
    }

    final preservedOffset = _thumbnailScrollController.hasClients
        ? _thumbnailScrollController.offset
        : null;

    setState(() {
      _images[_currentIndex].marked = !_images[_currentIndex].marked;
    });

    if (preservedOffset == null) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_thumbnailScrollController.hasClients) {
        return;
      }

      final maxScrollExtent = _thumbnailScrollController.position.maxScrollExtent;
      final clampedOffset = preservedOffset.clamp(0.0, maxScrollExtent);
      if ((_thumbnailScrollController.offset - clampedOffset).abs() > 0.5) {
        _thumbnailScrollController.jumpTo(clampedOffset);
      }
    });
  }

  Future<void> _copyMarkedImages() async {
    final markedImages = _images.where((image) => image.marked).toList();
    if (markedImages.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('マークされた画像がありません')));
      return;
    }

    final destinationPath = await getDirectoryPath();
    if (destinationPath == null) {
      return;
    }

    final destinationDirectory = Directory(destinationPath);
    if (!await destinationDirectory.exists()) {
      await destinationDirectory.create(recursive: true);
    }

    var copiedCount = 0;
    for (final image in markedImages) {
      final sourceFile = File(image.path);
      if (!await sourceFile.exists()) {
        continue;
      }

      final fileName = image.path.split(Platform.pathSeparator).last;
      final targetPath =
          '${destinationDirectory.path}${Platform.pathSeparator}$fileName';
      await sourceFile.copy(targetPath);
      copiedCount++;
    }

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$copiedCount件の画像をコピーしました')));
  }

  void _setIntervalSeconds(int value) {
    if (value < 1) {
      return;
    }

    setState(() {
      _intervalSeconds = value;
    });
    if (_isPlaying) {
      _restartTimer();
    }
  }

  void _showPrevious() {
    if (_images.isEmpty) {
      return;
    }

    _previewTransformController.value = Matrix4.identity();
    setState(() {
      _currentIndex = (_currentIndex - 1 + _images.length) % _images.length;
      _isZoomed = false;
    });
    _scrollThumbnailIntoView();
  }

  void _showNext() {
    if (_images.isEmpty) {
      return;
    }

    _previewTransformController.value = Matrix4.identity();
    setState(() {
      _currentIndex = (_currentIndex + 1) % _images.length;
      _isZoomed = false;
    });
    _scrollThumbnailIntoView();
  }

  void _scrollThumbnailIntoView() {
    if (_images.isEmpty || _thumbnailScrollController.hasClients == false) {
      return;
    }

    if (_lastScrolledThumbnailIndex == _currentIndex) {
      return;
    }

    final itemHeight = 118.0;
    final targetOffset = (_currentIndex * itemHeight) - 90;
    final maxScrollExtent = _thumbnailScrollController.position.maxScrollExtent;
    final clampedOffset = targetOffset.clamp(0.0, maxScrollExtent);

    _lastScrolledThumbnailIndex = _currentIndex;
    _thumbnailScrollController.jumpTo(clampedOffset);
  }

  @override
  Widget build(BuildContext context) {
    final currentImage = _images.isEmpty ? null : _images[_currentIndex];

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (event) {
        if (event is! KeyDownEvent) {
          return;
        }

        _onUserInteraction();

        if (event.logicalKey == LogicalKeyboardKey.space) {
          _togglePlayback();
          return;
        }

        if (event.logicalKey == LogicalKeyboardKey.digit1 ||
            event.logicalKey == LogicalKeyboardKey.numpad1) {
          _toggleMarkCurrent();
          return;
        }

        if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
            event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _showNext();
          return;
        }

        if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _showPrevious();
        }
      },
      child: MouseRegion(
        onHover: (_) => _onUserInteraction(),
        child: GestureDetector(
          onTap: _onUserInteraction,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              children: [
                if (currentImage != null)
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final viewportSize = constraints.biggest;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (details) {
                            _togglePreviewZoom(
                              details.localPosition,
                              viewportSize,
                            );
                          },
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 500),
                            child: _isZoomed
                                ? ClipRect(
                                    key: ValueKey<String>('zoom-${currentImage.path}'),
                                    child: InteractiveViewer(
                                      transformationController:
                                          _previewTransformController,
                                      constrained: false,
                                      panEnabled: true,
                                      scaleEnabled: true,
                                      minScale: 1,
                                      maxScale: 4,
                                      boundaryMargin: const EdgeInsets.all(32),
                                      child: Image(
                                        image: _imageProviderFor(currentImage.path),
                                        fit: BoxFit.none,
                                        alignment: Alignment.center,
                                        gaplessPlayback: true,
                                      ),
                                    ),
                                  )
                                : Image(
                                    key: ValueKey<String>(currentImage.path),
                                    image: _imageProviderFor(currentImage.path),
                                    fit: BoxFit.contain,
                                    gaplessPlayback: true,
                                  ),
                          ),
                        );
                      },
                    ),
                  )
                else
                  Positioned.fill(
                    child: Container(
                      color: Colors.black,
                      child: const Center(
                        child: Text(
                          'フォルダーを選択してスライドショーを開始',
                          style: TextStyle(color: Colors.white, fontSize: 24),
                        ),
                      ),
                    ),
                  ),
                if (currentImage != null && currentImage.marked)
                  Positioned(
                    top: 100,
                    right: 24,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check, color: Colors.white),
                          SizedBox(width: 6),
                          Text('マーク済み', style: TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
                if (_isLoading)
                  const Positioned.fill(
                    child: ColoredBox(
                      color: Color.fromARGB(120, 0, 0, 0),
                      child: Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                    ),
                  ),
                if (_images.isNotEmpty)
                  Positioned(
                    top: 80,
                    bottom: 100,
                    left: 16,
                    child: IgnorePointer(
                      ignoring: !_areControlsVisible,
                      child: AnimatedOpacity(
                        opacity: _areControlsVisible ? 1 : 0.2,
                        duration: const Duration(milliseconds: 200),
                        child: Container(
                          width: 180,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.45),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: ListView.builder(
                            key: const PageStorageKey<String>('thumbnail-list'),
                            controller: _thumbnailScrollController,
                            itemCount: _images.length,
                            itemBuilder: (context, index) {
                              final image = _images[index];
                              final isSelected = index == _currentIndex;
                              return GestureDetector(
                                onTap: () {
                                  _restoreMainFocus();
                                  _previewTransformController.value = Matrix4.identity();
                                  setState(() {
                                    _currentIndex = index;
                                    _isZoomed = false;
                                  });
                                  _scrollThumbnailIntoView();
                                  _onUserInteraction();
                                },
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? Colors.blue.withOpacity(0.3)
                                        : Colors.transparent,
                                    border: Border.all(
                                      color: isSelected
                                          ? Colors.blue
                                          : Colors.white.withOpacity(0.2),
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Stack(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: Image(
                                          image: _imageProviderFor(image.path),
                                          width: double.infinity,
                                          height: 110,
                                          fit: BoxFit.contain,
                                        ),
                                      ),
                                      if (image.marked)
                                        Positioned(
                                          top: 6,
                                          right: 6,
                                          child: Container(
                                            padding: const EdgeInsets.all(4),
                                            decoration: const BoxDecoration(
                                              color: Colors.green,
                                              shape: BoxShape.circle,
                                            ),
                                            child: const Icon(
                                              Icons.check,
                                              size: 14,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 20,
                  left: 20,
                  right: 20,
                  child: AnimatedOpacity(
                    opacity: _areControlsVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(
                      ignoring: !_areControlsVisible,
                      child: SafeArea(
                        child: Row(
                          children: [
                            FilledButton.icon(
                              onPressed: _pickFolder,
                              icon: const Icon(Icons.folder_open),
                              label: const Text('フォルダーを選択'),
                            ),
                            const SizedBox(width: 16),
                            Flexible(
                              child: Text(
                                _selectedDirectory ?? '未選択',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 24,
                  left: 0,
                  right: 0,
                  child: AnimatedOpacity(
                    opacity: _areControlsVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(
                      ignoring: !_areControlsVisible,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.45),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                onPressed: () {
                                  _restoreMainFocus();
                                  _showPrevious();
                                },
                                icon: const Icon(
                                  Icons.skip_previous,
                                  color: Colors.white,
                                ),
                              ),
                              IconButton(
                                onPressed: () {
                                  _restoreMainFocus();
                                  _togglePlayback();
                                },
                                icon: Icon(
                                  _isPlaying ? Icons.pause : Icons.play_arrow,
                                  color: Colors.white,
                                ),
                              ),
                              IconButton(
                                onPressed: () {
                                  _restoreMainFocus();
                                  _showNext();
                                },
                                icon: const Icon(Icons.skip_next, color: Colors.white),
                              ),
                              const SizedBox(width: 12),
                              const Icon(Icons.timer, color: Colors.white),
                              const SizedBox(width: 8),
                              DropdownButton<int>(
                                focusNode: _intervalFocusNode,
                                value: _intervalSeconds,
                                dropdownColor: Colors.black87,
                                underline: const SizedBox(),
                                style: const TextStyle(color: Colors.white),
                                items: [1, 2, 3, 5, 10, 15, 30, 60]
                                    .map(
                                      (value) => DropdownMenuItem<int>(
                                        value: value,
                                        child: Text('${value}秒'),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (value) {
                                  _restoreMainFocus();
                                  if (value != null) {
                                    _setIntervalSeconds(value);
                                  }
                                },
                              ),
                              const SizedBox(width: 12),
                              if (_images.isNotEmpty)
                                Text(
                                  '${_currentIndex + 1} / ${_images.length}',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              const SizedBox(width: 12),
                              FilledButton.icon(
                                onPressed: () {
                                  _restoreMainFocus();
                                  _copyMarkedImages();
                                },
                                icon: const Icon(Icons.copy_all),
                                label: const Text('コピー'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SlideImage {
  _SlideImage({
    required this.path,
    required this.lastModified,
    this.marked = false,
  });

  final String path;
  final DateTime lastModified;
  bool marked;
}
