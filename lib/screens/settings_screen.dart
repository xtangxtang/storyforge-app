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
  final _dashscopeKeyController = TextEditingController();
  final _proxyController = TextEditingController();
  bool _isLoading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    _llmBaseUrlController.text = AppConfig.llmBaseUrl;
    _llmKeyController.text = AppConfig.llmApiKey;
    _dashscopeKeyController.text = AppConfig.dashscopeApiKey;
    _proxyController.text = AppConfig.httpsProxy;
    setState(() => _isLoading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await AppConfig.save(
      baseUrl: _llmBaseUrlController.text.trim(),
      apiKey: _llmKeyController.text.trim(),
      dashscopeKey: _dashscopeKeyController.text.trim(),
      proxy: _proxyController.text.trim(),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('设置已保存')),
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
            const Text(
              'API 配置',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _llmBaseUrlController,
              decoration: const InputDecoration(
                labelText: 'LLM Base URL',
                hintText: 'https://coding.dashscope.aliyuncs.com/v1',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _llmKeyController,
              decoration: const InputDecoration(
                labelText: 'DashScope LLM API Key',
                hintText: 'sk-...（用于 qwen3.6-plus 文本生成）',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.key),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _dashscopeKeyController,
              decoration: const InputDecoration(
                labelText: 'DashScope 图视频 API Key',
                hintText: 'sk-...（用于 wan2.7 图像/视频生成）',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.image),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 24),
            const Text(
              '网络设置',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _proxyController,
              decoration: const InputDecoration(
                labelText: '代理地址（可选）',
                hintText: 'http://proxy.ims.intel.com:912',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.cloud),
              ),
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
            const Text(
              '说明',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              '• LLM Base URL 默认使用套餐专属 OpenAI 兼容地址\n'
              '• LLM API Key 用于调用 qwen3.6-plus 模型（策划、编剧、分镜生成）\n'
              '• 图视频 API Key 用于调用 wan2.7-image 和 wan2.7-i2v 模型\n'
              '• 两个 Key 可能相同，也可能不同，取决于您的 DashScope 账户配置',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _llmBaseUrlController.dispose();
    _llmKeyController.dispose();
    _dashscopeKeyController.dispose();
    _proxyController.dispose();
    super.dispose();
  }
}
