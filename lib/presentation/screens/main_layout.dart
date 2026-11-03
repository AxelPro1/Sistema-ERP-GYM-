import 'package:flutter/material.dart';
import '../../infrastructure/database/mysql_repository.dart';
import '../../application/services/dahua_biometric_service.dart';
import '../widgets/dashboard_principal.dart';
import '../widgets/socios_datagrid.dart';
import '../widgets/historial_asistencias.dart';
import '../widgets/caja_pos.dart';
import '../widgets/personal_widget.dart';
import '../widgets/reportes_widget.dart';
import '../widgets/configuracion_widget.dart';
import 'kiosko_acceso.dart';
import 'login_screen.dart';

class MainLayout extends StatefulWidget {
  final Map<String, dynamic>? usuarioActual;

  const MainLayout({super.key, this.usuarioActual});

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  final SocioRepository _repository = SocioRepository();
  final DahuaBiometricService _dahuaService = DahuaBiometricService();

  String _moduloSeleccionado = 'Dashboard';
  List<String> _modulosPermitidos = List<String>.from(
    SocioRepository.todosLosModulosSistema,
  );
  String _nombreUsuario = 'Administrador';
  String _rolUsuario = 'ADMINISTRADOR';
  String _loginUsuario = 'admin';

  final List<Map<String, dynamic>> _catalogoModulos = [
    {'nombre': 'Dashboard', 'icono': Icons.dashboard_outlined},
    {'nombre': 'Socios & Membresías', 'icono': Icons.people_alt_outlined},
    {'nombre': 'Control de Asistencias', 'icono': Icons.fingerprint},
    {'nombre': 'Finanzas & Caja', 'icono': Icons.point_of_sale_outlined},
    {'nombre': 'Personal', 'icono': Icons.badge_outlined},
    {'nombre': 'Reportes', 'icono': Icons.bar_chart_outlined},
    {'nombre': 'Configuración', 'icono': Icons.settings_outlined},
  ];

  bool get _esAdministrador =>
      _rolUsuario.trim().toUpperCase().contains('ADMIN') ||
      _loginUsuario.trim().toLowerCase() == 'admin';

  @override
  void initState() {
    super.initState();
    _inicializarSesionYPermisos();
    _conectarLectorDahua();
  }

  Future<void> _conectarLectorDahua() async {
    final config = await _repository.obtenerConfiguracionSistema();
    await _dahuaService.configurarYConectar(
      nuevaIp: (config['dahua_ip'] ?? '192.168.2.108').toString(),
      nuevoPuerto: (config['dahua_puerto'] as num?)?.toInt() ?? 80,
      nuevoUsuario: (config['dahua_usuario'] ?? 'admin').toString(),
      nuevaPassword: (config['dahua_password'] ?? 'Billblas').toString(),
    );
  }

  List<String> _normalizarListaModulos(
    List<dynamic>? rawList, {
    required bool esAdmin,
  }) {
    if (esAdmin) {
      return List<String>.from(SocioRepository.todosLosModulosSistema);
    }
    final List<String> limpios = [];
    if (rawList != null) {
      for (final item in rawList) {
        final canonico = SocioRepository.normalizarNombreModulo(
          item.toString(),
        );
        if (canonico != null && !limpios.contains(canonico)) {
          limpios.add(canonico);
        }
      }
    }
    if (limpios.isEmpty) {
      return ['Dashboard'];
    }
    return SocioRepository.todosLosModulosSistema
        .where((m) => limpios.contains(m))
        .toList();
  }

  Future<void> _inicializarSesionYPermisos() async {
    final Map<String, dynamic>? sesion =
        widget.usuarioActual ?? SocioRepository.usuarioSesionActual;

    if (sesion != null) {
      final String nombre = (sesion['nombre'] ?? 'Usuario').toString();
      final String rol = (sesion['rol'] ?? 'PERSONAL').toString().toUpperCase();
      final String login = (sesion['usuario'] ?? nombre).toString();
      final bool esAdmin =
          rol.contains('ADMIN') || login.trim().toLowerCase() == 'admin';

      final List<String> modulos = _normalizarListaModulos(
        sesion['modulos'] as List?,
        esAdmin: esAdmin,
      );

      setState(() {
        _nombreUsuario = nombre;
        _rolUsuario = rol;
        _loginUsuario = login;
        _modulosPermitidos = modulos;
        if (!_modulosPermitidos.contains(_moduloSeleccionado) &&
            _modulosPermitidos.isNotEmpty) {
          _moduloSeleccionado = _modulosPermitidos.first;
        }
      });
    }

    await _refrescarPermisosDesdeBaseDeDatos();
  }

