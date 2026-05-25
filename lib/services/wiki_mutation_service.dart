import 'dart:convert';

import '../models/models.dart';
import 'app_logger.dart';
import 'llm_service.dart';
import 'project_wiki_store.dart';

class WikiMutationService {
  final ProjectWikiStore store;
  final LlmService llm;

  WikiMutationService({
    required this.store,
    required this.llm,
  });

  Future<void> initializeProject({
    required String projectId,
    required String creativeInput,
  }) =>
      store.initializeProject(
        projectId: projectId,
        creativeInput: creativeInput,
      );

  Future<void> updateOpenQuestions({
    required String projectId,
    required List<Map<String, Object?>> questions,
  }) =>
      store.updateOpenQuestions(projectId: projectId, questions: questions);

  Future<void> updateUserAnswers({
    required String projectId,
    required String guidanceText,
  }) async {
    await store.updateUserAnswers(
      projectId: projectId,
      guidanceText: guidanceText,
    );
    await _grow(
      projectId: projectId,
      stage: 'constraints',
      mutationType: 'user_answers',
      payload: {'guidance': guidanceText},
    );
  }

  Future<void> updateBrief({
    required String projectId,
    required Map<String, dynamic> brief,
  }) async {
    await store.updateBrief(projectId: projectId, brief: brief);
    await _grow(
      projectId: projectId,
      stage: 'planning',
      mutationType: 'brief',
      payload: brief,
    );
  }

  Future<void> updateScript({
    required String projectId,
    required Map<String, dynamic> scriptData,
  }) async {
    await store.updateScript(projectId: projectId, scriptData: scriptData);
    await _grow(
      projectId: projectId,
      stage: 'scripting',
      mutationType: 'script',
      payload: scriptData,
    );
  }

  Future<void> updateAssets({
    required String projectId,
    required List assets,
  }) async {
    await store.updateAssets(projectId: projectId, assets: assets);
    await _grow(
      projectId: projectId,
      stage: 'asseting',
      mutationType: 'assets',
      payload: {'assets': assets.map(_toJsonSafe).toList()},
    );
  }

  Future<void> updateStoryboards({
    required String projectId,
    required List storyboards,
  }) async {
    await store.updateStoryboards(
        projectId: projectId, storyboards: storyboards);
    await _grow(
      projectId: projectId,
      stage: 'storyboarding',
      mutationType: 'storyboards',
      payload: {'storyboards': storyboards.map(_toJsonSafe).toList()},
    );
  }

  Future<void> updateVideoClips({
    required String projectId,
    required Map<String, dynamic> videoData,
  }) async {
    await store.updateVideoClips(projectId: projectId, videoData: videoData);
    await _grow(
      projectId: projectId,
      stage: 'generating',
      mutationType: 'video_clips',
      payload: videoData,
    );
  }

  Future<String?> persistVideoFile({
    required String projectId,
    required String videoUrl,
    String? storyboardId,
  }) =>
      store.persistVideoFile(
        projectId: projectId,
        videoUrl: videoUrl,
        storyboardId: storyboardId,
      );

  Future<String> compileContextPack(
    String projectId, {
    required String stage,
  }) =>
      store.compileContextPack(projectId, stage: stage);

  Future<void> appendLog(
    String projectId,
    String message, {
    Map<String, Object?>? data,
  }) =>
      store.appendLog(projectId, message, data: data);

  Future<void> _grow({
    required String projectId,
    required String stage,
    required String mutationType,
    required Object? payload,
  }) async {
    try {
      final existingKnowledge =
          await store.readWikiFile(projectId, 'knowledge.md');
      final context = await store.compileContextPack(projectId, stage: stage);
      final payloadText = _truncate(_prettyJson(payload), 8000);
      final contextText = _truncate(context, 12000);

      final response = await llm.chatCompletion(
        requestTag: 'wiki.grow.$mutationType',
        jsonMode: true,
        temperature: 0.2,
        messages: [
          ChatMessage(
            role: 'system',
            content: '''
你是 Storyforge 的 WikiMutationService。你的职责是把阶段产物提炼为长期项目知识，而不是复述全部内容。

要求：
1. 只保留后续生成有用的稳定信息：角色设定、场景地理、道具、剧情约束、镜头连续性、用户确认、已生成结果。
2. 去重：已有知识中已经表达过的内容不要重复写。
3. 归档：过时、被替代、太细的中间过程写入 archive_notes，不要放入长期知识。
4. 不要发明新剧情，不要修正用户没有确认的内容。
5. 输出严格 JSON。

JSON 结构：
{
  "canon": ["长期事实"],
  "characters": ["角色稳定设定"],
  "locations": ["场景稳定设定"],
  "props": ["道具稳定设定"],
  "continuity": ["跨镜头/跨阶段连续性规则"],
  "open_questions": ["仍需用户确认的问题"],
  "decisions": ["本次新增或更新的决策"],
  "archive_notes": ["可归档的中间信息或被替代信息"]
}
''',
          ),
          ChatMessage(
            role: 'user',
            content: '''
项目 ID：$projectId
阶段：$stage
变更类型：$mutationType

【现有 Living Knowledge】
${_truncate(existingKnowledge, 10000)}

【当前阶段上下文】
$contextText

【本次变更 payload】
$payloadText
''',
          ),
        ],
      );

      final decoded = jsonDecode(response.content);
      final summary = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
      await _writeLivingKnowledge(
        projectId: projectId,
        mutationType: mutationType,
        existingKnowledge: existingKnowledge,
        summary: summary,
      );
      await store.appendLog(projectId, 'WikiMutationService grew knowledge',
          data: {'mutationType': mutationType, 'stage': stage});
    } catch (e, st) {
      await AppLogger.warn(
        'WikiMutationService growth failed; base wiki update preserved',
        data: {
          'projectId': projectId,
          'stage': stage,
          'mutationType': mutationType,
        },
        error: e,
        stackTrace: st,
      );
      await store.appendLog(
        projectId,
        'WikiMutationService growth failed; base wiki update preserved',
        data: {'mutationType': mutationType, 'error': e.toString()},
      );
    }
  }

