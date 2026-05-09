import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../config/app_config.dart';
import '../db/dao/dao.dart';
import '../models/models.dart';
import '../core/director_agent.dart';
import '../core/agent.dart';
import '../services/llm_service.dart';
import '../services/dashscope_service.dart' as dashscope;
import '../services/app_logger.dart';
import '../services/persistent_image_store.dart';
import '../widgets/persistent_image.dart';
import 'seedance_web_screen.dart';

class CreateProjectScreen extends StatefulWidget {
  final Project? resumeProject;
  const CreateProjectScreen({super.key, this.resumeProject});

  @override
  State<CreateProjectScreen> createState() => _CreateProjectScreenState();
}

class _CreateProjectScreenState extends State<CreateProjectScreen> {
  final _promptController = TextEditingController();
  final _projectDao = ProjectDao();
  late LlmService _llm;

  String? _projectId;
  AgentContext? _agentCtx;
  DirectorAgent? _director;

  bool _creating = false;
  int _currentStageIndex = 0;
  final List<StageProgress> _stages = [];

  // Stage definitions
  static const _stageDefs = [
    StageDef(label: '策划', icon: Icons.lightbulb, color: Colors.orange, reviewType: 'brief'),
    StageDef(label: '编剧', icon: Icons.edit_note, color: Colors.blue, reviewType: 'script'),
    StageDef(label: '角色设计', icon: Icons.palette, color: Colors.red, reviewType: 'assets'),
    StageDef(label: '分镜', icon: Icons.view_carousel, color: Colors.purple, reviewType: 'storyboard'),
    StageDef(label: '视频', icon: Icons.videocam, color: Colors.teal, reviewType: 'video'),
  ];

  // User feedback for retry
  String _userFeedback = '';

  // Storyboard generation settings
  double _storyboardTemperature = 0.3;

  // Resume mode state
  bool _isResuming = false;
  final Map<int, StageProgress> _completedStages = {};

  @override
  void initState() {
    super.initState();
    _llm = LlmService();
    if (widget.resumeProject != null) {
      _isResuming = true;
      _projectId = widget.resumeProject!.id;
      WidgetsBinding.instance.addPostFrameCallback((_) => _resumeProject());
    }
  }

  /// Resume a project that was interrupted during creation
  Future<void> _resumeProject() async {
    final project = widget.resumeProject!;
    final pid = project.id;

    // Load existing data from DB
    final brief = await BriefDao().getByProjectId(pid);
    final script = await ScriptDao().getByProjectId(pid);
    final assets = await _ensureAssetImagesPersisted(
      await AssetDao().getByProjectId(pid),
    );
    final storyboards = await _ensureStoryboardImagesPersisted(
      await StoryboardDao().getByProjectId(pid),
    );
    final videoClips = await VideoClipDao().getByProjectId(pid);

    // Parse scenes from stored script content
    List<Scene> sceneObjects = [];
    if (script != null) {
      try {
        final decoded = jsonDecode(script.content) as Map<String, dynamic>;
        final scenesData = decoded['scenes'] as List? ?? [];
        sceneObjects = scenesData
            .whereType<Map<String, dynamic>>()
            .map((s) => Scene.fromMap(s))
            .toList();
      } catch (_) {}
    }

    // Determine which stages are completed
    int startStage = 0;
    if (brief != null) {
      final stage = StageProgress(label: '策划', icon: Icons.lightbulb, color: Colors.orange);
      stage.status = 'done';
      stage.finalData = {
        'genre': brief.genre,
        'duration': brief.duration,
        'aspect_ratio': brief.aspectRatio,
        'mood': brief.mood,
        'visual_style': brief.visualStyle,
        'story_outline': brief.storyOutline,
      };
      stage.contentPreview = _formatPreview(stage.finalData, 'brief');
      _completedStages[0] = stage;
      startStage = 1;
    }
    if (script != null) {
      final stage = StageProgress(label: '编剧', icon: Icons.edit_note, color: Colors.blue);
      stage.status = 'done';
      stage.finalData = {
        'scenes': sceneObjects,
        'assets': assets,
      };
      stage.contentPreview = _formatPreview(stage.finalData, 'script');
      _completedStages[1] = stage;
      startStage = 2;
    }
    // Always show the "角色设计" stage if we've passed scripting
    // Even if assets haven't been generated yet, we should show the stage
    {
      final stage = StageProgress(label: '角色设计', icon: Icons.palette, color: Colors.red);

      if (assets.isNotEmpty) {
        final hasAllImages = assets.every(
          (a) => PersistentImageStore.preferredSource(
                localPath: a.referenceImageLocalPath,
                remoteUrl: a.referenceImageUrl,
              ) !=
              null,
        );
        final hasAnyImages = assets.any(
          (a) => PersistentImageStore.preferredSource(
                localPath: a.referenceImageLocalPath,
                remoteUrl: a.referenceImageUrl,
              ) !=
              null,
        );

        stage.finalData = {'assets': assets};
        stage.contentPreview = _formatPreview(stage.finalData, 'assets');

        if (hasAllImages) {
          stage.status = 'done';
          _completedStages[2] = stage;
          if (startStage < 3) startStage = 3;
        } else if (hasAnyImages) {
          // Partially done — show with warning status
          stage.status = 'warn';
          final missingCount = assets.where(
            (a) => PersistentImageStore.preferredSource(
                  localPath: a.referenceImageLocalPath,
                  remoteUrl: a.referenceImageUrl,
                ) ==
                null,
          ).length;
          stage.feedback = '还有 $missingCount 个资产参考图未生成';
          // Show this stage but don't advance
          _stages.add(stage);
        } else {
          // Assets exist but no images yet — show as pending
          stage.status = 'waiting';
          stage.feedback = '${assets.length} 个资产待生成参考图';
          _stages.add(stage);
        }
      } else if (storyboards.isNotEmpty) {
        // Assets should have been generated if storyboards exist, but DB query returned empty
        // This means assets weren't saved — show as warning with note
        stage.status = 'warn';
        stage.feedback = '资产数据未保存，跳过此阶段';
        _stages.add(stage);
        startStage = 3;
      }
      // If no assets and no storyboards, skip (will generate from scratch)
    }
    if (storyboards.isNotEmpty) {
      await AppLogger.info('Resume: found storyboards in DB', data: {
        'projectId': pid,
        'storyboardCount': storyboards.length,
        'ids': storyboards.map((s) => s.id).toList(),
      });
      final stage = StageProgress(label: '分镜', icon: Icons.view_carousel, color: Colors.purple);
      stage.status = 'done';
      stage.finalData = {'storyboards': storyboards};
      stage.contentPreview = _formatPreview(stage.finalData, 'storyboard');
      _completedStages[3] = stage;
      startStage = 4;  // 分镜已完成，下一步是视频阶段
    } else {
      await AppLogger.warn('Resume: NO storyboards found in DB', data: {
        'projectId': pid,
        'projectState': project.state,
      });
    }
    if (videoClips.isNotEmpty) {
      final stage = StageProgress(label: '视频', icon: Icons.videocam, color: Colors.teal);
      stage.status = 'done';
      stage.finalData = {'clips': videoClips.map((c) => c.toMap()).toList()};
      stage.contentPreview = _formatPreview(stage.finalData, 'video');
      _completedStages[4] = stage;
      startStage = 4;
    }

    _currentStageIndex = startStage;
    final sortedStages = _completedStages.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    _stages.addAll(sortedStages.map((e) => e.value));

    // Setup agent context with existing data
    _director = DirectorAgent(llm: _llm);
    final prompt = brief?.storyOutline ?? project.name;
    _agentCtx = AgentContext(
      projectId: pid,
      data: {
        'prompt': prompt,
        'currentStage': startStage >= _stageDefs.length ? 'done' : _stageIndexToWorkflowStage(startStage),
      },
    );
    if (brief != null) {
      _agentCtx!.data['brief'] = {
        'genre': brief.genre,
        'mood': brief.mood,
        'story_outline': brief.storyOutline,
        'visual_style': brief.visualStyle,
      };
    }
    // Inject script into context for downstream stages
    if (script != null) {
      _agentCtx!.data['script'] = {
        'scenes': sceneObjects,
        'assets': assets.map((a) => a.toMap()).toList(),
      };
    }
    _promptController.text = prompt;

    if (startStage >= _stageDefs.length) {
      // Project fully completed
      setState(() => _creating = false);
    } else {
      // Show existing progress without auto-starting the next stage
      // User will control when to continue
      setState(() => _creating = false);
    }
  }

