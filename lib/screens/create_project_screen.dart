import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../config/app_config.dart';
import '../db/dao/dao.dart';
import '../models/models.dart';
import '../core/director_agent.dart';
import '../core/agent.dart';
import '../services/llm_service.dart';
import '../services/app_logger.dart';
import 'project_detail_screen.dart';

class CreateProjectScreen extends StatefulWidget {
  const CreateProjectScreen({super.key});

  @override
  State<CreateProjectScreen> createState() => _CreateProjectScreenState();
}

class _CreateProjectScreenState extends State<CreateProjectScreen> {
  final _promptController = TextEditingController();
  final _projectDao = ProjectDao();
  final _llm = LlmService();

  bool _creating = false;
  String _currentStage = '';
  String _statusText = '';

  Future<void> _createProject() async {
    if (_promptController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入创意描述')),
      );
      return;
    }

    if (!AppConfig.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先在设置页面配置 API Key'),
        ),
      );
      return;
    }

    setState(() {
      _creating = true;
      _currentStage = 'planning';
      _statusText = '正在初始化...';
    });

    try {
      final projectId = 'proj_${const Uuid().v4().substring(0, 8)}';
      await AppLogger.info(
        'Project creation started',
        data: {
          'projectId': projectId,
          'promptLength': _promptController.text.trim().length,
          'llmBaseUrl': AppConfig.llmBaseUrl,
          'proxy': AppConfig.httpsProxy.isEmpty ? 'DIRECT' : AppConfig.httpsProxy,
        },
      );

      final project = Project(
        id: projectId,
        name: _promptController.text.trim().substring(0, 20),
        state: 'planning',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

      await _projectDao.insert(project);

      // Run DirectorAgent pipeline
      final director = DirectorAgent(llm: _llm);

      // Stage 1: Planning
      setState(() {
        _currentStage = '策划';
        _statusText = '正在生成策划方案...';
      });
      await AppLogger.info(
        'Stage started',
        data: {
          'projectId': projectId,
          'stage': 'planning',
        },
      );
      var agentCtx = AgentContext(
        projectId: projectId,
        data: {
          'prompt': _promptController.text.trim(),
          'currentStage': 'planning',
        },
      );
      var result = await director.runPlanning(agentCtx);
      if (!result.success) {
        await _showError(
          '策划生成失败: ${result.error}',
          projectId: projectId,
          stage: 'planning',
        );
        return;
      }
      await AppLogger.info(
        'Stage completed',
        data: {
          'projectId': projectId,
          'stage': 'planning',
          'resultType': result.data?.runtimeType.toString(),
        },
      );

      // Save brief
      final briefData = result.data as Map<String, dynamic>?;
      if (briefData != null) {
        final brief = Brief(
          projectId: projectId,
          genre: briefData['genre'] as String?,
          duration: briefData['duration'] as int?,
          aspectRatio: briefData['aspect_ratio'] as String?,
          mood: briefData['mood'] as String?,
          visualStyle: briefData['visual_style'] as String?,
          storyOutline: briefData['story_outline'] as String?,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
        await BriefDao().insert(brief);
        agentCtx.data['brief'] = {
          'genre': brief.genre,
          'mood': brief.mood,
          'story_outline': brief.storyOutline,
          'visual_style': brief.visualStyle,
        };
      }

      // Update project state
      await _projectDao.updateState(projectId, 'scripting');

      // Stage 2: Scripting
      setState(() {
        _currentStage = '编剧';
        _statusText = '正在生成剧本...';
      });
      await AppLogger.info(
        'Stage started',
        data: {
          'projectId': projectId,
          'stage': 'scripting',
        },
      );
      agentCtx.data['currentStage'] = 'scripting';
      agentCtx.data['prompt'] = _promptController.text.trim();
      result = await director.runScripting(agentCtx);
      if (!result.success) {
        await _showError(
          '剧本生成失败: ${result.error}',
          projectId: projectId,
          stage: 'scripting',
        );
        return;
      }
      await AppLogger.info(
        'Stage completed',
        data: {
          'projectId': projectId,
          'stage': 'scripting',
          'resultType': result.data?.runtimeType.toString(),
        },
      );

      // Save script and assets
      final scriptData = result.data as Map<String, dynamic>?;
      if (scriptData != null) {
        final raw = scriptData['raw'] as Map<String, dynamic>?;
        if (raw != null) {
          final script = Script(
            projectId: projectId,
            content: '',
            createdAt: DateTime.now().millisecondsSinceEpoch,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          );
          await ScriptDao().insert(script);

          final assets = scriptData['assets'] as List<Asset>?;
          if (assets != null && assets.isNotEmpty) {
            await AssetDao().insertAll(assets);
          }
        }
      }

      await _projectDao.updateState(projectId, 'storyboarding');

      // Stage 3: Storyboarding
      setState(() {
        _currentStage = '分镜';
        _statusText = '正在生成分镜...';
      });
      await AppLogger.info(
        'Stage started',
        data: {
          'projectId': projectId,
          'stage': 'storyboarding',
        },
      );
      agentCtx.data['currentStage'] = 'storyboarding';
      result = await director.runStoryboarding(agentCtx);
      if (!result.success) {
        await _showError(
          '分镜生成失败: ${result.error}',
          projectId: projectId,
          stage: 'storyboarding',
        );
        return;
      }
      await AppLogger.info(
        'Stage completed',
        data: {
          'projectId': projectId,
          'stage': 'storyboarding',
          'resultType': result.data?.runtimeType.toString(),
        },
      );

      final storyboardData = result.data as Map<String, dynamic>?;
      if (storyboardData != null) {
        final storyboards = storyboardData['storyboards'] as List<Storyboard>?;
        if (storyboards != null && storyboards.isNotEmpty) {
          await StoryboardDao().insertAll(storyboards);
        }
      }

      await _projectDao.updateState(projectId, 'generating');

      // Navigate to project detail
      final newProject = await _projectDao.getById(projectId);
      if (newProject != null && mounted) {
        await AppLogger.info(
          'Project creation finished',
          data: {
            'projectId': projectId,
            'nextState': newProject.state,
          },
        );
        if (!mounted) {
          return;
        }
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => ProjectDetailScreen(project: newProject),
          ),
        );
      }
    } catch (e, st) {
      await _showError(
        '创建失败: $e',
        error: e,
        stackTrace: st,
        stage: _currentStage,
      );
    } finally {
      if (mounted) {
        setState(() => _creating = false);
      }
    }
  }

  Future<void> _showError(
    String message, {
    String? projectId,
    String? stage,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    await AppLogger.error(
      'Project creation failed',
      data: {
        'projectId': projectId,
        'stage': stage,
        'userMessage': message,
      },
      error: error ?? message,
      stackTrace: stackTrace,
    );

    if (mounted) {
      setState(() => _creating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$message\n日志: ${AppLogger.logFilePath}'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('创建项目')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _promptController,
              maxLines: 5,
              readOnly: _creating,
              decoration: const InputDecoration(
                labelText: '创意描述',
                hintText: '例如：一个都市白领女孩在咖啡店遇到了她的初恋...',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),
            if (_creating) ...[
              LinearProgressIndicator(
                value: _statusText.isEmpty
                    ? null
                    : {'策划': 0.2, '编剧': 0.5, '分镜': 0.8}[_currentStage] ?? 0.1,
              ),
              const SizedBox(height: 8),
              Text(
                '$_currentStage: $_statusText',
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              const Center(child: CircularProgressIndicator()),
            ],
            const Spacer(),
            FilledButton.icon(
              onPressed: _creating ? null : _createProject,
              icon: const Icon(Icons.auto_awesome),
              label: Text(_creating ? '生成中...' : '开始生成'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _promptController.dispose();
    _llm.dispose();
    super.dispose();
  }
}
