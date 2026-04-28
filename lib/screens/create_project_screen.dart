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
  final List<StageProgress> _stages = [];

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
      _stages.clear();
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

      final director = DirectorAgent(llm: _llm);

      // Stage 1: Planning
      final planningStage = StageProgress(label: '策划', icon: Icons.lightbulb);
      setState(() => _stages.add(planningStage));
      var agentCtx = AgentContext(
        projectId: projectId,
        data: {
          'prompt': _promptController.text.trim(),
          'currentStage': 'planning',
        },
      );

      var result = await director.runPlanning(
        agentCtx,
        onEvent: (event) => _onStageEvent(planningStage, event),
      );
      if (!result.success) {
        planningStage.status = 'error';
        planningStage.feedback = result.error;
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('策划生成失败: ${result.error}')),
        );
        return;
      }

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

      await _projectDao.updateState(projectId, 'scripting');

      // Stage 2: Scripting
      final scriptStage = StageProgress(label: '编剧', icon: Icons.edit_note);
      setState(() => _stages.add(scriptStage));
      agentCtx.data['currentStage'] = 'scripting';
      agentCtx.data['prompt'] = _promptController.text.trim();

      result = await director.runScripting(
        agentCtx,
        onEvent: (event) => _onStageEvent(scriptStage, event),
      );
      if (!result.success) {
        scriptStage.status = 'error';
        scriptStage.feedback = result.error;
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('剧本生成失败: ${result.error}')),
        );
        return;
      }

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
      final storyboardStage = StageProgress(label: '分镜', icon: Icons.view_carousel);
      setState(() => _stages.add(storyboardStage));
      agentCtx.data['currentStage'] = 'storyboarding';

      result = await director.runStoryboarding(
        agentCtx,
        onEvent: (event) => _onStageEvent(storyboardStage, event),
      );
      if (!result.success) {
        storyboardStage.status = 'error';
        storyboardStage.feedback = result.error;
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分镜生成失败: ${result.error}')),
        );
        return;
      }

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
      await AppLogger.error(
        'Project creation failed',
        data: {
          'userMessage': '创建失败: $e',
        },
        error: e,
        stackTrace: st,
      );
      if (mounted) {
        setState(() => _creating = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('创建失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _creating = false);
      }
    }
  }

  void _onStageEvent(StageProgress stage, StageEvent event) {
    if (!mounted) return;
    setState(() {
      switch (event.type) {
        case StageEventType.started:
          stage.status = 'running';
          stage.messages.add(_ProgressMessage(
            type: 'info',
            text: '开始生成...',
          ));
          break;
        case StageEventType.retryAttempt:
          stage.messages.add(_ProgressMessage(
            type: 'warn',
            text: '第 ${event.attempt} 次重试中...',
          ));
          break;
        case StageEventType.generating:
          stage.messages.add(_ProgressMessage(
            type: 'info',
            text: '正在生成内容...',
          ));
          break;
        case StageEventType.generated:
          if (event.content != null) {
            stage.contentPreview = event.content!;
          }
          stage.messages.add(_ProgressMessage(
            type: 'success',
            text: '内容生成完成',
          ));
          break;
        case StageEventType.reviewing:
          stage.messages.add(_ProgressMessage(
            type: 'info',
            text: 'DirectorAgent 审阅中...',
          ));
          break;
        case StageEventType.reviewPassed:
          stage.messages.add(_ProgressMessage(
            type: 'success',
            text: '✓ 审阅通过（评分: ${event.score}/10）',
          ));
          if (event.feedback != null && event.feedback!.isNotEmpty) {
            stage.messages.add(_ProgressMessage(
              type: 'note',
              text: event.feedback!,
            ));
          }
          stage.status = 'done';
          break;
        case StageEventType.reviewFailed:
          stage.messages.add(_ProgressMessage(
            type: 'error',
            text: '✗ 审阅未通过（评分: ${event.score}/10）',
          ));
          if (event.feedback != null) {
            stage.messages.add(_ProgressMessage(
              type: 'warn',
              text: '修改建议：${event.feedback}',
            ));
          }
          break;
        case StageEventType.error:
          stage.status = 'error';
          stage.feedback = event.feedback;
          stage.messages.add(_ProgressMessage(
            type: 'error',
            text: '错误：${event.feedback}',
          ));
          break;
        case StageEventType.completed:
          stage.status = 'done';
          break;
        case StageEventType.exhausted:
          stage.status = 'warn';
          stage.messages.add(_ProgressMessage(
            type: 'warn',
            text: '已达到最大重试次数',
          ));
          break;
      }
    });
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
            // Prompt input (disabled while creating)
            TextField(
              controller: _promptController,
              maxLines: 4,
              readOnly: _creating,
              decoration: const InputDecoration(
                labelText: '创意描述',
                hintText: '例如：一个都市白领女孩在咖啡店遇到了她的初恋...',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),

            // Live progress area
            Expanded(
              child: _stages.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.auto_awesome, size: 48, color: Colors.grey),
                          SizedBox(height: 12),
                          Text(
                            '输入创意后，AI 将逐步为你生成策划、编剧和分镜',
                            style: TextStyle(color: Colors.grey),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  : ListView(
                      children: _stages
                          .map((s) => _buildStageCard(s))
                          .toList(),
                    ),
            ),

            const SizedBox(height: 16),

            // Start button
            FilledButton.icon(
              onPressed: _creating ? null : _createProject,
              icon: _creating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(_creating ? '生成中...' : '开始生成'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStageCard(StageProgress stage) {
    final isRunning = stage.status == 'running';
    final isDone = stage.status == 'done';
    final isError = stage.status == 'error';

    Color borderColor;
    if (isRunning) {
      borderColor = Colors.blue;
    } else if (isDone) {
      borderColor = Colors.green;
    } else if (isError) {
      borderColor = Colors.red;
    } else {
      borderColor = Colors.grey.shade700;
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: borderColor, width: 3)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    stage.icon,
                    size: 20,
                    color: borderColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    stage.label,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: borderColor,
                    ),
                  ),
                  const Spacer(),
                  if (isRunning)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  if (isDone)
                    const Icon(Icons.check_circle, color: Colors.green, size: 18),
                  if (isError)
                    const Icon(Icons.error, color: Colors.red, size: 18),
                ],
              ),

              // Status indicator text
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _statusLabel(stage),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),

              // Expandable messages
              if (stage.messages.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildMessageList(stage),
              ],

              // Content preview
              if (stage.contentPreview.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade900,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SelectableText(
                    stage.contentPreview,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageList(StageProgress stage) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: stage.messages
            .map((m) => _buildMessage(m))
            .toList(),
      ),
    );
  }

  Widget _buildMessage(_ProgressMessage m) {
    Color color;
    String icon;
    switch (m.type) {
      case 'success':
        color = Colors.green;
        icon = '✓';
        break;
      case 'error':
        color = Colors.red;
        icon = '✗';
        break;
      case 'warn':
        color = Colors.orange;
        icon = '→';
        break;
      case 'note':
        color = Colors.grey;
        icon = '  ';
        break;
      default:
        color = Colors.blue;
        icon = '○';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(icon, style: TextStyle(color: color, fontSize: 12)),
          const SizedBox(width: 6),
          Expanded(
            child: SelectableText(
              m.text,
              style: TextStyle(color: color, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  String _statusLabel(StageProgress stage) {
    switch (stage.status) {
      case 'running':
        return '进行中...';
      case 'done':
        return '已完成';
      case 'error':
        return '失败';
      case 'warn':
        return '部分完成';
      default:
        return '等待中';
    }
  }

  @override
  void dispose() {
    _promptController.dispose();
    _llm.dispose();
    super.dispose();
  }
}

/// Tracks the progress of a single workflow stage
class StageProgress {
  final String label;
  final IconData icon;
  final List<_ProgressMessage> messages = [];
  String contentPreview = '';
  String status = 'pending'; // pending, running, done, error, warn
  String? feedback;

  StageProgress({required this.label, required this.icon});
}

/// A single progress message within a stage
class _ProgressMessage {
  final String type; // info, success, error, warn, note
  final String text;

  _ProgressMessage({required this.type, required this.text});
}
