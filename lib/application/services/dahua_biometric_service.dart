import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class DahuaBiometricService {
  static final DahuaBiometricService _instance =
      DahuaBiometricService._internal();
  factory DahuaBiometricService() => _instance;
  DahuaBiometricService._internal();

  // --- CREDENCIALES Y RED DEL SISTEMA INDEPENDIENTE DAHUA ---
  String ip = '192.168.2.108';
  String mascaraSubred = '255.255.255.0';
  String puertaEnlace = '192.168.2.1';
  int port = 80;
  String username = 'admin';
  String password = 'Billblas';

  bool _escuchando = false;
  bool get estaConectado => _escuchando;

  bool _modoCapturaNuevoSocio = false;
  bool _capturaSensorActiva = false;
  bool get enModoCapturaNuevoSocio => _modoCapturaNuevoSocio;

  String? _userIdEnCapturaActual;
  String? _nombreEnCapturaActual;

  bool _sincronizacionMasivaInicialRealizada = false;
  dynamic _rpcSessionId;
  int _rpcRequestId = 1;

  Timer? _pollingCapturaTimer;
  Set<String> _usuariosPreviosEnLector = {};
  String? _ultimoLogIdConocido;

  DateTime? _ultimaLecturaEmitida;
  HttpClient? _eventHttpClient;
  HttpServer? _localWsServer;
  final List<WebSocket> _wsClients = [];

  final StreamController<Map<String, dynamic>> _eventosController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get eventosStream => _eventosController.stream;

  Future<bool> configurarYConectar({
    required String nuevaIp,
    required int nuevoPuerto,
    required String nuevoUsuario,
    required String nuevaPassword,
    bool forzarReconexion = false,
  }) async {
    final String ipLimpia = nuevaIp.trim();
    final String ipFinal =
        (ipLimpia.isEmpty || ipLimpia == '192.168.1.108')
            ? '192.168.2.108'
            : ipLimpia;
    final int puertoFinal = nuevoPuerto > 0 ? nuevoPuerto : 80;
    final String userFinal =
        nuevoUsuario.trim().isEmpty ? 'admin' : nuevoUsuario.trim();

    final String passRecibida = nuevaPassword.trim();
    final String passFinal =
        (passRecibida.isEmpty || passRecibida == 'admin123')
            ? 'Billblas'
            : passRecibida;

    final bool cambiaronCredenciales = ip != ipFinal ||
        port != puertoFinal ||
        username != userFinal ||
        password != passFinal;

    ip = ipFinal;
    port = puertoFinal;
    username = userFinal;
    password = passFinal;

    await iniciarServidorWebSocketLocal();

    if (cambiaronCredenciales || forzarReconexion) {
      _rpcSessionId = null;
      await detenerEscucha();
    }

    final ok = await probarConexion();
    if (ok) {
      await _iniciarSesionRpcWeb2();
      await _configurarAudioLector();
    }

    if (!_escuchando) {
      iniciarEscuchaEventosEnVivo();
    }
    return ok;
  }

  Future<void> _configurarAudioLector() async {
    try {
      const String fraseEncoded =
          'Verificacion%20exitosa%20bienvenidos%20a%20Thor%20Gym';
      await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/configManager.cgi?action=setConfig'
        '&AccessControlCustomPrompt[0].SuccessPrompt=$fraseEncoded'
        '&AudioOutputVolume[0]=95',
        timeout: const Duration(seconds: 3),
      );
    } catch (_) {}
  }

  /// Autenticación nativa con el motor Web Service 2.0 (V3.002) mediante /RPC2_Login usando 'Billblas'
  Future<dynamic> _iniciarSesionRpcWeb2() async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('http://$ip:$port/RPC2_Login');

      final req1 = await client.postUrl(uri);
      req1.headers.chunkedTransferEncoding = false;
      final body1Str = jsonEncode({
        'method': 'global.login',
        'params': {
          'userName': username,
          'password': '',
          'clientType': 'Web3.0',
        },
        'id': _rpcRequestId++,
      });
      final bytes1 = utf8.encode(body1Str);
      req1.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
      req1.contentLength = bytes1.length;
      req1.add(bytes1);

      final res1 = await req1.close().timeout(const Duration(seconds: 4));
      final resp1Text = await utf8.decodeStream(res1);
      final Map<String, dynamic> json1 = jsonDecode(resp1Text);

      final dynamic session = json1['session'];
      final Map<String, dynamic>? params =
          json1['params'] is Map<String, dynamic>
              ? json1['params'] as Map<String, dynamic>
              : null;

      if (session == null || params == null) return null;

      final String realm = (params['realm'] ?? '').toString();
      final String random = (params['random'] ?? '').toString();

      final String pwdHash1 =
          _md5Hex('$username:$realm:$password').toUpperCase();
      final String pwdHash2 =
          _md5Hex('$username:$random:$pwdHash1').toUpperCase();

      final req2 = await client.postUrl(uri);
      req2.headers.chunkedTransferEncoding = false;
      final body2Str = jsonEncode({
        'method': 'global.login',
        'params': {
          'userName': username,
          'password': pwdHash2,
          'clientType': 'Web3.0',
          'authorityType': params['encryption']?.toString() ?? 'Default',
          'passwordType': 'Default',
        },
        'id': _rpcRequestId++,
        'session': session,
      });
      final bytes2 = utf8.encode(body2Str);
      req2.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
      req2.contentLength = bytes2.length;
      req2.add(bytes2);

      final res2 = await req2.close().timeout(const Duration(seconds: 4));
      final resp2Text = await utf8.decodeStream(res2);
      final Map<String, dynamic> json2 = jsonDecode(resp2Text);

      if (json2['result'] == true) {
        _rpcSessionId = json2['session'] ?? session;
        return _rpcSessionId;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>?> _ejecutarMetodoRpc2(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_rpcSessionId == null) {
      await _iniciarSesionRpcWeb2();
    }
    if (_rpcSessionId == null) return null;

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    try {
      final uri = Uri.parse('http://$ip:$port/RPC2');
      final req = await client.postUrl(uri);
      req.headers.chunkedTransferEncoding = false;

      final payload = jsonEncode({
        'method': method,
        'params': params,
        'id': _rpcRequestId++,
        'session': _rpcSessionId,
      });
      final bytes = utf8.encode(payload);
      req.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
      req.contentLength = bytes.length;
      req.add(bytes);

      final res = await req.close().timeout(const Duration(seconds: 5));
      final text = await utf8.decodeStream(res);
      final Map<String, dynamic> decoded = jsonDecode(text);

      if (decoded['result'] == false &&
          decoded['error'] != null &&
          decoded['error'].toString().contains('InvalidSession')) {
        _rpcSessionId = null;
        await _iniciarSesionRpcWeb2();
        if (_rpcSessionId != null) {
          final reqRetry = await client.postUrl(uri);
          reqRetry.headers.chunkedTransferEncoding = false;
          final payloadRetry = jsonEncode({
            'method': method,
            'params': params,
            'id': _rpcRequestId++,
            'session': _rpcSessionId,
          });
          final bytesRetry = utf8.encode(payloadRetry);
          reqRetry.headers.set(
            HttpHeaders.contentTypeHeader,
            'application/json; charset=utf-8',
          );
          reqRetry.contentLength = bytesRetry.length;
          reqRetry.add(bytesRetry);
          final resRetry = await reqRetry.close().timeout(
            const Duration(seconds: 5),
          );
          final textRetry = await utf8.decodeStream(resRetry);
          return jsonDecode(textRetry) as Map<String, dynamic>;
        }
      }
      return decoded;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Reproduce por la salida de audio del lector (192.168.2.108) y del sistema:
  /// "Verificación exitosa, bienvenidos a Thor Gym"
  Future<void> reproducirAudioBienvenidaThorGym([
    String? textoPersonalizado,
  ]) async {
    final String frase = textoPersonalizado ??
        'Verificación exitosa, bienvenidos a Thor Gym';

    try {
      final tempDir = Directory.systemTemp;
      final String rutaWav =
          '${tempDir.path}${Platform.pathSeparator}thor_gym_voice.wav';
      final String rutaEscapada = rutaWav.replaceAll("'", "''");
      final String fraseEscapada = frase.replaceAll("'", "''");

      final String scriptPs = '''
Add-Type -AssemblyName System.Speech;
\$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer;
\$synth.Rate = 0;
\$synth.Volume = 100;
\$format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(8000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono);
\$synth.SetOutputToWaveFile('$rutaEscapada', \$format);
\$synth.Speak('$fraseEscapada');
\$synth.SetOutputToDefaultAudioDevice();
\$synth.Speak('$fraseEscapada');
\$synth.Dispose();
''';

      await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        scriptPs,
      ]);

      final archivoWav = File(rutaWav);
      if (await archivoWav.exists()) {
        final Uint8List wavBytes = await archivoWav.readAsBytes();
        final Uint8List pcmBytes =
            wavBytes.length > 44 ? wavBytes.sublist(44) : wavBytes;
        await _enviarAudioAlAltavozDahua(pcmBytes);
      }
    } catch (_) {}
  }

  Future<void> _enviarAudioAlAltavozDahua(Uint8List audioBytes) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 4);
    const String path =
        '/cgi-bin/audio.cgi?action=postAudio&httptype=singlepart&channel=1';

    try {
      final uri = Uri.parse('http://$ip:$port$path');
      final req1 = await client.openUrl('POST', uri);
      req1.headers.chunkedTransferEncoding = false;
      req1.contentLength = 0;
      final res1 = await req1.close().timeout(const Duration(seconds: 3));
      await res1.drain();

      if (res1.statusCode == 401) {
        final wwwAuth = res1.headers.value(HttpHeaders.wwwAuthenticateHeader);
        if (wwwAuth != null) {
          final authHeader = _construirCabeceraDigest(
            wwwAuth: wwwAuth,
            method: 'POST',
            uri: path,
          );

          final req2 = await client.openUrl('POST', uri);
          req2.headers.chunkedTransferEncoding = false;
          req2.headers.set(HttpHeaders.authorizationHeader, authHeader);
          req2.headers.set(HttpHeaders.contentTypeHeader, 'Audio/PCM');
          req2.contentLength = audioBytes.length;
          req2.add(audioBytes);

          final res2 = await req2.close().timeout(const Duration(seconds: 5));
          await res2.drain();
        }
      }
    } catch (_) {
    } finally {
      client.close(force: true);
    }
  }

  /// Calcula el siguiente ID numérico libre verificando tanto la BD como los usuarios ya existentes en el lector
  Future<String> obtenerSiguienteIdDisponibleEnLector(
    String idSugeridoPorBd,
  ) async {
    int maxId = int.tryParse(idSugeridoPorBd.trim()) ?? 2;
    try {
      final idsEnLector = await obtenerUserIdsEnLector();
      for (final idStr in idsEnLector) {
        final val = int.tryParse(idStr.trim());
        if (val != null && val < 100000 && val >= maxId) {
          maxId = val + 1;
        }
      }
    } catch (_) {}
    return maxId.toString();
  }

  /// Pre-registra al usuario en la memoria interna del lector independiente Dahua
  /// y activa la espera/captura de huella (sin encender nunca la cámara facial).
  Future<void> activarModoCapturaNuevoSocio({
    String? userIdPreRegistro,
    String? nombrePreRegistro,
  }) async {
    _modoCapturaNuevoSocio = true;
    _ultimaLecturaEmitida = null;
    _userIdEnCapturaActual = userIdPreRegistro?.trim();
    _nombreEnCapturaActual =
        (nombrePreRegistro != null && nombrePreRegistro.trim().isNotEmpty)
            ? nombrePreRegistro.trim()
            : 'Socio ${_userIdEnCapturaActual ?? ""}';

    if (!_escuchando) {
      iniciarEscuchaEventosEnVivo();
    }

    _usuariosPreviosEnLector = await obtenerUserIdsEnLector();
    _ultimoLogIdConocido = await _obtenerUltimoRecNoDelLector();

    // Crear primero al usuario dentro de la memoria del lector Dahua
    if (_userIdEnCapturaActual != null && _userIdEnCapturaActual!.isNotEmpty) {
      await _crearUsuarioEnSistemaLector(
        userId: _userIdEnCapturaActual!,
        nombre: _nombreEnCapturaActual!,
      );
    }

    _iniciarPollingCapturaTresToques(_userIdEnCapturaActual);
    unawaited(solicitarEscaneoTresVecesEnLector());
  }

  void desactivarModoCapturaNuevoSocio() {
    _modoCapturaNuevoSocio = false;
    _capturaSensorActiva = false;
    _pollingCapturaTimer?.cancel();
    _pollingCapturaTimer = null;
  }

  void _iniciarPollingCapturaTresToques(String? userIdEsperado) {
    _pollingCapturaTimer?.cancel();
    _pollingCapturaTimer = Timer.periodic(
      const Duration(milliseconds: 800),
      (timer) async {
        if (!_modoCapturaNuevoSocio) {
          timer.cancel();
          return;
        }

        try {
          // 1. Verificar si se registró un toque en el log interno del lector
          final nuevoEventoLog = await _verificarNuevoToqueEnLogDelLector();
          if (nuevoEventoLog != null && _modoCapturaNuevoSocio) {
            final String uidLog = (nuevoEventoLog['user_id'] ?? '').toString();
            final String idFinal = uidLog.isNotEmpty
                ? uidLog
                : (userIdEsperado ?? 'HUELLA_NUEVA_SENSOR');
            final String? pkt = nuevoEventoLog['packet_data']?.toString();

            if (pkt != null &&
                pkt.isNotEmpty &&
                idFinal != 'HUELLA_NUEVA_SENSOR') {
              await _guardarHuellaEnCasilla1ConCoaccion(
                userId: idFinal,
                packetData: pkt,
              );
            }

            _emitirEvento({
              'event': 'HUELLA_LEIDA',
              'template': idFinal,
              'id_huella': idFinal,
              'user_id': idFinal,
              'packet_data': pkt,
              'toque_actual': 3,
              'total_toques': 3,
              'es_huella_nueva': uidLog.isEmpty,
              'coaccion_activa': true,
              'metodo_biometrico': 'HUELLA',
              'timestamp': DateTime.now().toIso8601String(),
            }, ignorarDebounce: true);
            return;
          }

          // 2. Verificar si el usuario pre-creado ya tiene su PacketData cargado en el lector
          if (userIdEsperado != null && userIdEsperado.trim().isNotEmpty) {
            final pkt = await obtenerPacketDataDesdeDahua(
              userIdEsperado.trim(),
            );
            if (pkt != null && pkt.isNotEmpty && _modoCapturaNuevoSocio) {
              await _guardarHuellaEnCasilla1ConCoaccion(
                userId: userIdEsperado.trim(),
                packetData: pkt,
              );

              _emitirEvento({
                'event': 'HUELLA_LEIDA',
                'template': userIdEsperado.trim(),
                'id_huella': userIdEsperado.trim(),
                'user_id': userIdEsperado.trim(),
                'packet_data': pkt,
                'toque_actual': 3,
                'total_toques': 3,
                'es_huella_nueva': false,
                'coaccion_activa': true,
                'metodo_biometrico': 'HUELLA',
                'timestamp': DateTime.now().toIso8601String(),
              }, ignorarDebounce: true);
              return;
            }
          }

          // 3. Verificar si se cargó una huella en cualquier usuario nuevo del lector
          final actuales = await obtenerUserIdsEnLector();
          for (final uid in actuales) {
            if (!_usuariosPreviosEnLector.contains(uid)) {
              final pkt = await obtenerPacketDataDesdeDahua(uid);
              if (pkt != null && pkt.isNotEmpty && _modoCapturaNuevoSocio) {
                _usuariosPreviosEnLector.add(uid);
                await _guardarHuellaEnCasilla1ConCoaccion(
                  userId: uid,
                  packetData: pkt,
                );
                _emitirEvento({
                  'event': 'HUELLA_LEIDA',
                  'template': uid,
                  'id_huella': uid,
                  'user_id': uid,
                  'packet_data': pkt,
                  'toque_actual': 3,
                  'total_toques': 3,
                  'es_huella_nueva': false,
                  'coaccion_activa': true,
                  'metodo_biometrico': 'HUELLA',
                  'timestamp': DateTime.now().toIso8601String(),
                }, ignorarDebounce: true);
                return;
              }
            }
          }
        } catch (_) {}
      },
    );
  }

  Future<String?> _obtenerUltimoRecNoDelLector() async {
    try {
      final res = await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/recordFinder.cgi?action=find&name=AccessControlCardRec&count=1&Order=Desc',
        timeout: const Duration(seconds: 3),
      );
      if (res != null && res.statusCode == 200) {
        final m = RegExp(r'records\[0\]\.RecNo=(\d+)').firstMatch(res.body);
        return m?.group(1);
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, String?>?> _verificarNuevoToqueEnLogDelLector() async {
    try {
      final res = await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/recordFinder.cgi?action=find&name=AccessControlCardRec&count=1&Order=Desc',
        timeout: const Duration(seconds: 3),
      );
      if (res == null || res.statusCode != 200) return null;

      final recNoMatch = RegExp(
        r'records\[0\]\.RecNo=(\d+)',
      ).firstMatch(res.body);
      final String? recNo = recNoMatch?.group(1);
      if (recNo == null || recNo == _ultimoLogIdConocido) return null;

      _ultimoLogIdConocido = recNo;

      final methodMatch = RegExp(
        r'records\[0\]\.Method=(\d+)',
      ).firstMatch(res.body);
      final int? method = methodMatch != null
          ? int.tryParse(methodMatch.group(1) ?? '')
          : null;
      if (method == 15 || method == 16 || method == 21) return null;

      final userMatch = RegExp(
        r'records\[0\]\.UserID=([^\r\n]+)',
      ).firstMatch(res.body);
      final String uid = (userMatch?.group(1) ?? '').trim();

      String? pkt;
      if (uid.isNotEmpty && uid != '0') {
        pkt = await obtenerPacketDataDesdeDahua(uid);
      }
      return {'user_id': uid == '0' ? '' : uid, 'packet_data': pkt};
    } catch (_) {
      return null;
    }
  }

  /// Solicita exclusivamente al sensor de huella capturar las 3 muestras (sin invocar nunca la cámara facial)
  Future<void> solicitarEscaneoTresVecesEnLector() async {
    if (_capturaSensorActiva) return;
    _capturaSensorActiva = true;

    try {
      await _ejecutarMetodoRpc2('AccessFingerprint.capture', {'ReaderID': 1});
      await _ejecutarMetodoRpc2('AccessFingerprint.capture', {'ReaderID': 0});

      final resFp1 = await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/AccessFingerprint.cgi?action=captureFingerprint&ReaderID=1',
        timeout: const Duration(seconds: 12),
      );
      if (resFp1 != null &&
          resFp1.statusCode == 200 &&
          resFp1.body.trim().isNotEmpty &&
          !resFp1.body.contains('Error')) {
        await _procesarEventoHuellaDahua(resFp1.body);
        return;
      }

      final resFp0 = await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/AccessFingerprint.cgi?action=captureFingerprint&ReaderID=0',
        timeout: const Duration(seconds: 12),
      );
      if (resFp0 != null &&
          resFp0.statusCode == 200 &&
          resFp0.body.trim().isNotEmpty &&
          !resFp0.body.contains('Error')) {
        await _procesarEventoHuellaDahua(resFp0.body);
      }
    } catch (_) {
    } finally {
      _capturaSensorActiva = false;
    }
  }

  /// Obtiene todos los UserID registrados en el lector Dahua consultando tanto AccessUser como AccessControlCard
  Future<Set<String>> obtenerUserIdsEnLector() async {
    final Set<String> ids = {};
    try {
      final res = await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/AccessUser.cgi?action=list&count=1000',
        timeout: const Duration(seconds: 4),
      );
      if (res != null && res.statusCode == 200) {
        final matches = RegExp(
          r'Users\[\d+\]\.UserID=([^\r\n]+)|"UserID"\s*:\s*"([^"]+)"',
        ).allMatches(res.body);
        for (final m in matches) {
          final id = (m.group(1) ?? m.group(2) ?? '').trim();
          if (id.isNotEmpty) ids.add(id);
        }
      }

      final resFinder = await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/recordFinder.cgi?action=find&name=AccessControlCard&count=1000',
        timeout: const Duration(seconds: 4),
      );
      if (resFinder != null && resFinder.statusCode == 200) {
        final matches = RegExp(
          r'records\[\d+\]\.UserID=([^\r\n]+)',
        ).allMatches(resFinder.body);
        for (final m in matches) {
          final id = (m.group(1) ?? '').trim();
          if (id.isNotEmpty) ids.add(id);
        }
      }
    } catch (_) {}
    return ids;
  }

  Future<bool> verificarUsuarioExisteEnLector(String userId) async {
    final uid = userId.trim();
    if (uid.isEmpty) return false;
    try {
      final ids = await obtenerUserIdsEnLector();
      if (ids.contains(uid)) return true;

      final uidEnc = Uri.encodeComponent(uid);
      final res = await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/recordFinder.cgi?action=find&name=AccessControlCard&condition.UserID=$uidEnc',
        timeout: const Duration(seconds: 4),
      );
      if (res != null &&
          res.statusCode == 200 &&
          res.body.contains('UserID=$uid')) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  Future<String?> obtenerPacketDataDesdeDahua(String userId) async {
    final uid = userId.trim();
    final uidEnc = Uri.encodeComponent(uid);
    try {
      final rpcRes = await _ejecutarMetodoRpc2('AccessFingerprint.get', {
        'UserID': uid,
      });
      if (rpcRes != null && rpcRes['result'] == true) {
        final pkt = _extraerPacketDataDeTexto(jsonEncode(rpcRes));
        if (pkt != null && pkt.isNotEmpty) return pkt;
      }

      final res1 = await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/AccessFingerprint.cgi?action=get&UserID=$uidEnc',
        timeout: const Duration(seconds: 4),
      );
      if (res1 != null && res1.statusCode == 200) {
        final pkt = _extraerPacketDataDeTexto(res1.body);
        if (pkt != null && pkt.isNotEmpty) return pkt;
      }

      final res2 = await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/recordFinder.cgi?action=find&name=AccessControlFingerPrint&condition.UserID=$uidEnc',
        timeout: const Duration(seconds: 4),
      );
      if (res2 != null && res2.statusCode == 200) {
        final pkt = _extraerPacketDataDeTexto(res2.body);
        if (pkt != null && pkt.isNotEmpty) return pkt;
      }
    } catch (_) {}
    return null;
  }

  void emitirActualizacionAsistencias() {
    final payload = {
      'event': 'ACTUALIZAR_ASISTENCIAS',
      'timestamp': DateTime.now().toIso8601String(),
    };
    _eventosController.add(payload);
    final jsonStr = jsonEncode(payload);
    for (final client in List<WebSocket>.from(_wsClients)) {
      try {
        client.add(jsonStr);
      } catch (_) {
        _wsClients.remove(client);
      }
    }
  }

  Future<void> iniciarServidorWebSocketLocal() async {
    if (_localWsServer != null) return;
    try {
      _localWsServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        8080,
        shared: true,
      );
      _localWsServer!.listen((HttpRequest req) async {
        if (WebSocketTransformer.isUpgradeRequest(req)) {
          final ws = await WebSocketTransformer.upgrade(req);
          _wsClients.add(ws);
          ws.done.then((_) => _wsClients.remove(ws));
        } else {
          req.response.statusCode = HttpStatus.ok;
          await req.response.close();
        }
      });
    } catch (_) {}
  }

  void _emitirEvento(
    Map<String, dynamic> payload, {
    bool ignorarDebounce = false,
  }) {
    final ahora = DateTime.now();
    if (!ignorarDebounce &&
        _ultimaLecturaEmitida != null &&
        ahora.difference(_ultimaLecturaEmitida!).inMilliseconds < 650) {
      return;
    }
    _ultimaLecturaEmitida = ahora;

    _eventosController.add(payload);
    final jsonStr = jsonEncode(payload);
    for (final client in List<WebSocket>.from(_wsClients)) {
      try {
        client.add(jsonStr);
      } catch (_) {
        _wsClients.remove(client);
      }
    }
  }

  Future<bool> probarConexion() async {
    try {
      final res = await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/magicBox.cgi?action=getMachineName',
        timeout: const Duration(seconds: 4),
      );
      return res != null && res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Crea o actualiza al usuario en la memoria interna del lector Dahua (192.168.2.108)
  /// utilizando tanto AccessUser.cgi como la tabla maestra AccessControlCard (sin ejecutar nunca removeMulti).
  Future<bool> _crearUsuarioEnSistemaLector({
    required String userId,
    required String nombre,
  }) async {
    final String uid = userId.trim();
    final String nom = nombre.trim();
    final String uidEnc = Uri.encodeComponent(uid);
    final String nomEnc = Uri.encodeComponent(nom);

    bool exito = false;

    final Map<String, dynamic> estructuraUsuarioV3 = {
      'Users': [
        {
          'UserID': uid,
          'UserName': nom,
          'UserType': 0,
          'Authority': 2,
          'CitizenIDNo': uid,
          'Department': 1,
          'Doors': [0],
          'TimeSections': [255],
          'SpecialDaysSchedule': [255],
          'ValidFrom': '2020-01-01 00:00:00',
          'ValidTo': '2037-12-31 23:59:59',
        },
      ],
    };

    // 1. Vía RPC2 Web Service 2.0
    final rpcInsert = await _ejecutarMetodoRpc2(
      'AccessUser.insertMulti',
      estructuraUsuarioV3,
    );
    if (rpcInsert != null && rpcInsert['result'] == true) {
      exito = true;
    } else {
      final rpcUpdate = await _ejecutarMetodoRpc2(
        'AccessUser.updateMulti',
        estructuraUsuarioV3,
      );
      if (rpcUpdate != null && rpcUpdate['result'] == true) {
        exito = true;
      }
    }

    // 2. Vía CGI V3 POST JSON a AccessUser.cgi
    final String jsonBody = jsonEncode(estructuraUsuarioV3);
    final resPostInsert = await _peticionDahuaDigest(
      'POST',
      '/cgi-bin/AccessUser.cgi?action=insertMulti',
      jsonBody: jsonBody,
      timeout: const Duration(seconds: 5),
    );
    if (resPostInsert != null &&
        resPostInsert.statusCode == 200 &&
        !resPostInsert.body.contains('Error')) {
      exito = true;
    } else {
      final resPostUpdate = await _peticionDahuaDigest(
        'POST',
        '/cgi-bin/AccessUser.cgi?action=updateMulti',
        jsonBody: jsonBody,
        timeout: const Duration(seconds: 5),
      );
      if (resPostUpdate != null &&
          resPostUpdate.statusCode == 200 &&
          !resPostUpdate.body.contains('Error')) {
        exito = true;
      }
    }

    // 3. Vía CGI V3 GET URL-Encoded a AccessUser.cgi
    final String queryParams =
        'Users[0].UserID=$uidEnc'
        '&Users[0].UserName=$nomEnc'
        '&Users[0].UserType=0'
        '&Users[0].Authority=2'
        '&Users[0].Department=1'
        '&Users[0].Doors[0]=0'
        '&Users[0].TimeSections[0]=255'
        '&Users[0].SpecialDaysSchedule[0]=255'
        '&Users[0].ValidFrom=2020-01-01%2000:00:00'
        '&Users[0].ValidTo=2037-12-31%2023:59:59';

    final resGetInsert = await _peticionDahuaDigest(
      'GET',
      '/cgi-bin/AccessUser.cgi?action=insertMulti&$queryParams',
      timeout: const Duration(seconds: 5),
    );
    if (resGetInsert != null &&
        resGetInsert.statusCode == 200 &&
        !resGetInsert.body.contains('Error')) {
      exito = true;
    } else {
      final resGetUpdate = await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/AccessUser.cgi?action=updateMulti&$queryParams',
        timeout: const Duration(seconds: 5),
      );
      if (resGetUpdate != null &&
          resGetUpdate.statusCode == 200 &&
          !resGetUpdate.body.contains('Error')) {
        exito = true;
      }
    }

    // 4. Tabla maestra interna AccessControlCard (Vía que garantiza que el usuario aparezca en el menú del lector)
    // Primero intentamos con CardNo vacío para no sumar tarjeta; si el firmware exige llave primaria, usamos hexCard
    final resRecSinCard = await _peticionDahuaDigest(
      'GET',
      '/cgi-bin/recordUpdater.cgi?action=insert&name=AccessControlCard'
      '&CardNo=&UserID=$uidEnc&CardName=$nomEnc'
      '&CardStatus=0&CardType=0&Doors[0]=0&TimeSections[0]=255'
      '&ValidDateStart=20200101000000&ValidDateEnd=20371231235959',
      timeout: const Duration(seconds: 4),
    );
    if (resRecSinCard != null &&
        resRecSinCard.statusCode == 200 &&
        !resRecSinCard.body.contains('Error')) {
      exito = true;
    }

    final bool yaExisteSinCard = await verificarUsuarioExisteEnLector(uid);
    if (!yaExisteSinCard) {
      final String hexCard =
          (int.tryParse(uid.replaceAll(RegExp(r'[^0-9]'), '')) ?? 1)
              .toRadixString(16)
              .toUpperCase()
              .padLeft(8, '0');
      final resRec = await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/recordUpdater.cgi?action=insert&name=AccessControlCard'
        '&CardNo=$hexCard&UserID=$uidEnc&CardName=$nomEnc'
        '&CardStatus=0&CardType=0&Doors[0]=0&TimeSections[0]=255'
        '&ValidDateStart=20200101000000&ValidDateEnd=20371231235959',
        timeout: const Duration(seconds: 5),
      );
      if (resRec != null &&
          resRec.statusCode == 200 &&
          !resRec.body.contains('Error')) {
        exito = true;
      }
    }

    return exito;
  }

  /// Guarda la huella capturada en la Casilla 1 (`PacketData[0]`) del lector
  /// y activa el botón de `Coacción` (`DuressIndex: 1`, con respaldo `DuressIndex: 0`).
  Future<bool> _guardarHuellaEnCasilla1ConCoaccion({
    required String userId,
    required String packetData,
  }) async {
    final String uid = userId.trim();
    final String pkt = packetData.trim();
    if (uid.isEmpty || pkt.isEmpty) return false;

    final String uidEncoded = Uri.encodeComponent(uid);
    final String fpEncoded = Uri.encodeComponent(pkt);

    final Map<String, dynamic> bodySlot1Coaccion = {
      'FingerprintCards': [
        {
          'UserID': uid,
          'PacketData': [pkt],
          'DuressIndex': 1,
        },
      ],
    };

    bool guardado = false;

    final rpcRes1 = await _ejecutarMetodoRpc2(
      'AccessFingerprint.insertMulti',
      bodySlot1Coaccion,
    );
    if (rpcRes1 != null && rpcRes1['result'] == true) {
      guardado = true;
    } else {
      final rpcUpd1 = await _ejecutarMetodoRpc2(
        'AccessFingerprint.update',
        bodySlot1Coaccion,
      );
      if (rpcUpd1 != null && rpcUpd1['result'] == true) {
        guardado = true;
      }
    }

    final resPost1 = await _peticionDahuaDigest(
      'POST',
      '/cgi-bin/AccessFingerprint.cgi?action=insertMulti',
      jsonBody: jsonEncode(bodySlot1Coaccion),
      timeout: const Duration(seconds: 5),
    );
    if (resPost1 != null &&
        resPost1.statusCode == 200 &&
        !resPost1.body.contains('Error')) {
      guardado = true;
    } else {
      final resUpd1 = await _peticionDahuaDigest(
        'POST',
        '/cgi-bin/AccessFingerprint.cgi?action=update',
        jsonBody: jsonEncode(bodySlot1Coaccion),
        timeout: const Duration(seconds: 5),
      );
      if (resUpd1 != null &&
          resUpd1.statusCode == 200 &&
          !resUpd1.body.contains('Error')) {
        guardado = true;
      }
    }

    if (!guardado) {
      final Map<String, dynamic> bodySlot0Coaccion = {
        'FingerprintCards': [
          {
            'UserID': uid,
            'PacketData': [pkt],
            'DuressIndex': 0,
          },
        ],
      };
      final resPost0 = await _peticionDahuaDigest(
        'POST',
        '/cgi-bin/AccessFingerprint.cgi?action=insertMulti',
        jsonBody: jsonEncode(bodySlot0Coaccion),
        timeout: const Duration(seconds: 5),
      );
      if (resPost0 != null &&
          resPost0.statusCode == 200 &&
          !resPost0.body.contains('Error')) {
        guardado = true;
      }
    }

    if (!guardado) {
      final resGet = await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/AccessFingerprint.cgi?action=insertMulti'
        '&FingerprintCards[0].UserID=$uidEncoded'
        '&FingerprintCards[0].PacketData[0]=$fpEncoded'
        '&FingerprintCards[0].DuressIndex=1',
        timeout: const Duration(seconds: 5),
      );
      if (resGet != null &&
          resGet.statusCode == 200 &&
          !resGet.body.contains('Error')) {
        guardado = true;
      }

      await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/recordUpdater.cgi?action=insert&name=AccessControlFingerPrint'
        '&UserID=$uidEncoded&PacketData=$fpEncoded&DuressIndex=1&Flag=1',
        timeout: const Duration(seconds: 5),
      );
    }

    return guardado;
  }

  /// Sincroniza al socio y su huella (con Coacción en Casilla 1) en el sistema independiente Dahua
  Future<bool> sincronizarSocioEnLectorDahua({
    required String ci,
    required String nombreCompleto,
    String? fingerprintBase64,
    required DateTime fechaVencimiento,
    bool reproducirVozAlSincronizar = true,
  }) async {
    try {
      final String idHuellaUsuario = ci.trim();
      if (idHuellaUsuario.isEmpty) return false;
      final String nombreLimpio = nombreCompleto.trim();

      bool guardadoEnLector = await _crearUsuarioEnSistemaLector(
        userId: idHuellaUsuario,
        nombre: nombreLimpio,
      );

      String? packetFinal = fingerprintBase64?.trim();
      if (packetFinal == null || packetFinal.isEmpty) {
        packetFinal = await obtenerPacketDataDesdeDahua(idHuellaUsuario);
      }

      if (packetFinal != null && packetFinal.isNotEmpty) {
        final okFp = await _guardarHuellaEnCasilla1ConCoaccion(
          userId: idHuellaUsuario,
          packetData: packetFinal,
        );
        if (okFp) guardadoEnLector = true;
      }

      final bool confirmadoEnMemoria = await verificarUsuarioExisteEnLector(
        idHuellaUsuario,
      );
      if (confirmadoEnMemoria) {
        guardadoEnLector = true;
      }

      if (reproducirVozAlSincronizar) {
        unawaited(reproducirAudioBienvenidaThorGym());
      }

      return guardadoEnLector;
    } catch (_) {
      return false;
    }
  }

  /// Sincroniza todos los socios registrados en MySQL hacia el sistema independiente del lector Dahua
  Future<int> sincronizarTodosLosSociosEnEquipo(
    List<Map<String, dynamic>> listaSocios, {
    bool forzar = false,
  }) async {
    if (_sincronizacionMasivaInicialRealizada && !forzar) {
      return listaSocios.length;
    }

    int totalSincronizados = 0;

    for (final socio in listaSocios) {
      final String templateHuella =
          (socio['template_huella'] ?? '').toString().trim();
      final String ciSocio = (socio['ci'] ?? '').toString().trim();
      final String? packetData = socio['packet_data']?.toString();
      final String nombre =
          (socio['nombre_completo'] ?? 'Socio').toString().trim();
      final DateTime fechaVenc = socio['fecha_vencimiento'] is DateTime
          ? socio['fecha_vencimiento'] as DateTime
          : DateTime.now().add(const Duration(days: 30));

      final String idEnLector =
          templateHuella.isNotEmpty ? templateHuella : ciSocio;
      if (idEnLector.isEmpty) continue;

      final ok = await sincronizarSocioEnLectorDahua(
        ci: idEnLector,
        nombreCompleto: nombre,
        fingerprintBase64: packetData,
        fechaVencimiento: fechaVenc,
        reproducirVozAlSincronizar: false,
      );

      if (ok) totalSincronizados++;
    }

    if (totalSincronizados > 0) {
      _sincronizacionMasivaInicialRealizada = true;
      if (forzar) {
        unawaited(reproducirAudioBienvenidaThorGym());
      }
    }
    return totalSincronizados;
  }

  Future<void> eliminarSocioDeLectorDahua(String idHuella) async {
    final uid = idHuella.trim();
    final uidEnc = Uri.encodeComponent(uid);
    try {
      await _ejecutarMetodoRpc2('AccessFingerprint.removeMulti', {
        'UserID': [uid],
      });
      await _ejecutarMetodoRpc2('AccessUser.removeMulti', {
        'UserID': [uid],
      });
      await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/AccessFingerprint.cgi?action=removeMulti&UserID[0]=$uidEnc',
      );
      await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/AccessCard.cgi?action=removeMulti&UserID[0]=$uidEnc',
      );
      await _peticionDahuaDigest(
        'GET',
        '/cgi-bin/AccessUser.cgi?action=removeMulti&UserID[0]=$uidEnc',
      );
    } catch (_) {}
  }

  Future<void> iniciarEscuchaEventosEnVivo() async {
    if (_escuchando) return;
    _escuchando = true;
    await iniciarServidorWebSocketLocal();

    const String path =
        '/cgi-bin/eventManager.cgi?action=attach&codes=%5BAll%5D';

    Future.doWhile(() async {
      if (!_escuchando) return false;
      try {
        _eventHttpClient = HttpClient();
        _eventHttpClient!.connectionTimeout = const Duration(seconds: 4);

        final req1 = await _eventHttpClient!.get(ip, port, path);
        final res1 = await req1.close();
        await res1.drain();

        String? authHeader;
        if (res1.statusCode == 401) {
          final wwwAuth = res1.headers.value(HttpHeaders.wwwAuthenticateHeader);
          if (wwwAuth != null) {
            authHeader = _construirCabeceraDigest(
              wwwAuth: wwwAuth,
              method: 'GET',
              uri: path,
            );
          }
        }

        final req2 = await _eventHttpClient!.get(ip, port, path);
        if (authHeader != null) {
          req2.headers.set(HttpHeaders.authorizationHeader, authHeader);
        } else {
          final basic = base64Encode(utf8.encode('$username:$password'));
          req2.headers.set(HttpHeaders.authorizationHeader, 'Basic $basic');
        }

        final res2 = await req2.close();
        if (res2.statusCode == 200) {
          String buffer = '';
          await for (final chunk in res2.transform(
            const Utf8Decoder(allowMalformed: true),
          )) {
            if (!_escuchando) break;
            buffer += chunk;

            while (true) {
              final int posCode = buffer.indexOf('Code=');
              if (posCode == -1) {
                if (buffer.length > 8192) buffer = '';
                break;
              }
              if (posCode > 0) {
                buffer = buffer.substring(posCode);
              }

              final int posCierreJson = buffer.indexOf('}');
              if (posCierreJson != -1) {
                final String bloqueEvento = buffer.substring(
                  0,
                  posCierreJson + 1,
                );
                buffer = buffer.substring(posCierreJson + 1);
                await _procesarEventoHuellaDahua(bloqueEvento);
              } else if (buffer.contains('\r\n\r\n')) {
                final int posFin = buffer.indexOf('\r\n\r\n');
                final String bloqueEvento = buffer.substring(0, posFin);
                buffer = buffer.substring(posFin + 4);
                await _procesarEventoHuellaDahua(bloqueEvento);
              } else {
                break;
              }
            }
          }
        }
      } catch (_) {}

      if (_escuchando) {
        await Future.delayed(const Duration(seconds: 1));
      }
      return _escuchando;
    });
  }

  Future<void> detenerEscucha() async {
    _escuchando = false;
    try {
      _eventHttpClient?.close(force: true);
    } catch (_) {}
    _eventHttpClient = null;
  }

  String? _extraerPacketDataDeTexto(String texto) {
    final regex = RegExp(
      r'"?(?:PacketData|FingerPrintData|Feature)"?(?:\[\d+\])?\s*[:=]\s*(?:\[\s*)?"?([A-Za-z0-9+/=\-_\r\n]{24,})"?',
    );
    final match = regex.firstMatch(texto);
    return match?.group(1)?.replaceAll(RegExp(r'\s+'), '');
  }

  Future<void> _procesarEventoHuellaDahua(String bloque) async {
    final methodMatch = RegExp(r'"?Method"?\s*[:=]\s*(\d+)').firstMatch(bloque);
    final int? methodCode = methodMatch != null
        ? int.tryParse(methodMatch.group(1) ?? '')
        : null;

    // Bloquear únicamente eventos de cámara facial (15, 16, 21)
    if (methodCode == 15 || methodCode == 16 || methodCode == 21) {
      return;
    }
    if (bloque.contains('Code=FaceRecognition') ||
        bloque.contains('Code=FaceDetection') ||
        bloque.contains('Code=VideoMotion')) {
      return;
    }

    if (bloque.contains('FingerPrintCheck') ||
        bloque.contains('CurrentCount')) {
      final currMatch = RegExp(r'"?CurrentCount"?\s*[:=]\s*(\d+)')
          .firstMatch(bloque);
      final totMatch = RegExp(r'"?TotalCount"?\s*[:=]\s*(\d+)')
          .firstMatch(bloque);
      if (currMatch != null) {
        final int toqueActual = int.tryParse(currMatch.group(1) ?? '1') ?? 1;
        final int totalToques = int.tryParse(totMatch?.group(1) ?? '3') ?? 3;
        _emitirEvento({
          'event': 'HUELLA_PROGRESO',
          'toque_actual': toqueActual,
          'total_toques': totalToques,
          'mensaje':
              'Lectura $toqueActual de $totalToques completada... ${toqueActual < totalToques ? "Vuelva a presionar su dedo en el lector" : "Procesando huella y activando Coacción..."}',
        }, ignorarDebounce: true);
      }
      return;
    }

    final String? packetData = _extraerPacketDataDeTexto(bloque);
    if (packetData != null && packetData.isNotEmpty) {
      final String idAsignado =
          (_userIdEnCapturaActual != null && _userIdEnCapturaActual!.isNotEmpty)
              ? _userIdEnCapturaActual!
              : 'HUELLA_NUEVA_SENSOR';

      if (idAsignado != 'HUELLA_NUEVA_SENSOR') {
        await _guardarHuellaEnCasilla1ConCoaccion(
          userId: idAsignado,
          packetData: packetData,
        );
      }

      _emitirEvento({
        'event': 'HUELLA_LEIDA',
        'template': idAsignado,
        'id_huella': idAsignado,
        'user_id': idAsignado,
        'packet_data': packetData,
        'toque_actual': 3,
        'total_toques': 3,
        'es_huella_nueva': true,
        'coaccion_activa': true,
        'metodo_biometrico': 'HUELLA',
        'timestamp': DateTime.now().toIso8601String(),
      }, ignorarDebounce: true);
      return;
    }

    if (!bloque.contains('Code=AccessControl') &&
        !bloque.contains('Code=DuressAlarm') &&
        !bloque.contains('Duress')) {
      return;
    }

    String? extraerValor(String clave) {
      final regexComillas = RegExp('"$clave"\\s*:\\s*"([^"]*)"');
      final m1 = regexComillas.firstMatch(bloque);
      if (m1 != null) {
        final v = m1.group(1)?.trim();
        if (v != null &&
            v.isNotEmpty &&
            v != '0' &&
            v != 'null' &&
            v != '00000000') {
          return v;
        }
      }

      final regexSinComillas =
          RegExp('"?$clave"?\\s*[:=]\\s*([^\\s,;"\\r\\n}]+)');
      final m2 = regexSinComillas.firstMatch(bloque);
      if (m2 != null) {
        final v = m2.group(1)?.trim();
        if (v != null &&
            v.isNotEmpty &&
            v != '0' &&
            v != 'null' &&
            v != '00000000') {
          return v;
        }
      }
      return null;
    }

    final String? userId = extraerValor('UserID');
    final String? fpId =
        extraerValor('FingerPrintID') ??
        extraerValor('FingerIndex') ??
        extraerValor('FingerNo');

    if ((userId != null && userId.isNotEmpty) ||
        (fpId != null && fpId.isNotEmpty)) {
      final String idHuellaReconocida =
          (userId != null && userId.isNotEmpty) ? userId : fpId!;

      String? packetRecuperado;
      if (_modoCapturaNuevoSocio && userId != null && userId.isNotEmpty) {
        packetRecuperado = await obtenerPacketDataDesdeDahua(userId);
      }

      _emitirEvento({
        'event': 'HUELLA_LEIDA',
        'template': idHuellaReconocida,
        'id_huella': idHuellaReconocida,
        'user_id': userId,
        'packet_data': packetRecuperado,
        'toque_actual': 3,
        'total_toques': 3,
        'es_huella_nueva': false,
        'coaccion_activa': true,
        'metodo_biometrico': 'HUELLA',
        'timestamp': DateTime.now().toIso8601String(),
      }, ignorarDebounce: _modoCapturaNuevoSocio);
      return;
    }

    if (_modoCapturaNuevoSocio) {
      final String idPre =
          (_userIdEnCapturaActual != null && _userIdEnCapturaActual!.isNotEmpty)
              ? _userIdEnCapturaActual!
              : 'HUELLA_NUEVA_SENSOR';

      String? packetDelUsuario;
      if (idPre != 'HUELLA_NUEVA_SENSOR') {
        packetDelUsuario = await obtenerPacketDataDesdeDahua(idPre);
      }

      _emitirEvento({
        'event': 'HUELLA_LEIDA',
        'template': idPre,
        'id_huella': idPre,
        'user_id': idPre == 'HUELLA_NUEVA_SENSOR' ? null : idPre,
        'packet_data': packetDelUsuario,
        'toque_actual': 3,
        'total_toques': 3,
        'es_huella_nueva': true,
        'coaccion_activa': true,
        'metodo_biometrico': 'HUELLA',
        'timestamp': DateTime.now().toIso8601String(),
      }, ignorarDebounce: true);
    } else {
      _emitirEvento({
        'event': 'HUELLA_LEIDA',
        'template': 'HUELLA_NO_REGISTRADA',
        'id_huella': 'HUELLA_NO_REGISTRADA',
        'user_id': null,
        'packet_data': null,
        'metodo_biometrico': 'HUELLA',
        'timestamp': DateTime.now().toIso8601String(),
      });
    }
  }

  Future<_DahuaResponse?> _peticionDahuaDigest(
    String method,
    String path, {
    String? jsonBody,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final client = HttpClient();
    client.connectionTimeout = timeout;
    try {
      final uri = Uri.parse('http://$ip:$port$path');

      final req1 = await client.openUrl(method, uri);
      req1.headers.chunkedTransferEncoding = false;
      req1.contentLength = 0;
      final res1 = await req1.close().timeout(timeout);
      final body1 = await utf8.decodeStream(res1);

      if (res1.statusCode != 401) {
        return _DahuaResponse(res1.statusCode, body1);
      }

      final wwwAuth = res1.headers.value(HttpHeaders.wwwAuthenticateHeader);
      if (wwwAuth == null) {
        return _DahuaResponse(res1.statusCode, body1);
      }

      final authHeader = _construirCabeceraDigest(
        wwwAuth: wwwAuth,
        method: method,
        uri: path,
      );

      final req2 = await client.openUrl(method, uri);
      req2.headers.chunkedTransferEncoding = false;
      req2.headers.set(HttpHeaders.authorizationHeader, authHeader);

      if (jsonBody != null) {
        final bytes = utf8.encode(jsonBody);
        req2.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/json; charset=utf-8',
        );
        req2.contentLength = bytes.length;
        req2.add(bytes);
      } else {
        req2.contentLength = 0;
      }

      final res2 = await req2.close().timeout(timeout);
      final body2 = await utf8.decodeStream(res2);

      return _DahuaResponse(res2.statusCode, body2);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  String _construirCabeceraDigest({
    required String wwwAuth,
    required String method,
    required String uri,
  }) {
    String extraerCampo(String nombre) {
      final match = RegExp('$nombre="([^"]+)"').firstMatch(wwwAuth);
      return match?.group(1) ?? '';
    }

    final realm = extraerCampo('realm');
    final nonce = extraerCampo('nonce');
    final opaque = extraerCampo('opaque');
    final qopRaw = extraerCampo('qop');
    final qop = qopRaw.contains('auth') ? 'auth' : qopRaw;

    const nc = '00000001';
    final cnonce = _md5Hex(DateTime.now().microsecondsSinceEpoch.toString())
        .substring(0, 16);

    final ha1 = _md5Hex('$username:$realm:$password');
    final ha2 = _md5Hex('$method:$uri');

    final String responseHash = qop.isNotEmpty
        ? _md5Hex('$ha1:$nonce:$nc:$cnonce:$qop:$ha2')
        : _md5Hex('$ha1:$nonce:$ha2');

    final buffer = StringBuffer('Digest ');
    buffer.write('username="$username", ');
    buffer.write('realm="$realm", ');
    buffer.write('nonce="$nonce", ');
    buffer.write('uri="$uri", ');
    if (qop.isNotEmpty) {
      buffer.write('qop=$qop, ');
      buffer.write('nc=$nc, ');
      buffer.write('cnonce="$cnonce", ');
    }
    buffer.write('response="$responseHash"');
    if (opaque.isNotEmpty) {
      buffer.write(', opaque="$opaque"');
    }
    return buffer.toString();
  }

  String _md5Hex(String input) {
    final data = utf8.encode(input);
    final lengthInBits = data.length * 8;

    final paddedLength = ((data.length + 8) ~/ 64 + 1) * 64;
    final buffer = Uint8List(paddedLength);
    buffer.setRange(0, data.length, data);
    buffer[data.length] = 0x80;

    final bd = ByteData.view(buffer.buffer);
    bd.setUint64(paddedLength - 8, lengthInBits, Endian.little);

    int a0 = 0x67452301;
    int b0 = 0xefcdab89;
    int c0 = 0x98badcfe;
    int d0 = 0x10325476;

    const List<int> s = [
      7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
      5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
      4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
      6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];

    const List<int> k = [
      0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
      0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
      0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
      0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
      0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
      0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
      0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
      0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
      0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
      0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
      0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
      0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
      0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
      0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
      0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
      0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ];

    int rotl32(int val, int shift) =>
        ((val << shift) & 0xFFFFFFFF) | ((val & 0xFFFFFFFF) >>> (32 - shift));

    for (int offset = 0; offset < paddedLength; offset += 64) {
      int a = a0, b = b0, c = c0, d = d0;

      for (int i = 0; i < 64; i++) {
        int f, g;
        if (i < 16) {
          f = (b & c) | ((~b & 0xFFFFFFFF) & d);
          g = i;
        } else if (i < 32) {
          f = (d & b) | ((~d & 0xFFFFFFFF) & c);
          g = (5 * i + 1) % 16;
        } else if (i < 48) {
          f = b ^ c ^ d;
          g = (3 * i + 5) % 16;
        } else {
          f = c ^ (b | (~d & 0xFFFFFFFF));
          g = (7 * i) % 16;
        }

        final word = bd.getUint32(offset + g * 4, Endian.little);
        final sum = (a + f + k[i] + word) & 0xFFFFFFFF;
        final temp = d;
        d = c;
        c = b;
        b = (b + rotl32(sum, s[i])) & 0xFFFFFFFF;
        a = temp;
      }

      a0 = (a0 + a) & 0xFFFFFFFF;
      b0 = (b0 + b) & 0xFFFFFFFF;
      c0 = (c0 + c) & 0xFFFFFFFF;
      d0 = (d0 + d) & 0xFFFFFFFF;
    }

    final out = ByteData(16);
    out.setUint32(0, a0, Endian.little);
    out.setUint32(4, b0, Endian.little);
    out.setUint32(8, c0, Endian.little);
    out.setUint32(12, d0, Endian.little);

    final hex = StringBuffer();
    for (int i = 0; i < 16; i++) {
      hex.write(out.getUint8(i).toRadixString(16).padLeft(2, '0'));
    }
    return hex.toString();
  }
}

class _DahuaResponse {
  final int statusCode;
  final String body;
  _DahuaResponse(this.statusCode, this.body);
}