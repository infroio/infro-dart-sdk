/// The transport every resource is built on.
///
/// AUTHENTICATION, RETRIES, IDEMPOTENCY AND ERROR MAPPING LIVE HERE ONLY
///
/// Deciding them once is what stops one endpoint retrying a `400`, another
/// forgetting the idempotency key, and a third losing the request id from the
/// error it throws.
///
/// RETRIES ARE NARROW AND IDEMPOTENT, WHICH IS THE WHOLE POINT
///
/// Only the four statuses the docs name as retryable — 408, 429, 502, 503 —
/// and always with an `Idempotency-Key`, so a retry of a request the gateway
/// already accepted returns the first response rather than doing the work
/// twice. Retrying a billed POST without one is how somebody is charged twice
/// for a render they asked for once.
///
/// `Retry-After` wins over the computed backoff when the server sends it, and
/// jitter is applied so a fleet that failed together does not retry together.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException, Platform, SocketException;
import 'dart:math';

import 'package:http/http.dart' as http;

import 'errors.dart';

/// Published production base URL. Overridable for staging and for tests.
const String defaultBaseUrl = 'https://api.infro.io/v1';

const String packageVersion = '0.1.2';

const Duration _defaultTimeout = Duration(minutes: 10);
const int _defaultMaxRetries = 2;

/// How long to wait before [attempt].
///
/// `Retry-After` first, because the server knows when capacity frees up and a
/// computed guess that undershoots produces a second 429. Otherwise
/// exponential with full jitter — a fleet that failed together must not retry
/// together, which is what turns a blip into a thundering herd.
Duration backoffFor(int attempt, Object? error, {Random? random}) {
  if (error is InfroApiException) {
    final after = error.retryAfter;
    if (after != null && !after.isNegative) {
      return after > const Duration(seconds: 60) ? const Duration(seconds: 60) : after;
    }
  }
  final ceilingMs = min(500 * pow(2, attempt - 1).toInt(), 8000);
  final draw = (random ?? Random()).nextDouble();
  return Duration(milliseconds: (ceilingMs * (0.5 + draw * 0.5)).round());
}

/// The HTTP layer.
class InfroTransport {
  InfroTransport({
    String? apiKey,
    String? baseUrl,
    this.timeout = _defaultTimeout,
    this.maxRetries = _defaultMaxRetries,
    Map<String, String>? defaultHeaders,
    http.Client? httpClient,
  })  : _apiKey = _resolveKey(apiKey),
        baseUrl = _resolveBaseUrl(baseUrl),
        _defaultHeaders = defaultHeaders ?? const {},
        _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  final String _apiKey;
  final String baseUrl;
  final Duration timeout;
  final int maxRetries;
  final Map<String, String> _defaultHeaders;
  final http.Client _http;
  final bool _ownsClient;

  static String _resolveKey(String? apiKey) {
    final key = apiKey ??
        (Platform.environment.containsKey('INFRO_API_KEY')
            ? Platform.environment['INFRO_API_KEY']
            : null);
    if (key == null || key.isEmpty) {
      throw ArgumentError(
        'No INFRO API key. Pass apiKey: or set INFRO_API_KEY in the '
        'environment. Create a key at https://dash.infro.io.',
      );
    }
    return key;
  }

  static String _resolveBaseUrl(String? baseUrl) {
    final value = baseUrl ?? Platform.environment['INFRO_BASE_URL'] ?? defaultBaseUrl;
    return value.replaceAll(RegExp(r'/+$'), '');
  }

  Map<String, String> _headers(
    String method,
    Map<String, String>? extra,
    String? idempotencyKey,
  ) {
    final headers = <String, String>{
      'Authorization': 'Bearer $_apiKey',
      'Accept': 'application/json',
      'User-Agent': 'infro-dart/$packageVersion',
      ..._defaultHeaders,
      ...?extra,
    };
    if (method != 'GET' && method != 'HEAD') {
      headers.putIfAbsent('Content-Type', () => 'application/json');
      // On every write, not only on the retry: the gateway keys on this when it
      // *first* sees the request, so adding it on the second attempt would be a
      // different request as far as the server is concerned.
      headers['Idempotency-Key'] = idempotencyKey ?? _newIdempotencyKey();
    }
    return headers;
  }

