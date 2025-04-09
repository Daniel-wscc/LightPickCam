import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:permission_handler/permission_handler.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart' show kIsWeb, compute;

late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 如果不是 Web 平台才請求權限
  if (!kIsWeb) {
    await [
      Permission.camera,
      Permission.storage,
    ].request();
  }
  
  try {
    cameras = await availableCameras();
  } catch (e) {
    print('Error getting cameras: $e');
    cameras = [];
  }
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => CameraState(),
      child: MaterialApp(
        title: 'Film Camera',
        theme: ThemeData.dark(),
        home: const CameraScreen(),
      ),
    );
  }
}

class CameraState extends ChangeNotifier {
  CameraController? controller;
  bool isInitialized = false;
  bool isTakingPicture = false;
  List<String> savedImagePaths = [];
  
  // 底片類型
  List<String> filmTypes = ["黑白", "懷舊", "高對比度", "黃色調"];
  int selectedFilmType = 0;
  
  // 添加預覽狀態控制
  bool isPreviewFiltered = false;
  
  CameraState() {
    _loadSavedImages();
  }
  
  Future<void> _loadSavedImages() async {
    final prefs = await SharedPreferences.getInstance();
    savedImagePaths = prefs.getStringList('saved_images') ?? [];
    notifyListeners();
  }
  
