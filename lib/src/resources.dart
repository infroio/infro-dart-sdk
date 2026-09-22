/// The endpoint surface.
///
/// Every method takes named parameters and returns the decoded JSON with the
/// field names the API actually uses. That is deliberate: the docs, the curl
/// examples and this SDK all spell `duration_seconds` the same way, so a reader
/// can copy a field out of a published example and it works. Renaming fields to
/// look more Dart-like would make the documentation unusable and would need an
/// update every time the API grew one.
///
/// INFRO's own extensions — `routing`, `fallbacks`, `logging`, `metadata` — are
/// ordinary named parameters rather than an untyped extras map, which is the
/// single largest ergonomic difference from driving the gateway through an
/// OpenAI-compatible client.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'client.dart';
import 'errors.dart';

/// Terminal job statuses. Anything else means "ask again".
const Set<String> _terminal = {'succeeded', 'failed', 'cancelled'};

/// Drop unset arguments rather than sending explicit nulls.
///
/// An explicit `null` is a *value* to most APIs and means "unset this", which
/// is not what a caller who omitted an argument meant.
Map<String, dynamic> _body(Map<String, dynamic> params) =>
    Map.fromEntries(params.entries.where((entry) => entry.value != null));

class Completions {
  Completions(this._transport);

  final InfroTransport _transport;

  /// A chat completion.
  Future<Map<String, dynamic>> create({
    required String model,
    required List<Map<String, dynamic>> messages,
    int? maxTokens,
    double? temperature,
    Map<String, dynamic>? routing,
    List<String>? fallbacks,
    bool? logging,
    Map<String, String>? metadata,
    Map<String, dynamic>? extra,
  }) {
    return _transport.request(
      'POST',
      '/chat/completions',
      body: _body({
        'model': model,
        'messages': messages,
        'max_tokens': maxTokens,
        'temperature': temperature,
        'routing': routing,
        'fallbacks': fallbacks,
        'logging': logging,
        'metadata': metadata,
        ...?extra,
      }),
    );
  }

  /// A streamed chat completion, as a stream of chunks.
  ///
  /// Ends at `[DONE]`. A stream that ends *without* it raises rather than
  /// finishing quietly: the gateway closes that way when a request fails after
  /// the first byte, so silence would hand the caller a truncated answer that
  /// looks complete.
  Stream<Map<String, dynamic>> createStream({
    required String model,
    required List<Map<String, dynamic>> messages,
    int? maxTokens,
    Map<String, dynamic>? routing,
    List<String>? fallbacks,
    bool? logging,
    Map<String, String>? metadata,
    Map<String, dynamic>? extra,
  }) async* {
    final response = await _transport.stream(
      'POST',
      '/chat/completions',
      headers: const {'Accept': 'text/event-stream'},
      body: _body({
        'model': model,
        'messages': messages,
        'max_tokens': maxTokens,
        'routing': routing,
        'fallbacks': fallbacks,
        'logging': logging,
        'metadata': metadata,
        'stream': true,
        // `include_usage` on by default, because `usage.cost` is the one number
        // a caller nearly always wants and it is only emitted when asked for.
        'stream_options': {'include_usage': true},
        ...?extra,
      }),
    );

    final requestId = response.headers['x-infro-request-id'];
    final lines = response.stream.transform(utf8.decoder).transform(const LineSplitter());

    var sawDone = false;
    await for (final payload in sseFrames(lines)) {
      if (payload == '[DONE]') {
        sawDone = true;
        return;
      }
      final chunk = jsonDecode(payload) as Map<String, dynamic>;
      if (chunk.containsKey('error')) {
        // Nothing can be re-routed past the first byte, so this is the ending.
        // Raised rather than yielded, because a caller iterating chunks would
        // otherwise have to inspect every one for a field that is almost never
        // there.
        final error = chunk['error'] as Map<String, dynamic>;
        throw errorFromResponse(
          response.statusCode,
          {'error': error},
          {if (requestId != null) 'x-infro-request-id': requestId},
        );
      }
      yield chunk;
    }

    if (!sawDone) {
      throw InfroApiException(
        'The stream ended before [DONE]. The response is incomplete — '
        'see https://infro.io/docs/api/streaming.',
        type: 'upstream_error',
        status: response.statusCode,
        requestId: requestId,
      );
    }
  }
}

class Chat {
  Chat(InfroTransport transport) : completions = Completions(transport);

  final Completions completions;
}

class Images {
  Images(this._transport);

  final InfroTransport _transport;

  Future<Map<String, dynamic>> generate({
    required String model,
    required String prompt,
    int? n,
    String? size,
    String? responseFormat,
    Map<String, dynamic>? routing,
    List<String>? fallbacks,
    Map<String, dynamic>? extra,
  }) {
    return _transport.request(
      'POST',
      '/images/generations',
      body: _body({
        'model': model,
        'prompt': prompt,
        'n': n,
        'size': size,
        'response_format': responseFormat,
        'routing': routing,
        'fallbacks': fallbacks,
        ...?extra,
      }),
    );
  }
}

