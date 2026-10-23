// Sync connectivity probe (diagnostic tool, run manually).
//
// Purpose: when "sync fails on the desktop build", run this to see where the
// traffic actually goes. It prints, step by step:
//   [1] proxy detection  - initSystemProxy() result + *_proxy env vars
//   [2] direct reachability - canReachDirect(host, 443): can we TCP-connect
//       AND complete a TLS handshake with SNI + certificate validation for
//       the real hostname? (true => nothing is rerouted at all). TCP-only is
//       NOT enough: a poisoned resolver often hands out a real foreign IP
//       whose port 443 accepts TCP happily, so a TCP-only probe would wrongly
//       report "reachable" and skip the DoH reroute.
//   [3] system DNS       - what the poisoned local resolver returns
//   [4] DoH resolution   - what DoH returns for the same host (DoH requests
//       are forced DIRECT, never via proxy; see doh_resolver.dart)
//   [5] real HTTPS GET   - through (a) the sync client built by
//       createDirectHttpClient (probe, then DoH direct-connect if needed)
//       and (b) a plain HttpClient (pre-change behavior, baseline)
//
// Reading the output:
//   - (b) works but (a) fails/slow  -> the DoH reroute is the problem.
//   - both fail                     -> local network / proxy is the problem.
//   - [3] returns a non-Cloudflare IP (e.g. 31.13.x / 69.171.x) while [4]
//     returns 104.21.x / 172.67.x -> DNS poisoning, DoH path is required and
//     the probe is what keeps healthy machines on the normal path.
//
// Run: /d/DevTools/flutter/bin/dart run tool/probe_sync.dart
// (Dart lives outside PATH on this machine; HTTPS requests need no extra deps.)

import 'dart:convert';
import 'dart:io';

import 'package:aimindtree_app/data/sync/direct_connect.dart';
import 'package:aimindtree_app/data/sync/doh_resolver.dart';
import 'package:aimindtree_app/data/sync/http_proxy.dart';

/// The Cloudflare Workers relay actually used by the app.
const String kHost = 'aimindtree-sync-relay.tuanx.workers.dev';

/// Budget for each diagnostic HTTP request.
const Duration kRequestTimeout = Duration(seconds: 25);

Future<void> main() async {
  stdout.writeln('[1] init proxy...');
  await initSystemProxy();
  stdout.writeln('    detectedSystemProxy = ${detectedSystemProxy ?? "(none)"}');
  final env = Platform.environment;
  for (final key in <String>[
    'https_proxy',
    'HTTPS_PROXY',
    'http_proxy',
    'HTTP_PROXY',
    'ALL_PROXY',
  ]) {
    final value = env[key];
    if (value != null && value.isNotEmpty) {
      stdout.writeln('    env $key = $value');
    }
  }

  stdout.writeln(
    '[2] direct reachability (TCP + TLS handshake to $kHost:443)...',
  );
  final swProbe = Stopwatch()..start();
  final reachable = await canReachDirect(kHost, 443, kReachabilityProbeTimeout);
  stdout.writeln(
    '    canReachDirect = $reachable (${swProbe.elapsedMilliseconds}ms)'
    '${reachable ? " -> no reroute, plain client used" : " -> DoH path enabled"}',
  );

  stdout.writeln('[3] system DNS lookup...');
  try {
    final list = await InternetAddress.lookup(kHost);
    stdout.writeln('    ${list.map((e) => e.address).toList()}');
  } on Object catch (e) {
    stdout.writeln('    DNS ERROR: $e');
  }

  stdout.writeln('[4] DoH resolve (forced DIRECT, no proxy)...');
  try {
    final ips = await sharedDoHResolver.resolveViaDoH(kHost);
    stdout.writeln('    ips = $ips');
  } on Object catch (e) {
    stdout.writeln('    DoH ERROR: $e');
  }

  await _probe(
    'sync client (createDirectHttpClient)',
    await createDirectHttpClient('https://$kHost'),
  );
  await _probe(
    'plain client (pre-change baseline)',
    HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..findProxy = syncFindProxy,
  );
}

/// Fire one real GET through [client] and print status / timing / body head.
Future<void> _probe(String label, HttpClient client) async {
  stdout.writeln('[5] GET via $label ...');
  final sw = Stopwatch()..start();
  try {
    final req = await client
        .getUrl(Uri.parse('https://$kHost/'))
        .timeout(kRequestTimeout);
    final resp = await req.close().timeout(kRequestTimeout);
    final body = await resp.transform(utf8.decoder).join();
    final head = body.length > 160 ? body.substring(0, 160) : body;
    stdout.writeln(
      '    OK ${resp.statusCode} in ${sw.elapsedMilliseconds}ms len=${body.length}',
    );
    stdout.writeln('    body: $head');
  } on Object catch (e) {
    stdout.writeln(
      '    FAILED in ${sw.elapsedMilliseconds}ms: ${e.runtimeType}: $e',
    );
  } finally {
    client.close(force: true);
  }
}