  Future<List<Asset>> _ensureAssetImagesPersisted(List<Asset> assets) async {
    final imageStore = PersistentImageStore();
    final updatedAssets = <Asset>[];

    for (final asset in assets) {
      String? localPath = asset.referenceImageLocalPath;
      if (localPath == null && asset.referenceImageUrl != null && asset.referenceImageUrl!.isNotEmpty) {
        localPath = await imageStore.persistRemoteImage(
          asset.referenceImageUrl,
          category: 'assets',
          entityId: asset.id,
        );
        if (localPath != null) {
          await AssetDao().updateReferenceImage(asset.id, localPath: localPath);
        }
      }

      if (localPath != asset.referenceImageLocalPath) {
        updatedAssets.add(Asset(
          id: asset.id,
          projectId: asset.projectId,
          type: asset.type,
          name: asset.name,
          description: asset.description,
          prompt: asset.prompt,
          referenceImageUrl: asset.referenceImageUrl,
          referenceImageLocalPath: localPath,
          state: asset.state,
          createdAt: asset.createdAt,
        ));
      } else {
        updatedAssets.add(asset);
      }
    }

    return updatedAssets;
  }

  Future<List<Storyboard>> _ensureStoryboardImagesPersisted(
    List<Storyboard> storyboards,
  ) async {
    final imageStore = PersistentImageStore();
    final updatedStoryboards = <Storyboard>[];

    for (final storyboard in storyboards) {
      String? localPath = storyboard.referenceImageLocalPath;
      if (localPath == null &&
          storyboard.referenceImageUrl != null &&
          storyboard.referenceImageUrl!.isNotEmpty) {
        localPath = await imageStore.persistRemoteImage(
          storyboard.referenceImageUrl,
          category: 'storyboards',
          entityId: storyboard.id,
        );
        if (localPath != null) {
          await StoryboardDao().updateImageUrl(
            storyboard.id,
            storyboard.referenceImageUrl!,
            localPath: localPath,
          );
        }
      }

      if (localPath != storyboard.referenceImageLocalPath) {
        updatedStoryboards.add(Storyboard(
          id: storyboard.id,
          projectId: storyboard.projectId,
          sceneNum: storyboard.sceneNum,
          shotNum: storyboard.shotNum,
          shotType: storyboard.shotType,
          cameraMove: storyboard.cameraMove,
          description: storyboard.description,
          firstFramePrompt: storyboard.firstFramePrompt,
          videoPrompt: storyboard.videoPrompt,
          duration: storyboard.duration,
          assets: storyboard.assets,
          state: storyboard.state,
          createdAt: storyboard.createdAt,
          referenceImageUrl: storyboard.referenceImageUrl,
          referenceImageLocalPath: localPath,
          referenceImageUrls: storyboard.referenceImageUrls,
        ));
      } else {
        updatedStoryboards.add(storyboard);
      }
    }

    return updatedStoryboards;
  }

  Future<void> _startProject() async {
    if (_promptController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入创意描述')),
      );
      return;
    }

