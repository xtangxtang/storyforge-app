import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/models.dart';

class ProjectWikiStore {
  static const _schemaVersion = 'storyforge-wiki-v1';

  Future<Directory> projectDirectory(String projectId) async {
    final root = _resolveWritableRoot();
    final dir = Directory(p.join(root, 'Storyforge', 'projects', projectId));
    await dir.create(recursive: true);
    return dir;
  }

  String _resolveWritableRoot() {
    if (Platform.isWindows) {
      return Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    }
    return Platform.environment['HOME'] ?? Directory.systemTemp.path;
  }

  Future<void> initializeProject({
    required String projectId,
    required String creativeInput,
  }) async {
    final dir = await projectDirectory(projectId);
    for (final child in [
      'raw',
      'wiki',
      p.join('outputs', 'images'),
      p.join('outputs', 'videos'),
    ]) {
      await Directory(p.join(dir.path, child)).create(recursive: true);
    }

    await _writeIfAbsent(
      p.join(dir.path, 'raw', 'creative_input.md'),
      '# Creative Input\n\n$creativeInput\n',
    );
    await _writeIfAbsent(
      p.join(dir.path, 'raw', 'user_answers.md'),
      '# User Answers\n\n',
    );
    await _writeIfAbsent(
      p.join(dir.path, 'wiki', 'index.md'),
      _frontMatter('index', projectId) +
          '''
# Project Wiki

- [Raw Creative Input](../raw/creative_input.md)
- [User Answers](../raw/user_answers.md)
- [Open Questions](open_questions.md)
- [Constraints](constraints.md)
- [Story Bible](story_bible.md)
- [Brief](brief.md)
- [Script](script.md)
- [Asset Manifest](asset_manifest.md)
- [Storyboards](storyboards.md)
- [Video Prompt Pack](video_prompt_pack.md)
- [Decisions](decisions.md)
- [Log](log.md)
''',
    );
    await _writeIfAbsent(
      p.join(dir.path, 'wiki', 'open_questions.md'),
      _frontMatter('open_questions', projectId) + '# Open Questions\n\n',
    );
    await _writeIfAbsent(
      p.join(dir.path, 'wiki', 'constraints.md'),
      _frontMatter('constraints', projectId) + '# Constraints\n\n',
    );
    await _writeIfAbsent(
      p.join(dir.path, 'wiki', 'story_bible.md'),
      _frontMatter('story_bible', projectId) + '# Story Bible\n\n',
    );
    await _writeIfAbsent(
      p.join(dir.path, 'wiki', 'decisions.md'),
      _frontMatter('decisions', projectId) + '# Decisions\n\n',
    );
    await _writeIfAbsent(
      p.join(dir.path, 'wiki', 'log.md'),
      _frontMatter('log', projectId) + '# Log\n\n',
    );

    await appendLog(projectId, 'Initialized project wiki');
  }

  Future<void> updateOpenQuestions({
    required String projectId,
    required List<Map<String, Object?>> questions,
  }) async {
    final buffer = StringBuffer()
      ..write(_frontMatter('open_questions', projectId))
      ..writeln('# Open Questions')
      ..writeln()
      ..writeln(
          'These questions are generated before planning. They identify missing user-owned creative choices; agents must not invent these answers.')
      ..writeln();

    if (questions.isEmpty) {
      buffer.writeln('No blocking questions detected.');
    } else {
      for (var i = 0; i < questions.length; i++) {
        final q = questions[i];
        buffer
          ..writeln('## ${i + 1}. ${q['title'] ?? 'Question'}')
          ..writeln()
          ..writeln('- id: `${q['id'] ?? 'question_$i'}`')
          ..writeln('- required: ${q['required'] ?? true}')
          ..writeln('- question: ${q['question'] ?? ''}')
          ..writeln('- hint: ${q['hint'] ?? ''}')
          ..writeln('- answer: pending')
          ..writeln();
      }
    }

    await _writeWiki(projectId, 'open_questions.md', buffer.toString());
    await appendLog(projectId, 'Updated open questions', data: {
      'questionCount': questions.length,
    });
  }

