import 'dart:io';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';

class GeneradorReciboPdf {
  /// Genera el documento PDF con los datos del pago
  static pw.Document _crearDocumento({
    required String nombreSocio,
    required String ci,
    required String plan,
    required double importe,
    required DateTime nuevaFecha,
  }) {
    final pdf = pw.Document();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a5, // Formato pequeño ideal para recibos
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Center(
                child: pw.Text(
                  'GYM ERP BIOMÉTRICO',
                  style: pw.TextStyle(
                    fontSize: 24,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.Center(
                child: pw.Text(
                  'Recibo de Mensualidad',
                  style: pw.TextStyle(fontSize: 16),
                ),
              ),
              pw.SizedBox(height: 20),
              pw.Divider(),
              pw.SizedBox(height: 10),
              pw.Text(
                'Fecha de Emisión: ${DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now())}',
              ),
              pw.SizedBox(height: 20),
              pw.Text(
                'DATOS DEL CLIENTE',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              ),
              pw.Text('Nombre: $nombreSocio'),
              pw.Text('CI: $ci'),
              pw.SizedBox(height: 20),
              pw.Text(
                'DETALLE DE PAGO',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              ),
              pw.Text('Plan Adquirido: $plan'),
              pw.Text('Importe Pagado: Bs $importe'),
              pw.SizedBox(height: 10),
              pw.Container(
                padding: const pw.EdgeInsets.all(10),
                color: PdfColors.grey200,
                child: pw.Text(
                  'NUEVO VENCIMIENTO: ${DateFormat('dd/MM/yyyy').format(nuevaFecha)}',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                ),
              ),
              pw.Spacer(),
              pw.Divider(),
              pw.Center(
                child: pw.Text(
                  'Gracias por su preferencia',
                  style: pw.TextStyle(fontSize: 10),
                ),
              ),
            ],
          );
        },
      ),
    );

    return pdf;
  }

  /// Guarda el PDF directamente en la carpeta Documentos de Windows
  static Future<String> guardarSilencioso({
    required String nombreSocio,
    required String ci,
    required String plan,
    required double importe,
    required DateTime nuevaFecha,
  }) async {
    final pdf = _crearDocumento(
      nombreSocio: nombreSocio,
      ci: ci,
      plan: plan,
      importe: importe,
      nuevaFecha: nuevaFecha,
    );

    // Obtiene la ruta de Documentos del usuario en Windows
    final directory = await getApplicationDocumentsDirectory();

    // Crea una subcarpeta "Recibos Gym" si no existe
    final folderPath = '${directory.path}\\Recibos Gym';
    final folder = Directory(folderPath);
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }

    // Nombre del archivo con timestamp
    final String timestamp = DateFormat('yyyyMMdd_HHmmss')
        .format(DateTime.now());
    final File file = File('$folderPath\\Recibo_${ci}_$timestamp.pdf');

    await file.writeAsBytes(await pdf.save());
    return file.path;
  }
}
