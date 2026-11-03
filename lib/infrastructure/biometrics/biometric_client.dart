import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

class BiometricClient {
  late WebSocketChannel _channel;
  
  // Singleton
  static final BiometricClient _instance = BiometricClient._internal();
  factory BiometricClient() => _instance;
  BiometricClient._internal();

  void conectar() {
    _channel = WebSocketChannel.connect(
      Uri.parse('ws://localhost:8080'),
    );

    _channel.stream.listen((message) {
      final data = jsonDecode(message);
      if (data['event'] == 'HUELLA_LEIDA') {
        final template = data['template'];
        _procesarHuella(template);
      }
    },
    onError: (error) => print('Error en Lector: $error'),
    onDone: () {
      print('Lector desconectado. Reconectando...');
      Future.delayed(Duration(seconds: 3), conectar); // Auto-reconexión
    });
  }

  void _procesarHuella(String template) {
    // TODO: Invocar Caso de Uso: VerificarAccesoUseCase
    print("Huella detectada en UI, procesando hash: $template");
    // Aquí dispararemos el cambio de estado en la UI a "Acceso Permitido" o "Denegado"
  }
}