// Run with:
//
//     INFRO_API_KEY=sk_infro_... dart run example/infro_example.dart
//
// Four calls, one per thing this client exists for that an OpenAI-compatible
// client cannot express: a cost figure on an image, a video render as an async
// job, the route that served a request, and the key's own balance.

import 'dart:io';

import 'package:infro/infro.dart';

Future<void> main() async {
  // The key falls back to INFRO_API_KEY, so it is never in this file.
  final infro = Infro();

  try {
    // Text. `route` is a position in the fallback chain — "primary",
    // "standby_a" — and never a vendor: the gateway does not name upstreams.
    final completion = await infro.chat.completions.create(
      model: 'anthropic/claude-sonnet-5',
      messages: [
        {'role': 'user', 'content': 'Name one thing fog is good for.'},
      ],
    );
    stdout.writeln(completion['choices'][0]['message']['content']);
    stdout.writeln('served by route: ${completion['route']}');

    // Streaming is a Stream, which is what a Flutter widget already consumes.
    // It throws rather than completing quietly if the gateway closes without
    // [DONE] — truncated text that looks complete is worse than an error.
    final stream = infro.chat.completions.createStream(
      model: 'anthropic/claude-sonnet-5',
      messages: [
        {'role': 'user', 'content': 'Write a haiku about fog.'},
      ],
    );
    await for (final chunk in stream) {
      stdout.write(chunk['choices'][0]['delta']['content'] ?? '');
    }
    stdout.writeln();

    // An image, with what it cost on the same response.
    final image = await infro.images.generate(
      model: 'bfl/flux-2-pro',
      prompt: 'a lighthouse in fog, 35mm',
    );
    stdout.writeln(image['data'][0]['url']);
    stdout.writeln('cost: \$${image['usage']['cost']}');

    // Video is an async job: submit, then wait. `wait` polls to a deadline and
    // says the job may still be running rather than pretending it failed.
    final job = await infro.videos.create(
      model: 'google/veo-3.1',
      prompt: 'a lighthouse beam sweeping through fog',
      durationSeconds: 8,
    );
    stdout.writeln('job ${job['id']} is ${job['status']}');

    final finished = await infro.jobs.waitFor(
      job['id'] as String,
      timeout: const Duration(minutes: 10),
    );
    stdout.writeln(finished['output'][0]['url']);

    // What is left on the key.
    final key = await infro.keys.retrieve();
    stdout.writeln('balance: \$${key['balance']}');
  } on BudgetExceededException catch (e) {
    // The taxonomy is types, so this is a branch rather than a string match.
    stderr.writeln('top up first: ${e.message}');
    exitCode = 1;
  } on RateLimitException catch (e) {
    stderr.writeln('slow down: ${e.message}');
    exitCode = 1;
  } on InfroApiException catch (e) {
    stderr.writeln('${e.status} ${e.type}: ${e.message}');
    exitCode = 1;
  } finally {
    infro.close();
  }
}
