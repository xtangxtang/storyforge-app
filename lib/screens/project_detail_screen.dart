import 'package:flutter/material.dart';
import '../db/dao/dao.dart';
import '../models/models.dart';
import '../services/dashscope_service.dart';

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

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final pid = widget.project.id;
    final brief = await BriefDao().getByProjectId(pid);
    final assets = await AssetDao().getByProjectId(pid);
    final storyboards = await StoryboardDao().getByProjectId(pid);
    final clips = await VideoClipDao().getByProjectId(pid);

    setState(() {
      _brief = brief;
      _assets = assets;
      _storyboards = storyboards;
      _videoClips = clips;
      _loading = false;
    });
  }

  Future<void> _generateVideos() async {
    if (_storyboards.isEmpty) return;

    setState(() {
      _generating = true;
      _genStatus = '正在生成视频...';
    });

    try {
      final dashscope = DashscopeService();

      for (final sb in _storyboards) {
        if (!mounted) return;

        final clipId = 'clip_${DateTime.now().millisecondsSinceEpoch.toString().substring(6)}';
        final clip = VideoClip(
          id: clipId,
          projectId: widget.project.id,
          storyboardId: sb.id,
          state: 'generating',
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
        await VideoClipDao().insert(clip);

        setState(() => _genStatus = '正在生成 ${sb.description?.substring(0, 10) ?? '...'} 的首帧图...');

        try {
          // Generate image
          final imagePrompt = sb.firstFramePrompt ?? sb.description ?? '';
          final imageUrl = await dashscope.generateImage(imagePrompt);

          setState(() => _genStatus = '正在生成视频...');

          // Generate video
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.project.name),
        actions: [
          if (widget.project.state == 'generating' &&
              _storyboards.isNotEmpty &&
              _videoClips.isEmpty)
            FilledButton.icon(
              onPressed: _generating ? null : _generateVideos,
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
      body: _generating
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
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _assets
                          .map((a) => Chip(
                                label: Text(a.name),
                                avatar: Icon(
                                  a.type == 'character'
                                      ? Icons.person
                                      : Icons.location_on,
                                ),
                              ))
                          .toList(),
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
                        final clip = _videoClips.where(
                          (c) => c.storyboardId == sb.id,
                        ).firstOrNull;

                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: ListTile(
                            leading: CircleAvatar(
                              child: Text('${sb.sceneNum}-${sb.shotNum}'),
                            ),
                            title: Text(sb.description ?? ''),
                            subtitle: Text(
                              '${sb.shotType} | ${sb.cameraMove} | ${sb.duration ?? 5}s',
                            ),
                            trailing: _buildVideoStatus(clip),
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
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: ListTile(
                            leading: Icon(
                              clip.state == 'completed'
                                  ? Icons.check_circle
                                  : clip.state == 'failed'
                                      ? Icons.error
                                      : Icons.pending,
                              color: clip.state == 'completed'
                                  ? Colors.green
                                  : clip.state == 'failed'
                                      ? Colors.red
                                      : Colors.orange,
                            ),
                            title: Text('分镜: ${clip.storyboardId}'),
                            subtitle: clip.errorReason != null
                                ? Text(clip.errorReason!,
                                    style: const TextStyle(color: Colors.red))
                                : null,
                          ),
                        );
                      }).toList(),
                    ),
                  ),

                if (_storyboards.isEmpty)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('暂无分镜数据', style: TextStyle(color: Colors.grey)),
                    ),
                  ),
              ],
            ),
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
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
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
      clip.state == 'completed' ? '已完成' : clip.state == 'failed' ? '失败' : '生成中',
      style: TextStyle(
        color: clip.state == 'completed'
            ? Colors.green
            : clip.state == 'failed'
                ? Colors.red
                : Colors.orange,
      ),
    );
  }
}
