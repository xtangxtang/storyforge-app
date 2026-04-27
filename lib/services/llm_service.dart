import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import 'app_logger.dart';
import 'http_client_factory.dart';

class ChatMessage {
  final String role;
  final String content;

  ChatMessage({required this.role, required this.content});

  Map<String, dynamic> toMap() => {'role': role, 'content': content};
}

class LlmResponse {
  final String content;
  final Map<String, dynamic>? usage;

  LlmResponse({required this.content, this.usage});
}

class LlmService {
  final http.Client _client;

  LlmService({http.Client? client}) : _client = client ?? createConfiguredHttpClient();

  Future<LlmResponse> chatCompletion({
    required List<ChatMessage> messages,
    String? model,
    double temperature = 0.7,
    bool jsonMode = false,
    String? requestTag,
  }) async {
    final baseUrl = AppConfig.llmBaseUrl;
    final apiKey = AppConfig.llmApiKey;
    final modelName = model ?? AppConfig.llmModel;

    if (apiKey.isEmpty) {
      throw Exception('LLM API key not configured. Go to Settings to add it.');
    }

    var processedMessages = messages;
    Map<String, dynamic>? responseFormat;
    if (jsonMode) {
      responseFormat = {'type': 'json_object'};
      final systemIdx = processedMessages.indexWhere((m) => m.role == 'system');
      if (systemIdx >= 0) {
        if (!processedMessages[systemIdx].content.toLowerCase().contains('json')) {
          processedMessages = [
            ChatMessage(
              role: 'system',
              content: '${processedMessages[systemIdx].content}\n\n必须返回严格的 JSON 格式。',
            ),
            ...processedMessages.where((m) => m != processedMessages[systemIdx]),
          ];
        }
      } else {
        processedMessages = [
          ChatMessage(role: 'system', content: '返回严格的 JSON 格式。'),
          ...processedMessages,
        ];
      }
    }

    final body = jsonEncode({
      'model': modelName,
      'messages': processedMessages.map((m) => m.toMap()).toList(),
      'temperature': temperature,
      if (responseFormat != null) 'response_format': responseFormat,
    });

    final uri = Uri.parse('$baseUrl/chat/completions');
    final proxy = normalizeConfiguredProxy() ?? 'DIRECT';
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };

    await AppLogger.info(
      'LLM request started',
      data: {
        'tag': requestTag ?? 'untagged',
        'endpoint': uri.toString(),
        'model': modelName,
        'jsonMode': jsonMode,
        'messageCount': processedMessages.length,
        'proxy': proxy,
      },
    );

    http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: headers,
            body: body,
          )
          .timeout(const Duration(seconds: 120));
    } on TimeoutException {
      await AppLogger.error(
        'LLM request timed out',
        data: {
          'tag': requestTag ?? 'untagged',
          'endpoint': uri.toString(),
          'proxy': proxy,
        },
      );
      throw Exception(
        'LLM request timed out after 120s. Endpoint: $uri, proxy: $proxy',
      );
    } on SocketException catch (e, st) {
      await AppLogger.error(
        'LLM network request failed',
        data: {
          'tag': requestTag ?? 'untagged',
          'endpoint': uri.toString(),
          'proxy': proxy,
        },
        error: e,
        stackTrace: st,
      );
      throw Exception(
        'LLM network request failed. Endpoint: $uri, proxy: $proxy, error: ${e.message}',
      );
    } catch (e, st) {
      await AppLogger.error(
        'LLM request failed before response',
        data: {
          'tag': requestTag ?? 'untagged',
          'endpoint': uri.toString(),
        },
        error: e,
        stackTrace: st,
      );
      throw Exception('LLM request failed. Endpoint: $uri, error: $e');
    }

    await AppLogger.info(
      'LLM response received',
      data: {
        'tag': requestTag ?? 'untagged',
        'statusCode': response.statusCode,
        'endpoint': uri.toString(),
        'bodyLength': response.body.length,
      },
    );

    if (response.statusCode != 200) {
      await AppLogger.error(
        'LLM API returned non-200 status',
        data: {
          'tag': requestTag ?? 'untagged',
          'statusCode': response.statusCode,
          'endpoint': uri.toString(),
          'bodyPreview': AppLogger.preview(response.body),
        },
      );
      throw Exception('LLM API error (${response.statusCode}): ${response.body}');
    }

    late final Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e, st) {
      await AppLogger.error(
        'LLM response JSON parse failed',
        data: {
          'tag': requestTag ?? 'untagged',
          'endpoint': uri.toString(),
          'bodyPreview': AppLogger.preview(response.body),
        },
        error: e,
        stackTrace: st,
      );
      throw Exception('LLM response parse failed: $e');
    }

    final choices = data['choices'] as List?;
    final content =
        choices?.isNotEmpty == true ? choices![0]['message']['content'] as String : '';

    await AppLogger.info(
      'LLM response parsed',
      data: {
        'tag': requestTag ?? 'untagged',
        'usage': data['usage'],
        'contentLength': content.length,
      },
    );

    return LlmResponse(
      content: content,
      usage: data['usage'] as Map<String, dynamic>?,
    );
  }

  void dispose() => _client.close();
}
