/// The documented error taxonomy, as exceptions a caller can catch.
///
/// The gateway publishes a closed set of `error.type` values with an HTTP
/// status for each. A client that threw one exception for all of them would
/// make the most common decision — "should I retry this?" — a substring match
/// on a message, which is what breaks the moment a message is reworded.
///
/// So there is a class per family, and [InfroApiException.retryable] is derived
/// from the *status* rather than the type: the status is what the docs key
/// retry guidance on, and it is what a proxy in front of INFRO preserves even
/// if it rewrites the body.
library;

/// The four statuses the docs name as retryable, and no others.
///
/// Deliberately not `>= 500`. A `500 internal_error` is a defect in the
/// gateway's own code: retrying it fails identically and turns one bug into a
/// retry storm. `502` and `503` are upstream conditions a second attempt
/// genuinely re-rolls.
const Set<int> retryableStatuses = {408, 429, 502, 503};

/// The one code that overrides its own status.
///
/// `no_provider_connected` is a 503 saying the organization has no connected
/// provider able to serve the model. Unlike every other 503, a second attempt
/// cannot change that — it stays true until somebody connects a provider in
/// the console, which the message tells them to do. Retrying spends the whole
/// backoff to arrive at advice the first response already carried, and it is
/// the error a new organization is most likely to meet.
const Set<String> neverRetryCodes = {'no_provider_connected'};

/// Base class for everything this package throws.
sealed class InfroException implements Exception {
  const InfroException(this.message);

  final String message;

  @override
  String toString() => 'InfroException: $message';
}

/// A response the gateway actually produced.
class InfroApiException extends InfroException {
  const InfroApiException(
    super.message, {
    this.type = 'unknown',
    this.code,
    required this.status,
    this.requestId,
    this.retryAfter,
  });

  /// One of the published `error.type` values, or `unknown`.
  final String type;

  /// An upstream-supplied sub-code, when there is one. Often null.
  final String? code;

  final int status;

  /// `req_…`. The first thing support asks for.
  final String? requestId;

  /// What the server asked us to wait, when it said.
  final Duration? retryAfter;

  /// Whether trying again could plausibly succeed. Keyed on status.
  bool get retryable =>
      !(code != null && neverRetryCodes.contains(code)) &&
      retryableStatuses.contains(status);

  @override
  String toString() {
    final parts = <String>['$runtimeType: $message', 'status=$status', 'type=$type'];
    if (code != null) parts.add('code=$code');
    if (requestId != null) parts.add('request_id=$requestId');
    return parts.join(' ');
  }
}

/// 401. The key is missing, malformed, or revoked.
class AuthenticationException extends InfroApiException {
  const AuthenticationException(super.message,
      {super.type, super.code, required super.status, super.requestId, super.retryAfter});
}

/// 403. The key is valid and not allowed to do this.
class PermissionDeniedException extends InfroApiException {
  const PermissionDeniedException(super.message,
      {super.type, super.code, required super.status, super.requestId, super.retryAfter});
}

/// 400. Something about the request itself.
class InvalidRequestException extends InfroApiException {
  const InvalidRequestException(super.message,
      {super.type, super.code, required super.status, super.requestId, super.retryAfter});
}

/// 404. No such model, job, or request.
class NotFoundException extends InfroApiException {
  const NotFoundException(super.message,
      {super.type, super.code, required super.status, super.requestId, super.retryAfter});
}

/// 429. Honour [retryAfter]; the client already does.
class RateLimitException extends InfroApiException {
  const RateLimitException(super.message,
      {super.type, super.code, required super.status, super.requestId, super.retryAfter});
}

/// 402. A budget you set has no room for this request.
///
/// Not a funding problem: INFRO holds no balance and takes no part in what
/// your provider charges. The message names the ceiling that refused it.
class BudgetExceededException extends InfroApiException {
  const BudgetExceededException(super.message,
      {super.type, super.code, required super.status, super.requestId, super.retryAfter});
}

/// 502. Every route for the model failed.
class UpstreamException extends InfroApiException {
  const UpstreamException(super.message,
      {super.type, super.code, required super.status, super.requestId, super.retryAfter});
}

/// 503. No route was eligible — a policy or an outage, not a bad request.
class NoAvailableProviderException extends InfroApiException {
  const NoAvailableProviderException(super.message,
      {super.type, super.code, required super.status, super.requestId, super.retryAfter});
}

