import 'package:flutter/material.dart';
import '../config/app_config.dart';
import '../db/dao/dao.dart';
import '../models/models.dart';
import '../services/media_service.dart';
import '../services/app_logger.dart';
import '../services/llm_service.dart';
import '../services/persistent_image_store.dart';
import '../services/project_wiki_store.dart';
import '../services/wiki_mutation_service.dart';
import '../widgets/persistent_image.dart';
import 'create_project_screen.dart';
import 'seedance_web_screen.dart';
import 'video_preview_screen.dart';

class ProjectDetailScreen extends StatefulWidget {
  final Project project;
  const ProjectDetailScreen({super.key, required this.project});

  @override
  State<ProjectDetailScreen> createState() => _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends State<ProjectDetailScreen> {
  Brief? _brief;
  List<Asset> _assets = [];
  List<Storyboard> _storyboards = [];
  List<VideoClip> _videoClips = [];
  bool _loading = true;
  bool _generating = false;
  String _genStatus = '';

  // Step-by-step image generation state
  bool _imageReviewMode = false;
  int _currentImageIndex = -1;
  String? _currentImageUrl;
  bool _imageGenerating = false;
  // storyboardId -> image URL
  final Map<String, String> _confirmedImages = {};
  final _llm = LlmService();
  late final _wiki = WikiMutationService(
    store: ProjectWikiStore(),
    llm: _llm,
  );
  final Map<String, String> _retryFeedback = {};
  bool _allImagesConfirmed = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _llm.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final pid = widget.project.id;
    final brief = await BriefDao().getByProjectId(pid);
    final assets = await _ensureAssetImagesPersisted(
      await AssetDao().getByProjectId(pid),
    );
    final rawStoryboards = await StoryboardDao().getByProjectId(pid);
    await AppLogger.info('ProjectDetail: loaded storyboards from DB', data: {
      'projectId': pid,
      'storyboardCount': rawStoryboards.length,
      'ids': rawStoryboards.map((s) => s.id).toList(),
    });
    final storyboards = await _ensureStoryboardImagesPersisted(rawStoryboards);
    final clips = await VideoClipDao().getByProjectId(pid);

    setState(() {
      _brief = brief;
      _assets = assets;
      _storyboards = storyboards;
      _videoClips = clips;
      _loading = false;
    });
  }

