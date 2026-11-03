import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../../infrastructure/database/mysql_repository.dart';
import '../../application/services/dahua_biometric_service.dart';
import 'modal_nuevo_socio.dart';

class SociosDataGrid extends StatefulWidget {
  const SociosDataGrid({super.key});

  @override
  State<SociosDataGrid> createState() => _SociosDataGridState();
}

class _SociosDataGridState extends State<SociosDataGrid> {
  final SocioRepository _repository = SocioRepository();
  final DahuaBiometricService _dahuaService = DahuaBiometricService();
  final TextEditingController _busquedaController = TextEditingController();

  late Future<List<Map<String, dynamic>>> _sociosFuture;
  Timer? _relojTimer;
  StreamSubscription<Map<String, dynamic>>? _eventosSub;
  bool _sincronizandoMasivo = false;

  @override
  void initState() {
    super.initState();
    _cargarSocios();
    _conectarYSincronizarSociosExistentes();

    _eventosSub = _dahuaService.eventosStream.listen((evento) {
      if (evento['event'] == 'ACTUALIZAR_ASISTENCIAS' && mounted) {
        _cargarSocios();
      }
    });

    _relojTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) _cargarSocios();
    });
  }

  @override
  void dispose() {
    _relojTimer?.cancel();
    _eventosSub?.cancel();
    _busquedaController.dispose();
    super.dispose();
  }

  Future<void> _conectarYSincronizarSociosExistentes() async {
    try {
      final config = await _repository.obtenerConfiguracionSistema();
      final String ipConfig =
          (config['dahua_ip'] ?? '192.168.2.108').toString();
      final int puertoConfig =
          (config['dahua_puerto'] as num?)?.toInt() ?? 80;
      final String usuarioConfig =
          (config['dahua_usuario'] ?? 'admin').toString();
      final String passConfig =
          (config['dahua_password'] ?? 'Billblas').toString();

      await _dahuaService.configurarYConectar(
        nuevaIp: ipConfig == '192.168.1.108' ? '192.168.2.108' : ipConfig,
        nuevoPuerto: puertoConfig,
        nuevoUsuario: usuarioConfig,
        nuevaPassword: passConfig,
      );

      final sociosExistentes = await _repository.obtenerListaSocios();
      if (sociosExistentes.isNotEmpty) {
        await _dahuaService.sincronizarTodosLosSociosEnEquipo(
          sociosExistentes,
          forzar: false,
        );
      }
    } catch (_) {}
  }

  Future<void> _sincronizarPadronManualAlEquipo() async {
    if (_sincronizandoMasivo) return;
    setState(() => _sincronizandoMasivo = true);

    try {
      final config = await _repository.obtenerConfiguracionSistema();
      await _dahuaService.configurarYConectar(
        nuevaIp: (config['dahua_ip'] ?? '192.168.2.108').toString(),
        nuevoPuerto: (config['dahua_puerto'] as num?)?.toInt() ?? 80,
        nuevoUsuario: (config['dahua_usuario'] ?? 'admin').toString(),
        nuevaPassword: (config['dahua_password'] ?? 'Billblas').toString(),
      );

      final todosLosSocios = await _repository.obtenerListaSocios();
      final int enviados =
          await _dahuaService.sincronizarTodosLosSociosEnEquipo(
            todosLosSocios,
            forzar: true,
          );

      if (!mounted) return;
      setState(() => _sincronizandoMasivo = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Sincronizadas $enviados de ${todosLosSocios.length} huellas en el lector (${_dahuaService.ip}).',
          ),
          backgroundColor: enviados > 0 ? Colors.green : Colors.orange,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _sincronizandoMasivo = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error sincronizando con el lector: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _cargarSocios() {
    setState(() {
      _sociosFuture = _repository.obtenerListaSocios(
        busqueda: _busquedaController.text.trim(),
      );
    });
  }

  Widget _construirAvatarSocio({
    required String? fotoUrl,
    required Color colorBorde,
  }) {
    final String rutaLimpia = (fotoUrl ?? '').trim();
    if (rutaLimpia.isNotEmpty) {
      final archivo = File(rutaLimpia);
      if (archivo.existsSync()) {
        return Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: colorBorde, width: 1.5),
          ),
          child: ClipOval(
            child: Image.file(
              archivo,
              width: 40,
              height: 40,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  Icon(Icons.person, color: colorBorde, size: 20),
            ),
          ),
        );
      }
    }

    return CircleAvatar(
      radius: 20,
      backgroundColor: colorBorde.withValues(alpha: 0.12),
      child: Icon(Icons.person, color: colorBorde, size: 20),
    );
  }

  Future<void> _abrirModalNuevoSocio() async {
    final creado = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const ModalNuevoSocio(),
    );

    if (creado == true && mounted) {
      _cargarSocios();
      _dahuaService.emitirActualizacionAsistencias();
    }
  }

  Future<void> _abrirModalRenovacion(Map<String, dynamic> socio) async {
    final List<Map<String, dynamic>> planes = [
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

    Map<String, dynamic> planSeleccionado =
        (socio['plan_id'] == 2) ? planes[1] : planes[0];
    String metodoPago = 'EFECTIVO';
    String? comprobanteQrPath;
    bool procesando = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final double importe =
                (planSeleccionado['precio'] as num).toDouble();

            Future<void> ejecutarRenovacion({required bool imprimir}) async {
              if (metodoPago == 'QR' && comprobanteQrPath == null) {
                ScaffoldMessenger.of(this.context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Debe subir el comprobante del pago por QR obligatoriamente.',
                    ),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }

              setModalState(() => procesando = true);

              final nuevaFechaVenc = await _repository.renovarMensualidad(
                socioId: socio['id'].toString(),
                planId: planSeleccionado['id'] as int,
                diasDuracion: planSeleccionado['dias'] as int,
                importe: importe,
                metodoPago: metodoPago,
                comprobanteUrl: metodoPago == 'QR' ? comprobanteQrPath : null,
              );

              if (nuevaFechaVenc != null) {
                final String codigoHuella =
                    (socio['template_huella'] ?? '').toString().trim();

                if (codigoHuella.isNotEmpty) {
                  await _dahuaService.sincronizarSocioEnLectorDahua(
                    ci: codigoHuella,
                    nombreCompleto: socio['nombre_completo'].toString(),
                    fingerprintBase64: socio['packet_data']?.toString(),
                    fechaVencimiento: nuevaFechaVenc,
                    reproducirVozAlSincronizar: true,
                  );
                }

                await _repository.registrarAccesoPorHuella(
                  socioId: socio['id'].toString(),
                );
                _dahuaService.emitirActualizacionAsistencias();

                await _repository.generarEImprimirBoleta(
                  nombreSocio: socio['nombre_completo'].toString(),
                  ciSocio: socio['ci'].toString(),
                  conceptoPlan: (planSeleccionado['id'] == 2)
                      ? 'Sesión Diaria'
                      : 'Mensual / Socio',
                  importe: importe,
                  metodoPago: metodoPago,
                  fechaVencimiento: nuevaFechaVenc,
                  imprimir: imprimir,
                );

                if (!mounted) return;
                Navigator.of(ctx).pop();
                _cargarSocios();

                ScaffoldMessenger.of(this.context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Membresía renovada y huella sincronizada en tiempo real.',
                    ),
                    backgroundColor: Colors.green,
                  ),
                );
              } else {
                setModalState(() => procesando = false);
                ScaffoldMessenger.of(this.context).showSnackBar(
                  SnackBar(
                    content: Text(
                      _repository.ultimoError ?? 'Error al renovar.',
                    ),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            }

            return AlertDialog(
              title: Text(
                'Renovar: ${socio['nombre_completo']}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'C.I.: ${socio['ci']}  •  Huella N°: ${socio['template_huella']}  •  Estado: ${socio['estado']}',
                      style: TextStyle(color: Colors.grey.shade700),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<Map<String, dynamic>>(
                      value: planSeleccionado,
                      decoration: const InputDecoration(
                        labelText: 'Seleccione Plan o Sesión',
                        prefixIcon: Icon(Icons.fitness_center),
                        border: OutlineInputBorder(),
                      ),
                      items: planes.map((p) {
                        return DropdownMenuItem<Map<String, dynamic>>(
                          value: p,
                          child: Text(
                            '${p['nombre']} - Bs ${(p['precio'] as num).toStringAsFixed(2)}',
                          ),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setModalState(() => planSeleccionado = val);
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Método de Pago:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: RadioListTile<String>(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Efectivo'),
                            value: 'EFECTIVO',
                            groupValue: metodoPago,
                            activeColor: const Color(0xFF28A745),
                            onChanged: (v) {
                              if (v != null) {
                                setModalState(() => metodoPago = v);
                              }
                            },
                          ),
                        ),
                        Expanded(
                          child: RadioListTile<String>(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Pago QR'),
                            value: 'QR',
                            groupValue: metodoPago,
                            activeColor: const Color(0xFF28A745),
                            onChanged: (v) {
                              if (v != null) {
                                setModalState(() => metodoPago = v);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    if (metodoPago == 'QR') ...[
                      const Divider(),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              comprobanteQrPath != null
                                  ? 'Comprobante cargado'
                                  : 'Subir comprobante QR (Obligatorio)*',
                              style: TextStyle(
                                fontSize: 12,
                                color: comprobanteQrPath != null
                                    ? Colors.green.shade700
                                    : Colors.red.shade700,
                              ),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: () async {
                              final file = await FilePicker.pickFile(
                                type: FileType.image,
                              );
                              if (file != null && file.path != null) {
                                setModalState(
                                  () => comprobanteQrPath = file.path,
                                );
                              }
                            },
                            icon: const Icon(Icons.upload_file, size: 16),
                            label: const Text('Subir QR'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                      procesando ? null : () => Navigator.of(ctx).pop(),
                  child: const Text(
                    'Cancelar',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: procesando
                      ? null
                      : () => ejecutarRenovacion(imprimir: false),
                  icon: const Icon(Icons.picture_as_pdf, size: 17),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey.shade800,
                    foregroundColor: Colors.white,
                  ),
                  label: const Text('Guardar PDF'),
                ),
                ElevatedButton.icon(
                  onPressed: procesando
                      ? null
                      : () => ejecutarRenovacion(imprimir: true),
                  icon: const Icon(Icons.print, size: 17),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF28A745),
                    foregroundColor: Colors.white,
                  ),
                  label: const Text('Guardar e Imprimir'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _confirmarEliminarSocio(Map<String, dynamic> socio) async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar Socio'),
        content: Text(
          '¿Está seguro de eliminar a ${socio['nombre_completo']} (CI: ${socio['ci']}) de la base de datos y del lector de huella?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Sí, Borrar'),
          ),
        ],
      ),
    );

    if (confirmar == true) {
      final String template =
          (socio['template_huella'] ?? '').toString().trim();

      if (template.isNotEmpty) {
        await _dahuaService.eliminarSocioDeLectorDahua(template);
      }

      final ok = await _repository.eliminarSocio(socio['id'].toString());
      if (ok && mounted) {
        _cargarSocios();
        _dahuaService.emitirActualizacionAsistencias();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Socio y huella eliminados de la base de datos y del lector.',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
          ),
        ],
      ),
      child: Column(
        children: [
          // --- CABECERA ADAPTABLE SIN OVERFLOW ---
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Padrón de Socios & Control de Huellas',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Sincronizado en tiempo real con el lector de huella (192.168.2.108) y Control de Asistencias.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _sincronizandoMasivo
                          ? null
                          : _sincronizarPadronManualAlEquipo,
                      icon: _sincronizandoMasivo
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.fingerprint, size: 18),
                      label: Text(
                        _sincronizandoMasivo
                            ? 'Sincronizando...'
                            : 'Sincronizar Huellas al Lector',
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      height: 40,
                      child: TextField(
                        controller: _busquedaController,
                        onChanged: (_) => _cargarSocios(),
                        decoration: InputDecoration(
                          hintText: 'Buscar por CI o Nombre...',
                          prefixIcon: const Icon(Icons.search, size: 18),
                          suffixIcon: _busquedaController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 16),
                                  onPressed: () {
                                    _busquedaController.clear();
                                    _cargarSocios();
                                  },
                                )
                              : null,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: _abrirModalNuevoSocio,
                      icon: const Icon(Icons.person_add_alt_1, size: 18),
                      label: const Text('+ Agregar Nuevo'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF28A745),
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
          const Divider(height: 1),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            color: Colors.grey.shade50,
            child: const Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(
                    'FOTO / SOCIO / C.I. / CONTACTO',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.black54,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    'PLAN / N° HUELLA',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.black54,
                    ),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    'VIGENCIA (RELOJ PC)',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.black54,
                    ),
                  ),
                ),
                Expanded(
                  flex: 1,
                  child: Text(
                    'ESTADO',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.black54,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      'ACCIONES',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.black54,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _sociosFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFF28A745)),
                  );
                }

                final socios = snapshot.data ?? [];
                if (socios.isEmpty) {
                  return const Center(
                    child: Text(
                      'No se encontraron socios registrados.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  itemCount: socios.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final s = socios[index];
                    final bool esVigente = s['estado'] == 'Vigente';
                    final Color colorEstado =
                        esVigente ? const Color(0xFF28A745) : Colors.red;
                    final String tel = (s['telefono'] ?? '').toString();
                    final String correo = (s['correo'] ?? '').toString();

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Row(
                              children: [
                                _construirAvatarSocio(
                                  fotoUrl: s['foto_url']?.toString(),
                                  colorBorde: colorEstado,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        s['nombre_completo'].toString(),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        'CI: ${s['ci']}${tel.isNotEmpty ? " • Tel: $tel" : ""}${correo.isNotEmpty ? " • $correo" : ""}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade600,
                                        ),
                                        overflow: TextOverflow.ellipsis,
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
                                Text(
                                  s['identificador'].toString(),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  'Huella N°: ${s['template_huella']}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.green.shade800,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text(
                              s['detalle_validez'].toString(),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: esVigente
                                    ? Colors.green.shade800
                                    : Colors.red.shade800,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 1,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: esVigente
                                    ? Colors.green.shade50
                                    : Colors.red.shade50,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: colorEstado),
                              ),
                              child: Text(
                                s['estado'].toString(),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: colorEstado,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: () => _abrirModalRenovacion(s),
                                  icon: const Icon(Icons.autorenew, size: 16),
                                  label: const Text('Renovar'),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  tooltip: 'Borrar Socio',
                                  onPressed: () =>
                                      _confirmarEliminarSocio(s),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    color: Colors.red,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}