  Future<void> updateUserAnswers({
    required String projectId,
    required String guidanceText,
  }) async {
    await _writeRaw(
      projectId,
      'user_answers.md',
      '# User Answers\n\n$guidanceText\n',
    );
    await _writeWiki(
      projectId,
      'constraints.md',
      _frontMatter('constraints', projectId) +
          '''
# Constraints

These user-confirmed constraints must be preserved across planning, scripting, asset design, storyboarding, and video generation.

$guidanceText
''',
    );
    await _mergeStoryBible(
      projectId,
      sectionTitle: 'User-Confirmed Constraints',
      content: guidanceText,
    );
    await appendLog(projectId, 'Updated user-confirmed constraints');
  }

  Future<void> updateBrief({
    required String projectId,
    required Map<String, dynamic> brief,
  }) async {
    final content = '''
# Brief

- genre: ${brief['genre'] ?? ''}
- duration: ${brief['duration'] ?? ''} seconds
- aspect_ratio: ${brief['aspect_ratio'] ?? ''}
- mood: ${brief['mood'] ?? ''}
- visual_style: ${brief['visual_style'] ?? ''}

## Story Outline

${brief['story_outline'] ?? ''}
''';
    await _writeWiki(
        projectId, 'brief.md', _frontMatter('brief', projectId) + content);
    await _mergeStoryBible(
      projectId,
      sectionTitle: 'Brief',
      content: content,
    );
    await appendLog(projectId, 'Updated brief');
  }

  Future<void> updateScript({
    required String projectId,
    required Map<String, dynamic> scriptData,
  }) async {
    final buffer = StringBuffer()
      ..write(_frontMatter('script', projectId))
      ..writeln('# Script')
      ..writeln();

    final scenes = scriptData['scenes'] as List? ?? const [];
    if (scenes.isNotEmpty) {
      buffer.writeln('## Scenes\n');
      for (final scene in scenes) {
        final map = _toMap(scene);
        if (map == null) continue;
        buffer
          ..writeln(
              '### Scene ${map['scene_num'] ?? ''}: ${map['location'] ?? ''}')
          ..writeln()
          ..writeln('- duration: ${map['duration'] ?? ''} seconds')
          ..writeln('- description: ${map['description'] ?? ''}')
          ..writeln('- action: ${map['action'] ?? ''}')
          ..writeln('- dialogue: ${_formatDialogue(map['dialogue'])}')
          ..writeln();
      }
    }

    final assets = scriptData['assets'] as List? ?? const [];
    if (assets.isNotEmpty) {
      buffer.writeln('## Extracted Assets\n');
      for (final asset in assets) {
        final map = _toMap(asset);
        if (map == null) continue;
        buffer
          ..writeln('- ${map['type'] ?? ''}: ${map['name'] ?? ''}')
          ..writeln('  - description: ${map['description'] ?? ''}')
          ..writeln();
      }
    }

    await _writeWiki(projectId, 'script.md', buffer.toString());
    await _mergeStoryBible(
      projectId,
      sectionTitle: 'Script Summary',
      content: buffer.toString(),
    );
    await appendLog(projectId, 'Updated script', data: {
      'sceneCount': scenes.length,
      'assetCount': assets.length,
    });
  }

  Future<void> updateAssets({
    required String projectId,
    required List assets,
  }) async {
    final buffer = StringBuffer()
      ..write(_frontMatter('asset_manifest', projectId))
      ..writeln('# Asset Manifest')
      ..writeln()
      ..writeln(
          'These are canonical visual anchors for downstream storyboards and video generation.')
      ..writeln();

    for (final asset in assets) {
      final map = _toMap(asset);
      if (map == null) continue;
      buffer
        ..writeln('## ${map['name'] ?? ''}')
        ..writeln()
        ..writeln('- type: ${map['type'] ?? ''}')
        ..writeln('- description: ${map['description'] ?? ''}')
        ..writeln('- prompt: ${map['prompt'] ?? ''}')
        ..writeln('- reference_image_url: ${map['reference_image_url'] ?? ''}')
        ..writeln(
            '- reference_image_local_path: ${map['reference_image_local_path'] ?? ''}')
        ..writeln();
    }

    await _writeWiki(projectId, 'asset_manifest.md', buffer.toString());
    await _mergeStoryBible(
      projectId,
      sectionTitle: 'Visual Anchors',
      content: buffer.toString(),
    );
    await appendLog(projectId, 'Updated asset manifest', data: {
      'assetCount': assets.length,
    });
  }

