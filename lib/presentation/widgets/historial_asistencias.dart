import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../infrastructure/database/mysql_repository.dart';
import '../../application/services/dahua_biometric_service.dart';

class HistorialAsistenciasWidget extends StatefulWidget {
  @override
  _HistorialAsistenciasWidgetState createState() =>
      _HistorialAsistenciasWidgetState();
}

class _HistorialAsistenciasWidgetState
    extends State<HistorialAsistenciasWidget> {
  final SocioRepository _repository = SocioRepository();
  final DahuaBiometricService _dahuaService = DahuaBiometricService();

  String _filtroEstado = 'TODOS';
  DateTime? _fechaFiltro;

  late Future<List<Map<String, dynamic>>> _historialFuture;
  StreamSubscription<Map<String, dynamic>>? _dahuaSub;
  WebSocketChannel? _wsChannel;
  Timer? _relojTimer;
  Timer? _relojSegundoTimer;
  DateTime _horaActualPc = DateTime.now();
  DateTime? _ultimoProceso;

  @override
  void initState() {
    super.initState();
    _cargarHistorial();
    _conectarYSincronizarLectorEnTiempoReal();

    _relojSegundoTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _horaActualPc = DateTime.now());
      }
    });

    _relojTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) _cargarHistorial();
    });
  }

  @override
  void dispose() {
    _relojTimer?.cancel();
    _relojSegundoTimer?.cancel();
    _dahuaSub?.cancel();
    _wsChannel?.sink.close();
    super.dispose();
  }

  void _cargarHistorial() {
    setState(() {
      _historialFuture = _repository.obtenerHistorialAccesos(
        fecha: _fechaFiltro,
        filtroEstado: _filtroEstado,
      );
    });
  }

  Future<void> _conectarYSincronizarLectorEnTiempoReal() async {
    final config = await _repository.obtenerConfiguracionSistema();
    await _dahuaService.configurarYConectar(
      nuevaIp: (config['dahua_ip'] ?? '192.168.2.108').toString(),
      nuevoPuerto: (config['dahua_puerto'] as num?)?.toInt() ?? 80,
      nuevoUsuario: (config['dahua_usuario'] ?? 'admin').toString(),
      nuevaPassword: (config['dahua_password'] ?? '').toString(),
    );

    final socios = await _repository.obtenerListaSocios();
    if (socios.isNotEmpty) {
      await _dahuaService.sincronizarTodosLosSociosEnEquipo(
        socios,
        forzar: false,
      );
    }

    _iniciarEscuchaDahuaEnTiempoReal();
  }

  Widget _construirAvatarSocio({
    required String? fotoUrl,
    required Color colorEstado,
    double radio = 22,
    IconData iconoPorDefecto = Icons.person,
  }) {
    final String rutaLimpia = (fotoUrl ?? '').trim();
    if (rutaLimpia.isNotEmpty) {
      final archivoFoto = File(rutaLimpia);
      if (archivoFoto.existsSync()) {
        return Container(
          width: radio * 2,
          height: radio * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: colorEstado, width: 2),
          ),
          child: ClipOval(
            child: Image.file(
              archivoFoto,
              width: radio * 2,
              height: radio * 2,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  Icon(iconoPorDefecto, color: colorEstado, size: radio),
            ),
          ),
        );
      }
    }

    return CircleAvatar(
      radius: radio,
      backgroundColor: colorEstado.withOpacity(0.12),
      child: Icon(iconoPorDefecto, color: colorEstado, size: radio),
    );
  }

  /// Compara en tiempo real la huella puesta en el lector con la base de datos:
  /// - Si pertenece a un socio vigente, permite el ingreso y reproduce la bienvenida por audio.
  /// - Si no pertenece a ningún socio en la BD, niega el ingreso ("Usuario no encontrado en el sistema").
  Future<void> _procesarHuellaRecibida(Map<String, dynamic> data) async {
    if (_dahuaService.enModoCapturaNuevoSocio) return;

    final ahora = DateTime.now();
    if (_ultimoProceso != null &&
        ahora.difference(_ultimoProceso!).inMilliseconds < 850) {
      return;
    }
    _ultimoProceso = ahora;

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
    _cargarHistorial();

    final bool exito = resultado['exito'] == true;
    final bool noEncontrado = resultado['no_encontrado'] == true;

    if (exito) {
      unawaited(
        _dahuaService.reproducirAudioBienvenidaThorGym(
          'Verificación exitosa, bienvenidos a Thor Gym',
        ),
      );
    } else if (noEncontrado) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Acceso Denegado: Usuario no encontrado en el sistema',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 4),
        ),
      );
    }

    _mostrarModalResultadoLectura(resultado);
  }

  void _iniciarEscuchaDahuaEnTiempoReal() {
    _dahuaService.iniciarEscuchaEventosEnVivo();

    _dahuaSub?.cancel();
    _dahuaSub = _dahuaService.eventosStream.listen((data) async {
      if (data['event'] == 'ACTUALIZAR_ASISTENCIAS') {
        if (mounted) _cargarHistorial();
        return;
      }
      if (_dahuaService.enModoCapturaNuevoSocio) return;
      if (data['event'] == 'HUELLA_LEIDA') {
        await _procesarHuellaRecibida(data);
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
              if (mounted) _cargarHistorial();
              return;
            }
            if (_dahuaService.enModoCapturaNuevoSocio) return;
            if (data['event'] == 'HUELLA_LEIDA') {
              await _procesarHuellaRecibida(data);
            }
          } catch (_) {}
        },
        onError: (_) {},
      );
    } catch (_) {}
  }

  String _formatearFecha(DateTime dt) {
    return "${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}";
  }

  String _formatearHoraExacta(DateTime dt) {
    return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}";
  }

  Future<void> _seleccionarFecha() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _fechaFiltro ?? DateTime.now(),
      firstDate: DateTime(2024),
      lastDate: DateTime(2030),
    );
    if (picked != null) {
      setState(() => _fechaFiltro = picked);
      _cargarHistorial();
    }
  }

  void _mostrarModalResultadoLectura(Map<String, dynamic> resultado) {
    final bool noEncontrado = resultado['no_encontrado'] == true;
    final String estado = (resultado['estado'] ?? 'Vencido').toString();
    final bool esVigente = estado == 'Vigente' && !noEncontrado;
    final String tipoIngreso =
        (resultado['tipo_ingreso'] ?? 'INGRESO').toString();
    final String identificador =
        (resultado['identificador'] ?? 'No Registrado').toString();
    final String nombre = noEncontrado
        ? 'Usuario no encontrado en el sistema'
        : (resultado['nombre_completo'] ?? 'Usuario').toString();
    final String ci = (resultado['ci'] ?? 'S/N').toString();
    final String telefono = (resultado['telefono'] ?? '').toString();
    final String correo = (resultado['correo'] ?? '').toString();
    final String huellaId = (resultado['template_huella'] ?? '').toString();
    final String detalleVigencia = noEncontrado
        ? 'Acceso Denegado: La huella colocada no pertenece a ningún socio registrado'
        : (resultado['detalle_vigencia'] ?? '').toString();
    final DateTime fechaHoraActual =
        resultado['fecha_hora'] is DateTime
            ? resultado['fecha_hora']
            : DateTime.now();
    final DateTime? horaIngresoPrevio =
        resultado['hora_ingreso_previo'] is DateTime
            ? resultado['hora_ingreso_previo']
            : null;
    final String? fotoUrl = resultado['foto_url']?.toString();

    final Color colorTema = esVigente ? const Color(0xFF28A745) : Colors.red;

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          title: Row(
            children: [
              Icon(
                esVigente ? Icons.check_circle : Icons.block,
                color: colorTema,
                size: 30,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  noEncontrado
                      ? 'ACCESO DENEGADO'
                      : '$tipoIngreso PERMITIDO - ${estado.toUpperCase()}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: colorTema,
                    fontSize: 18,
                  ),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _construirAvatarSocio(
                  fotoUrl: noEncontrado ? null : fotoUrl,
                  colorEstado: colorTema,
                  radio: 48,
                  iconoPorDefecto:
                      noEncontrado ? Icons.fingerprint : Icons.person,
                ),
                const SizedBox(height: 12),
                Text(
                  nombre,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                    color: noEncontrado ? Colors.red.shade800 : Colors.black87,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  noEncontrado
                      ? 'Huella no encontrada en la base de datos'
                      : 'CI: $ci  •  Plan: $identificador  •  Huella: $huellaId',
                  style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                if (!noEncontrado &&
                    (telefono.isNotEmpty || correo.isNotEmpty)) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${telefono.isNotEmpty ? "Tel: $telefono" : ""}${telefono.isNotEmpty && correo.isNotEmpty ? "  •  " : ""}${correo.isNotEmpty ? correo : ""}',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: colorTema.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: colorTema.withOpacity(0.4)),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Hora de lectura (PC):',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            _formatearHoraExacta(fechaHoraActual),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                      if (!noEncontrado && horaIngresoPrevio != null) ...[
                        const Divider(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Ventana de 4 horas:',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              '${_formatearHoraExacta(horaIngresoPrevio)} → ${_formatearHoraExacta(horaIngresoPrevio.add(const Duration(hours: 4)))}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ],
                      const Divider(height: 16),
                      Text(
                        detalleVigencia,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: colorTema,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: colorTema,
                foregroundColor: Colors.white,
              ),
              child: const Text('Entendido'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _historialFuture,
      builder: (context, snapshot) {
        final registros = snapshot.data ?? [];

        int totalLecturas = registros.length;
        int totalVigentes = 0;
        int totalVencidos = 0;
        int totalReingresos = 0;

        for (var r in registros) {
          if (r['estado'] == 'Vigente') {
            totalVigentes++;
          } else {
            totalVencidos++;
          }
          if (r['tipo_ingreso'] == 'REINGRESO') {
            totalReingresos++;
          }
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _buildResumenCard(
                    titulo: 'Socios Controlados por Huella',
                    valor: '$totalLecturas',
                    icono: Icons.fingerprint,
                    color: Colors.blue.shade700,
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: _buildResumenCard(
                    titulo: 'Sesiones Vigentes (< 4h)',
                    valor: '$totalVigentes',
                    icono: Icons.check_circle_outline,
                    color: const Color(0xFF28A745),
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: _buildResumenCard(
                    titulo: 'Reingresos Verificados',
                    valor: '$totalReingresos',
                    icono: Icons.autorenew,
                    color: Colors.indigo,
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: _buildResumenCard(
                    titulo: 'Sesiones Vencidas (> 4h)',
                    valor: '$totalVencidos',
                    icono: Icons.cancel_outlined,
                    color: Colors.red,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Control de Asistencias por Huella en Tiempo Real',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Hora PC: ${_formatearHoraExacta(_horaActualPc)}  •  Lector Puente (${_dahuaService.ip})',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.green.shade800,
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.grey.shade300,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    value: _filtroEstado,
                                    icon: const Icon(Icons.filter_list),
                                    items: const [
                                      DropdownMenuItem(
                                        value: 'TODOS',
                                        child: Text('Todos los Socios'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'VIGENTE',
                                        child: Text('Estado: Vigente'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'VENCIDO',
                                        child: Text('Estado: Vencido'),
                                      ),
                                    ],
                                    onChanged: (nuevoFiltro) {
                                      if (nuevoFiltro != null) {
                                        setState(
                                          () => _filtroEstado = nuevoFiltro,
                                        );
                                        _cargarHistorial();
                                      }
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton.icon(
                                onPressed: _seleccionarFecha,
                                icon: const Icon(
                                  Icons.calendar_today,
                                  size: 16,
                                ),
                                label: Text(
                                  _fechaFiltro == null
                                      ? 'Todas las fechas'
                                      : _formatearFecha(_fechaFiltro!),
                                ),
                              ),
                              if (_fechaFiltro != null) ...[
                                const SizedBox(width: 4),
                                IconButton(
                                  onPressed: () {
                                    setState(() => _fechaFiltro = null);
                                    _cargarHistorial();
                                  },
                                  icon: const Icon(
                                    Icons.clear,
                                    size: 18,
                                    color: Colors.red,
                                  ),
                                ),
                              ],
                              const SizedBox(width: 6),
                              IconButton(
                                onPressed: _cargarHistorial,
                                icon: const Icon(Icons.refresh),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),

                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      color: Colors.grey.shade50,
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Text(
                              'FOTO / SOCIO / C.I. / CONTACTO',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              'HUELLA / PLAN',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              'HORA INGRESO (PC)',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text(
                              'CONTROL DE SESIÓN (4H) Y VIGENCIA',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 1,
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                'ESTADO',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey.shade700,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),

                    Expanded(
                      child: registros.isEmpty
                          ? const Center(
                              child: Text(
                                'Esperando lecturas del sensor de huella en tiempo real...',
                                style: TextStyle(color: Colors.grey),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 10,
                              ),
                              itemCount: registros.length,
                              itemBuilder: (context, index) =>
                                  _buildAsistenciaRow(registros[index]),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildResumenCard({
    required String titulo,
    required String valor,
    required IconData icono,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: color, width: 4)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titulo,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  valor,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          CircleAvatar(
            backgroundColor: color.withOpacity(0.12),
            child: Icon(icono, color: color, size: 22),
          ),
        ],
      ),
    );
  }

  Widget _buildAsistenciaRow(Map<String, dynamic> item) {
    final String nombre = item['nombre_completo'] ?? 'Usuario';
    final String ci = item['ci'] ?? 'S/N';
    final String telefono = (item['telefono'] ?? '').toString();
    final String huella = (item['template_huella'] ?? '').toString();
    final String identificador = item['identificador'] ?? 'Mensual / Socio';
    final String tipoIngreso = item['tipo_ingreso'] ?? 'INGRESO';
    final String estado = item['estado'] ?? 'Vencido';
    final String detalleVigencia = item['detalle_vigencia'] ?? '';
    final String? fotoUrl = item['foto_url']?.toString();
    final DateTime fechaHora = item['fecha_hora'];
    final DateTime horaInicioSesion =
        item['hora_ingreso_previo'] ?? fechaHora;
    final DateTime horaVenceSesion =
        item['fecha_vencimiento_sesion'] ??
        horaInicioSesion.add(const Duration(hours: 4));

    final bool isVigente = estado == 'Vigente';
    final bool esReingreso = tipoIngreso == 'REINGRESO';
    final Color colorEstado = isVigente ? const Color(0xFF28A745) : Colors.red;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Row(
              children: [
                _construirAvatarSocio(
                  fotoUrl: fotoUrl,
                  colorEstado: colorEstado,
                  radio: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        nombre,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'CI: $ci${telefono.isNotEmpty ? " • Tel: $telefono" : ""}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: esReingreso
                            ? Colors.purple.shade50
                            : Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: esReingreso
                              ? Colors.purple.shade300
                              : Colors.blue.shade300,
                        ),
                      ),
                      child: Text(
                        tipoIngreso,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: esReingreso
                              ? Colors.purple.shade800
                              : Colors.blue.shade800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '$identificador • ID: $huella',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade800,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _formatearHoraExacta(fechaHora),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatearFecha(fechaHora),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  detalleVigencia,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isVigente
                        ? Colors.green.shade800
                        : Colors.red.shade800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Inicio: ${_formatearHoraExacta(horaInicioSesion)}  •  Límite 4h: ${_formatearHoraExacta(horaVenceSesion)}',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 1,
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: isVigente ? Colors.green.shade50 : Colors.red.shade50,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isVigente ? Colors.green : Colors.red,
                  ),
                ),
                child: Text(
                  estado,
                  style: TextStyle(
                    color: isVigente
                        ? Colors.green.shade700
                        : Colors.red.shade700,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}