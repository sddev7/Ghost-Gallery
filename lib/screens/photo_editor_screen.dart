import 'dart:io';
import 'package:flutter/material.dart';
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:path_provider/path_provider.dart';

class CustomPhotoEditorPage extends StatefulWidget {
  final String imageUrl;
  final Function(String) onSave;
  final String? initialTool;
  final bool forWallpaper;

  const CustomPhotoEditorPage({
    super.key,
    required this.imageUrl,
    required this.onSave,
    this.initialTool,
    this.forWallpaper = false,
  });

  @override
  State<CustomPhotoEditorPage> createState() => _CustomPhotoEditorPageState();
}

class _CustomPhotoEditorPageState extends State<CustomPhotoEditorPage> {
  String? _geminiApiKey;
  bool _isLoadingKey = true;
  String? _aiTip;

  @override
  void initState() {
    super.initState();
    _loadKey();
  }

  Future<void> _loadKey() async {
    final key ="";
    if (mounted) {
      setState(() {
        _geminiApiKey = key;
        _isLoadingKey = false;
      });
    }
  }

  void _showAiDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E1E24) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              const Icon(Icons.auto_awesome, color: Colors.purpleAccent),
              const SizedBox(width: 10),
              const Text('Ghost AI Assistant 👻', style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'How should the AI help you edit this photo?',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: 'e.g. make it warm, colorful and high contrast',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                  fillColor: isDark ? Colors.white10 : Colors.black54.withValues(alpha: 0.03),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _exampleChip(controller, 'Vibrant & Warm ☀️'),
                  _exampleChip(controller, 'Cool Vintage 🎞️'),
                  _exampleChip(controller, 'Dramatic Contrast 🎭'),
                ],
              )
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final prompt = controller.text.trim();
                if (prompt.isNotEmpty) {
                  Navigator.pop(ctx);
                  _runAiAssistant(prompt);
                }
              },
              style: ElevatedButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('Ask AI'),
            ),
          ],
        );
      },
    );
  }

  Widget _exampleChip(TextEditingController controller, String text) {
    return ActionChip(
      label: Text(text, style: const TextStyle(fontSize: 11)),
      onPressed: () {
        controller.text = text;
      },
    );
  }

  Future<void> _runAiAssistant(String prompt) async {
    if (_geminiApiKey == null) return;

    // Show loading overlay
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.purpleAccent),
              const SizedBox(height: 16),
              const Text(
                'Brewing AI magic... 👻✨',
                style: TextStyle(
                  color: Colors.white,
                  decoration: TextDecoration.none,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          ProImageEditor.file(
            File(widget.imageUrl),
            callbacks: ProImageEditorCallbacks(
              onImageEditingComplete: (bytes) async {
                try {
                  final tempDir = await getTemporaryDirectory();
                  final path = '${tempDir.path}/edited_${DateTime.now().millisecondsSinceEpoch}.jpg';
                  final file = File(path);
                  await file.writeAsBytes(bytes);
                  // Notify caller first so the Completer captures the path,
                  // then pop the editor. The caller awaits the push and opens
                  // the next dialog only after this route fully dismounts.
                  widget.onSave(path);
                  if (mounted) {
                    Navigator.pop(context);
                  }
                } catch (e) {
                  debugPrint("Error saving edited image: $e");
                }
              },
              onCloseEditor: (mode) {
                Navigator.pop(context);
              },
            ),
            configs: ProImageEditorConfigs(
              designMode: ImageEditorDesignMode.material,
              theme: ThemeData(
                useMaterial3: true,
                brightness: Theme.of(context).brightness,
                colorScheme: Theme.of(context).colorScheme,
                scaffoldBackgroundColor: Theme.of(context).scaffoldBackgroundColor,
                appBarTheme: AppBarTheme(
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  foregroundColor: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              mainEditor: MainEditorConfigs(
                enableZoom: true,
                tools: widget.forWallpaper
                    ? const [SubEditorMode.cropRotate]
                    : const [
                        SubEditorMode.cropRotate,
                        SubEditorMode.tune,
                        SubEditorMode.filter,
                        SubEditorMode.blur,
                        SubEditorMode.paint,
                        SubEditorMode.text,
                      ],
              ),
            ),
          ),
          
        ],
      ),
    );
  }
}