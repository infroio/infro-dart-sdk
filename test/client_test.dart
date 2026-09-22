/// The transport, which is where every expensive mistake in a client lives.
///
/// The three that matter, and that this suite exists to prevent:
///
/// * **Retrying something that should not be retried.** A `400` retried three
///   times is three times the latency for the same failure; a billed `POST`
///   retried without an idempotency key is somebody charged twice for one
///   render.
/// * **Losing the request id.** It is the first thing support asks for and the
///   last thing anybody records.
/// * **Mis-framing a stream.** An SSE frame split across two network reads is
///   normal, not exceptional, and a parser that assumes otherwise works
///   perfectly in development.
///
/// The client is driven through a mock HTTP client rather than a live server,
/// so what is asserted is the *request the SDK built* — its headers, its body,
/// and how many times it was sent.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:infro/infro.dart';
import 'package:test/test.dart';

const key = 'unit-test-key-not-a-secret';

/// A recorded exchange: what was sent, and what to answer with.
class Recorder {
  Recorder(this._responses);

  final List<Object> _responses;
  final List<http.BaseRequest> sent = [];

  http.Client get client => MockClient.streaming((request, bodyStream) async {
        sent.add(request);
        if (_responses.isEmpty) throw StateError('no canned response left');
        final next = _responses.removeAt(0);
        if (next is Exception) throw next;
        return next as http.StreamedResponse;
      });
}

http.StreamedResponse ok(Object body, {int status = 200, Map<String, String>? headers}) {
  final bytes = utf8.encode(jsonEncode(body));
  return http.StreamedResponse(
    Stream.value(bytes),
    status,
    contentLength: bytes.length,
    headers: {
      'content-type': 'application/json',
      'x-infro-request-id': 'req_TEST01',
      ...?headers,
    },
  );
}

http.StreamedResponse failure(int status, String type, String message) => ok(
      {
        'error': {'message': message, 'type': type, 'code': null},
      },
      status: status,
    );

http.StreamedResponse sse(List<String> frames, {int status = 200}) {
  final bytes = utf8.encode(frames.join());
  return http.StreamedResponse(
    Stream.value(bytes),
    status,
    headers: {'content-type': 'text/event-stream', 'x-infro-request-id': 'req_STREAM'},
  );
}

String chunk(String content) => 'data: ${jsonEncode({
      'id': 'c',
      'object': 'chat.completion.chunk',
      'choices': [
        {
          'index': 0,
          'delta': {'content': content},
          'finish_reason': null,
        }
      ],
    })}\n\n';

({Infro sdk, Recorder recorder}) make(List<Object> responses, {int maxRetries = 0}) {
  final recorder = Recorder(responses);
  final sdk = Infro(
    apiKey: key,
    baseUrl: 'https://api.test/v1',
    maxRetries: maxRetries,
    httpClient: recorder.client,
  );
  return (sdk: sdk, recorder: recorder);
}

