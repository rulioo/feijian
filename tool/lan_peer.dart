// A headless Feijian peer. Not part of the app; run it by hand:
//
//   dart run tool/lan_peer.dart --name Study-PC
//   dart compile exe tool/lan_peer.dart -o dist/feijian_peer.exe && dist/feijian_peer.exe
//
// Why it exists: `flutter build windows` needs the MSVC toolchain, and this is
// the only Windows binary this project can produce without one. It is not the
// app — no window, no history, no database. What it *is* is a second real
// device on the LAN: it announces, it is discovered, it accepts a control
// connection, and it sends and acknowledges messages over the same `core/` code
// the app uses. That is enough to test M1 and M2 end to end between a phone
// running the app and a PC, which is otherwise blocked on a multi-gigabyte
// download.
//
// It is not a substitute for that download or for two real devices: nothing
// here exercises the UI, and running it beside the app on one host tests one
// network stack twice. `discovery_probe.dart` says the same thing at more
// length about what a same-host probe can and cannot prove.
//
// Commands, typed at the prompt:
//
//   list            peers, newest state, numbered
//   send <who> <text>   <who> is that number, or an id prefix, or part of a name
//   connect <who>   dial now instead of waiting for the next announce
//   help
//   quit
//
// Options:
//
//   --name <name>   device name shown to others (default: this host's name)
//   --port <port>   TCP listen port (default: 24250, same as the app)
//   --discovery-port <port>   UDP port to announce on (default: 24250)
//   --id <uuid>     stable device id, so a phone recognises it across runs
//
// `--port` and `--discovery-port` are separate because they answer different
// questions. Two peers on one host need different TCP ports so both can listen,
// but the same UDP port so they can hear each other — which is how this tool is
// tested without a second machine.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:feijian/core/constants.dart';
import 'package:feijian/core/discovery/discovery_service.dart';
import 'package:feijian/core/models/peer.dart';
import 'package:feijian/core/protocol/payloads.dart';
import 'package:feijian/core/transport/connection_manager.dart';
import 'package:feijian/core/utils/id.dart';
import 'package:feijian/core/utils/message_dedupe.dart';

