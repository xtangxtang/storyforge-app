import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../services/persistent_image_store.dart';

/// Storyboard data passed from project_detail_screen for batch video generation.
class SeedanceStoryboardItem {
  final String storyboardId;
  final String? imageUrl;
  final String? prompt;
  final String description;
  final int sceneNum;
  final int shotNum;
  /// Additional reference images (characters, props) to upload alongside the first frame.
  final List<String>? referenceImageUrls;

  SeedanceStoryboardItem({
    required this.storyboardId,
    required this.imageUrl,
    this.prompt,
    required this.description,
    required this.sceneNum,
    required this.shotNum,
    this.referenceImageUrls,
  });
}

/// Result of batch generation: maps storyboardId -> videoUrl
typedef BatchGenerationResult = Map<String, String>;

class SeedanceWebScreen extends StatefulWidget {
  /// Single mode: one storyboard (backward compatible).
  final String? initialImageUrl;
  final String? prompt;

  /// Batch mode: list of storyboards to process.
  final List<SeedanceStoryboardItem>? batchStoryboards;

  const SeedanceWebScreen({
    super.key,
    this.initialImageUrl,
    this.prompt,
    this.batchStoryboards,
  });

  bool get isBatchMode => batchStoryboards != null && batchStoryboards!.isNotEmpty;

  @override
  State<SeedanceWebScreen> createState() => _SeedanceWebScreenState();
}

class _SeedanceWebScreenState extends State<SeedanceWebScreen> {
  final _controller = WebviewController();
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _loading = true;
  String _currentUrl = '';
  bool _isLoggedIn = false;
  String _statusMessage = '正在加载 seedance.io...';

  // Single mode: extraction result
  String? _extractedVideoUrl;
  bool _videoExtracted = false;

  // Image injection state
  bool _injectingImage = false;
  bool _imageInjected = false;
  String _injectStatus = '';

  // Batch mode state
  bool _batchRunning = false;
  int _batchCurrentIndex = -1;
  final Map<String, String> _batchResults = {}; // storyboardId -> videoUrl
  final Map<String, String> _batchErrors = {}; // storyboardId -> error message
  bool _batchComplete = false;

  // Interactive mode (default): process one storyboard at a time with review
  bool _interactiveMode = true;
  int _interactiveCurrentIndex = 0;
  bool _interactiveGenerating = false;
  String? _interactiveVideoUrl;
  bool _interactiveApproved = false;
  bool _allowOffEntryNavigation = false;

  // Persistence keys
  static const String _prefBatchState = 'seedance_batch_state';
  static const String _prefBatchResults = 'seedance_batch_results';
  static const String _prefBatchErrors = 'seedance_batch_errors';
  bool _hasSavedState = false;

  StreamSubscription<String>? _urlSub;
  StreamSubscription<LoadingState>? _loadingSub;
  StreamSubscription<HistoryChanged>? _historySub;
  StreamSubscription<dynamic>? _messageSub;

  bool _isSeedanceEntryPage(String url) {
    final normalized = url.toLowerCase();
    return normalized.contains('seedance.io') && normalized.contains('/seedance-2');
  }

  bool _isSeedanceAllowedResultPage(String url) {
    final normalized = url.toLowerCase();
    return normalized.contains('/result') ||
        normalized.contains('/my-works') ||
        normalized.contains('/t-') ||
        normalized.contains('/image-to-video') ||
        normalized.contains('/i2v') ||
        normalized.contains('/ai-video-generator');
    // NOTE: /ai-image-generator is intentionally NOT included — it's the
    // AI Image Generator page, NOT the image-to-video tool we need.
  }

  bool _shouldForceBackToEntry(String url) {
    final normalized = url.toLowerCase();
    if (!normalized.contains('seedance.io')) return false;
    if (_isSeedanceEntryPage(normalized)) return false;
    if (_isSeedanceAllowedResultPage(normalized)) return false;
    return true;
  }

  @override
  void initState() {
    super.initState();
    _initWebView();
    // Load saved batch state in batch mode
    if (widget.isBatchMode) {
      Future.delayed(const Duration(seconds: 4), _loadSavedBatchState);
    }
  }

