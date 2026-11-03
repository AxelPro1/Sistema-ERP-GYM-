import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../infrastructure/database/mysql_repository.dart';
import '../../application/services/dahua_biometric_service.dart';

class KioskoAccesoScreen extends StatefulWidget {
  const KioskoAccesoScreen({super.key});

  @override
  State<KioskoAccesoScreen> createState() => _KioskoAccesoScreenState();
}

class _KioskoAccesoScreenState extends State<KioskoAccesoScreen> {
  final SocioRepository _repository = SocioRepository();
  final DahuaBiometricService _dahuaService = DahuaBiometricService();

  StreamSubscription<Map<String, dynamic>>? _dahuaSub;
  WebSocketChannel? _wsChannel;
  Timer? _relojTimer;
  Timer? _autoRefrescoTimer;
  Timer? _limpiarTarjetaTimer;

  DateTime _horaActualPc = DateTime.now();
  DateTime? _ultimaLecturaProcesada;

  Map<String, dynamic>? _ultimoSocioVerificado;
  List<Map<String, dynamic>> _historialIngresos = [];
  bool _cargandoHistorial = true;

  @override
  void initState() {
    super.initState();
    _cargarHistorialIngresos();
    _conectarYEscucharLectorEnVivo();

    _relojTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _horaActualPc = DateTime.now());
      }
    });

    _autoRefrescoTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) {
        _cargarHistorialIngresos();
      }
    });
  }

  @override
  void dispose() {
    _relojTimer?.cancel();
    _autoRefrescoTimer?.cancel();
    _limpiarTarjetaTimer?.cancel();
    _dahuaSub?.cancel();
    _wsChannel?.sink.close();
    super.dispose();
  }

  Future<void> _cargarHistorialIngresos() async {
    final lista = await _repository.obtenerHistorialAccesos();
    if (!mounted) return;
    setState(() {
      _historialIngresos = lista;
      _cargandoHistorial = false;
    });
  }

  Future<void> _conectarYEscucharLectorEnVivo() async {
    final config = await _repository.obtenerConfiguracionSistema();
    await _dahuaService.configurarYConectar(
      nuevaIp: (config['dahua_ip'] ?? '192.168.2.108').toString(),
      nuevoPuerto: (config['dahua_puerto'] as num?)?.toInt() ?? 80,
      nuevoUsuario: (config['dahua_usuario'] ?? 'admin').toString(),
      nuevaPassword: (config['dahua_password'] ?? 'Billblas').toString(),
      forzarReconexion: false,
    );

    _dahuaSub?.cancel();
    _dahuaSub = _dahuaService.eventosStream.listen((data) async {
      if (data['event'] == 'ACTUALIZAR_ASISTENCIAS') {
        await _cargarHistorialIngresos();
        return;
      }
      if (_dahuaService.enModoCapturaNuevoSocio) return;
      if (data['event'] == 'HUELLA_LEIDA') {
        await _procesarHuellaEnKiosko(data);
      }
    });

    try {
      _wsChannel?.sink.close();
      _wsChannel = WebSocketChannel.connect(Uri.parse('ws://localhost:8080'));
      _wsChannel!.stream.listen(
        (message) async {
          try {
            final data = jsonDecode(message);
            if (data is! Map<String, dynamic>) return;
            if (data['event'] == 'ACTUALIZAR_ASISTENCIAS') {
              await _cargarHistorialIngresos();
              return;
            }
            if (_dahuaService.enModoCapturaNuevoSocio) return;
            if (data['event'] == 'HUELLA_LEIDA') {
              await _procesarHuellaEnKiosko(data);
            }
          } catch (_) {}
        },
        onError: (_) {},
      );
    } catch (_) {}
  }

  /// Procesa en tiempo real la huella ingresada en el lector, actualiza la tarjeta
  /// principal del Kiosko y refresca la lista lateral de socios que ingresaron.
  Future<void> _procesarHuellaEnKiosko(Map<String, dynamic> data) async {
    final ahora = DateTime.now();
    if (_ultimaLecturaProcesada != null &&
        ahora.difference(_ultimaLecturaProcesada!).inMilliseconds < 850) {
      return;
    }
    _ultimaLecturaProcesada = ahora;

    final String codigoLeido =
        (data['id_huella'] ?? data['template'] ?? '').toString().trim();
    final String? packetData = data['packet_data']?.toString();

    final resultado = await _repository.registrarAccesoPorHuella(
      templateHuella: codigoLeido.isNotEmpty
          ? codigoLeido
          : 'HUELLA_NO_REGISTRADA',
      packetDataLeido: packetData,
    );

    if (!mounted) return;

    final bool exito = resultado['exito'] == true;
    if (exito) {
      unawaited(
        _dahuaService.reproducirAudioBienvenidaThorGym(
          'Verificación exitosa, bienvenidos a Thor Gym',
        ),
      );
    }

    setState(() {
      _ultimoSocioVerificado = resultado;
    });

    await _cargarHistorialIngresos();

    // Volver al estado de espera después de 12 segundos
    _limpiarTarjetaTimer?.cancel();
    _limpiarTarjetaTimer = Timer(const Duration(seconds: 12), () {
      if (mounted) {
        setState(() => _ultimoSocioVerificado = null);
      }
    });
  }

  String _formatearHora(DateTime dt) {
    return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}";
  }

  String _formatearFecha(DateTime dt) {
    return "${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}";
  }

  Widget _construirFotoSocio({
    required String? fotoUrl,
    required Color colorBorde,
    required double tamano,
    IconData iconoDefecto = Icons.person,
  }) {
    final String rutaLimpia = (fotoUrl ?? '').trim();
    if (rutaLimpia.isNotEmpty) {
      final archivo = File(rutaLimpia);
      if (archivo.existsSync()) {
        return Container(
          width: tamano,
          height: tamano,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: colorBorde, width: 3),
          ),
          child: ClipOval(
            child: Image.file(
              archivo,
              width: tamano,
              height: tamano,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  Icon(iconoDefecto, size: tamano * 0.5, color: colorBorde),
            ),
          ),
        );
      }
    }

    return Container(
      width: tamano,
      height: tamano,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colorBorde.withValues(alpha: 0.15),
        border: Border.all(color: colorBorde, width: 3),
      ),
      child: Icon(iconoDefecto, size: tamano * 0.5, color: colorBorde),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Column(
          children: [
            // --- BARRA SUPERIOR DEL KIOSKO ---
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
              decoration: const BoxDecoration(
                color: Color(0xFF1E293B),
                border: Border(
                  bottom: BorderSide(color: Colors.white12, width: 1),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF28A745),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.fitness_center,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'THOR GYM - KIOSKO DE CONTROL BIOMÉTRICO',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.8,
                            ),
                          ),
                          Text(
                            'Verificación de Socios y Usuarios por Huella Dactilar en Tiempo Real',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.greenAccent),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.fingerprint,
                              color: Colors.greenAccent,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Lector Activo: ${_dahuaService.ip}',
                              style: const TextStyle(
                                color: Colors.greenAccent,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${_formatearFecha(_horaActualPc)}  •  ${_formatearHora(_horaActualPc)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton.icon(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back, size: 18),
                        label: const Text('Volver al ERP'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // --- CONTENIDO PRINCIPAL DIVIDIDO EN 2 PANELES ---
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  children: [
                    // PANEL IZQUIERDO: LECTOR EN VIVO / ÚLTIMO SOCIO QUE INGRESÓ SU HUELLA
                    Expanded(
                      flex: 5,
                      child: _construirPanelVerificacionEnVivo(),
                    ),
                    const SizedBox(width: 24),

                    // PANEL DERECHO: LISTA EN TIEMPO REAL DE SOCIOS QUE INGRESAN SU HUELLA
                    Expanded(
                      flex: 6,
                      child: _construirPanelHistorialIngresosEnVivo(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Panel izquierdo: Muestra la tarjeta del socio que acaba de colocar su huella
  /// o la pantalla de espera activa del escáner.
  Widget _construirPanelVerificacionEnVivo() {
    if (_ultimoSocioVerificado == null) {
      return Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF28A745).withValues(alpha: 0.12),
                border: Border.all(
                  color: const Color(0xFF28A745),
                  width: 3,
                ),
              ),
              child: const Icon(
                Icons.fingerprint,
                size: 92,
                color: Color(0xFF28A745),
              ),
            ),
            const SizedBox(height: 28),
            const Text(
              'COLOQUE SU DEDO EN EL LECTOR',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            const Text(
              'El sistema verificará su huella dactilar en tiempo real y mostrará su estado de membresía y sesión de 4 horas.',
              style: TextStyle(color: Colors.white70, fontSize: 15),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Socios controlados hoy: ${_historialIngresos.length}',
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final res = _ultimoSocioVerificado!;
    final bool noEncontrado = res['no_encontrado'] == true;
    final String estado = (res['estado'] ?? 'Vencido').toString();
    final bool esVigente = estado == 'Vigente' && !noEncontrado;
    final Color colorTema =
        esVigente ? const Color(0xFF28A745) : Colors.redAccent;

    final String nombre = noEncontrado
        ? 'Usuario no encontrado en el sistema'
        : (res['nombre_completo'] ?? 'Socio').toString();
    final String ci = (res['ci'] ?? 'S/N').toString();
    final String huellaId = (res['template_huella'] ?? '').toString();
    final String plan = (res['identificador'] ?? 'Sin Plan').toString();
    final String tipoIngreso =
        (res['tipo_ingreso'] ?? 'INGRESO').toString();
    final String detalleVigencia =
        (res['detalle_vigencia'] ?? '').toString();
    final DateTime fechaHora =
        res['fecha_hora'] is DateTime ? res['fecha_hora'] : DateTime.now();

    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colorTema, width: 3),
        boxShadow: [
          BoxShadow(
            color: colorTema.withValues(alpha: 0.25),
            blurRadius: 24,
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              color: colorTema,
              borderRadius: BorderRadius.circular(30),
            ),
            child: Text(
              noEncontrado
                  ? 'ACCESO DENEGADO - HUELLA NO REGISTRADA'
                  : '$tipoIngreso PERMITIDO - ${estado.toUpperCase()}',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
          const SizedBox(height: 22),
          _construirFotoSocio(
            fotoUrl: noEncontrado ? null : res['foto_url']?.toString(),
            colorBorde: colorTema,
            tamano: 135,
            iconoDefecto: noEncontrado ? Icons.block : Icons.person,
          ),
          const SizedBox(height: 18),
          Text(
            nombre,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            noEncontrado
                ? 'La huella ingresada no pertenece a ningún socio activo'
                : 'C.I.: $ci   •   Plan: $plan   •   Huella N°: $huellaId',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 22),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colorTema.withValues(alpha: 0.5)),
            ),
            child: Column(
              children: [
                Text(
                  'Hora de ingreso: ${_formatearHora(fechaHora)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  detalleVigencia,
                  style: TextStyle(
                    color: esVigente ? Colors.greenAccent : Colors.redAccent,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Panel derecho: Lista en tiempo real de todos los usuarios y socios que ingresan su huella
  Widget _construirPanelHistorialIngresosEnVivo() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Socios y Usuarios que Ingresaron su Huella',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Actualización automática en tiempo real al colocar el dedo en el lector',
                      style: TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                  ],
                ),
                IconButton(
                  onPressed: _cargarHistorialIngresos,
                  icon: const Icon(Icons.refresh, color: Colors.white70),
                  tooltip: 'Actualizar lista',
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          Expanded(
            child: _cargandoHistorial
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFF28A745)),
                  )
                : _historialIngresos.isEmpty
                    ? const Center(
                        child: Text(
                          'Aún no hay lecturas de huella registradas.',
                          style: TextStyle(color: Colors.white54, fontSize: 15),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: _historialIngresos.length,
                        separatorBuilder: (_, __) =>
                            const Divider(color: Colors.white12, height: 16),
                        itemBuilder: (context, index) {
                          final item = _historialIngresos[index];
                          final String nombre =
                              (item['nombre_completo'] ?? 'Socio').toString();
                          final String ci = (item['ci'] ?? 'S/N').toString();
                          final String huella =
                              (item['template_huella'] ?? '').toString();
                          final String plan =
                              (item['identificador'] ?? 'Mensual / Socio')
                                  .toString();
                          final String tipoIngreso =
                              (item['tipo_ingreso'] ?? 'INGRESO').toString();
                          final String estado =
                              (item['estado'] ?? 'Vencido').toString();
                          final String detalleVigencia =
                              (item['detalle_vigencia'] ?? '').toString();
                          final DateTime fechaHora =
                              item['fecha_hora'] is DateTime
                                  ? item['fecha_hora']
                                  : DateTime.now();

                          final bool esVigente = estado == 'Vigente';
                          final Color colorEstado = esVigente
                              ? const Color(0xFF28A745)
                              : Colors.redAccent;

                          return Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: index == 0
                                    ? colorEstado.withValues(alpha: 0.7)
                                    : Colors.white10,
                              ),
                            ),
                            child: Row(
                              children: [
                                _construirFotoSocio(
                                  fotoUrl: item['foto_url']?.toString(),
                                  colorBorde: colorEstado,
                                  tamano: 52,
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              nombre,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 15,
                                                fontWeight: FontWeight.bold,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: colorEstado.withValues(
                                                alpha: 0.2,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              border: Border.all(
                                                color: colorEstado,
                                              ),
                                            ),
                                            child: Text(
                                              '$tipoIngreso • $estado',
                                              style: TextStyle(
                                                color: colorEstado,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'CI: $ci  •  $plan  •  Huella N°: $huella',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 12,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${_formatearHora(fechaHora)} (${_formatearFecha(fechaHora)})  •  $detalleVigencia',
                                        style: TextStyle(
                                          color: esVigente
                                              ? Colors.greenAccent
                                              : Colors.redAccent,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}