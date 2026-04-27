import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../config/app_config.dart';

http.Client createConfiguredHttpClient() {
  final proxy = _normalizeProxy(AppConfig.httpsProxy);
  if (proxy == null) {
    return http.Client();
  }

  final httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..findProxy = (_) => 'PROXY $proxy';

  return IOClient(httpClient);
}

String? normalizeConfiguredProxy() => _normalizeProxy(AppConfig.httpsProxy);

String? _normalizeProxy(String rawProxy) {
  final trimmed = rawProxy.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final proxyValue = trimmed.contains('://') ? trimmed : 'http://$trimmed';
  final proxyUri = Uri.tryParse(proxyValue);
  if (proxyUri == null || proxyUri.host.isEmpty) {
    return null;
  }

  final userInfo = proxyUri.userInfo.isEmpty ? '' : '${proxyUri.userInfo}@';
  final port = proxyUri.hasPort
      ? proxyUri.port
      : (proxyUri.scheme == 'https' ? 443 : 80);

  return '$userInfo${proxyUri.host}:$port';
}