import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:mysql1/mysql1.dart';
import 'package:uuid/uuid.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:path_provider/path_provider.dart';

class SocioRepository {
  String? ultimoError;
  static bool _estructuraInicializada = false;

  /// Sesión activa del usuario logueado y sus módulos permitidos
  static Map<String, dynamic>? usuarioSesionActual;

  static const List<String> todosLosModulosSistema = [
    'Dashboard',
    'Socios & Membresías',
    'Control de Asistencias',
    'Finanzas & Caja',
    'Personal',
    'Reportes',
    'Configuración',
  ];

  /// Normaliza cualquier nombre de módulo (incluso si tuvo errores de tildes UTF-8 en BD)
  /// hacia el nombre canónico exacto de `todosLosModulosSistema`.
  static String? normalizarNombreModulo(String raw) {
    final s = raw.trim().toLowerCase();
    if (s.isEmpty) return null;
    if (s.contains('dashboard') || s.contains('inicio')) {
      return 'Dashboard';
    }
    if (s.contains('socio') || s.contains('membres')) {
      return 'Socios & Membresías';
    }
    if (s.contains('asistencia') || s.contains('acceso')) {
      return 'Control de Asistencias';
    }
    if (s.contains('finanza') || s.contains('caja')) {
      return 'Finanzas & Caja';
    }
    if (s.contains('personal') || s.contains('usuario')) {
      return 'Personal';
    }
    if (s.contains('reporte')) {
      return 'Reportes';
    }
    if (s.contains('config')) {
      return 'Configuración';
    }
    return null;
  }

  Future<MySqlConnection> _getConnection() async {
    final settings = ConnectionSettings(
      host: '127.0.0.1',
      port: 3306,
      user: 'root',
      db: 'gym_pos',
    );
    return await MySqlConnection.connect(settings);
  }

  /// Decodifica correctamente en UTF-8 cualquier columna TEXT/BLOB de MySQL
  /// para preservar tildes como "Socios & Membresías" y "Configuración".
  String _aTexto(dynamic valor, [String porDefecto = '']) {
    if (valor == null) return porDefecto;
    if (valor is String) return valor;
    if (valor is Blob) {
      final bytes = valor.toBytes();
      try {
        return utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        return String.fromCharCodes(bytes);
      }
    }
    if (valor is List<int>) {
      try {
        return utf8.decode(valor, allowMalformed: true);
      } catch (_) {
        return String.fromCharCodes(valor);
      }
    }
    return valor.toString();
  }

  DateTime? _aFecha(dynamic valor) {
    if (valor == null) return null;
    if (valor is DateTime) {
      return DateTime(
        valor.year,
        valor.month,
        valor.day,
        valor.hour,
        valor.minute,
        valor.second,
      );
    }
    final texto = _aTexto(valor).trim();
    if (texto.isEmpty) return null;
    final parsed = DateTime.tryParse(texto);
    if (parsed == null) return null;
    return DateTime(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
    );
  }

  String _aSqlDateTime(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min:$s';
  }

  String _formatearMinutosRestantes(int minutosRestantes) {
    if (minutosRestantes <= 0) return '0m';
    final int horas = minutosRestantes ~/ 60;
    final int mins = minutosRestantes % 60;
    return horas > 0 ? '${horas}h ${mins}m' : '${mins}m';
  }

  Future<String> obtenerSiguienteIdNumericoHuella() async {
    MySqlConnection? conn;
    try {
      conn = await _getConnection();
      await _asegurarEstructuraYPlanes(conn);
      final res = await conn.query('SELECT template FROM huellas');
      int maxId = 1;
      for (var row in res) {
        final val = int.tryParse(_aTexto(row['template']).trim());
        if (val != null && val < 100000 && val > maxId) {
          maxId = val;
        }
      }
      return (maxId + 1).toString();
    } catch (_) {
      return '2';
    } finally {
      if (conn != null) await conn.close();
    }
  }

  double _calcularSimilitudBiometrica(String huellaLeida, String huellaEnBd) {
    final String a = huellaLeida.trim();
    final String b = huellaEnBd.trim();
    if (a.isEmpty || b.isEmpty) return 0.0;
    if (a == b) return 1.0;
    if (a.length < 16 || b.length < 16) return a == b ? 1.0 : 0.0;

    final int minLen = min(a.length, b.length);
    final int maxLen = max(a.length, b.length);
    if ((minLen / maxLen) < 0.75) return 0.0;

    int coincidencias = 0;
    for (int i = 0; i < minLen; i++) {
      if (a.codeUnitAt(i) == b.codeUnitAt(i)) coincidencias++;
    }
    final double simDirecta = coincidencias / maxLen;

    final Set<String> bloquesA = {};
    final Set<String> bloquesB = {};
    for (int i = 0; i <= a.length - 8; i += 4) {
      bloquesA.add(a.substring(i, i + 8));
    }
    for (int i = 0; i <= b.length - 8; i += 4) {
      bloquesB.add(b.substring(i, i + 8));
    }
    if (bloquesA.isEmpty || bloquesB.isEmpty) return simDirecta;
    final int inter = bloquesA.intersection(bloquesB).length;
    final int uni = bloquesA.union(bloquesB).length;
    return max(simDirecta, uni > 0 ? (inter / uni) : 0.0);
  }

  Future<String?> _guardarCopiaPermanenteFoto(
    String? rutaOriginal,
    String ciSocio,
  ) async {
    if (rutaOriginal == null || rutaOriginal.trim().isEmpty) return null;
    try {
      final archivoOrigen = File(rutaOriginal);
      if (!await archivoOrigen.exists()) return rutaOriginal;

      final dir = await getApplicationDocumentsDirectory();
      final carpetaFotos = Directory('${dir.path}/Fotos_Socios_Gym');
      if (!await carpetaFotos.exists()) {
        await carpetaFotos.create(recursive: true);
      }

      final extension = rutaOriginal.contains('.')
          ? rutaOriginal.substring(rutaOriginal.lastIndexOf('.'))
          : '.jpg';
      final ciLimpio = ciSocio.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
      final nuevoPath =
          '${carpetaFotos.path}/socio_${ciLimpio}_${DateTime.now().millisecondsSinceEpoch}$extension';

      await archivoOrigen.copy(nuevoPath);
      return nuevoPath;
    } catch (_) {
      return rutaOriginal;
    }
  }

  Future<void> _asegurarColumnasPersonal(MySqlConnection conn) async {
    try {
      await conn.query('''
        CREATE TABLE IF NOT EXISTS personal_erp (
          id VARCHAR(36) PRIMARY KEY,
          nombre VARCHAR(100) NOT NULL,
          usuario VARCHAR(80) NOT NULL,
          password VARCHAR(100) NOT NULL,
          rol VARCHAR(30) NOT NULL DEFAULT 'PERSONAL',
          permisos_modulos LONGTEXT NULL,
          activo TINYINT(1) DEFAULT 1
        )
      ''');

      final cols = await conn.query('SHOW COLUMNS FROM personal_erp');
      bool tienePermisos = false;
      bool tieneRol = false;
      bool tieneActivo = false;

      for (var c in cols) {
        final f = _aTexto(c['Field']).toLowerCase();
        if (f == 'permisos_modulos') tienePermisos = true;
        if (f == 'rol') tieneRol = true;
        if (f == 'activo') tieneActivo = true;
      }

      if (!tienePermisos) {
        await conn.query(
          'ALTER TABLE personal_erp ADD COLUMN permisos_modulos LONGTEXT NULL',
        );
      }
      if (!tieneRol) {
        await conn.query(
          "ALTER TABLE personal_erp ADD COLUMN rol VARCHAR(30) NOT NULL DEFAULT 'PERSONAL'",
        );
      }
      if (!tieneActivo) {
        await conn.query(
          'ALTER TABLE personal_erp ADD COLUMN activo TINYINT(1) DEFAULT 1',
        );
      }

      var resAdmin = await conn.query(
        'SELECT COUNT(*) as total FROM personal_erp',
      );
      if (((resAdmin.first['total'] as num?)?.toInt() ?? 0) == 0) {
        await conn.query(
          '''
          INSERT INTO personal_erp (id, nombre, usuario, password, rol, permisos_modulos, activo)
          VALUES (?, 'Thor Administrador', 'admin', 'admin123', 'ADMINISTRADOR', ?, 1)
          ''',
          [const Uuid().v4(), jsonEncode(todosLosModulosSistema)],
        );
      }
    } catch (_) {}
  }

  /// Decodifica y normaliza los módulos asignados:
  /// - Si el rol es ADMINISTRADOR (o contiene ADMIN), SIEMPRE devuelve todos los módulos del sistema
  ///   (incluyendo "Socios & Membresías" y "Configuración").
  /// - Si es otro rol (PERSONAL, RECEPCIONISTA, CAJERO, ENTRENADOR), devuelve estrictamente
  ///   los módulos asignados en `permisos_modulos`.
  List<String> _decodificarModulosAsignados(
    String rawPermisos,
    String rol, {
    String usuario = '',
  }) {
    if (rol.trim().toUpperCase().contains('ADMIN') ||
        usuario.trim().toLowerCase() == 'admin') {
      return List<String>.from(todosLosModulosSistema);
    }

    final List<String> resultado = [];
    final String limpio = rawPermisos.trim();

    if (limpio.isNotEmpty) {
      try {
        final decoded = jsonDecode(limpio);
        if (decoded is List) {
          for (final item in decoded) {
            final canonico = normalizarNombreModulo(item.toString());
            if (canonico != null && !resultado.contains(canonico)) {
              resultado.add(canonico);
            }
          }
        }
      } catch (_) {
        for (final parte in limpio.split(',')) {
          final canonico = normalizarNombreModulo(parte);
          if (canonico != null && !resultado.contains(canonico)) {
            resultado.add(canonico);
          }
        }
      }
    }

    if (resultado.isEmpty) {
      return ['Dashboard', 'Socios & Membresías', 'Control de Asistencias'];
    }

    // Ordenar siempre según el catálogo principal
    return todosLosModulosSistema
        .where((m) => resultado.contains(m))
        .toList();
  }