    if (!AppConfig.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在设置页面配置 API Key')),
      );
      return;
    }

    final projectId = 'proj_${const Uuid().v4().substring(0, 8)}';
    _projectId = projectId;

    final project = Project(
      id: projectId,
      name: _promptController.text.trim().substring(0, 20),
      state: 'planning',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _projectDao.insert(project);

    _director = DirectorAgent(llm: _llm);
    _agentCtx = AgentContext(
      projectId: projectId,
      data: {
        'prompt': _promptController.text.trim(),
        'currentStage': 'planning',
      },
    );

    setState(() {
      _creating = true;
      _currentStageIndex = 0;
      _stages.clear();
    });

    await _runCurrentStage();
  }

  /// Get existing stage or create new one (prevents duplicate cards)
  StageProgress _getOrCreateCurrentStage() {
    // Check if we already have a card for this stage
    if (_stages.length > _currentStageIndex) {
      final existing = _stages[_currentStageIndex];
      // If retrying, reset state but keep the card
      if (existing.status == 'done' || existing.status == 'warn') {
        existing.status = 'running';
        existing.messages.add(_ProgressMessage(type: 'warn', text: '--- 根据反馈重新生成 ---'));
        existing.contentPreview = '';
        existing.finalData = null;
      } else if (existing.status == 'pending') {
        existing.status = 'running';
      }
      return existing;
    }
    // New stage
    final def = _stageDefs[_currentStageIndex];
    final stage = StageProgress(label: def.label, icon: def.icon, color: def.color);
    _stages.add(stage);
    return stage;
  }

  Future<void> _runCurrentStage() async {
    if (_currentStageIndex >= _stageDefs.length) {
      await _finishProject();
      return;
    }

    final stage = _getOrCreateCurrentStage();

    await AppLogger.info('Stage started', data: {'projectId': _projectId, 'stage': stage.label});

    try {
      AgentResult result;
      switch (_currentStageIndex) {
        case 0: // 策划
          // Inject user feedback for retry
          if (_userFeedback.isNotEmpty) {
            _agentCtx!.data['feedback'] = _userFeedback;
            _userFeedback = '';
          }
          result = await _director!.runPlanning(
            _agentCtx!,
            onEvent: (event) => _onStageEvent(stage, event),
          );
          if (result.success && result.data != null) {
            final briefData = result.data as Map<String, dynamic>;
            // Check if this is a retry result (has reviewScore) or first result
            final hasBriefData = briefData.containsKey('genre') && briefData.containsKey('story_outline');
            if (hasBriefData) {
              final brief = Brief(
                projectId: _projectId!,
                genre: briefData['genre'] as String?,
                duration: briefData['duration'] as int?,
                aspectRatio: briefData['aspect_ratio'] as String?,
                mood: briefData['mood'] as String?,
                visualStyle: briefData['visual_style'] as String?,
                storyOutline: briefData['story_outline'] as String?,
                createdAt: DateTime.now().millisecondsSinceEpoch,
              );
              await BriefDao().insert(brief);
              _agentCtx!.data['brief'] = {
                'genre': brief.genre,
                'mood': brief.mood,
                'story_outline': brief.storyOutline,
                'visual_style': brief.visualStyle,
              };
            }
            stage.finalData = briefData;
          }
          break;

        case 1: // 编剧
          _agentCtx!.data['currentStage'] = 'scripting';
          _agentCtx!.data['prompt'] = _promptController.text.trim();
          if (_userFeedback.isNotEmpty) {
            _agentCtx!.data['feedback'] = _userFeedback;
            _userFeedback = '';
          }
          result = await _director!.runScripting(
            _agentCtx!,
            onEvent: (event) => _onStageEvent(stage, event),
          );
          if (result.success && result.data != null) {
            final scriptData = result.data as Map<String, dynamic>;
            // Only insert script/assets on first attempt
            if (stage.finalData == null) {
              final script = Script(
                projectId: _projectId!,
                content: jsonEncode(scriptData['raw']),
                createdAt: DateTime.now().millisecondsSinceEpoch,
                updatedAt: DateTime.now().millisecondsSinceEpoch,
              );
              await ScriptDao().insert(script);

              final rawAssets = scriptData['assets'];
              if (rawAssets is List && rawAssets.isNotEmpty) {
                final assets = rawAssets.map((e) {
                  if (e is Asset) return e;
                  if (e is Map<String, dynamic>) return Asset.fromMap(e);
                  throw Exception('Invalid asset type: ${e.runtimeType}');
                }).toList();
                await AssetDao().insertAll(assets);
              }
            }
            stage.finalData = scriptData;
            // Inject script into context so ProductionAgent can use it
            _agentCtx!.data['script'] = scriptData;
          }
          break;

        case 2: // 角色设计
          _agentCtx!.data['currentStage'] = 'asseting';
          if (_userFeedback.isNotEmpty) {
            _agentCtx!.data['feedback'] = _userFeedback;
            _userFeedback = '';
          }
          result = await _director!.runAsseting(
            _agentCtx!,
            onEvent: (event) => _onStageEvent(stage, event),
          );
          if (result.success && result.data != null) {
            final assetData = result.data as Map<String, dynamic>;
            final rawAssets = assetData['assets'];
            // Always update DB with latest image URLs from asset results
            if (rawAssets is List && rawAssets.isNotEmpty) {
              final imageStore = PersistentImageStore();
              for (final rawAsset in rawAssets) {
                Asset? asset;
                if (rawAsset is Asset) {
                  asset = rawAsset;
                } else if (rawAsset is Map<String, dynamic>) {
                  asset = Asset.fromMap(rawAsset);
                }

                if (asset != null &&
                    asset.referenceImageUrl != null &&
                    asset.referenceImageUrl!.isNotEmpty) {
                  final localPath = await imageStore.persistRemoteImage(
                    asset.referenceImageUrl,
                    category: 'assets',
                    entityId: asset.id,
                  );
                  await AssetDao().updateReferenceImage(
                    asset.id,
                    imageUrl: asset.referenceImageUrl!,
                    localPath: localPath,
                  );
                }
              }
            }
            // Update assets in context for downstream stages
            if (rawAssets is List) {
              final scriptData = _agentCtx!.data['script'] as Map<String, dynamic>?;
              if (scriptData != null) {
                scriptData['assets'] = rawAssets;
              }
            }
            stage.finalData = assetData;
          }
          break;

        case 3: // 分镜
          _agentCtx!.data['currentStage'] = 'storyboarding';
          _agentCtx!.data['storyboardTemperature'] = _storyboardTemperature;
          // Inject script for review comparison
          if (stage.finalData != null) {
            _agentCtx!.data['scriptForReview'] = _formatScriptForReview(stage.finalData!);
          }
          if (_userFeedback.isNotEmpty) {
            _agentCtx!.data['feedback'] = _userFeedback;
            _userFeedback = '';
          }
          result = await _director!.runStoryboarding(
            _agentCtx!,
            onEvent: (event) => _onStageEvent(stage, event),
          );
          if (result.success && result.data != null) {
            final storyboardData = result.data as Map<String, dynamic>;
            final storyboards = storyboardData['storyboards'] as List<Storyboard>?;

            // Debug: log storyboard save attempt
            await AppLogger.info('Storyboard save check', data: {
              'projectId': _projectId,
              'storyboardsCount': storyboards?.length ?? 0,
              'stageFinalDataIsNull': stage.finalData == null,
            });

            if (storyboards != null && storyboards.isNotEmpty) {
              if (stage.finalData == null) {
                // First attempt: insert new storyboards
                await AppLogger.info('Inserting new storyboards', data: {
                  'projectId': _projectId,
                  'count': storyboards.length,
                  'ids': storyboards.map((s) => s.id).toList(),
                });
                await StoryboardDao().insertAll(storyboards);
              } else {
                // Retry: update existing storyboards with new data
                await AppLogger.info('Updating existing storyboards on retry', data: {
                  'projectId': _projectId,
                  'count': storyboards.length,
                  'ids': storyboards.map((s) => s.id).toList(),
                });
                await StoryboardDao().insertAll(storyboards);
              }

              // Verify save by reading back from DB
              final savedCount = (await StoryboardDao().getByProjectId(_projectId!)).length;
              await AppLogger.info('Storyboard save verified', data: {
                'projectId': _projectId,
                'savedCount': savedCount,
              });
            } else {
              await AppLogger.warn('No storyboards to save', data: {
                'projectId': _projectId,
                'storyboardDataKeys': storyboardData.keys.toList(),
              });
            }

            // Inject asset reference images into storyboards for video generation.
            // VideoAgent reads these from script assets, so we must ensure they
            // are populated here before the video stage runs.
            final scriptData = _agentCtx!.data['script'] as Map<String, dynamic>?;
            if (scriptData != null) {
              final assetsWithImages = scriptData['assets'] as List?;
              if (assetsWithImages is List && assetsWithImages.isNotEmpty) {
                // Build a map of asset name -> reference image URL
                final assetImageMap = <String, String>{};
                for (final a in assetsWithImages) {
                  String? name;
                  String? refUrl;
                  if (a is Asset) {
                    name = a.name;
                    refUrl = a.referenceImageUrl;
                  } else if (a is Map<String, dynamic>) {
                    name = a['name'] as String?;
                    refUrl = a['reference_image_url'] as String?;
                  }
                  if (name != null && name.isNotEmpty && refUrl != null && refUrl.isNotEmpty) {
                    assetImageMap[name] = refUrl;
                  }
                }

                // Attach asset reference images to storyboards
                final rawStoryboards = storyboardData['storyboards'] as List?;
                if (rawStoryboards is List) {
                  for (final sb in rawStoryboards) {
                    if (sb is Map<String, dynamic>) {
                      final desc = sb['description'] as String? ?? '';
                      final firstFramePrompt = sb['first_frame_prompt'] as String? ?? '';
                      final combined = '$desc $firstFramePrompt';
                      // Find which asset names are mentioned in this storyboard
                      final mentionedAssets = <String>[];
                      for (final entry in assetImageMap.entries) {
                        if (combined.contains(entry.key)) {
                          mentionedAssets.add(entry.value);
                        }
                      }
                      if (mentionedAssets.isNotEmpty) {
                        sb['assets'] = jsonEncode(mentionedAssets);
                      }
                    }
                  }
                }
              }
            }

            stage.finalData = storyboardData;
          }
          break;

        case 4: // 视频
          if (AppConfig.useSeedanceForVideo) {
            result = await _runSeedanceVideoStage(stage);
          } else {
            result = await _runApiVideoStage(stage);
          }
          break;

        default:
          return;
      }

      if (!result.success) {
        stage.status = 'error';
        stage.feedback = result.error;
        setState(() {});

        // Save completed stages before failing
        await _saveProgressOnError(stage);

        setState(() => _creating = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${stage.label}生成失败: ${result.error}'),
            action: SnackBarAction(
              label: '查看项目',
              textColor: Colors.white,
              onPressed: () async {
                if (_projectId != null) {
                  final project = await _projectDao.getById(_projectId!);
                  if (project != null && mounted) {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(builder: (_) => CreateProjectScreen(resumeProject: project)),
                    );
                  }
                }
              },
            ),
          ),
        );
        return;
      }

      // DirectorAgent always returns success=true, but check if review actually passed
      final reviewScore = result.data?['reviewScore'];
      if (reviewScore != null && (reviewScore as num) < 6) {
        // Review exhausted retries - show feedback but still allow to continue
        stage.status = 'warn';
        stage.feedback = result.data?['reviewFeedback'] as String?;
      } else {
        stage.status = 'done';
      }
      stage.contentPreview = _formatPreview(stage.finalData, _stageDefs[_currentStageIndex].reviewType);

      // Persist project state AFTER stage data is saved to DB.
      // This guarantees that on app relaunch, the state accurately reflects
      // the last completed stage — never ahead of actual persisted data.
      final completedState = _stageIndexToWorkflowStage(_currentStageIndex);
      await _projectDao.updateState(_projectId!, completedState);

      setState(() {});
    } catch (e, st) {
      await AppLogger.error('Stage failed', data: {'stage': stage.label}, error: e, stackTrace: st);
      stage.status = 'error';
      stage.feedback = e.toString();

      // Save completed stages before failing
      await _saveProgressOnError(stage);

      setState(() => _creating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${stage.label}出错: $e'),
          action: SnackBarAction(
            label: '查看项目',
            textColor: Colors.white,
            onPressed: () async {
              if (_projectId != null) {
                final project = await _projectDao.getById(_projectId!);
                if (project != null && mounted) {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => CreateProjectScreen(resumeProject: project)),
                  );
                }
              }
            },
          ),
        ),
      );
    }
  }

  /// Called when a stage fails. No state update needed — the project state
  /// already points to the last successfully completed stage (saved after
  /// the previous stage's success). Just log the failure.
  Future<void> _saveProgressOnError(StageProgress failedStage) async {
    if (_projectId == null) return;
    await AppLogger.warn('Stage failed, state unchanged', data: {
      'stage': failedStage.label,
      'projectId': _projectId,
      'currentState': _stageIndexToWorkflowStage(_currentStageIndex),
    });
  }

  String _stageIndexToWorkflowStage(int index) {
    switch (index) {
      case 0: return 'planning';
      case 1: return 'scripting';
      case 2: return 'asseting';
      case 3: return 'storyboarding';
      case 4: return 'generating';
      default: return 'done';
    }
  }

  /// API mode video stage — uses VideoAgent via DirectorAgent
  Future<AgentResult> _runApiVideoStage(StageProgress stage) async {
    _agentCtx!.data['currentStage'] = 'generating';
    if (_userFeedback.isNotEmpty) {
      _agentCtx!.data['feedback'] = _userFeedback;
      _userFeedback = '';
    }
    if (stage.finalData == null) {
      final storyboards = await StoryboardDao().getByProjectId(_projectId!);
      _agentCtx!.data['storyboards'] = storyboards.map((s) => s.toMap()).toList();
    } else {
      _agentCtx!.data['storyboards'] = stage.finalData!['storyboards'];
    }
    final result = await _director!.runGenerating(
      _agentCtx!,
      onEvent: (event) => _onStageEvent(stage, event),
    );
    if (result.success && result.data != null) {
      final videoData = result.data as Map<String, dynamic>;
      final clips = videoData['clips'] as List?;
      if (clips != null && stage.finalData == null) {
        for (final clipMap in clips) {
          if (clipMap is Map<String, dynamic>) {
            final clip = VideoClip(
              id: 'clip_${clipMap['storyboard_id'] ?? const Uuid().v4().substring(0, 8)}',
              projectId: _projectId!,
              storyboardId: clipMap['storyboard_id'] as String? ?? '',
              videoUrl: clipMap['video_url'] as String?,
              state: clipMap['state'] as String? ?? 'generating',
              errorReason: clipMap['error_reason'] as String?,
              createdAt: DateTime.now().millisecondsSinceEpoch,
            );
            await VideoClipDao().insert(clip);

            if (clipMap['reference_image_url'] != null) {
              final referenceImageUrl = clipMap['reference_image_url'] as String;
              final localPath = clipMap['reference_image_local_path'] as String? ??
                  await PersistentImageStore().persistRemoteImage(
                    referenceImageUrl,
                    category: 'storyboards',
                    entityId: clipMap['storyboard_id'] as String,
                  );
              await StoryboardDao().updateImageUrl(
                clipMap['storyboard_id'] as String,
                referenceImageUrl,
                localPath: localPath,
              );
            }
          }
        }
      }
      stage.finalData = videoData;
    }
    return result;
  }

  /// Seedance mode video stage — opens a single SeedanceWebScreen for all storyboards.
  Future<AgentResult> _runSeedanceVideoStage(StageProgress stage) async {
    // Get storyboards from the agent context first (they have the latest data),
    // fall back to DB if not available.
    List<Storyboard> storyboards;
    final contextStoryboards = _agentCtx?.data['storyboards'];
    if (contextStoryboards is List && contextStoryboards.isNotEmpty) {
      storyboards = contextStoryboards
          .map((sb) => sb is Storyboard ? sb : Storyboard.fromMap(sb as Map<String, dynamic>))
          .toList();
    } else {
      storyboards = await StoryboardDao().getByProjectId(_projectId!);
    }
    final scriptData = _agentCtx?.data['script'] as Map<String, dynamic>?;

    final clips = <Map<String, dynamic>>[];
    int successCount = 0;

    // Collect shared character + prop reference image URLs.
    final refImageUrls = <String>[];
    // Also build a map of asset name -> reference image URL for injecting into storyboards.
    final assetImageMap = <String, String>{};
    if (scriptData != null) {
      final rawAssets = scriptData['assets'] as List?;
      if (rawAssets != null) {
        for (final a in rawAssets) {
          Map<String, dynamic>? m;
          if (a is Asset) {
            m = {
              'type': a.type,
              'name': a.name,
              'reference_image_url': a.referenceImageUrl,
              'reference_image_local_path': a.referenceImageLocalPath,
            };
          } else if (a is Map<String, dynamic>) {
            m = a;
          }
          if (m == null) continue;
          final type = m['type']?.toString() ?? '';
          final name = m['name']?.toString() ?? '';
          final refUrl = PersistentImageStore.preferredSource(
            localPath: m['reference_image_local_path']?.toString(),
            remoteUrl: m['reference_image_url']?.toString(),
          );
          if ((type == 'character' || type == 'prop') && refUrl != null && refUrl.isNotEmpty) {
            refImageUrls.add(refUrl);
          }
          if (name.isNotEmpty && refUrl != null && refUrl.isNotEmpty) {
            assetImageMap[name] = refUrl;
          }
        }
      }
    }

    final batchItems = <SeedanceStoryboardItem>[];
    for (final sb in storyboards) {
      // Try to get image URL from storyboard first
      var imageUrl = PersistentImageStore.preferredSource(
            localPath: sb.referenceImageLocalPath,
            remoteUrl: sb.referenceImageUrl,
          ) ??
          (sb.referenceImageUrls?.isNotEmpty == true ? sb.referenceImageUrls!.first : null);

      // If storyboard has no image, try to find a matching asset reference image
      // by checking if any asset name is mentioned in the storyboard description
      if (imageUrl == null || imageUrl.isEmpty) {
        final combined = '${sb.description ?? ''} ${sb.firstFramePrompt ?? ''}';
        for (final entry in assetImageMap.entries) {
          if (combined.contains(entry.key)) {
            imageUrl = entry.value;
            break;
          }
        }
      }

      if (imageUrl == null || imageUrl.isEmpty) {
        clips.add({
          'storyboard_id': sb.id,
          'state': 'failed',
          'error_reason': '缺少首帧图',
        });
        continue;
      }

      batchItems.add(SeedanceStoryboardItem(
        storyboardId: sb.id,
        imageUrl: imageUrl,
        prompt: sb.videoPrompt,
        description: sb.description ?? '',
        sceneNum: sb.sceneNum,
        shotNum: sb.shotNum,
        referenceImageUrls: refImageUrls.isNotEmpty ? refImageUrls : null,
      ));
    }

    if (batchItems.isNotEmpty) {
      stage.status = 'running';
      stage.contentPreview = '正在处理 ${batchItems.length} 个镜头...';
      setState(() {});

      final result = await Navigator.push<Map<String, String>>(
        context,
        MaterialPageRoute(
          builder: (_) => SeedanceWebScreen(batchStoryboards: batchItems),
        ),
      );

      for (final sb in storyboards) {
        final videoUrl = result?[sb.id];
        if (videoUrl != null && videoUrl.isNotEmpty) {
          final clip = VideoClip(
            id: 'clip_seedance_${const Uuid().v4().substring(0, 8)}',
            projectId: _projectId!,
            storyboardId: sb.id,
            videoUrl: videoUrl,
            state: 'completed',
            createdAt: DateTime.now().millisecondsSinceEpoch,
          );
          await VideoClipDao().insert(clip);
          clips.add({
            'storyboard_id': sb.id,
            'video_url': videoUrl,
            'state': 'completed',
          });
          successCount++;
        } else if (!clips.any((clip) => clip['storyboard_id'] == sb.id)) {
          clips.add({
            'storyboard_id': sb.id,
            'state': 'failed',
            'error_reason': '未返回结果',
          });
        }
      }
    }

    final videoData = <String, dynamic>{
      'clips': clips,
      'total': storyboards.length,
      'success': successCount,
      'failed': storyboards.length - successCount,
      'reviewScore': 7,
      'nextStage': 'done',
    };
    stage.finalData = videoData;

    return AgentResult.success(videoData);
  }

  /// Move to next stage
  Future<void> _approveAndContinue() async {
    _userFeedback = '';
    _currentStageIndex++;
    await _runCurrentStage();
  }

  /// Retry current stage with user feedback
  Future<void> _retryWithFeedback() async {
    if (_userFeedback.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入修改建议')),
      );
      return;
    }
    final currentStage = _stages[_currentStageIndex];
    currentStage.status = 'running';
    currentStage.messages.add(_ProgressMessage(type: 'warn', text: '--- 根据反馈重新生成 ---'));
    currentStage.contentPreview = '';
    currentStage.finalData = null;
    setState(() {});
    // Don't create a new card - just re-run the same stage index
    await _runCurrentStage();
  }

  Future<void> _finishProject() async {
    await _projectDao.updateState(_projectId!, 'done');
    final newProject = await _projectDao.getById(_projectId!);
    if (newProject != null && mounted) {
      await AppLogger.info('Project creation finished', data: {'projectId': _projectId});
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => CreateProjectScreen(resumeProject: newProject)),
      );
    }
  }

  void _onStageEvent(StageProgress stage, StageEvent event) {
    if (!mounted) return;
    setState(() {
      // IMPORTANT: Only the "started" event changes status to 'running'.
      // All other events just append messages. The FINAL status is always
      // determined by _runCurrentStage() after the DirectorAgent returns,
      // based on result.success. This prevents internal DirectorAgent retry
      // errors from permanently setting the stage to 'error'.
      switch (event.type) {
        case StageEventType.started:
          stage.status = 'running';
          stage.messages.add(_ProgressMessage(type: 'info', text: '开始生成...'));
          break;
        case StageEventType.retryAttempt:
          stage.messages.add(_ProgressMessage(type: 'warn', text: '第 ${event.attempt} 次重试...'));
          break;
        case StageEventType.generating:
          stage.messages.add(_ProgressMessage(type: 'info', text: '正在生成内容...'));
          break;
        case StageEventType.generated:
          if (event.content != null) stage.contentPreview = event.content!;
          stage.messages.add(_ProgressMessage(type: 'success', text: '内容生成完成'));
          break;
        case StageEventType.reviewing:
          stage.messages.add(_ProgressMessage(type: 'info', text: 'DirectorAgent 审阅中...'));
          break;
        case StageEventType.reviewPassed:
          stage.messages.add(_ProgressMessage(type: 'success', text: '✓ 审阅通过（评分: ${event.score}/10）'));
          if (event.feedback != null && event.feedback!.isNotEmpty && event.feedback != '通过') {
            stage.messages.add(_ProgressMessage(type: 'note', text: event.feedback!));
          }
          break;
        case StageEventType.reviewFailed:
          // DirectorAgent will retry internally — this is not a terminal failure
          stage.messages.add(_ProgressMessage(type: 'warn', text: '✗ 审阅未通过（评分: ${event.score}/10），将自动重试...'));
          if (event.feedback != null) {
            stage.messages.add(_ProgressMessage(type: 'warn', text: '修改建议：${event.feedback}'));
          }
          break;
        case StageEventType.error:
          // Only add to messages — do NOT change status here.
          // DirectorAgent catches errors internally and may retry.
          stage.messages.add(_ProgressMessage(type: 'error', text: '错误：${event.feedback ?? "未知错误"}'));
          break;
        default:
          break;
      }
    });
  }

  String _formatScriptForReview(Map<String, dynamic> scriptData) {
    final lines = <String>[];
    final assets = scriptData['assets'] as List?;
    if (assets != null) {
      for (final a in assets) {
        String name, desc, type;
        if (a is Asset) {
          name = a.name;
          desc = a.description ?? '';
          type = a.type;
        } else if (a is Map<String, dynamic>) {
          name = a['name']?.toString() ?? '';
          desc = a['description']?.toString() ?? '';
          type = a['type']?.toString() ?? '';
        } else {
          continue;
        }
        if (type == 'character') {
          lines.add('角色：$name — $desc');
        } else if (type == 'prop') {
          lines.add('道具：$name — $desc');
        }
      }
    }
    final scenes = scriptData['scenes'] as List?;
    if (scenes != null) {
      for (final s in scenes) {
        String sceneNum, location, description, action;
        List<dynamic>? dialogue;
        if (s is Scene) {
          sceneNum = s.sceneNum.toString();
          location = s.location;
          description = s.description;
          action = s.action;
          dialogue = s.dialogue;
        } else if (s is Map<String, dynamic>) {
          sceneNum = (s['scene_num'] ?? 0).toString();
          location = s['location'] ?? '';
          description = s['description'] ?? '';
          action = s['action'] ?? '';
          dialogue = s['dialogue'] as List?;
        } else {
          continue;
        }
        lines.add('\n━━ 场景 $sceneNum：$location ━━');
        lines.add('描述：$description');
        lines.add('动作：$action');
        if (dialogue != null && dialogue.isNotEmpty) {
          for (final d in dialogue) {
            lines.add('  "$d"');
          }
        }
      }
    }
    return lines.join('\n');
  }

  String _formatPreview(Map<String, dynamic>? data, String type) {
    if (data == null) return '';
    switch (type) {
      case 'brief':
        final parts = <String>[];
        if (data['genre'] != null) parts.add(' 类型：${data['genre']}');
        if (data['duration'] != null) parts.add('⏱ 时长：${data['duration']} 秒');
        if (data['aspect_ratio'] != null) parts.add('📐 画面比例：${data['aspect_ratio']}');
        if (data['mood'] != null) parts.add('🎭 情绪基调：${data['mood']}');
        if (data['visual_style'] != null) parts.add(' 视觉风格：${data['visual_style']}');
        if (data['story_outline'] != null) parts.add('\n📖 故事大纲：\n${data['story_outline']}');
        return parts.join('\n');
      case 'script':
        final rawScenes = data['scenes'] as List?;
        final raw = data['raw'] as Map<String, dynamic>?;
        final scenes = rawScenes ?? (raw?['scenes'] as List?);
        if (scenes == null) return '';
        final lines = <String>[];
        for (final s in scenes) {
          String sceneNum, location, description, action;
          List<dynamic>? dialogue;
          int duration;
          if (s is Scene) {
            sceneNum = s.sceneNum.toString();
            location = s.location;
            description = s.description;
            action = s.action;
            dialogue = s.dialogue;
            duration = s.duration;
          } else if (s is Map<String, dynamic>) {
            sceneNum = (s['scene_num'] ?? 0).toString();
            location = s['location'] ?? '';
            description = s['description'] ?? '';
            action = s['action'] ?? '';
            dialogue = s['dialogue'] as List?;
            duration = (s['duration'] as num? ?? 0).toInt();
          } else {
            continue;
          }
          lines.add('━━ 场景 $sceneNum：$location ━━');
          lines.add('描述：$description');
          lines.add('动作：$action');
          if (dialogue != null && dialogue.isNotEmpty) {
            for (final d in dialogue) {
              lines.add('  "$d"');
            }
          }
          lines.add('时长：${duration}秒');
          lines.add('');
        }
        return lines.join('\n');
      case 'storyboard':
        final rawStoryboards = data['storyboards'] as List?;
        if (rawStoryboards == null) return '';
        final lines = <String>[];
        for (final sb in rawStoryboards) {
          String sceneNum, shotNum, description, shotType, cameraMove, firstFrame, videoPrompt;
          int duration;
          if (sb is Storyboard) {
            sceneNum = sb.sceneNum.toString();
            shotNum = sb.shotNum.toString();
            description = sb.description ?? '';
            shotType = sb.shotType ?? '';
            cameraMove = sb.cameraMove ?? '';
            firstFrame = sb.firstFramePrompt ?? '';
            videoPrompt = sb.videoPrompt ?? '';
            duration = sb.duration ?? 5;
          } else if (sb is Map<String, dynamic>) {
            sceneNum = (sb['scene_num'] ?? 0).toString();
            shotNum = (sb['shot_num'] ?? 0).toString();
            description = sb['description'] ?? '';
            shotType = sb['shot_type'] ?? '';
            cameraMove = sb['camera_move'] ?? '';
            firstFrame = sb['first_frame_prompt'] ?? '';
            videoPrompt = sb['video_prompt'] ?? '';
            duration = (sb['duration'] as num? ?? 5).toInt();
          } else {
            continue;
          }
          lines.add('━━ 镜头 $sceneNum-$shotNum ━━');
          lines.add('画面：$description');
          lines.add('镜头：$shotType | 运镜：$cameraMove');
          lines.add('首帧提示词：$firstFrame');
          lines.add('视频提示词：$videoPrompt');
          lines.add('时长：${duration}秒');
          lines.add('');
        }
        return lines.join('\n');
      case 'video':
        final rawClips = data['clips'] as List?;
        if (rawClips == null) return '';
        final lines = <String>[];
        int clipSuccess = 0;
        int clipFailed = 0;
        for (final c in rawClips) {
          if (c is Map<String, dynamic>) {
            final sbId = c['storyboard_id'] ?? '?';
            final state = c['state'] as String?;
            final videoUrl = c['video_url'] as String?;
            final refUrl = c['reference_image_url'] as String?;
            if (state == 'done' && videoUrl != null) {
              lines.add('━━ 镜头 $sbId ━━');
              lines.add('参考图: ${refUrl ?? "无"}');
              lines.add('视频: ${videoUrl.substring(0, videoUrl.length.clamp(0, 60))}');
              lines.add('');
              clipSuccess++;
            } else {
              lines.add('━━ 镜头 $sbId ━━');
              lines.add('失败: ${c['error_reason'] ?? "未知原因"}');
              lines.add('');
              clipFailed++;
            }
          }
        }
        lines.insert(0, '成功: $clipSuccess / 失败: $clipFailed\n');
        return lines.join('\n');
      case 'assets':
        final rawAssets = data['assets'] as List?;
        if (rawAssets == null || rawAssets.isEmpty) return '';
        int withImages = 0;
        int total = 0;
        final lines = <String>[];
        for (final a in rawAssets) {
          String name, type, hasImage;
          if (a is Asset) {
            name = a.name;
            type = a.type == 'character' ? '角色' : (a.type == 'prop' ? '道具' : '场景');
            hasImage = PersistentImageStore.preferredSource(
                      localPath: a.referenceImageLocalPath,
                      remoteUrl: a.referenceImageUrl,
                    ) !=
                    null
                ? '✓'
                : '✗';
          } else if (a is Map<String, dynamic>) {
            name = a['name'] as String? ?? '?';
            type = a['type'] == 'character' ? '角色' : (a['type'] == 'prop' ? '道具' : '场景');
            hasImage = PersistentImageStore.preferredSource(
                      localPath: a['reference_image_local_path'] as String?,
                      remoteUrl: a['reference_image_url'] as String?,
                    ) !=
                    null
                ? '✓'
                : '✗';
          } else {
            continue;
          }
          lines.add('$type: $name $hasImage');
          total++;
          if (hasImage == '✓') withImages++;
        }
        lines.insert(0, '已完成: $withImages / $total\n');
        return lines.join('\n');
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('创建项目')),
      body: Column(
        children: [
          // Prompt input (disabled while creating)
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _promptController,
              maxLines: 3,
              readOnly: _creating,
              decoration: const InputDecoration(
                labelText: '创意描述',
                hintText: '例如：一个都市白领女孩在咖啡店遇到了她的初恋...',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
          ),

          // Progress area
          Expanded(
            child: _stages.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.auto_awesome, size: 48, color: Colors.grey),
                        SizedBox(height: 12),
                        Text('输入创意后，AI 将逐步为你生成策划、编剧和分镜', style: TextStyle(color: Colors.grey), textAlign: TextAlign.center),
                      ],
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: _stages.map((s) => _buildStageCard(s)).toList(),
                  ),
          ),

          // Bottom action bar
          _buildBottomBar(),
        ],
      ),
    );
  }

  /// Show fullscreen image zoom dialog
  void _showImageZoomDialog({
    String? remoteUrl,
    String? localPath,
    required String title,
  }) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 5.0,
                child: PersistentImage(
                  remoteUrl: remoteUrl,
                  localPath: localPath,
                  fit: BoxFit.contain,
                  placeholder: const Center(
                    child: Icon(Icons.broken_image, size: 64, color: Colors.grey),
                  ),
                ),
              ),
            ),
            // Close button
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 32),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
            // Title
            Positioned(
              bottom: 16,
              left: 16,
              child: Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build asset review UI: grid of asset images with regenerate buttons
  Widget _buildAssetReview(StageProgress stage) {
    final assetData = stage.finalData;
    final rawAssets = assetData?['assets'] as List?;
    if (rawAssets == null || rawAssets.isEmpty) {
      return const Text('无资产数据', style: TextStyle(color: Colors.grey, fontSize: 13));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('参考图预览：', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        const SizedBox(height: 8),
        ...rawAssets.map((a) {
          String name, type, imageUrl, assetId;
          String? localPath;
          if (a is Asset) {
            name = a.name;
            type = a.type;
            imageUrl = a.referenceImageUrl ?? '';
            localPath = a.referenceImageLocalPath;
            assetId = a.id;
          } else if (a is Map<String, dynamic>) {
            name = a['name'] as String? ?? '?';
            type = a['type'] as String? ?? '?';
            imageUrl = a['reference_image_url'] as String? ?? '';
            localPath = a['reference_image_local_path'] as String?;
            assetId = a['id'] as String? ?? '';
          } else {
            return const SizedBox.shrink();
          }
          final typeLabel = type == 'character' ? '角色' : (type == 'prop' ? '道具' : '场景');
          final displaySource = PersistentImageStore.preferredSource(
            localPath: localPath,
            remoteUrl: imageUrl,
          );

          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Image thumbnail (double-tap to zoom)
                GestureDetector(
                  onDoubleTap: displaySource != null && displaySource.isNotEmpty
                      ? () => _showImageZoomDialog(
                            remoteUrl: imageUrl,
                            localPath: localPath,
                            title: '$typeLabel: $name',
                          )
                      : null,
                  child: SizedBox(
                    width: 80,
                    height: 80,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: displaySource != null && displaySource.isNotEmpty
                          ? PersistentImage(
                              remoteUrl: imageUrl,
                              localPath: localPath,
                              imageKey: ValueKey(displaySource),
                              fit: BoxFit.cover,
                            )
                          : Container(
                              color: Colors.grey.shade800,
                              child: const Icon(Icons.image_not_supported, color: Colors.grey),
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Name, type, status
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        typeLabel,
                        style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (imageUrl.isNotEmpty)
                            const Icon(Icons.check_circle, color: Colors.green, size: 14)
                          else
                            const Icon(Icons.error, color: Colors.red, size: 14),
                          const SizedBox(width: 4),
                          Text(
                            imageUrl.isNotEmpty ? '已生成' : '生成失败',
                            style: TextStyle(
                              color: imageUrl.isNotEmpty ? Colors.green : Colors.red,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // Regenerate button
                if (imageUrl.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () => _regenerateAsset(stage, assetId),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重新生成', style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }

  /// Show dialog for asset regeneration feedback, then regenerate
  Future<void> _regenerateAsset(StageProgress stage, String assetId) async {
    final assetData = stage.finalData;
    final rawAssets = assetData?['assets'] as List?;
    if (rawAssets == null) return;

    // Find the asset to regenerate
    String? name;
    String? type;
    String? basePrompt;

    for (final a in rawAssets) {
      if (a is Asset && a.id == assetId) {
        name = a.name;
        type = a.type;
        basePrompt = a.prompt ?? a.description ?? '';
        break;
      } else if (a is Map<String, dynamic> && a['id'] == assetId) {
        name = a['name'] as String? ?? '?';
        type = a['type'] as String? ?? '?';
        basePrompt = a['prompt'] as String? ?? a['description'] as String? ?? '';
        break;
      }
    }

    if (name == null || type == null || basePrompt == null) return;

    if (basePrompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$name 没有可用的描述，无法重新生成')),
      );
      return;
    }

    // Show dialog that displays current description and allows editing
    final result = await _showRegenerateFeedbackDialog(name!, type!, basePrompt);
    if (result == null) return; // User cancelled
    final editedDescription = result.description;
    final feedback = result.feedback;

    // Use the edited description if provided, otherwise use the original
    final effectiveDescription = editedDescription.isNotEmpty ? editedDescription : basePrompt;

    // Build the enhanced prompt using the SAME structure as AssetDesignAgent._buildAssetPrompt()
    // This ensures consistent image generation quality
    final scriptData = _agentCtx?.data['script'] as Map<String, dynamic>?;
    final brief = _agentCtx?.data['brief'] as Map<String, dynamic>?;

    final buffer = StringBuffer();

    // 1. Visual style from brief (if available)
    final visualStyle = brief?['visual_style']?.toString();
    if (visualStyle != null && visualStyle.isNotEmpty) {
      buffer.writeln('整体视觉风格：$visualStyle');
      buffer.writeln('');
    }

    // 2. Type-specific framing (critical for correct image generation)
    if (type == 'character') {
      buffer.writeln('[角色设计参考图]');
      buffer.writeln('生成一张角色参考图，用于后续所有分镜和视频中该角色的外观一致性。');
      buffer.writeln('');
      buffer.writeln('角色描述：$effectiveDescription');
    } else if (type == 'location') {
      buffer.writeln('[场景设计参考图]');
      buffer.writeln('生成一张场景参考图，用于后续所有分镜和视频中该场景的环境一致性。');
      buffer.writeln('');
      buffer.writeln('场景描述：$effectiveDescription');
    } else if (type == 'prop') {
      buffer.writeln('[道具设计参考图]');
      buffer.writeln('生成一张道具参考图，用于后续所有分镜和视频中该道具的外观一致性。');
      buffer.writeln('');
      buffer.writeln('道具描述：$effectiveDescription');
    } else {
      buffer.writeln(effectiveDescription);
    }

    // 3. User feedback (if provided)
    if (feedback.isNotEmpty) {
      buffer.writeln('');
      buffer.write('修改意见：$feedback');
    }

    final enhancedPrompt = buffer.toString();

    final typeLabel = type == 'character' ? '角色' : (type == 'prop' ? '道具' : '场景');
    stage.messages.add(_ProgressMessage(type: 'info', text: '正在重新生成 $typeLabel: $name...'));
    setState(() {});

    try {
      final imageService = dashscope.DashscopeService();
      final imageUrl = await imageService.generateImage(enhancedPrompt);
      final localPath = await PersistentImageStore().persistRemoteImage(
        imageUrl,
        category: 'assets',
        entityId: assetId,
      );

      if (imageUrl.isEmpty) {
        stage.messages.add(_ProgressMessage(type: 'error', text: '$typeLabel: $name 重新生成失败：返回了空 URL'));
        setState(() {});
        return;
      }

      // Replace the asset in stage.finalData['assets']
      // For Asset objects: create a new Asset with updated referenceImageUrl
      // For Maps: update reference_image_url in place
      bool found = false;
      for (int i = 0; i < rawAssets.length; i++) {
        final a = rawAssets[i];
        if (a is Asset && a.id == assetId) {
          final newAsset = Asset(
            id: a.id,
            projectId: a.projectId,
            type: a.type,
            name: a.name,
            description: a.description,
            prompt: a.prompt,
            referenceImageUrl: imageUrl,
            referenceImageLocalPath: localPath,
            state: a.state,
            createdAt: a.createdAt,
          );
          rawAssets[i] = newAsset;
          found = true;
          break;
        } else if (a is Map<String, dynamic> && a['id'] == assetId) {
          a['reference_image_url'] = imageUrl;
          a['reference_image_local_path'] = localPath;
          found = true;
          break;
        }
      }

      if (!found) {
        stage.messages.add(_ProgressMessage(type: 'warn', text: '$typeLabel: $name 在数据中未找到，图片已生成但未更新'));
      }

      // Update in context for downstream stages (handle both Asset objects and Maps)
      if (scriptData != null) {
        final contextAssets = scriptData['assets'] as List?;
        if (contextAssets != null) {
          for (int i = 0; i < contextAssets.length; i++) {
            final ca = contextAssets[i];
            if (ca is Asset && ca.id == assetId) {
              // Replace with new Asset object
              contextAssets[i] = Asset(
                id: ca.id,
                projectId: ca.projectId,
                type: ca.type,
                name: ca.name,
                description: ca.description,
                prompt: ca.prompt,
                referenceImageUrl: imageUrl,
                referenceImageLocalPath: localPath,
                state: ca.state,
                createdAt: ca.createdAt,
              );
              break;
            } else if (ca is Map<String, dynamic> && ca['id'] == assetId) {
              ca['reference_image_url'] = imageUrl;
              ca['reference_image_local_path'] = localPath;
              break;
            }
          }
        }
      }

      // Update in DB
      await AssetDao().updateReferenceImage(
        assetId,
        imageUrl: imageUrl,
        localPath: localPath,
      );

      stage.messages.add(_ProgressMessage(type: 'success', text: '$typeLabel: $name 重新生成完成'));
    } catch (e) {
      stage.messages.add(_ProgressMessage(type: 'error', text: '$typeLabel: $name 重新生成失败: $e'));
    }

    // Clear Flutter's image cache to force reload of updated local image files.
    // Without this, Image.file shows the cached old image even though the file
    // on disk has been replaced with the newly generated one.
    // We clear both the main image cache and the live image cache.
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();

    setState(() {});
  }

  /// Show dialog that displays current asset description and allows editing.
  /// Returns (editedDescription, feedback) tuple, or null if cancelled.
  Future<({String description, String feedback})?> _showRegenerateFeedbackDialog(
    String assetName,
    String assetType,
    String currentDescription,
  ) async {
    final typeLabel = assetType == 'character' ? '角色' : (assetType == 'prop' ? '道具' : '场景');
    final descController = TextEditingController(text: currentDescription);
    final feedbackController = TextEditingController();

    return showDialog<({String description, String feedback})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('重新生成 $typeLabel: $assetName'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('当前描述：', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade800,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  currentDescription,
                  style: const TextStyle(fontSize: 13, color: Colors.white70),
                ),
              ),
              const SizedBox(height: 12),
              const Text('编辑描述（用于图像生成）：', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: descController,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: '例如：男中学生，短发，穿着蓝色校服...',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              const Text('修改意见（可选）：', style: TextStyle(fontSize: 14)),
              const SizedBox(height: 8),
              TextField(
                controller: feedbackController,
                maxLines: 2,
                decoration: const InputDecoration(
                  hintText: '例如：头发改成黑色，衣服换成西装...',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, (
              description: descController.text,
              feedback: feedbackController.text,
            )),
            child: const Text('开始重新生成'),
          ),
        ],
      ),
    );
  }

  Widget _buildStageCard(StageProgress stage) {
    final isDone = stage.status == 'done';
    final isRunning = stage.status == 'running';
    final isError = stage.status == 'error';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: stage.color, width: 4)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Icon(stage.icon, size: 20, color: stage.color),
                  const SizedBox(width: 8),
                  Text(stage.label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: stage.color)),
                  const Spacer(),
                  if (isRunning)
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  if (isDone)
                    const Icon(Icons.check_circle, color: Colors.green, size: 18),
                  if (isError)
                    const Icon(Icons.error, color: Colors.red, size: 18),
                  if (stage.status == 'warn')
                    const Icon(Icons.warning_amber, color: Colors.orange, size: 18),
                ],
              ),

              const SizedBox(height: 6),
              Text(_statusLabel(stage), style: const TextStyle(fontSize: 12, color: Colors.grey)),

              // Messages
              if (stage.messages.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.grey.shade900, borderRadius: BorderRadius.circular(6)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: stage.messages.map((m) => _buildMessage(m)).toList(),
                  ),
                ),
              ],

              // Content preview
              if (stage.contentPreview.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: Colors.grey.shade900, borderRadius: BorderRadius.circular(6)),
                  child: SelectableText(stage.contentPreview, style: const TextStyle(fontSize: 13)),
                ),
              ],

              // Asset design review: show images with regenerate buttons
              // Show for both done and warn status (partially generated)
              if (stage.label == '角色设计' && (isDone || stage.status == 'warn')) ...[
                const SizedBox(height: 8),
                _buildAssetReview(stage),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessage(_ProgressMessage m) {
    Color color;
    String icon;
    switch (m.type) {
      case 'success': color = Colors.green; icon = '✓'; break;
      case 'error': color = Colors.red; icon = '✗'; break;
      case 'warn': color = Colors.orange; icon = '→'; break;
      case 'note': color = Colors.grey; icon = '  '; break;
      default: color = Colors.blue; icon = '○';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(icon, style: TextStyle(color: color, fontSize: 12)),
          const SizedBox(width: 6),
          Expanded(child: SelectableText(m.text, style: TextStyle(color: color, fontSize: 12))),
        ],
      ),
    );
  }

  String _statusLabel(StageProgress stage) {
    switch (stage.status) {
      case 'running': return '进行中...';
      case 'done': return '已完成，请审阅';
      case 'warn': return '部分完成';
      case 'error': return '失败';
      default: return '等待中';
    }
  }

  Widget _buildTemperatureSlider() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.purple.shade200, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tune, size: 16, color: Colors.purple),
              const SizedBox(width: 6),
              const Text(
                '分镜生成创意度',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.purple,
                ),
              ),
              const Spacer(),
              Text(
                _storyboardTemperature.toStringAsFixed(1),
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Slider(
            value: _storyboardTemperature,
            min: 0.0,
            max: 1.0,
            divisions: 10,
            label: _storyboardTemperature.toStringAsFixed(1),
            onChanged: (v) => setState(() => _storyboardTemperature = v),
          ),
          const SizedBox(height: 4),
          const Text(
            '温度越低，LLM 越确定性地遵循剧本；温度越高，LLM 越有创意发挥空间',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    if (!_creating) {
      if (_isResuming) {
        // Resumed project: show "继续生成" if there are more stages, or "返回" if all done
        final allDone = _completedStages.length >= _stageDefs.length;
        final nextLabel = _currentStageIndex < _stageDefs.length
            ? _stageDefs[_currentStageIndex].label
            : '';

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(top: BorderSide(color: Colors.grey.shade800)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!allDone) ...[
                Text(
                  '下一步：$nextLabel',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () {
                    setState(() => _creating = true);
                    _runCurrentStage();
                  },
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('继续生成'),
                ),
                const SizedBox(height: 8),
              ],
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back),
                label: const Text('返回项目列表'),
              ),
            ],
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton.icon(
          onPressed: _startProject,
          icon: const Icon(Icons.auto_awesome),
          label: const Text('开始生成'),
        ),
      );
    }

    final currentStage = _currentStageIndex < _stages.length ? _stages[_currentStageIndex] : null;
    final isDone = currentStage?.status == 'done';
    final isWarn = currentStage?.status == 'warn';
    final isError = currentStage?.status == 'error';
    final isLastStage = _currentStageIndex >= _stageDefs.length - 1;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Colors.grey.shade800)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Error state
          if (isError) ...[
            Text(
              currentStage?.feedback ?? '生成失败',
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () {
                currentStage?.status = 'running';
                currentStage?.messages.add(_ProgressMessage(type: 'warn', text: '--- 重新生成 ---'));
                currentStage?.contentPreview = '';
                currentStage?.finalData = null;
                setState(() {});
                _runCurrentStage();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('重新生成'),
            ),
          ]
          // Done or Warn state (warn = review exhausted but allow to continue)
          else if (isDone || isWarn) ...[
            if (isWarn && currentStage?.feedback != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.shade900.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '⚠ 审查未通过（已重试多次）。建议修改后重新生成，或点击继续。',
                  style: const TextStyle(color: Colors.orange, fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
            ],
            // Show temperature slider before storyboard stage
            if (_currentStageIndex == 3) ...[
              _buildTemperatureSlider(),
              const SizedBox(height: 12),
            ],
            // Feedback input
            TextField(
              maxLines: 2,
              decoration: InputDecoration(
                hintText: isLastStage
                    ? '可选：输入修改建议，或直接点击"完成并进入详情页"'
                    : '可选：输入修改建议，或直接点击"${isLastStage ? '完成并进入详情页' : '同意并继续'}"',
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onChanged: (v) => _userFeedback = v,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _retryWithFeedback,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新生成'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: isLastStage ? _finishProject : _approveAndContinue,
                    icon: Icon(isLastStage ? Icons.check : Icons.arrow_forward),
                    label: Text(isLastStage ? '完成并进入详情页' : '同意并继续'),
                  ),
                ),
              ],
            ),
          ] else ...[
            const LinearProgressIndicator(),
          ],
        ],
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

/// Stage definition
class StageDef {
  final String label;
  final IconData icon;
  final Color color;
  final String reviewType;

  const StageDef({required this.label, required this.icon, required this.color, required this.reviewType});
}

/// Tracks the progress of a single workflow stage
class StageProgress {
  final String label;
  final IconData icon;
  final Color color;
  final List<_ProgressMessage> messages = [];
  String contentPreview = '';
  String status = 'pending'; // pending, running, done, error
  String? feedback;
  Map<String, dynamic>? finalData;

  StageProgress({required this.label, required this.icon, required this.color});
}

/// A single progress message within a stage
class _ProgressMessage {
  final String type; // info, success, error, warn, note
  final String text;

  _ProgressMessage({required this.type, required this.text});
}
