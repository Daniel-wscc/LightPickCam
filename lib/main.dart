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
import 'package:flutter/services.dart';

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

// 靜態方法用於在背景執行緒處理圖片
Future<Uint8List?> _isolateImageProcess(Map<String, dynamic> params) async {
  try {
    final Uint8List imageData = params['imageData'];
    final int filterType = params['filterType'];
    
    final decodedImage = img.decodeImage(imageData);
    
    if (decodedImage == null) return null;
    
    img.Image processedImage = decodedImage;
    
    switch (filterType) {
      case 0: // 黑白
        processedImage = img.grayscale(processedImage);
        // 增加 20% 的對比度
        processedImage = img.contrast(processedImage, contrast: 120);
        break;
        
      case 1: // 懷舊
        // 先調整色調
        processedImage = img.adjustColor(
          processedImage,
          saturation: 0.7,     // 降低飽和度到 70%
          brightness: 1.0,     // 保持原始亮度
          contrast: 1.1,       // 輕微提高對比度
        );
        // 添加輕微的褐色調
        processedImage = img.colorOffset(
          processedImage,
          red: 10,
          green: 0,
          blue: -10
        );
        break;
        
      case 2: // 高對比度
        processedImage = img.contrast(processedImage, contrast: 130);  // 增加 30% 的對比度
        processedImage = img.adjustColor(
          processedImage,
          saturation: 1.2,    // 提高飽和度到 120%
          brightness: 1.0,    // 保持原始亮度
        );
        break;
        
      case 3: // 黃色調
        processedImage = img.adjustColor(
          processedImage,
          saturation: 1.1,    // 提高飽和度到 110%
          brightness: 1.0,    // 保持原始亮度
          contrast: 1.05      // 輕微提高對比度
        );
        // 輕微的黃色調
        processedImage = img.colorOffset(
          processedImage,
          red: 10,
          green: 8,
          blue: -5
        );
        break;
    }
    
    // 添加非常輕微的顆粒感
    processedImage = img.noise(processedImage, 3);
    
    // 返回處理後的圖片數據，使用高品質壓縮
    return Uint8List.fromList(img.encodeJpg(processedImage, quality: 95));
  } catch (e) {
    print('Error in isolate image processing: $e');
    return null;
  }
}

class CameraState extends ChangeNotifier {
  CameraController? controller;
  bool isInitialized = false;
  bool isTakingPicture = false;
  List<ImageItem> savedImages = [];  // 修改為保存 ImageItem
  
  // 底片類型
  List<String> filmTypes = ["黑白", "懷舊", "高對比度", "黃色調"];
  int selectedFilmType = 0;
  
  // 添加當前相機索引
  int currentCameraIndex = 0;
  
  // 添加預覽狀態控制
  bool isPreviewFiltered = false;
  
  CameraState() {
    _loadSavedImages();
  }
  
  Future<void> _loadSavedImages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<String> originalPaths = prefs.getStringList('original_images') ?? [];
      final List<String> filteredPaths = prefs.getStringList('filtered_images') ?? [];
      
      // 驗證文件是否存在並配對原圖和濾鏡圖
      savedImages = [];
      for (int i = 0; i < originalPaths.length && i < filteredPaths.length; i++) {
        final originalExists = File(originalPaths[i]).existsSync();
        final filteredExists = File(filteredPaths[i]).existsSync();
        
        if (originalExists && filteredExists) {
          savedImages.add(ImageItem(
            originalPath: originalPaths[i],
            filteredPath: filteredPaths[i],
          ));
        }
      }
      