  Future<void> _refrescarPermisosDesdeBaseDeDatos() async {
    if (_esAdministrador) {
      if (mounted) {
        setState(() {
          _modulosPermitidos = List<String>.from(
            SocioRepository.todosLosModulosSistema,
          );
        });
      }
      return;
    }

    final modulosBd = await _repository.obtenerModulosPermitidosPorNombre(
      _loginUsuario,
    );
    if (!mounted || modulosBd == null || modulosBd.isEmpty) return;

    final List<String> modulosNormalizados = _normalizarListaModulos(
      modulosBd,
      esAdmin: _esAdministrador,
    );

    setState(() {
      _modulosPermitidos = modulosNormalizados;
      if (!_modulosPermitidos.contains(_moduloSeleccionado) &&
          _modulosPermitidos.isNotEmpty) {
        _moduloSeleccionado = _modulosPermitidos.first;
      }
    });
  }

  Widget _construirContenidoModulo(String nombreModulo) {
    if (!_esAdministrador && !_modulosPermitidos.contains(nombreModulo)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 64, color: Colors.red),
            const SizedBox(height: 12),
            Text(
              'No tiene permisos asignados para acceder al módulo "$nombreModulo".',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      );
    }

    switch (nombreModulo) {
      case 'Dashboard':
        return DashboardPrincipalWidget();
      case 'Socios & Membresías':
        return const SociosDataGrid();
      case 'Control de Asistencias':
        return HistorialAsistenciasWidget();
      case 'Finanzas & Caja':
        return CajaPosWidget();
      case 'Personal':
        return const PersonalWidget();
      case 'Reportes':
        return ReportesWidget();
      case 'Configuración':
        return ConfiguracionWidget();
      default:
        return DashboardPrincipalWidget();
    }
  }

  void _cerrarSesion() {
    SocioRepository.usuarioSesionActual = null;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> modulosVisibles = _esAdministrador
        ? _catalogoModulos
        : _catalogoModulos
              .where((m) => _modulosPermitidos.contains(m['nombre']))
              .toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F9),
      body: Row(
        children: [
          Container(
            width: 260,
            color: const Color(0xFF1A2234),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 24,
                  ),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Colors.white12, width: 1),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF28A745),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.fitness_center,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'THOR GYM',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'Sistema ERP Biométrico',
                              style: TextStyle(
                                color: Colors.white60,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 10,
                    ),
                    itemCount: modulosVisibles.length,
                    itemBuilder: (context, index) {
                      final item = modulosVisibles[index];
                      final String nombreMod = item['nombre'].toString();
                      final IconData iconoMod = item['icono'] as IconData;
                      final bool activo = _moduloSeleccionado == nombreMod;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          tileColor: activo
                              ? const Color(0xFF28A745)
                              : Colors.transparent,
                          leading: Icon(
                            iconoMod,
                            color: activo ? Colors.white : Colors.white70,
                            size: 20,
                          ),
                          title: Text(
                            nombreMod,
                            style: TextStyle(
                              color: activo ? Colors.white : Colors.white70,
                              fontWeight: activo
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              fontSize: 14,
                            ),
                          ),
                          onTap: () async {
                            await _refrescarPermisosDesdeBaseDeDatos();
                            if (!mounted) return;
                            if (_esAdministrador ||
                                _modulosPermitidos.contains(nombreMod)) {
                              setState(() => _moduloSeleccionado = nombreMod);
                            }
                          },
                        ),
                      );
                    },
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        tileColor: Colors.white.withValues(alpha: 0.06),
                        leading: const Icon(
                          Icons.tv,
                          color: Colors.greenAccent,
                          size: 20,
                        ),
                        title: const Text(
                          'Modo Kiosko Acceso',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => KioskoAccesoScreen(),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor: const Color(0xFF28A745),
                          child: Text(
                            _nombreUsuario.isNotEmpty
                                ? _nombreUsuario[0].toUpperCase()
                                : 'U',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text(
                          _nombreUsuario,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '$_rolUsuario (${modulosVisibles.length} mód.)',
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 11,
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: 'Cerrar Sesión',
                          icon: const Icon(
                            Icons.logout,
                            color: Colors.redAccent,
                            size: 20,
                          ),
                          onPressed: _cerrarSesion,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 64,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _moduloSeleccionado,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.green.shade50,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Colors.green.shade300),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.fingerprint,
                                  size: 16,
                                  color: Color(0xFF28A745),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Lector Dahua: ${_dahuaService.ip}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.green.shade800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 14),
                          Text(
                            'Usuario: $_nombreUsuario ($_rolUsuario)',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: _construirContenidoModulo(_moduloSeleccionado),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}