import 'package:uuid/uuid.dart';

class AgentContext {
  final String projectId;
  final Map<String, dynamic> data;

  AgentContext({required this.projectId, Map<String, dynamic>? data})
      : data = data ?? {};
}

class AgentResult<T> {
  final bool success;
  final T? data;
  final String? error;

  AgentResult({required this.success, this.data, this.error});

  factory AgentResult.error(String message) =>
      AgentResult(success: false, error: message);

  factory AgentResult.success(T data) =>
      AgentResult(success: true, data: data);
}

abstract class Agent {
  String get name;

  Future<AgentResult> run(AgentContext context);

  Future<AgentResult> review(
    AgentContext context,
    AgentResult result,
  ) async {
    if (!result.success) {
      return retry(context, result);
    }
    return result;
  }

  Future<AgentResult> retry(
    AgentContext context,
    AgentResult result,
  ) async {
    return run(context);
  }

  String createTaskId() => 'task_${const Uuid().v4().substring(0, 8)}';
}
