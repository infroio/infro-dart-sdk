# infro

[![pub package](https://img.shields.io/pub/v/infro.svg)](https://pub.dev/packages/infro)
[![CI](https://github.com/infroio/dart-sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/infroio/dart-sdk/actions/workflows/ci.yml)
[![Pub Points](https://img.shields.io/pub/points/infro)](https://pub.dev/packages/infro/score)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

The official Dart client for the [INFRO](https://infro.io) API — one endpoint
for text, image, video and audio models.

```bash
dart pub add infro
```

```dart
import 'package:infro/infro.dart';

final infro = Infro();  // reads INFRO_API_KEY

final image = await infro.images.generate(
  model: 'bfl/flux-2-pro',
  prompt: 'a lighthouse in fog, 35mm',
);

print(image['data'][0]['url']);
print("cost: \$${image['usage']['cost']}");
```

## Why Dart is on the list

Because Flutter is. A mobile app that calls model APIs wants the multimodal
surface and the per-request cost figure in the same place, and the alternative
is hand-rolled JSON in a widget. One dependency — `package:http`, which a
Flutter app already carries.

## Configuration

```dart
final infro = Infro(
  apiKey: 'sk_infro_...',            // or INFRO_API_KEY in the environment
  baseUrl: 'https://api.infro.io/v1',
  timeout: Duration(minutes: 10),     // per attempt
  maxRetries: 2,                      // attempts *after* the first
);
```

The key falls back to `INFRO_API_KEY` because a key in source is a key in
version control.

> On Flutter for web there is no `Platform.environment`, so pass `apiKey`
> explicitly — and remember that a key shipped in a web bundle is a public key.
> Proxy through your own backend instead.

## Text

```dart
final completion = await infro.chat.completions.create(
  model: 'anthropic/claude-sonnet-5',
  messages: [
    {'role': 'user', 'content': 'Hello'},
  ],
);

print(completion['choices'][0]['message']['content']);
print(completion['model']);  // the model that *served* — matters with fallbacks
print(completion['route']);  // "primary" or "standby_a" — a position, never a vendor
```

Streaming is a `Stream`, which is what every Flutter widget already knows how to
consume:

```dart
final stream = infro.chat.completions.createStream(
  model: 'anthropic/claude-sonnet-5',
  messages: [
    {'role': 'user', 'content': 'Write a haiku about fog.'},
  ],
);

await for (final chunk in stream) {
  stdout.write(chunk['choices'][0]['delta']['content'] ?? '');
}
```

A stream that ends *without* `[DONE]` throws rather than completing quietly: the
gateway closes that way when a request fails after the first byte, so silence
would hand you a truncated answer that looks complete.

## Routing, fallbacks and cost control

```dart
final completion = await infro.chat.completions.create(
  model: 'openai/gpt-5.6-terra',
  messages: [{'role': 'user', 'content': 'Hello'}],
  routing: {'policy': 'fastest', 'regions': ['us', 'eu']},
  fallbacks: ['deepseek/deepseek-v4-flash'],
  metadata: {'user': 'u_42', 'feature': 'summariser'},
  logging: false,  // this request's content is never stored
);
```

## Video

Renders take minutes, so they are jobs. A webhook is the production path:

```dart
final job = await infro.videos.create(
  model: 'kuaishou/kling-o3',
  prompt: 'slow push-in on a lighthouse in fog',
  durationSeconds: 6,
  webhook: {'url': 'https://api.example.com/hooks/infro'},
);
```

In a script or a test, where there is nowhere for a webhook to land, poll:

```dart
final finished = await infro.jobs.waitFor(job['id'] as String);
print(finished['output']['url']);
```

`waitFor` throws on a failed render rather than returning it, because a caller
who awaited "the finished video" will use whatever comes back as one.

## Audio

```dart
final bytes = await infro.audio.speech(
  model: 'elevenlabs/eleven-v3',
  input: 'The lighthouse keeper watched the fog roll in.',
  voice: 'rachel',
);
await File('out.mp3').writeAsBytes(bytes);
```

## Errors

```dart
try {
  await infro.chat.completions.create(model: model, messages: messages);
} on BudgetExceededException catch (error) {
  // top up; retrying will not help
} on RateLimitException catch (error) {
  // already retried for you; error.retryAfter is the server's own hint
} on InfroApiException catch (error) {
  print(error.requestId);  // the first thing support will ask for
} on InfroConnectionException {
  // never reached the gateway — DNS, TLS, a dropped socket
}
```

Every exception carries `status`, `type`, `code`, `requestId` and `retryable`.
`retryable` is keyed on the HTTP status, not the type, because the status is
what the docs promise and what a proxy preserves.

## Retries

Only the four statuses the docs name as retryable — `408`, `429`, `502`, `503` —
and always with an `Idempotency-Key`, so a retry of a request the gateway
already accepted returns the first response instead of doing the work twice.
`Retry-After` wins over the computed backoff; jitter stops a fleet that failed
together from retrying together.

Streams are never retried: past the first byte the caller has already seen part
of an answer.

## Anything this client does not model

The gateway grows faster than a client library, so there is an escape hatch that
keeps the authentication and the retries:

```dart
final usage = await infro.transport.request('GET', '/usage?from=2026-08-01');
```

## Documentation

<https://infro.io/docs> — the API reference, the error table, and the routing,
fallback and privacy semantics this client is a thin shell over.
