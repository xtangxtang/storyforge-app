import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';

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

  LlmService({http.Client? client}) : _client = client ?? http.Client();

  Future<LlmResponse> chatCompletion({
    required List<ChatMessage> messages,
    String? model,
    double temperature = 0.7,
    bool jsonMode = false,
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
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };

    http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: headers,
            body: body,
          )
          .timeout(const Duration(seconds: 120));
    } catch (e) {
      throw Exception('LLM request timeout or failed: $e');
    }

    if (response.statusCode != 200) {
      throw Exception('LLM API error (${response.statusCode}): ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = data['choices'] as List?;
    final content =
        choices?.isNotEmpty == true ? choices![0]['message']['content'] as String : '';

    return LlmResponse(
      content: content,
      usage: data['usage'] as Map<String, dynamic>?,
    );
  }

  void dispose() => _client.close();
}