  Future<void> _initWebView() async {
    try {
      await _controller.initialize();
      await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);

      _urlSub = _controller.url.listen((url) {
        if (!mounted) return;
        setState(() => _currentUrl = url);

        // Redirect guard: keep the automation anchored on Seedance 2 until we
        // explicitly allow navigation to result pages after clicking generate.
        if (!_allowOffEntryNavigation && _shouldForceBackToEntry(url)) {
          debugPrint('Redirect guard: detected navigation away from /zh/seedance-2 to: $url');
          _controller.loadUrl(AppConfig.seedanceUrl);
        }
      });

      _loadingSub = _controller.loadingState.listen((state) {
        if (!mounted) return;
        setState(() {
          _loading = state == LoadingState.loading;
          if (_loading) {
            _statusMessage = '加载中...';
          }
        });
      });

      _historySub = _controller.historyChanged.listen((history) {
        if (!mounted) return;
        setState(() {
          _canGoBack = history.canGoBack;
          _canGoForward = history.canGoForward;
        });
      });

      _messageSub = _controller.webMessage.listen(_onWebMessage);

      setState(() => _statusMessage = '正在加载 seedance.io...');
      await _controller.loadUrl(AppConfig.seedanceUrl);
      await Future.delayed(const Duration(seconds: 5));

      // Post-load redirect check: ensure we're on a valid Seedance tool page
      // (not just /zh/seedance-2 but also /image-to-video, /ai-image-generator, etc.)
      if (_currentUrl.isNotEmpty &&
          _currentUrl.contains('seedance.io') &&
          !_isSeedanceEntryPage(_currentUrl) &&
          !_isSeedanceAllowedResultPage(_currentUrl)) {
        debugPrint('Page on unexpected Seedance page: $_currentUrl, navigating back to seedance-2');
        setState(() => _statusMessage = '页面被重定向，正在返回 seedance-2...');
        await _controller.loadUrl(AppConfig.seedanceUrl);
        await Future.delayed(const Duration(seconds: 5));
      }

      // Hide the example panels
      await _hideSeedanceExamples();

      // Auto login if credentials configured
      final email = AppConfig.seedanceEmail;
      final password = AppConfig.seedancePassword;
      if (email.isNotEmpty && password.isNotEmpty) {
        setState(() => _statusMessage = '正在尝试自动登录...');
        await _loginWithGoogle(email, password);
      }

      // Single mode: auto-inject image
      if (!widget.isBatchMode &&
          widget.initialImageUrl != null &&
          widget.initialImageUrl!.isNotEmpty) {
        await Future.delayed(const Duration(seconds: 2));
        await _injectImageToSeedance(widget.initialImageUrl!);
      }

      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _statusMessage = 'WebView 初始化失败: $e';
        });
      }
    }
  }

  // ===================================================================
  // Google Login
  // ===================================================================

  Future<void> _loginWithGoogle(String email, String password) async {
    final clickResult = await _clickGoogleSignInButton();
    setState(() => _statusMessage = 'Google登录: $clickResult');
    if (clickResult == 'no_google_button_found') {
      setState(() => _statusMessage = '未找到 Google 登录按钮，请手动登录');
      return;
    }

    await _waitForUrlContains('accounts.google.com', timeoutSeconds: 15);

    setState(() => _statusMessage = '正在填写 Google 邮箱...');
    final emailResult = await _fillGoogleEmail(email);
    setState(() => _statusMessage = '邮箱: $emailResult');
    if (emailResult == 'no_email_input') {
      setState(() => _statusMessage = '未找到邮箱输入框，请手动登录');
      return;
    }

    await _waitForUrlContains('accounts.google.com', timeoutSeconds: 10);
    await Future.delayed(const Duration(seconds: 3));

    setState(() => _statusMessage = '正在填写 Google 密码...');
    final passwordResult = await _fillGooglePassword(password);
    setState(() => _statusMessage = '密码: $passwordResult');
    if (passwordResult == 'no_password_input') {
      setState(() => _statusMessage = '未找到密码输入框，请手动登录');
      return;
    }

    setState(() => _statusMessage = '等待登录跳转...');
    await _waitForUrlContains('seedance.io', timeoutSeconds: 20);

    setState(() {
      _isLoggedIn = true;
      _statusMessage = 'Google 登录完成';
    });
  }

  Future<void> _triggerGoogleLogin() async {
    final email = AppConfig.seedanceEmail;
    final password = AppConfig.seedancePassword;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _statusMessage = '请先在设置中配置 Google 邮箱和密码');
      return;
    }
    await _loginWithGoogle(email, password);
  }

  Future<void> _triggerManualLogin() async {
    final result = await _clickGoogleSignInButton();
    setState(() => _statusMessage = '登录: $result');
  }

  Future<void> _showGoogleLoginSettings() async {
    final emailCtrl = TextEditingController(text: AppConfig.seedanceEmail);
    final passwordCtrl = TextEditingController(text: AppConfig.seedancePassword);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Google 登录设置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: emailCtrl,
              decoration: const InputDecoration(
                labelText: 'Google 邮箱',
                hintText: 'your-email@gmail.com',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passwordCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Google 密码',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '⚠️ 凭据将保存在本地。如果 Google 要求验证码或 2FA，自动登录可能失败，届时请手动登录。',
              style: TextStyle(fontSize: 11, color: Colors.orange),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存并登录'),
          ),
        ],
      ),
    );
    final emailValue = emailCtrl.text.trim();
    final passwordValue = passwordCtrl.text.trim();
    emailCtrl.dispose();
    passwordCtrl.dispose();
    if (saved == true) {
      await AppConfig.save(
        seedanceEmail: emailValue,
        seedancePassword: passwordValue,
      );
      if (emailValue.isNotEmpty && passwordValue.isNotEmpty) {
        await _loginWithGoogle(emailValue, passwordValue);
      }
    }
  }

  Future<String> _clickGoogleSignInButton() async {
    final script = '''
    (function() {
      const allEls = document.querySelectorAll('button, a, [role="button"], div, span, p, label');
      for (const el of allEls) {
        const text = (el.textContent || '').trim();
        const textLower = text.toLowerCase();
        if ((textLower.includes('google') && (textLower.includes('sign') || textLower.includes('log'))) ||
            text === 'Google' || text === 'Google 登录' ||
            textLower === 'sign in with google' ||
            text.includes('Sign in with Google') ||
            text === '登录' || text === '登 录' || text === '登陆') {
          if (el.tagName === 'BUTTON' || el.tagName === 'A' ||
              el.getAttribute('role') === 'button' ||
              el.onclick || el.getAttribute('data-testid')) {
            el.click();
            return 'clicked: "' + text.substring(0, 30) + '" (' + el.tagName + ')';
          }
        }
      }
      const headers = document.querySelectorAll('header, nav, [class*="header"], [class*="Header"]');
      for (const header of headers) {
        const googleBtns = header.querySelectorAll('button, a');
        for (const btn of googleBtns) {
          const html = btn.innerHTML || '';
          if (html.includes('google') || html.toLowerCase().includes('google')) {
            btn.click();
            return 'clicked_header_google: ' + btn.tagName;
          }
        }
      }
      const authLinks = document.querySelectorAll('a[href*="auth"], a[href*="login"], a[href*="signin"]');
      if (authLinks.length > 0) {
        authLinks[0].click();
        return 'clicked_auth_link: ' + authLinks[0].href.substring(0, 60);
      }
      const userIndicators = document.querySelectorAll(
        '[class*="avatar"], [class*="Avatar"], [class*="profile"], [class*="user"]'
      );
      for (const el of userIndicators) {
        const img = el.querySelector('img');
        if (img && img.src) return 'already_logged_in (found avatar)';
      }
      return 'no_google_button_found';
    })();
    ''';
    try {
      final result = await _controller.executeScript(script);
      return result?.toString() ?? 'error';
    } catch (e) { return 'error: $e'; }
  }

  Future<void> _waitForUrlContains(String pattern, {int timeoutSeconds = 15}) async {
    final startTime = DateTime.now();
    while (DateTime.now().difference(startTime).inSeconds < timeoutSeconds) {
      if (_currentUrl.contains(pattern)) return;
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<String> _fillGoogleEmail(String email) async {
    final script = '''
    (function() {
      const emailSelectors = [
        'input[type="email"]', 'input[name="identifier"]', 'input[name="Email"]',
        'input[autocomplete="username"]', 'input[autocomplete="email"]',
        'input[id*="identifierId"]', 'input[class*="whsOnd"]',
      ];
      for (const sel of emailSelectors) {
        const input = document.querySelector(sel);
        if (input && input.offsetParent !== null) {
          const nativeSetter = Object.getOwnPropertyDescriptor(
            window.HTMLInputElement.prototype, 'value')?.set;
          if (nativeSetter) nativeSetter.call(input, '%EMAIL%');
          else input.value = '%EMAIL%';
          input.dispatchEvent(new Event('input', { bubbles: true }));
          input.dispatchEvent(new Event('change', { bubbles: true }));
          input.dispatchEvent(new Event('blur', { bubbles: true }));
          setTimeout(() => {
            const nextBtns = document.querySelectorAll('button, [role="button"]');
            for (const btn of nextBtns) {
              const text = (btn.textContent || '').trim();
              if (text === 'Next' || text === '下一步' || text.toLowerCase() === 'next') {
                btn.click(); return;
              }
            }
            const form = document.querySelector('form');
            if (form) form.submit();
          }, 500);
          return 'email_filled_next_clicking';
        }
      }
      const passwordInputs = document.querySelectorAll('input[type="password"]');
      if (passwordInputs.length > 0 && passwordInputs[0].offsetParent !== null)
        return 'already_on_password_page';
      if (!window.location.href.includes('accounts.google.com'))
        return 'redirected_away_from_google';
      return 'no_email_input';
    })();
    ''';
    try {
      final escapedEmail = email.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
      final result = await _controller.executeScript(script.replaceAll('%EMAIL%', escapedEmail));
      return result?.toString() ?? 'error';
    } catch (e) { return 'error: $e'; }
  }

  Future<String> _fillGooglePassword(String password) async {
    final script = '''
    (function() {
      const passwordSelectors = [
        'input[type="password"]', 'input[name="password"]', 'input[name="Passwd"]',
        'input[autocomplete="current-password"]', 'input[id*="password"]',
        'input[class*="whsOnd"]',
      ];
      for (const sel of passwordSelectors) {
        const input = document.querySelector(sel);
        if (input && input.offsetParent !== null) {
          const nativeSetter = Object.getOwnPropertyDescriptor(
            window.HTMLInputElement.prototype, 'value')?.set;
          if (nativeSetter) nativeSetter.call(input, '%PASSWORD%');
          else input.value = '%PASSWORD%';
          input.dispatchEvent(new Event('input', { bubbles: true }));
          input.dispatchEvent(new Event('change', { bubbles: true }));
          setTimeout(() => {
            const buttons = document.querySelectorAll('button, [role="button"]');
            for (const btn of buttons) {
              const text = (btn.textContent || '').trim();
              if (text === 'Next' || text === '下一步' || text === 'Sign in' ||
                  text === '登录' || text.toLowerCase() === 'next' || text.toLowerCase() === 'sign in') {
                btn.click(); return;
              }
            }
            const form = document.querySelector('form');
            if (form) form.submit();
          }, 500);
          return 'password_filled_next_clicking';
        }
      }
      if (document.querySelector('[class*="g-recaptcha"], [class*="grecaptcha"], iframe[src*="recaptcha"]'))
        return 'captcha_detected_manual_login_needed';
      const allText = document.body.textContent || '';
      if (allText.includes('2-Step Verification') || allText.includes('verify it'))
        return '2fa_detected_manual_login_needed';
      if (!window.location.href.includes('accounts.google.com'))
        return 'redirected_away_login_success';
      return 'no_password_input';
    })();
    ''';
    try {
      final jsSafePassword = password.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
      final result = await _controller.executeScript(script.replaceAll('%PASSWORD%', jsSafePassword));
      return result?.toString() ?? 'error';
    } catch (e) { return 'error: $e'; }
  }

  // ===================================================================
  // Web Message Handler
  // ===================================================================

  void _onWebMessage(dynamic message) {
    if (message is Map<String, dynamic>) {
      final type = message['type'] as String?;
      if (type == 'video_url') {
        final url = message['url'] as String?;
        if (url != null && url.isNotEmpty) {
          if (mounted) {
            setState(() {
              _extractedVideoUrl = url;
              _videoExtracted = true;
              _statusMessage = '视频已提取！';
            });
          }
        }
      }
    }
  }

  // ===================================================================
  // Hide example panels
  // ===================================================================

  Future<void> _hideSeedanceExamples() async {
    try {
      final script = '''
      (function() {
        try {
          // Hide "示例图片" panel
          const allDivs = document.querySelectorAll('div');
          for (const el of allDivs) {
            const text = el.textContent || '';
            if (text.includes('示例图片') || text.includes('示例视频') || text.includes('生成的图片结果将显示在这里') || text.includes('生成的视频结果将显示在这里')) {
              // Hide the closest large container
              let parent = el;
              for (let i = 0; i < 5; i++) {
                if (!parent.parentElement) break;
                parent = parent.parentElement;
                const rect = parent.getBoundingClientRect();
                if (rect.width > 300 && rect.height > 200) {
                  parent.style.display = 'none';
                  break;
                }
              }
              el.style.display = 'none';
            }
          }
          // Also inject CSS rules
          const style = document.createElement('style');
          style.textContent = `
            [class*="preview"], [class*="Preview"], [class*="sample"], [class*="Sample"], [class*="result"], [class*="Result"] {
              display: none !important;
            }
            /* Fix sidebar scrolling */
            [class*="sidebar"], [class*="Sidebar"], [class*="menu"], [class*="Menu"],
            [class*="nav"], [class*="Nav"] {
              overflow-y: auto !important;
              max-height: 100vh !important;
            }
          `;
          document.head.appendChild(style);
          return 'done';
        } catch (e) {
          return 'error: ' + e.message;
        }
      })();
      ''';
      final result = await _controller.executeScript(script);
      debugPrint('Hide examples result: $result');
    } catch (e) {
      debugPrint('Hide examples failed: $e');
    }
  }

  // ===================================================================
  // Core Automation: Tab Switching, Image Upload, Prompt, Generate
  // ===================================================================

  Future<void> _switchToImageToVideoTab() async {
    setState(() => _statusMessage = '正在切换到图生视频...');

    final baseUrl = _currentUrl.contains('/zh/')
        ? _currentUrl.split('/zh/').firstOrNull ?? 'https://seedance.io'
        : 'https://seedance.io';

    // ============================================================
    // Method 1: Click "Seedance 2.0" in top nav bar first,
    // then find image-to-video from the canonical platform page
    // ============================================================
    try {
      setState(() => _statusMessage = '尝试从顶部导航进入 Seedance 2.0...');

      final seedance2Script = '''
      (function() {
        const allEls = document.querySelectorAll('a, button, [role="button"], [role="link"], div, span, li, p, nav *');
        for (const el of allEls) {
          const text = (el.textContent || el.innerText || '').trim();
          if (text.includes('Seedance 2.0') || text.includes('Seedance2.0') ||
              (text === 'Seedance 2.0')) {
            let target = el;
            // Walk up to find actual clickable element
            for (let i = 0; i < 8 && target.parentElement; i++) {
              const tag = target.tagName;
              if (tag === 'A' || tag === 'BUTTON' || tag === 'LI' ||
                  target.getAttribute('role') === 'button' ||
                  target.getAttribute('role') === 'link') break;
              target = target.parentElement;
            }
            const rect = target.getBoundingClientRect();
            const cx = rect.left + rect.width / 2;
            const cy = rect.top + rect.height / 2;
            target.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, cancelable: true, view: window, clientX: cx, clientY: cy}));
            target.dispatchEvent(new MouseEvent('mouseup', {bubbles: true, cancelable: true, view: window, clientX: cx, clientY: cy}));
            target.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window, clientX: cx, clientY: cy}));
            if (target.href) return 'clicked_seedance2:' + target.href;
            return 'clicked_seedance2_no_href';
          }
        }
        return 'seedance2_not_found';
      })();
      ''';
      final result = await _controller.executeScript(seedance2Script);
      debugPrint('Seedance 2.0 nav click result: ${result?.toString()}');
      await Future.delayed(const Duration(milliseconds: 2000));

      // Check if we got to seedance-2 page
      if (_currentUrl.contains('/seedance-2')) {
        setState(() => _statusMessage = '已进入 Seedance 2.0，正在找图生视频...');
      }
    } catch (e) {
      debugPrint('Method 1a (Seedance 2.0 nav) failed: $e');
    }

    // ============================================================
    // Method 2: Direct window.location.href to image-to-video
    // ============================================================
    final urlsToTry = [
      '$baseUrl/zh/image-to-video',
      '$baseUrl/zh/seedance-2/image-to-video',
      '$baseUrl/image-to-video',
      '$baseUrl/zh/i2v',
      '$baseUrl/i2v',
      '$baseUrl/zh/ai-video-generator',
    ];

    for (final url in urlsToTry) {
      try {
        debugPrint('Trying window.location.href = $url');
        final script = '(function() { window.location.href = "$url"; return "ok"; })();';
        await _controller.executeScript(script);
        await Future.delayed(const Duration(milliseconds: 2000));
        if (_isOnImageToVideoPage()) {
          setState(() => _statusMessage = '已切换到图生视频');
          return;
        }
      } catch (_) {}
    }

    // ============================================================
    // Method 3: Find "图生视频" in sidebar (video AI section)
    // ============================================================
    try {
      // Expand "视频AI" sidebar section first
      final expandScript = '''
      (function() {
        const allEls = document.querySelectorAll('a, button, [role="button"], [role="link"], div, span, li, p');
        for (const el of allEls) {
          const text = (el.textContent || el.innerText || '').trim();
          if (text === '视频AI' || text === '视频 AI') {
            let target = el;
            for (let i = 0; i < 5 && target.parentElement; i++) {
              const tag = target.tagName;
              if (tag === 'A' || tag === 'BUTTON' || tag === 'LI' ||
                  target.getAttribute('role') === 'button' ||
                  target.getAttribute('role') === 'link') break;
              target = target.parentElement;
            }
            const rect = target.getBoundingClientRect();
            target.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window, clientX: rect.left + rect.width/2, clientY: rect.top + rect.height/2}));
            return 'expanded_video_ai';
          }
        }
        return 'no_video_ai_section_found';
      })();
      ''';
      await _controller.executeScript(expandScript);
      await Future.delayed(const Duration(milliseconds: 1500));

      // Click "图生视频" in sidebar
      final clickScript = '''
      (function() {
        const allEls = document.querySelectorAll('a, button, [role="button"], [role="link"], div, span, li, p');
        for (const el of allEls) {
          const text = (el.textContent || el.innerText || '').trim();
          if (text === '图生视频') {
            let target = el;
            for (let i = 0; i < 5 && target.parentElement; i++) {
              const tag = target.tagName;
              if (tag === 'A' || tag === 'BUTTON' || tag === 'LI' ||
                  target.getAttribute('role') === 'button' ||
                  target.getAttribute('role') === 'link') break;
              target = target.parentElement;
            }
            const rect = target.getBoundingClientRect();
            const cx = rect.left + rect.width / 2;
            const cy = rect.top + rect.height / 2;
            target.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, cancelable: true, view: window, clientX: cx, clientY: cy}));
            target.dispatchEvent(new MouseEvent('mouseup', {bubbles: true, cancelable: true, view: window, clientX: cx, clientY: cy}));
            target.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window, clientX: cx, clientY: cy}));
            if (target.href) return 'clicked_i2v_href:' + target.href;
            return 'clicked_i2v:' + target.tagName;
          }
        }
        // Fallback: find by href pattern
        for (const el of allEls) {
          if (el.href && typeof el.href === 'string') {
            const href = el.href.toLowerCase();
            if (href.includes('image-to-video') || href.includes('/i2v')) {
              el.click();
              return 'clicked_by_href:' + el.href;
            }
          }
        }
        return 'i2v_element_not_found';
      })();
      ''';
      final result = await _controller.executeScript(clickScript);
      debugPrint('Sidebar click result: ${result?.toString()}');
      await Future.delayed(const Duration(seconds: 3));
      if (_isOnImageToVideoPage()) {
        setState(() => _statusMessage = '已切换到图生视频');
        return;
      }
    } catch (e) {
      debugPrint('Method 3 (sidebar click) failed: $e');
    }

    // ============================================================
    // Method 4: loadUrl fallback
    // ============================================================
    for (final url in urlsToTry.take(3)) {
      try {
        await _controller.loadUrl(url);
        await Future.delayed(const Duration(seconds: 3));
        if (_isOnImageToVideoPage()) {
          setState(() => _statusMessage = '已切换到图生视频');
          return;
        }
      } catch (_) {}
    }

    // ============================================================
    // All automatic methods failed — ask user to manually navigate
    // ============================================================
    setState(() => _statusMessage = '请手动切换到图生视频页面');

    if (mounted) {
      final userConfirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('需要手动操作'),
          content: const Text(
            '自动切换失败。请按照以下步骤操作：\n\n'
            '1. 点击页面顶部导航栏中的 "Seedance 2.0"\n'
            '2. 进入 Seedance 2.0 后，在左侧导航栏点击 "视频AI → 图生视频"\n\n'
            '确认进入正确的页面后，点击下方按钮继续。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('我已进入图生视频页面，继续'),
            ),
          ],
        ),
      );

      if (userConfirmed == true) {
        setState(() => _statusMessage = '用户已确认，开始生成');
        return;
      } else {
        setState(() => _statusMessage = '已取消');
        throw Exception('用户取消了页面切换');
      }
    }
  }

  bool _isOnImageToVideoPage() {
    return _currentUrl.contains('image-to-video') ||
        _currentUrl.contains('/i2v') ||
        _currentUrl.contains('ai-video-generator');
  }

  /// Switch to the "帧生成视频" (Frame to Video) sub-tab within image-to-video.
  /// Seedance 2.0 has sub-options: "参考生成视频" and "帧生成视频".
  /// For first-frame-based generation we need "帧生成视频".
  Future<void> _switchToFrameToVideoSubTab() async {
    final script = '''
    (function() {
      const allEls = document.querySelectorAll('button, a, [role="tab"], [role="button"], div, span, p, label, li');
      for (const el of allEls) {
        const text = (el.textContent || el.innerText || '').trim();
        if (text === '帧生成视频' || text === '首帧生成视频' ||
            text.toLowerCase() === 'frame to video' ||
            text.toLowerCase().includes('frame') && text.toLowerCase().includes('video')) {
          const style = window.getComputedStyle(el);
          if (el.tagName === 'BUTTON' || el.tagName === 'A' ||
              el.tagName === 'LI' || el.tagName === 'DIV' || el.tagName === 'SPAN' ||
              el.getAttribute('role') === 'tab' || el.getAttribute('role') === 'button' ||
              style.cursor === 'pointer') {
            el.click();
            return 'switched_to_frame2v: "' + text + '" (' + el.tagName + ')';
          }
        }
      }
      return 'frame2v_subtab_not_found';
    })();
    ''';
    try {
      final result = await _controller.executeScript(script);
      setState(() => _statusMessage = '子Tab: ${result?.toString() ?? "unknown"}');
    } catch (e) {
      setState(() => _statusMessage = '子Tab切换失败: $e');
    }
  }

  Future<String?> _downloadImageAsBase64(String imageUrl) async {
    try {
      List<int>? bytes;
      String mimeType = PersistentImageStore.guessMimeType(imageUrl);

      if (PersistentImageStore.isLocalPath(imageUrl)) {
        final filePath = PersistentImageStore.normalizeLocalPath(imageUrl);
        if (filePath != null && await File(filePath).exists()) {
          bytes = await File(filePath).readAsBytes();
        }
      } else {
        final response = await http.get(Uri.parse(imageUrl));
        if (response.statusCode == 200) {
          bytes = response.bodyBytes;
        }
      }

      if (bytes != null && bytes.isNotEmpty) {
        final base64String = base64Encode(bytes);
        if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
          mimeType = 'image/jpeg';
        } else if (bytes.length >= 4 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
          mimeType = 'image/png';
        } else if (bytes.length >= 4 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46) {
          mimeType = 'image/webp';
        }
        return 'data:$mimeType;base64,$base64String';
      }
    } catch (e) {
      debugPrint('Failed to download image: $e');
    }
    return null;
  }

  Future<void> _injectImageToSeedance(String imageUrl) async {
    if (_injectingImage) return;
    setState(() {
      _injectingImage = true;
      _statusMessage = '正在下载图片...';
    });

    final base64Data = await _downloadImageAsBase64(imageUrl);
    if (base64Data == null) {
      setState(() {
        _injectingImage = false;
        _statusMessage = '图片下载失败';
      });
      return;
    }

    setState(() => _statusMessage = '正在上传图片到 seedance.io...');
    final base64Only = base64Data.split(',').last;
    String mimeType = 'image/png';
    if (base64Data.startsWith('data:image/jpeg')) mimeType = 'image/jpeg';
    else if (base64Data.startsWith('data:image/webp')) mimeType = 'image/webp';

    const injectScript = '''
    (function() {
      function findFileInput() {
        const inputs = document.querySelectorAll('input[type="file"]');
        for (const input of inputs) {
          const accept = (input.getAttribute('accept') || '').toLowerCase();
          if (accept.includes('image') || accept.includes('.jpg') || accept.includes('.png') || accept.includes('.webp')) {
            return input;
          }
        }
        if (inputs.length > 0) return inputs[0];
        return null;
      }
      function findUploadButton() {
        const allEls = document.querySelectorAll('button, a, label, [role="button"]');
        for (const el of allEls) {
          const text = (el.textContent || el.innerText || '').trim();
          const textLower = text.toLowerCase();
          if (text === '+' || textLower === 'upload' || textLower === 'upload image' ||
              (textLower.includes('upload') && textLower.includes('image')) ||
              (textLower.includes('reference') && textLower.includes('image')) ||
              text === '添加' || text.includes('上传') ||
              text.includes('参考图片') || text.includes('参考图像')) {
            const parent = el.closest('[class*="image"], [class*="Image"], [class*="upload"], [class*="drop"], [class*="reference"]');
            if (parent) return {el, context: 'upload_area'};
            const nearby = el.parentElement?.textContent || '';
            const nearbyLower = nearby.toLowerCase();
            if (nearbyLower.includes('image') || nearbyLower.includes('upload') ||
                nearbyLower.includes('reference') || nearbyLower.includes('jpg') ||
                nearby.includes('图片') || nearby.includes('上传')) {
              return {el, context: 'nearby_text'};
            }
          }
        }
        return null;
      }
      function findDropZone() {
        const selectors = [
          '[class*="upload-zone"]', '[class*="UploadZone"]', '[class*="drop-zone"]',
          '[class*="dropzone"]', '[class*="upload-area"]', '[class*="image-upload"]',
          '[class*="ImageUpload"]', '[class*="reference-image"]', '[class*="ReferenceImage"]',
        ];
        for (const sel of selectors) {
          const zones = document.querySelectorAll(sel);
          for (const zone of zones) {
            const text = (zone.textContent || '').toLowerCase();
            if (text.includes('upload') || text.includes('drop') || text.includes('click') ||
                text.includes('image') || text.includes('drag') ||
                text.includes('上传') || text.includes('拖拽') || text.includes('图片')) {
              return zone;
            }
          }
        }
        const allDivs = document.querySelectorAll('div');
        for (const el of allDivs) {
          const computed = window.getComputedStyle(el);
          const text = (el.textContent || '').toLowerCase();
          if (computed.borderStyle?.includes('dashed') &&
              (text.includes('upload') || text.includes('image') || text.includes('参考') || text.includes('上传'))) {
            return el;
          }
        }
        return null;
      }
      try {
        const base64 = '%BASE64_DATA%';
        const mimeType = '%MIME_TYPE%';
        const binaryString = atob(base64);
        const len = binaryString.length;
        const bytes = new Uint8Array(len);
        for (let i = 0; i < len; i++) bytes[i] = binaryString.charCodeAt(i);
        const blob = new Blob([bytes], { type: mimeType });
        const file = new File([blob], 'storyforge_reference.png', { type: mimeType });

        let result = '';
        let fileInputSet = false;

        const fileInput = findFileInput();
        if (fileInput) {
          const dt = new DataTransfer();
          dt.items.add(file);
          fileInput.files = dt.files;
          fileInput.dispatchEvent(new Event('change', { bubbles: true }));
          fileInput.dispatchEvent(new Event('input', { bubbles: true }));
          result = 'file_input_direct: ' + fileInput.tagName;
          fileInputSet = true;
        }

        if (!fileInputSet) {
          const uploadBtn = findUploadButton();
          if (uploadBtn) {
            uploadBtn.el.click();
            result = 'clicked_upload_btn: ' + uploadBtn.el.tagName;
            setTimeout(() => {
              const newInput = findFileInput();
              if (newInput) {
                const dt2 = new DataTransfer();
                dt2.items.add(file);
                newInput.files = dt2.files;
                newInput.dispatchEvent(new Event('change', { bubbles: true }));
              }
            }, 300);
          }
        }

        if (!fileInputSet) {
          const dropZone = findDropZone();
          if (dropZone) {
            const dt = new DataTransfer();
            dt.items.add(file);
            dropZone.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt }));
            let p = dropZone.parentElement;
            while (p) {
              p.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt }));
              p = p.parentElement;
            }
            result += '; drop_zone_dispatched';
          }
        }

        return result || 'no_upload_element_found';
      } catch (err) {
        return 'error: ' + err.message;
      }
    })();
    ''';

    try {
      final script = injectScript
          .replaceAll('%BASE64_DATA%', base64Only)
          .replaceAll('%MIME_TYPE%', mimeType)
          .replaceAll('%FILE_NAME%', 'storyforge_reference.png');
      final result = await _controller.executeScript(script);
      setState(() {
        _injectingImage = false;
        final res = result?.toString() ?? 'unknown';
        if (res.contains('file_input') || res.contains('clicked_upload')) {
          _imageInjected = true;
          _injectStatus = res;
          _statusMessage = '图片已上传到 seedance.io';
        } else {
          _injectStatus = res;
          _statusMessage = '图片注入结果: $_injectStatus';
        }
      });
    } catch (e) {
      setState(() {
        _injectingImage = false;
        _statusMessage = '图片注入失败: $e';
      });
    }
  }

  /// Inject an additional reference image (character/prop) into Seedance.
  /// Unlike _injectImageToSeedance which targets the first image slot,
  /// this adds images to additional upload slots.
  Future<void> _injectAdditionalImage(String imageUrl) async {
    final base64Data = await _downloadImageAsBase64(imageUrl);
    if (base64Data == null) return;

    final base64Only = base64Data.split(',').last;
    String mimeType = 'image/png';
    if (base64Data.startsWith('data:image/jpeg')) mimeType = 'image/jpeg';
    else if (base64Data.startsWith('data:image/webp')) mimeType = 'image/webp';

    const injectScript = '''
    (function() {
      function findFileInputs() {
        const inputs = document.querySelectorAll('input[type="file"]');
        const imageInputs = [];
        for (const input of inputs) {
          const accept = (input.getAttribute('accept') || '').toLowerCase();
          if (accept.includes('image') || accept.includes('.jpg') || accept.includes('.png') || accept.includes('.webp')) {
            imageInputs.push(input);
          }
        }
        return imageInputs;
      }
      try {
        const base64 = '%BASE64_DATA%';
        const mimeType = '%MIME_TYPE%';
        const binaryString = atob(base64);
        const len = binaryString.length;
        const bytes = new Uint8Array(len);
        for (let i = 0; i < len; i++) bytes[i] = binaryString.charCodeAt(i);
        const blob = new Blob([bytes], { type: mimeType });
        const file = new File([blob], 'storyforge_ref.png', { type: mimeType });

        const inputs = findFileInputs();
        if (inputs.length > 1) {
          // Use only file inputs that don't already have files (skip first frame slot)
          let injected = false;
          for (const input of inputs) {
            if (input.files && input.files.length > 0) continue;
            const dt = new DataTransfer();
            dt.items.add(file);
            input.files = dt.files;
            input.dispatchEvent(new Event('change', { bubbles: true }));
            input.dispatchEvent(new Event('input', { bubbles: true }));
            injected = true;
            break;
          }
          if (injected) return 'additional_image_injected';
          // All slots occupied, try last one
          const lastInput = inputs[inputs.length - 1];
          const dt = new DataTransfer();
          dt.items.add(file);
          lastInput.files = dt.files;
          lastInput.dispatchEvent(new Event('change', { bubbles: true }));
          lastInput.dispatchEvent(new Event('input', { bubbles: true }));
          return 'additional_image_injected_last_slot';
        }
        // Fallback: click add/upload button to reveal more slots
        const allEls = document.querySelectorAll('button, label, [role="button"]');
        for (const el of allEls) {
          const text = (el.textContent || el.innerText || '').trim();
          if (text === '+' || text === '添加' || text.includes('添加')) {
            el.click();
            setTimeout(() => {
              const newInputs = findFileInputs();
              for (const input of newInputs) {
                if (!input.files || input.files.length === 0) {
                  const dt = new DataTransfer();
                  dt.items.add(file);
                  input.files = dt.files;
                  input.dispatchEvent(new Event('change', { bubbles: true }));
                  input.dispatchEvent(new Event('input', { bubbles: true }));
                  break;
                }
              }
            }, 500);
            return 'clicked_add_button';
          }
        }
        return 'no_additional_slot_found';
      } catch (err) {
        return 'error: ' + err.message;
      }
    })();
    ''';

    try {
      final script = injectScript
          .replaceAll('%BASE64_DATA%', base64Only)
          .replaceAll('%MIME_TYPE%', mimeType);
      await _controller.executeScript(script);
    } catch (e) {
      debugPrint('Additional image injection failed: $e');
    }
  }

  Future<void> _injectPromptToSeedance(String promptText) async {
    final script = '''
    (function() {
      function findPromptTextarea() {
        // Strategy 1: Find textarea by its containing section label
        const allLabels = document.querySelectorAll('label, span, p, div, h1, h2, h3, h4, h5, h6');
        for (const label of allLabels) {
          const text = (label.textContent || '').trim();
          if (text === '提示词' || text === 'Prompt' ||
              text.toLowerCase() === 'prompt' || text.includes('提示词') ||
              text.includes('提示')) {
            // Find textarea in the same section
            const section = label.parentElement || label.closest('div') || label.closest('section');
            if (section) {
              const tas = section.querySelectorAll('textarea');
              for (const ta of tas) {
                if (ta.offsetParent !== null) return ta;
              }
              // Also check for contenteditable
              const editables = section.querySelectorAll('[contenteditable="true"], [role="textbox"], [role="combobox"]');
              if (editables.length > 0) return editables[0];
            }
          }
        }
        // Strategy 2: Find textarea by character counter nearby
        const textareas = document.querySelectorAll('textarea');
        for (const ta of textareas) {
          if (ta.offsetParent === null) continue;
          const rect = ta.getBoundingClientRect();
          if (rect.width < 10 || rect.height < 10) continue;
          const placeholder = (ta.getAttribute('placeholder') || '').toLowerCase();
          // Look for textarea with create/prompt/describe placeholder that has a char counter nearby
          if ((placeholder.includes('what do you want') || placeholder.includes('create') ||
               placeholder.includes('prompt') || placeholder.includes('describe') ||
               placeholder.includes('提示') || placeholder.includes('描述')) &&
              placeholder.length > 5) {
            return ta;
          }
        }
        // Strategy 3: Find by nearby text "2000" (char counter)
        for (const ta of textareas) {
          if (ta.offsetParent === null) continue;
          const parent = ta.parentElement;
          if (!parent) continue;
          const siblingText = parent.textContent || '';
          if (siblingText.includes('2000') || siblingText.includes('2,000')) {
            return ta;
          }
        }
        // Strategy 4: Find the LARGEST visible textarea (prompt area is usually the biggest)
        let largestTa = null;
        let largestArea = 0;
        for (const ta of textareas) {
          if (ta.offsetParent === null) continue;
          const rect = ta.getBoundingClientRect();
          const area = rect.width * rect.height;
          if (area > largestArea) {
            largestArea = area;
            largestTa = ta;
          }
        }
        if (largestTa) return largestTa;
        // Fallback: last visible textarea
        for (let i = textareas.length - 1; i >= 0; i--) {
          if (textareas[i].offsetParent !== null) return textareas[i];
        }
        return null;
      }
      try {
        const el = findPromptTextarea();
        if (!el) return 'no_prompt_element_found';
        // Check if it's actually a textarea or a div-based editor
        const tag = el.tagName.toLowerCase();
        if (tag === 'div' || el.isContentEditable) {
          el.focus();
          el.textContent = '%PROMPT_TEXT%';
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return 'prompt_injected_div';
        }
        // For textarea: use multiple event dispatch approaches
        const nativeInputValueSetter = Object.getOwnPropertyDescriptor(
          window.HTMLTextAreaElement.prototype, 'value')?.set;
        if (nativeInputValueSetter) {
          nativeInputValueSetter.call(el, '%PROMPT_TEXT%');
        } else {
          el.value = '%PROMPT_TEXT%';
        }
        // Dispatch events in order that React expects
        el.dispatchEvent(new Event('focus', { bubbles: true }));
        el.dispatchEvent(new Event('input', { bubbles: true, cancelable: true }));
        el.dispatchEvent(new Event('change', { bubbles: true, cancelable: true }));
        el.dispatchEvent(new Event('blur', { bubbles: true }));
        // Also try React's synthetic event approach
        try {
          const setter = Object.getOwnPropertyDescriptor(el.__proto__, 'value')?.set;
          if (setter) setter.call(el, '%PROMPT_TEXT%');
        } catch(e) {}
        return 'prompt_injected: TEXTAREA (' + el.placeholder?.substring(0, 20) + ')';
      } catch (err) {
        return 'error: ' + err.message;
      }
    })();
    ''';
    try {
      final escapedPrompt = promptText
          .replaceAll('\\', '\\\\')
          .replaceAll("'", "\\'")
          .replaceAll('\n', '\\n')
          .replaceAll('\r', '\\n')
          .replaceAll('\t', ' ')
          .replaceAll('`', '\\`');
      final scriptText = script.replaceAll('%PROMPT_TEXT%', escapedPrompt);
      final result = await _controller.executeScript(scriptText);
      final res = result?.toString() ?? 'unknown';
      setState(() => _statusMessage = '提示词: $res');
    } catch (e) {
      setState(() => _statusMessage = '提示词注入失败: $e');
    }
  }

  Future<void> _clickSeedanceGenerate() async {
    final script = '''
    (function() {
      const buttons = document.querySelectorAll('button, a, [role="button"]');
      for (const btn of buttons) {
        const text = (btn.textContent || btn.innerText || '').trim();
        const textLower = text.toLowerCase();
        if (text === 'Create' || text === 'Generate' ||
            textLower === 'create' || textLower === 'generate' ||
            textLower === 'generate video' || textLower === 'start generating' ||
            text.includes('立即生成') || text.includes('生成视频') ||
            text.includes('开始生成') || text.includes('生成')) {
          btn.click();
          return 'clicked: "' + text.substring(0, 30) + '" (' + btn.tagName + ')';
        }
      }
      const bottomArea = document.querySelector(
        '[class*="footer"], [class*="Footer"], [class*="bottom"], [class*="Bottom"], ' +
        '[class*="action-bar"], [class*="ActionBar"]'
      );
      if (bottomArea) {
        const btns = bottomArea.querySelectorAll('button, [role="button"]');
        for (const btn of btns) {
          const bg = window.getComputedStyle(btn).background || '';
          if (bg.includes('gradient') || bg.includes('linear')) {
            btn.click();
            return 'clicked_gradient_btn: ' + btn.tagName;
          }
        }
        if (btns.length > 0) {
          btns[btns.length - 1].click();
          return 'clicked_last_btn_in_footer';
        }
      }
      const allButtons = document.querySelectorAll('button');
      if (allButtons.length > 0) {
        const btnTexts = [];
        for (const btn of allButtons) btnTexts.push(btn.textContent.trim().substring(0, 20));
        return 'no_match_found, buttons: [' + btnTexts.join(', ') + ']';
      }
      return 'no_button_found_at_all';
    })();
    ''';
    try {
      final result = await _controller.executeScript(script);
      setState(() => _statusMessage = '生成按钮: $result');
    } catch (e) {
      setState(() => _statusMessage = '点击生成按钮失败: $e');
    }
  }

  // ===================================================================
  // Video Extraction
  // ===================================================================

  Future<String?> _extractVideoUrl() async {
    const extractScript = '''
    (function() {
      const videoElements = document.querySelectorAll('video');
      for (const v of videoElements) {
        const src = v.src || v.currentSrc;
        if (src && src.length > 10 && !src.startsWith('blob:')) {
          // Skip page URLs like /zh/t-text-to-video
          if (src.includes('/zh/t-') || src.includes('/text-to-')) continue;
          return src;
        }
      }
      const downloadLinks = document.querySelectorAll(
        'a[href*=".mp4"], a[href*="download"], a[href*="blob:"]'
      );
      for (const link of downloadLinks) {
        if (link.href && !link.href.includes('/zh/t-') && !link.href.includes('/text-to-')) return link.href;
      }
      const allElements = document.querySelectorAll('[data-video-url], [data-src*="mp4"], [data-url*="video"]');
      for (const el of allElements) {
        const url = el.getAttribute('data-video-url') || el.getAttribute('data-src') || el.getAttribute('data-url');
        if (url && !url.includes('/zh/t-') && !url.includes('/text-to-')) return url;
      }
      const sources = document.querySelectorAll('source[src*="mp4"], source[src*="video"]');
      if (sources.length > 0 && sources[0].src) return sources[0].src;
      return null;
    })();
    ''';
    try {
      final result = await _controller.executeScript(extractScript);
      final url = result as String?;
      if (url != null && url.isNotEmpty && !url.startsWith('no_') && !url.startsWith('{')) {
        return url;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<void> _extractVideo() async {
    const extractScript = '''
    (function() {
      const videoElements = document.querySelectorAll('video');
      for (const v of videoElements) {
        const src = v.src || v.currentSrc;
        if (src && src.length > 10 && !src.startsWith('blob:')) {
          window.chrome.webview.postMessage({type: 'video_url', url: src});
          return 'video_element: ' + src.substring(0, 80);
        }
      }
      const downloadLinks = document.querySelectorAll(
        'a[href*=".mp4"], a[href*="download"], a[href*="blob:"]'
      );
      for (const link of downloadLinks) {
        if (link.href) {
          window.chrome.webview.postMessage({type: 'video_url', url: link.href});
          return 'download_link: ' + link.href.substring(0, 80);
        }
      }
      const allElements = document.querySelectorAll('[data-video-url], [data-src*="mp4"], [data-url*="video"]');
      for (const el of allElements) {
        const url = el.getAttribute('data-video-url') || el.getAttribute('data-src') || el.getAttribute('data-url');
        if (url) {
          window.chrome.webview.postMessage({type: 'video_url', url: url});
          return 'data_attr: ' + url.substring(0, 80);
        }
      }
      const sources = document.querySelectorAll('source[src*="mp4"], source[src*="video"]');
      if (sources.length > 0 && sources[0].src) {
        window.chrome.webview.postMessage({type: 'video_url', url: sources[0].src});
        return 'source_element: ' + sources[0].src.substring(0, 80);
      }
      const iframes = document.querySelectorAll('iframe');
      if (iframes.length > 0) return 'found_iframe, may contain video: ' + iframes[0].src;
      return 'no_video_found';
    })();
    ''';
    try {
      final result = await _controller.executeScript(extractScript);
      setState(() => _statusMessage = '视频提取: $result');
    } catch (e) {
      setState(() => _statusMessage = '提取失败: $e');
    }
  }

  /// Validate that a URL is a real video URL and not a tracking/share button link.
  bool _isValidVideoUrl(String url) {
    final lower = url.toLowerCase();
    final blocked = [
      'sharethis.com', 'addthis.com', 'addtoany.com', 'shareaholic.com',
      'pinterest.com/pin', 'twitter.com/intent', 'facebook.com/sharer',
      'linkedin.com/share', 'reddit.com/submit', 'wa.me', 't.me/share',
    ];
    for (final b in blocked) {
      if (lower.contains(b)) return false;
    }
    return lower.contains('mp4') || lower.contains('webm') ||
           lower.contains('.mov') || lower.contains('video') ||
           lower.contains('download') || lower.contains('result') ||
           lower.contains('tos-') || lower.contains('cdn') ||
           lower.contains('blob:');
  }

  /// Check if a video has been generated on the current page.
  /// Returns the video URL if found, null otherwise.
  Future<String?> _checkVideoGenerated() async {
    final deepUrl = await _deepExtractVideoUrl();
    if (deepUrl != null && _isValidVideoUrl(deepUrl)) return deepUrl;
    final url = await _extractVideoUrl();
    if (url != null && _isValidVideoUrl(url)) return url;
    final domUrl = await _domCheckVideoGenerated();
    if (domUrl != null && _isValidVideoUrl(domUrl)) return domUrl;
    return null;
  }

  /// Deep extraction: check page JavaScript variables, React state, fetch responses
  Future<String?> _deepExtractVideoUrl() async {
    const script = '''
    (function() {
      // Known demo/example paths to exclude
      const demoPaths = ['/seedance-demo/', '/seedream-demo/', '/seedance-example/', '/seedream-example/', '/example/', '/demo/'];
      function isDemo(src) {
        if (!src) return true;
        for (const p of demoPaths) { if (src.includes(p)) return true; }
        return false;
      }

      // 1. Check video element's currentSrc (including blob URLs)
      const videos = document.querySelectorAll('video');
      for (const v of videos) {
        const src = v.currentSrc || v.src;
        if (src && src.length > 10) {
          if (src.startsWith('blob:') || src.match(/\\.(mp4|webm|mov)(\\?|\$)/)) {
            if (!isDemo(src)) return 'blob_or_file:' + src;
          }
        }
      }

      // 2. Check all iframes for video player sources
      const iframes = document.querySelectorAll('iframe');
      for (const iframe of iframes) {
        const src = iframe.src || '';
        if (src && (src.includes('player') || src.includes('video') || src.includes('embed')) && !isDemo(src)) {
          return 'iframe:' + src;
        }
      }

      // 3. Check for Next.js/React window.__NEXT_DATA__ or similar
      try {
        if (window.__NEXT_DATA__ && window.__NEXT_DATA__.props) {
          const props = JSON.stringify(window.__NEXT_DATA__.props);
          const mp4Match = props.match(/https?:\\/\\/[^\\s"']+\\.mp4[^\\s"']*/i);
          if (mp4Match && !isDemo(mp4Match[0])) return 'next_data:' + mp4Match[0];
          const webmMatch = props.match(/https?:\\/\\/[^\\s"']+\\.webm[^\\s"']*/i);
          if (webmMatch && !isDemo(webmMatch[0])) return 'next_data:' + webmMatch[0];
        }
      } catch(e) {}

      // 4. Check window variables that might hold video URL
      const knownVars = ['videoUrl', 'video_url', 'resultUrl', 'result_url', 'outputUrl', 'output_url', 'videoSrc', 'downloadUrl'];
      for (const varName of knownVars) {
        if (window[varName] && typeof window[varName] === 'string' && window[varName].length > 10 && !isDemo(window[varName])) {
          return 'window_var:' + window[varName];
        }
      }

      // 5. Check for links with download attribute or video file extensions (NOT demo)
      const links = document.querySelectorAll('a[href]');
      for (const a of links) {
        const href = a.href || '';
        if (isDemo(href)) continue;
        if (href.match(/\\.(mp4|webm|mov)(\\?|\$)/i)) {
          return 'download_link:' + href;
        }
        if (a.getAttribute('download') && href.length > 20) {
          return 'download_attr:' + href;
        }
      }

      // 6. Skip CDN images entirely - they're too often demos/examples
      return null;
    })();
    ''';
    try {
      final result = await _controller.executeScript(script);
      final r = result as String?;
      if (r != null && r.length > 10 && !r.startsWith('null')) {
        final colonIdx = r.indexOf(':');
        if (colonIdx > 0) return r.substring(colonIdx + 1);
        return r;
      }
    } catch (_) {}
    return null;
  }

  /// Fallback DOM-based check
  Future<String?> _domCheckVideoGenerated() async {
    const checkScript = '''
    (function() {
      // Check all video elements (including blob: URLs)
      const videos = document.querySelectorAll('video');
      for (const v of videos) {
        const src = v.src || v.currentSrc;
        if (src && src.length > 10) {
          return 'video_src:' + src;
        }
      }
      // Check iframes for video sources
      const iframes = document.querySelectorAll('iframe');
      for (const iframe of iframes) {
        const src = iframe.src || '';
        if (src && (src.includes('.mp4') || src.includes('.webm') || src.includes('.mov') || src.includes('blob:'))) {
          return 'iframe_src:' + src;
        }
      }
      // Check for direct video file links only (NOT page URLs)
      const links = document.querySelectorAll('a');
      for (const a of links) {
        const href = a.href || '';
        const text = (a.textContent || '').trim().toLowerCase();
        // Only match actual video file URLs, not page URLs containing "video"
        if ((href.includes('.mp4') || href.includes('.webm') || href.includes('.mov') ||
             href.includes('blob:')) &&
            href.length > 20 && !href.includes('/zh/t-') && !href.includes('/text-to-')) {
          return 'link:' + href;
        }
        // Also match download links with clear download text
        if ((text.includes('download') || text.includes('下载') || text.includes('保存视频')) &&
            href.length > 20 && !href.includes('/zh/t-') && !href.includes('/text-to-')) {
          return 'download_link:' + href;
        }
      }
      // Check for video in data attributes
      const allEls = document.querySelectorAll('*');
      for (const el of allEls) {
        for (const attr of el.attributes) {
          const val = attr.value || '';
          if (val.length > 20 && (val.includes('.mp4') || val.includes('.webm') ||
              val.includes('.mov') || val.includes('blob:')) &&
              !val.includes('/zh/t-') && !val.includes('/text-to-')) {
            return 'attr_' + attr.name + ':' + val;
          }
        }
      }
      return null;
    })();
    ''';
    try {
      final result = await _controller.executeScript(checkScript);
      final r = result as String?;
      if (r != null && r.length > 10 && !r.startsWith('null')) {
        final colonIdx = r.indexOf(':');
        if (colonIdx > 0) return r.substring(colonIdx + 1);
        return r;
      }
    } catch (_) {}
    return null;
  }

  /// Check if seedance.io is showing a "generating" / loading state
  Future<bool> _isGeneratingInProgress() async {
    final script = '''
    (function() {
      const allText = document.body.textContent || '';
      // If page mentions generating, processing, creating, etc.
      if (allText.toLowerCase().includes('generating') ||
          allText.toLowerCase().includes('processing') ||
          allText.includes('生成中') ||
          allText.includes('处理中') ||
          allText.includes('创建中')) {
        return true;
      }
      // Check for loading spinners
      const spinners = document.querySelectorAll(
        '[class*="loading"], [class*="spinner"], [class*="Loading"], [class*="Spinner"], [class*="progress"]'
      );
      if (spinners.length > 0) return true;
      return false;
    })();
    ''';
    try {
      final result = await _controller.executeScript(script);
      return result == true;
    } catch (_) {
      return false;
    }
  }

  /// Wait for video to finish generating on seedance.io page.
  /// Polls for completion signals: new video element, download link, or page change.

  Future<String?> _waitForVideoGeneration({int timeoutMinutes = 5}) async {
    final timeout = Duration(minutes: timeoutMinutes);
    final startTime = DateTime.now();
    int pollCount = 0;
    String? previousUrl;

    while (DateTime.now().difference(startTime) < timeout) {
      if (!mounted) return null;

      pollCount++;
      final elapsed = DateTime.now().difference(startTime).inSeconds;

      // Check if video URL is available
      final videoUrl = await _checkVideoGenerated();
      if (videoUrl != null && _isValidVideoUrl(videoUrl)) {
        setState(() => _statusMessage = '视频生成完成！URL: ${videoUrl.substring(0, videoUrl.length > 50 ? 50 : videoUrl.length)}...');
        return videoUrl;
      }

      // Also check if still generating to give more info
      final stillGenerating = await _isGeneratingInProgress();

      // Run lightweight debug scan every poll to show what's on the page
      final debugInfo = await _quickVideoDebugScan();

      // Update status with debug info
      setState(() {
        _statusMessage = '等待视频... ${elapsed ~/ 60}分${elapsed % 60}秒 | 生成中: $stillGenerating | $debugInfo';
      });

      // Detect page navigation (URL change indicates we may be on a result page)
      final currentUrl = _currentUrl;
      if (previousUrl != null && currentUrl != previousUrl && currentUrl.isNotEmpty) {
        // Page navigated - wait a moment for result page to load, then extract
        await Future.delayed(const Duration(seconds: 5));

        // Try deep extraction first (blob URLs, JS variables, etc.)
        final deepUrl = await _deepExtractVideoUrl();
        if (deepUrl != null && _isValidVideoUrl(deepUrl)) {
          setState(() => _statusMessage = '视频生成完成！URL: ${deepUrl.substring(0, deepUrl.length > 50 ? 50 : deepUrl.length)}...');
          return deepUrl;
        }

        // If no direct video URL, check if this is a result page we should save
        final isDemoOrLanding = currentUrl.contains('/seedance-2') ||
            currentUrl.contains('/zh/ai-image') ||
            currentUrl.contains('/zh/text-to-video') ||
            currentUrl.contains('/zh/image-to-video') ||
            currentUrl.contains('/seedance-example') ||
            currentUrl.contains('/seedream-example') ||
            currentUrl.contains('/example/') ||
            currentUrl.contains('/demo/');
        if (currentUrl.contains('seedance.io') && !isDemoOrLanding &&
            currentUrl.length > 30 && _isValidVideoUrl(currentUrl)) {
          setState(() => _statusMessage = '检测到结果页面，保存页面URL: ${currentUrl.substring(0, currentUrl.length > 50 ? 50 : currentUrl.length)}...');
          return currentUrl;
        }
      }
      previousUrl = currentUrl;

      if (!stillGenerating) {
        // Not generating anymore - page might have changed
        await Future.delayed(const Duration(seconds: 3));
        final finalUrl = await _checkVideoGenerated();
        if (finalUrl != null) return finalUrl;
      }

      await Future.delayed(const Duration(seconds: 10));
    }

    setState(() => _statusMessage = '视频生成超时（${timeoutMinutes}分钟，共${pollCount}次检测）');
    return null;
  }

  /// Lightweight scan to show what's currently on the page for debugging.
  Future<String> _quickVideoDebugScan() async {
    final script = '''
    (function() {
      const videos = document.querySelectorAll('video').length;
      const iframes = document.querySelectorAll('iframe').length;
      const links = document.querySelectorAll('a').length;
      const spinners = document.querySelectorAll('[class*="loading"], [class*="spinner"], [class*="Loading"], [class*="Spinner"], [class*="progress"]').length;
      const bodyText = (document.body.textContent || '').toLowerCase();
      const hasGenerating = bodyText.includes('generating') || bodyText.includes('processing') || bodyText.includes('creating') || bodyText.includes('生成') || bodyText.includes('处理');
      const hasVideo = bodyText.includes('video') || bodyText.includes('mp4');
      const hasDownload = bodyText.includes('download') || bodyText.includes('save') || bodyText.includes('下载') || bodyText.includes('保存');

      // Check for any elements with video-like attributes
      let videoLikeCount = 0;
      const allEls = document.querySelectorAll('[data-*]');
      for (const el of allEls) {
        const attrs = el.getAttributeNames ? el.getAttributeNames() : [];
        for (const attr of attrs) {
          const val = el.getAttribute(attr) || '';
          if (val.includes('.mp4') || val.includes('.webm') || val.includes('video') || val.includes('blob:')) {
            videoLikeCount++;
            break;
          }
        }
      }

      // Find any visible buttons with key text
      const keyBtns = [];
      document.querySelectorAll('button, [role="button"]').forEach(el => {
        const text = (el.textContent || '').trim();
        if ((text.includes('Download') || text.includes('download') || text.includes('保存') || text.includes('下载') || text.includes('Create') || text.includes('generate')) && text.length < 30) {
          keyBtns.push(text.substring(0, 20));
        }
      });

      return '视频:\${videos} iframe:\${iframes} 链接:\${links} 加载器:\${spinners} 生成文本:\${hasGenerating} 视频文本:\${hasVideo} 下载文本:\${hasDownload} data属性:\${videoLikeCount} 关键按钮:[\${keyBtns.join(", ")}]';
    })();
    ''';
    try {
      final result = await _controller.executeScript(script);
      return result?.toString() ?? 'scan_failed';
    } catch (_) {
      return 'scan_error';
    }
  }

  // ===================================================================
  // Interactive Mode: Process one storyboard at a time with review
  // ===================================================================

  /// Process a single storyboard in interactive mode:
  /// navigate to Seedance 2.0 → upload images → fill prompt → STOP for manual generation
  Future<void> _processStoryboardInteractive(int index) async {
    final item = widget.batchStoryboards![index];
    setState(() {
      _allowOffEntryNavigation = false;
      _statusMessage = '正在处理镜头 ${item.sceneNum}-${item.shotNum}: ${item.description}...';
    });

    // Step 1: Navigate to Seedance 2.0 entry page
    final onMainPage = await _navigateToMainPage();
    if (!onMainPage) {
      setState(() {
        _interactiveVideoUrl = null;
        _interactiveGenerating = false;
        _interactiveApproved = false;
      });
      return;
    }
    await Future.delayed(const Duration(seconds: 2));

    // Step 2: Try to switch to Image-to-Video tab
    await _switchToImageToVideoTab();
    await Future.delayed(const Duration(seconds: 2));

    // Step 3: If still on ai-image-generator, ask user to manually switch
    if (!_isOnImageToVideoPage()) {
      setState(() => _statusMessage = '请手动点击顶部导航「视频AI → 图生视频」');

      if (mounted) {
        final userConfirmed = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('需要手动操作'),
            content: const Text(
              '请点击顶部导航栏的「视频AI → 图生视频」，\n'
              '进入图生视频页面后点击"继续"，我会自动上传图片并填入提示词。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('已进入，继续'),
              ),
            ],
          ),
        );

        if (userConfirmed != true) {
          setState(() {
            _interactiveGenerating = false;
            _statusMessage = '已取消';
          });
          return;
        }
      }
    }

    // Step 4: Upload reference images (characters/props/scenes)
    if (item.referenceImageUrls != null && item.referenceImageUrls!.isNotEmpty) {
      setState(() => _statusMessage = '正在上传参考角色/道具/场景图片...');
      int uploadedCount = 0;
      for (final refUrl in item.referenceImageUrls!) {
        if (uploadedCount >= 8) break;
        await _injectAdditionalImage(refUrl);
        uploadedCount++;
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    // Step 5: Upload first frame image (main reference)
    if (item.imageUrl != null && item.imageUrl!.isNotEmpty) {
      setState(() => _statusMessage = '正在上传首帧图（镜头 ${item.sceneNum}-${item.shotNum}）...');
      await _injectImageToSeedance(item.imageUrl!);
      await Future.delayed(const Duration(seconds: 3));
    }

    // Step 6: Fill prompt
    if (item.prompt != null && item.prompt!.isNotEmpty) {
      setState(() => _statusMessage = '正在注入提示词...');
      await _injectPromptToSeedance(item.prompt!);
      await Future.delayed(const Duration(seconds: 1));
    }

    // Step 7: STOP — let user review and manually click "立即生成"
    setState(() {
      _interactiveGenerating = false;
      _interactiveApproved = false;
      _statusMessage =
          '镜头 ${item.sceneNum}-${item.shotNum} 图片和提示词已填入，请确认无误后点击页面上的"立即生成"';
    });
  }

  /// Approve current video and continue to the next storyboard when available.
  Future<void> _approveAndNext() async {
    final item = widget.batchStoryboards![_interactiveCurrentIndex];
    if (_interactiveVideoUrl != null) {
      _batchResults[item.storyboardId] = _interactiveVideoUrl!;
    }
    await _saveBatchState();

    final nextIndex = _interactiveCurrentIndex + 1;
    if (nextIndex < widget.batchStoryboards!.length) {
      setState(() {
        _interactiveCurrentIndex = nextIndex;
        _batchCurrentIndex = nextIndex;
        _interactiveVideoUrl = null;
        _interactiveGenerating = true;
        _interactiveApproved = false;
        _statusMessage = '准备处理下一个镜头...';
      });
      await _processStoryboardInteractive(nextIndex);
      return;
    }

    setState(() {
      _batchComplete = true;
      _batchRunning = false;
    });
    await _clearSavedState();
    Navigator.pop(context, _batchResults);
  }

  /// User manually clicked "立即生成" on Seedance page, now extract video URL.
  /// This is called after the user confirms generation is done.
  Future<void> _extractAndApproveVideo() async {
    setState(() {
      _interactiveGenerating = true;
      _statusMessage = '正在提取视频链接...';
    });

    String? videoUrl;
    for (int attempt = 0; attempt < 5; attempt++) {
      videoUrl = await _checkVideoGenerated();
      if (videoUrl != null) break;
      await Future.delayed(const Duration(seconds: 3));
    }

    // Fallback: use current page URL if it's not a demo page
    if (videoUrl == null) {
      final currentPage = _currentUrl;
      final isDemo = currentPage.contains('/seedance-2') ||
          currentPage.contains('/zh/ai-image') ||
          currentPage.contains('/zh/text-to-video') ||
          currentPage.contains('/zh/image-to-video') ||
          currentPage.contains('/example/') ||
          currentPage.contains('/demo/');
      if (!isDemo && currentPage.contains('seedance.io') && currentPage.length > 20) {
        videoUrl = currentPage;
      }
    }

    setState(() {
      _interactiveGenerating = false;
    });

    if (videoUrl != null) {
      _batchResults[widget.batchStoryboards![_interactiveCurrentIndex].storyboardId] = videoUrl;
      await _saveBatchState();

      final nextIndex = _interactiveCurrentIndex + 1;
      if (nextIndex < widget.batchStoryboards!.length) {
        setState(() {
          _interactiveCurrentIndex = nextIndex;
          _batchCurrentIndex = nextIndex;
          _interactiveVideoUrl = null;
          _interactiveApproved = false;
          _statusMessage = '准备处理下一个镜头...';
        });
        await _processStoryboardInteractive(nextIndex);
      } else {
        setState(() {
          _batchComplete = true;
          _batchRunning = false;
        });
        await _clearSavedState();
        Navigator.pop(context, _batchResults);
      }
    } else {
      setState(() {
        _statusMessage = '未找到视频链接，请确认视频已生成完成';
      });
    }
  }

  /// Regenerate current storyboard: clear form and re-process
  Future<void> _regenerateCurrentStoryboard() async {
    setState(() {
      _allowOffEntryNavigation = false;
      _interactiveVideoUrl = null;
      _interactiveGenerating = true;
      _interactiveApproved = false;
      _statusMessage = '正在返回主页准备重新生成...';
    });
    final onMainPage = await _navigateToMainPage();
    if (!onMainPage) {
      setState(() {
        _interactiveGenerating = false;
      });
      return;
    }
    await _switchToImageToVideoTab();
    await Future.delayed(const Duration(seconds: 2));
    await _processStoryboardInteractive(_interactiveCurrentIndex);
  }

  /// Start interactive mode from current index
  Future<void> _startInteractiveGeneration() async {
    if (!widget.isBatchMode || widget.batchStoryboards!.isEmpty) return;

    setState(() {
      _batchRunning = true;
      _batchCurrentIndex = 0;
      _interactiveCurrentIndex = 0;
      _interactiveGenerating = true;
      _interactiveVideoUrl = null;
      _interactiveApproved = false;
      _batchComplete = false;
      _statusMessage = '开始逐个分镜生成 ${widget.batchStoryboards!.length} 个视频...';
    });

    // _processStoryboardInteractive handles navigation and I2V tab switching internally.
    await _processStoryboardInteractive(0);
  }

  // ===================================================================
  // Batch Processing (legacy full-auto mode)
  // ===================================================================

  /// Process a single storyboard: navigate to I2V page → upload reference images → upload first frame → prompt → generate → wait for video
  Future<String?> _processSingleStoryboard(SeedanceStoryboardItem item) async {
    setState(() {
      _allowOffEntryNavigation = false;
      _statusMessage = '正在处理镜头 ${item.sceneNum}-${item.shotNum}: ${item.description}...';
    });

    // Reset to the canonical Seedance 2 entry page before each automation run.
    final onMainPage = await _navigateToMainPage();
    if (!onMainPage) return null;
    await Future.delayed(const Duration(seconds: 2));

    // 1. Switch to Image-to-Video tab
    await _switchToImageToVideoTab();
    await Future.delayed(const Duration(seconds: 2));

    // 2. Switch to "帧生成视频" sub-tab
    await _switchToFrameToVideoSubTab();
    await Future.delayed(const Duration(seconds: 1));

    // 3. Upload additional reference images (characters/props/scenes) FIRST
    if (item.referenceImageUrls != null && item.referenceImageUrls!.isNotEmpty) {
      setState(() => _statusMessage = '正在上传参考角色/道具/场景图片...');
      int uploadedCount = 0;
      for (final refUrl in item.referenceImageUrls!) {
        if (uploadedCount >= 8) break;
        await _injectAdditionalImage(refUrl);
        uploadedCount++;
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    // 4. Upload first frame image (main reference)
    if (item.imageUrl != null && item.imageUrl!.isNotEmpty) {
      setState(() => _statusMessage = '正在上传首帧图（镜头 ${item.sceneNum}-${item.shotNum}）...');
      await _injectImageToSeedance(item.imageUrl!);
      await Future.delayed(const Duration(seconds: 3));
    }

    // 5. Fill prompt
    if (item.prompt != null && item.prompt!.isNotEmpty) {
      setState(() => _statusMessage = '正在注入提示词...');
      await _injectPromptToSeedance(item.prompt!);
      await Future.delayed(const Duration(seconds: 1));
    }

    // 6. Click "立即生成"
    setState(() => _statusMessage = '点击"立即生成"...');
    await _clickSeedanceGenerate();
    if (mounted) {
      setState(() => _allowOffEntryNavigation = true);
    }
    await Future.delayed(const Duration(seconds: 3));

    // 7. Wait for video to finish (stay on page, don't navigate away)
    setState(() => _statusMessage = '等待视频生成完成（镜头 ${item.sceneNum}-${item.shotNum}，可能需要2-5分钟）...');
    String? videoUrl = await _waitForVideoGeneration(timeoutMinutes: 8);

    // Fallback: if no direct URL, check if page navigated to result
    if (videoUrl == null) {
      final currentPage = _currentUrl;
      if (currentPage.contains('seedance.io') && currentPage.length > 20) {
        final isDemoOrLanding = currentPage.contains('/seedance-2') ||
            currentPage.contains('/zh/ai-image') ||
            currentPage.contains('/zh/text-to-video') ||
            currentPage.contains('/zh/image-to-video') ||
            currentPage.contains('/seedance-example') ||
            currentPage.contains('/seedream-example') ||
            currentPage.contains('/example/') ||
            currentPage.contains('/demo/');
        if (!isDemoOrLanding && _isValidVideoUrl(currentPage)) {
          setState(() => _statusMessage = '视频生成完成，保存结果页面...');
          videoUrl = currentPage;
        } else {
          debugPrint('Page is demo/landing or not a valid video URL: $currentPage');
        }
      }
    }

    if (mounted) {
      setState(() {
        _statusMessage = videoUrl != null
            ? '镜头 ${item.sceneNum}-${item.shotNum} 视频已生成'
            : '镜头 ${item.sceneNum}-${item.shotNum} 生成完成（未提取到视频URL）';
      });
    }

    return videoUrl;
  }

  /// Navigate back to the main seedance.io page for the next storyboard.
  /// This clears the form so we can upload a new image.
  Future<bool> _navigateToMainPage() async {
    for (int attempt = 0; attempt < 3; attempt++) {
      if (mounted) {
        setState(() {
          _allowOffEntryNavigation = false;
          _statusMessage = '正在进入 Seedance 2 页面...';
        });
      }

      await _controller.loadUrl(AppConfig.seedanceUrl);
      await Future.delayed(const Duration(seconds: 4));

      final currentUrl = _currentUrl;
      if (_isSeedanceEntryPage(currentUrl)) {
        return true;
      }
    }

    if (mounted) {
      setState(() {
        _statusMessage = '无法进入 Seedance 2 页面，当前页面: ${_currentUrl.isEmpty ? 'unknown' : _currentUrl}';
      });
    }
    return false;
  }

  /// Start batch processing all storyboards
  Future<void> _startBatchGeneration() async {
    if (!widget.isBatchMode || widget.batchStoryboards!.isEmpty) return;

    // Default to interactive mode (one at a time with review)
    if (_interactiveMode) {
      await _startInteractiveGeneration();
      return;
    }

    // Legacy full-auto mode: process all without review
    if (_batchResults.isNotEmpty || _batchErrors.isNotEmpty || _hasSavedState) {
      final shouldResume = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('发现已有进度'),
          content: Text(
            '已处理 ${_batchResults.length + _batchErrors.length}/${widget.batchStoryboards!.length} 个镜头\n'
            '是否保留已有结果并从上次中断处继续？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('重新开始'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('继续'),
            ),
          ],
        ),
      );

      if (shouldResume == true) {
        // Resume from where we left off
        final nextIndex = _findNextUnprocessedIndex();
        await _resumeBatchGeneration(nextIndex);
        return;
      } else {
        // Clear and start fresh
        _batchResults.clear();
        _batchErrors.clear();
        await _clearSavedState();
      }
    }

    setState(() {
      _batchRunning = true;
      _batchCurrentIndex = 0;
      _batchComplete = false;
      _statusMessage = '开始批量生成 ${widget.batchStoryboards!.length} 个视频...';
    });

    // First switch to I2V tab
    await _switchToImageToVideoTab();
    await Future.delayed(const Duration(seconds: 2));

    for (int i = 0; i < widget.batchStoryboards!.length; i++) {
      if (!mounted) return;

      final item = widget.batchStoryboards![i];
      setState(() {
        _batchCurrentIndex = i;
        _statusMessage = '[${i + 1}/${widget.batchStoryboards!.length}] 处理镜头 ${item.sceneNum}-${item.shotNum}: ${item.description}';
      });

      try {
        final videoUrl = await _processSingleStoryboard(item);

        if (videoUrl != null) {
          _batchResults[item.storyboardId] = videoUrl;
          setState(() {
            _statusMessage = '[${i + 1}/${widget.batchStoryboards!.length}] ✓ 视频生成完成';
          });
        } else {
          _batchErrors[item.storyboardId] = '视频生成超时或失败';
          setState(() {
            _statusMessage = '[${i + 1}/${widget.batchStoryboards!.length}] ✗ 视频生成失败';
          });
        }

        // Save progress after each item
        await _saveBatchState();

        // Navigate back to main page for next storyboard
        if (i < widget.batchStoryboards!.length - 1) {
          setState(() => _statusMessage = '正在返回主页准备下一个...');
          await _navigateToMainPage();
          await _switchToImageToVideoTab();
          await Future.delayed(const Duration(seconds: 2));
        }
      } catch (e) {
        _batchErrors[item.storyboardId] = e.toString();
        setState(() {
          _statusMessage = '[${i + 1}/${widget.batchStoryboards!.length}] ✗ 错误: $e';
        });
        await _saveBatchState();

        // Navigate back for next
        if (i < widget.batchStoryboards!.length - 1) {
          await _navigateToMainPage();
          await _switchToImageToVideoTab();
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }

    setState(() {
      _batchRunning = false;
      _batchComplete = true;
      _statusMessage = '批量生成完成！成功: ${_batchResults.length}, 失败: ${_batchErrors.length}';
    });
    await _saveBatchState();
  }

  /// Find the next unprocessed storyboard index
  int _findNextUnprocessedIndex() {
    for (int i = 0; i < widget.batchStoryboards!.length; i++) {
      final id = widget.batchStoryboards![i].storyboardId;
      if (!_batchResults.containsKey(id) && !_batchErrors.containsKey(id)) {
        return i;
      }
    }
    return widget.batchStoryboards!.length; // All done
  }

  /// Stop batch processing
  void _stopBatchGeneration() {
    setState(() {
      _batchRunning = false;
      _statusMessage = '批量生成已停止';
    });
  }

  /// Return results to previous screen
  void _finishAndReturn() {
    // Clear saved state on successful return
    _clearSavedState();
    Navigator.pop(context, _batchResults);
  }

  /// Save batch progress to shared_preferences
  Future<void> _saveBatchState() async {
    if (!widget.isBatchMode) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stateData = jsonEncode({
        'currentIndex': _batchCurrentIndex,
        'running': _batchRunning,
        'complete': _batchComplete,
        'timestamp': DateTime.now().toIso8601String(),
      });
      await prefs.setString(_prefBatchState, stateData);

      if (_batchResults.isNotEmpty) {
        await prefs.setString(_prefBatchResults, jsonEncode(_batchResults));
      }
      if (_batchErrors.isNotEmpty) {
        await prefs.setString(_prefBatchErrors, jsonEncode(_batchErrors));
      }
      setState(() => _hasSavedState = true);
      _showSaveToast('已保存当前进度');
    } catch (e) {
      debugPrint('保存状态失败: $e');
    }
  }

  /// Load previously saved batch state
  Future<void> _loadSavedBatchState() async {
    if (!widget.isBatchMode) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stateStr = prefs.getString(_prefBatchState);
      if (stateStr == null) return;

      final stateData = jsonDecode(stateStr) as Map<String, dynamic>;
      final timestamp = DateTime.parse(stateData['timestamp'] as String);
      final hoursSinceSave = DateTime.now().difference(timestamp).inHours;

      if (hoursSinceSave > 24) {
        // State too old, clear it
        await _clearSavedState();
        return;
      }

      final resultsStr = prefs.getString(_prefBatchResults);
      if (resultsStr != null) {
        final results = jsonDecode(resultsStr) as Map<String, dynamic>;
        for (final entry in results.entries) {
          _batchResults[entry.key] = entry.value as String;
        }
      }

      final errorsStr = prefs.getString(_prefBatchErrors);
      if (errorsStr != null) {
        final errors = jsonDecode(errorsStr) as Map<String, dynamic>;
        for (final entry in errors.entries) {
          _batchErrors[entry.key] = entry.value as String;
        }
      }

      final wasRunning = stateData['running'] == true;
      final wasComplete = stateData['complete'] == true;
      final savedIndex = stateData['currentIndex'] as int? ?? 0;

      if (wasComplete && _batchResults.isNotEmpty) {
        // Already completed - just show results
        setState(() {
          _batchComplete = true;
          _batchRunning = false;
          _batchCurrentIndex = savedIndex;
          _hasSavedState = true;
        });
        _showSaveToast('已恢复上次完成的批量结果');
      } else if (wasRunning || _batchResults.isNotEmpty || _batchErrors.isNotEmpty) {
        // Partially done - offer to resume
        final completedCount = _batchResults.length;
        final failedCount = _batchErrors.length;
        final totalCount = widget.batchStoryboards!.length;
        final remaining = totalCount - completedCount - failedCount;

        final shouldResume = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('发现未完成的批量任务'),
            content: Text(
              '上次批量生成已处理 ${completedCount + failedCount}/$totalCount 个镜头\n'
              '成功: $completedCount, 失败: $failedCount\n'
              '是否继续处理剩余 $remaining 个？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('重新开始'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('继续'),
              ),
            ],
          ),
        );

        if (shouldResume == true) {
          setState(() {
            _batchCurrentIndex = savedIndex;
            _hasSavedState = true;
          });
          // Start from where we left off
          await _resumeBatchGeneration(savedIndex);
        } else {
          // Restart from beginning
          await _clearSavedState();
        }
      }
    } catch (e) {
      debugPrint('加载状态失败: $e');
    }
  }

  /// Resume batch generation from a specific index
  Future<void> _resumeBatchGeneration(int startIndex) async {
    if (!widget.isBatchMode || widget.batchStoryboards!.isEmpty) return;

    setState(() {
      _batchRunning = true;
      _batchComplete = false;
      _statusMessage = '继续批量生成，从镜头 ${widget.batchStoryboards![startIndex].sceneNum}-${widget.batchStoryboards![startIndex].shotNum} 开始...';
    });

    // Switch to I2V tab
    await _switchToImageToVideoTab();
    await Future.delayed(const Duration(seconds: 2));

    for (int i = startIndex; i < widget.batchStoryboards!.length; i++) {
      if (!mounted) return;

      final item = widget.batchStoryboards![i];
      // Skip already processed items
      if (_batchResults.containsKey(item.storyboardId) ||
          _batchErrors.containsKey(item.storyboardId)) {
        continue;
      }

      setState(() {
        _batchCurrentIndex = i;
        _statusMessage = '[${i + 1}/${widget.batchStoryboards!.length}] 处理镜头 ${item.sceneNum}-${item.shotNum}: ${item.description}';
      });

      try {
        final videoUrl = await _processSingleStoryboard(item);

        if (videoUrl != null) {
          _batchResults[item.storyboardId] = videoUrl;
          setState(() {
            _statusMessage = '[${i + 1}/${widget.batchStoryboards!.length}] ✓ 视频生成完成';
          });
        } else {
          _batchErrors[item.storyboardId] = '视频生成超时或失败';
          setState(() {
            _statusMessage = '[${i + 1}/${widget.batchStoryboards!.length}] ✗ 视频生成失败';
          });
        }

        // Save progress after each item
        await _saveBatchState();

        // Navigate back to main page for next storyboard
        if (i < widget.batchStoryboards!.length - 1) {
          setState(() => _statusMessage = '正在返回主页准备下一个...');
          await _navigateToMainPage();
          await _switchToImageToVideoTab();
          await Future.delayed(const Duration(seconds: 2));
        }
      } catch (e) {
        _batchErrors[item.storyboardId] = e.toString();
        setState(() {
          _statusMessage = '[${i + 1}/${widget.batchStoryboards!.length}] ✗ 错误: $e';
        });
        await _saveBatchState();

        // Navigate back for next
        if (i < widget.batchStoryboards!.length - 1) {
          await _navigateToMainPage();
          await _switchToImageToVideoTab();
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }

    setState(() {
      _batchRunning = false;
      _batchComplete = true;
      _statusMessage = '批量生成完成！成功: ${_batchResults.length}, 失败: ${_batchErrors.length}';
    });
    await _saveBatchState();
  }

  /// Clear saved batch state
  Future<void> _clearSavedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefBatchState);
      await prefs.remove(_prefBatchResults);
      await prefs.remove(_prefBatchErrors);
      setState(() => _hasSavedState = false);
    } catch (e) {
      debugPrint('清除状态失败: $e');
    }
  }

  void _showSaveToast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontSize: 12)),
        duration: const Duration(seconds: 2),
        backgroundColor: Colors.green.shade800,
      ),
    );
  }

  // ===================================================================
  // Utility Buttons
  // ===================================================================

  Future<void> _confirmBackToApp() async {
    if (_batchRunning) {
      final shouldStop = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('批量生成进行中'),
          content: const Text('批量生成正在进行中，确定要返回吗？\n已生成的结果将会保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('返回'),
            ),
          ],
        ),
      );
      if (shouldStop != true) return;
      _stopBatchGeneration();
    }
    // Save state before leaving
    await _saveBatchState();
    Navigator.pop(context, _batchResults);
  }

  Future<void> _reload() async => await _controller.reload();
  Future<void> _goBack() async { if (_canGoBack) await _controller.goBack(); }
  Future<void> _goForward() async { if (_canGoForward) await _controller.goForward(); }

  Future<void> _manualInjectImage() async {
    final url = widget.initialImageUrl;
    if (url != null && url.isNotEmpty) await _injectImageToSeedance(url);
  }

  Future<void> _fullAuto() async {
    if (widget.initialImageUrl == null || widget.initialImageUrl!.isEmpty) {
      setState(() => _statusMessage = '没有可用的图片 URL');
      return;
    }
    await _switchToImageToVideoTab();
    await Future.delayed(const Duration(seconds: 2));
    await _injectImageToSeedance(widget.initialImageUrl!);
    await Future.delayed(const Duration(seconds: 2));
    if (widget.prompt != null && widget.prompt!.isNotEmpty) {
      setState(() => _statusMessage = '正在注入提示词...');
      await _injectPromptToSeedance(widget.prompt!);
      await Future.delayed(const Duration(seconds: 1));
    }
    setState(() => _statusMessage = '点击"Create"...');
    await _clickSeedanceGenerate();
    setState(() => _statusMessage = '等待视频生成中（可能需要2-5分钟）...');

    for (int i = 0; i < 30; i++) {
      await Future.delayed(const Duration(seconds: 15));
      if (!mounted) return;
      final currentUrl = _currentUrl;
      if (currentUrl.contains('/result') || currentUrl.contains('/video') ||
          (currentUrl.contains('seedance.io') && !currentUrl.contains('/seedance-2'))) {
        setState(() => _statusMessage = '检测到页面变化，尝试提取视频...');
        await _extractVideo();
        break;
      }
      if (i % 4 == 0) {
        setState(() => _statusMessage = '生成中... ${(i + 1) * 15}秒已等待');
      }
    }
    await _extractVideo();
  }

  Future<void> _copyVideoUrl() async {
    if (_extractedVideoUrl != null) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('视频链接'),
          content: SelectableText(_extractedVideoUrl!, style: const TextStyle(fontSize: 12)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      );
    }
  }

  Future<void> _debugInspectDOM() async {
    final script = '''
    (function() {
      const info = {
        url: window.location.href,
        title: document.title,
        fileInputs: [], textareas: [], buttons: [], selects: [], ranges: [], videos: [], images: [], iframes: [],
        loadingElements: [], generatingElements: [], resultElements: [],
        videoCandidates: [], downloadLinks: [],
        bodyTextKeywords: [],
        reactStateHints: [],
      };
      // File inputs
      document.querySelectorAll('input[type="file"]').forEach((el, i) => {
        info.fileInputs.push({i, name: el.name||'', accept: el.getAttribute('accept')||'', visible: el.offsetParent!==null});
      });
      // Textareas
      document.querySelectorAll('textarea').forEach((el, i) => {
        info.textareas.push({i, placeholder: (el.getAttribute('placeholder')||'').substring(0,60), classes: el.className?.substring(0,60)});
      });
      // Buttons (key ones)
      document.querySelectorAll('button, [role="button"]').forEach((el, i) => {
        const text = (el.textContent||'').trim();
        if (text.length > 0 && text.length < 80) {
          info.buttons.push({i, text: text.substring(0,40), tag: el.tagName, disabled: el.disabled||false, classes: (el.className||'').toString().substring(0,50)});
        }
      });
      if (info.buttons.length > 60) info.buttons = info.buttons.slice(0, 60);
      // Video elements
      document.querySelectorAll('video').forEach((el, i) => {
        info.videos.push({i, src: (el.src||el.currentSrc||'none').substring(0,120), readyState: el.readyState, playing: !el.paused});
      });
      // Image elements with meaningful URLs
      document.querySelectorAll('img[src], img[data-src]').forEach((el, i) => {
        const src = el.src || el.getAttribute('data-src') || '';
        if (src && !src.startsWith('data:') && src.length > 20) {
          info.images.push({i, src: src.substring(0,100)});
        }
      });
      if (info.images.length > 30) info.images = info.images.slice(0, 30);
      // iframes
      document.querySelectorAll('iframe').forEach((el, i) => {
        info.iframes.push({i, src: (el.src||'').substring(0,120), visible: el.offsetParent!==null});
      });
      // Loading/progress/spinner elements
      document.querySelectorAll('[class*="loading"], [class*="Loading"], [class*="spinner"], [class*="Spinner"], [class*="progress"], [class*="Progress"], [class*="animat"]').forEach((el, i) => {
        const text = (el.textContent||'').trim().substring(0,50);
        info.loadingElements.push({i, classes: (el.className||'').toString().substring(0,80), text: text});
      });
      if (info.loadingElements.length > 20) info.loadingElements = info.loadingElements.slice(0, 20);
      // Elements mentioning video/download/result keywords
      const allEls = document.querySelectorAll('a, [href], [data-*]');
      for (const el of allEls) {
        const attrs = el.getAttributeNames ? el.getAttributeNames() : [];
        for (const attr of attrs) {
          const val = el.getAttribute(attr) || '';
          if (val.length > 15 && val.length < 500 && (val.includes('.mp4') || val.includes('.webm') || val.includes('.mov') || val.includes('video') || val.includes('download') || val.includes('blob:') || val.includes('cdn') || val.includes('tos-'))) {
            info.videoCandidates.push({tag: el.tagName, attr: attr, value: val.substring(0,150)});
          }
        }
      }
      if (info.videoCandidates.length > 20) info.videoCandidates = info.videoCandidates.slice(0, 20);
      // Download links
      document.querySelectorAll('a[href]').forEach((el) => {
        const href = el.href || '';
        const text = (el.textContent||'').trim().substring(0,30);
        if (href.length > 20 && (href.includes('.mp4') || href.includes('.webm') || href.includes('download') || href.includes('blob:') || text.toLowerCase().includes('download') || text.includes('下载') || text.includes('保存'))) {
          info.downloadLinks.push({href: href.substring(0,150), text: text});
        }
      });
      // Body text keywords
      const bodyText = document.body.textContent || '';
      const keywords = ['generating', 'processing', 'creating', 'video', 'result', 'done', 'complete', 'error', 'failed', 'success', '生成', '处理', '创建', '视频', '结果', '完成', '失败', '错误'];
      for (const kw of keywords) {
        if (bodyText.toLowerCase().includes(kw)) info.bodyTextKeywords.push(kw);
      }
      // React/Vue hints
      const reactRoot = document.querySelector('[id*="root"], [id*="app"], #__next, #__nuxt');
      if (reactRoot) info.reactStateHints.push('found_root: ' + (reactRoot.id || reactRoot.className?.substring(0,30)));
      const hasReactFiber = !!document.querySelector('*[data-reactroot]');
      if (hasReactFiber) info.reactStateHints.push('data-reactroot found');
      return JSON.stringify(info, null, 2);
    })();
    ''';
    try {
      final result = await _controller.executeScript(script);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('DOM 详细调试'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(result?.toString() ?? 'null',
                style: const TextStyle(fontSize: 9, fontFamily: 'monospace')),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
        ),
      );
    } catch (e) {
      setState(() => _statusMessage = 'DOM调试失败: $e');
    }
  }

  // ===================================================================
  // Build
  // ===================================================================

  @override
  Widget build(BuildContext context) {
    final isBatch = widget.isBatchMode;
    final totalItems = isBatch ? widget.batchStoryboards!.length : 1;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isBatch ? 'Seedance 批量生成' : 'Seedance 浏览器'),
            if (_statusMessage.isNotEmpty)
              Text(_statusMessage,
                style: const TextStyle(fontSize: 10, color: Colors.grey),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Back to app button (always available)
            IconButton(
              icon: const Icon(Icons.home_outlined),
              onPressed: _confirmBackToApp,
              tooltip: '返回App',
            ),
            // Browser back button (only when available)
            if (_canGoBack)
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _goBack,
                tooltip: '网页后退',
                constraints: const BoxConstraints(minWidth: 32),
                padding: const EdgeInsets.all(4),
              ),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _canGoForward ? _goForward : null, tooltip: '前进'),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _reload, tooltip: '刷新'),
        ],
      ),
      body: Column(
        children: [
          // URL bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: Colors.grey.shade900,
            child: Row(
              children: [
                const Icon(Icons.link, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _currentUrl.isNotEmpty ? _currentUrl : AppConfig.seedanceUrl,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_loading) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
          ),

          // Batch progress (batch mode only)
          if (isBatch)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              color: Colors.grey.shade800,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '批量生成进度: ${_batchResults.length} 成功 / ${_batchErrors.length} 失败 / ${totalItems} 总计',
                        style: const TextStyle(fontSize: 12, color: Colors.white),
                      ),
                      const Spacer(),
                      // Mode toggle
                      if (!_batchRunning && !_interactiveGenerating)
                        TextButton.icon(
                          onPressed: () => setState(() => _interactiveMode = !_interactiveMode),
                          icon: Icon(_interactiveMode ? Icons.person : Icons.play_circle, size: 14),
                          label: Text(_interactiveMode ? '逐个审阅模式' : '全自动模式', style: const TextStyle(fontSize: 11)),
                          style: TextButton.styleFrom(foregroundColor: Colors.cyan, padding: EdgeInsets.zero),
                        ),
                      if (_batchRunning)
                        FilledButton.icon(
                          onPressed: _stopBatchGeneration,
                          icon: const Icon(Icons.stop, size: 14),
                          label: const Text('停止', style: TextStyle(fontSize: 11)),
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            backgroundColor: Colors.red,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          ),
                        ),
                    ],
                  ),
                  if (totalItems > 0)
                    LinearProgressIndicator(
                      value: (_batchCurrentIndex + 1) / totalItems,
                      minHeight: 4,
                    ),
                  // Interactive mode review controls
                  // Interactive mode: filled and waiting for manual generation
                  if (_interactiveMode && !_interactiveGenerating && _interactiveVideoUrl == null && _batchCurrentIndex < totalItems) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _extractAndApproveVideo,
                            icon: const Icon(Icons.play_arrow, size: 14),
                            label: const Text('视频已生成，提取并继续', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              backgroundColor: Colors.cyan,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  // Interactive mode: video extracted, awaiting approval
                  if (_interactiveMode && _interactiveVideoUrl != null && !_interactiveGenerating) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _regenerateCurrentStoryboard,
                            icon: const Icon(Icons.refresh, size: 14),
                            label: const Text('重新生成', style: TextStyle(fontSize: 11)),
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              foregroundColor: Colors.orange,
                              side: const BorderSide(color: Colors.orange),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _interactiveVideoUrl != null ? _approveAndNext : null,
                            icon: const Icon(Icons.check, size: 14),
                            label: const Text('通过，下一个', style: TextStyle(fontSize: 11)),
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              backgroundColor: Colors.green,
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  // Storyboard list (vertical scrollable, more compact)
                  if (isBatch && widget.batchStoryboards!.isNotEmpty)
                    SizedBox(
                      height: 48,
                      child: ListView.builder(
                        scrollDirection: Axis.vertical,
                        itemCount: widget.batchStoryboards!.length,
                        itemBuilder: (ctx, i) {
                          final item = widget.batchStoryboards![i];
                          final hasResult = _batchResults.containsKey(item.storyboardId);
                          final hasError = _batchErrors.containsKey(item.storyboardId);
                          final isCurrentAuto = i == _batchCurrentIndex && _batchRunning;
                          final isCurrentInteractive = _interactiveMode && i == _interactiveCurrentIndex && _batchCurrentIndex < totalItems;

                          return Container(
                            height: 28,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            decoration: BoxDecoration(
                              color: isCurrentAuto || isCurrentInteractive ? Colors.orange.shade800 :
                                     hasResult ? Colors.green.shade900 :
                                     hasError ? Colors.red.shade900 : Colors.grey.shade700,
                              borderRadius: BorderRadius.circular(3),
                              border: (isCurrentAuto || isCurrentInteractive) ? Border.all(color: Colors.orange, width: 1) : null,
                            ),
                            child: Row(
                              children: [
                                Text(
                                  '${item.sceneNum}-${item.shotNum}',
                                  style: const TextStyle(fontSize: 14, color: Colors.white, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    item.description,
                                    style: const TextStyle(fontSize: 13, color: Colors.white),
                                    maxLines: 1, overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (hasResult) const Text('✓', style: TextStyle(fontSize: 14, color: Colors.greenAccent)),
                                if (hasError) const Text('✗', style: TextStyle(fontSize: 14, color: Colors.redAccent)),
                                if (isCurrentInteractive && _interactiveGenerating)
                                  const Text('生成中', style: TextStyle(fontSize: 12, color: Colors.orangeAccent)),
                                if (isCurrentInteractive && !_interactiveGenerating && _interactiveVideoUrl == null)
                                  const Text('待确认', style: TextStyle(fontSize: 12, color: Colors.cyan)),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),

          // Automation toolbar — keep only buttons relevant to the workflow:
          // tab switching, batch generation, returning to app, extracting video
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(bottom: BorderSide(color: Colors.grey.shade800)),
            ),
            child: Wrap(
              spacing: 6, runSpacing: 4,
              children: [
                // Tab switching (needed for image-to-video tab)
                OutlinedButton.icon(
                  onPressed: _switchToImageToVideoTab,
                  icon: const Icon(Icons.tab, size: 14),
                  label: const Text('切到图生视频', style: TextStyle(fontSize: 11)),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: Colors.cyan,
                    side: const BorderSide(color: Colors.cyan),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                ),
                // Batch mode: start generation
                if (isBatch && !_interactiveGenerating && _interactiveVideoUrl == null)
                  FilledButton.icon(
                    onPressed: _batchRunning ? null : _startBatchGeneration,
                    icon: Icon(_interactiveMode ? Icons.person : Icons.play_arrow, size: 14),
                    label: Text(_interactiveMode ? '开始逐个生成' : '开始全自动', style: const TextStyle(fontSize: 11)),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      backgroundColor: _interactiveMode ? Colors.cyan : Colors.orange,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    ),
                  ),
                // Interactive mode: show generating indicator
                if (isBatch && _interactiveGenerating)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade800,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                        SizedBox(width: 8),
                        Text('生成中...', style: TextStyle(fontSize: 11, color: Colors.white)),
                      ],
                    ),
                  ),
                // Batch complete: return button
                if (isBatch && _batchComplete)
                  FilledButton.icon(
                    onPressed: _finishAndReturn,
                    icon: const Icon(Icons.check_circle, size: 14),
                    label: const Text('完成并返回', style: TextStyle(fontSize: 11)),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      backgroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    ),
                  ),
                // Video extraction
                FilledButton.icon(
                  onPressed: _extractVideo,
                  icon: const Icon(Icons.download, size: 14),
                  label: const Text('提取视频', style: TextStyle(fontSize: 11)),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                ),
              ],
            ),
          ),

          // Video preview for interactive mode (when video is generated and ready for review)
          if (isBatch && _interactiveMode && _interactiveVideoUrl != null && !_interactiveGenerating)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: Colors.green.shade800,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.play_circle_filled, color: Colors.white, size: 24),
                      const SizedBox(width: 8),
                      Text(
                        '视频已生成！点击下方按钮查看',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: () {
                          _controller.loadUrl(_interactiveVideoUrl!);
                        },
                        icon: const Icon(Icons.play_arrow, size: 16),
                        label: const Text('打开视频', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.green.shade800,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _interactiveVideoUrl!,
                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),

          // Video URL display (single mode)
          if (!isBatch && _videoExtracted && _extractedVideoUrl != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: Colors.green.shade900.withOpacity(0.3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('已提取视频链接:', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  SelectableText(_extractedVideoUrl!, style: const TextStyle(fontSize: 11, color: Colors.green)),
                ],
              ),
            ),

          // Batch results summary
          if (isBatch && _batchComplete && _batchResults.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: Colors.green.shade900.withOpacity(0.3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('批量生成结果:', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  ..._batchResults.entries.map((e) => Text(
                    '✓ ${e.key}: ${e.value.length > 60 ? e.value.substring(0, 60) + '...' : e.value}',
                    style: const TextStyle(fontSize: 10, color: Colors.greenAccent),
                  )),
                  if (_batchErrors.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    ..._batchErrors.entries.map((e) => Text(
                      '✗ ${e.key}: ${e.value}',
                      style: const TextStyle(fontSize: 10, color: Colors.redAccent),
                    )),
                  ],
                ],
              ),
            ),

          // WebView content
          Expanded(
            child: _loading && _currentUrl.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('正在初始化 WebView2...'),
                      ],
                    ),
                  )
                : Webview(_controller, permissionRequested: _onPermissionRequested),
          ),
        ],
      ),
    );
  }

  FutureOr<WebviewPermissionDecision> _onPermissionRequested(
    String url, WebviewPermissionKind kind, bool isUserInitiated,
  ) => WebviewPermissionDecision.allow;

  @override
  void dispose() {
    _urlSub?.cancel();
    _loadingSub?.cancel();
    _historySub?.cancel();
    _messageSub?.cancel();
    _controller.dispose();
    super.dispose();
  }
}
