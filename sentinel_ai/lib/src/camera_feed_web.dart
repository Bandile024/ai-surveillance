import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

class CameraFeed extends StatefulWidget {
  const CameraFeed({super.key, required this.streamUrl});

  final String streamUrl;

  @override
  State<CameraFeed> createState() => _CameraFeedState();
}

class _CameraFeedState extends State<CameraFeed> {
  static int _nextViewId = 0;
  late final String _viewType;
  late final html.ImageElement _image;

  @override
  void initState() {
    super.initState();
    _viewType = 'sentinel-camera-feed-${_nextViewId++}';
    _image = html.ImageElement()
      ..src = widget.streamUrl
      ..alt = 'Live AI surveillance camera'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover'
      ..style.backgroundColor = '#111827';
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId) => _image,
    );
  }

  @override
  void didUpdateWidget(covariant CameraFeed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.streamUrl != widget.streamUrl) {
      _image.src = widget.streamUrl;
    }
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}