  Future<List<Asset>> _ensureAssetImagesPersisted(List<Asset> assets) async {
    final imageStore = PersistentImageStore();
    final updatedAssets = <Asset>[];

    for (final asset in assets) {
      String? localPath = asset.referenceImageLocalPath;
      if (localPath == null &&
          asset.referenceImageUrl != null &&
          asset.referenceImageUrl!.isNotEmpty) {
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

  /// Start image generation review mode.
  /// Tries sequential (batch) mode first for character consistency.
  /// Falls back to single-image mode if sequential returns wrong count.
  Future<void> _startImageGeneration() async {
    if (_storyboards.isEmpty) return;
    final dashscope = MediaService();

    setState(() {
      _imageReviewMode = true;
      _currentImageIndex = 0;
      _currentImageUrl = null;
      _imageGenerating = true;
      _genStatus = '正在生成分镜首帧图...';
      _confirmedImages.clear();
      _retryFeedback.clear();
    });

    List<String> imageUrls = [];

    try {
      final prompts = _storyboards.map((sb) {
        final feedback = _retryFeedback[sb.id];
        if (feedback != null) {
          return '${sb.firstFramePrompt ?? sb.description ?? ''}\n\n修改要求：$feedback';
        }
        return sb.firstFramePrompt ?? sb.description ?? '';
      }).toList();

      // Try sequential (batch) mode first
      imageUrls = await dashscope.generateImagesSequential(prompts);

      if (imageUrls.length != _storyboards.length) {
        // Sequential mode returned wrong count, fall back to single-image mode
        await AppLogger.info(
          'Sequential mode returned wrong count, falling back to single-image mode',
          data: {
            'tag': 'ui.image',
            'expected': _storyboards.length,
            'actual': imageUrls.length,
          },
        );
        imageUrls = [];
        for (int i = 0; i < prompts.length; i++) {
          if (!mounted) return;
          setState(() => _genStatus =
              '正在生成镜头 ${_storyboards[i].sceneNum}-${_storyboards[i].shotNum} (${i + 1}/${prompts.length})...');
          final url = await dashscope.generateImage(prompts[i]);
          imageUrls.add(url);
        }
      }
    } catch (e) {
      // Sequential mode failed completely, fall back to single-image mode
      await AppLogger.warn(
        'Sequential mode failed, falling back to single-image mode',
        data: {'tag': 'ui.image', 'error': e.toString()},
      );
      if (!mounted) return;
      imageUrls = [];
      final prompts = _storyboards.map((sb) {
        final feedback = _retryFeedback[sb.id];
        if (feedback != null) {
          return '${sb.firstFramePrompt ?? sb.description ?? ''}\n\n修改要求：$feedback';
        }
        return sb.firstFramePrompt ?? sb.description ?? '';
      }).toList();
      for (int i = 0; i < prompts.length; i++) {
        if (!mounted) return;
        setState(() => _genStatus =
            '正在生成镜头 ${_storyboards[i].sceneNum}-${_storyboards[i].shotNum} (${i + 1}/${prompts.length})...');
        try {
          final url = await dashscope.generateImage(prompts[i]);
          imageUrls.add(url);
        } catch (e2) {
          if (!mounted) return;
          setState(() {
            _imageGenerating = false;
            _genStatus = '生成失败: $e2';
          });
          return;
        }
      }
    }

    if (!mounted) return;

    final imageStore = PersistentImageStore();

    // Store all URLs mapped to their storyboard IDs
    for (int i = 0; i < imageUrls.length && i < _storyboards.length; i++) {
      final sb = _storyboards[i];
      final url = imageUrls[i];
      _confirmedImages[sb.id] = url;
      final localPath = await imageStore.persistRemoteImage(
        url,
        category: 'storyboards',
        entityId: sb.id,
      );

      // Update DB
      try {
        await StoryboardDao().updateImageUrl(sb.id, url, localPath: localPath);
      } catch (_) {
        // Ignore DB errors, continue
      }

      // Update local storyboard state
      final idx = _storyboards.indexWhere((s) => s.id == sb.id);
      if (idx >= 0) {
        _storyboards[idx] = Storyboard(
          id: _storyboards[idx].id,
          projectId: _storyboards[idx].projectId,
          sceneNum: _storyboards[idx].sceneNum,
          shotNum: _storyboards[idx].shotNum,
          shotType: _storyboards[idx].shotType,
          cameraMove: _storyboards[idx].cameraMove,
          description: _storyboards[idx].description,
          firstFramePrompt: _storyboards[idx].firstFramePrompt,
          videoPrompt: _storyboards[idx].videoPrompt,
          duration: _storyboards[idx].duration,
          assets: _storyboards[idx].assets,
          state: 'image_ready',
          createdAt: _storyboards[idx].createdAt,
          referenceImageUrl: url,
          referenceImageLocalPath: localPath,
          referenceImageUrls: _storyboards[idx].referenceImageUrls,
        );
      }
    }
    await _wiki.updateStoryboards(
      projectId: widget.project.id,
      storyboards: _storyboards,
    );

    if (!mounted) return;

    // Set first image for review
    setState(() {
      _currentImageUrl = _confirmedImages[_storyboards[0].id];
      _imageGenerating = false;
      _genStatus =
          '镜头 ${_storyboards[0].sceneNum}-${_storyboards[0].shotNum} 首帧图已生成，请审阅（1/${_storyboards.length}）';
    });
  }

  /// Generate image for the current storyboard index
  Future<void> _generateCurrentImage() async {
    if (_currentImageIndex < 0 || _currentImageIndex >= _storyboards.length) {
      return;
    }

    final sb = _storyboards[_currentImageIndex];
    final dashscope = MediaService();

    setState(() {
      _imageGenerating = true;
      _genStatus = '正在生成镜头 ${sb.sceneNum}-${sb.shotNum} 的首帧图...';
    });

    try {
      final prompt = sb.firstFramePrompt ?? sb.description ?? '';
      final feedback = _retryFeedback[sb.id];
      final finalPrompt =
          feedback != null ? '$prompt\n\n修改要求：$feedback' : prompt;

      final imageUrl = await dashscope.generateImage(finalPrompt);
      final localPath = await PersistentImageStore().persistRemoteImage(
        imageUrl,
        category: 'storyboards',
        entityId: sb.id,
      );

      await AppLogger.info(
        'generateImage returned to UI',
        data: {
          'tag': 'ui.image',
          'mounted': mounted,
          'urlLen': imageUrl.length,
        },
      );

      if (!mounted) {
        await AppLogger.info('Not mounted after generateImage',
            data: {'tag': 'ui.image'});
        return;
      }

      // Update storyboard in DB
      try {
        await StoryboardDao()
            .updateImageUrl(sb.id, imageUrl, localPath: localPath);
        await AppLogger.info('DB update completed',
            data: {'tag': 'ui.image', 'id': sb.id});
      } catch (e, st) {
        await AppLogger.error(
          'DB update threw exception',
          data: {'tag': 'ui.image', 'error': e.toString()},
          stackTrace: st,
        );
      }

      if (!mounted) {
        await AppLogger.info('Not mounted before setState',
            data: {'tag': 'ui.image'});
        return;
      }

      final storyboardIndex = _storyboards.indexWhere((s) => s.id == sb.id);
      if (storyboardIndex >= 0) {
        final current = _storyboards[storyboardIndex];
        _storyboards[storyboardIndex] = Storyboard(
          id: current.id,
          projectId: current.projectId,
          sceneNum: current.sceneNum,
          shotNum: current.shotNum,
          shotType: current.shotType,
          cameraMove: current.cameraMove,
          description: current.description,
          firstFramePrompt: current.firstFramePrompt,
          videoPrompt: current.videoPrompt,
          duration: current.duration,
          assets: current.assets,
          state: 'image_ready',
          createdAt: current.createdAt,
          referenceImageUrl: imageUrl,
          referenceImageLocalPath: localPath,
          referenceImageUrls: current.referenceImageUrls,
        );
      }
      await _wiki.updateStoryboards(
        projectId: widget.project.id,
        storyboards: _storyboards,
      );

      setState(() {
        _currentImageUrl = imageUrl;
        _imageGenerating = false;
        _genStatus = '镜头 ${sb.sceneNum}-${sb.shotNum} 首帧图生成完成，请审阅';
      });

      await AppLogger.info(
        'setState completed',
        data: {
          'tag': 'ui.image',
          'generating': _imageGenerating,
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _imageGenerating = false;
        _genStatus = '生成失败: $e';
      });
    }
  }

  /// User confirms the current image, move to next
  Future<void> _confirmImage() async {
    if (_currentImageUrl == null) return;
    final sb = _storyboards[_currentImageIndex];
    _confirmedImages[sb.id] = _currentImageUrl!;

    final nextIndex = _currentImageIndex + 1;
    if (nextIndex >= _storyboards.length) {
      // All images confirmed - exit review mode
      setState(() {
        _imageReviewMode = false;
        _currentImageIndex = -1;
        _currentImageUrl = null;
        _allImagesConfirmed = true;
        _genStatus = '所有首帧图已确认，可以生成视频了';
      });
      await _loadData();
      return;
    }

    // Move to next pre-generated image
    setState(() {
      _currentImageIndex = nextIndex;
      _currentImageUrl = _confirmedImages[_storyboards[nextIndex].id];
    });
  }

  /// User wants to retry the current image with feedback
  Future<void> _retryCurrentImage() async {
    final sb = _storyboards[_currentImageIndex];

    final feedback = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return Dialog(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '重新生成首帧图',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  '镜头 ${sb.sceneNum}-${sb.shotNum}：${sb.description ?? ''}',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                const Text('请输入修改要求：'),
                const SizedBox(height: 8),
                TextField(
                  controller: ctrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: '例如：让画面更亮一些，增加一些科技感',
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, ctrl.text),
                      child: const Text('重新生成'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    if (feedback != null && feedback.isNotEmpty && mounted) {
      _retryFeedback[sb.id] = feedback;
      await _generateCurrentImage();
    }
  }

  /// After all images are confirmed, generate videos for all clips
  Future<void> _startVideoGeneration() async {
    if (_storyboards.isEmpty) return;

    setState(() {
      _generating = true;
      _genStatus = '正在生成视频...';
    });

    try {
      final dashscope = MediaService();

      for (int i = 0; i < _storyboards.length; i++) {
        if (!mounted) return;
        final sb = _storyboards[i];
        final imageUrl = _confirmedImages[sb.id] ?? sb.referenceImageUrl ?? '';

        final clipId =
            'clip_${DateTime.now().millisecondsSinceEpoch.toString().substring(6)}';
        final clip = VideoClip(
          id: clipId,
          projectId: widget.project.id,
          storyboardId: sb.id,
          state: 'generating',
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
        await VideoClipDao().insert(clip);

        setState(() => _genStatus =
            '正在生成 ${_truncateText(sb.description ?? '...', 15)} 的视频...');

        try {
          final videoPrompt = sb.videoPrompt ?? '';
          final videoUrl = await dashscope.generateVideo(
            prompt: videoPrompt,
            firstFrameUrl: imageUrl,
            duration: sb.duration ?? 5,
          );

          await VideoClipDao().update(clipId, {
            'video_url': videoUrl,
            'state': 'completed',
          });
        } catch (e) {
          await VideoClipDao().update(clipId, {
            'state': 'failed',
            'error_reason': e.toString(),
          });
        }
      }

      setState(() => _genStatus = '视频生成完成！');
    } catch (e) {
      setState(() => _genStatus = '生成失败: $e');
    } finally {
      setState(() => _generating = false);
      await _loadData();
    }
  }

  /// Generate video for a single storyboard using Seedance web automation.
  Future<void> _generateVideoForStoryboard(Storyboard sb) async {
    final imageUrl = PersistentImageStore.preferredSource(
          localPath: sb.referenceImageLocalPath,
          remoteUrl: sb.referenceImageUrl,
        ) ??
        (sb.referenceImageUrls?.isNotEmpty == true
            ? sb.referenceImageUrls!.first
            : null);
    if (imageUrl == null || imageUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('该分镜缺少首帧图，请先生成首帧图。'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    // Collect character + scene + prop reference image URLs
    final refImageUrls = <String>[];
    for (final a in _assets) {
      final referenceSource = PersistentImageStore.preferredSource(
        localPath: a.referenceImageLocalPath,
        remoteUrl: a.referenceImageUrl,
      );
      if ((a.type == 'character' ||
              a.type == 'prop' ||
              a.type == 'location' ||
              a.type == 'scene') &&
          referenceSource != null &&
          referenceSource.isNotEmpty) {
        refImageUrls.add(referenceSource);
      }
    }

    final item = SeedanceStoryboardItem(
      storyboardId: sb.id,
      imageUrl: imageUrl,
      prompt: _buildSeedanceContinuityPrompt(sb),
      firstFramePrompt: sb.firstFramePrompt,
      description: sb.description ?? '',
      sceneNum: sb.sceneNum,
      shotNum: sb.shotNum,
      referenceImageUrls: refImageUrls.isNotEmpty ? refImageUrls : null,
    );

    final result = await Navigator.push<Map<String, String>>(
      context,
      MaterialPageRoute(
        builder: (_) => SeedanceWebScreen(
          batchStoryboards: [item],
          projectId: widget.project.id,
        ),
      ),
    );

    // Handle result: save video clip if generated
    if (result != null && result.containsKey(sb.id)) {
      final videoUrl = result[sb.id]!;
      await _saveSeedanceVideoClip(sb.id, videoUrl);
      if (mounted) _loadData();
    }
  }

  String _buildSeedanceContinuityPrompt(Storyboard storyboard) {
    final sorted = [..._storyboards]..sort((a, b) {
        if (a.sceneNum != b.sceneNum) return a.sceneNum - b.sceneNum;
        return a.shotNum - b.shotNum;
      });
    final index = sorted.indexWhere((s) => s.id == storyboard.id);
    final previous = index > 0 ? sorted[index - 1] : null;
    final next =
        index >= 0 && index + 1 < sorted.length ? sorted[index + 1] : null;
    final previousSameScene =
        previous != null && previous.sceneNum == storyboard.sceneNum;
    final nextSameScene = next != null && next.sceneNum == storyboard.sceneNum;

    final buffer = StringBuffer()
      ..writeln(storyboard.videoPrompt ?? '')
      ..writeln()
      ..writeln('【连续性约束，必须优先遵守】')
      ..writeln('当前镜头：Scene ${storyboard.sceneNum} Shot ${storyboard.shotNum}')
      ..writeln('当前镜头画面：${storyboard.description ?? ''}');
    if (previousSameScene) {
      buffer
        ..writeln('上一镜头画面：${previous.description ?? ''}')
        ..writeln('上一镜头动态：${previous.videoPrompt ?? ''}')
        ..writeln('本镜头首帧必须承接上一镜头结尾的人物位置、朝向、运动方向和场景方位。');
    } else {
      buffer.writeln('这是该场景第一个镜头，需要建立清楚的场景方位和人物运动方向。');
    }
    if (nextSameScene) {
      buffer
        ..writeln('下一镜头画面：${next.description ?? ''}')
        ..writeln('下一镜头动态：${next.videoPrompt ?? ''}')
        ..writeln('本镜头结尾必须为下一镜头留下合理衔接，不要让人物突然反向或瞬移。');
    }
    buffer
      ..writeln('硬性要求：保持同一人物、同一服装、同一道具、同一校门/教室空间关系。')
      ..writeln('明确表现“起始状态 -> 动作过程 -> 结束状态”；除非明确写出转身/回头，否则不得改变运动方向。');
    return buffer.toString();
  }

  /// Generate video for a single storyboard through the configured DashScope API.
  Future<void> _generateApiVideoForStoryboard(Storyboard sb) async {
    final imageUrl = _remoteStoryboardImageUrl(sb);
    if (imageUrl == null || imageUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('该分镜缺少可供 API 访问的首帧图，请先生成首帧图。'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    final refImageUrls = _assets
        .map((a) => a.referenceImageUrl)
        .whereType<String>()
        .where((url) => url.isNotEmpty)
        .toList();

    final clipId = 'clip_${sb.id}_${DateTime.now().millisecondsSinceEpoch}';
    await VideoClipDao().insert(
      VideoClip(
        id: clipId,
        projectId: widget.project.id,
        storyboardId: sb.id,
        state: 'generating',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    setState(() {
      _generating = true;
      _genStatus = '正在生成镜头 ${sb.sceneNum}-${sb.shotNum} 视频...';
    });

    try {
      final videoUrl = await MediaService().generateVideo(
        prompt: sb.videoPrompt ?? '',
        firstFrameUrl: imageUrl,
        duration: sb.duration ?? 5,
        referenceImageUrls: refImageUrls.isNotEmpty ? refImageUrls : null,
      );
      await VideoClipDao().update(clipId, {
        'video_url': videoUrl,
        'state': 'completed',
      });
    } catch (e) {
      await VideoClipDao().update(clipId, {
        'state': 'failed',
        'error_reason': e.toString(),
      });
    } finally {
      if (mounted) {
        setState(() => _generating = false);
        await _loadData();
      }
    }
  }

  String? _remoteStoryboardImageUrl(Storyboard sb) {
    final primary = sb.referenceImageUrl;
    if (primary != null &&
        primary.isNotEmpty &&
        !PersistentImageStore.isLocalPath(primary)) {
      return primary;
    }
    final urls = sb.referenceImageUrls ?? const [];
    for (final url in urls) {
      if (url.isNotEmpty && !PersistentImageStore.isLocalPath(url)) {
        return url;
      }
    }
    return null;
  }

  /// Save a single Seedance video clip to the database.
  Future<void> _saveSeedanceVideoClip(
      String storyboardId, String videoUrl) async {
    final clipId =
        'clip_seedance_${DateTime.now().millisecondsSinceEpoch.toString().substring(6)}_$storyboardId';
    try {
      final localPath = await _wiki.persistVideoFile(
        projectId: widget.project.id,
        videoUrl: videoUrl,
        storyboardId: storyboardId,
      );
      final clip = VideoClip(
        id: clipId,
        projectId: widget.project.id,
        storyboardId: storyboardId,
        videoUrl: videoUrl,
        videoLocalPath: localPath,
        state: 'completed',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      await VideoClipDao().insert(clip);
      final clips = await VideoClipDao().getByProjectId(widget.project.id);
      await _wiki.updateVideoClips(
        projectId: widget.project.id,
        videoData: {'clips': clips.map((c) => c.toMap()).toList()},
      );
    } catch (e) {
      await AppLogger.warn(
        'Failed to save Seedance video clip',
        data: {'storyboard_id': storyboardId, 'error': e.toString()},
      );
    }
  }

  /// Start batch video generation using Seedance web automation.
  /// Opens a single SeedanceWebScreen with all storyboards for interactive processing.
  Future<void> _startSeedanceBatchGeneration() async {
    if (_storyboards.isEmpty) return;

    // Collect character + scene + prop reference image URLs (shared across all storyboards)
    final refImageUrls = <String>[];
    for (final a in _assets) {
      final referenceSource = PersistentImageStore.preferredSource(
        localPath: a.referenceImageLocalPath,
        remoteUrl: a.referenceImageUrl,
      );
      if ((a.type == 'character' ||
              a.type == 'prop' ||
              a.type == 'location' ||
              a.type == 'scene') &&
          referenceSource != null &&
          referenceSource.isNotEmpty) {
        refImageUrls.add(referenceSource);
      }
    }

    // Build batch items for all storyboards that have images
    final batchItems = <SeedanceStoryboardItem>[];
    for (final sb in _storyboards) {
      final imageUrl = PersistentImageStore.preferredSource(
            localPath: sb.referenceImageLocalPath,
            remoteUrl: sb.referenceImageUrl,
          ) ??
          (sb.referenceImageUrls?.isNotEmpty == true
              ? sb.referenceImageUrls!.first
              : null);
      if (imageUrl == null || imageUrl.isEmpty) continue;

      batchItems.add(SeedanceStoryboardItem(
        storyboardId: sb.id,
        imageUrl: imageUrl,
        prompt: _buildSeedanceContinuityPrompt(sb),
        firstFramePrompt: sb.firstFramePrompt,
        description: sb.description ?? '',
        sceneNum: sb.sceneNum,
        shotNum: sb.shotNum,
        referenceImageUrls: refImageUrls.isNotEmpty ? refImageUrls : null,
      ));
    }

    if (batchItems.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '没有可用的分镜图片。请先点击"生成首帧图"按钮生成所有分镜首帧图，确认后再使用批量生成视频。',
            ),
            duration: Duration(seconds: 5),
          ),
        );
      }
      return;
    }

    // Open single SeedanceWebScreen with all storyboards
    final result = await Navigator.push<Map<String, String>>(
      context,
      MaterialPageRoute(
        builder: (_) => SeedanceWebScreen(
          batchStoryboards: batchItems,
          projectId: widget.project.id,
        ),
      ),
    );

    if (result == null || result.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未生成任何视频')),
        );
      }
      return;
    }

    // Save results
    int success = 0;
    int failed = 0;
    for (final sb in _storyboards) {
      if (!result.containsKey(sb.id)) {
        failed++;
        continue;
      }
      final videoUrl = result[sb.id]!;
      try {
        await _saveSeedanceVideoClip(sb.id, videoUrl);
        success++;
      } catch (e) {
        failed++;
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('批量生成完成：成功 $success 个，失败 $failed 个')),
    );
    await _loadData();
  }

  /// Old bulk generate method (kept for compatibility)
  Future<void> _generateVideos() async {
    if (_storyboards.isEmpty) return;

    setState(() {
      _generating = true;
      _genStatus = '正在生成视频...';
    });

    try {
      final dashscope = MediaService();

      for (final sb in _storyboards) {
        if (!mounted) return;

        final clipId =
            'clip_${DateTime.now().millisecondsSinceEpoch.toString().substring(6)}';
        final clip = VideoClip(
          id: clipId,
          projectId: widget.project.id,
          storyboardId: sb.id,
          state: 'generating',
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
        await VideoClipDao().insert(clip);

        setState(() => _genStatus =
            '正在生成 ${_truncateText(sb.description ?? '...', 10)} 的首帧图...');

        try {
          final imagePrompt = sb.firstFramePrompt ?? sb.description ?? '';
          final imageUrl = await dashscope.generateImage(imagePrompt);

          setState(() => _genStatus = '正在生成视频...');

          final videoPrompt = sb.videoPrompt ?? '';
          final videoUrl = await dashscope.generateVideo(
            prompt: videoPrompt,
            firstFrameUrl: imageUrl,
            duration: sb.duration ?? 5,
          );

          await VideoClipDao().update(clipId, {
            'video_url': videoUrl,
            'state': 'completed',
          });
        } catch (e) {
          await VideoClipDao().update(clipId, {
            'state': 'failed',
            'error_reason': e.toString(),
          });
        }
      }

      setState(() => _genStatus = '视频生成完成！');
    } catch (e) {
      setState(() => _genStatus = '生成失败: $e');
    } finally {
      setState(() => _generating = false);
      final clips = await VideoClipDao().getByProjectId(widget.project.id);
      await _wiki.updateVideoClips(
        projectId: widget.project.id,
        videoData: {'clips': clips.map((c) => c.toMap()).toList()},
      );
      await _loadData();
    }
  }

  /// Retry only the failed video clips
  Future<void> _retryFailedClips() async {
    final failedClips = _videoClips.where((c) => c.state == 'failed').toList();
    if (failedClips.isEmpty) return;

    setState(() {
      _generating = true;
      _genStatus = '正在重试失败的视频片段...';
    });

    try {
      final dashscope = MediaService();
      int count = 0;

      for (final clip in failedClips) {
        if (!mounted) return;
        final sb =
            _storyboards.where((s) => s.id == clip.storyboardId).firstOrNull;
        if (sb == null) continue;

        final imageUrl = sb.referenceImageUrl;
        if (imageUrl == null || imageUrl.isEmpty) continue;

        count++;
        setState(() => _genStatus = '正在重试 ${count}/${failedClips.length}...');

        try {
          final videoPrompt = sb.videoPrompt ?? '';
          final videoUrl = await dashscope.generateVideo(
            prompt: videoPrompt,
            firstFrameUrl: imageUrl,
            duration: sb.duration ?? 5,
          );

          await VideoClipDao().update(clip.id, {
            'video_url': videoUrl,
            'state': 'completed',
            'error_reason': null,
          });
        } catch (e) {
          await VideoClipDao().update(clip.id, {
            'state': 'failed',
            'error_reason': e.toString(),
          });
        }
      }

      setState(() => _genStatus = '重试完成！');
    } catch (e) {
      setState(() => _genStatus = '重试失败: $e');
    } finally {
      setState(() => _generating = false);
      final clips = await VideoClipDao().getByProjectId(widget.project.id);
      await _wiki.updateVideoClips(
        projectId: widget.project.id,
        videoData: {'clips': clips.map((c) => c.toMap()).toList()},
      );
      await _loadData();
    }
  }

  /// Regenerate all video clips from scratch
  Future<void> _regenerateAllClips() async {
    if (_storyboards.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认'),
        content: const Text('这将删除所有现有视频片段并重新生成，确认继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _generating = true;
      _genStatus = '正在重新生成视频...';
    });

    try {
      final dashscope = MediaService();
      int total = _storyboards.length;
      int success = 0;

      for (int i = 0; i < _storyboards.length; i++) {
        if (!mounted) return;
        final sb = _storyboards[i];
        String? imageUrl = sb.referenceImageUrl;

        if (imageUrl == null || imageUrl.isEmpty) {
          // Skip if no reference image, try generating one first
          setState(() => _genStatus =
              '正在生成镜头 ${sb.sceneNum}-${sb.shotNum} 参考图... (${i + 1}/$total)');
          try {
            final imagePrompt = sb.firstFramePrompt ?? sb.description ?? '';
            final img = await dashscope.generateImage(imagePrompt);
            final localPath = await PersistentImageStore().persistRemoteImage(
              img,
              category: 'storyboards',
              entityId: sb.id,
            );
            await StoryboardDao()
                .updateImageUrl(sb.id, img, localPath: localPath);
            // Update local copy
            final idx = _storyboards.indexWhere((s) => s.id == sb.id);
            if (idx >= 0) {
              _storyboards[idx] = Storyboard(
                id: sb.id,
                projectId: sb.projectId,
                sceneNum: sb.sceneNum,
                shotNum: sb.shotNum,
                shotType: sb.shotType,
                cameraMove: sb.cameraMove,
                description: sb.description,
                firstFramePrompt: sb.firstFramePrompt,
                videoPrompt: sb.videoPrompt,
                duration: sb.duration,
                assets: sb.assets,
                state: 'image_ready',
                createdAt: sb.createdAt,
                referenceImageUrl: img,
                referenceImageLocalPath: localPath,
                referenceImageUrls: sb.referenceImageUrls,
              );
            }
            imageUrl = img;
            await _wiki.updateStoryboards(
              projectId: widget.project.id,
              storyboards: _storyboards,
            );
          } catch (e) {
            await AppLogger.warn('Failed to generate image for retry',
                data: {'storyboard_id': sb.id});
          }
        }

        final clipId = 'clip_${sb.id}_${DateTime.now().millisecondsSinceEpoch}';
        final clip = VideoClip(
          id: clipId,
          projectId: widget.project.id,
          storyboardId: sb.id,
          state: 'generating',
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
        await VideoClipDao().insert(clip);

        setState(() => _genStatus =
            '正在生成镜头 ${sb.sceneNum}-${sb.shotNum} 视频... (${i + 1}/$total)');

        try {
          final finalImageUrl = imageUrl ?? '';
          if (finalImageUrl.isNotEmpty) {
            final videoPrompt = sb.videoPrompt ?? '';
            final videoUrl = await dashscope.generateVideo(
              prompt: videoPrompt,
              firstFrameUrl: finalImageUrl,
              duration: sb.duration ?? 5,
            );
            await VideoClipDao().update(clipId, {
              'video_url': videoUrl,
              'state': 'completed',
            });
            success++;
          } else {
            await VideoClipDao().update(clipId, {
              'state': 'failed',
              'error_reason': '无可用参考图',
            });
          }
        } catch (e) {
          await VideoClipDao().update(clipId, {
            'state': 'failed',
            'error_reason': e.toString(),
          });
        }
      }

      setState(() => _genStatus = '生成完成：成功 $success/$total');
    } catch (e) {
      setState(() => _genStatus = '生成失败: $e');
    } finally {
      setState(() => _generating = false);
      final clips = await VideoClipDao().getByProjectId(widget.project.id);
      await _wiki.updateVideoClips(
        projectId: widget.project.id,
        videoData: {'clips': clips.map((c) => c.toMap()).toList()},
      );
      await _loadData();
    }
  }

  /// Show dialog to edit storyboard fields
  Future<void> _editStoryboard(Storyboard sb) async {
    final descCtrl = TextEditingController(text: sb.description ?? '');
    final firstFrameCtrl =
        TextEditingController(text: sb.firstFramePrompt ?? '');
    final videoCtrl = TextEditingController(text: sb.videoPrompt ?? '');
    final durationCtrl = TextEditingController(text: '${sb.duration ?? 5}');

    final shotTypes = ['close-up', 'medium', 'wide', 'extreme-close-up'];
    final cameraMoves = ['static', 'pan', 'zoom', 'tilt', 'dolly'];

    int selectedShotType = shotTypes.indexOf(sb.shotType ?? 'medium');
    if (selectedShotType < 0) selectedShotType = 1;

    int selectedCameraMove = cameraMoves.indexOf(sb.cameraMove ?? 'static');
    if (selectedCameraMove < 0) selectedCameraMove = 0;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      child: Text(
                        '${sb.sceneNum}-${sb.shotNum}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      '编辑分镜',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const Divider(),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Scene & Shot number (read-only)
                        _editField(
                          label: '场景-镜头',
                          value: '${sb.sceneNum}-${sb.shotNum}',
                          readOnly: true,
                        ),
                        // Description
                        _editTextField(
                          label: '画面描述',
                          controller: descCtrl,
                          maxLines: 3,
                        ),
                        // Shot type dropdown
                        _editDropdown(
                          label: '镜头类型',
                          value: shotTypes[selectedShotType],
                          items: shotTypes,
                          onChanged: (v) =>
                              selectedShotType = shotTypes.indexOf(v!),
                        ),
                        // Camera move dropdown
                        _editDropdown(
                          label: '运镜方式',
                          value: cameraMoves[selectedCameraMove],
                          items: cameraMoves,
                          onChanged: (v) =>
                              selectedCameraMove = cameraMoves.indexOf(v!),
                        ),
                        // Duration
                        _editTextField(
                          label: '时长 (秒)',
                          controller: durationCtrl,
                          keyboardType: TextInputType.number,
                        ),
                        // First frame prompt
                        _editTextField(
                          label: '首帧图提示词',
                          controller: firstFrameCtrl,
                          maxLines: 3,
                          hint: '用于 wan2.7-image 生成首帧',
                        ),
                        // Video prompt
                        _editTextField(
                          label: '视频提示词',
                          controller: videoCtrl,
                          maxLines: 3,
                          hint: '用于 wan2.7-i2v 生成视频',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () {
                        Navigator.pop(ctx, {
                          'description': descCtrl.text,
                          'firstFramePrompt': firstFrameCtrl.text,
                          'videoPrompt': videoCtrl.text,
                          'shotType': shotTypes[selectedShotType],
                          'cameraMove': cameraMoves[selectedCameraMove],
                          'duration': int.tryParse(durationCtrl.text) ?? 5,
                        });
                      },
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    descCtrl.dispose();
    firstFrameCtrl.dispose();
    videoCtrl.dispose();
    durationCtrl.dispose();

    if (result != null && mounted) {
      await StoryboardDao().update(sb.id, {
        'description': result['description'],
        'first_frame_prompt': result['firstFramePrompt'],
        'video_prompt': result['videoPrompt'],
        'shot_type': result['shotType'],
        'camera_move': result['cameraMove'],
        'duration': result['duration'],
      });
      // Update local state
      setState(() {
        final idx = _storyboards.indexWhere((s) => s.id == sb.id);
        if (idx >= 0) {
          _storyboards[idx] = Storyboard(
            id: _storyboards[idx].id,
            projectId: _storyboards[idx].projectId,
            sceneNum: _storyboards[idx].sceneNum,
            shotNum: _storyboards[idx].shotNum,
            shotType: result['shotType'] as String,
            cameraMove: result['cameraMove'] as String,
            description: result['description'] as String,
            firstFramePrompt: result['firstFramePrompt'] as String,
            videoPrompt: result['videoPrompt'] as String,
            duration: result['duration'] as int,
            assets: _storyboards[idx].assets,
            state: _storyboards[idx].state,
            createdAt: _storyboards[idx].createdAt,
            referenceImageUrl: _storyboards[idx].referenceImageUrl,
            referenceImageLocalPath: _storyboards[idx].referenceImageLocalPath,
            referenceImageUrls: _storyboards[idx].referenceImageUrls,
          );
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('分镜已更新')),
      );
    }
  }

  Widget _editField({
    required String label,
    required String value,
    bool readOnly = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          Text(value, style: const TextStyle(fontSize: 14)),
        ],
      ),
    );
  }

  Widget _editTextField({
    required String label,
    required TextEditingController controller,
    int maxLines = 1,
    TextInputType? keyboardType,
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          TextField(
            controller: controller,
            maxLines: maxLines,
            keyboardType: keyboardType,
            decoration: InputDecoration(
              hintText: hint,
              border: const OutlineInputBorder(),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _editDropdown({
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          DropdownButtonFormField<String>(
            value: value,
            items: items
                .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                .toList(),
            onChanged: onChanged,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.project.name),
        actions: [
          // Show "继续创建" button for incomplete projects
          if (!_imageReviewMode &&
              ['planning', 'scripting', 'asseting', 'storyboarding']
                  .contains(widget.project.state))
            FilledButton.icon(
              onPressed: () async {
                final result = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        CreateProjectScreen(resumeProject: widget.project),
                  ),
                );
                if (result == true && mounted) {
                  // Reload data after resuming
                  _loadData();
                }
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('继续创建'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
          // Image review mode: show progress
          if (_imageReviewMode && !_imageGenerating && _currentImageUrl != null)
            TextButton.icon(
              onPressed: _confirmImage,
              icon: const Icon(Icons.check),
              label: const Text('确认'),
              style: TextButton.styleFrom(foregroundColor: Colors.green),
            ),
          if (_imageReviewMode && !_imageGenerating && _currentImageUrl != null)
            TextButton.icon(
              onPressed: _retryCurrentImage,
              icon: const Icon(Icons.refresh),
              label: const Text('重新生成'),
              style: TextButton.styleFrom(foregroundColor: Colors.orange),
            ),
          // All images confirmed: offer video generation
          if (!_imageReviewMode &&
              widget.project.state == 'generating' &&
              _storyboards.isNotEmpty &&
              _videoClips.isEmpty)
            FilledButton.icon(
              onPressed: _generating ? null : _startImageGeneration,
              icon: _generating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.image),
              label: const Text('生成首帧图'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
          // After images confirmed, generate videos (API mode only — Seedance uses per-storyboard buttons)
          if (!_imageReviewMode &&
              widget.project.state == 'generating' &&
              _storyboards.isNotEmpty &&
              _videoClips.isEmpty &&
              _allImagesConfirmed &&
              !AppConfig.useSeedanceForVideo)
            FilledButton.icon(
              onPressed: _generating ? null : _startVideoGeneration,
              icon: _generating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.video_library),
              label: Text(_generating ? _genStatus : '生成视频'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
      body: _imageReviewMode
          ? _buildImageReviewPanel()
          : _generating
              ? Column(
                  children: [
                    const LinearProgressIndicator(),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_genStatus),
                    ),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.all(8),
                  children: [
                    // Brief section
                    if (_brief != null)
                      _buildSectionCard(
                        title: '策划',
                        icon: Icons.lightbulb,
                        color: Colors.orange,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _infoRow('类型', _brief!.genre ?? '-'),
                            _infoRow('时长', '${_brief!.duration ?? 0}秒'),
                            _infoRow('情绪', _brief!.mood ?? '-'),
                            _infoRow('故事', _brief!.storyOutline ?? '-'),
                          ],
                        ),
                      ),

                    // Assets section
                    if (_assets.isNotEmpty)
                      _buildSectionCard(
                        title: '资产 (${_assets.length})',
                        icon: Icons.people,
                        color: Colors.blue,
                        child: Column(
                          children: _assets.map((a) {
                            final typeLabel = a.type == 'character'
                                ? '角色'
                                : (a.type == 'prop' ? '道具' : '场景');
                            final fallbackIcon = a.type == 'character'
                                ? Icons.person
                                : (a.type == 'prop'
                                    ? Icons.inventory_2
                                    : Icons.location_on);

                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              child: ListTile(
                                leading: PersistentImageStore.preferredSource(
                                          localPath: a.referenceImageLocalPath,
                                          remoteUrl: a.referenceImageUrl,
                                        ) !=
                                        null
                                    ? ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: PersistentImage(
                                          remoteUrl: a.referenceImageUrl,
                                          localPath: a.referenceImageLocalPath,
                                          width: 48,
                                          height: 48,
                                          fit: BoxFit.cover,
                                          placeholder: CircleAvatar(
                                            child: Icon(fallbackIcon),
                                          ),
                                        ),
                                      )
                                    : CircleAvatar(
                                        child: Icon(fallbackIcon),
                                      ),
                                title: Text(a.name),
                                subtitle: Text(typeLabel),
                                trailing: Icon(
                                  PersistentImageStore.preferredSource(
                                            localPath:
                                                a.referenceImageLocalPath,
                                            remoteUrl: a.referenceImageUrl,
                                          ) !=
                                          null
                                      ? Icons.check_circle
                                      : Icons.image_not_supported,
                                  color: PersistentImageStore.preferredSource(
                                            localPath:
                                                a.referenceImageLocalPath,
                                            remoteUrl: a.referenceImageUrl,
                                          ) !=
                                          null
                                      ? Colors.green
                                      : Colors.grey,
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),

                    // Storyboards section
                    if (_storyboards.isNotEmpty)
                      _buildSectionCard(
                        title: '分镜 (${_storyboards.length})',
                        icon: Icons.view_carousel,
                        color: Colors.purple,
                        child: Column(
                          children: _storyboards.map((sb) {
                            final clip = _videoClips
                                .where(
                                  (c) => c.storyboardId == sb.id,
                                )
                                .firstOrNull;
                            final isConfirmed =
                                _confirmedImages.containsKey(sb.id);
                            final thumbUrl = isConfirmed
                                ? _confirmedImages[sb.id]
                                : PersistentImageStore.preferredSource(
                                    localPath: sb.referenceImageLocalPath,
                                    remoteUrl: sb.referenceImageUrl,
                                  );

                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 4),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    InkWell(
                                      onTap: () => _editStoryboard(sb),
                                      child: ListTile(
                                        leading: thumbUrl != null &&
                                                thumbUrl.isNotEmpty
                                            ? ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                                child: PersistentImage(
                                                  remoteUrl:
                                                      PersistentImageStore
                                                              .isLocalPath(
                                                                  thumbUrl)
                                                          ? null
                                                          : thumbUrl,
                                                  localPath: PersistentImageStore
                                                          .isLocalPath(thumbUrl)
                                                      ? thumbUrl
                                                      : sb.referenceImageLocalPath,
                                                  width: 40,
                                                  height: 40,
                                                  fit: BoxFit.cover,
                                                  placeholder: CircleAvatar(
                                                    backgroundColor:
                                                        Colors.green.shade100,
                                                    child: const Icon(
                                                        Icons.check,
                                                        color: Colors.green,
                                                        size: 18),
                                                  ),
                                                ),
                                              )
                                            : CircleAvatar(
                                                child: Text(
                                                    '${sb.sceneNum}-${sb.shotNum}'),
                                              ),
                                        title: Text(sb.description ?? ''),
                                        subtitle: Text(
                                          '${sb.shotType} | ${sb.cameraMove} | ${sb.duration ?? 5}s',
                                        ),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            _buildVideoStatus(clip),
                                            const SizedBox(width: 8),
                                            const Icon(Icons.edit,
                                                size: 18, color: Colors.grey),
                                          ],
                                        ),
                                      ),
                                    ),
                                    // Per-storyboard "生成视频" button
                                    if (!_imageReviewMode &&
                                        thumbUrl != null &&
                                        thumbUrl.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                            left: 72, right: 16),
                                        child: SizedBox(
                                          width: double.infinity,
                                          height: 32,
                                          child: FilledButton.icon(
                                            onPressed: clip != null &&
                                                    (clip.state ==
                                                            'completed' ||
                                                        clip.state == 'done')
                                                ? null
                                                : () => AppConfig
                                                        .useSeedanceForVideo
                                                    ? _generateVideoForStoryboard(
                                                        sb)
                                                    : _generateApiVideoForStoryboard(
                                                        sb),
                                            icon: Icon(
                                              clip != null &&
                                                      (clip.state ==
                                                              'completed' ||
                                                          clip.state == 'done')
                                                  ? Icons.check_circle
                                                  : Icons.videocam,
                                              size: 16,
                                            ),
                                            label: Text(
                                              clip != null &&
                                                      (clip.state ==
                                                              'completed' ||
                                                          clip.state == 'done')
                                                  ? '视频已生成'
                                                  : (clip != null
                                                      ? '重新生成视频'
                                                      : '生成视频'),
                                              style:
                                                  const TextStyle(fontSize: 12),
                                            ),
                                            style: FilledButton.styleFrom(
                                              visualDensity:
                                                  VisualDensity.compact,
                                              backgroundColor: clip != null &&
                                                      (clip.state ==
                                                              'completed' ||
                                                          clip.state == 'done')
                                                  ? Colors.green.shade700
                                                  : Colors.purple,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 8),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),

                    // Video clips
                    if (_videoClips.isNotEmpty)
                      _buildSectionCard(
                        title: '视频片段',
                        icon: Icons.video_library,
                        color: Colors.green,
                        child: Column(
                          children: _videoClips.map((clip) {
                            final sb = _storyboards
                                .where(
                                  (s) => s.id == clip.storyboardId,
                                )
                                .firstOrNull;
                            final thumbUrl =
                                PersistentImageStore.preferredSource(
                                      localPath: sb?.referenceImageLocalPath,
                                      remoteUrl: sb?.referenceImageUrl,
                                    ) ??
                                    '';

                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              child: InkWell(
                                onTap: (clip.state == 'completed' ||
                                            clip.state == 'done') &&
                                        clip.videoUrl != null
                                    ? () => _previewVideo(clip, sb)
                                    : null,
                                child: ListTile(
                                  leading: thumbUrl.isNotEmpty
                                      ? ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(4),
                                          child: PersistentImage(
                                            remoteUrl: PersistentImageStore
                                                    .isLocalPath(thumbUrl)
                                                ? null
                                                : thumbUrl,
                                            localPath: PersistentImageStore
                                                    .isLocalPath(thumbUrl)
                                                ? thumbUrl
                                                : sb?.referenceImageLocalPath,
                                            width: 48,
                                            height: 48,
                                            fit: BoxFit.cover,
                                            placeholder: _buildVideoStatusIcon(
                                                clip.state),
                                          ),
                                        )
                                      : _buildVideoStatusIcon(clip.state),
                                  title: Text(
                                    sb != null
                                        ? '镜头 ${sb.sceneNum}-${sb.shotNum}: ${sb.description ?? ''}'
                                        : '分镜: ${clip.storyboardId}',
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (clip.errorReason != null)
                                        Text(clip.errorReason!,
                                            style: const TextStyle(
                                                color: Colors.red)),
                                      if ((clip.state == 'completed' ||
                                              clip.state == 'done') &&
                                          clip.videoUrl != null)
                                        Text(
                                          '点击预览视频',
                                          style: const TextStyle(
                                            color: Colors.blue,
                                            fontSize: 12,
                                          ),
                                        ),
                                    ],
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _buildVideoStatus(clip),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),

                    // Retry buttons for failed clips
                    if (_videoClips.any((c) => c.state == 'failed'))
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _generating ? null : _retryFailedClips,
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试失败片段'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.orange,
                            side: const BorderSide(color: Colors.orange),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    if (_videoClips.any(
                        (c) => c.state == 'completed' || c.state == 'done'))
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _generating ? null : _regenerateAllClips,
                          icon: const Icon(Icons.auto_awesome),
                          label: const Text('重新生成全部'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.teal,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),

                    if (_storyboards.isEmpty)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text('暂无分镜数据',
                              style: TextStyle(color: Colors.grey)),
                        ),
                      ),
                  ],
                ),
    );
  }

  Widget _buildImageReviewPanel() {
    if (_currentImageIndex < 0 || _currentImageIndex >= _storyboards.length) {
      return const Center(child: Text('没有更多分镜需要生成'));
    }

    final sb = _storyboards[_currentImageIndex];
    final total = _storyboards.length;
    final current = _currentImageIndex + 1;

    return Column(
      children: [
        // Progress bar
        LinearProgressIndicator(
          value: current / total,
        ),
        // Status header
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.image, color: Colors.purple),
                  const SizedBox(width: 8),
                  Text(
                    '首帧图生成 ($current/$total)',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '镜头 ${sb.sceneNum}-${sb.shotNum}：${sb.description ?? ''}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              if (_retryFeedback[sb.id] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '修改要求：${_retryFeedback[sb.id]}',
                    style: const TextStyle(fontSize: 12, color: Colors.orange),
                  ),
                ),
            ],
          ),
        ),
        // Image display or loading indicator
        Expanded(
          child: _imageGenerating
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('正在生成中，请稍候...'),
                    ],
                  ),
                )
              : _currentImageUrl != null
                  ? Center(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            const SizedBox(height: 8),
                            Container(
                              constraints: const BoxConstraints(maxWidth: 512),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.grey.shade300),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: PersistentImage(
                                  remoteUrl: _currentImageUrl,
                                  localPath: _currentImageIndex >= 0 &&
                                          _currentImageIndex <
                                              _storyboards.length
                                      ? _storyboards[_currentImageIndex]
                                          .referenceImageLocalPath
                                      : null,
                                  fit: BoxFit.contain,
                                  placeholder: const Padding(
                                    padding: EdgeInsets.all(32),
                                    child: Column(
                                      children: [
                                        Icon(Icons.broken_image,
                                            size: 64, color: Colors.grey),
                                        SizedBox(height: 8),
                                        Text('图片加载失败'),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              '提示词：${sb.firstFramePrompt ?? sb.description ?? ''}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                                fontStyle: FontStyle.italic,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    )
                  // Generation failed and no image yet
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline,
                              size: 48, color: Colors.red),
                          const SizedBox(height: 16),
                          Text(
                            _genStatus,
                            style: const TextStyle(color: Colors.red),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: () {
                              setState(() {
                                _imageReviewMode = false;
                                _currentImageIndex = -1;
                                _currentImageUrl = null;
                                _imageGenerating = false;
                              });
                            },
                            icon: const Icon(Icons.arrow_back),
                            label: const Text('返回'),
                          ),
                        ],
                      ),
                    ),
        ),
        // Action buttons at bottom
        if (!_imageGenerating && _currentImageUrl != null)
          Container(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _retryCurrentImage,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新生成'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orange,
                    side: const BorderSide(color: Colors.orange),
                  ),
                ),
                const SizedBox(width: 16),
                FilledButton.icon(
                  onPressed: _confirmImage,
                  icon: const Icon(Icons.check),
                  label: const Text('确认并继续'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required Color color,
    required Widget child,
  }) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const Divider(),
            child,
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 50,
            child: Text(label, style: const TextStyle(color: Colors.grey)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _buildVideoStatus(VideoClip? clip) {
    if (clip == null) return const Text('未生成');
    return Text(
      (clip.state == 'completed' || clip.state == 'done')
          ? '已完成'
          : clip.state == 'failed'
              ? '失败'
              : '生成中',
      style: TextStyle(
        color: (clip.state == 'completed' || clip.state == 'done')
            ? Colors.green
            : clip.state == 'failed'
                ? Colors.red
                : Colors.orange,
      ),
    );
  }

  Widget _buildVideoStatusIcon(String state) {
    IconData icon;
    Color color;
    if (state == 'completed' || state == 'done') {
      icon = Icons.check_circle;
      color = Colors.green;
    } else if (state == 'failed') {
      icon = Icons.error;
      color = Colors.red;
    } else {
      icon = Icons.pending;
      color = Colors.orange;
    }
    return CircleAvatar(
      backgroundColor: color.withOpacity(0.1),
      child: Icon(icon, color: color, size: 18),
    );
  }

  /// Show video preview dialog with reference image and video URL
  /// Full-screen video preview using WebView2
  Future<void> _previewVideo(VideoClip clip, Storyboard? sb) async {
    if (clip.videoUrl == null) return;

    final title = sb != null ? '镜头 ${sb.sceneNum}-${sb.shotNum}' : '视频预览';

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPreviewScreen(
          videoUrl: clip.videoUrl!,
          title: title,
        ),
      ),
    );
  }
}

String _truncateText(String value, int maxLength) {
  if (value.length <= maxLength) return value;
  return value.substring(0, maxLength);
}
