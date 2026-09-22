# Changelog

All three INFRO SDKs share one version line: a customer reading a changelog
should not have to work out which of three independent version numbers applies
to them.

## 0.1.2

- Correct the runtime version reported in the SDK user agent and enforce the
  package version in tests.

## 0.1.1

- Link the package metadata to its public GitHub repository and issue tracker.

## 0.1.0

First release.

- `chat.completions.create` and `createStream` for text, streaming as a `Stream`
  that throws rather than completing quietly when the gateway closes without
  `[DONE]`.
- `images.generate`, `video.create` / `retrieve` / `wait`, `audio.speech` and
  `audio.transcribe`, each carrying `usage.cost` on the response.
- `models.list`, `models.retrieve` and `key.retrieve`.
- The documented error taxonomy as exception classes, so "should I retry this?"
  is a branch on a type rather than a substring match on a message.
- Retries only on 408, 429, 502 and 503, always carrying the `Idempotency-Key`
  sent with the first attempt — except `no_provider_connected`, the one 503 a
  retry can never clear, which fails immediately so the advice in its message
  arrives without a backoff in front of it. A stream is never retried.
- `request()` as an escape hatch for endpoints this client does not yet model.