  Future<void> _savePaths() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('saved_images', savedImagePaths);
  }

  void initializeCamera() async {
    if (cameras.isEmpty) return;
    
    controller = CameraController(
      cameras[0],
      ResolutionPreset.max,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await controller?.initialize();
      isInitialized = true;
      // 初始化後設置預覽濾鏡
      await _updatePreviewFilter();
      notifyListeners();
    } catch (e) {
      print('Error initializing camera: $e');
    }
  }
  
  void changeFilmType(int index) {
    selectedFilmType = index;
    // 切換濾鏡時重置預覽
    _updatePreviewFilter();
    notifyListeners();
  }
  
  // 更新預覽濾鏡
  Future<void> _updatePreviewFilter() async {
    if (controller == null) return;
    
    try {
      await controller!.setFocusMode(FocusMode.locked);
      await controller!.setExposureMode(ExposureMode.locked);
      
      // 根據不同濾鏡類型設置不同的預覽效果
      switch (selectedFilmType) {
        case 0: // 黑白
          await controller!.setExposureOffset(-0.5);
        case 1: // 懷舊
          await controller!.setExposureOffset(-0.3);
        case 2: // 高對比度
          await controller!.setExposureOffset(-0.7);
        case 3: // 黃色調
          await controller!.setExposureOffset(0.3);
      }
      
      isPreviewFiltered = true;
    } catch (e) {
      print('Error updating preview filter: $e');
    }
  }
  
  Future<String?> _applyFilter(String imagePath) async {
    // 在背景執行緒處理圖片
    return compute(_processImage, {
      'imagePath': imagePath,
      'filterType': selectedFilmType,
    });
  }
  
  // 靜態方法用於在背景執行緒處理圖片
  static Future<String?> _processImage(Map<String, dynamic> params) async {
    try {
      final String imagePath = params['imagePath'];
      final int filterType = params['filterType'];
      
      final bytes = await File(imagePath).readAsBytes();
      final decodedImage = img.decodeImage(bytes);
      
      if (decodedImage == null) return null;
      
      img.Image processedImage;
      
      switch (filterType) {
        case 0: // 黑白
          processedImage = img.grayscale(decodedImage);
        case 1: // 懷舊
          processedImage = img.sepia(decodedImage);
        case 2: // 高對比度
          processedImage = img.contrast(decodedImage, contrast: 1.5);
        case 3: // 黃色調
          processedImage = img.copyRotate(decodedImage, angle: 0);
          processedImage = img.colorOffset(processedImage, red: 0, green: 0, blue: -20);
        default:
          processedImage = decodedImage;
      }
      
      processedImage = img.noise(processedImage, 5);
      processedImage = img.vignette(processedImage);
      
      final directory = await getApplicationDocumentsDirectory();
      final fileName = 'film_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final filteredImagePath = path.join(directory.path, fileName);
      
      await File(filteredImagePath).writeAsBytes(img.encodeJpg(processedImage));
      
      return filteredImagePath;
    } catch (e) {
      print('Error processing image: $e');
      return null;
    }
  }

  Future<void> takePicture() async {
    if (!isInitialized || isTakingPicture) return;

    try {
      isTakingPicture = true;
      notifyListeners();

      // 拍照前重置相機設置
      await controller?.setFocusMode(FocusMode.auto);
      await controller?.setExposureMode(ExposureMode.auto);
      
      final XFile? image = await controller?.takePicture();
      
      if (image != null) {
        // 在背景處理圖片
        final filteredImagePath = await _applyFilter(image.path);
        
        if (filteredImagePath != null) {
          savedImagePaths.add(filteredImagePath);
          await _savePaths();
        }
      }
      
      // 拍照後恢復預覽濾鏡
      await _updatePreviewFilter();
      
    } catch (e) {
      print('Error taking picture: $e');
    } finally {
      isTakingPicture = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  @override
  void initState() {
    super.initState();
    context.read<CameraState>().initializeCamera();
  }
  
  void _showGallery() {
    Navigator.push(
      context, 
      MaterialPageRoute(
        builder: (context) => GalleryScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Consumer<CameraState>(
        builder: (context, cameraState, child) {
          if (!cameraState.isInitialized) {
            return const Center(child: CircularProgressIndicator());
          }

          return Stack(
            children: [
              // 相機預覽
              CameraPreview(cameraState.controller!),
              
              // 底片選擇器
              Positioned(
                top: MediaQuery.of(context).padding.top + 10,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 15, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: DropdownButton<int>(
                      value: cameraState.selectedFilmType,
                      dropdownColor: Colors.black87,
                      underline: SizedBox(),
                      icon: Icon(Icons.arrow_drop_down, color: Colors.white),
                      items: List.generate(
                        cameraState.filmTypes.length,
                        (index) => DropdownMenuItem(
                          value: index,
                          child: Text(
                            cameraState.filmTypes[index],
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                      onChanged: (index) {
                        if (index != null) {
                          cameraState.changeFilmType(index);
                        }
                      },
                    ),
                  ),
                ),
              ),
              
              // 底部操作區
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.all(25.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // 相簿按鈕
                      IconButton(
                        icon: Icon(Icons.photo_library, color: Colors.white, size: 30),
                        onPressed: _showGallery,
                      ),
                      
                      // 拍照按鈕
                      FloatingActionButton(
                        onPressed: cameraState.isTakingPicture 
                          ? null 
                          : () => cameraState.takePicture(),
                        backgroundColor: Colors.white24,
                        child: Icon(
                          Icons.camera,
                          size: 36,
                          color: cameraState.isTakingPicture 
                            ? Colors.grey 
                            : Colors.white,
                        ),
                      ),
                      
                      // 空白處(為了平衡)
                      SizedBox(width: 48),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class GalleryScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('我的底片'),
        backgroundColor: Colors.black,
      ),
      backgroundColor: Colors.black,
      body: Consumer<CameraState>(
        builder: (context, cameraState, child) {
          if (cameraState.savedImagePaths.isEmpty) {
            return Center(
              child: Text('尚無照片', style: TextStyle(color: Colors.white)),
            );
          }
          
          return GridView.builder(
            padding: EdgeInsets.all(8),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: cameraState.savedImagePaths.length,
            itemBuilder: (context, index) {
              final reversedIndex = cameraState.savedImagePaths.length - 1 - index;
              final imagePath = cameraState.savedImagePaths[reversedIndex];
              
              return GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => FullScreenImage(imagePath: imagePath),
                  ),
                ),
                child: Hero(
                  tag: imagePath,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white30),
                    ),
                    child: Image.file(
                      File(imagePath),
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class FullScreenImage extends StatelessWidget {
  final String imagePath;
  
  const FullScreenImage({super.key, required this.imagePath});
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: Hero(
          tag: imagePath,
          child: Image.file(
            File(imagePath),
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
