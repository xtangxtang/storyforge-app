import 'package:flutter/material.dart';
import '../config/app_config.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _llmBaseUrlController = TextEditingController();
  final _llmKeyController = TextEditingController();
  final _llmModelController = TextEditingController();
  final _imageBaseUrlController = TextEditingController();
  final _imageKeyController = TextEditingController();
  final _imageModelController = TextEditingController();
  final _videoBaseUrlController = TextEditingController();
  final _videoKeyController = TextEditingController();
  final _videoModelController = TextEditingController();
  final _proxyController = TextEditingController();
  final _seedanceUrlController = TextEditingController();
  final _seedanceEmailController = TextEditingController();
  final _seedancePasswordController = TextEditingController();
  bool _isLoading = true;
  bool _saving = false;
  String _videoMode = 'api';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    _llmBaseUrlController.text = AppConfig.llmBaseUrl;
    _llmKeyController.text = AppConfig.llmApiKey;
    _llmModelController.text = AppConfig.llmModel;
    _imageBaseUrlController.text = AppConfig.imageBaseUrl;
    _imageKeyController.text = AppConfig.imageApiKey;
    _imageModelController.text = AppConfig.imageModel;
    _videoBaseUrlController.text = AppConfig.videoBaseUrl;
    _videoKeyController.text = AppConfig.videoApiKey;
    _videoModelController.text = AppConfig.videoModel;
    _proxyController.text = AppConfig.httpsProxy;
    _seedanceUrlController.text = AppConfig.seedanceUrl;
    _seedanceEmailController.text = AppConfig.seedanceEmail;
    _seedancePasswordController.text = AppConfig.seedancePassword;
    _videoMode = AppConfig.videoGenerationMode;
    setState(() => _isLoading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await AppConfig.save(
      baseUrl: _llmBaseUrlController.text.trim(),
      apiKey: _llmKeyController.text.trim(),
      model: _llmModelController.text.trim(),
      imageBaseUrl: _imageBaseUrlController.text.trim(),
      imageApiKey: _imageKeyController.text.trim(),
      imageModel: _imageModelController.text.trim(),
      videoBaseUrl: _videoBaseUrlController.text.trim(),
      videoApiKey: _videoKeyController.text.trim(),
      videoModel: _videoModelController.text.trim(),
      videoGenerationMode: _videoMode,
      proxy: _proxyController.text.trim(),
      seedanceUrl: _seedanceUrlController.text.trim(),
      seedanceEmail: _seedanceEmailController.text.trim(),
      seedancePassword: _seedancePasswordController.text.trim(),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设置已保存')),
      );
    }
    setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('文本生成 (LLM)'),
            _textField('LLM Base URL', _llmBaseUrlController,
                hint:
                    'https://coding.dashscope.aliyuncs.com/v1 或 https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1',
                icon: Icons.link),
            const SizedBox(height: 12),
            _textField('LLM API Key', _llmKeyController,
                hint: 'sk-...（用于 qwen3.6-plus 文本生成）',
                icon: Icons.key,
                obscure: true),
            const SizedBox(height: 12),
            _textField('LLM 模型', _llmModelController,
                hint: 'qwen3.6-plus', icon: Icons.smart_toy),

            const SizedBox(height: 24),
            _sectionTitle('图像生成'),
            _textField('图像 Base URL', _imageBaseUrlController,
                hint:
                    'https://dashscope.aliyuncs.com 或 https://token-plan.cn-beijing.maas.aliyuncs.com（不要带 /v1 或 /compatible-mode）',
                icon: Icons.image),
            const SizedBox(height: 12),
            _textField('图像 API Key', _imageKeyController,
                hint: 'MAAS Token Plan API Key（用于 wan2.7-image-pro）',
                icon: Icons.key,
                obscure: true),
            const SizedBox(height: 12),
            _textField('图像模型', _imageModelController,
                hint: 'wan2.7-image-pro', icon: Icons.image_outlined),

            const SizedBox(height: 24),
            _sectionTitle('视频生成'),
            // Video generation mode selector
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade700),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('生成引擎',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 4),
                  RadioListTile<String>(
                    title: const Text('API 模式 (wan2.7-i2v)'),
                    subtitle: const Text('使用 DashScope API，需要配置 API Key',
                        style: TextStyle(fontSize: 12)),
                    value: 'api',
                    groupValue: _videoMode,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (v) => setState(() => _videoMode = v!),
                  ),
                  RadioListTile<String>(
                    title: const Text('Seedance Web 自动化'),
                    subtitle: const Text('使用 Seedance 2.0 网页，需要配置 Google 登录',
                        style: TextStyle(fontSize: 12)),
                    value: 'seedance',
                    groupValue: _videoMode,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (v) => setState(() => _videoMode = v!),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // Show API config fields when in API mode
            if (_videoMode == 'api') ...[
              _textField('视频 Base URL', _videoBaseUrlController,
                  hint:
                      'https://dashscope.aliyuncs.com 或 https://token-plan.cn-beijing.maas.aliyuncs.com',
                  icon: Icons.videocam),
              const SizedBox(height: 12),
              _textField('视频 API Key', _videoKeyController,
                  hint: 'MAAS Token Plan API Key 或 DashScope Key',
                  icon: Icons.key,
                  obscure: true),
              const SizedBox(height: 12),
              _textField('视频模型', _videoModelController,
                  hint: 'wan2.7-i2v', icon: Icons.videocam_outlined),
            ] else ...[
              // Seedance mode: show hint that Seedance settings below will be used
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade900.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline, size: 16, color: Colors.blue),
                        SizedBox(width: 8),
                        Text('Seedance Web 模式',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.blue,
                                fontSize: 13)),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                        '视频生成将使用下方 Seedance 网页自动化。\n'
                        '请确保已配置 Seedance 网址和 Google 登录信息。',
                        style: TextStyle(fontSize: 12, color: Colors.blue)),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),
            _sectionTitle('网络设置'),
            _textField('代理地址（可选）', _proxyController,
                hint: 'http://proxy.ims.intel.com:912', icon: Icons.cloud),

            const SizedBox(height: 24),
            _sectionTitle('Seedance 网页自动化'),
            _textField('Seedance 网址', _seedanceUrlController,
                hint: 'https://seedance.io/zh/seedance-2', icon: Icons.web),
            const SizedBox(height: 12),
            _textField('Google 邮箱', _seedanceEmailController,
                hint: 'yourname@gmail.com', icon: Icons.email, obscure: false),
            const SizedBox(height: 12),
            _textField('Google 密码', _seedancePasswordController,
                hint: '你的 Google 账号密码', icon: Icons.lock, obscure: true),
            const SizedBox(height: 8),
            const Text(
              '• 使用 Google 邮箱和密码登录 seedance.io\n'
              '• 当前凭据通过 SharedPreferences 保存在本机，建议优先手动登录或使用专用账号',
              style: TextStyle(color: Colors.orange, fontSize: 12),
            ),

            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: Text(_saving ? '保存中...' : '保存'),
              ),
            ),
            const SizedBox(height: 16),
            _sectionTitle('说明'),
            const Text(
              '• LLM Base URL 可配置为 DashScope 地址：https://coding.dashscope.aliyuncs.com/v1\n'
              '  或 MAAS 兼容地址：https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1\n'
              '• 图像/视频 Base URL 配置为 MAAS 平台基础地址：https://token-plan.cn-beijing.maas.aliyuncs.com（不带 /compatible-mode/v1）\n'
              '• MAAS 的 /compatible-mode/v1 仅支持 chat completions，不支持图像/视频生成接口\n'
              '• LLM API Key 用于调用 qwen3.6-plus 或 MAAS 模型（策划、编剧、分镜生成）\n'
              '• 图像/视频 API Key 配置为 MAAS Token Plan 的 Key\n'
              '• 视频生成引擎可选择 API 模式（wan2.7-i2v）或 Seedance Web 自动化',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(text,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold));
  }

  Widget _textField(String label, TextEditingController controller,
      {String? hint, IconData? icon, bool obscure = false}) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        prefixIcon: icon != null ? Icon(icon) : null,
      ),
    );
  }

  @override
  void dispose() {
    _llmBaseUrlController.dispose();
    _llmKeyController.dispose();
    _llmModelController.dispose();
    _imageBaseUrlController.dispose();
    _imageKeyController.dispose();
    _imageModelController.dispose();
    _videoBaseUrlController.dispose();
    _videoKeyController.dispose();
    _videoModelController.dispose();
    _proxyController.dispose();
    _seedanceUrlController.dispose();
    _seedanceEmailController.dispose();
    _seedancePasswordController.dispose();
    super.dispose();
  }
}