  Future<void> _asegurarEstructuraYPlanes(MySqlConnection conn) async {
    if (_estructuraInicializada) return;
    _estructuraInicializada = true;

    try {
      var colsSocios = await conn.query('SHOW COLUMNS FROM socios');
      bool tieneCorreo = false;
      for (var c in colsSocios) {
        if (_aTexto(c['Field']).toLowerCase() == 'correo') tieneCorreo = true;
      }
      if (!tieneCorreo) {
        await conn.query(
          'ALTER TABLE socios ADD COLUMN correo VARCHAR(120) NULL',
        );
      }
    } catch (_) {}

    try {
      var colsHuellas = await conn.query('SHOW COLUMNS FROM huellas');
      bool tienePacketData = false;
      for (var c in colsHuellas) {
        if (_aTexto(c['Field']).toLowerCase() == 'packet_data') {
          tienePacketData = true;
        }
      }
      if (!tienePacketData) {
        await conn.query(
          'ALTER TABLE huellas ADD COLUMN packet_data LONGTEXT NULL',
        );
      }
    } catch (_) {}

    try {
      var colsMens = await conn.query('SHOW COLUMNS FROM mensualidades');
      bool tieneMetodo = false,
          tieneComp = false,
          tieneQrVer = false,
          tieneMontoVer = false;
      for (var c in colsMens) {
        final f = _aTexto(c['Field']).toLowerCase();
        if (f == 'metodo_pago') tieneMetodo = true;
        if (f == 'comprobante_url') tieneComp = true;
        if (f == 'qr_verificado') tieneQrVer = true;
        if (f == 'monto_verificado') tieneMontoVer = true;
      }
      if (!tieneMetodo) {
        await conn.query(
          "ALTER TABLE mensualidades ADD COLUMN metodo_pago VARCHAR(20) DEFAULT 'EFECTIVO'",
        );
      }
      if (!tieneComp) {
        await conn.query(
          "ALTER TABLE mensualidades ADD COLUMN comprobante_url TEXT NULL",
        );
      }
      if (!tieneQrVer) {
        await conn.query(
          "ALTER TABLE mensualidades ADD COLUMN qr_verificado TINYINT(1) DEFAULT 1",
        );
      }
      if (!tieneMontoVer) {
        await conn.query(
          "ALTER TABLE mensualidades ADD COLUMN monto_verificado DECIMAL(10,2) NULL",
        );
      }
    } catch (_) {}

    try {
      var colsAcc = await conn.query('SHOW COLUMNS FROM accesos_log');
      bool tienePrev = false,
          tieneTipo = false,
          tieneTemp = false,
          tieneDet = false;
      String tipoEst = '';
      for (var c in colsAcc) {
        final f = _aTexto(c['Field']).toLowerCase();
        if (f == 'hora_ingreso_previo') tienePrev = true;
        if (f == 'tipo_ingreso') tieneTipo = true;
        if (f == 'template_leido') tieneTemp = true;
        if (f == 'detalle_vigencia') tieneDet = true;
        if (f == 'estado') tipoEst = _aTexto(c['Type']).toLowerCase();
      }
      if (tipoEst.contains('enum')) {
        await conn.query(
          "ALTER TABLE accesos_log MODIFY COLUMN estado VARCHAR(30) NOT NULL",
        );
      }
      if (!tienePrev) {
        await conn.query(
          "ALTER TABLE accesos_log ADD COLUMN hora_ingreso_previo DATETIME NULL",
        );
      }
      if (!tieneTipo) {
        await conn.query(
          "ALTER TABLE accesos_log ADD COLUMN tipo_ingreso VARCHAR(20) DEFAULT 'INGRESO'",
        );
      }
      if (!tieneTemp) {
        await conn.query(
          "ALTER TABLE accesos_log ADD COLUMN template_leido VARCHAR(120) NULL",
        );
      }
      if (!tieneDet) {
        await conn.query(
          "ALTER TABLE accesos_log ADD COLUMN detalle_vigencia VARCHAR(150) NULL",
        );
      }
    } catch (_) {}

    await _asegurarColumnasPersonal(conn);

    try {
      await conn.query('''
        CREATE TABLE IF NOT EXISTS configuracion_erp (
          id INT PRIMARY KEY,
          nombre_gimnasio VARCHAR(120) DEFAULT 'THOR GYM',
          nit_telefono VARCHAR(80) DEFAULT '',
          direccion VARCHAR(180) DEFAULT '',
          mensaje_recibo VARCHAR(180) DEFAULT '¡Gracias por entrenar con nosotros!',
          precio_mensual DECIMAL(10,2) DEFAULT 100.00,
          precio_sesion DECIMAL(10,2) DEFAULT 10.00,
          horas_reingreso INT DEFAULT 4,
          dahua_ip VARCHAR(60) DEFAULT '192.168.2.108',
          dahua_puerto INT DEFAULT 80,
          dahua_usuario VARCHAR(60) DEFAULT 'admin',
          dahua_password VARCHAR(80) DEFAULT 'Billblas'
        )
      ''');

      var resConf = await conn.query(
        'SELECT COUNT(*) as total FROM configuracion_erp WHERE id = 1',
      );
      if (((resConf.first['total'] as num?)?.toInt() ?? 0) == 0) {
        await conn.query('''
          INSERT INTO configuracion_erp 
            (id, nombre_gimnasio, nit_telefono, direccion, mensaje_recibo, precio_mensual, precio_sesion, horas_reingreso, dahua_ip, dahua_puerto, dahua_usuario, dahua_password)
          VALUES 
            (1, 'THOR GYM', '70000000', 'Av. Principal - Bolivia', '¡Gracias por entrenar con nosotros!', 100.00, 10.00, 4, '192.168.2.108', 80, 'admin', 'Billblas')
        ''');
      } else {
        await conn.query('''
          UPDATE configuracion_erp 
          SET dahua_ip = '192.168.2.108',
              dahua_usuario = 'admin',
              dahua_password = 'Billblas'
          WHERE id = 1 AND (dahua_ip = '192.168.1.108' OR dahua_password IS NULL OR TRIM(dahua_password) = '' OR dahua_password = 'admin123')
        ''');
      }
    } catch (_) {}
  }

  bool _esPagoSesionDiaria(int? planId, double? importe) {
    if (planId == 2) return true;
    if (importe != null && importe > 0 && importe <= 15.0) return true;
    return false;
  }

  Future<Map<String, dynamic>?> buscarSocioPorHuella(
    String idOTemplateHuella, {
    String? packetData,
  }) async {
    MySqlConnection? conn;
    try {
      final String limpio = idOTemplateHuella.trim();
      final String packetLimpio = (packetData ?? '').trim();

      if ((limpio.isEmpty || limpio == 'HUELLA_NO_REGISTRADA') &&
          packetLimpio.isEmpty) {
        return null;
      }

      conn = await _getConnection();
      await _asegurarEstructuraYPlanes(conn);

      final todasLasHuellas = await conn.query('''
        SELECT 
          h.id AS huella_id,
          h.socio_id AS huella_socio_id,
          h.template,
          h.packet_data,
          s.id AS socio_real_id,
          s.ci,
          s.nombre_completo,
          s.telefono,
          s.correo,
          s.foto_url,
          s.activo
        FROM huellas h
        INNER JOIN socios s ON (s.id = h.socio_id OR s.id = h.id)
      ''');

      Map<String, dynamic>? mejorCoincidencia;
      double mayorSimilitud = 0.0;

      for (var row in todasLasHuellas) {
        final String hId = _aTexto(row['huella_id']).trim();
        final String sRealId = _aTexto(row['socio_real_id']).trim();
        final String hTemplate = _aTexto(row['template']).trim();
        final String hPacket = _aTexto(row['packet_data']).trim();
        final String sCi = _aTexto(row['ci']).trim();

        if (limpio.isNotEmpty && limpio != 'HUELLA_NO_REGISTRADA') {
          if (limpio == hTemplate || limpio == hId || limpio == sRealId) {
            return {
              'id': sRealId,
              'huella_id': hId,
              'ci': sCi,
              'nombre_completo': _aTexto(row['nombre_completo']),
              'telefono': _aTexto(row['telefono']),
              'correo': _aTexto(row['correo']),
              'template': hTemplate,
              'packet_data': hPacket,
              'similitud': 100.0,
              'foto_url': row['foto_url'] != null
                  ? _aTexto(row['foto_url'])
                  : null,
            };
          }
        }

        if (packetLimpio.isNotEmpty && hPacket.isNotEmpty) {
          final double simPkt = _calcularSimilitudBiometrica(
            packetLimpio,
            hPacket,
          );
          if (simPkt >= 0.85 && simPkt > mayorSimilitud) {
            mayorSimilitud = simPkt;
            mejorCoincidencia = {
              'id': sRealId,
              'huella_id': hId,
              'ci': sCi,
              'nombre_completo': _aTexto(row['nombre_completo']),
              'telefono': _aTexto(row['telefono']),
              'correo': _aTexto(row['correo']),
              'template': hTemplate,
              'packet_data': hPacket,
              'similitud': (simPkt * 100).roundToDouble(),
              'foto_url': row['foto_url'] != null
                  ? _aTexto(row['foto_url'])
                  : null,
            };
          }
        }
      }

      return mejorCoincidencia;
    } catch (_) {
      return null;
    } finally {
      if (conn != null) await conn.close();
    }
  }

  Future<List<Map<String, dynamic>>> obtenerPlanes() async {
    try {
      final config = await obtenerConfiguracionSistema();
      final double pMensual =
          (config['precio_mensual'] as num?)?.toDouble() ?? 100.0;
      final double pSesion =
          (config['precio_sesion'] as num?)?.toDouble() ?? 10.0;
      return [
        {'id': 1, 'nombre': 'Mensual / Socio', 'dias': 30, 'precio': pMensual},
        {'id': 2, 'nombre': 'Sesión Diaria', 'dias': 1, 'precio': pSesion},
      ];
    } catch (_) {
      return [
        {'id': 1, 'nombre': 'Mensual / Socio', 'dias': 30, 'precio': 100.0},
        {'id': 2, 'nombre': 'Sesión Diaria', 'dias': 1, 'precio': 10.0},
      ];
    }
  }