class Videos {
  Videos(this._transport);

  final InfroTransport _transport;

  /// Submit a render. Returns immediately with a queued job.
  Future<Map<String, dynamic>> create({
    required String model,
    required String prompt,
    int? durationSeconds,
    String? resolution,
    String? aspectRatio,
    String? image,
    Map<String, dynamic>? webhook,
    Map<String, dynamic>? routing,
    List<String>? fallbacks,
    Map<String, dynamic>? extra,
  }) {
    return _transport.request(
      'POST',
      '/videos',
      body: _body({
        'model': model,
        'prompt': prompt,
        'duration_seconds': durationSeconds,
        'resolution': resolution,
        'aspect_ratio': aspectRatio,
        'image': image,
        'webhook': webhook,
        'routing': routing,
        'fallbacks': fallbacks,
        ...?extra,
      }),
    );
  }

  Future<Map<String, dynamic>> retrieve(String jobId) =>
      _transport.request('GET', '/videos/${Uri.encodeComponent(jobId)}');
}

class Jobs {
  Jobs(this._transport);

  final InfroTransport _transport;

  Future<Map<String, dynamic>> retrieve(String jobId) =>
      _transport.request('GET', '/jobs/${Uri.encodeComponent(jobId)}');

  Future<Map<String, dynamic>> list({String? status, int? limit, String? cursor}) {
    final query = _body({'status': status, 'limit': limit?.toString(), 'cursor': cursor})
        .map((key, value) => MapEntry(key, value.toString()));
    final suffix = query.isEmpty ? '' : '?${Uri(queryParameters: query).query}';
    return _transport.request('GET', '/jobs$suffix');
  }

  Future<Map<String, dynamic>> cancel(String jobId) =>
      _transport.request('POST', '/jobs/${Uri.encodeComponent(jobId)}/cancel');

  /// Poll until the job reaches a terminal status.
  ///
  /// A convenience, and deliberately an unglamorous one: a webhook is the
  /// documented way to learn a render finished, and polling is what you do in a
  /// script or a test where there is nowhere for a webhook to land.
  ///
  /// Throws on a failed render rather than returning it, because a caller who
  /// awaited "the finished video" will use whatever comes back as one.
  Future<Map<String, dynamic>> waitFor(
    String jobId, {
    Duration timeout = const Duration(minutes: 30),
    Duration pollInterval = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var interval = pollInterval;

    while (true) {
      final job = await retrieve(jobId);
      final status = job['status'] as String?;

      if (status == 'succeeded') return job;
      if (status != null && _terminal.contains(status)) {
        final error = job['error'] as Map<String, dynamic>?;
        throw InfroApiException(
          (error?['message'] as String?) ?? 'Job $jobId ended as $status.',
          type: (error?['type'] as String?) ?? 'upstream_error',
          code: error?['code'] as String?,
          status: 502,
          requestId: jobId,
        );
      }

      if (!DateTime.now().isBefore(deadline)) {
        throw InfroApiException(
          'Job $jobId did not finish within the wait timeout. It may still be '
          'running — retrieve it, or use a webhook.',
          type: 'timeout_error',
          status: 408,
          requestId: jobId,
        );
      }

      await Future<void>.delayed(interval);
      final doubled = interval * 2;
      interval = doubled > const Duration(seconds: 30) ? const Duration(seconds: 30) : doubled;
    }
  }
}

class Audio {
  Audio(this._transport);

  final InfroTransport _transport;

  /// Text to speech. Returns the audio bytes.
  Future<Uint8List> speech({
    required String model,
    required String input,
    required String voice,
    String? format,
    double? speed,
    Map<String, dynamic>? extra,
  }) async {
    final response = await _transport.send(
      'POST',
      '/audio/speech',
      headers: const {'Accept': 'audio/*'},
      body: _body({
        'model': model,
        'input': input,
        'voice': voice,
        'format': format,
        'speed': speed,
        ...?extra,
      }),
    );
    return response.bodyBytes;
  }

  Future<Map<String, dynamic>> transcribe({
    required String model,
    required String file,
    String? language,
    Map<String, dynamic>? extra,
  }) {
    return _transport.request(
      'POST',
      '/audio/transcriptions',
      body: _body({'model': model, 'file': file, 'language': language, ...?extra}),
    );
  }
}

class Models {
  Models(this._transport);

  final InfroTransport _transport;

  Future<Map<String, dynamic>> list() => _transport.request('GET', '/models');

  Future<Map<String, dynamic>> retrieve(String modelId) =>
      _transport.request('GET', '/models/$modelId');
}

class Keys {
  Keys(this._transport);

  final InfroTransport _transport;

  /// What this key is, what it may spend, and what is left.
  Future<Map<String, dynamic>> retrieve() => _transport.request('GET', '/key');
}

class Requests {
  Requests(this._transport);

  final InfroTransport _transport;

  Future<Map<String, dynamic>> retrieve(String requestId) =>
      _transport.request('GET', '/requests/${Uri.encodeComponent(requestId)}');
}
