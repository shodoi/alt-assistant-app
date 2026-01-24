import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:camera_macos/camera_macos.dart';
import 'package:path_provider/path_provider.dart';

// macOS & モバイル兼用カメラ画面
class CameraScreen extends StatefulWidget {
  final CameraDescription? camera;
  const CameraScreen({super.key, this.camera});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  // Mobile用
  CameraController? _mobileController;
  Future<void>? _initializeControllerFuture;
  
  // macOS用
  CameraMacOSController? _macOSController;

  @override
  void initState() {
    super.initState();
    if (!Platform.isMacOS && widget.camera != null) {
      _mobileController = CameraController(
        widget.camera!,
        ResolutionPreset.high,
        enableAudio: false,
      );
      _initializeControllerFuture = _mobileController!.initialize();
    }
  }

  @override
  void dispose() {
    _mobileController?.dispose();
    super.dispose();
  }

  Future<void> _takePicture() async {
    try {
      if (Platform.isMacOS) {
        if (_macOSController != null) {
          final picture = await _macOSController!.takePicture();
          if (picture != null && mounted) {
             String? filePath = picture.url;
             
             // バイトデータがある場合はファイルに書き出す
             if (picture.bytes != null && (filePath == null || filePath.isEmpty)) {
               try {
                 final tempDir = await getTemporaryDirectory();
                 final fileName = 'mac_camera_${DateTime.now().millisecondsSinceEpoch}.jpg';
                 final file = File('${tempDir.path}/$fileName');
                 await file.writeAsBytes(picture.bytes!);
                 filePath = file.path;
               } catch (e) {
                 debugPrint('Error saving temp file: $e');
               }
             }
             
             if (filePath != null) {
               Navigator.pop(context, XFile(filePath));
             } else {
               ScaffoldMessenger.of(context).showSnackBar(
                 const SnackBar(content: Text('画像の取得に失敗しました')),
               );
             }
          }
        }
      } else {
        if (_initializeControllerFuture != null && _mobileController != null) {
          await _initializeControllerFuture;
          final image = await _mobileController!.takePicture();
          if (mounted) Navigator.pop(context, image);
        }
      }
    } catch (e) {
      debugPrint('Error taking picture: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('撮影エラー: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isMacOS) {
      return Scaffold(
        appBar: AppBar(title: const Text('写真を撮影 (macOS)')),
        body: CameraMacOSView(
          fit: BoxFit.contain,
          cameraMode: CameraMacOSMode.photo,
          enableAudio: false,
          onCameraInizialized: (CameraMacOSController controller) {
            setState(() {
              _macOSController = controller;
            });
          },
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: _takePicture,
          tooltip: '写真を撮影',
          child: const Icon(Icons.camera),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      );
    } else {
      // Mobile Implementation
      if (widget.camera == null) {
         return const Scaffold(body: Center(child: Text('カメラが見つかりません')));
      }

      return Scaffold(
        appBar: AppBar(
          title: const Text('写真を撮影'),
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        body: FutureBuilder<void>(
          future: _initializeControllerFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.done) {
              return CameraPreview(_mobileController!);
            } else if (snapshot.hasError) {
              return Center(
                child: Text('カメラエラー: ${snapshot.error}'),
              );
            } else {
              return const Center(child: CircularProgressIndicator());
            }
          },
        ),
        floatingActionButton: FloatingActionButton(
          backgroundColor: Colors.white,
          onPressed: _takePicture,
          tooltip: '写真を撮影',
          child: const Icon(Icons.camera, color: Colors.black),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      );
    }
  }
}
