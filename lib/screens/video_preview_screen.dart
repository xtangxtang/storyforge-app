import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';

/// Full-screen video preview using WebView2.
///
/// First tries to navigate directly to the video URL (works for pages
/// with embedded video players like seedance.io result pages).
/// If it looks like a direct file URL (.mp4/.webm), falls back to an
/// HTML5 <video> player.
class VideoPreviewScreen extends StatefulWidget {
  final String videoUrl;
  final String? title;

  const VideoPreviewScreen({super.key, required this.videoUrl, this.title});

  @override
  State<VideoPreviewScreen> createState() => _VideoPreviewScreenState();
}

class _VideoPreviewScreenState extends State<VideoPreviewScreen> {
  final _controller = WebviewController();
  bool _loading = true;
  String _errorMsg = '';
  String _currentUrl = '';
  // Track whether we navigated to a direct URL or loaded HTML
  bool _isDirectNav = false;

  StreamSubscription<LoadingState>? _loadingSub;
  StreamSubscription<String>? _urlSub;

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  bool _isDirectVideoUrl(String url) {
    final lower = url.toLowerCase();
    // Direct file URLs: .mp4, .webm, .mov, .m3u8, blob:
    return lower.contains('.mp4') ||
        lower.contains('.webm') ||
        lower.contains('.mov') ||
        lower.contains('.m3u8') ||
        lower.startsWith('blob:') ||
        lower.startsWith('data:video');
  }

  Future<void> _initWebView() async {
    try {
      await _controller.initialize();
      await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);

      _loadingSub = _controller.loadingState.listen((state) {
        if (!mounted) return;
        setState(() {
          _loading = state == LoadingState.loading;
        });
      });

      _urlSub = _controller.url.listen((url) {
        if (!mounted) return;
        setState(() => _currentUrl = url);
      });

      final url = widget.videoUrl;

      if (url.startsWith('http://') || url.startsWith('https://')) {
        // Strategy: Navigate directly to the URL first.
        // This works for seedance.io result pages that show a video player.
        if (_isDirectVideoUrl(url)) {
          // Looks like a direct file URL — use HTML player
          _isDirectNav = false;
          await _loadDirectVideo(url);
        } else {
          // Assume it's a page URL — navigate directly
          _isDirectNav = true;
          await _controller.loadUrl(url);
        }
      } else {
        // Not a URL, try to load as-is or show error
        _isDirectNav = true;
        await _controller.loadUrl(url);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _errorMsg = e.toString();
        });
      }
    }
  }

  /// Load a direct video file URL via HTML5 <video> element
  Future<void> _loadDirectVideo(String url) async {
    final safeUrl = url
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;');

    // Use RGB instead of hex colors to avoid $ interpolation issues with CSS #codes
    final html = '''
<!DOCTYPE html>
<html style="margin:0;background:rgb(0,0,0);height:100%;">
<head>
  <meta charset="utf-8">
  <style>
    html, body { margin: 0; padding: 0; height: 100%; background: rgb(0,0,0); overflow: hidden; }
    video { width: 100%; height: 100%; object-fit: contain; background: rgb(0,0,0); }
    .loading { position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%);
               color: rgb(255,255,255); font-family: sans-serif; font-size: 16px; text-align: center; }
    .error-msg { position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%);
               color: rgb(255,255,255); font-family: sans-serif; font-size: 14px; text-align: center; max-width: 80%; word-break: break-all; }
  </style>
</head>
<body>
  <div class="loading" id="loading">正在加载视频...</div>
  <video controls autoplay playsinline preload="auto" id="player">
    <source src="$safeUrl" type="video/mp4">
    您的浏览器不支持视频播放
  </video>
  <script>
    const v = document.getElementById('player');
    const ld = document.getElementById('loading');
    v.addEventListener('canplay', function() { ld.style.display = 'none'; });
    v.addEventListener('error', function(e) {
      ld.style.display = 'none';
      var msg = document.createElement('div');
      msg.className = 'error-msg';
      msg.innerHTML = '视频加载失败<br><small style="color:rgb(136,136,136);">' + (v.error ? v.error.message : 'unknown error') + '</small>' +
        '<br><br><a href="' + v.src + '" target="_blank" style="color:rgb(79,195,247);">在新窗口打开</a>';
      document.body.appendChild(msg);
    });
  </script>
</body>
</html>
''';

    try {
      final bytes = utf8.encode(html);
      final base64Html = base64Encode(bytes);
      await _controller.loadUrl('data:text/html;base64,$base64Html');
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _errorMsg = '加载失败: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title ?? '视频预览'),
            if (_currentUrl.isNotEmpty && _currentUrl != widget.videoUrl)
              Text(
                _currentUrl.length > 60
                    ? '${_currentUrl.substring(0, 60)}...'
                    : _currentUrl,
                style: const TextStyle(fontSize: 9, color: Colors.grey),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          // If direct nav (page-based video), offer to open in external browser
          if (_isDirectNav && _currentUrl.isNotEmpty)
            Tooltip(
              message: '在外部浏览器打开',
              child: IconButton(
                icon: const Icon(Icons.open_in_browser),
                onPressed: () {
                  // Navigate to the current page URL - WebView handles it
                  // User can also right-click in WebView
                },
              ),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              setState(() => _loading = true);
              if (_isDirectNav) {
                await _controller.loadUrl(_currentUrl.isNotEmpty ? _currentUrl : widget.videoUrl);
              } else {
                await _loadDirectVideo(widget.videoUrl);
              }
            },
            tooltip: '刷新',
          ),
        ],
      ),
      body: _errorMsg.isNotEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 16),
                  const Text('视频加载失败', style: TextStyle(color: Colors.red)),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: SelectableText(
                      _errorMsg,
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            )
          : Stack(
              children: [
                Webview(_controller),
                if (_loading)
                  Container(
                    color: Colors.black,
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: Colors.white),
                          SizedBox(height: 16),
                          Text('正在加载视频...', style: TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  @override
  void dispose() {
    _loadingSub?.cancel();
    _urlSub?.cancel();
    _controller.dispose();
    super.dispose();
  }
}