  Future<void> updateStoryboards({
    required String projectId,
    required List storyboards,
  }) async {
    final buffer = StringBuffer()
      ..write(_frontMatter('storyboards', projectId))
      ..writeln('# Storyboards')
      ..writeln();

    for (final sb in storyboards) {
      final map = _toMap(sb);
      if (map == null) continue;
      buffer
        ..writeln(
            '## Scene ${map['scene_num'] ?? ''} Shot ${map['shot_num'] ?? ''}')
        ..writeln()
        ..writeln('- shot_type: ${map['shot_type'] ?? ''}')
        ..writeln('- camera_move: ${map['camera_move'] ?? ''}')
        ..writeln('- duration: ${map['duration'] ?? ''} seconds')
        ..writeln('- description: ${map['description'] ?? ''}')
        ..writeln()
        ..writeln('### First Frame Prompt')
        ..writeln(map['first_frame_prompt'] ?? '')
        ..writeln()
        ..writeln('### Video Prompt')
        ..writeln(map['video_prompt'] ?? '')
        ..writeln();
    }

    await _writeWiki(projectId, 'storyboards.md', buffer.toString());
    await _writeWiki(
      projectId,
      'video_prompt_pack.md',
      buffer.toString().replaceFirst('# Storyboards', '# Video Prompt Pack'),
    );
    await appendLog(projectId, 'Updated storyboards', data: {
      'storyboardCount': storyboards.length,
    });
  }

  Future<void> updateVideoClips({
    required String projectId,
    required Map<String, dynamic> videoData,
  }) async {
    final clips = videoData['clips'] as List? ?? const [];
    final buffer = StringBuffer()
      ..write(_frontMatter('video_results', projectId))
      ..writeln('# Video Results')
      ..writeln()
      ..writeln('- total: ${videoData['total'] ?? clips.length}')
      ..writeln('- success: ${videoData['success'] ?? ''}')
      ..writeln('- failed: ${videoData['failed'] ?? ''}')
      ..writeln();

    for (final clip in clips) {
      final map = _toMap(clip);
      if (map == null) continue;
      buffer
        ..writeln('## Clip ${map['storyboard_id'] ?? map['id'] ?? ''}')
        ..writeln()
        ..writeln('- state: ${map['state'] ?? ''}')
        ..writeln('- video_url: ${map['video_url'] ?? ''}')
        ..writeln('- local_path: ${map['local_path'] ?? ''}')
        ..writeln('- error_reason: ${map['error_reason'] ?? ''}')
        ..writeln();
    }

    await _writeWiki(projectId, 'video_results.md', buffer.toString());
    await appendLog(projectId, 'Updated video results', data: {
      'clipCount': clips.length,
    });
  }

  Future<String> compileContextPack(
    String projectId, {
    required String stage,
  }) async {
    final files = switch (stage) {
      'planning' => [
          p.join('raw', 'creative_input.md'),
          p.join('raw', 'user_answers.md'),
          p.join('wiki', 'constraints.md'),
          p.join('wiki', 'story_bible.md'),
        ],
      'scripting' => [
          p.join('raw', 'creative_input.md'),
          p.join('wiki', 'constraints.md'),
          p.join('wiki', 'story_bible.md'),
          p.join('wiki', 'brief.md'),
        ],
      'asseting' => [
          p.join('wiki', 'constraints.md'),
          p.join('wiki', 'story_bible.md'),
          p.join('wiki', 'script.md'),
        ],
      'storyboarding' => [
          p.join('wiki', 'constraints.md'),
          p.join('wiki', 'story_bible.md'),
          p.join('wiki', 'script.md'),
          p.join('wiki', 'asset_manifest.md'),
        ],
      'generating' => [
          p.join('wiki', 'constraints.md'),
          p.join('wiki', 'story_bible.md'),
          p.join('wiki', 'asset_manifest.md'),
          p.join('wiki', 'video_prompt_pack.md'),
        ],
      _ => [
          p.join('wiki', 'constraints.md'),
          p.join('wiki', 'story_bible.md'),
        ],
    };

    final dir = await projectDirectory(projectId);
    final buffer = StringBuffer()
      ..writeln('# Compiled Project Wiki Context')
      ..writeln()
      ..writeln('stage: $stage')
      ..writeln();

    for (final relativePath in files) {
      final file = File(p.join(dir.path, relativePath));
      if (!await file.exists()) continue;
      final content = await file.readAsString();
      if (content.trim().isEmpty) continue;
      buffer
        ..writeln('---')
        ..writeln('source: $relativePath')
        ..writeln()
        ..writeln(content.trim())
        ..writeln();
    }
    return buffer.toString();
  }

