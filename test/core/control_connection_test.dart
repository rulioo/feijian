import 'dart:async';
import 'dart:io';

import 'package:feijian/core/constants.dart';
import 'package:feijian/core/protocol/frame_codec.dart';
import 'package:feijian/core/protocol/payloads.dart';
import 'package:feijian/core/transport/connection_state.dart';
import 'package:feijian/core/transport/control_connection.dart';
import 'package:feijian/core/transport/feijian_server.dart';
import 'package:flutter_test/flutter_test.dart';

import 'transport_harness.dart';

/// A raw socket that has been through the handshake, for driving bytes onto a
/// [ControlConnection] that a real peer would never send.
class RawPeer {
  RawPeer(this.socket, this.server);

  final Socket socket;
  final FeijianServer server;

  void write(List<int> bytes) => socket.add(bytes);

  Future<void> close() async {
    await socket.close();
    await socket.done.catchError((Object _) {});
    await server.dispose();
  }
}

/// Dials [server] with a bare socket — no framework on the client side, so the
/// test controls every byte.
Future<RawPeer> rawDial(FeijianServer server, {String id = 'raw-peer'}) async {
  final Socket socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    server.boundPort!,
  );
  socket.add(FrameCodec.encode(helloFor(id).toFrame()));
  return RawPeer(socket, server);
}

