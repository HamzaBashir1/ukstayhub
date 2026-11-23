import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// listing-image-gallery – fullscreen, swipe, pinch to zoom.
class PhotoViewer extends StatefulWidget {
  const PhotoViewer({super.key, required this.images, this.initial = 0});
  final List<String> images;
  final int initial;

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late final PageController _c = PageController(initialPage: widget.initial);
  late int _i = widget.initial;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text('${_i + 1} / ${widget.images.length}', style: AppText.inter(size: 15, weight: FontWeight.w600, color: Colors.white)),
          centerTitle: true,
        ),
        body: PageView.builder(
          controller: _c,
          itemCount: widget.images.length,
          onPageChanged: (i) => setState(() => _i = i),
          itemBuilder: (_, i) => InteractiveViewer(
            minScale: 1,
            maxScale: 4,
            child: Center(
              child: NetImage(cloudinary(widget.images[i], width: 1600, crop: false), fit: BoxFit.contain, cacheWidth: 1600),
            ),
          ),
        ),
      );
}
