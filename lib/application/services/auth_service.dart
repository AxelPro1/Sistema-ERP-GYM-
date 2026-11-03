import '../../infrastructure/database/mysql_repository.dart';

enum RolUsuario {
  administrador,
  atencionCliente,
  personal,
}

class UsuarioActual {
  final String id;
  final String nombre;
  final String usuario;
  final RolUsuario rol;
  final List<String> modulosPermitidos;

  UsuarioActual({
    this.id = '',
    required this.nombre,
    this.usuario = '',
    required this.rol,
    this.modulosPermitidos = const [],
  });

  bool get esAdministrador => rol == RolUsuario.administrador;

  bool get puedeAdministrarUsuarios =>
      esAdministrador || modulosPermitidos.contains('Personal');

  bool get puedeVerHistorial =>
      esAdministrador ||
      modulosPermitidos.contains('Control de Asistencias') ||
      modulosPermitidos.contains('Reportes');

  bool get puedeRegistrarHuellas =>
      esAdministrador || modulosPermitidos.contains('Socios & Membresías');

  bool get tieneAccesoAConfiguracion =>
      esAdministrador || modulosPermitidos.contains('Configuración');

  bool puedeVerModulo(String nombreModulo) {
    if (esAdministrador) return true;
    if (nombreModulo == 'Personal') return false;
    return modulosPermitidos.contains(nombreModulo);
  }
}

class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  final SocioRepository _repository = SocioRepository();
  UsuarioActual? currentUser;
  String? ultimoError;

  /// Autentica al usuario contra la tabla del módulo Personal en MySQL
  Future<bool> login(String usuarioOCorreo, String password) async {
    ultimoError = null;

    final data = await _repository.autenticarPersonal(
      usuarioOCorreo: usuarioOCorreo,
      password: password,
    );

    if (data == null) {
      ultimoError =
          _repository.ultimoError ?? 'Usuario o contraseña incorrectos.';
      return false;
    }

    final String rolStr = (data['rol'] ?? 'PERSONAL').toString().toUpperCase();
    final bool esAdmin = rolStr.contains('ADMIN');
    final List<String> modulos = data['modulos'] is List
        ? (data['modulos'] as List).map((e) => e.toString()).toList()
        : <String>[];

    currentUser = UsuarioActual(
      id: (data['id'] ?? '').toString(),
      nombre: (data['nombre'] ?? 'Personal').toString(),
      usuario: (data['usuario'] ?? usuarioOCorreo).toString(),
      rol: esAdmin ? RolUsuario.administrador : RolUsuario.atencionCliente,
      modulosPermitidos: modulos,
    );

    return true;
  }

  /// Alias compatible si en alguna pantalla se invoca iniciarSesion()
  Future<bool> iniciarSesion(String usuarioOCorreo, String password) {
    return login(usuarioOCorreo, password);
  }

  void logout() {
    currentUser = null;
  }
}