Future<void> main(List<String> args) async {
  final String name =
      _option(args, '--name') ?? '${Platform.localHostname} (peer)';
  final int port =
      int.tryParse(_option(args, '--port') ?? '') ?? kDiscoveryPort;
  final int discoveryPort =
      int.tryParse(_option(args, '--discovery-port') ?? '') ?? kDiscoveryPort;
  final String deviceId = _option(args, '--id') ?? newId();

  final HelloPayload hello = HelloPayload(
    role: ConnectionRole.control,
    deviceId: deviceId,
    name: name,
    // Claimed as a desktop and not `unknown`, so the phone renders the icon it
    // would render for the real app rather than the fallback.
    deviceType: DeviceType.windows,
    icon: DeviceIcon.desktop,
    // A concrete port rather than 0: this goes into every `hello` and is what
    // the peer dials back on, and it cannot be discovered from the socket after
    // the payload has already been built.
    port: port,
    version: kProtocolVersion,
  );

  final ConnectionManager manager = ConnectionManager(
    selfHello: hello,
    port: port,
    onLog: (String message) => _log('conn', message),
  );
  final DiscoveryService discovery = DiscoveryService(
    discoveryPort: discoveryPort,
    onLog: (String message) => _log('disc', message),
  );

  // The manager first: its bound port is what the announce has to carry, and a
  // peer that announces a port it is not listening on is discovered and then
  // unreachable, which is a worse failure than not being discovered at all.
  try {
    await manager.start();
  } on SocketException catch (error) {
    stderr.writeln(
      'Cannot listen on TCP $port: ${error.osError?.message ?? error.message}\n'
      'Another copy of Feijian is probably running. Start this one with '
      '--port <other> — but note that a peer on a different port is still '
      'discovered, since the announce carries it.',
    );
    exitCode = 1;
    return;
  }

  discovery.updateSelf(
    Peer(
      id: deviceId,
      name: name,
      deviceType: DeviceType.windows,
      icon: DeviceIcon.desktop,
      os: 'Windows (headless peer)',
      lastPort: port,
      isOnline: true,
    ),
  );
  await discovery.start();

  // --- Wire ---------------------------------------------------------------
  final MessageDedupe dedupe = MessageDedupe();

  manager.peerConnected.listen((String peerId) {
    _say('connected to ${_describe(peerId, discovery)}');
  });
  manager.peerLost.listen((PeerConnectionLost lost) {
    // The enum name, not a `wire` value: this reason never goes on the wire, it
    // is only ever the local side's own diagnosis.
    _say('lost ${_describe(lost.peerId, discovery)} (${lost.reason.name})');
  });
  manager.delivered.listen((MessageDelivered d) {
    _say('delivered ${d.msgId.substring(0, 8)} to ${_describe(d.peerId, discovery)}');
  });
  manager.deliveryFailed.listen((MessageDeliveryFailed f) {
    _say(
      'gave up on ${f.msgId.substring(0, 8)} to '
      '${_describe(f.peerId, discovery)} after ${f.attempts} attempts',
    );
  });

  manager.incoming.listen((IncomingMessage incoming) {
    final String from = _describe(incoming.peerId, discovery);
    final bool isNew = dedupe.isNew(incoming.payload.msgId);
    // The app writes the message here, and only acks once the write is durable
    // (§4.5: an ack means "I have this and it will survive a crash"). This tool
    // has nothing to lose, so it acks at once — but it still acks a duplicate,
    // because the sender is retrying precisely because it never saw the first
    // ack, and staying quiet would leave it retrying a message that arrived.
    final bool acked = manager.sendAck(incoming.peerId, incoming.payload.msgId);
    if (!acked) {
      _say('could not ack ${incoming.payload.msgId.substring(0, 8)}');
      return;
    }
    if (isNew) {
      _say('<$from> ${incoming.payload.text}');
    } else {
      _say('(duplicate from $from, acked again)');
    }
  });

  // Auto-connect, exactly as the app does: a device that is announcing is a
  // device worth holding a control connection to, and messages to a peer with
  // no connection are refused rather than queued for it.
  discovery.changes.listen((void _) {
    for (final Peer peer in discovery.table.peers) {
      if (!peer.isOnline || peer.lastIp == null) {
        continue;
      }
      manager.requireConnection(
        peer.id,
        address: InternetAddress.tryParse(peer.lastIp!)!,
        port: peer.lastPort,
      );
    }
  });

  stdout.writeln(
    '\n'
    'Feijian headless peer\n'
    '  name  $name\n'
    '  id    $deviceId\n'
    '  tcp   $port\n'
    '  udp   $discoveryPort  (multicast $kMulticastGroup)\n'
    '  type "help" for commands, "quit" to stop\n',
  );
  _printPeers(discovery);

  // Ctrl+C ends it the same way `quit` does, so a stopped peer sends its `bye`
  // rather than leaving the other side waiting out the idle timeout.
  final StreamSubscription<ProcessSignal>? interrupt = _watchInterrupt();

  await _repl(manager, discovery);
  await interrupt?.cancel();
  await discovery.dispose();
  await manager.dispose();
}

/// The prompt loop. Ends on `quit` or on end of input, which is what a piped
/// stdin does: `echo "list" | feijian_peer.exe` runs one command and stops.
Future<void> _repl(ConnectionManager manager, DiscoveryService discovery) async {
  await for (final String line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    final List<String> parts = trimmed.split(RegExp(r'\s+'));
    final String command = parts.first.toLowerCase();

    switch (command) {
      case 'list':
      case 'l':
      case 'ls':
        _printPeers(discovery);
      case 'send':
      case 's':
        if (parts.length < 3) {
          stdout.writeln('usage: send <who> <text>');
          break;
        }
        final Peer? target = _resolve(parts[1], discovery);
        if (target == null) {
          break;
        }
        await _send(manager, target, parts.skip(2).join(' '));
      case 'connect':
      case 'c':
        if (parts.length < 2) {
          stdout.writeln('usage: connect <who>');
          break;
        }
        final Peer? target = _resolve(parts[1], discovery);
        if (target == null || target.lastIp == null) {
          break;
        }
        manager.requireConnection(
          target.id,
          address: InternetAddress.tryParse(target.lastIp!)!,
          port: target.lastPort,
        );
        stdout.writeln('dialling ${target.name} at ${target.lastIp}…');
      case 'help':
      case 'h':
      case '?':
        stdout.writeln(
          '  list                 peers, numbered\n'
          '  send <who> <text>    <who> is a number, an id prefix, or a name\n'
          '  connect <who>        dial now\n'
          '  help / quit',
        );
      case 'quit':
      case 'q':
      case 'exit':
        return;
      default:
        stdout.writeln('unknown command "$command" — try "help"');
    }
  }
}