void main() {
  group('constructing a client', () {
    test('refuses to start without a key rather than failing on the first request', () {
      // A key missing at construction is a configuration mistake. Discovering
      // it as a 401 on the first customer request is the same mistake, later.
      expect(
        () => Infro(apiKey: '', baseUrl: 'https://api.test/v1'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('strips a trailing slash from the base URL', () {
      final sdk = Infro(apiKey: key, baseUrl: 'https://api.test/v1/');
      expect(sdk.baseUrl, 'https://api.test/v1');
    });
  });

  group('every request', () {
    test('authenticates and identifies itself', () async {
      final t = make([ok({'ok': true})]);
      await t.sdk.keys.retrieve();

      expect(t.recorder.sent.first.headers['Authorization'], 'Bearer $key');
      expect(t.recorder.sent.first.headers['User-Agent'], startsWith('infro-dart/'));
    });

    test('carries an idempotency key on a write', () async {
      // On the first attempt, not only on the retry: the gateway keys on it
      // when it *first* sees the request.
      final t = make([ok({'id': 'req_1'})]);
      await t.sdk.images.generate(model: 'm', prompt: 'p');

      expect(t.recorder.sent.first.headers['Idempotency-Key'], isNotNull);
    });

    test('does not put one on a read', () async {
      final t = make([ok({'data': []})]);
      await t.sdk.models.list();
      expect(t.recorder.sent.first.headers.containsKey('Idempotency-Key'), isFalse);
    });
  });

  group('errors', () {
    test('throws the class that matches the type', () async {
      final cases = <int, Object>{
        402: isA<BudgetExceededException>(),
        429: isA<RateLimitException>(),
        400: isA<InvalidRequestException>(),
        502: isA<UpstreamException>(),
        503: isA<NoAvailableProviderException>(),
      };
      final types = {
        402: 'budget_exceeded',
        429: 'rate_limit_exceeded',
        400: 'invalid_request_error',
        502: 'upstream_error',
        503: 'no_available_provider',
      };

      for (final entry in cases.entries) {
        final t = make([failure(entry.key, types[entry.key]!, 'nope')]);
        await expectLater(t.sdk.models.list(), throwsA(entry.value));
      }
    });

    test('carries the message and the request id', () async {
      final t = make([failure(402, 'budget_exceeded', 'Your balance is exhausted.')]);

      await expectLater(
        t.sdk.models.list(),
        throwsA(isA<BudgetExceededException>()
            .having((e) => e.message, 'message', 'Your balance is exhausted.')
            .having((e) => e.requestId, 'requestId', 'req_TEST01')
            .having((e) => e.status, 'status', 402)),
      );
    });

    test('keys retryability on the status, not the type', () {
      expect(const InfroApiException('', status: 429).retryable, isTrue);
      expect(const InfroApiException('', status: 503).retryable, isTrue);
      expect(const InfroApiException('', status: 400).retryable, isFalse);
      // A defect in the gateway's own code fails identically on a retry.
      expect(const InfroApiException('', status: 500).retryable, isFalse);
    });

    test('does not retry no_provider_connected, though it is a 503', () {
      // The one code that overrides its own status. Nothing about a second
      // attempt connects a provider account, and it is the first error most
      // new organizations meet.
      expect(
        const InfroApiException('', status: 503, code: 'no_provider_connected')
            .retryable,
        isFalse,
      );
      // A plain 503 with no code is still retryable.
      expect(const InfroApiException('', status: 503).retryable, isTrue);
    });

    test('survives a body that is not the documented envelope', () async {
      // A load balancer in front of INFRO can return HTML.
      final bytes = utf8.encode('<html>bad gateway</html>');
      final t = make([
        http.StreamedResponse(Stream.value(bytes), 502, contentLength: bytes.length),
      ]);

      await expectLater(
        t.sdk.models.list(),
        throwsA(isA<UpstreamException>().having((e) => e.message, 'message', contains('502'))),
      );
    });

    test('names the request id in the string form', () {
      const error = InfroApiException('Rate limited',
          type: 'rate_limit_exceeded', status: 429, requestId: 'req_A');
      expect(error.toString(), contains('req_A'));
      expect(error.toString(), contains('status=429'));
    });
  });

  group('retrying', () {
    test('retries a 503 and returns the eventual success', () async {
      final t = make(
        [failure(503, 'no_available_provider', 'no route'), ok({'data': []})],
        maxRetries: 1,
      );

      expect(await t.sdk.models.list(), {'data': []});
      expect(t.recorder.sent.length, 2);
    });

    test('does not retry a 400', () async {
      final t = make([failure(400, 'invalid_request_error', 'bad model')], maxRetries: 3);
      await expectLater(t.sdk.models.list(), throwsA(isA<InvalidRequestException>()));
      expect(t.recorder.sent.length, 1);
    });

    test('does not retry a 402, because more credit is not a matter of waiting', () async {
      final t = make([failure(402, 'budget_exceeded', 'exhausted')], maxRetries: 3);
      await expectLater(t.sdk.models.list(), throwsA(isA<BudgetExceededException>()));
      expect(t.recorder.sent.length, 1);
    });

    test('reuses the same idempotency key across a retry', () async {
      // The point of the key. A second attempt carrying a different one is a
      // second render, and a second charge.
      final t = make(
        [failure(502, 'upstream_error', 'flaky'), ok({'id': 'req_1'})],
        maxRetries: 1,
      );
      await t.sdk.images.generate(model: 'm', prompt: 'p');

      expect(
        t.recorder.sent[0].headers['Idempotency-Key'],
        t.recorder.sent[1].headers['Idempotency-Key'],
      );
    });

    test('gives up after the configured attempts', () async {
      final t = make(
        [
          failure(502, 'upstream_error', 'a'),
          failure(502, 'upstream_error', 'b'),
          failure(502, 'upstream_error', 'c'),
        ],
        maxRetries: 2,
      );
      await expectLater(
        t.sdk.models.list(),
        throwsA(isA<UpstreamException>().having((e) => e.message, 'message', 'c')),
      );
      expect(t.recorder.sent.length, 3);
    });
  });

  group('backoff', () {
    test('obeys Retry-After when the server sends one', () {
      // The server knows when capacity frees up; a guess that undershoots
      // produces a second 429.
      const error = InfroApiException('', status: 429, retryAfter: Duration(seconds: 12));
      expect(backoffFor(1, error), const Duration(seconds: 12));
    });

    test('caps an absurd Retry-After rather than sleeping for an hour', () {
      const error = InfroApiException('', status: 429, retryAfter: Duration(hours: 24));
      expect(backoffFor(1, error), const Duration(seconds: 60));
    });

    test('is bounded however many attempts have failed', () {
      expect(backoffFor(30, null).inMilliseconds, lessThanOrEqualTo(8000));
    });
  });

  group('the resource surface', () {
    test('sends INFRO extensions as top-level body fields', () async {
      // Top level, not headers and not a nested envelope — which is what keeps
      // a codebase that uses them working against another OpenAI-compatible
      // backend that simply ignores them.
      final t = make([ok({'id': 'c', 'choices': [], 'usage': {'cost': 0}})]);

      await t.sdk.chat.completions.create(
        model: 'm',
        messages: const [],
        routing: const {'policy': 'fastest', 'regions': ['eu']},
        fallbacks: const ['deepseek/deepseek-v4-flash'],
        logging: false,
        metadata: const {'user': 'u_1'},
      );

      final body = jsonDecode((t.recorder.sent.first as http.Request).body) as Map<String, dynamic>;
      expect(body['routing'], {'policy': 'fastest', 'regions': ['eu']});
      expect(body['fallbacks'], ['deepseek/deepseek-v4-flash']);
      expect(body['logging'], isFalse);
      expect(body['metadata'], {'user': 'u_1'});
    });

    test('omits unset arguments rather than sending null', () async {
      // An explicit null is a *value* to most APIs and means "unset this",
      // which is not what a caller who omitted an argument meant.
      final t = make([ok({'id': 'req_1'})]);
      await t.sdk.images.generate(model: 'm', prompt: 'p');

      final body = jsonDecode((t.recorder.sent.first as http.Request).body) as Map<String, dynamic>;
      expect(body.keys.toSet(), {'model', 'prompt'});
    });

    test('generates an image and reports its cost', () async {
      final t = make([
        ok({
          'id': 'req_1',
          'data': [
            {'url': 'https://cdn.infro.io/x.png'}
          ],
          'usage': {'cost': 0.04},
        })
      ]);

      final image = await t.sdk.images.generate(model: 'bfl/flux-2-pro', prompt: 'a lighthouse');
      expect(t.recorder.sent.first.url.toString(), 'https://api.test/v1/images/generations');
      expect((image['usage'] as Map)['cost'], 0.04);
    });

    test('submits a video as a job', () async {
      final t = make([ok({'id': 'job_1', 'status': 'queued'})]);
      final job = await t.sdk.videos.create(
        model: 'kuaishou/kling-o3',
        prompt: 'a lighthouse',
        durationSeconds: 6,
        webhook: const {'url': 'https://example.com/hook'},
      );

      expect(job['status'], 'queued');
      final body = jsonDecode((t.recorder.sent.first as http.Request).body) as Map<String, dynamic>;
      expect(body['duration_seconds'], 6);
    });

    test('escapes a job id into the path', () async {
      // A path built by concatenation is a path an id can escape, and an id is
      // caller-supplied.
      final t = make([ok({'id': 'j'})]);
      await t.sdk.jobs.retrieve('job_../../admin');
      expect(t.recorder.sent.first.url.toString(), isNot(contains('/admin')));
    });
  });

  group('waiting for a job', () {
    test('polls until it succeeds', () async {
      final t = make([
        ok({'id': 'j', 'status': 'running'}),
        ok({'id': 'j', 'status': 'succeeded', 'output': {'url': 'https://cdn/x.mp4'}}),
      ]);

      final job = await t.sdk.jobs.waitFor('j', pollInterval: const Duration(milliseconds: 1));
      expect(job['status'], 'succeeded');
      expect(t.recorder.sent.length, 2);
    });

    test('throws on a failed job rather than returning it', () async {
      // A caller who awaited "the finished video" and got a failure map will
      // use it as though it were a video.
      final t = make([
        ok({
          'id': 'j',
          'status': 'failed',
          'error': {'message': 'the render failed', 'type': 'upstream_error', 'code': null},
        })
      ]);

      await expectLater(
        t.sdk.jobs.waitFor('j', pollInterval: const Duration(milliseconds: 1)),
        throwsA(isA<InfroApiException>()
            .having((e) => e.message, 'message', 'the render failed')),
      );
    });

    test('gives up at the deadline and says the job may still be running', () async {
      final t = make([ok({'id': 'j', 'status': 'running'})]);

      await expectLater(
        t.sdk.jobs.waitFor(
          'j',
          pollInterval: const Duration(milliseconds: 1),
          timeout: Duration.zero,
        ),
        throwsA(isA<InfroApiException>()
            .having((e) => e.message, 'message', contains('may still be running'))),
      );
    });
  });

  group('SSE framing', () {
    test('yields each frame and stops at [DONE]', () async {
      final t = make([sse([chunk('Hel'), chunk('lo'), 'data: [DONE]\n\n'])]);

      final contents = await t.sdk.chat.completions
          .createStream(model: 'm', messages: const [])
          .map((c) => ((c['choices'] as List).first as Map)['delta']['content'])
          .toList();

      expect(contents, ['Hel', 'lo']);
    });

    test('ignores keep-alive comments a proxy injects', () async {
      final t = make([sse([': keep-alive\n\n', chunk('a'), 'data: [DONE]\n\n'])]);
      final chunks =
          await t.sdk.chat.completions.createStream(model: 'm', messages: const []).toList();
      expect(chunks.length, 1);
    });

    test('raises a mid-stream error frame as an error', () async {
      // Nothing can be re-routed past the first byte, so this is the ending.
      final frame = 'data: ${jsonEncode({
            'error': {'message': 'upstream died', 'type': 'upstream_error', 'code': null},
          })}\n\n';
      final t = make([sse([chunk('a'), frame])]);

      await expectLater(
        t.sdk.chat.completions.createStream(model: 'm', messages: const []).toList(),
        throwsA(isA<UpstreamException>().having((e) => e.message, 'message', 'upstream died')),
      );
    });

    test('treats a stream that ends without [DONE] as truncated', () async {
      // The gateway documents closing without [DONE] on a mid-stream failure,
      // so its absence is meaningful. Returning the partial answer silently is
      // how truncated text reaches a user as though it were complete.
      final t = make([sse([chunk('half an answer')])]);

      await expectLater(
        t.sdk.chat.completions.createStream(model: 'm', messages: const []).toList(),
        throwsA(isA<InfroApiException>()
            .having((e) => e.message, 'message', contains('incomplete'))),
      );
    });

    test('asks for usage on a stream', () async {
      final t = make([sse(['data: [DONE]\n\n'])]);
      await t.sdk.chat.completions.createStream(model: 'm', messages: const []).toList();

      final body = jsonDecode((t.recorder.sent.first as http.Request).body) as Map<String, dynamic>;
      expect((body['stream_options'] as Map)['include_usage'], isTrue);
    });
  });
}
