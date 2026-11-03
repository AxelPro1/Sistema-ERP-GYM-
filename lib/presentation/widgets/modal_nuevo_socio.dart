import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:camera/camera.dart';

import '../../infrastructure/database/mysql_repository.dart';
import '../../application/services/dahua_biometric_service.dart';

class ModalNuevoSocio extends StatefulWidget {
  const ModalNuevoSocio({Key? key}) : super(key: key);

  @override
  _ModalNuevoSocioState createState() => _ModalNuevoSocioState();
}

class _ModalNuevoSocioState extends State<ModalNuevoSocio> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _ciController = TextEditingController();
  final TextEditingController _nombreController = TextEditingController();
  final TextEditingController _telefonoController = TextEditingController();
  final TextEditingController _correoController = TextEditingController();

  WebSocketChannel? _wsChannel;
  StreamSubscription<Map<String, dynamic>>? _dahuaSub;
  String? _idUnicoHuella;
  String? _huellaTemplate;
  String? _packetDataHuella;
  String? _idPreAsignadoLector;
  String? _fotoPath;
  bool _esperandoHuella = false;
  bool _guardando = false;
  int _toquesCompletados = 0;
  String _mensajeEstadoHuella = 'Ponga el dedo en el escáner (3 lecturas)';

  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  bool _camaraActiva = false;
  bool _isCamaraInicializada = false;

  final List<Map<String, dynamic>> _planesDisponibles = [
    {
      'id': 1,
      'nombre': 'Mensual / Socio (30 días - Reingreso 4h)',
      'dias': 30,
      'precio': 100.0,
    },
    {
      'id': 2,
      'nombre': 'Sesión Diaria (Validez 4 horas)',
      'dias': 1,
      'precio': 10.0,
    },
  ];
  late Map<String, dynamic> _planSeleccionado;
  String _metodoPago = 'EFECTIVO';
  String? _comprobanteQrPath;

  final SocioRepository _repository = SocioRepository();
  final DahuaBiometricService _dahuaService = DahuaBiometricService();

  @override
  void initState() {
    super.initState();
    _planSeleccionado = _planesDisponibles.first;
    _initCamarasDisponibles();
    _conectarPuenteLectorSinReiniciarStream();
  }

  Future<void> _conectarPuenteLectorSinReiniciarStream() async {
    final config = await _repository.obtenerConfiguracionSistema();
    await _dahuaService.configurarYConectar(
      nuevaIp: (config['dahua_ip'] ?? '192.168.2.108').toString(),
      nuevoPuerto:
          (config['dahua_puerto'] as num?)?.toInt() ?? _dahuaService.port,
      nuevoUsuario:
          (config['dahua_usuario'] ?? _dahuaService.username).toString(),
      nuevaPassword:
          (config['dahua_password'] ?? _dahuaService.password).toString(),
      forzarReconexion: false,
    );
  }

  @override
  void dispose() {
    _dahuaService.desactivarModoCapturaNuevoSocio();
    _dahuaSub?.cancel();
    _wsChannel?.sink.close();
    _ciController.dispose();
    _nombreController.dispose();
    _telefonoController.dispose();
    _correoController.dispose();
    _cameraController?.dispose();
    super.dispose();
  }

  Future<void> _initCamarasDisponibles() async {
    try {
      _cameras = await availableCameras();
    } catch (_) {}
  }

  Future<void> _encenderCamara() async {
    if (_cameras == null || _cameras!.isEmpty) {
      _mostrarSnack('No se detectó ninguna cámara web en el equipo.', Colors.red);
      return;
    }

    _cameraController = CameraController(_cameras![0], ResolutionPreset.medium);
    try {
      await _cameraController!.initialize();
      setState(() {
        _camaraActiva = true;
        _isCamaraInicializada = true;
        _fotoPath = null;
      });
    } catch (e) {
      _mostrarSnack('Error al inicializar la cámara: $e', Colors.red);
    }
  }

  Future<void> _tomarFoto() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    try {
      final XFile foto = await _cameraController!.takePicture();
      setState(() {
        _fotoPath = foto.path;
        _camaraActiva = false;
      });
      await _cameraController!.dispose();
      _cameraController = null;
      _isCamaraInicializada = false;
    } catch (_) {
      _mostrarSnack('Error al tomar la fotografía.', Colors.red);
    }
  }

  Future<void> _subirFoto() async {
    if (_camaraActiva) {
      await _cameraController?.dispose();
      _cameraController = null;
      setState(() {
        _camaraActiva = false;
        _isCamaraInicializada = false;
      });
    }
    final PlatformFile? file = await FilePicker.pickFile(type: FileType.image);
    if (file != null && file.path != null) {
      setState(() => _fotoPath = file.path);
    }
  }

  Future<void> _subirComprobanteQr() async {
    final PlatformFile? file = await FilePicker.pickFile(type: FileType.image);
    if (file != null && file.path != null) {
      setState(() => _comprobanteQrPath = file.path);
      _mostrarSnack('Comprobante QR cargado correctamente.', Colors.green);
    }
  }

  Future<void> _procesarHuellaCapturada(Map<String, dynamic> data) async {
    if (!mounted || !_esperandoHuella) return;

    if (data['event'] == 'HUELLA_PROGRESO') {
      final int toque =
          (data['toque_actual'] as num?)?.toInt() ?? _toquesCompletados;
      setState(() {
        _toquesCompletados = toque.clamp(0, 3);
        _mensajeEstadoHuella =
            (data['mensaje'] ?? 'Por favor, presione su dedo (3 lecturas)...')
                .toString();
      });
      return;
    }

    if (data['event'] != 'HUELLA_LEIDA') return;

    final String idHardwareLeido =
        (data['id_huella'] ?? data['template'] ?? '').toString().trim();
    final String? packetData = data['packet_data']?.toString();

    if (idHardwareLeido == 'HUELLA_NO_REGISTRADA') return;

    final bool esHuellaSinIdEnLector =
        idHardwareLeido.isEmpty || idHardwareLeido == 'HUELLA_NUEVA_SENSOR';

    if (!esHuellaSinIdEnLector || (packetData != null && packetData.isNotEmpty)) {
      final socioExistente = await _repository.buscarSocioPorHuella(
        esHuellaSinIdEnLector ? '' : idHardwareLeido,
        packetData: packetData,
      );

      if (!mounted) return;

      if (socioExistente != null) {
        setState(() {
          _idUnicoHuella = null;
          _huellaTemplate = null;
          _packetDataHuella = null;
          _esperandoHuella = false;
          _toquesCompletados = 0;
          _mensajeEstadoHuella =
              'Huella ya pertenece a ${socioExistente['nombre_completo']}';
        });
        _dahuaService.desactivarModoCapturaNuevoSocio();
        _dahuaSub?.cancel();
        _wsChannel?.sink.close();

        _mostrarSnack(
          '¡Huella Duplicada! Esta huella ya pertenece al socio ${socioExistente['nombre_completo']} (CI: ${socioExistente['ci']}).',
          Colors.red,
        );
        return;
      }
    }

    final String idHuellaAsignado = !esHuellaSinIdEnLector
        ? idHardwareLeido
        : (_idPreAsignadoLector ??
            await _repository.obtenerSiguienteIdNumericoHuella());

    String? packetFinal = packetData;
    if (packetFinal == null || packetFinal.isEmpty) {
      packetFinal = await _dahuaService.obtenerPacketDataDesdeDahua(
        idHuellaAsignado,
      );
    }

    String nuevoUuidUnico = const Uuid().v4();
    while (await _repository.buscarSocioPorHuella(nuevoUuidUnico) != null) {
      nuevoUuidUnico = const Uuid().v4();
    }

    if (!mounted) return;

    setState(() {
      _idUnicoHuella = nuevoUuidUnico;
      _huellaTemplate = idHuellaAsignado;
      _packetDataHuella = packetFinal;
      _esperandoHuella = false;
      _toquesCompletados = 3;
      _mensajeEstadoHuella =
          'Huella Digital (1/3) Guardada con Coacción (Núm. $idHuellaAsignado)';
    });

    _dahuaService.desactivarModoCapturaNuevoSocio();
    _dahuaSub?.cancel();
    _wsChannel?.sink.close();

    _mostrarSnack(
      'Usuario Núm. $idHuellaAsignado y su huella vinculados correctamente.',
      Colors.green,
    );
  }

  /// Calcula el siguiente Núm. libre (en BD y en Lector), crea al usuario en el lector Dahua
  /// y activa el modo de lectura de huella.
  Future<void> _activarEscanerHuella() async {
    final String nombreTemp = _nombreController.text.trim();
    if (nombreTemp.isEmpty) {
      _mostrarSnack(
        'Ingrese primero el Nombre Completo del socio antes de leer la huella.',
        Colors.orange,
      );
      return;
    }

    final String sigIdBd = await _repository.obtenerSiguienteIdNumericoHuella();
    final String sigIdLibre =
        await _dahuaService.obtenerSiguienteIdDisponibleEnLector(sigIdBd);
    _idPreAsignadoLector = sigIdLibre;

    if (!mounted) return;

    setState(() {
      _esperandoHuella = true;
      _idUnicoHuella = null;
      _huellaTemplate = null;
      _packetDataHuella = null;
      _toquesCompletados = 0;
      _mensajeEstadoHuella =
          'Creando usuario Núm. $sigIdLibre ($nombreTemp) en el lector...';
    });

    _dahuaSub?.cancel();
    _dahuaSub = _dahuaService.eventosStream.listen(_procesarHuellaCapturada);

    try {
      _wsChannel?.sink.close();
      _wsChannel = WebSocketChannel.connect(Uri.parse('ws://localhost:8080'));
      _wsChannel!.stream.listen(
        (message) {
          try {
            final data = jsonDecode(message);
            if (data is Map<String, dynamic>) {
              _procesarHuellaCapturada(data);
            }
          } catch (_) {}
        },
        onError: (_) {},
      );
    } catch (_) {}

    await _dahuaService.activarModoCapturaNuevoSocio(
      userIdPreRegistro: sigIdLibre,
      nombrePreRegistro: nombreTemp,
    );

    if (!mounted) return;
    setState(() {
      _mensajeEstadoHuella =
          'Usuario Núm. $sigIdLibre creado en el lector.\nPresione su dedo en el lector (3 tomas con Coacción)...';
    });
  }

  Future<void> _guardarSocio({required bool imprimirBoleta}) async {
    if (!_formKey.currentState!.validate()) return;

    if (_huellaTemplate == null ||
        _huellaTemplate!.trim().isEmpty ||
        _idUnicoHuella == null) {
      _mostrarSnack(
        'Debe capturar la huella dactilar antes de guardar.',
        Colors.red,
      );
      return;
    }

    if (_metodoPago == 'QR' && _comprobanteQrPath == null) {
      _mostrarSnack(
        'Debe subir el comprobante del pago por QR obligatoriamente.',
        Colors.red,
      );
      return;
    }

    setState(() => _guardando = true);

    final String ci = _ciController.text.trim();
    final String nombre = _nombreController.text.trim();
    final String telefono = _telefonoController.text.trim();
    final String correo = _correoController.text.trim();
    final int planId = _planSeleccionado['id'] as int;
    final int diasDuracion = _planSeleccionado['dias'] as int;
    final double importe = (_planSeleccionado['precio'] as num).toDouble();
    final String nombrePlan =
        planId == 2 ? 'Sesión Diaria' : 'Mensual / Socio';

    // 1. Descargar PacketData del lector si se cargó en las 3 tomas del usuario
    if (_packetDataHuella == null || _packetDataHuella!.isEmpty) {
      _packetDataHuella = await _dahuaService.obtenerPacketDataDesdeDahua(
        _huellaTemplate!,
      );
    }

    // 2. Guardar y confirmar al usuario + su huella en el sistema independiente del lector Dahua
    final bool guardadoEnSistemaLector =
        await _dahuaService.sincronizarSocioEnLectorDahua(
          ci: _huellaTemplate!,
          nombreCompleto: nombre,
          fingerprintBase64: _packetDataHuella,
          fechaVencimiento: DateTime.now().add(Duration(days: diasDuracion)),
          reproducirVozAlSincronizar: true,
        );

    // 3. Guardar en la base de datos del gimnasio (MySQL) bajo el mismo ID único
    final DateTime? fechaVencimiento =
        await _repository.registrarSocioConHuella(
          idUnicoHuella: _idUnicoHuella,
          ci: ci,
          nombre: nombre,
          telefono: telefono,
          correo: correo,
          templateHuella: _huellaTemplate!,
          packetDataHuella: _packetDataHuella,
          fotoUrl: _fotoPath,
          planId: planId,
          diasDuracion: diasDuracion,
          importe: importe,
          metodoPago: _metodoPago,
          comprobanteUrl: _metodoPago == 'QR' ? _comprobanteQrPath : null,
        );

    if (!mounted) return;

    if (fechaVencimiento != null) {
      _dahuaService.emitirActualizacionAsistencias();

      final String? rutaPdf = await _repository.generarEImprimirBoleta(
        nombreSocio: nombre,
        ciSocio: ci,
        conceptoPlan: nombrePlan,
        importe: importe,
        metodoPago: _metodoPago,
        fechaVencimiento: fechaVencimiento,
        imprimir: imprimirBoleta,
      );

      if (!mounted) return;
      setState(() => _guardando = false);

      final String msgLector = guardadoEnSistemaLector
          ? 'y guardado en el sistema Dahua (Núm. $_huellaTemplate)'
          : '(guardado en BD local)';

      _mostrarSnack(
        imprimirBoleta
            ? 'Socio registrado $msgLector. Boleta enviada a impresión.'
            : 'Socio registrado $msgLector. PDF en: ${rutaPdf ?? "Documentos/Recibos_Gym"}',
        Colors.green,
      );
      Navigator.of(context).pop(true);
    } else {
      setState(() => _guardando = false);
      _mostrarSnack(
        _repository.ultimoError ??
            'Error al guardar: Verifique si la huella o el CI ya existen.',
        Colors.red,
      );
    }
  }

  void _mostrarSnack(String mensaje, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(mensaje), backgroundColor: color));
  }

  Widget _construirIndicadorTresLecturas() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(3, (index) {
        final bool completado =
            _huellaTemplate != null || _toquesCompletados > index;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: completado ? const Color(0xFF28A745) : Colors.transparent,
            border: Border.all(
              color: completado ? const Color(0xFF28A745) : Colors.blue,
              width: 2,
            ),
          ),
          child: completado
              ? const Icon(Icons.check, size: 14, color: Colors.white)
              : Center(
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                  ),
                ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double importeActual =
        (_planSeleccionado['precio'] as num).toDouble();

    return AlertDialog(
      title: const Text(
        'Registrar Nuevo Socio',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      content: SizedBox(
        width: 820,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 1,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 160,
                        height: 160,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.grey.shade300),
                          image: (_fotoPath != null && !_camaraActiva)
                              ? DecorationImage(
                                  image: FileImage(File(_fotoPath!)),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: _camaraActiva && _isCamaraInicializada
                              ? AspectRatio(
                                  aspectRatio: 1.0,
                                  child: CameraPreview(_cameraController!),
                                )
                              : (_fotoPath == null
                                    ? Icon(
                                        Icons.person_outline,
                                        size: 80,
                                        color: Colors.grey.shade400,
                                      )
                                    : null),
                        ),
                      ),
                      const SizedBox(height: 15),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _camaraActiva
                              ? ElevatedButton.icon(
                                  onPressed: _tomarFoto,
                                  icon: const Icon(Icons.camera),
                                  label: const Text('Capturar'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF28A745),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                  ),
                                )
                              : OutlinedButton.icon(
                                  onPressed: _encenderCamara,
                                  icon: const Icon(Icons.videocam, size: 16),
                                  label: const Text('Cámara'),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                  ),
                                ),
                          const SizedBox(width: 10),
                          OutlinedButton.icon(
                            onPressed: _subirFoto,
                            icon: const Icon(Icons.upload_file, size: 16),
                            label: const Text('Subir'),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 25),
                      Container(
                        padding: const EdgeInsets.all(15),
                        decoration: BoxDecoration(
                          color: _huellaTemplate != null
                              ? Colors.green.shade50
                              : Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _huellaTemplate != null
                                ? Colors.green
                                : Colors.grey.shade300,
                          ),
                        ),
                        child: Column(
                          children: [
                            Icon(
                              _huellaTemplate != null
                                  ? Icons.fingerprint
                                  : Icons.fingerprint_outlined,
                              color: _huellaTemplate != null
                                  ? Colors.green
                                  : (_esperandoHuella
                                        ? Colors.blue
                                        : Colors.grey),
                              size: 40,
                            ),
                            const SizedBox(height: 8),
                            _construirIndicadorTresLecturas(),
                            const SizedBox(height: 10),
                            Text(
                              _mensajeEstadoHuella,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                color: _huellaTemplate != null
                                    ? Colors.green
                                    : Colors.grey.shade700,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 10),
                            if (_huellaTemplate == null && !_esperandoHuella)
                              ElevatedButton(
                                onPressed: _activarEscanerHuella,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF28A745),
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size(double.infinity, 36),
                                ),
                                child: const Text('Leer Huella (3 Tomas)'),
                              ),
                            if (_esperandoHuella) ...[
                              const SizedBox(height: 6),
                              OutlinedButton.icon(
                                onPressed: () {
                                  _dahuaService
                                      .solicitarEscaneoTresVecesEnLector();
                                },
                                icon: const Icon(Icons.fingerprint, size: 16),
                                label: const Text(
                                  'Reenviar orden al sensor de huella',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                              TextButton(
                                onPressed: () {
                                  _dahuaService
                                      .desactivarModoCapturaNuevoSocio();
                                  _dahuaSub?.cancel();
                                  _wsChannel?.sink.close();
                                  setState(() {
                                    _esperandoHuella = false;
                                    _toquesCompletados = 0;
                                    _mensajeEstadoHuella =
                                        'Ponga el dedo en el escáner (3 lecturas)';
                                  });
                                },
                                child: const Text(
                                  'Cancelar espera',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.red,
                                  ),
                                ),
                              ),
                            ],
                            if (_huellaTemplate != null)
                              TextButton.icon(
                                onPressed: _activarEscanerHuella,
                                icon: const Icon(Icons.refresh, size: 15),
                                label: const Text(
                                  'Volver a leer huella',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 30),
                Expanded(
                  flex: 2,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFormField(
                        controller: _ciController,
                        decoration: const InputDecoration(
                          labelText: 'Carnet de Identidad (CI)*',
                          prefixIcon: Icon(Icons.badge),
                        ),
                        validator: (val) =>
                            val == null || val.trim().isEmpty ? 'Requerido' : null,
                      ),
                      const SizedBox(height: 15),
                      TextFormField(
                        controller: _nombreController,
                        decoration: const InputDecoration(
                          labelText: 'Nombre Completo*',
                          prefixIcon: Icon(Icons.person),
                        ),
                        validator: (val) =>
                            val == null || val.trim().isEmpty ? 'Requerido' : null,
                      ),
                      const SizedBox(height: 15),
                      TextFormField(
                        controller: _telefonoController,
                        decoration: const InputDecoration(
                          labelText: 'Teléfono*',
                          prefixIcon: Icon(Icons.phone),
                        ),
                        validator: (val) =>
                            val == null || val.trim().isEmpty ? 'Requerido' : null,
                      ),
                      const SizedBox(height: 15),
                      TextFormField(
                        controller: _correoController,
                        decoration: const InputDecoration(
                          labelText: 'Correo Electrónico',
                          prefixIcon: Icon(Icons.email),
                        ),
                      ),
                      const SizedBox(height: 25),
                      Container(
                        padding: const EdgeInsets.all(15),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Identificador y Datos de Pago',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.green.shade50,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: Colors.green),
                                  ),
                                  child: Text(
                                    'Total: Bs ${importeActual.toStringAsFixed(2)}',
                                    style: TextStyle(
                                      color: Colors.green.shade800,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<Map<String, dynamic>>(
                              value: _planSeleccionado,
                              decoration: const InputDecoration(
                                labelText: 'Identificador de Membresía',
                                prefixIcon: Icon(Icons.fitness_center),
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: _planesDisponibles.map((plan) {
                                return DropdownMenuItem<Map<String, dynamic>>(
                                  value: plan,
                                  child: Text(
                                    '${plan['nombre']} - Bs ${(plan['precio'] as num).toStringAsFixed(2)}',
                                  ),
                                );
                              }).toList(),
                              onChanged: (nuevoPlan) {
                                if (nuevoPlan != null) {
                                  setState(() => _planSeleccionado = nuevoPlan);
                                }
                              },
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Método de Pago:',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: RadioListTile<String>(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Row(
                                      children: [
                                        Icon(
                                          Icons.payments_outlined,
                                          size: 18,
                                          color: Colors.green,
                                        ),
                                        SizedBox(width: 6),
                                        Text('Efectivo'),
                                      ],
                                    ),
                                    value: 'EFECTIVO',
                                    groupValue: _metodoPago,
                                    activeColor: const Color(0xFF28A745),
                                    onChanged: (val) {
                                      if (val != null) {
                                        setState(() => _metodoPago = val);
                                      }
                                    },
                                  ),
                                ),
                                Expanded(
                                  child: RadioListTile<String>(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Row(
                                      children: [
                                        Icon(
                                          Icons.qr_code_2,
                                          size: 18,
                                          color: Colors.blue,
                                        ),
                                        SizedBox(width: 6),
                                        Text('Pago QR'),
                                      ],
                                    ),
                                    value: 'QR',
                                    groupValue: _metodoPago,
                                    activeColor: const Color(0xFF28A745),
                                    onChanged: (val) {
                                      if (val != null) {
                                        setState(() => _metodoPago = val);
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                            if (_metodoPago == 'QR') ...[
                              const Divider(),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      _comprobanteQrPath != null
                                          ? 'Archivo: ${_comprobanteQrPath!.split(Platform.pathSeparator).last}'
                                          : 'Ningún comprobante seleccionado (Obligatorio)*',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: _comprobanteQrPath != null
                                            ? Colors.green.shade700
                                            : Colors.red.shade700,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  OutlinedButton.icon(
                                    onPressed: _subirComprobanteQr,
                                    icon: const Icon(
                                      Icons.upload_file,
                                      size: 16,
                                    ),
                                    label: Text(
                                      _comprobanteQrPath == null
                                          ? 'Subir Comprobante'
                                          : 'Cambiar',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _guardando ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
        ),
        ElevatedButton.icon(
          onPressed: _guardando
              ? null
              : () => _guardarSocio(imprimirBoleta: false),
          icon: _guardando
              ? const SizedBox.shrink()
              : const Icon(Icons.picture_as_pdf, size: 18),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blueGrey.shade800,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
          ),
          label: const Text('Guardar Comprobante en PDF'),
        ),
        ElevatedButton.icon(
          onPressed: _guardando
              ? null
              : () => _guardarSocio(imprimirBoleta: true),
          icon: _guardando
              ? const SizedBox.shrink()
              : const Icon(Icons.print, size: 18),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF28A745),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
          ),
          label: _guardando
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                )
              : const Text('Guardar e Imprimir Boleta'),
        ),
      ],
    );
  }
}