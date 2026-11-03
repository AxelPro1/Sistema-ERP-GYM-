import 'package:flutter/material.dart';
import '../../infrastructure/database/mysql_repository.dart';

class ReportesWidget extends StatefulWidget {
  @override
  _ReportesWidgetState createState() => _ReportesWidgetState();
}

class _ReportesWidgetState extends State<ReportesWidget> {
  final SocioRepository _repository = SocioRepository();

  DateTime _fechaDesde = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    1,
  );
  DateTime _fechaHasta = DateTime.now();
  int _tabSeleccionada = 0; // 0 = Finanzas, 1 = Asistencias, 2 = Estado Socios
  bool _cargando = true;
  bool _exportandoPdf = false;

  List<Map<String, dynamic>> _pagos = [];
  List<Map<String, dynamic>> _asistencias = [];
  List<Map<String, dynamic>> _socios = [];

  @override
  void initState() {
    super.initState();
    _cargarDatosReportes();
  }

  Future<void> _cargarDatosReportes() async {
    setState(() => _cargando = true);
    final pagos = await _repository.obtenerPagosPorRango(
      desde: _fechaDesde,
      hasta: _fechaHasta,
    );
    final asistencias = await _repository.obtenerAsistenciasPorRango(
      desde: _fechaDesde,
      hasta: _fechaHasta,
    );
    final socios = await _repository.obtenerListaSocios();

    if (!mounted) return;
    setState(() {
      _pagos = pagos;
      _asistencias = asistencias;
      _socios = socios;
      _cargando = false;
    });
  }

  String _fmtFecha(DateTime d) =>
      "${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}";

  String _fmtFechaHora(DateTime d) =>
      "${_fmtFecha(d)} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}";

  Future<void> _seleccionarRangoFechas() async {
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime(2030),
      initialDateRange: DateTimeRange(start: _fechaDesde, end: _fechaHasta),
    );
    if (picked != null) {
      setState(() {
        _fechaDesde = picked.start;
        _fechaHasta = picked.end;
      });
      _cargarDatosReportes();
    }
  }

  void _aplicarFiltroRapido(String tipo) {
    final ahora = DateTime.now();
    setState(() {
      if (tipo == 'HOY') {
        _fechaDesde = DateTime(ahora.year, ahora.month, ahora.day);
        _fechaHasta = ahora;
      } else if (tipo == 'SEMANA') {
        _fechaDesde = ahora.subtract(const Duration(days: 6));
        _fechaHasta = ahora;
      } else if (tipo == 'MES') {
        _fechaDesde = DateTime(ahora.year, ahora.month, 1);
        _fechaHasta = ahora;
      }
    });
    _cargarDatosReportes();
  }

  Future<void> _exportarReportePdf({required bool imprimir}) async {
    setState(() => _exportandoPdf = true);

    String titulo = '';
    List<Map<String, String>> kpis = [];
    List<String> headers = [];
    List<List<String>> rows = [];

    if (_tabSeleccionada == 0) {
      titulo = 'Reporte Financiero de Ingresos y Membresías';
      double totalConfirmado = 0;
      double totalMensualidades = 0;
      double totalSesionesDiarias = 0;

      for (var p in _pagos) {
        final bool confirmado =
            p['metodo_pago'] == 'EFECTIVO' || p['qr_verificado'] == true;
        final double imp = (p['importe'] as num).toDouble();
        if (confirmado) {
          totalConfirmado += imp;
          if (p['es_sesion_diaria'] == true) {
            totalSesionesDiarias += imp;
          } else {
            totalMensualidades += imp;
          }
        }
      }

      kpis = [
        {
          'titulo': 'Total Recaudado',
          'valor': 'Bs ${totalConfirmado.toStringAsFixed(2)}',
        },
        {
          'titulo': 'Mensualidades (100 Bs)',
          'valor': 'Bs ${totalMensualidades.toStringAsFixed(2)}',
        },
        {
          'titulo': 'Sesiones Diarias (10 Bs)',
          'valor': 'Bs ${totalSesionesDiarias.toStringAsFixed(2)}',
        },
        {'titulo': 'Transacciones', 'valor': '${_pagos.length}'},
      ];

      headers = ['Fecha / Hora', 'Socio', 'C.I.', 'Concepto', 'Método', 'Monto'];
      rows = _pagos.map((p) {
        return [
          _fmtFechaHora(p['fecha_pago'] as DateTime),
          p['nombre_completo'].toString(),
          p['ci'].toString(),
          p['concepto'].toString(),
          p['metodo_pago'].toString(),
          'Bs ${(p['importe'] as num).toStringAsFixed(2)}',
        ];
      }).toList();
    } else if (_tabSeleccionada == 1) {
      titulo = 'Reporte de Control de Asistencias Biométricas';
      int vigentes =
          _asistencias.where((a) => a['estado'] == 'Vigente').length;
      int vencidos =
          _asistencias.where((a) => a['estado'] != 'Vigente').length;

      kpis = [
        {'titulo': 'Total Lecturas', 'valor': '${_asistencias.length}'},
        {'titulo': 'Accesos Vigentes', 'valor': '$vigentes'},
        {'titulo': 'Accesos Vencidos', 'valor': '$vencidos'},
      ];

      headers = [
        'Fecha / Hora',
        'Usuario',
        'C.I.',
        'Tipo / Movimiento',
        'Vigencia',
        'Estado',
      ];
      rows = _asistencias.map((a) {
        return [
          _fmtFechaHora(a['fecha_hora'] as DateTime),
          a['nombre_completo'].toString(),
          a['ci'].toString(),
          '${a['identificador']} (${a['tipo_ingreso']})',
          a['detalle_vigencia'].toString(),
          a['estado'].toString(),
        ];
      }).toList();
    } else {
      titulo = 'Reporte General de Padrón de Socios y Sesiones';
      int mensualesVigentes = _socios
          .where((s) => s['plan_id'] == 1 && s['estado'] == 'Vigente')
          .length;
      int mensualesVencidos = _socios
          .where((s) => s['plan_id'] == 1 && s['estado'] == 'Vencido')
          .length;
      int sesionesDiarias =
          _socios.where((s) => s['plan_id'] == 2).length;

      kpis = [
        {'titulo': 'Mensuales Vigentes', 'valor': '$mensualesVigentes'},
        {'titulo': 'Mensualidades Vencidas', 'valor': '$mensualesVencidos'},
        {'titulo': 'Pases Sesión Diaria', 'valor': '$sesionesDiarias'},
      ];

      headers = [
        'Nombre Completo',
        'C.I.',
        'Identificador',
        'Detalle de Vigencia',
        'Estado',
      ];
      rows = _socios.map((s) {
        return [
          s['nombre_completo'].toString(),
          s['ci'].toString(),
          s['identificador'].toString(),
          s['detalle_validez'].toString(),
          s['estado'].toString(),
        ];
      }).toList();
    }

    final ruta = await _repository.generarReporteEjecutivoPdf(
      tituloReporte: titulo,
      desde: _fechaDesde,
      hasta: _fechaHasta,
      resumenKpis: kpis,
      cabecerasTabla: headers,
      filasTabla: rows,
      imprimir: imprimir,
    );

    if (!mounted) return;
    setState(() => _exportandoPdf = false);

    if (ruta != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            imprimir
                ? 'Reporte enviado a impresión y respaldado en $ruta'
                : 'Reporte PDF guardado en: $ruta',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Error al generar PDF: ${_repository.ultimoError ?? "Error desconocido"}',
          ),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Cálculos de resumen financiero
    double totalIngresosConfirmados = 0;
    double totalMensualidadesBs = 0;
    double totalSesionesDiariasBs = 0;

    for (var p in _pagos) {
      final bool confirmado =
          p['metodo_pago'] == 'EFECTIVO' || p['qr_verificado'] == true;
      final double imp = (p['importe'] as num).toDouble();
      if (confirmado) {
        totalIngresosConfirmados += imp;
        if (p['es_sesion_diaria'] == true) {
          totalSesionesDiariasBs += imp;
        } else {
          totalMensualidadesBs += imp;
        }
      }
    }

    final int sociosMensualesVigentes = _socios
        .where((s) => s['plan_id'] == 1 && s['estado'] == 'Vigente')
        .length;
    final int sociosMensualesVencidos = _socios
        .where((s) => s['plan_id'] == 1 && s['estado'] == 'Vencido')
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // --- 1. BARRA SUPERIOR DE FILTROS DE FECHA Y EXPORTACIÓN PDF ---
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.analytics_outlined,
                    color: Color(0xFF28A745),
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Reportes y Auditoría del Sistema',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Periodo seleccionado: ${_fmtFecha(_fechaDesde)} al ${_fmtFecha(_fechaHasta)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: () => _aplicarFiltroRapido('HOY'),
                    child: const Text('Hoy'),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton(
                    onPressed: () => _aplicarFiltroRapido('SEMANA'),
                    child: const Text('7 Días'),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton(
                    onPressed: () => _aplicarFiltroRapido('MES'),
                    child: const Text('Este Mes'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _seleccionarRangoFechas,
                    icon: const Icon(Icons.date_range, size: 16),
                    label: const Text('Rango de Fechas'),
                  ),
                  const SizedBox(width: 14),
                  ElevatedButton.icon(
                    onPressed: _exportandoPdf
                        ? null
                        : () => _exportarReportePdf(imprimir: false),
                    icon: const Icon(Icons.picture_as_pdf, size: 17),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueGrey.shade800,
                      foregroundColor: Colors.white,
                    ),
                    label: const Text('Guardar PDF'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _exportandoPdf
                        ? null
                        : () => _exportarReportePdf(imprimir: true),
                    icon: const Icon(Icons.print, size: 17),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF28A745),
                      foregroundColor: Colors.white,
                    ),
                    label: const Text('Imprimir Reporte'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // --- 2. TARJETAS KPI DEL PERIODO ---
        Row(
          children: [
            Expanded(
              child: _buildKpi(
                'Ingresos Confirmados',
                'Bs ${totalIngresosConfirmados.toStringAsFixed(2)}',
                Icons.account_balance_wallet,
                const Color(0xFF28A745),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildKpi(
                'Por Mensualidades (100 Bs)',
                'Bs ${totalMensualidadesBs.toStringAsFixed(2)}',
                Icons.card_membership,
                Colors.indigo,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildKpi(
                'Por Sesiones Diarias (10 Bs)',
                'Bs ${totalSesionesDiariasBs.toStringAsFixed(2)}',
                Icons.bolt,
                Colors.amber.shade800,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildKpi(
                'Mensualidades Vigentes / Vencidas',
                '$sociosMensualesVigentes Vig. / $sociosMensualesVencidos Venc.',
                Icons.people_alt_outlined,
                Colors.teal,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // --- 3. PESTAÑAS Y TABLA DETALLADA ---
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 8,
                ),
              ],
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      _buildTabButton(
                        index: 0,
                        titulo: '1. Ingresos y Finanzas (${_pagos.length})',
                        icono: Icons.payments_outlined,
                      ),
                      const SizedBox(width: 10),
                      _buildTabButton(
                        index: 1,
                        titulo:
                            '2. Asistencias Biométricas (${_asistencias.length})',
                        icono: Icons.fingerprint,
                      ),
                      const SizedBox(width: 10),
                      _buildTabButton(
                        index: 2,
                        titulo: '3. Estado de Socios (${_socios.length})',
                        icono: Icons.badge_outlined,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _cargando
                      ? const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF28A745),
                          ),
                        )
                      : _construirContenidoTab(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTabButton({
    required int index,
    required String titulo,
    required IconData icono,
  }) {
    final bool activo = _tabSeleccionada == index;
    return ElevatedButton.icon(
      onPressed: () => setState(() => _tabSeleccionada = index),
      icon: Icon(icono, size: 17),
      label: Text(titulo),
      style: ElevatedButton.styleFrom(
        elevation: 0,
        backgroundColor:
            activo ? const Color(0xFF28A745) : Colors.grey.shade100,
        foregroundColor: activo ? Colors.white : Colors.grey.shade800,
      ),
    );
  }

  Widget _construirContenidoTab() {
    if (_tabSeleccionada == 0) {
      if (_pagos.isEmpty) {
        return const Center(
          child: Text(
            'No hay pagos registrados en este rango de fechas.',
            style: TextStyle(color: Colors.grey),
          ),
        );
      }
      return ListView.separated(
        padding: const EdgeInsets.all(20),
        itemCount: _pagos.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final p = _pagos[index];
          final bool esQr = p['metodo_pago'] == 'QR';
          final bool verificado = p['qr_verificado'] == true;
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: Colors.green.shade50,
              child: Icon(
                esQr ? Icons.qr_code_2 : Icons.payments_outlined,
                color: Colors.green.shade800,
              ),
            ),
            title: Text(
              '${p['nombre_completo']} (CI: ${p['ci']})',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              '${p['concepto']} • Fecha: ${_fmtFechaHora(p['fecha_pago'] as DateTime)} • Método: ${p['metodo_pago']}',
            ),
            trailing: Text(
              'Bs ${(p['importe'] as num).toStringAsFixed(2)}${esQr && !verificado ? " (Pendiente)" : ""}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
                color: esQr && !verificado
                    ? Colors.orange.shade800
                    : Colors.green.shade800,
              ),
            ),
          );
        },
      );
    }

    if (_tabSeleccionada == 1) {
      if (_asistencias.isEmpty) {
        return const Center(
          child: Text(
            'No hay asistencias biométricas en este rango de fechas.',
            style: TextStyle(color: Colors.grey),
          ),
        );
      }
      return ListView.separated(
        padding: const EdgeInsets.all(20),
        itemCount: _asistencias.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final a = _asistencias[index];
          final bool vigente = a['estado'] == 'Vigente';
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor:
                  vigente ? Colors.green.shade50 : Colors.red.shade50,
              child: Icon(
                Icons.fingerprint,
                color: vigente ? Colors.green : Colors.red,
              ),
            ),
            title: Text(
              '${a['nombre_completo']} (CI: ${a['ci']}) - ${a['tipo_ingreso']}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              '${a['identificador']} • ${_fmtFechaHora(a['fecha_hora'] as DateTime)} • ${a['detalle_vigencia']}',
            ),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: vigente ? Colors.green.shade50 : Colors.red.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: vigente ? Colors.green : Colors.red,
                ),
              ),
              child: Text(
                a['estado'],
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: vigente ? Colors.green.shade800 : Colors.red.shade800,
                ),
              ),
            ),
          );
        },
      );
    }

    if (_socios.isEmpty) {
      return const Center(
        child: Text(
          'No hay socios registrados.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: _socios.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final s = _socios[index];
        final bool vigente = s['estado'] == 'Vigente';
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(
            backgroundColor: Colors.indigo.shade50,
            child: Icon(Icons.person_outline, color: Colors.indigo.shade800),
          ),
          title: Text(
            '${s['nombre_completo']} (CI: ${s['ci']})',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          subtitle: Text('${s['identificador']} • ${s['detalle_validez']}'),
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: vigente ? Colors.green.shade50 : Colors.red.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: vigente ? Colors.green : Colors.red,
              ),
            ),
            child: Text(
              s['estado'],
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                color: vigente ? Colors.green.shade800 : Colors.red.shade800,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildKpi(
    String titulo,
    String valor,
    IconData icono,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
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
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          CircleAvatar(
            backgroundColor: color.withOpacity(0.12),
            child: Icon(icono, color: color, size: 20),
          ),
        ],
      ),
    );
  }
}