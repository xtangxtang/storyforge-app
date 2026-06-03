import 'package:flutter/material.dart';
import '../config/app_config.dart';
import '../config/config_profile.dart';

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
  final _comfyuiUrlController = TextEditingController();
  final _arkBaseUrlController = TextEditingController();
  final _arkKeyController = TextEditingController();
  final _arkImageModelController = TextEditingController();
  final _arkVideoModelController = TextEditingController();
  final _proxyController = TextEditingController();
  final _seedanceUrlController = TextEditingController();
  final _seedanceEmailController = TextEditingController();
  final _seedancePasswordController = TextEditingController();
  bool _isLoading = true;
  bool _saving = false;

  String _activeId = '';
  String _imageProvider = 'dashscope'; // 'dashscope' | 'comfyui'
  String _videoChoice = 'api'; // 'api' | 'comfyui' | 'seedance'

  bool get _comfyuiInUse =>
      _imageProvider == 'comfyui' || _videoChoice == 'comfyui';
  bool get _arkInUse => _imageProvider == 'ark' || _videoChoice == 'ark';

  @override
  void initState() {
    super.initState();
    _loadFromConfig();
    setState(() => _isLoading = false);
  }

  /// Populate the form from the current AppConfig (active profile).
  void _loadFromConfig() {
    _activeId = AppConfig.activeProfileId;
    _llmBaseUrlController.text = AppConfig.llmBaseUrl;
    _llmKeyController.text = AppConfig.llmApiKey;
    _llmModelController.text = AppConfig.llmModel;
    _imageBaseUrlController.text = AppConfig.imageBaseUrl;
    _imageKeyController.text = AppConfig.imageApiKey;
    _imageModelController.text = AppConfig.imageModel;
    _videoBaseUrlController.text = AppConfig.videoBaseUrl;
    _videoKeyController.text = AppConfig.videoApiKey;
    _videoModelController.text = AppConfig.videoModel;
    _comfyuiUrlController.text = AppConfig.comfyuiBaseUrl;
    _arkBaseUrlController.text = AppConfig.arkBaseUrl;
    _arkKeyController.text = AppConfig.arkApiKey;
    _arkImageModelController.text = AppConfig.arkImageModel;
    _arkVideoModelController.text = AppConfig.arkVideoModel;
    _proxyController.text = AppConfig.httpsProxy;
    _seedanceUrlController.text = AppConfig.seedanceUrl;
    _seedanceEmailController.text = AppConfig.seedanceEmail;
    _seedancePasswordController.text = AppConfig.seedancePassword;
    _imageProvider = AppConfig.imageProvider;
    if (AppConfig.useArkForVideo) {
      _videoChoice = 'ark';
    } else if (AppConfig.useComfyuiForVideo) {
      _videoChoice = 'comfyui';
    } else if (AppConfig.useSeedanceForVideo) {
      _videoChoice = 'seedance';
    } else {
      _videoChoice = 'api';
    }
  }

  /// Map the radio choice to the persisted videoProvider value.
  String get _videoProvider => switch (_videoChoice) {
        'ark' => 'ark',
        'comfyui' => 'comfyui',
        _ =>
          'dashscope', // 'api' and 'seedance' both use the dashscope provider
      };

  /// Write the current form values into the active profile (no snackbar).
  Future<void> _persistForm() async {
    await AppConfig.save(
      baseUrl: _llmBaseUrlController.text.trim(),
      apiKey: _llmKeyController.text.trim(),
      model: _llmModelController.text.trim(),
      imageProvider: _imageProvider,
      imageBaseUrl: _imageBaseUrlController.text.trim(),
      imageApiKey: _imageKeyController.text.trim(),
      imageModel: _imageModelController.text.trim(),
      videoProvider: _videoProvider,
      videoBaseUrl: _videoBaseUrlController.text.trim(),
      videoApiKey: _videoKeyController.text.trim(),
      videoModel: _videoModelController.text.trim(),
      videoGenerationMode: _videoChoice == 'seedance' ? 'seedance' : 'api',
      comfyuiBaseUrl: _comfyuiUrlController.text.trim(),
      arkBaseUrl: _arkBaseUrlController.text.trim(),
      arkApiKey: _arkKeyController.text.trim(),
      arkImageModel: _arkImageModelController.text.trim(),
      arkVideoModel: _arkVideoModelController.text.trim(),
      proxy: _proxyController.text.trim(),
      seedanceUrl: _seedanceUrlController.text.trim(),
      seedanceEmail: _seedanceEmailController.text.trim(),
      seedancePassword: _seedancePasswordController.text.trim(),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await _persistForm();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设置已保存到当前 Profile')),
      );
    }
    setState(() => _saving = false);
  }

  Future<void> _switchProfile(String id) async {
    if (id == _activeId) return;
    await AppConfig.switchProfile(id);
    setState(_loadFromConfig);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已切换到「${AppConfig.activeProfile?.name ?? ''}」')),
      );
    }
  }

  Future<void> _saveAsNewProfile() async {
    final name = await _promptName('另存为新 Profile', '');
    if (name == null) return;
    await _persistForm(); // make runtime reflect the form
    final p = await AppConfig.createProfileFromCurrent(name);
    setState(_loadFromConfig);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已另存为「${p.name}」并切换')),
      );
    }
  }

  Future<void> _renameProfile() async {
    final current = AppConfig.activeProfile;
    if (current == null) return;
    final name = await _promptName('重命名 Profile', current.name);
    if (name == null) return;
    await AppConfig.renameProfile(_activeId, name);
    setState(() {});
  }

  Future<void> _deleteProfile() async {
    if (AppConfig.profiles.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('至少保留一个 Profile')),
      );
      return;
    }
    final name = AppConfig.activeProfile?.name ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 Profile'),
        content: Text('确定删除「$name」？此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await AppConfig.deleteProfile(_activeId);
    setState(_loadFromConfig);
  }

  Future<String?> _promptName(String title, String initial) async {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Profile 名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.isNotEmpty) Navigator.pop(ctx, v);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
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
            _profileCard(),
            const SizedBox(height: 24),
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
            _providerSelector(
              value: _imageProvider,
              options: const {
                'ark': '火山 Ark (Seedream 5.0 lite)',
                'dashscope': 'DashScope API (wan2.7-image)',
                'comfyui': 'ComfyUI 本地 (Qwen-Image)',
              },
              onChanged: (v) => setState(() => _imageProvider = v),
            ),
            const SizedBox(height: 12),
            if (_imageProvider == 'ark') ...[
              _textField('图像模型 (Ark)', _arkImageModelController,
                  hint: 'doubao-seedream-5.0-lite', icon: Icons.image_outlined),
            ] else if (_imageProvider == 'dashscope') ...[
              _textField('图像 Base URL', _imageBaseUrlController,
                  hint:
                      'https://dashscope.aliyuncs.com（不要带 /v1 或 /compatible-mode）',
                  icon: Icons.image),
              const SizedBox(height: 12),
              _textField('图像 API Key', _imageKeyController,
                  hint: 'MAAS Token Plan API Key（用于 wan2.7-image-pro）',
                  icon: Icons.key,
                  obscure: true),
              const SizedBox(height: 12),
              _textField('图像模型', _imageModelController,
                  hint: 'wan2.7-image-pro', icon: Icons.image_outlined),
            ] else ...[
              _textField('图像模型 (ComfyUI UNET 文件名)', _imageModelController,
                  hint: 'qwen_image_2512_fp8_e4m3fn.safetensors',
                  icon: Icons.image_outlined),
            ],
            const SizedBox(height: 24),
            _sectionTitle('视频生成'),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade700),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('生成引擎',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 4),
                  RadioListTile<String>(
                    title: const Text('火山 Ark (Seedance 2.0)'),
                    value: 'ark',
                    groupValue: _videoChoice,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (v) => setState(() => _videoChoice = v!),
                  ),
                  RadioListTile<String>(
                    title: const Text('DashScope API (wan2.7-i2v)'),
                    value: 'api',
                    groupValue: _videoChoice,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (v) => setState(() => _videoChoice = v!),
                  ),
                  RadioListTile<String>(
                    title: const Text('ComfyUI 本地 (Wan2.2-TI2V-5B)'),
                    value: 'comfyui',
                    groupValue: _videoChoice,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (v) => setState(() => _videoChoice = v!),
                  ),
                  RadioListTile<String>(
                    title: const Text('Seedance Web 自动化'),
                    value: 'seedance',
                    groupValue: _videoChoice,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (v) => setState(() => _videoChoice = v!),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (_videoChoice == 'ark') ...[
              _textField('视频模型 (Ark)', _arkVideoModelController,
                  hint: 'doubao-seedance-2.0', icon: Icons.videocam_outlined),
            ] else if (_videoChoice == 'api') ...[
              _textField('视频 Base URL', _videoBaseUrlController,
                  hint: 'https://dashscope.aliyuncs.com', icon: Icons.videocam),
              const SizedBox(height: 12),
              _textField('视频 API Key', _videoKeyController,
                  hint: 'MAAS Token Plan API Key 或 DashScope Key',
                  icon: Icons.key,
                  obscure: true),
              const SizedBox(height: 12),
              _textField('视频模型', _videoModelController,
                  hint: 'wan2.7-i2v', icon: Icons.videocam_outlined),
            ] else if (_videoChoice == 'comfyui') ...[
              _textField('视频模型 (ComfyUI UNET 文件名)', _videoModelController,
                  hint: 'wan2.2_ti2v_5B_fp16.safetensors',
                  icon: Icons.videocam_outlined),
            ] else ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade900.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                    '视频生成将使用下方 Seedance 网页自动化。\n请确保已配置 Seedance 网址和 Google 登录信息。',
                    style: TextStyle(fontSize: 12, color: Colors.blue)),
              ),
            ],
            if (_arkInUse) ...[
              const SizedBox(height: 24),
              _sectionTitle('火山 Ark 服务'),
              _textField('Ark Base URL', _arkBaseUrlController,
                  hint: 'https://ark.cn-beijing.volces.com/api/plan/v3',
                  icon: Icons.dns),
              const SizedBox(height: 12),
              _textField('Ark API Key', _arkKeyController,
                  hint: 'ark-...（火山方舟 agent plan 的 key）',
                  icon: Icons.key,
                  obscure: true),
              const SizedBox(height: 8),
              const Text(
                '• 图像用 Seedream 5.0 lite，视频用 Seedance 2.0（豆包）\n'
                '• 模型只跟随英文提示，应用会自动把中文提示翻成英文再发送\n'
                '• 文本生成 (策划/编剧) 仍走上方 LLM 配置',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
            if (_comfyuiInUse) ...[
              const SizedBox(height: 24),
              _sectionTitle('ComfyUI 服务'),
              _textField('ComfyUI Base URL', _comfyuiUrlController,
                  hint: 'http://172.16.116.208:8188', icon: Icons.dns),
              const SizedBox(height: 8),
              const Text(
                '• 自托管 ComfyUI 的 HTTP 地址；内网地址会自动绕过代理直连\n'
                '• 图像用 Qwen-Image，视频用 Wan2.2-TI2V-5B（图生视频）\n'
                '• 文本生成 (策划/编剧) 仍走上方 LLM 配置',
                style: TextStyle(color: Colors.grey, fontSize: 12),
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
                hint: 'yourname@gmail.com', icon: Icons.email),
            const SizedBox(height: 12),
            _textField('Google 密码', _seedancePasswordController,
                hint: '你的 Google 账号密码', icon: Icons.lock, obscure: true),
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
                label: Text(_saving ? '保存中...' : '保存到当前 Profile'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _profileCard() {
    // Show ComfyUI-backed profiles first (the preferred default), keeping the
    // original relative order within each group.
    bool isComfy(ConfigProfile p) =>
        p.imageProvider == 'comfyui' || p.videoProvider == 'comfyui';
    final profiles = [
      ...AppConfig.profiles.where(isComfy),
      ...AppConfig.profiles.where((p) => !isComfy(p)),
    ];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.primary),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_tree, size: 18),
              const SizedBox(width: 8),
              const Text('配置 Profile',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: profiles.any((p) => p.id == _activeId)
                ? _activeId
                : (profiles.isNotEmpty ? profiles.first.id : null),
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '当前 Profile',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.layers),
            ),
            items: [
              for (final p in profiles)
                DropdownMenuItem(value: p.id, child: Text(p.name)),
            ],
            onChanged: (v) {
              if (v != null) _switchProfile(v);
            },
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _saveAsNewProfile,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('另存为新 Profile'),
              ),
              OutlinedButton.icon(
                onPressed: _renameProfile,
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('重命名'),
              ),
              OutlinedButton.icon(
                onPressed: _deleteProfile,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('删除'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '切换 Profile 会丢弃未保存的修改；编辑后点下方「保存到当前 Profile」生效。',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _providerSelector({
    required String value,
    required Map<String, String> options,
    required ValueChanged<String> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade700),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('生成引擎',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 4),
          for (final entry in options.entries)
            RadioListTile<String>(
              title: Text(entry.value),
              value: entry.key,
              groupValue: value,
              contentPadding: EdgeInsets.zero,
              onChanged: (v) => onChanged(v!),
            ),
        ],
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
    _comfyuiUrlController.dispose();
    _arkBaseUrlController.dispose();
    _arkKeyController.dispose();
    _arkImageModelController.dispose();
    _arkVideoModelController.dispose();
    _proxyController.dispose();
    _seedanceUrlController.dispose();
    _seedanceEmailController.dispose();
    _seedancePasswordController.dispose();
    super.dispose();
  }
}