      print('Loaded ${savedImages.length} image pairs');
      notifyListeners();
    } catch (e) {
      print('Error loading saved images: $e');
    }
  }
  
  Future<void> _savePaths() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'original_images',
        savedImages.map((item) => item.originalPath).toList(),
      );
      await prefs.setStringList(
        'filtered_images',
        savedImages.map((item) => item.filteredPath).toList(),
      );
      print('Saved ${savedImages.length} image pairs to preferences');
    } catch (e) {
      print('Error saving image paths: $e');
    }
  }

  void initializeCamera() async {
    if (cameras.isEmpty) return;
    
    controller = CameraController(
      cameras[currentCameraIndex],
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
      // 只需要基本的相機設置
      await controller!.setFocusMode(FocusMode.auto);
      await controller!.setExposureMode(ExposureMode.auto);
      isPreviewFiltered = true;
    } catch (e) {
      print('Error updating preview filter: $e');
    }
  }
  
  Future<String?> _applyFilter(String imagePath) async {
    try {
      // 讀取圖片數據
      final File imageFile = File(imagePath);
      final Uint8List imageData = await imageFile.readAsBytes();

      // 在背景執行緒處理圖片
      final Uint8List? processedImageData = await compute(_isolateImageProcess, {
        'imageData': imageData,
        'filterType': selectedFilmType,
      });

      if (processedImageData == null) return null;

      // 在主線程中保存處理後的圖片
      final appDir = await getApplicationDocumentsDirectory();
      final fileName = 'film_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final filteredImagePath = path.join(appDir.path, fileName);
      
      await File(filteredImagePath).writeAsBytes(processedImageData);
      print('Image saved to: $filteredImagePath');
      
      return filteredImagePath;
    } catch (e) {
      print('Error applying filter: $e');
      return null;
    }
  }

  Future<void> takePicture() async {
    if (!isInitialized || isTakingPicture) return;

    try {
      isTakingPicture = true;
      notifyListeners();

      // 拍照前重置相機設置以獲得最佳效果
      await controller?.setFocusMode(FocusMode.auto);
      await controller?.setExposureMode(ExposureMode.auto);
      await Future.delayed(Duration(milliseconds: 300));
      
      final XFile? image = await controller?.takePicture();
      
      if (image != null) {
        // 保存原圖
        final appDir = await getApplicationDocumentsDirectory();
        final originalFileName = 'original_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final originalPath = path.join(appDir.path, originalFileName);
        
        // 複製原圖到應用目錄
        await File(image.path).copy(originalPath);
        print('Original image saved to: $originalPath');
        
        // 在背景處理圖片
        final filteredImagePath = await _applyFilter(originalPath);
        
        if (filteredImagePath != null) {
          // 添加原圖和濾鏡圖的配對
          savedImages.add(ImageItem(
            originalPath: originalPath,
            filteredPath: filteredImagePath,
          ));
          await _savePaths();
          print('Image pair saved and added to list');
        } else {
          print('Failed to process image');
          // 如果濾鏡處理失敗，刪除原圖
          await File(originalPath).delete();
        }
      }
      
      // 拍照後恢復預覽濾鏡
      await Future.delayed(Duration(milliseconds: 200));
      await _updatePreviewFilter();
      
    } catch (e) {
      print('Error taking picture: $e');
    } finally {
      isTakingPicture = false;
      notifyListeners();
    }
  }

  // 添加切換相機的方法
  Future<void> switchCamera() async {
    if (cameras.length <= 1) return;

    currentCameraIndex = (currentCameraIndex + 1) % cameras.length;
    
    // 釋放當前相機
    await controller?.dispose();
    
    // 重新初始化相機
    controller = CameraController(
      cameras[currentCameraIndex],
      ResolutionPreset.max,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await controller?.initialize();
      await _updatePreviewFilter();
      notifyListeners();
    } catch (e) {
      print('Error switching camera: $e');
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }
}

// 新增 ImageItem 類來管理圖片配對
class ImageItem {
  final String originalPath;
  final String filteredPath;
  
  ImageItem({
    required this.originalPath,
    required this.filteredPath,
  });
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

