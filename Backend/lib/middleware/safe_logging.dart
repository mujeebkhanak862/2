/// P0-06 — Secret Handling + Log Redaction (request logging half).
///
/// Pehle `bin/server.dart` shelf ke built-in `logRequests()` middleware
/// use karta tha. Woh apne aap mein headers/body log nahi karta (shelf
/// ka default format sirf method/path/status/duration deta hai) — lekin
/// yeh ek **implicit trust** thi kisi third-party library ke default
/// behavior par, koi explicit guarantee ya test nahi. Ab yeh apna
/// chhota sa logging middleware hai jo:
///   1. Explicitly sirf `method`, `path`, `status`, `duration` log karta
///      hai — kabhi bhi headers (Authorization included) ya body nahi.
///   2. Testable hai — `logSink` inject kar sakte hain (default `print`),
///      taaki `test/log_redaction_test.dart` output capture karke assert
///      kar sake ke kabhi koi secret/token leak nahi hota.
library;

import 'dart:async';
import 'package:shelf/shelf.dart';

typedef LogSink = void Function(String message);

/// `logSink` default `print` hai — tests isko override karke output
/// capture karte hain.
Middleware safeRequestLogging({LogSink logSink = print}) {
  return (Handler inner) {
    return (Request request) async {
      final stopwatch = Stopwatch()..start();
      // NOTE: jaan-bujh kar sirf yeh 4 fields — request.headers (jisme
      // Authorization hota hai) ya request body kabhi is closure mein
      // touch nahi hote.
      final method = request.method;
      final path = request.requestedUri.path;

      try {
        final response = await inner(request);
        stopwatch.stop();
        logSink(
            '${DateTime.now().toUtc().toIso8601String()} $method $path '
            '${response.statusCode} ${stopwatch.elapsedMilliseconds}ms');
        return response;
      } catch (e) {
        stopwatch.stop();
        // Exception ka `toString()` yahan log hota hai — agar kabhi
        // koi downstream code exception message mein galti se sensitive
        // data daal de, woh yahan tak pahunch sakta hai. Filhaal poore
        // codebase mein koi bhi exception secret/token interpolate
        // nahi karta (manually verify kiya gaya — `grep` P0-06 audit
        // mein), lekin yeh risk surface hai agar future mein koi naya
        // exception path add ho. Message ko yahan bhi ek length-bound
        // rakhte hain taaki koi bahut bada (potentially payload-leaking)
        // exception string bhi na chhap jaaye.
        final errorSummary = e.toString();
        final truncated = errorSummary.length > 200
            ? '${errorSummary.substring(0, 200)}...(truncated)'
            : errorSummary;
        logSink('${DateTime.now().toUtc().toIso8601String()} $method $path '
            'ERROR $truncated (${stopwatch.elapsedMilliseconds}ms)');
        rethrow;
      }
    };
  };
}