/// 408. The upstream did not answer in time.
class InfroTimeoutException extends InfroApiException {
  const InfroTimeoutException(super.message,
      {super.type, super.code, required super.status, super.requestId, super.retryAfter});
}

/// 500. A defect on our side. Not retryable — it fails identically.
class InternalException extends InfroApiException {
  const InternalException(super.message,
      {super.type, super.code, required super.status, super.requestId, super.retryAfter});
}

/// A failure that never reached the gateway: DNS, TLS, a dropped socket.
///
/// Separate from [InfroApiException] because the remedies differ and so does
/// the blame: there is no request id, no type, and nothing INFRO can tell you
/// about it. Retryable, because a connection that failed to open may open.
class InfroConnectionException extends InfroException {
  const InfroConnectionException(super.message, [this.cause]);

  final Object? cause;

  bool get retryable => true;

  @override
  String toString() => 'InfroConnectionException: $message';
}

InfroApiException _construct(
  String? type,
  int status,
  String message, {
  String? code,
  String? requestId,
  Duration? retryAfter,
}) {
  final resolved = type ?? _typeForStatus(status);
  return switch (resolved) {
    'authentication_error' => AuthenticationException(message,
        type: resolved, code: code, status: status, requestId: requestId, retryAfter: retryAfter),
    'permission_denied' => PermissionDeniedException(message,
        type: resolved, code: code, status: status, requestId: requestId, retryAfter: retryAfter),
    'invalid_request_error' => InvalidRequestException(message,
        type: resolved, code: code, status: status, requestId: requestId, retryAfter: retryAfter),
    'not_found_error' => NotFoundException(message,
        type: resolved, code: code, status: status, requestId: requestId, retryAfter: retryAfter),
    'rate_limit_exceeded' => RateLimitException(message,
        type: resolved, code: code, status: status, requestId: requestId, retryAfter: retryAfter),
    'budget_exceeded' => BudgetExceededException(message,
        type: resolved, code: code, status: status, requestId: requestId, retryAfter: retryAfter),
    'upstream_error' => UpstreamException(message,
        type: resolved, code: code, status: status, requestId: requestId, retryAfter: retryAfter),
    'no_available_provider' => NoAvailableProviderException(message,
        type: resolved, code: code, status: status, requestId: requestId, retryAfter: retryAfter),
    'timeout_error' => InfroTimeoutException(message,
        type: resolved, code: code, status: status, requestId: requestId, retryAfter: retryAfter),
    'internal_error' => InternalException(message,
        type: resolved, code: code, status: status, requestId: requestId, retryAfter: retryAfter),
    _ => InfroApiException(message,
        type: resolved, code: code, status: status, requestId: requestId, retryAfter: retryAfter),
  };
}

/// The type a status implies, for a body that is not the documented envelope.
///
/// A proxy or a load balancer in front of INFRO can return HTML, and the
/// exception still has to be the right class.
String _typeForStatus(int status) => switch (status) {
      400 => 'invalid_request_error',
      401 => 'authentication_error',
      402 => 'budget_exceeded',
      403 => 'permission_denied',
      404 => 'not_found_error',
      408 => 'timeout_error',
      429 => 'rate_limit_exceeded',
      500 => 'internal_error',
      502 => 'upstream_error',
      503 => 'no_available_provider',
      _ => 'unknown',
    };

/// Build the right exception from a response the gateway produced.
InfroApiException errorFromResponse(
  int status,
  Object? body,
  Map<String, String> headers,
) {
  final envelope = body is Map ? body['error'] : null;
  final type = envelope is Map ? envelope['type'] as String? : null;
  final message = (envelope is Map ? envelope['message'] as String? : null) ??
      'INFRO request failed with status $status';

  final retryAfterRaw = _header(headers, 'retry-after');
  final retryAfterSeconds = retryAfterRaw == null ? null : int.tryParse(retryAfterRaw);

  return _construct(
    type,
    status,
    message,
    code: envelope is Map ? envelope['code'] as String? : null,
    requestId: _header(headers, 'x-infro-request-id'),
    retryAfter: retryAfterSeconds == null ? null : Duration(seconds: retryAfterSeconds),
  );
}

String? _header(Map<String, String> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name) return entry.value;
  }
  return null;
}
