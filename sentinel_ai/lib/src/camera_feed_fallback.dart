import 'package:flutter/material.dart';

class CameraFeed extends StatelessWidget {
  const CameraFeed({super.key, required this.streamUrl});

  final String streamUrl;

  @override
  Widget build(BuildContext context) {
    return Image.network(
      streamUrl,
      fit: BoxFit.cover,
      errorBuilder: (_, error, _) => const Center(
        child: Text(
          'Live camera streaming is currently supported in the local Chrome app.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