  Future<DateTime?> registrarSocioConHuella({
    String? idUnicoHuella,
    required String ci,
    required String nombre,
    required String telefono,
    String correo = '',
    required String templateHuella,
    String? packetDataHuella,
    String? fotoUrl,
    int planId = 1,
    int diasDuracion = 30,
    double importe = 100.0,
    String metodoPago = 'EFECTIVO',
    String? comprobanteUrl,
  }) async {
    MySqlConnection? conn;
    ultimoError = null;

    try {
      final String huellaLimpia = templateHuella.trim();
      if (huellaLimpia.isEmpty || huellaLimpia == 'HUELLA_NO_REGISTRADA') {
        ultimoError = 'Ponga el dedo en el lector para capturar la huella.';
        return null;
      }

      final String idMaestroUnico =
          (idUnicoHuella != null && idUnicoHuella.trim().isNotEmpty)
              ? idUnicoHuella.trim()
              : const Uuid().v4();

      final duplicadoHuella = await buscarSocioPorHuella(
        huellaLimpia,
        packetData: packetDataHuella,
      );
      if (duplicadoHuella != null) {
        ultimoError =
            'Esta huella ya pertenece a ${duplicadoHuella['nombre_completo']} (CI: ${duplicadoHuella['ci']}).';
        return null;
      }

      conn = await _getConnection();
      await _asegurarEstructuraYPlanes(conn);

      var resCi = await conn.query(
        'SELECT nombre_completo FROM socios WHERE TRIM(ci) = ? LIMIT 1',
        [ci.trim()],
      );
      if (resCi.isNotEmpty) {
        ultimoError =
            'El CI ${ci.trim()} ya está registrado a nombre de ${_aTexto(resCi.first['nombre_completo'])}.';
        return null;
      }

      final String? rutaFotoPermanente = await _guardarCopiaPermanenteFoto(
        fotoUrl,
        ci.trim(),
      );

      final DateTime ahoraPc = DateTime.now();
      final String ahoraSql = _aSqlDateTime(ahoraPc);
      final bool esDiaria = _esPagoSesionDiaria(planId, importe);
      final int planIdReal = esDiaria ? 2 : 1;

      final DateTime fechaVencimiento = esDiaria
          ? ahoraPc.add(const Duration(hours: 4))
          : ahoraPc.add(Duration(days: diasDuracion));
      final String vencimientoSql = _aSqlDateTime(fechaVencimiento);

      final DateTime vence4h = ahoraPc.add(const Duration(hours: 4));
      final String horaVence4hStr =
          "${vence4h.hour.toString().padLeft(2, '0')}:${vence4h.minute.toString().padLeft(2, '0')}";
      final String detalleVigenciaInicial = esDiaria
          ? 'Huella N° $huellaLimpia • Sesión 4h activa (Vence $horaVence4hStr)'
          : 'Huella N° $huellaLimpia • Quedan $diasDuracion días • Sesión 4h (hasta $horaVence4hStr)';

      final int qrVerificado = metodoPago == 'QR' ? 0 : 1;
      final double? montoVerificado = metodoPago == 'QR' ? null : importe;

      await conn.query('START TRANSACTION');

      await conn.query(
        'INSERT INTO socios (id, ci, nombre_completo, telefono, correo, foto_url, activo) VALUES (?, ?, ?, ?, ?, ?, TRUE)',
        [
          idMaestroUnico,
          ci.trim(),
          nombre.trim(),
          telefono.trim(),
          correo.trim(),
          rutaFotoPermanente,
        ],
      );

      await conn.query(
        'INSERT INTO huellas (id, socio_id, template, packet_data, fecha_registro) VALUES (?, ?, ?, ?, ?)',
        [
          idMaestroUnico,
          idMaestroUnico,
          huellaLimpia,
          packetDataHuella,
          ahoraSql,
        ],
      );

      await conn.query(
        '''
        INSERT INTO mensualidades 
          (id, socio_id, plan_id, fecha_pago, fecha_vencimiento, importe, metodo_pago, comprobante_url, qr_verificado, monto_verificado) 
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          idMaestroUnico,
          idMaestroUnico,
          planIdReal,
          ahoraSql,
          vencimientoSql,
          importe,
          metodoPago,
          comprobanteUrl,
          qrVerificado,
          montoVerificado,
        ],
      );

      await conn.query(
        '''
        INSERT INTO accesos_log 
          (id, socio_id, estado, fecha_hora, hora_ingreso_previo, tipo_ingreso, template_leido, detalle_vigencia) 
        VALUES (?, ?, 'PERMITIDO', ?, ?, 'INGRESO', ?, ?)
        ''',
        [
          idMaestroUnico,
          idMaestroUnico,
          ahoraSql,
          ahoraSql,
          huellaLimpia,
          detalleVigenciaInicial,
        ],
      );

      await conn.query('COMMIT');
      return fechaVencimiento;
    } catch (e) {
      ultimoError = e.toString();
      if (conn != null) {
        try {
          await conn.query('ROLLBACK');
        } catch (_) {}
      }
      return null;
    } finally {
      if (conn != null) await conn.close();
    }
  }

  Future<bool> eliminarSocio(String socioId) async {
    MySqlConnection? conn;
    ultimoError = null;
    try {
      conn = await _getConnection();
      await conn.query('START TRANSACTION');
      await conn.query('DELETE FROM accesos_log WHERE id = ? OR socio_id = ?', [
        socioId,
        socioId,
      ]);
      await conn.query(
        'DELETE FROM mensualidades WHERE id = ? OR socio_id = ?',
        [socioId, socioId],
      );
      await conn.query('DELETE FROM huellas WHERE id = ? OR socio_id = ?', [
        socioId,
        socioId,
      ]);
      await conn.query('DELETE FROM socios WHERE id = ?', [socioId]);
      await conn.query('COMMIT');
      return true;
    } catch (e) {
      ultimoError = e.toString();
      if (conn != null) {
        try {
          await conn.query('ROLLBACK');
        } catch (_) {}
      }
      return false;
    } finally {
      if (conn != null) await conn.close();
    }
  }

  Future<DateTime?> renovarMensualidad({
    required String socioId,
    required int planId,
    required int diasDuracion,
    required double importe,
    required String metodoPago,
    String? comprobanteUrl,
  }) async {
    MySqlConnection? conn;
    ultimoError = null;
    try {
      conn = await _getConnection();
      await _asegurarEstructuraYPlanes(conn);

      final DateTime ahoraPc = DateTime.now();
      final String ahoraSql = _aSqlDateTime(ahoraPc);
      final bool esDiaria = _esPagoSesionDiaria(planId, importe);
      final int planIdReal = esDiaria ? 2 : 1;
      DateTime nuevaFechaVencimiento;

      if (esDiaria) {
        nuevaFechaVencimiento = ahoraPc.add(const Duration(hours: 4));
      } else {
        var resUltima = await conn.query(
          'SELECT fecha_vencimiento FROM mensualidades WHERE socio_id = ? OR id = ? ORDER BY fecha_vencimiento DESC LIMIT 1',
          [socioId, socioId],
        );
        DateTime baseDate = ahoraPc;
        if (resUltima.isNotEmpty) {
          final DateTime? ult = _aFecha(resUltima.first['fecha_vencimiento']);
          if (ult != null && ult.isAfter(baseDate)) baseDate = ult;
        }
        nuevaFechaVencimiento = baseDate.add(Duration(days: diasDuracion));
      }

      final int qrVerificado = metodoPago == 'QR' ? 0 : 1;
      final double? montoVerificado = metodoPago == 'QR' ? null : importe;

      await conn.query('START TRANSACTION');
      final resExistente = await conn.query(
        'SELECT id FROM mensualidades WHERE socio_id = ? OR id = ? LIMIT 1',
        [socioId, socioId],
      );

      if (resExistente.isNotEmpty) {
        final String idFilaMens = _aTexto(resExistente.first['id']);
        await conn.query(
          '''
          UPDATE mensualidades SET
            plan_id = ?, fecha_pago = ?, fecha_vencimiento = ?,
            importe = ?, metodo_pago = ?, comprobante_url = ?,
            qr_verificado = ?, monto_verificado = ?
          WHERE id = ?
          ''',
          [
            planIdReal,
            ahoraSql,
            _aSqlDateTime(nuevaFechaVencimiento),
            importe,
            metodoPago,
            comprobanteUrl,
            qrVerificado,
            montoVerificado,
            idFilaMens,
          ],
        );
      } else {
        await conn.query(
          '''
          INSERT INTO mensualidades 
            (id, socio_id, plan_id, fecha_pago, fecha_vencimiento, importe, metodo_pago, comprobante_url, qr_verificado, monto_verificado) 
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            socioId,
            socioId,
            planIdReal,
            ahoraSql,
            _aSqlDateTime(nuevaFechaVencimiento),
            importe,
            metodoPago,
            comprobanteUrl,
            qrVerificado,
            montoVerificado,
          ],
        );
      }