  Future<void> appendLog(
    String projectId,
    String message, {
    Map<String, Object?>? data,
  }) async {
    final dir = await projectDirectory(projectId);
    final file = File(p.join(dir.path, 'wiki', 'log.md'));
    await file.parent.create(recursive: true);
    final buffer = StringBuffer()
      ..writeln('## ${DateTime.now().toIso8601String()}')
      ..writeln()
      ..writeln(message);
    if (data != null && data.isNotEmpty) {
      buffer.writeln();
      for (final entry in data.entries) {
        buffer.writeln('- ${entry.key}: ${entry.value}');
      }
    }
    buffer.writeln();
    await file.writeAsString(buffer.toString(), mode: FileMode.append);
  }

  Future<void> _mergeStoryBible(
    String projectId, {
    required String sectionTitle,
    required String content,
  }) async {
    final dir = await projectDirectory(projectId);
    final file = File(p.join(dir.path, 'wiki', 'story_bible.md'));
    final existing = await file.exists() ? await file.readAsString() : '';
    final marker = '## $sectionTitle';
    final nextSection = '$marker\n\n${content.trim()}\n';
    final updated = _replaceSection(existing, marker, nextSection);
    await file.writeAsString(updated);
  }

  String _replaceSection(String existing, String marker, String replacement) {
    if (!existing.contains(marker)) {
      final prefix = existing.trim().isEmpty
          ? _frontMatter('story_bible', 'unknown') + '# Story Bible\n'
          : existing.trimRight();
      return '$prefix\n\n$replacement\n';
    }

    final start = existing.indexOf(marker);
    final nextStart = existing.indexOf('\n## ', start + marker.length);
    if (nextStart == -1) {
      return '${existing.substring(0, start).trimRight()}\n\n$replacement\n';
    }
    return '${existing.substring(0, start).trimRight()}\n\n$replacement\n${existing.substring(nextStart).trimLeft()}';
  }

  Future<void> _writeRaw(
    String projectId,
    String filename,
    String content,
  ) async {
    final dir = await projectDirectory(projectId);
    final file = File(p.join(dir.path, 'raw', filename));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  Future<void> _writeWiki(
    String projectId,
    String filename,
    String content,
  ) async {
    final dir = await projectDirectory(projectId);
    final file = File(p.join(dir.path, 'wiki', filename));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  Future<void> _writeIfAbsent(String filePath, String content) async {
    final file = File(filePath);
    await file.parent.create(recursive: true);
    if (await file.exists()) return;
    await file.writeAsString(content);
  }

  String _frontMatter(String page, String projectId) => '''
---
schema: $_schemaVersion
project_id: $projectId
page: $page
updated_at: ${DateTime.now().toIso8601String()}
---

''';

  String _formatDialogue(dynamic dialogue) {
    if (dialogue is List) {
      return dialogue.map((e) => e.toString()).join(' / ');
    }
    return dialogue?.toString() ?? '';
  }

  Map<String, dynamic>? _toMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is Scene) return value.toMap();
    if (value is Asset) return value.toMap();
    if (value is Storyboard) return value.toMap();
    if (value is VideoClip) return value.toMap();
    if (value == null) return null;
    try {
      final decoded = jsonDecode(jsonEncode(value));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
    return null;
  }
}