  // 獲取濾鏡效果
  Widget _getFilterPreview(Widget child, int filterType) {
    switch (filterType) {
      case 0: // 黑白
        return ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            0.2126, 0.7152, 0.0722, 0, 0,
            0.2126, 0.7152, 0.0722, 0, 0,
            0.2126, 0.7152, 0.0722, 0, 0,
            0, 0, 0, 1, 0,
          ]),
          child: child,
        );
        
      case 1: // 懷舊
        return ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            0.393, 0.769, 0.189, 0, 0,
            0.349, 0.686, 0.168, 0, 0,
            0.272, 0.534, 0.131, 0, 0,
            0, 0, 0, 1, 0,
          ]),
          child: child,
        );
        
      case 2: // 高對比度
        return ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            1.3, 0, 0, 0, 0,
            0, 1.3, 0, 0, 0,
            0, 0, 1.3, 0, 0,
            0, 0, 0, 1, 0,
          ]),
          child: child,
        );
        
      case 3: // 黃色調
        return ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            1.2, 0, 0, 0, 10,
            0, 1.1, 0, 0, 10,
            0, 0, 0.9, 0, 0,
            0, 0, 0, 1, 0,
          ]),
          child: child,
        );
        
      default:
        return child;
    }
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
              // 相機預覽與濾鏡效果
              _getFilterPreview(
                CameraPreview(cameraState.controller!),
                cameraState.selectedFilmType,
              ),
              
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
                      
                      // 切換相機按鈕
                      IconButton(
                        icon: Icon(Icons.flip_camera_ios, color: Colors.white, size: 30),
                        onPressed: () => cameraState.switchCamera(),
                      ),
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
          if (cameraState.savedImages.isEmpty) {
            return Center(
              child: Text('尚無照片', style: TextStyle(color: Colors.white)),
            );
          }
          
          return GridView.builder(
            padding: EdgeInsets.all(8),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: cameraState.savedImages.length,
            itemBuilder: (context, index) {
              final reversedIndex = cameraState.savedImages.length - 1 - index;
              final imageItem = cameraState.savedImages[reversedIndex];
              
              return GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => FullScreenImageGallery(
                      images: cameraState.savedImages,
                      initialIndex: reversedIndex,
                    ),
                  ),
                ),
                child: Hero(
                  tag: imageItem.filteredPath,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white30),
                    ),
                    child: Image.file(
                      File(imageItem.filteredPath),
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

class FullScreenImageGallery extends StatefulWidget {
  final List<ImageItem> images;
  final int initialIndex;
  
  const FullScreenImageGallery({
    super.key,
    required this.images,
    required this.initialIndex,
  });
  
  @override
  State<FullScreenImageGallery> createState() => _FullScreenImageGalleryState();
}

class _FullScreenImageGalleryState extends State<FullScreenImageGallery> {
  late PageController _pageController;
  late int currentIndex;
  bool showOriginal = false;
  
  @override
  void initState() {
    super.initState();
    currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: currentIndex);
  }
  
  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: IconThemeData(color: Colors.white),
        actions: [
          // 切換原圖/濾鏡按鈕
          IconButton(
            icon: Icon(
              showOriginal ? Icons.filter_b_and_w : Icons.filter,
              color: Colors.white,
            ),
            onPressed: () {
              setState(() {
                showOriginal = !showOriginal;
              });
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          // 圖片查看器
          PageView.builder(
            controller: _pageController,
            itemCount: widget.images.length,
            onPageChanged: (index) {
              setState(() {
                currentIndex = index;
              });
            },
            itemBuilder: (context, index) {
              final imageItem = widget.images[index];
              final imagePath = showOriginal 
                ? imageItem.originalPath 
                : imageItem.filteredPath;
              
              return GestureDetector(
                onTap: () {
                  setState(() {
                    showOriginal = !showOriginal;
                  });
                },
                child: Hero(
                  tag: imageItem.filteredPath,
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4.0,
                    child: Image.file(
                      File(imagePath),
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              );
            },
          ),
          
          // 提示文字
          Positioned(
            bottom: 16,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '點擊切換 ${showOriginal ? "濾鏡" : "原圖"} · 左右滑動切換照片 · 雙指縮放',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