void main() {
  group('handshake', () {
    test('both sides learn who the other is', () async {
      final ConnectionPair pair = await connectedPair(
        outboundId: 'device-aaa',
        inboundId: 'device-bbb',
      );
      addTearDown(pair.close);

      expect(pair.outbound.state, ConnectionState.ready);
      expect(pair.inbound.state, ConnectionState.ready);
      expect(pair.outbound.remoteId, 'device-bbb');
      expect(pair.inbound.remoteId, 'device-aaa');
      expect(pair.outbound.peerHello!.name, 'device-bbb');
      expect(pair.outbound.isOutbound, isTrue);
      expect(pair.inbound.isOutbound, isFalse);
    });

    test('the accepting side answers with the role that was asked for', () async {
      // One listening socket serves both control and data connections
      // (design.md §4.4), so the role cannot come from the server's own
      // configuration — only from the peer's request.
      final ConnectionPair pair = await connectedPair(
        role: ConnectionRole.data,
      );
      addTearDown(pair.close);

      expect(pair.inbound.peerHello!.role, ConnectionRole.data);
    });

    test('our own identity is what the peer is told', () async {
      final ConnectionPair pair = await connectedPair(outboundId: 'device-aaa');
      addTearDown(pair.close);

      expect(pair.inbound.peerHello!.deviceId, 'device-aaa');
      expect(pair.outbound.peerHello!.deviceId, 'device-bbb');
    });

    test('a version mismatch is tolerated rather than refused', () async {
      // §4.3 keeps the framing stable across versions and requires unknown
      // frames to be ignored, so a difference is worth reporting and not worth
      // dropping a peer over.
      final FeijianServer server = FeijianServer(
        selfHello: helloFor('device-bbb'),
        port: 0,
        tuning: testTuning,
      );
      await server.start();
      final Future<ControlConnection> accepted = server.incoming.first;

      final ControlConnection outbound = await ControlConnection.connect(
        address: InternetAddress.loopbackIPv4,
        port: server.boundPort!,
        selfHello: helloFor('device-aaa', version: kProtocolVersion + 7),
        tuning: testTuning,
      );
      final ControlConnection inbound = await accepted;
      addTearDown(() async {
        await outbound.close();
        await inbound.close();
        await server.dispose();
      });

      await waitForReady(outbound);
      expect(outbound.peerHello!.version, kProtocolVersion);
    });

    test('a peer that never says hello is dropped', () async {
      final FeijianServer server = FeijianServer(
        selfHello: helloFor('device-bbb'),
        port: 0,
        tuning: testTuning,
      );
      await server.start();
      final Future<ControlConnection> accepted = server.incoming.first;

      // Connect and say nothing. Anyone on the LAN can do this, so it must not
      // hold a connection open indefinitely.
      final Socket silent = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort!,
      );
      final ControlConnection inbound = await accepted;
      addTearDown(() async {
        silent.destroy();
        await server.dispose();
      });

      expect(
        await waitForClosed(inbound),
        ConnectionClosedReason.handshakeTimeout,
      );
    });

    test('a hello after the handshake cannot rewrite the identity', () async {
      final ConnectionPair pair = await connectedPair();
      addTearDown(pair.close);

      pair.outbound.send(helloFor('impostor').toFrame());
      // A ping behind it proves the frame stream is still healthy, so the
      // assertion below is about the impostor being ignored and not about the
      // connection having died.
      pair.outbound.send(
        MessagePayload(
          msgId: 'm1',
          ts: DateTime(2026, 10, 4, 12),
          text: 'still here',
        ).toFrame(),
      );

      final Frame frame = await pair.inbound.frames.first.timeout(patience);
      expect(frame.type, FrameType.msg);
      expect(pair.inbound.remoteId, 'device-aaa');
      expect(pair.inbound.closeReason, isNull);
    });
  });

  group('framing over a real socket', () {
    test('a hello split across two writes is still understood', () async {
      final FeijianServer server = FeijianServer(
        selfHello: helloFor('device-bbb'),
        port: 0,
        tuning: testTuning,
      );
      await server.start();
      final Future<ControlConnection> accepted = server.incoming.first;

      final List<int> hello = FrameCodec.encode(helloFor('device-aaa').toFrame());
      final Socket raw = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort!,
      );
      // Split inside the header length prefix, the least forgiving place.
      raw.add(hello.sublist(0, 2));
      await raw.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      raw.add(hello.sublist(2));
      await raw.flush();

      final ControlConnection inbound = await accepted;
      addTearDown(() async {
        raw.destroy();
        await inbound.close();
        await server.dispose();
      });

      await waitForReady(inbound);
      expect(inbound.remoteId, 'device-aaa');
    });

    test('a message split across two writes is still understood', () async {
      final List<int> frame = FrameCodec.encode(
        MessagePayload(
          msgId: 'split-1',
          ts: DateTime(2026, 10, 4, 12),
          text: 'hello',
        ).toFrame(),
      );

      final FeijianServer server = FeijianServer(
        selfHello: helloFor('device-bbb'),
        port: 0,
        tuning: testTuning,
      );
      await server.start();
      final Future<ControlConnection> accepted = server.incoming.first;
      final Socket client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort!,
      );
      client.add(FrameCodec.encode(helloFor('device-aaa').toFrame()));
      await client.flush();

      final ControlConnection inbound = await accepted;
      await waitForReady(inbound);
      addTearDown(() async {
        client.destroy();
        await inbound.close();
        await server.dispose();
      });

      final List<Frame> received = <Frame>[];
      inbound.frames.listen(received.add);

      client.add(frame.sublist(0, 7));
      await client.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, isEmpty, reason: 'a partial frame is not a frame');

      client.add(frame.sublist(7));
      await client.flush();

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, hasLength(1));
      expect(
        MessagePayload.from(received.single).value!.text,
        'hello',
        reason: 'the bytes were reassembled, not truncated',
      );
    });

    test('unframeable bytes drop the connection', () async {
      // 0xFFFFFFFF as a header length is far past the 1 MB cap, so the stream is
      // corrupt or hostile and there is no boundary to resynchronise to.
      final FeijianServer server = FeijianServer(
        selfHello: helloFor('device-bbb'),
        port: 0,
        tuning: testTuning,
      );
      await server.start();
      final Future<ControlConnection> accepted = server.incoming.first;
      final RawPeer raw = await rawDial(server);
      final ControlConnection inbound = await accepted;
      await waitForReady(inbound);
      addTearDown(() async {
        await inbound.close();
        await raw.close();
      });

      raw.write(<int>[0xFF, 0xFF, 0xFF, 0xFF, 0x00]);

      expect(
        await waitForClosed(inbound),
        ConnectionClosedReason.protocolError,
      );
    });
  });

  group('what the connection keeps to itself', () {
    test('msg frames are forwarded', () async {
      final ConnectionPair pair = await connectedPair();
      addTearDown(pair.close);

      pair.outbound.send(
        MessagePayload(
          msgId: 'm1',
          ts: DateTime(2026, 10, 4, 12),
          text: 'hi',
        ).toFrame(),
      );

      final Frame frame = await pair.inbound.frames.first.timeout(patience);
      expect(frame.type, FrameType.msg);
      expect(MessagePayload.from(frame).value!.msgId, 'm1');
    });

    test('ping, pong, bye and a repeat hello are not forwarded', () async {
      final ConnectionPair pair = await connectedPair();
      addTearDown(pair.close);

      // One collector for the whole test: `frames` is single-subscription, and
      // keeping it open is what makes "nothing else arrived" assertable.
      final List<Frame> forwarded = <Frame>[];
      final Completer<void> gotSomething = Completer<void>();
      pair.inbound.frames.listen((Frame frame) {
        forwarded.add(frame);
        if (!gotSomething.isCompleted) {
          gotSomething.complete();
        }
      });

      pair.outbound
          .send(HeartbeatPayload(ts: DateTime(2026)).toFrame(FrameType.pong));
      pair.outbound.send(helloFor('impostor').toFrame());
      pair.outbound
          .send(HeartbeatPayload(ts: DateTime(2026)).toFrame(FrameType.ping));
      // A real frame last, so the assertion cannot pass by the connection having
      // died before anything arrived.
      pair.outbound.send(
        MessagePayload(
          msgId: 'm1',
          ts: DateTime(2026, 10, 4, 12),
          text: 'hi',
        ).toFrame(),
      );

      // The msg was written last and TCP preserves order, so by the time it has
      // been decoded every earlier frame has been through the filter too.
      await gotSomething.future.timeout(patience);
      expect(forwarded.single.type, FrameType.msg,
          reason: 'only the msg should surface');
    });

    test('an unknown frame type is ignored, not fatal', () async {
      // §4.3: a newer peer will send frames this build has never heard of, and
      // refusing them would make versions unable to coexist on one network.
      final ConnectionPair pair = await connectedPair();
      addTearDown(pair.close);

      pair.outbound.send(Frame.of('quantum_teleport', <String, Object?>{
        'payload': 'from a future version',
      }));
      pair.outbound.send(
        MessagePayload(
          msgId: 'm1',
          ts: DateTime(2026, 10, 4, 12),
          text: 'after the unknown frame',
        ).toFrame(),
      );

      final Frame frame = await pair.inbound.frames.first.timeout(patience);
      expect(frame.type, FrameType.msg);
      expect(MessagePayload.from(frame).value!.text, 'after the unknown frame');
      expect(pair.inbound.state, ConnectionState.ready);
    });
  });

  group('heartbeat and silence', () {
    test('the connection beats, and a peer that stops answering is dropped',
        () async {
      final FeijianServer server = FeijianServer(
        selfHello: helloFor('device-bbb'),
        port: 0,
        tuning: testTuning,
      );
      await server.start();
      final Future<ControlConnection> accepted = server.incoming.first;
      final RawPeer raw = await rawDial(server);
      final ControlConnection inbound = await accepted;
      await waitForReady(inbound);
      addTearDown(() async {
        await inbound.close();
        await raw.close();
      });

      // Collect what the server sends us. A raw client that answers nothing is
      // exactly what a peer behind a dropped Wi-Fi link looks like: TCP has no
      // reason to report anything, and only the heartbeat notices.
      final List<int> fromServer = <int>[];
      raw.socket.listen(
        (List<int> chunk) => fromServer.addAll(chunk),
        onError: (Object _) {},
        cancelOnError: false,
      );

      expect(
        await waitForClosed(inbound),
        ConnectionClosedReason.idleTimeout,
      );
      expect(
        fromServer,
        isNotEmpty,
        reason: 'the server should have been beating into the silence',
      );
    });
  });

  group('closing', () {
    test('a local close is announced so the peer learns of it', () async {
      // Regression: `destroy()` discards whatever is still buffered, so a `bye`
      // written without a flush never leaves the machine and the peer only
      // finds out when its idle timeout expires ninety seconds later.
      final ConnectionPair pair = await connectedPair();
      addTearDown(pair.close);

      await pair.outbound.close();

      expect(
        await waitForClosed(pair.inbound),
        ConnectionClosedReason.remoteBye,
      );
      expect(pair.outbound.state, ConnectionState.closed);
    });

    test('closing twice is harmless', () async {
      final ConnectionPair pair = await connectedPair();
      addTearDown(pair.server.dispose);

      await pair.outbound.close();
      await pair.outbound.close();
      expect(pair.outbound.closeReason, ConnectionClosedReason.localBye);
    });

    test('a peer that vanishes without a bye is still noticed', () async {
      final FeijianServer server = FeijianServer(
        selfHello: helloFor('device-bbb'),
        port: 0,
        tuning: testTuning,
      );
      await server.start();
      final Future<ControlConnection> accepted = server.incoming.first;
      final RawPeer raw = await rawDial(server);
      final ControlConnection inbound = await accepted;
      await waitForReady(inbound);
      addTearDown(() async {
        await inbound.close();
        await server.dispose();
      });

      // No `bye` — a yanked cable or a killed process, which is the common case.
      raw.socket.destroy();

      expect(
        await waitForClosed(inbound),
        anyOf(
          ConnectionClosedReason.remoteBye,
          ConnectionClosedReason.socketError,
        ),
      );
    });

    test('sending after close is refused rather than silently dropped', () async {
      final ConnectionPair pair = await connectedPair();
      addTearDown(pair.server.dispose);

      await pair.outbound.close();
      expect(pair.outbound.send(Frame.of(FrameType.ping)), isFalse);
      expect(pair.outbound.closeReason, ConnectionClosedReason.localBye);
    });
  });
}
