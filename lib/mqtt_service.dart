import 'dart:convert';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_browser_client.dart';

class MqttService {
  final String host; // z.B. "HA_IP:1884"
  final String username;
  final String password;

  late final MqttBrowserClient client;

  MqttService({
    required this.host,
    required this.username,
    required this.password,
  }) {
    client = MqttBrowserClient('ws://$host/mqtt', 'flutter_web_${DateTime.now().millisecondsSinceEpoch}');
    client.port = 1884; // muss 1884 sein
    client.keepAlivePeriod = 30;
    client.logging(on: false);
    client.onConnected = () => print('MQTT connected');
    client.onDisconnected = () => print('MQTT disconnected');
  }

  Future<void> connect() async {
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(client.clientIdentifier)
        .authenticateAs(username, password)
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);

    try {
      await client.connect();
    } catch (e) {
      client.disconnect();
      rethrow;
    }
  }

  void subscribe(String topic) {
    client.subscribe(topic, MqttQos.atMostOnce);
  }

  Stream<Map<String, dynamic>> messages() {
    return client.updates!.expand((events) => events).map((event) {
      final rec = event.payload as MqttPublishMessage;
      final payload =
          MqttPublishPayload.bytesToStringAsString(rec.payload.message);
      return {
        'topic': event.topic,
        'payload': payload,
        'json': _tryJson(payload),
      };
    });
  }

  void publishJson(String topic, Map<String, dynamic> data) {
    final builder = MqttClientPayloadBuilder();
    builder.addString(jsonEncode(data));
    client.publishMessage(topic, MqttQos.atMostOnce, builder.payload!);
  }

  Map<String, dynamic>? _tryJson(String s) {
    try {
      final x = jsonDecode(s);
      if (x is Map<String, dynamic>) return x;
      return null;
    } catch (_) {
      return null;
    }
  }

  void disconnect() => client.disconnect();
}
