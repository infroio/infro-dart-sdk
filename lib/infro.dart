/// `infro` — the official Dart client for the INFRO API.
///
/// WHAT THIS EXISTS FOR
///
/// Text is served over an OpenAI-compatible endpoint, so any client that lets
/// you override a base URL will talk to it. What no such client can express is
/// the rest of the platform: an image generation whose response carries
/// `usage.cost`, a video render that is an async job with a signed webhook, a
/// transcription, the catalog, the key's own balance — and INFRO's request
/// extensions (`routing`, `fallbacks`, `logging`, `metadata`).
///
/// Dart is on this list because Flutter is: a mobile app that calls model APIs
/// wants the multimodal surface and the cost figure in the same place, and the
/// alternative is hand-rolled JSON in a widget.
///
/// ```dart
/// import 'package:infro/infro.dart';
///
/// final infro = Infro();   // reads INFRO_API_KEY
///
/// final image = await infro.images.generate(
///   model: 'bfl/flux-2-pro',
///   prompt: 'a lighthouse in fog, 35mm',
/// );
/// print(image['data'][0]['url']);
/// ```
///
/// WHAT IT DELIBERATELY DOES NOT DO
///
/// It does not model providers, because the gateway never names one. It does
/// not expose a provider selection field, because the gateway refuses it with
/// `provider_selection_unsupported`. And it does not retry a request without an
/// idempotency key — see `src/client.dart` for why that is the difference
/// between a retry and a double charge.
library;

import 'package:http/http.dart' as http;

import 'src/client.dart';
import 'src/resources.dart';

export 'src/client.dart' show defaultBaseUrl, packageVersion, backoffFor, InfroTransport;
export 'src/errors.dart';
export 'src/resources.dart';

/// The client.
///
/// `apiKey` falls back to `INFRO_API_KEY` in the environment, because a key in
/// source is a key in version control and the one place a client can make that
/// the harder path is its constructor.
class Infro {
  Infro({
    String? apiKey,
    String? baseUrl,
    Duration timeout = const Duration(minutes: 10),
    int maxRetries = 2,
    Map<String, String>? defaultHeaders,
    http.Client? httpClient,
  }) : this.withTransport(InfroTransport(
          apiKey: apiKey,
          baseUrl: baseUrl,
          timeout: timeout,
          maxRetries: maxRetries,
          defaultHeaders: defaultHeaders,
          httpClient: httpClient,
        ));

  /// Build from a transport directly. Used by the tests and by anyone who needs
  /// to configure the HTTP layer beyond what the constructor exposes.
  Infro.withTransport(this.transport)
      : chat = Chat(transport),
        images = Images(transport),
        videos = Videos(transport),
        jobs = Jobs(transport),
        audio = Audio(transport),
        models = Models(transport),
        keys = Keys(transport),
        requests = Requests(transport);

  /// The transport, exposed so an endpoint this client does not model is still
  /// reachable with the authentication and the retries intact. The gateway
  /// grows faster than a client library, and the alternative to this is
  /// somebody re-implementing both in application code.
  final InfroTransport transport;

  final Chat chat;
  final Images images;
  final Videos videos;
  final Jobs jobs;
  final Audio audio;
  final Models models;
  final Keys keys;
  final Requests requests;

  String get baseUrl => transport.baseUrl;

  void close() => transport.close();
}