  /// A JSON request that returns a decoded body.
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? body,
    int? maxRetries,
    Map<String, String>? headers,
    String? idempotencyKey,
  }) async {
    final response = await send(
      method,
      path,
      body: body,
      maxRetries: maxRetries,
      headers: headers,
      idempotencyKey: idempotencyKey,
    );
    if (response.statusCode == 204 || response.bodyBytes.isEmpty) return const {};
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// A request that returns the response itself, for binary bodies.
  Future<http.Response> send(
    String method,
    String path, {
    Object? body,
    int? maxRetries,
    Map<String, String>? headers,
    String? idempotencyKey,
  }) async {
    final attempts = maxRetries ?? this.maxRetries;
    final uri = Uri.parse('$baseUrl${path.startsWith('/') ? path : '/$path'}');
    final requestHeaders = _headers(method, headers, idempotencyKey);
    Object? last;

    for (var attempt = 0; attempt <= attempts; attempt += 1) {
      if (attempt > 0) await Future<void>.delayed(backoffFor(attempt, last));

      http.Response response;
      try {
        final request = http.Request(method, uri)..headers.addAll(requestHeaders);
        if (body != null) request.body = jsonEncode(body);
        final streamed = await _http.send(request).timeout(timeout);
        response = await http.Response.fromStream(streamed);
      } on TimeoutException catch (error) {
        final failure = InfroConnectionException(
          'Request timed out after ${timeout.inSeconds}s',
          error,
        );
        if (attempt == attempts) throw failure;
        last = failure;
        continue;
      } on SocketException catch (error) {
        final failure = InfroConnectionException('Could not reach $baseUrl', error);
        if (attempt == attempts) throw failure;
        last = failure;
        continue;
      } on HttpException catch (error) {
        final failure = InfroConnectionException('Could not reach $baseUrl', error);
        if (attempt == attempts) throw failure;
        last = failure;
        continue;
      }

      if (response.statusCode >= 200 && response.statusCode < 300) return response;

      final error = errorFromResponse(
        response.statusCode,
        _decodeOrNull(response),
        response.headers,
      );

      // Keyed on the status, decided once. Re-deciding it in a catch block is
      // how a `400` gets retried three times.
      if (!error.retryable || attempt == attempts) throw error;
      last = error;
    }

    throw last is InfroException
        ? last
        : const InfroConnectionException('Request failed with no outcome');
  }

  /// A streamed request, for Server-Sent Events.
  ///
  /// Never retried by the caller: past the first byte the customer has already
  /// seen part of an answer, and replaying would show them a sentence starting
  /// twice.
  Future<http.StreamedResponse> stream(
    String method,
    String path, {
    Object? body,
    Map<String, String>? headers,
    String? idempotencyKey,
  }) async {
    final uri = Uri.parse('$baseUrl${path.startsWith('/') ? path : '/$path'}');
    final request = http.Request(method, uri)
      ..headers.addAll(_headers(method, headers, idempotencyKey));
    if (body != null) request.body = jsonEncode(body);

    final http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } on SocketException catch (error) {
      throw InfroConnectionException('Could not reach $baseUrl', error);
    }

    if (response.statusCode >= 200 && response.statusCode < 300) return response;

    // The body carries the message, and it has not been read yet.
    final failed = await http.Response.fromStream(response);
    throw errorFromResponse(failed.statusCode, _decodeOrNull(failed), failed.headers);
  }

  void close() {
    if (_ownsClient) _http.close();
  }
}

Object? _decodeOrNull(http.Response response) {
  try {
    return jsonDecode(utf8.decode(response.bodyBytes));
  } catch (_) {
    // A non-JSON body is a normal proxy outcome, not an exceptional one.
    return null;
  }
}

/// A key the gateway can deduplicate on.
String _newIdempotencyKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Yield each `data:` payload from a stream of decoded lines.
///
/// Frames are separated by a blank line and a `data:` value may span several of
/// them, so this accumulates rather than treating one line as one frame. `:`
/// comment lines are skipped, because a proxy is entitled to inject keep-alives
/// and a parser that threw on one would fail only behind a load balancer.
Stream<String> sseFrames(Stream<String> lines) async* {
  final parts = <String>[];
  await for (final line in lines) {
    if (line.isEmpty) {
      if (parts.isNotEmpty) {
        yield parts.join('\n');
        parts.clear();
      }
      continue;
    }
    if (line.startsWith(':')) continue;
    if (line.startsWith('data:')) parts.add(line.substring(5).trimLeft());
  }
  if (parts.isNotEmpty) yield parts.join('\n');
}
