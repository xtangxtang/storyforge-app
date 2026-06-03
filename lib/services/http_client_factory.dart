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
    // Honour a no_proxy policy: LAN / loopback / the ComfyUI host must be
    // reached directly even when an enterprise proxy is configured for the
    // internet (otherwise self-hosted ComfyUI on 172.16.x is unreachable).
    ..findProxy = ((uri) => _shouldBypassProxy(uri) ? 'DIRECT' : 'PROXY $proxy')
    // Enterprise TLS-inspecting proxies (e.g. Fortinet) re-sign HTTPS with a
    // corporate CA that Dart's built-in root store doesn't trust, which would
    // otherwise make every cloud call (LLM, Ark, DashScope) fail with
    // CERTIFICATE_VERIFY_FAILED. Since reaching the internet here REQUIRES
    // going through that proxy, accept its substituted cert for proxied
    // (non-bypassed) hosts only. Direct/LAN traffic keeps normal validation.
    ..badCertificateCallback = ((cert, host, port) =>
        !_shouldBypassProxy(Uri(host: host, port: port)));

  return IOClient(httpClient);
}

String? normalizeConfiguredProxy() => _normalizeProxy(AppConfig.httpsProxy);

bool _shouldBypassProxy(Uri uri) {
  final host = uri.host;
  if (host.isEmpty) return false;
  if (host == 'localhost') return true;

  final comfyHost = Uri.tryParse(AppConfig.comfyuiBaseUrl)?.host;
  if (comfyHost != null && comfyHost.isNotEmpty && host == comfyHost) {
    return true;
  }

  return _isPrivateOrLoopbackIp(host);
}

/// True for IPv4 loopback / RFC1918 private / link-local addresses.
bool _isPrivateOrLoopbackIp(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final p in parts) {
    final v = int.tryParse(p);
    if (v == null || v < 0 || v > 255) return false;
    octets.add(v);
  }
  final a = octets[0], b = octets[1];
  if (a == 127) return true; // 127.0.0.0/8 loopback
  if (a == 10) return true; // 10.0.0.0/8
  if (a == 192 && b == 168) return true; // 192.168.0.0/16
  if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
  if (a == 169 && b == 254) return true; // 169.254.0.0/16 link-local
  return false;
}

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