/// Stores nothing and so owes nothing: the row is written before the send in
/// the app, and here the "row" is this line of output.
Future<void> _send(
  ConnectionManager manager,
  Peer target,
  String text,
) async {
  final String body = text.trim();
  if (body.isEmpty) {
    stdout.writeln('nothing to send');
    return;
  }
  final String msgId = newId();
  final bool sent = manager.sendMessage(
    target.id,
    MessagePayload(msgId: msgId, ts: DateTime.now(), text: body),
  );
  if (sent) {
    stdout.writeln('-> ${target.name}: $body');
    return;
  }
  // Refused rather than queued: this tool has no database, so a message it
  // cannot send now would be silently lost. Saying so is the honest version.
  stdout.writeln(
    'no connection to ${target.name} — run "connect ${target.name}" and '
    'wait for it to come up',
  );
}

void _printPeers(DiscoveryService discovery) {
  final List<Peer> peers = discovery.table.peers;
  if (peers.isEmpty) {
    stdout.writeln('  (no peers yet — another device announcing on this LAN '
        'should appear within a few seconds)');
    return;
  }
  stdout.writeln('  ${discovery.table.onlineCount}/${peers.length} online');
  for (int i = 0; i < peers.length; i++) {
    final Peer peer = peers[i];
    stdout.writeln(
      '  ${i + 1}) ${peer.name}'
      '${peer.isOnline ? '' : ' (offline)'}'
      '  ${peer.lastIp ?? '?'}:${peer.lastPort ?? '?'}'
      '  ${peer.deviceType.wire}'
      '${peer.os == null ? '' : '  ${peer.os}'}'
      '  ${peer.id.substring(0, 8)}',
    );
  }
}

/// A number, an id prefix, or part of a name — in that order.
///
/// The number is an index into the listing above, which the peer table keeps
/// ordered (online first, then by name), so it only moves when a device goes
/// offline or is renamed. The name fallback is why the resolved peer is echoed
/// back before anything is sent: a substring can match more than one device,
/// and sending a test message to the wrong one is confusing rather than
/// dangerous, but silent.
Peer? _resolve(String who, DiscoveryService discovery) {
  final List<Peer> peers = discovery.table.peers;
  final int? index = int.tryParse(who);
  if (index != null) {
    if (index < 1 || index > peers.length) {
      stdout.writeln('no peer $index — run "list"');
      return null;
    }
    return peers[index - 1];
  }

  final String needle = who.toLowerCase();
  final List<Peer> matches = peers
      .where((Peer p) =>
          p.id.startsWith(needle) || p.name.toLowerCase().contains(needle))
      .toList();
  if (matches.isEmpty) {
    stdout.writeln('no peer matching "$who" — run "list"');
    return null;
  }
  if (matches.length > 1) {
    stdout.writeln(
      '"$who" matches ${matches.length}: '
      '${matches.map((Peer p) => p.name).join(', ')} — use the number instead',
    );
    return null;
  }
  return matches.single;
}

String _describe(String peerId, DiscoveryService discovery) {
  final Peer? peer = discovery.table[peerId];
  // The table drops a peer a minute after it stops announcing, but a connection
  // to it can outlive that. The id is the fallback rather than "unknown",
  // because it is what the other side printed about itself.
  return peer == null ? peerId.substring(0, 8) : peer.name;
}

StreamSubscription<ProcessSignal>? _watchInterrupt() {
  try {
    return ProcessSignal.sigint.watch().listen((_) {
      stdout.writeln('\nstopping…');
      exit(0);
    });
  } on Object {
    // Not every console on every platform delivers SIGINT to a Dart process.
    // Ctrl+C still ends it either way; only the graceful goodbye is lost.
    return null;
  }
}

String? _option(List<String> args, String flag) {
  final int at = args.indexOf(flag);
  if (at < 0 || at + 1 >= args.length) {
    return null;
  }
  return args[at + 1];
}

void _say(String message) => stdout.writeln('${_clock()}  $message');

void _log(String tag, String message) =>
    stdout.writeln('${_clock()}  [$tag] $message');

String _clock() {
  final DateTime now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
}