  Future<void> _writeLivingKnowledge({
    required String projectId,
    required String mutationType,
    required String existingKnowledge,
    required Map<String, dynamic> summary,
  }) async {
    final archiveNotes = _stringList(summary['archive_notes']);
    final archiveFile = archiveNotes.isEmpty
        ? ''
        : 'wiki_growth_${DateTime.now().millisecondsSinceEpoch}_$mutationType.md';
    if (archiveNotes.isNotEmpty) {
      await store.writeArchiveFile(
        projectId,
        archiveFile,
        '# Archived Notes\n\n${archiveNotes.map((e) => '- $e').join('\n')}\n',
      );
    }

    final merged = _mergeKnowledge(existingKnowledge, summary, archiveFile);
    await store.writeWikiFile(projectId, 'knowledge.md', merged);
  }

  String _mergeKnowledge(
    String existing,
    Map<String, dynamic> summary,
    String archiveFile,
  ) {
    final projectId = _extractProjectId(existing);
    final sections = {
      'Canon': _stringList(summary['canon']),
      'Characters': _stringList(summary['characters']),
      'Locations': _stringList(summary['locations']),
      'Props': _stringList(summary['props']),
      'Continuity': _stringList(summary['continuity']),
      'Open Questions': _stringList(summary['open_questions']),
      'Decisions': _stringList(summary['decisions']),
      'Archive Index':
          archiveFile.isEmpty ? <String>[] : ['../archive/$archiveFile'],
    };

    final buffer = StringBuffer()
      ..write(store.frontMatterFor('knowledge', projectId))
      ..writeln('# Living Knowledge')
      ..writeln()
      ..writeln('This page is maintained by WikiMutationService.')
      ..writeln();

    for (final entry in sections.entries) {
      final existingItems = _extractBullets(existing, entry.key);
      final mergedItems = _dedupe([...existingItems, ...entry.value]);
      buffer
        ..writeln('## ${entry.key}')
        ..writeln();
      for (final item in mergedItems) {
        buffer.writeln('- $item');
      }
      buffer.writeln();
    }
    return buffer.toString();
  }

  List<String> _extractBullets(String markdown, String section) {
    final marker = '## $section';
    final start = markdown.indexOf(marker);
    if (start == -1) return const [];
    final next = markdown.indexOf('\n## ', start + marker.length);
    final block = markdown.substring(
      start + marker.length,
      next == -1 ? markdown.length : next,
    );
    return block
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.startsWith('- '))
        .map((line) => line.substring(2).trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  List<String> _stringList(dynamic value) {
    if (value is List) {
      return value
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    if (value is String && value.trim().isNotEmpty) return [value.trim()];
    return const [];
  }

  List<String> _dedupe(List<String> items) {
    final seen = <String>{};
    final result = <String>[];
    for (final item in items) {
      final key = item
          .toLowerCase()
          .replaceAll(RegExp(r'\s+'), '')
          .replaceAll(RegExp(r'[，。,.；;：:]'), '');
      if (key.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      result.add(item);
    }
    return result;
  }

  String _extractProjectId(String existing) {
    final match = RegExp(r'project_id:\s*(.+)').firstMatch(existing);
    return match?.group(1)?.trim() ?? 'unknown';
  }

  String _prettyJson(Object? value) =>
      const JsonEncoder.withIndent('  ').convert(_toJsonSafe(value));

  Object? _toJsonSafe(Object? value) {
    if (value is Asset) return value.toMap();
    if (value is Storyboard) return value.toMap();
    if (value is Scene) return value.toMap();
    if (value is VideoClip) return value.toMap();
    if (value is Map) {
      return value
          .map((key, val) => MapEntry(key.toString(), _toJsonSafe(val)));
    }
    if (value is Iterable) return value.map(_toJsonSafe).toList();
    return value;
  }

  String _truncate(String value, int maxLength) =>
      value.length <= maxLength ? value : value.substring(0, maxLength);
}