      await conn.query('UPDATE socios SET activo = TRUE WHERE id = ?', [
        socioId,
      ]);
      await conn.query('COMMIT');
      return nuevaFechaVencimiento;
    } catch (e) {
      ultimoError = e.toString();
      if (conn != null) {
        try {
          await conn.query('ROLLBACK');
        } catch (_) {}
      }
      return null;
    } finally {
      if (conn != null) await conn.close();
    }
  }

  Future<Map<String, dynamic>> registrarAccesoPorHuella({
    String? socioId,
    String? templateHuella,
    String? packetDataLeido,
  }) async {
    MySqlConnection? conn;
    ultimoError = null;

    try {
      final DateTime ahoraPc = DateTime.now();
      final String ahoraSql = _aSqlDateTime(ahoraPc);
      final String codigoLeido = (templateHuella ?? '').trim();

      Map<String, dynamic>? socioEncontrado;

      if (socioId != null && socioId.trim().isNotEmpty) {
        socioEncontrado = await buscarSocioPorHuella(socioId.trim());
      } else {
        socioEncontrado = await buscarSocioPorHuella(
          codigoLeido,
          packetData: packetDataLeido,
        );
      }

      if (socioEncontrado == null) {
        return {
          'exito': false,
          'no_encontrado': true,
          'estado': 'Vencido',
          'tipo_ingreso': 'ACCESO DENEGADO',
          'identificador': 'No Registrado',
          'nombre_completo': 'Usuario no encontrado en el sistema',
          'ci': 'Huella no registrada',
          'telefono': '',
          'correo': '',
          'template_huella': codigoLeido,
          'foto_url': null,
          'fecha_hora': ahoraPc,
          'hora_ingreso_previo': null,
          'detalle_vigencia': 'Usuario no encontrado en el sistema',
          'mensaje':
              'Usuario no encontrado en el sistema. La huella colocada no pertenece a ningún socio registrado.',
        };
      }

      conn = await _getConnection();
      await _asegurarEstructuraYPlanes(conn);

      final String socioRealId = _aTexto(socioEncontrado['id']);
      final String huellaId = _aTexto(socioEncontrado['huella_id'], socioRealId);
      final String nombreSocio = _aTexto(socioEncontrado['nombre_completo']);
      final String ciSocio = _aTexto(socioEncontrado['ci']);
      final String telSocio = _aTexto(socioEncontrado['telefono']);
      final String correoSocio = _aTexto(socioEncontrado['correo']);
      final String templateGuardado = _aTexto(
        socioEncontrado['template'],
        ciSocio,
      );
      final String? fotoUrl = socioEncontrado['foto_url']?.toString();

      var resMensualidad = await conn.query(
        'SELECT plan_id, importe, fecha_pago, fecha_vencimiento FROM mensualidades WHERE socio_id = ? OR id = ? ORDER BY fecha_pago DESC LIMIT 1',
        [socioRealId, huellaId],
      );

      if (resMensualidad.isEmpty) {
        const String detalleSinPago = 'Socio sin plan activo';
        await _actualizarAccesoSocio(
          conn: conn,
          socioRealId: socioRealId,
          huellaId: huellaId,
          estado: 'VENCIDO',
          fechaHoraSql: ahoraSql,
          horaPrevioSql: ahoraSql,
          tipoIngreso: 'INGRESO',
          template: templateGuardado,
          detalleVigencia: detalleSinPago,
        );
        return {
          'exito': false,
          'no_encontrado': false,
          'estado': 'Vencido',
          'tipo_ingreso': 'INGRESO',
          'identificador': 'Sin Plan',
          'nombre_completo': nombreSocio,
          'ci': ciSocio,
          'telefono': telSocio,
          'correo': correoSocio,
          'template_huella': templateGuardado,
          'foto_url': fotoUrl,
          'fecha_hora': ahoraPc,
          'hora_ingreso_previo': ahoraPc,
          'detalle_vigencia': detalleSinPago,
          'mensaje': 'Socio $nombreSocio sin pagos activos.',
        };
      }

      final int? rawPlanId = (resMensualidad.first['plan_id'] as num?)?.toInt();
      final double? rawImporte =
          (resMensualidad.first['importe'] as num?)?.toDouble();
      final bool esSesionDiaria = _esPagoSesionDiaria(rawPlanId, rawImporte);

      final String identificador =
          esSesionDiaria ? 'Sesión Diaria' : 'Mensual / Socio';
      final DateTime fechaPago =
          _aFecha(resMensualidad.first['fecha_pago']) ?? ahoraPc;
      final DateTime fechaVenc =
          _aFecha(resMensualidad.first['fecha_vencimiento']) ?? ahoraPc;

      var resAccesoActual = await conn.query(
        'SELECT fecha_hora, hora_ingreso_previo, estado FROM accesos_log WHERE socio_id = ? OR id = ? ORDER BY fecha_hora DESC LIMIT 1',
        [socioRealId, huellaId],
      );

      DateTime? horaInicioSesionHoy;
      if (resAccesoActual.isNotEmpty) {
        final DateTime? prev = _aFecha(
          resAccesoActual.first['hora_ingreso_previo'],
        );
        final DateTime? ult = _aFecha(resAccesoActual.first['fecha_hora']);
        final DateTime? baseComp = prev ?? ult;

        if (baseComp != null &&
            baseComp.year == ahoraPc.year &&
            baseComp.month == ahoraPc.month &&
            baseComp.day == ahoraPc.day) {
          horaInicioSesionHoy = baseComp;
        }
      }

      final String tipoMovimiento =
          horaInicioSesionHoy != null ? 'REINGRESO' : 'INGRESO';
      final DateTime inicioSesionEfectivo = horaInicioSesionHoy ?? ahoraPc;
      final String inicioSesionSql = _aSqlDateTime(inicioSesionEfectivo);

      if (esSesionDiaria) {
        final DateTime baseDiaria =
            horaInicioSesionHoy ??
            (fechaPago.year == ahoraPc.year &&
                    fechaPago.month == ahoraPc.month &&
                    fechaPago.day == ahoraPc.day
                ? fechaPago
                : ahoraPc);

        int minDesdeIngreso = ahoraPc.difference(baseDiaria).inMinutes;
        if (minDesdeIngreso < 0) minDesdeIngreso = 0;

        final String horaIngStr =
            "${baseDiaria.hour.toString().padLeft(2, '0')}:${baseDiaria.minute.toString().padLeft(2, '0')}";
        final String baseSql = _aSqlDateTime(baseDiaria);

        if (minDesdeIngreso >= 240) {
          final String detVenc =
              'Huella N° $templateGuardado • Sesión de 4h vencida (Ingresó $horaIngStr)';
          await _actualizarAccesoSocio(
            conn: conn,
            socioRealId: socioRealId,
            huellaId: huellaId,
            estado: 'SESION_VENCIDA',
            fechaHoraSql: ahoraSql,
            horaPrevioSql: baseSql,
            tipoIngreso: tipoMovimiento,
            template: templateGuardado,
            detalleVigencia: detVenc,
          );
          return {
            'exito': false,
            'no_encontrado': false,
            'estado': 'Vencido',
            'tipo_ingreso': tipoMovimiento,
            'identificador': 'Sesión Diaria',
            'nombre_completo': nombreSocio,
            'ci': ciSocio,
            'telefono': telSocio,
            'correo': correoSocio,
            'template_huella': templateGuardado,
            'foto_url': fotoUrl,
            'fecha_hora': ahoraPc,
            'hora_ingreso_previo': baseDiaria,
            'detalle_vigencia': detVenc,
            'mensaje': 'Sesión de 4 horas vencida para $nombreSocio.',
          };
        } else {
          final DateTime vence4h = baseDiaria.add(const Duration(hours: 4));
          final String tRest = _formatearMinutosRestantes(
            240 - minDesdeIngreso,
          );
          final String hVenceStr =
              "${vence4h.hour.toString().padLeft(2, '0')}:${vence4h.minute.toString().padLeft(2, '0')}";
          final String detVig =
              'Huella N° $templateGuardado • Quedan $tRest (Vence $hVenceStr)';

          await _actualizarAccesoSocio(
            conn: conn,
            socioRealId: socioRealId,
            huellaId: huellaId,
            estado: 'PERMITIDO',
            fechaHoraSql: ahoraSql,
            horaPrevioSql: baseSql,
            tipoIngreso: tipoMovimiento,
            template: templateGuardado,
            detalleVigencia: detVig,
          );
          return {
            'exito': true,
            'no_encontrado': false,
            'estado': 'Vigente',
            'tipo_ingreso': tipoMovimiento,
            'identificador': 'Sesión Diaria',
            'nombre_completo': nombreSocio,
            'ci': ciSocio,
            'telefono': telSocio,
            'correo': correoSocio,
            'template_huella': templateGuardado,
            'foto_url': fotoUrl,
            'fecha_hora': ahoraPc,
            'hora_ingreso_previo': baseDiaria,
            'detalle_vigencia': detVig,
            'mensaje': 'Verificación exitosa, bienvenidos a Thor Gym.',
          };
        }
      }

      final DateTime hoySoloDia = DateTime(
        ahoraPc.year,
        ahoraPc.month,
        ahoraPc.day,
      );
      final DateTime vencSoloDia = DateTime(
        fechaVenc.year,
        fechaVenc.month,
        fechaVenc.day,
      );
      final int diasRestantes = vencSoloDia.difference(hoySoloDia).inDays;

      if (vencSoloDia.isBefore(hoySoloDia)) {
        final String detMensVenc =
            'Huella N° $templateGuardado • Mensualidad Vencida (0 días)';
        await _actualizarAccesoSocio(
          conn: conn,
          socioRealId: socioRealId,
          huellaId: huellaId,
          estado: 'VENCIDO',
          fechaHoraSql: ahoraSql,
          horaPrevioSql: inicioSesionSql,
          tipoIngreso: tipoMovimiento,
          template: templateGuardado,
          detalleVigencia: detMensVenc,
        );
        return {
          'exito': false,
          'no_encontrado': false,
          'estado': 'Vencido',
          'tipo_ingreso': tipoMovimiento,
          'identificador': identificador,
          'nombre_completo': nombreSocio,
          'ci': ciSocio,
          'telefono': telSocio,
          'correo': correoSocio,
          'template_huella': templateGuardado,
          'foto_url': fotoUrl,
          'fecha_hora': ahoraPc,
          'hora_ingreso_previo': inicioSesionEfectivo,
          'detalle_vigencia': detMensVenc,
          'mensaje': 'Mensualidad vencida para $nombreSocio.',
        };
      }

      int minDesdeInicioHoy =
          ahoraPc.difference(inicioSesionEfectivo).inMinutes;
      if (minDesdeInicioHoy < 0) minDesdeInicioHoy = 0;

      if (minDesdeInicioHoy >= 240) {
        final String hPrimStr =
            "${inicioSesionEfectivo.hour.toString().padLeft(2, '0')}:${inicioSesionEfectivo.minute.toString().padLeft(2, '0')}";
        final String detReingVenc =
            'Huella N° $templateGuardado • Sesión 4h vencida (Ingresó $hPrimStr)';
        await _actualizarAccesoSocio(
          conn: conn,
          socioRealId: socioRealId,
          huellaId: huellaId,
          estado: 'SESION_VENCIDA',
          fechaHoraSql: ahoraSql,
          horaPrevioSql: inicioSesionSql,
          tipoIngreso: tipoMovimiento,
          template: templateGuardado,
          detalleVigencia: detReingVenc,
        );
        return {
          'exito': false,
          'no_encontrado': false,
          'estado': 'Vencido',
          'tipo_ingreso': tipoMovimiento,
          'identificador': identificador,
          'nombre_completo': nombreSocio,
          'ci': ciSocio,
          'telefono': telSocio,
          'correo': correoSocio,
          'template_huella': templateGuardado,
          'foto_url': fotoUrl,
          'fecha_hora': ahoraPc,
          'hora_ingreso_previo': inicioSesionEfectivo,
          'detalle_vigencia': detReingVenc,
          'mensaje': 'Sesión de 4 horas hoy vencida para $nombreSocio.',
        };
      }

      final DateTime vence4h = inicioSesionEfectivo.add(
        const Duration(hours: 4),
      );
      final String tRestHoy = _formatearMinutosRestantes(
        (240 - minDesdeInicioHoy).clamp(0, 240),
      );
      final String hVenceStr =
          "${vence4h.hour.toString().padLeft(2, '0')}:${vence4h.minute.toString().padLeft(2, '0')}";
      final String detMensVig =
          'Huella N° $templateGuardado • Quedan $diasRestantes días • Sesión 4h ($tRestHoy hasta $hVenceStr)';

      await _actualizarAccesoSocio(
        conn: conn,
        socioRealId: socioRealId,
        huellaId: huellaId,
        estado: 'PERMITIDO',
        fechaHoraSql: ahoraSql,
        horaPrevioSql: inicioSesionSql,
        tipoIngreso: tipoMovimiento,
        template: templateGuardado,
        detalleVigencia: detMensVig,
      );

      return {
        'exito': true,
        'no_encontrado': false,
        'estado': 'Vigente',
        'tipo_ingreso': tipoMovimiento,
        'identificador': identificador,
        'nombre_completo': nombreSocio,
        'ci': ciSocio,
        'telefono': telSocio,
        'correo': correoSocio,
        'template_huella': templateGuardado,
        'foto_url': fotoUrl,
        'fecha_hora': ahoraPc,
        'hora_ingreso_previo': inicioSesionEfectivo,
        'detalle_vigencia': detMensVig,
        'mensaje': 'Verificación exitosa, bienvenidos a Thor Gym.',
      };
    } catch (_) {
      return {
        'exito': false,
        'no_encontrado': true,
        'estado': 'Vencido',
        'nombre_completo': 'Usuario no encontrado en el sistema',
        'mensaje': 'Usuario no encontrado en el sistema.',
      };
    } finally {
      if (conn != null) await conn.close();
    }
  }

  Future<void> _actualizarAccesoSocio({
    required MySqlConnection conn,
    required String socioRealId,
    required String huellaId,
    required String estado,
    required String fechaHoraSql,
    required String horaPrevioSql,
    required String tipoIngreso,
    required String template,
    required String detalleVigencia,
  }) async {
    final resExistente = await conn.query(
      'SELECT id FROM accesos_log WHERE socio_id = ? OR id = ? LIMIT 1',
      [socioRealId, huellaId],
    );

    if (resExistente.isNotEmpty) {
      final String idFilaAcceso = _aTexto(resExistente.first['id']);
      await conn.query(
        '''
        UPDATE accesos_log SET
          estado = ?, fecha_hora = ?, hora_ingreso_previo = ?,
          tipo_ingreso = ?, template_leido = ?, detalle_vigencia = ?
        WHERE id = ?
        ''',
        [
          estado,
          fechaHoraSql,
          horaPrevioSql,
          tipoIngreso,
          template,
          detalleVigencia,
          idFilaAcceso,
        ],
      );
    } else {
      await conn.query(
        '''
        INSERT INTO accesos_log 
          (id, socio_id, estado, fecha_hora, hora_ingreso_previo, tipo_ingreso, template_leido, detalle_vigencia) 
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          socioRealId,
          socioRealId,
          estado,
          fechaHoraSql,
          horaPrevioSql,
          tipoIngreso,
          template,
          detalleVigencia,
        ],
      );
    }
  }

  Future<List<Map<String, dynamic>>> obtenerListaSocios({
    String? busqueda,
  }) async {
    MySqlConnection? conn;
    try {
      conn = await _getConnection();
      await _asegurarEstructuraYPlanes(conn);

      String sqlSocios =
          'SELECT id, ci, nombre_completo, telefono, correo, foto_url, activo FROM socios';
      List<dynamic> params = [];

      if (busqueda != null && busqueda.trim().isNotEmpty) {
        final String filtro = '%${busqueda.trim()}%';
        sqlSocios += ' WHERE ci LIKE ? OR nombre_completo LIKE ?';
        params = [filtro, filtro];
      }

      final resSocios = await conn.query(sqlSocios, params);
      final resHuellas = await conn.query(
        'SELECT id, socio_id, template, packet_data FROM huellas',
      );
      final resMensualidades = await conn.query(
        'SELECT id, socio_id, plan_id, importe, fecha_pago, fecha_vencimiento FROM mensualidades ORDER BY fecha_pago DESC',
      );
      final resAccesos = await conn.query(
        "SELECT id, socio_id, fecha_hora, hora_ingreso_previo FROM accesos_log WHERE estado = 'PERMITIDO' ORDER BY fecha_hora DESC",
      );

      final Map<String, String> huellaPorSocio = {};
      final Map<String, String?> packetPorSocio = {};
      for (var h in resHuellas) {
        final String idH = _aTexto(h['id']);
        final String sIdH = _aTexto(h['socio_id']);
        final String tempH = _aTexto(h['template']);
        final String? pktH = h['packet_data'] != null
            ? _aTexto(h['packet_data'])
            : null;
        huellaPorSocio[idH] = tempH;
        huellaPorSocio[sIdH] = tempH;
        packetPorSocio[idH] = pktH;
        packetPorSocio[sIdH] = pktH;
      }

      final Map<String, Map<String, dynamic>> ultimaMensPorSocio = {};
      for (var m in resMensualidades) {
        final sId = _aTexto(m['socio_id']);
        final mId = _aTexto(m['id']);
        final info = {
          'plan_id': _esPagoSesionDiaria(
                (m['plan_id'] as num?)?.toInt(),
                (m['importe'] as num?)?.toDouble(),
              )
              ? 2
              : 1,
          'importe': (m['importe'] as num?)?.toDouble() ?? 100.0,
          'fecha_pago': _aFecha(m['fecha_pago']),
          'fecha_vencimiento': _aFecha(m['fecha_vencimiento']),
        };
        ultimaMensPorSocio.putIfAbsent(sId, () => info);
        ultimaMensPorSocio.putIfAbsent(mId, () => info);
      }

      final Map<String, DateTime> inicioSesionPorSocio = {};
      for (var a in resAccesos) {
        final sId = _aTexto(a['socio_id']);
        final aId = _aTexto(a['id']);
        final fh =
            _aFecha(a['hora_ingreso_previo']) ?? _aFecha(a['fecha_hora']);
        if (fh != null) {
          if (sId.isNotEmpty) inicioSesionPorSocio.putIfAbsent(sId, () => fh);
          if (aId.isNotEmpty) inicioSesionPorSocio.putIfAbsent(aId, () => fh);
        }
      }

      final DateTime ahoraPc = DateTime.now();
      final DateTime hoySoloDia = DateTime(
        ahoraPc.year,
        ahoraPc.month,
        ahoraPc.day,
      );

      List<Map<String, dynamic>> socios = [];
      for (var row in resSocios) {
        final String sId = _aTexto(row['id']);
        final infoPlan = ultimaMensPorSocio[sId];
        final int planId = infoPlan != null ? (infoPlan['plan_id'] as int) : 1;
        final DateTime? fechaPago = infoPlan?['fecha_pago'] as DateTime?;
        final DateTime? fechaVenc = infoPlan?['fecha_vencimiento'] as DateTime?;
        final DateTime? horaIngreso = inicioSesionPorSocio[sId];

        bool esVigente = false;
        String identificadorTipo =
            planId == 2 ? 'Sesión Diaria' : 'Mensual / Socio';
        String detalleValidez = '';

        if (planId == 2) {
          final DateTime? base4h = horaIngreso ?? fechaPago;
          if (base4h != null) {
            int minTrans = ahoraPc.difference(base4h).inMinutes;
            if (minTrans < 0) minTrans = 0;
            esVigente = minTrans < 240;
            detalleValidez = esVigente
                ? 'Sesión Activa (Quedan ${_formatearMinutosRestantes(240 - minTrans)} de 4h)'
                : 'Sesión de 4 horas vencida';
          } else {
            detalleValidez = 'Sesión de 4 horas vencida';
          }
        } else {
          if (fechaVenc != null) {
            final DateTime vencSoloDia = DateTime(
              fechaVenc.year,
              fechaVenc.month,
              fechaVenc.day,
            );
            final int diasRest = vencSoloDia.difference(hoySoloDia).inDays;
            esVigente = !vencSoloDia.isBefore(hoySoloDia);
            detalleValidez = esVigente
                ? 'Mensualidad Vigente (Quedan $diasRest días)'
                : 'Mensualidad Vencida (30 días cumplidos)';
          } else {
            detalleValidez = 'Mensualidad Vencida';
          }
        }

        socios.add({
          'id': sId,
          'ci': _aTexto(row['ci']),
          'nombre_completo': _aTexto(row['nombre_completo']),
          'telefono': _aTexto(row['telefono']),
          'correo': _aTexto(row['correo']),
          'foto_url': row['foto_url'] != null ? _aTexto(row['foto_url']) : null,
          'activo': row['activo'] == 1 || row['activo'] == true,
          'tiene_huella': huellaPorSocio.containsKey(sId),
          'template_huella': huellaPorSocio[sId] ?? '',
          'packet_data': packetPorSocio[sId],
          'plan_id': planId,
          'identificador': identificadorTipo,
          'detalle_validez': detalleValidez,
          'estado': esVigente ? 'Vigente' : 'Vencido',
          'fecha_vencimiento': fechaVenc,
        });
      }
      return socios.reversed.toList();
    } catch (_) {
      return [];
    } finally {
      if (conn != null) await conn.close();
    }
  }

  Future<List<Map<String, dynamic>>> obtenerHistorialAccesos({
    DateTime? fecha,
    String filtroEstado = 'TODOS',
  }) async {
    MySqlConnection? conn;
    try {
      conn = await _getConnection();
      await _asegurarEstructuraYPlanes(conn);

      String query = '''
        SELECT 
          a.id, 
          a.socio_id,
          a.estado, 
          a.fecha_hora, 
          a.hora_ingreso_previo,
          a.tipo_ingreso,
          a.template_leido,
          a.detalle_vigencia,
          s.ci, 
          s.nombre_completo, 
          s.telefono,
          s.correo,
          s.foto_url,
          h.template AS huella_registrada,
          m.plan_id,
          m.importe,
          m.fecha_pago,
          m.fecha_vencimiento
        FROM accesos_log a
        INNER JOIN socios s ON (a.socio_id = s.id OR a.id = s.id)
        INNER JOIN huellas h ON (h.socio_id = s.id OR h.id = s.id)
        LEFT JOIN mensualidades m ON (m.socio_id = s.id OR m.id = s.id)
      ''';

      if (fecha != null) {
        final dateStr =
            "${fecha.year}-${fecha.month.toString().padLeft(2, '0')}-${fecha.day.toString().padLeft(2, '0')}";
        query += " WHERE DATE(a.fecha_hora) = '$dateStr'";
      }

      query += " ORDER BY a.fecha_hora DESC LIMIT 200";

      final results = await conn.query(query);
      final DateTime ahoraPc = DateTime.now();
      final DateTime hoySoloDia = DateTime(
        ahoraPc.year,
        ahoraPc.month,
        ahoraPc.day,
      );

      List<Map<String, dynamic>> historial = [];
      final Set<String> sociosMostrados = {};

      for (var row in results) {
        final String sId = _aTexto(row['socio_id'], _aTexto(row['id']));
        if (sociosMostrados.contains(sId)) continue;
        sociosMostrados.add(sId);

        final DateTime fechaHora = _aFecha(row['fecha_hora']) ?? ahoraPc;
        final DateTime horaInicioSesion =
            _aFecha(row['hora_ingreso_previo']) ?? fechaHora;

        final String tipoIngreso = _aTexto(row['tipo_ingreso'], 'INGRESO');
        final int? rawPlanId = (row['plan_id'] as num?)?.toInt();
        final double? rawImporte = (row['importe'] as num?)?.toDouble();
        final bool esDiaria = _esPagoSesionDiaria(rawPlanId, rawImporte);
        final int planId = esDiaria ? 2 : 1;
        final DateTime? fechaVenc = _aFecha(row['fecha_vencimiento']);

        final String identificador =
            planId == 2 ? 'Sesión Diaria' : 'Mensual / Socio';
        final String estadoOriginal = _aTexto(row['estado'], 'PERMITIDO');

        int minTrans = ahoraPc.difference(horaInicioSesion).inMinutes;
        if (minTrans < 0) minTrans = 0;

        final bool expiro4h = minTrans >= 240;
        final bool esVigente = estadoOriginal == 'PERMITIDO' && !expiro4h;
        final String estadoDosValores = esVigente ? 'Vigente' : 'Vencido';

        if (filtroEstado == 'VIGENTE' && estadoDosValores != 'Vigente') {
          continue;
        }
        if (filtroEstado == 'VENCIDO' && estadoDosValores != 'Vencido') {
          continue;
        }

        final DateTime horaFin4h = horaInicioSesion.add(
          const Duration(hours: 4),
        );
        final String horaFinStr =
            "${horaFin4h.hour.toString().padLeft(2, '0')}:${horaFin4h.minute.toString().padLeft(2, '0')}";
        final String horaIniStr =
            "${horaInicioSesion.hour.toString().padLeft(2, '0')}:${horaInicioSesion.minute.toString().padLeft(2, '0')}";
        final int minRest = (240 - minTrans).clamp(0, 240);
        final String tRestStr = _formatearMinutosRestantes(minRest);

        final String templateHuella = _aTexto(
          row['huella_registrada'],
          _aTexto(row['template_leido']),
        );

        String infoVigencia = '';
        if (planId == 2) {
          infoVigencia = esVigente
              ? 'Huella N° $templateHuella • Sesión Activa: Quedan $tRestStr (Vence $horaFinStr)'
              : 'Huella N° $templateHuella • Sesión de 4h vencida (Ingresó $horaIniStr)';
        } else if (fechaVenc != null) {
          final DateTime vencSoloDia = DateTime(
            fechaVenc.year,
            fechaVenc.month,
            fechaVenc.day,
          );
          final int diasRest = vencSoloDia.difference(hoySoloDia).inDays;
          if (diasRest >= 0) {
            infoVigencia = esVigente
                ? 'Huella N° $templateHuella • Quedan $diasRest días • Sesión 4h ($tRestStr hasta $horaFinStr)'
                : 'Huella N° $templateHuella • Sesión 4h vencida (Ingresó $horaIniStr) • Quedan $diasRest días';
          } else {
            infoVigencia =
                'Huella N° $templateHuella • Mensualidad Vencida (30 días cumplidos)';
          }
        } else {
          infoVigencia = 'Huella N° $templateHuella • Mensualidad Vencida';
        }

        historial.add({
          'id': _aTexto(row['id']),
          'socio_id': sId,
          'identificador': identificador,
          'tipo_ingreso': tipoIngreso,
          'estado': estadoDosValores,
          'estado_original': estadoOriginal,
          'fecha_hora': fechaHora,
          'hora_ingreso_previo': horaInicioSesion,
          'fecha_vencimiento_sesion': horaFin4h,
          'minutos_restantes': esVigente ? minRest : 0,
          'detalle_vigencia': infoVigencia,
          'template_huella': templateHuella,
          'ci': _aTexto(row['ci']),
          'nombre_completo': _aTexto(row['nombre_completo'], 'Socio'),
          'telefono': _aTexto(row['telefono']),
          'correo': _aTexto(row['correo']),
          'foto_url': row['foto_url'] != null ? _aTexto(row['foto_url']) : null,
        });
      }
      return historial;
    } catch (_) {
      return [];
    } finally {
      if (conn != null) await conn.close();
    }
  }

  /// Autentica al personal:
  /// - Si tiene permiso de ADMINISTRADOR, recibe acceso total a los 7 módulos (incluidos Socios & Membresías y Configuración).
  /// - Si es PERSONAL u otro rol, recibe exactamente los módulos que tiene asignados.
  Future<Map<String, dynamic>?> autenticarPersonal({
    required String usuarioOCorreo,
    required String password,
  }) async {
    MySqlConnection? conn;
    ultimoError = null;
    try {
      conn = await _getConnection();
      await _asegurarEstructuraYPlanes(conn);
      await _asegurarColumnasPersonal(conn);

      final String u = usuarioOCorreo.trim();
      final String p = password.trim();

      var results = await conn.query(
        '''
        SELECT id, nombre, usuario, password, rol, permisos_modulos, activo 
        FROM personal_erp 
        WHERE (LOWER(TRIM(usuario)) = LOWER(?) OR LOWER(TRIM(nombre)) = LOWER(?))
          AND TRIM(password) = ?
        LIMIT 1
        ''',
        [u, u, p],
      );

      if (results.isEmpty) {
        ultimoError = 'Usuario o contraseña incorrectos.';
        return null;
      }

      final row = results.first;
      if (!(row['activo'] == 1 || row['activo'] == true)) {
        ultimoError = 'Esta cuenta de personal se encuentra desactivada.';
        return null;
      }

      final String userLogin = _aTexto(row['usuario']);
      final String rol = _aTexto(row['rol'], 'PERSONAL').toUpperCase();
      final String rawPermisos = _aTexto(row['permisos_modulos']);
      final List<String> modulosPermitidos = _decodificarModulosAsignados(
        rawPermisos,
        rol,
        usuario: userLogin,
      );

      final datosSesion = {
        'id': _aTexto(row['id']),
        'nombre': _aTexto(row['nombre'], 'Personal'),
        'usuario': userLogin,
        'rol': rol,
        'modulos': modulosPermitidos,
      };
      usuarioSesionActual = datosSesion;
      return datosSesion;
    } catch (e) {
      ultimoError = 'Error conectando con la base de datos: $e';
      return null;
    } finally {
      if (conn != null) await conn.close();
    }
  }

  Future<List<Map<String, dynamic>>> obtenerListaPersonal() async {
    MySqlConnection? conn;
    try {
      conn = await _getConnection();
      await _asegurarEstructuraYPlanes(conn);
      await _asegurarColumnasPersonal(conn);

      var results = await conn.query('SELECT * FROM personal_erp');
      List<Map<String, dynamic>> personal = [];

      for (var row in results) {
        final String userLogin = _aTexto(row['usuario']);
        final String rol = _aTexto(row['rol'], 'PERSONAL').toUpperCase();
        final String rawPermisos = _aTexto(row['permisos_modulos']);
        final List<String> modulosPermitidos = _decodificarModulosAsignados(
          rawPermisos,
          rol,
          usuario: userLogin,
        );

        personal.add({
          'id': _aTexto(row['id']),
          'nombre': _aTexto(row['nombre'], 'Sin Nombre'),
          'usuario': userLogin,
          'password': _aTexto(row['password']),
          'rol': rol,
          'modulos': modulosPermitidos,
          'activo': row['activo'] == 1 || row['activo'] == true,
        });
      }
      return personal;
    } catch (_) {
      return [];
    } finally {
      if (conn != null) await conn.close();
    }
  }

  /// Guarda los módulos asignados al miembro del personal:
  /// - Si es ADMINISTRADOR, le asigna acceso total a los 7 módulos.
  /// - Si es cualquier otro rol, guarda exactamente los módulos normalizados seleccionados.
  Future<bool> guardarMiembroPersonal({
    String? id,
    required String nombre,
    required String usuario,
    required String password,
    required String rol,
    required List<String> modulosPermitidos,
    bool activo = true,
  }) async {
    MySqlConnection? conn;
    ultimoError = null;
    try {
      conn = await _getConnection();
      await _asegurarEstructuraYPlanes(conn);
      await _asegurarColumnasPersonal(conn);

      final String rolLimpio = rol.trim().toUpperCase();
      final List<String> modulosExactos = [];

      if (rolLimpio.contains('ADMIN') ||
          usuario.trim().toLowerCase() == 'admin') {
        modulosExactos.addAll(todosLosModulosSistema);
      } else {
        for (final m in modulosPermitidos) {
          final canonico = normalizarNombreModulo(m);
          if (canonico != null && !modulosExactos.contains(canonico)) {
            modulosExactos.add(canonico);
          }
        }
      }

      final String permisosJson = jsonEncode(modulosExactos);

      if (id == null || id.trim().isEmpty) {
        await conn.query(
          '''
          INSERT INTO personal_erp (id, nombre, usuario, password, rol, permisos_modulos, activo)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            const Uuid().v4(),
            nombre.trim(),
            usuario.trim(),
            password.trim(),
            rolLimpio,
            permisosJson,
            activo ? 1 : 0,
          ],
        );
      } else {
        await conn.query(
          '''
          UPDATE personal_erp 
          SET nombre = ?, usuario = ?, password = ?, rol = ?, permisos_modulos = ?, activo = ?
          WHERE id = ?
          ''',
          [
            nombre.trim(),
            usuario.trim(),
            password.trim(),
            rolLimpio,
            permisosJson,
            activo ? 1 : 0,
            id.trim(),
          ],
        );
      }

      if (usuarioSesionActual != null &&
          (usuarioSesionActual!['id'] == id ||
              usuarioSesionActual!['usuario'].toString().toLowerCase() ==
                  usuario.trim().toLowerCase())) {
        usuarioSesionActual!['modulos'] = modulosExactos;
        usuarioSesionActual!['nombre'] = nombre.trim();
        usuarioSesionActual!['rol'] = rolLimpio;
      }

      return true;
    } catch (e) {
      ultimoError = e.toString();
      return false;
    } finally {
      if (conn != null) await conn.close();
    }
  }

  Future<bool> eliminarMiembroPersonal(String id) async {
    MySqlConnection? conn;
    ultimoError = null;
    try {
      conn = await _getConnection();
      await conn.query('DELETE FROM personal_erp WHERE id = ?', [id]);
      return true;
    } catch (e) {
      ultimoError = e.toString();
      return false;
    } finally {
      if (conn != null) await conn.close();
    }
  }

  Future<List<String>?> obtenerModulosPermitidosPorNombre(
    String nombreUsuario,
  ) async {
    MySqlConnection? conn;
    try {
      conn = await _getConnection();
      await _asegurarEstructuraYPlanes(conn);
      await _asegurarColumnasPersonal(conn);

      final String limpio = nombreUsuario.trim();
      var res = await conn.query(
        '''
        SELECT usuario, rol, permisos_modulos 
        FROM personal_erp 
        WHERE id = ? OR LOWER(TRIM(nombre)) = LOWER(?) OR LOWER(TRIM(usuario)) = LOWER(?) 
        LIMIT 1
        ''',
        [limpio, limpio, limpio],
      );
      if (res.isEmpty) return null;

      final String userLogin = _aTexto(res.first['usuario']);
      final String rol = _aTexto(res.first['rol'], 'PERSONAL');
      final String raw = _aTexto(res.first['permisos_modulos']);
      return _decodificarModulosAsignados(raw, rol, usuario: userLogin);
    } catch (_) {
      return null;
    } finally {
      if (conn != null) await conn.close();
    }
  }

  Future<Map<String, dynamic>> obtenerConfiguracionSistema() async {
    MySqlConnection? conn;
    try {
      conn = await _getConnection();
      await _asegurarEstructuraYPlanes(conn);

      await conn.query('''
        UPDATE configuracion_erp 
        SET dahua_ip = '192.168.2.108',
            dahua_usuario = 'admin',
            dahua_password = 'Billblas'
        WHERE id = 1 AND (dahua_password IS NULL OR TRIM(dahua_password) = '' OR dahua_password = 'admin123')
      ''');

      var res = await conn.query(
        'SELECT * FROM configuracion_erp WHERE id = 1 LIMIT 1',
      );
      if (res.isEmpty) {
        return {
          'nombre_gimnasio': 'THOR GYM',
          'nit_telefono': '70000000',
          'direccion': 'Av. Principal - Bolivia',
          'mensaje_recibo': '¡Gracias por entrenar con nosotros!',
          'precio_mensual': 100.0,
          'precio_sesion': 10.0,
          'horas_reingreso': 4,
          'dahua_ip': '192.168.2.108',
          'dahua_puerto': 80,
          'dahua_usuario': 'admin',
          'dahua_password': 'Billblas',
        };
      }
      final row = res.first;
      final String ipG = _aTexto(row['dahua_ip'], '192.168.2.108');
      final String passG = _aTexto(row['dahua_password'], 'Billblas').trim();
      return {
        'nombre_gimnasio': _aTexto(row['nombre_gimnasio'], 'THOR GYM'),
        'nit_telefono': _aTexto(row['nit_telefono']),
        'direccion': _aTexto(row['direccion']),
        'mensaje_recibo': _aTexto(
          row['mensaje_recibo'],
          '¡Gracias por entrenar con nosotros!',
        ),
        'precio_mensual':
            (row['precio_mensual'] as num?)?.toDouble() ?? 100.0,
        'precio_sesion':
            (row['precio_sesion'] as num?)?.toDouble() ?? 10.0,
        'horas_reingreso': (row['horas_reingreso'] as num?)?.toInt() ?? 4,
        'dahua_ip': ipG == '192.168.1.108' ? '192.168.2.108' : ipG,
        'dahua_puerto': (row['dahua_puerto'] as num?)?.toInt() ?? 80,
        'dahua_usuario': _aTexto(row['dahua_usuario'], 'admin'),
        'dahua_password':
            (passG.isEmpty || passG == 'admin123') ? 'Billblas' : passG,
      };
    } catch (_) {
      return {
        'nombre_gimnasio': 'THOR GYM',
        'nit_telefono': '70000000',
        'direccion': 'Av. Principal - Bolivia',
        'mensaje_recibo': '¡Gracias por entrenar con nosotros!',
        'precio_mensual': 100.0,
        'precio_sesion': 10.0,
        'horas_reingreso': 4,
        'dahua_ip': '192.168.2.108',
        'dahua_puerto': 80,
        'dahua_usuario': 'admin',
        'dahua_password': 'Billblas',
      };
    } finally {
      if (conn != null) await conn.close();
    }
  }

  Future<bool> guardarConfiguracionSistema(Map<String, dynamic> config) async {
    MySqlConnection? conn;
    ultimoError = null;
    try {
      conn = await _getConnection();
      await _asegurarEstructuraYPlanes(conn);

      final double pMens =
          (config['precio_mensual'] as num?)?.toDouble() ?? 100.0;
      final double pSes =
          (config['precio_sesion'] as num?)?.toDouble() ?? 10.0;
      final String passCfg =
          (config['dahua_password'] ?? 'Billblas').toString().trim();

      await conn.query(
        '''
        UPDATE configuracion_erp SET
          nombre_gimnasio = ?, nit_telefono = ?, direccion = ?, mensaje_recibo = ?,
          precio_mensual = ?, precio_sesion = ?, horas_reingreso = ?,
          dahua_ip = ?, dahua_puerto = ?, dahua_usuario = ?, dahua_password = ?
        WHERE id = 1
        ''',
        [
          config['nombre_gimnasio'] ?? 'THOR GYM',
          config['nit_telefono'] ?? '',
          config['direccion'] ?? '',
          config['mensaje_recibo'] ?? '¡Gracias por entrenar con nosotros!',
          pMens,
          pSes,
          config['horas_reingreso'] ?? 4,
          config['dahua_ip'] ?? '192.168.2.108',
          config['dahua_puerto'] ?? 80,
          config['dahua_usuario'] ?? 'admin',
          (passCfg.isEmpty || passCfg == 'admin123') ? 'Billblas' : passCfg,
        ],
      );
      return true;
    } catch (e) {
      ultimoError = e.toString();
      return false;
    } finally {
      if (conn != null) await conn.close();
    }
  }

  Future<List<Map<String, dynamic>>> obtenerPagosPorRango({
    required DateTime desde,
    required DateTime hasta,
  }) async {
    MySqlConnection? conn;
    try {
      conn = await _getConnection();
      await _asegurarEstructuraYPlanes(conn);

      final String dStr =
          "${desde.year}-${desde.month.toString().padLeft(2, '0')}-${desde.day.toString().padLeft(2, '0')} 00:00:00";
      final String hStr =
          "${hasta.year}-${hasta.month.toString().padLeft(2, '0')}-${hasta.day.toString().padLeft(2, '0')} 23:59:59";

      final results = await conn.query(
        '''
        SELECT m.id, m.socio_id, m.plan_id, m.fecha_pago, m.fecha_vencimiento,
               m.importe, m.metodo_pago, m.qr_verificado, s.nombre_completo, s.ci
        FROM mensualidades m
        LEFT JOIN socios s ON (m.socio_id = s.id OR m.id = s.id)
        WHERE m.fecha_pago >= ? AND m.fecha_pago <= ?
        ORDER BY m.fecha_pago DESC
        ''',
        [dStr, hStr],
      );

      List<Map<String, dynamic>> lista = [];
      for (var row in results) {
        final int? rawPlanId = (row['plan_id'] as num?)?.toInt();
        final double importe = (row['importe'] as num?)?.toDouble() ?? 0.0;
        final bool esDiaria = _esPagoSesionDiaria(rawPlanId, importe);
        lista.add({
          'id': _aTexto(row['id']),
          'nombre_completo': _aTexto(
            row['nombre_completo'],
            'Socio Eliminado',
          ),
          'ci': _aTexto(row['ci'], 'S/N'),
          'concepto': esDiaria ? 'Sesión Diaria' : 'Mensual / Socio',
          'es_sesion_diaria': esDiaria,
          'fecha_pago': _aFecha(row['fecha_pago']) ?? DateTime.now(),
          'importe': importe,
          'metodo_pago': _aTexto(row['metodo_pago'], 'EFECTIVO'),
          'qr_verificado':
              row['qr_verificado'] == 1 || row['qr_verificado'] == true,
        });
      }
      return lista;
    } catch (_) {
      return [];
    } finally {
      if (conn != null) await conn.close();
    }
  }

  Future<List<Map<String, dynamic>>> obtenerAsistenciasPorRango({
    required DateTime desde,
    required DateTime hasta,
  }) async {
    final todas = await obtenerHistorialAccesos();
    final DateTime inicio = DateTime(desde.year, desde.month, desde.day);
    final DateTime fin = DateTime(
      hasta.year,
      hasta.month,
      hasta.day,
      23,
      59,
      59,
    );
    return todas.where((item) {
      final DateTime fh = item['fecha_hora'] as DateTime;
      return !fh.isBefore(inicio) && !fh.isAfter(fin);
    }).toList();
  }

  Future<String?> generarReporteEjecutivoPdf({
    required String tituloReporte,
    required DateTime desde,
    required DateTime hasta,
    required List<Map<String, String>> resumenKpis,
    required List<String> cabecerasTabla,
    required List<List<String>> filasTabla,
    bool imprimir = false,
  }) async {
    try {
      final config = await obtenerConfiguracionSistema();
      final String nombreGym =
          (config['nombre_gimnasio'] ?? 'THOR GYM').toString();
      final pdf = pw.Document();
      final ahora = DateTime.now();
      String fmtFecha(DateTime d) =>
          "${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}";

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(28),
          build: (pw.Context context) => [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      nombreGym,
                      style: pw.TextStyle(
                        fontSize: 20,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.Text(
                      tituloReporte,
                      style: pw.TextStyle(
                        fontSize: 13,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                pw.Text(
                  'Periodo: ${fmtFecha(desde)} al ${fmtFecha(hasta)}',
                  style: const pw.TextStyle(fontSize: 10),
                ),
              ],
            ),
            pw.Divider(height: 20),
            pw.Wrap(
              spacing: 12,
              runSpacing: 8,
              children: resumenKpis
                  .map(
                    (kpi) => pw.Container(
                      padding: const pw.EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: pw.BoxDecoration(
                        border: pw.Border.all(color: PdfColors.grey400),
                        borderRadius: const pw.BorderRadius.all(
                          pw.Radius.circular(6),
                        ),
                      ),
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text(
                            kpi['titulo'] ?? '',
                            style: const pw.TextStyle(
                              fontSize: 9,
                              color: PdfColors.grey700,
                            ),
                          ),
                          pw.SizedBox(height: 3),
                          pw.Text(
                            kpi['valor'] ?? '',
                            style: pw.TextStyle(
                              fontSize: 12,
                              fontWeight: pw.FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),
            pw.SizedBox(height: 18),
            pw.TableHelper.fromTextArray(
              headers: cabecerasTabla,
              data: filasTabla,
              headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 9,
                color: PdfColors.white,
              ),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.blueGrey800,
              ),
              cellStyle: const pw.TextStyle(fontSize: 8.5),
            ),
          ],
        ),
      );

      final bytes = await pdf.save();
      String? rutaArchivo;
      try {
        final dir = await getApplicationDocumentsDirectory();
        final carpeta = Directory('${dir.path}/Reportes_Gym');
        if (!await carpeta.exists()) await carpeta.create(recursive: true);
        rutaArchivo =
            '${carpeta.path}/Reporte_${ahora.millisecondsSinceEpoch}.pdf';
        await File(rutaArchivo).writeAsBytes(bytes);
      } catch (_) {}

      if (imprimir) {
        await Printing.layoutPdf(
          onLayout: (PdfPageFormat format) async => bytes,
          name: tituloReporte,
        );
      }
      return rutaArchivo;
    } catch (e) {
      ultimoError = e.toString();
      return null;
    }
  }

  Future<String?> generarEImprimirBoleta({
    required String nombreSocio,
    required String ciSocio,
    required String conceptoPlan,
    required double importe,
    required String metodoPago,
    required DateTime fechaVencimiento,
    bool imprimir = true,
  }) async {
    try {
      final config = await obtenerConfiguracionSistema();
      final String nombreGym =
          (config['nombre_gimnasio'] ?? 'THOR GYM').toString();
      final String mensajePie =
          (config['mensaje_recibo'] ?? '¡Gracias por entrenar con nosotros!')
              .toString();

      final pdf = pw.Document();
      final ahora = DateTime.now();
      final nroRecibo = const Uuid().v4().substring(0, 8).toUpperCase();

      String fmtF(DateTime d) =>
          "${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}";
      String fmtH(DateTime d) =>
          "${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}";

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.roll80,
          margin: const pw.EdgeInsets.all(12),
          build: (pw.Context context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              pw.Center(
                child: pw.Text(
                  nombreGym,
                  style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.Center(
                child: pw.Text(
                  'COMPROBANTE / BOLETA DE PAGO',
                  style: const pw.TextStyle(fontSize: 10),
                ),
              ),
              pw.Divider(),
              pw.Text(
                'Recibo Nro: $nroRecibo',
                style: const pw.TextStyle(fontSize: 9),
              ),
              pw.Text(
                'Fecha: ${fmtF(ahora)} ${fmtH(ahora)}',
                style: const pw.TextStyle(fontSize: 9),
              ),
              pw.Divider(),
              pw.Text(
                'SOCIO: $nombreSocio',
                style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Text('CI: $ciSocio', style: const pw.TextStyle(fontSize: 9)),
              pw.Divider(),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Expanded(
                    child: pw.Text(
                      conceptoPlan,
                      style: const pw.TextStyle(fontSize: 10),
                    ),
                  ),
                  pw.Text(
                    'Bs ${importe.toStringAsFixed(2)}',
                    style: pw.TextStyle(
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 6),
              pw.Text(
                'Método de Pago: $metodoPago',
                style: const pw.TextStyle(fontSize: 9),
              ),
              pw.Text(
                'Válido hasta: ${fmtF(fechaVencimiento)} ${fmtH(fechaVencimiento)}',
                style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Divider(),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'TOTAL PAGADO:',
                    style: pw.TextStyle(
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    'Bs ${importe.toStringAsFixed(2)}',
                    style: pw.TextStyle(
                      fontSize: 12,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 12),
              pw.Center(
                child: pw.Text(
                  mensajePie,
                  style: const pw.TextStyle(fontSize: 9),
                ),
              ),
            ],
          ),
        ),
      );

      final bytes = await pdf.save();
      String? rutaArchivo;
      try {
        final dir = await getApplicationDocumentsDirectory();
        final carpeta = Directory('${dir.path}/Recibos_Gym');
        if (!await carpeta.exists()) await carpeta.create(recursive: true);
        rutaArchivo =
            '${carpeta.path}/Comprobante_${ciSocio}_${ahora.millisecondsSinceEpoch}.pdf';
        await File(rutaArchivo).writeAsBytes(bytes);
      } catch (_) {}

      if (imprimir) {
        await Printing.layoutPdf(
          onLayout: (PdfPageFormat format) async => bytes,
          name: 'Boleta_${ciSocio}_$nroRecibo',
        );
      }
      return rutaArchivo;
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> obtenerPagosCaja({
    DateTime? fecha,
    String filtroMetodo = 'TODOS',
  }) async {
    MySqlConnection? conn;
    try {
      conn = await _getConnection();
      await _asegurarEstructuraYPlanes(conn);

      List<String> cond = [];
      List<dynamic> params = [];

      if (fecha != null) {
        cond.add("DATE(m.fecha_pago) = ?");
        params.add(
          "${fecha.year}-${fecha.month.toString().padLeft(2, '0')}-${fecha.day.toString().padLeft(2, '0')}",
        );
      }
      if (filtroMetodo == 'EFECTIVO') cond.add("m.metodo_pago = 'EFECTIVO'");
      if (filtroMetodo == 'QR') cond.add("m.metodo_pago = 'QR'");
      if (filtroMetodo == 'PENDIENTES_QR') {
        cond.add("m.metodo_pago = 'QR' AND m.qr_verificado = 0");
      }

      String whereClause = cond.isNotEmpty ? 'WHERE ${cond.join(" AND ")}' : '';
      final results = await conn.query('''
        SELECT m.id, m.socio_id, m.plan_id, m.fecha_pago, m.fecha_vencimiento,
               m.importe, m.metodo_pago, m.comprobante_url, m.qr_verificado,
               m.monto_verificado, s.nombre_completo, s.ci
        FROM mensualidades m
        LEFT JOIN socios s ON (m.socio_id = s.id OR m.id = s.id)
        $whereClause
        ORDER BY m.fecha_pago DESC
      ''', params);

      List<Map<String, dynamic>> pagos = [];
      for (var row in results) {
        final double imp = (row['importe'] as num?)?.toDouble() ?? 0.0;
        final int? pId = (row['plan_id'] as num?)?.toInt();
        pagos.add({
          'id': _aTexto(row['id']),
          'socio_id': _aTexto(row['socio_id']),
          'nombre_completo': _aTexto(
            row['nombre_completo'],
            'Socio Eliminado',
          ),
          'ci': _aTexto(row['ci'], 'S/N'),
          'concepto': _esPagoSesionDiaria(pId, imp)
              ? 'Sesión Diaria'
              : 'Mensual / Socio',
          'fecha_pago': _aFecha(row['fecha_pago']) ?? DateTime.now(),
          'fecha_vencimiento':
              _aFecha(row['fecha_vencimiento']) ?? DateTime.now(),
          'importe': imp,
          'metodo_pago': _aTexto(row['metodo_pago'], 'EFECTIVO'),
          'comprobante_url': row['comprobante_url'] != null
              ? _aTexto(row['comprobante_url'])
              : null,
          'qr_verificado':
              row['qr_verificado'] == 1 || row['qr_verificado'] == true,
          'monto_verificado': row['monto_verificado'] != null
              ? (row['monto_verificado'] as num).toDouble()
              : null,
        });
      }
      return pagos;
    } catch (_) {
      return [];
    } finally {
      if (conn != null) await conn.close();
    }
  }

  Future<bool> verificarMontoPagoQr({
    required String mensualidadId,
    required double montoComprobante,
  }) async {
    MySqlConnection? conn;
    ultimoError = null;
    try {
      conn = await _getConnection();
      await _asegurarEstructuraYPlanes(conn);
      final res = await conn.query(
        'UPDATE mensualidades SET importe = ?, monto_verificado = ?, qr_verificado = 1 WHERE id = ? AND qr_verificado = 0',
        [montoComprobante, montoComprobante, mensualidadId],
      );
      if ((res.affectedRows ?? 0) == 0) {
        ultimoError = 'Este pago ya fue verificado previamente.';
        return false;
      }
      return true;
    } catch (e) {
      ultimoError = e.toString();
      return false;
    } finally {
      if (conn != null) await conn.close();
    }
  }

  Future<Map<String, dynamic>> obtenerMetricasDashboard() async {
    MySqlConnection? conn;
    try {
      conn = await _getConnection();
      await _asegurarEstructuraYPlanes(conn);

      final DateTime ahoraPc = DateTime.now();
      final String hoyStr =
          "${ahoraPc.year}-${ahoraPc.month.toString().padLeft(2, '0')}-${ahoraPc.day.toString().padLeft(2, '0')}";

      var resAccesos = await conn.query(
        "SELECT COUNT(*) as total FROM accesos_log WHERE DATE(fecha_hora) = ? AND estado = 'PERMITIDO'",
        [hoyStr],
      );
      int accesosHoy = resAccesos.first['total'] ?? 0;

      var resIngresos = await conn.query(
        'SELECT SUM(importe) as total FROM mensualidades WHERE DATE(fecha_pago) = ? AND qr_verificado = 1',
        [hoyStr],
      );
      double ingresosHoy = resIngresos.first['total'] != null
          ? (resIngresos.first['total'] as num).toDouble()
          : 0.0;

      final listaSocios = await obtenerListaSocios();
      int sociosMensualesActivos = 0, vigentes = 0, vencidos = 0;

      for (var s in listaSocios) {
        if (s['activo'] == true && s['plan_id'] == 1) {
          sociosMensualesActivos++;
          if (s['estado'] == 'Vigente') {
            vigentes++;
          } else {
            vencidos++;
          }
        }
      }

      var resBajas = await conn.query(
        'SELECT COUNT(*) as total FROM socios WHERE activo = FALSE',
      );
      int bajas = resBajas.first['total'] ?? 0;

      var resSemana = await conn.query('''
        SELECT DATE(fecha_hora) as fecha, COUNT(*) as cantidad 
        FROM accesos_log 
        WHERE fecha_hora >= DATE_SUB(CURDATE(), INTERVAL 6 DAY) AND estado = 'PERMITIDO'
        GROUP BY DATE(fecha_hora)
        ORDER BY DATE(fecha_hora) ASC
      ''');

      List<int> asistenciaSemanal = List.filled(7, 0);
      DateTime hoy = DateTime(ahoraPc.year, ahoraPc.month, ahoraPc.day);

      for (var row in resSemana) {
        DateTime fRow = _aFecha(row['fecha']) ?? hoy;
        int diff = hoy
            .difference(DateTime(fRow.year, fRow.month, fRow.day))
            .inDays;
        if (diff >= 0 && diff < 7) {
          asistenciaSemanal[6 - diff] = (row['cantidad'] as num).toInt();
        }
      }

      return {
        'socios_activos': sociosMensualesActivos,
        'accesos_hoy': accesosHoy,
        'ingresos_hoy': ingresosHoy,
        'vencidos': vencidos,
        'vigentes': vigentes,
        'bajas': bajas,
        'asistencia_semanal': asistenciaSemanal,
      };
    } catch (e) {
      return {'error_sql': e.toString()};
    } finally {
      if (conn != null) await conn.close();
    }
  }
}