import 'dart:io';
import 'package:flutter/material.dart';
import '../../infrastructure/database/mysql_repository.dart';

class CajaPosWidget extends StatefulWidget {
  @override
  _CajaPosWidgetState createState() => _CajaPosWidgetState();
}

class _CajaPosWidgetState extends State<CajaPosWidget> {
  final SocioRepository _repository = SocioRepository();

  DateTime? _fechaFiltro; // null = muestra todos los pagos
  String _filtroMetodo = 'TODOS'; // 'TODOS', 'EFECTIVO', 'QR', 'PENDIENTES_QR'
  late Future<List<Map<String, dynamic>>> _pagosFuture;

  @override
  void initState() {
    super.initState();
    _cargarPagos();
  }

  void _cargarPagos() {
    setState(() {
      _pagosFuture = _repository.obtenerPagosCaja(
        fecha: _fechaFiltro,
        filtroMetodo: _filtroMetodo,
      );
    });
  }

  String _formatearFechaHora(DateTime dt) {
    final dia = dt.day.toString().padLeft(2, '0');
    final mes = dt.month.toString().padLeft(2, '0');
    final anio = dt.year;
    final hora = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$dia/$mes/$anio $hora:$min';
  }

  Future<void> _seleccionarFecha() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _fechaFiltro ?? DateTime.now(),
      firstDate: DateTime(2024),
      lastDate: DateTime(2030),
    );
    if (picked != null) {
      setState(() {
        _fechaFiltro = picked;
      });
      _cargarPagos();
    }
  }

  /// Abre un visor para inspeccionar la imagen del comprobante QR en tamaño grande
  void _verImagenComprobante(String? rutaImagen, String nombreSocio) {
    if (rutaImagen == null ||
        rutaImagen.isEmpty ||
        !File(rutaImagen).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'El archivo de imagen del comprobante no se encuentra disponible en este equipo.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          width: 520,
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Comprobante QR - $nombreSocio',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              const Divider(),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 450),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(rutaImagen),
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Modal para verificar el comprobante QR e insertar manualmente el total del comprobante.
  /// Una vez guardado, el monto queda bloqueado y ya no se puede modificar.
  Future<void> _mostrarDialogoVerificarQr(Map<String, dynamic> pago) async {
    final bool yaVerificado = pago['qr_verificado'] == true;
    if (yaVerificado) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Este pago QR ya fue verificado y se encuentra bloqueado.',
          ),
          backgroundColor: Colors.grey,
        ),
      );
      return;
    }

    final TextEditingController montoManualController = TextEditingController();
    final GlobalKey<FormState> formKey = GlobalKey<FormState>();
    bool guardando = false;
    final String? rutaComprobante = pago['comprobante_url'];
    final bool existeArchivo =
        rutaComprobante != null &&
        rutaComprobante.isNotEmpty &&
        File(rutaComprobante).existsSync();

    final bool? verificadoExitoso = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.verified_user, color: Color(0xFF28A745)),
                  SizedBox(width: 10),
                  Text(
                    'Verificar Monto de Comprobante QR',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                ],
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              content: SizedBox(
                width: 500,
                child: SingleChildScrollView(
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Datos del socio y concepto
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Socio: ${pago['nombre_completo']} (CI: ${pago['ci']})',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Servicio registrado: ${pago['concepto']} (Monto esperado: Bs ${(pago['importe'] as double).toStringAsFixed(2)})',
                                style: TextStyle(
                                  color: Colors.grey.shade700,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 15),

                        // Vista previa del comprobante subido
                        const Text(
                          'Comprobante adjunto:',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (existeArchivo)
                          Center(
                            child: GestureDetector(
                              onTap: () => _verImagenComprobante(
                                rutaComprobante,
                                pago['nombre_completo'],
                              ),
                              child: Container(
                                height: 220,
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.grey.shade300,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                  color: Colors.black12,
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.file(
                                    File(rutaComprobante),
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                            ),
                          )
                        else
                          Container(
                            padding: const EdgeInsets.all(16),
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Colors.orange.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.orange.shade200),
                            ),
                            child: const Row(
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  color: Colors.orange,
                                ),
                                SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'No se encontró la vista previa de la imagen en esta PC. Verifique el monto en su extracto bancario.',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 20),

                        // Campo para insertar manualmente el total del comprobante
                        TextFormField(
                          controller: montoManualController,
                          autofocus: true,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText:
                                'Insertar Total del Comprobante Manualmente (Bs)*',
                            hintText: 'Ej: 100.00 o 10.00',
                            prefixIcon: Icon(Icons.payments_outlined),
                            border: OutlineInputBorder(),
                          ),
                          validator: (val) {
                            if (val == null || val.trim().isEmpty) {
                              return 'Debe ingresar el monto total del comprobante obligatoriamente';
                            }
                            final parsed = double.tryParse(
                              val.trim().replaceAll(',', '.'),
                            );
                            if (parsed == null || parsed <= 0) {
                              return 'Ingrese un monto numérico válido mayor a 0';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),

                        // Advertencia de bloqueo permanente
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.red.shade200),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.lock_outline,
                                size: 18,
                                color: Colors.red.shade700,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Atención: Una vez ingresado y confirmado este monto, quedará registrado de forma definitiva y ya no se podrá modificar.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.red.shade800,
                                    fontWeight: FontWeight.w500,
                                  ),
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
                  onPressed: guardando
                      ? null
                      : () => Navigator.of(ctx).pop(false),
                  child: const Text(
                    'Cancelar',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: guardando
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;

                          final double montoConfirmado = double.parse(
                            montoManualController.text
                                .trim()
                                .replaceAll(',', '.'),
                          );

                          setModalState(() => guardando = true);

                          final exito =
                              await _repository.verificarMontoPagoQr(
                                mensualidadId: pago['id'],
                                montoComprobante: montoConfirmado,
                              );

                          if (!mounted) return;
                          setModalState(() => guardando = false);

                          if (exito) {
                            Navigator.of(ctx).pop(true);
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  _repository.ultimoError ??
                                      'Error al verificar el pago.',
                                ),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        },
                  icon: guardando
                      ? const SizedBox.shrink()
                      : const Icon(Icons.check_circle_outline, size: 18),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF28A745),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                  ),
                  label: guardando
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text('Confirmar y Bloquear Monto'),
                ),
              ],
            );
          },
        );
      },
    );

    if (verificadoExitoso == true && mounted) {
      _cargarPagos();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Monto QR verificado y bloqueado correctamente.',
          ),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _pagosFuture,
      builder: (context, snapshot) {
        final pagos = snapshot.data ?? [];

        // Cálculos de resumen financiero sobre la lista actual
        double totalEfectivo = 0;
        double totalQrVerificado = 0;
        int cantidadQrPendientes = 0;

        for (var p in pagos) {
          final String metodo = p['metodo_pago'] ?? 'EFECTIVO';
          final bool verificado = p['qr_verificado'] == true;
          final double monto = (p['importe'] as num).toDouble();

          if (metodo == 'EFECTIVO') {
            totalEfectivo += monto;
          } else if (metodo == 'QR') {
            if (verificado) {
              totalQrVerificado += monto;
            } else {
              cantidadQrPendientes++;
            }
          }
        }

        final double totalRecaudadoConfirmado =
            totalEfectivo + totalQrVerificado;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- 1. TARJETAS DE RESUMEN DE CAJA ---
            Row(
              children: [
                Expanded(
                  child: _buildKpiCard(
                    titulo: 'Total Recaudado (Confirmado)',
                    valor: 'Bs ${totalRecaudadoConfirmado.toStringAsFixed(2)}',
                    icono: Icons.account_balance_wallet,
                    color: const Color(0xFF28A745),
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: _buildKpiCard(
                    titulo: 'Pagos en Efectivo',
                    valor: 'Bs ${totalEfectivo.toStringAsFixed(2)}',
                    icono: Icons.payments_outlined,
                    color: Colors.teal,
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: _buildKpiCard(
                    titulo: 'Pagos QR Verificados',
                    valor: 'Bs ${totalQrVerificado.toStringAsFixed(2)}',
                    icono: Icons.qr_code_2,
                    color: Colors.blue.shade700,
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: _buildKpiCard(
                    titulo: 'QR Pendientes de Verificar',
                    valor: '$cantidadQrPendientes',
                    icono: Icons.pending_actions,
                    color: cantidadQrPendientes > 0
                        ? Colors.orange.shade800
                        : Colors.grey,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // --- 2. TABLA PRINCIPAL DE TRANSACCIONES Y AUDITORÍA QR ---
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
                    // Cabecera y Controles de Filtro
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Historial de Pagos y Verificación QR',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'Audite los comprobantes QR e ingrese su monto para consolidarlos en caja.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              // Filtro por método / estado
                              DropdownButton<String>(
                                value: _filtroMetodo,
                                underline: const SizedBox(),
                                items: const [
                                  DropdownMenuItem(
                                    value: 'TODOS',
                                    child: Text('Todos los pagos'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'EFECTIVO',
                                    child: Text('Solo Efectivo'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'QR',
                                    child: Text('Todos los QR'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'PENDIENTES_QR',
                                    child: Text('QR Pendientes de Verificar'),
                                  ),
                                ],
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() => _filtroMetodo = val);
                                    _cargarPagos();
                                  }
                                },
                              ),
                              const SizedBox(width: 15),

                              // Filtro por Fecha
                              OutlinedButton.icon(
                                onPressed: _seleccionarFecha,
                                icon: const Icon(
                                  Icons.calendar_today,
                                  size: 16,
                                ),
                                label: Text(
                                  _fechaFiltro == null
                                      ? 'Todas las fechas'
                                      : "${_fechaFiltro!.day.toString().padLeft(2, '0')}/${_fechaFiltro!.month.toString().padLeft(2, '0')}/${_fechaFiltro!.year}",
                                ),
                              ),
                              if (_fechaFiltro != null) ...[
                                const SizedBox(width: 6),
                                IconButton(
                                  tooltip: 'Quitar filtro de fecha',
                                  onPressed: () {
                                    setState(() => _fechaFiltro = null);
                                    _cargarPagos();
                                  },
                                  icon: const Icon(
                                    Icons.clear,
                                    size: 18,
                                    color: Colors.red,
                                  ),
                                ),
                              ],
                              const SizedBox(width: 10),
                              IconButton(
                                tooltip: 'Actualizar pagos',
                                onPressed: _cargarPagos,
                                icon: const Icon(Icons.refresh),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),

                    // Encabezados de la Tabla
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      color: Colors.grey.shade50,
                      child: Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: Text(
                              'SOCIO / C.I.',
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
                              'CONCEPTO / FECHA',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 1,
                            child: Text(
                              'MÉTODO',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 1,
                            child: Text(
                              'COMPROBANTE',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 1,
                            child: Text(
                              'MONTO',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                'VERIFICACIÓN / ACCIONES',
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

                    // Filas de Pagos
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return const Center(
                              child: CircularProgressIndicator(
                                color: Color(0xFF28A745),
                              ),
                            );
                          }

                          if (snapshot.hasError) {
                            return Center(
                              child: Text(
                                'Error cargando pagos: ${snapshot.error}',
                                style: const TextStyle(color: Colors.red),
                              ),
                            );
                          }

                          if (pagos.isEmpty) {
                            return const Center(
                              child: Text(
                                'No se encontraron pagos registrados para los filtros seleccionados.',
                                style: TextStyle(color: Colors.grey),
                              ),
                            );
                          }

                          return ListView.builder(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 10,
                            ),
                            itemCount: pagos.length,
                            itemBuilder: (context, index) {
                              return _buildPagoRow(pagos[index]);
                            },
                          );
                        },
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

  Widget _buildKpiCard({
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
                    fontSize: 20,
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

  Widget _buildPagoRow(Map<String, dynamic> pago) {
    final String metodo = pago['metodo_pago'] ?? 'EFECTIVO';
    final bool esQr = metodo == 'QR';
    final bool qrVerificado = pago['qr_verificado'] == true;
    final double importe = (pago['importe'] as num).toDouble();
    final String? comprobanteUrl = pago['comprobante_url'];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
      ),
      child: Row(
        children: [
          // 1. Socio y CI
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pago['nombre_completo'],
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  'CI: ${pago['ci']}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),

          // 2. Concepto y Fecha
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pago['concepto'],
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatearFechaHora(pago['fecha_pago']),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),

          // 3. Método de Pago (Badge)
          Expanded(
            flex: 1,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: esQr ? Colors.blue.shade50 : Colors.green.shade50,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: esQr ? Colors.blue.shade300 : Colors.green.shade300,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      esQr ? Icons.qr_code_2 : Icons.payments_outlined,
                      size: 14,
                      color: esQr
                          ? Colors.blue.shade800
                          : Colors.green.shade800,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      metodo,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: esQr
                            ? Colors.blue.shade800
                            : Colors.green.shade800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 4. Comprobante QR
          Expanded(
            flex: 1,
            child: Align(
              alignment: Alignment.centerLeft,
              child: esQr
                  ? TextButton.icon(
                      onPressed: () => _verImagenComprobante(
                        comprobanteUrl,
                        pago['nombre_completo'],
                      ),
                      icon: const Icon(Icons.image_outlined, size: 16),
                      label: const Text(
                        'Ver Foto',
                        style: TextStyle(fontSize: 12),
                      ),
                    )
                  : Text(
                      'No aplica',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
            ),
          ),

          // 5. Monto
          Expanded(
            flex: 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bs ${importe.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: (esQr && !qrVerificado)
                        ? Colors.orange.shade800
                        : Colors.black87,
                  ),
                ),
                if (esQr && !qrVerificado)
                  Text(
                    'Por verificar',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),

          // 6. Acciones (Verificar Monto QR / Bloqueado / Reimprimir Boleta)
          Expanded(
            flex: 2,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (esQr && !qrVerificado)
                  ElevatedButton.icon(
                    onPressed: () => _mostrarDialogoVerificarQr(pago),
                    icon: const Icon(Icons.fact_check_outlined, size: 16),
                    label: const Text('Verificar Monto'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                  )
                else if (esQr && qrVerificado)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.green.shade300),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.lock,
                          size: 14,
                          color: Colors.green.shade700,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Verificado',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.green.shade800,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Cobrado en Caja',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Reimprimir Boleta de Pago',
                  onPressed: () async {
                    await _repository.generarEImprimirBoleta(
                      nombreSocio: pago['nombre_completo'],
                      ciSocio: pago['ci'],
                      conceptoPlan: pago['concepto'],
                      importe: importe,
                      metodoPago: metodo,
                      fechaVencimiento: pago['fecha_vencimiento'],
                    );
                  },
                  icon: const Icon(Icons.print_outlined, size: 20),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}