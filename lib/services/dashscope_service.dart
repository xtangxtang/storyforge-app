import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';

class DashscopeService {
  final http.Client _client;

  DashscopeService({http.Client? client}) : _client = client ?? http.Client();

  /// Generate image via wan2.7-image model
  /// Uses multimodal-generation endpoint
  /// Prompt should be in Chinese for best results
  Future<String> generateImage(String prompt) async {
    final baseUrl = AppConfig.dashscopeBaseUrl;
    final apiKey = AppConfig.dashscopeApiKey;

    if (apiKey.isEmpty) {
      throw Exception(
        'DashScope API key not configured. Go to Settings to add it.',
      );
    }

    final uri = Uri.parse(
      '$baseUrl/api/v1/services/aigc/multimodal-generation/generation',
    );
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
      'X-DashScope-Async': 'enable',
    };
    final body = jsonEncode({
      'model': 'wan2.7-image',
      'input': {
        'messages': [
          {
            'role': 'user',
            'content': [
              {'text': prompt},
            ],
          },
        ],
      },
      'parameters': {
        'size': '1024*1024',
        'n': 1,
      },
    });

    final response = await _client
        .post(uri, headers: headers, body: body)
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception('Image generation failed: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    // Check if it's async (has task_id)
    final taskId = data['output']?['task_id'] as String?;
    if (taskId != null) {
      return _pollImageTask(taskId);
    }

    // Sync response
    final choices = data['output']?['choices'] as List?;
    if (choices != null && choices.isNotEmpty) {
      final content = choices[0]['message']['content'] as List?;
      if (content != null && content.isNotEmpty) {
        return content[0]['image'] as String;
      }
    }

    throw Exception('No image URL in response');
  }

  Future<String> _pollImageTask(String taskId) async {
    final baseUrl = AppConfig.dashscopeBaseUrl;
    final apiKey = AppConfig.dashscopeApiKey;

    for (int i = 0; i < 120; i++) {
      await Future.delayed(const Duration(seconds: 5));
      final uri = Uri.parse('$baseUrl/api/v1/tasks/$taskId');
      final headers = {
        'Authorization': 'Bearer $apiKey',
      };
      final response = await _client.get(uri, headers: headers);
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final status = data['output']?['task_status'] as String?;

      if (status == 'SUCCEEDED') {
        final results = data['output']?['results'] as List?;
        if (results != null && results.isNotEmpty) {
          return results[0]['url'] as String;
        }
        // Fallback: check choices
        final choices = data['output']?['choices'] as List?;
        if (choices != null && choices.isNotEmpty) {
          final content = choices[0]['message']['content'] as List?;
          if (content != null && content.isNotEmpty) {
            return content[0]['image'] as String;
          }
        }
        throw Exception('No image URL in task result');
      } else if (status == 'FAILED') {
        final message =
            data['output']?['message'] as String? ?? 'Task failed';
        throw Exception('Image generation failed: $message');
      }
    }

    throw Exception('Image generation timeout');
  }

  /// Generate video via wan2.7-i2v (image-to-video)
  /// Prompt should be in Chinese describing motion/camera
  /// Returns a video URL
  Future<String> generateVideo({
    required String prompt,
    required String firstFrameUrl,
    int duration = 5,
  }) async {
    final baseUrl = AppConfig.dashscopeBaseUrl;
    final apiKey = AppConfig.dashscopeApiKey;

    if (apiKey.isEmpty) {
      throw Exception(
        'DashScope API key not configured. Go to Settings to add it.',
      );
    }

    final uri = Uri.parse(
      '$baseUrl/api/v1/services/aigc/video-generation/video-synthesis',
    );
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
      'X-DashScope-Async': 'enable',
    };
    final body = jsonEncode({
      'model': 'wan2.7-i2v',
      'input': {
        'prompt': prompt,
        'media_url': firstFrameUrl,
      },
      'parameters': {
        'resolution': '720P',
        'duration': duration,
        'prompt_extend': true,
      },
    });

    final response = await _client
        .post(uri, headers: headers, body: body)
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception('Video generation failed: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final taskId = data['output']?['task_id'] as String?;
    if (taskId == null) {
      throw Exception('No task_id returned from video generation');
    }

    return _pollVideoTask(taskId);
  }

  Future<String> _pollVideoTask(String taskId) async {
    final baseUrl = AppConfig.dashscopeBaseUrl;
    final apiKey = AppConfig.dashscopeApiKey;

    for (int i = 0; i < 120; i++) {
      await Future.delayed(const Duration(seconds: 5));
      final uri = Uri.parse('$baseUrl/api/v1/tasks/$taskId');
      final headers = {
        'Authorization': 'Bearer $apiKey',
      };
      final response = await _client.get(uri, headers: headers);
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final status = data['output']?['task_status'] as String?;

      if (status == 'SUCCEEDED') {
        final videoUrl = data['output']?['video_url'] as String?;
        if (videoUrl != null && videoUrl.isNotEmpty) {
          return videoUrl;
        }
        final results = data['output']?['results'] as List?;
        if (results != null && results.isNotEmpty) {
          return results[0]['url'] as String;
        }
        throw Exception('No video URL in task result');
      } else if (status == 'FAILED') {
        final message =
            data['output']?['message'] as String? ?? 'Task failed';
        throw Exception('Video generation failed: $message');
      }
      // PENDING or RUNNING, continue polling
    }

    throw Exception('Video generation timeout (10 min)');
  }

  void dispose() => _client.close();
}
