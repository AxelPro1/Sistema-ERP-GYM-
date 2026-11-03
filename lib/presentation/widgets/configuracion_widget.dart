import 'package:flutter/material.dart';
import '../../infrastructure/database/mysql_repository.dart';
import '../../application/services/dahua_biometric_service.dart';

class ConfiguracionWidget extends StatefulWidget {
  @override
  _ConfiguracionWidgetState createState() => _ConfiguracionWidgetState();
}

class _ConfiguracionWidgetState extends State<ConfiguracionWidget> {
  final _formKey = GlobalKey<FormState>();
  final SocioRepository _repository = SocioRepository();
  final DahuaBiometricService _dahuaService = DahuaBiometricService();

  final TextEditingController _nombreGymCtrl = TextEditingController();
  final TextEditingController _nitTelefonoCtrl = TextEditingController();
  final TextEditingController _direccionCtrl = TextEditingController();
  final TextEditingController _mensajeReciboCtrl = TextEditingController();
  final TextEditingController _precioMensualCtrl = TextEditingController();
  final TextEditingController _precioSesionCtrl = TextEditingController();
  final TextEditingController _horasReingresoCtrl = TextEditingController();

  // --- PARÁMETROS PUENTE ETHERNET DIRECTO (192.168.2.108) ---
  final TextEditingController _dahuaIpCtrl =
      TextEditingController(text: '192.168.2.108');
  final TextEditingController _dahuaPortCtrl =
      TextEditingController(text: '80');
  final TextEditingController _dahuaUserCtrl =
      TextEditingController(text: 'admin');
  final TextEditingController _dahuaPassCtrl = TextEditingController();

  bool _cargando = true;
  bool _guardando = false;
  bool _probandoEquipo = false;
  bool _ocultarPass = true;

  @override
  void initState() {
    super.initState();
    _cargarConfiguracion();
  }

  @override
  void dispose() {
    _nombreGymCtrl.dispose();
    _nitTelefonoCtrl.dispose();
    _direccionCtrl.dispose();
    _mensajeReciboCtrl.dispose();
    _precioMensualCtrl.dispose();
    _precioSesionCtrl.dispose();
    _horasReingresoCtrl.dispose();
    _dahuaIpCtrl.dispose();
    _dahuaPortCtrl.dispose();
    _dahuaUserCtrl.dispose();
    _dahuaPassCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargarConfiguracion() async {
    setState(() => _cargando = true);
    final config = await _repository.obtenerConfiguracionSistema();
    if (!mounted) return;

    final String ipGuardada =
        (config['dahua_ip'] ?? '192.168.2.108').toString().trim();
    final String passGuardada =
        (config['dahua_password'] ?? '').toString().trim();

    setState(() {
      _nombreGymCtrl.text =
          (config['nombre_gimnasio'] ?? 'THOR GYM').toString();
      _nitTelefonoCtrl.text = (config['nit_telefono'] ?? '').toString();
      _direccionCtrl.text = (config['direccion'] ?? '').toString();
      _mensajeReciboCtrl.text = (config['mensaje_recibo'] ??
              '¡Gracias por entrenar con nosotros!')
          .toString();
      _precioMensualCtrl.text =
          ((config['precio_mensual'] as num?)?.toDouble() ?? 100.0)
              .toStringAsFixed(2);
      _precioSesionCtrl.text =
          ((config['precio_sesion'] as num?)?.toDouble() ?? 10.0)
              .toStringAsFixed(2);
      _horasReingresoCtrl.text =
          ((config['horas_reingreso'] as num?)?.toInt() ?? 4).toString();

      _dahuaIpCtrl.text = (ipGuardada.isEmpty || ipGuardada == '192.168.1.108')
          ? '192.168.2.108'
          : ipGuardada;
      _dahuaPortCtrl.text =
          ((config['dahua_puerto'] as num?)?.toInt() ?? 80).toString();
      _dahuaUserCtrl.text = (config['dahua_usuario'] ?? 'admin').toString();
      _dahuaPassCtrl.text = passGuardada.isNotEmpty
          ? passGuardada
          : (_dahuaService.password.isNotEmpty
                ? _dahuaService.password
                : 'admin123');
      _cargando = false;
    });
  }

  Future<void> _guardarConfiguracion() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _guardando = true);

    final String ipFinal = _dahuaIpCtrl.text.trim().isEmpty
        ? '192.168.2.108'
        : _dahuaIpCtrl.text.trim();
    final int puertoFinal = int.tryParse(_dahuaPortCtrl.text.trim()) ?? 80;
    final String usuarioFinal = _dahuaUserCtrl.text.trim().isEmpty
        ? 'admin'
        : _dahuaUserCtrl.text.trim();
    final String passFinal = _dahuaPassCtrl.text.trim();

    final datos = {
      'nombre_gimnasio': _nombreGymCtrl.text.trim(),
      'nit_telefono': _nitTelefonoCtrl.text.trim(),
      'direccion': _direccionCtrl.text.trim(),
      'mensaje_recibo': _mensajeReciboCtrl.text.trim(),
      'precio_mensual':
          double.tryParse(_precioMensualCtrl.text.trim()) ?? 100.0,
      'precio_sesion': double.tryParse(_precioSesionCtrl.text.trim()) ?? 10.0,
      'horas_reingreso': int.tryParse(_horasReingresoCtrl.text.trim()) ?? 4,
      'dahua_ip': ipFinal,
      'dahua_puerto': puertoFinal,
      'dahua_usuario': usuarioFinal,
      'dahua_password': passFinal,
    };

    final ok = await _repository.guardarConfiguracionSistema(datos);
    await _dahuaService.configurarYConectar(
      nuevaIp: ipFinal,
      nuevoPuerto: puertoFinal,
      nuevoUsuario: usuarioFinal,
      nuevaPassword: passFinal,
    );

    if (!mounted) return;
    setState(() => _guardando = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Configuración guardada y puente Ethernet ($ipFinal) actualizado.'
              : 'Error al guardar: ${_repository.ultimoError}',
        ),
        backgroundColor: ok ? Colors.green : Colors.red,
      ),
    );
  }

  Future<void> _probarYSincronizarConEquipo() async {
    setState(() => _probandoEquipo = true);

    final String ipFinal = _dahuaIpCtrl.text.trim().isEmpty
        ? '192.168.2.108'
        : _dahuaIpCtrl.text.trim();
    final int puertoFinal = int.tryParse(_dahuaPortCtrl.text.trim()) ?? 80;
    final String usuarioFinal = _dahuaUserCtrl.text.trim().isEmpty
        ? 'admin'
        : _dahuaUserCtrl.text.trim();
    final String passFinal = _dahuaPassCtrl.text.trim();

    // Guardar primero en MySQL para que la contraseña quede persistente
    await _repository.guardarConfiguracionSistema({
      'nombre_gimnasio': _nombreGymCtrl.text.trim(),
      'nit_telefono': _nitTelefonoCtrl.text.trim(),
      'direccion': _direccionCtrl.text.trim(),
      'mensaje_recibo': _mensajeReciboCtrl.text.trim(),
      'precio_mensual':
          double.tryParse(_precioMensualCtrl.text.trim()) ?? 100.0,
      'precio_sesion': double.tryParse(_precioSesionCtrl.text.trim()) ?? 10.0,
      'horas_reingreso': int.tryParse(_horasReingresoCtrl.text.trim()) ?? 4,
      'dahua_ip': ipFinal,
      'dahua_puerto': puertoFinal,
      'dahua_usuario': usuarioFinal,
      'dahua_password': passFinal,
    });

    final conectado = await _dahuaService.configurarYConectar(
      nuevaIp: ipFinal,
      nuevoPuerto: puertoFinal,
      nuevoUsuario: usuarioFinal,
      nuevaPassword: passFinal,
    );

    int sincronizados = 0;
    if (conectado) {
      final socios = await _repository.obtenerListaSocios();
      sincronizados = await _dahuaService.sincronizarTodosLosSociosEnEquipo(
        socios,
        forzar: true,
      );
    }

    if (!mounted) return;
    setState(() => _probandoEquipo = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          conectado
              ? 'Conexión exitosa con $ipFinal. Se sincronizaron $sincronizados socios en la memoria del equipo.'
              : 'No hubo respuesta desde $ipFinal. Verifique el cable Ethernet y la contraseña del equipo.',
        ),
        backgroundColor: conectado ? Colors.green : Colors.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF28A745)),
      );
    }

    return SingleChildScrollView(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.storefront, color: Color(0xFF28A745)),
                      SizedBox(width: 10),
                      Text(
                        'Datos del Gimnasio y Tarifas del Sistema',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _nombreGymCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Nombre del Gimnasio',
                            prefixIcon: Icon(Icons.fitness_center),
                            border: OutlineInputBorder(),
                          ),
                          validator: (v) =>
                              v == null || v.isEmpty ? 'Requerido' : null,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextFormField(
                          controller: _nitTelefonoCtrl,
                          decoration: const InputDecoration(
                            labelText: 'NIT / Teléfono',
                            prefixIcon: Icon(Icons.phone),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _direccionCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Dirección',
                            prefixIcon: Icon(Icons.location_on_outlined),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextFormField(
                          controller: _mensajeReciboCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Mensaje al pie de la Boleta',
                            prefixIcon: Icon(Icons.receipt_long),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _precioMensualCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Precio Mensual / Socio (Bs)',
                            prefixIcon: Icon(Icons.payments_outlined),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextFormField(
                          controller: _precioSesionCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Precio Sesión Diaria (Bs)',
                            prefixIcon: Icon(Icons.today),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextFormField(
                          controller: _horasReingresoCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Límite de Sesión / Reingreso (Horas)',
                            prefixIcon: Icon(Icons.timer_outlined),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            Container(
              padding: const EdgeInsets.all(24),
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.settings_ethernet, color: Color(0xFF28A745)),
                      SizedBox(width: 10),
                      Text(
                        'Puente Ethernet Directo - Lector Dahua DHI-ASI3204E-DW',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Configuración de Red Directa: IP Dispositivo 192.168.2.108  •  Máscara 255.255.255.0  •  Puerta de Enlace (PC) 192.168.2.1',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.green.shade800,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Divider(height: 28),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _dahuaIpCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Dirección IP del Equipo Dahua',
                            prefixIcon: Icon(Icons.lan_outlined),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 1,
                        child: TextFormField(
                          controller: _dahuaPortCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Puerto HTTP',
                            prefixIcon: Icon(Icons.numbers),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _dahuaUserCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Usuario Administrador',
                            prefixIcon: Icon(Icons.person_outline),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _dahuaPassCtrl,
                          obscureText: _ocultarPass,
                          decoration: InputDecoration(
                            labelText: 'Contraseña del Equipo Dahua*',
                            prefixIcon: const Icon(Icons.lock_outline),
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _ocultarPass
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                              ),
                              onPressed: () {
                                setState(() => _ocultarPass = !_ocultarPass);
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _probandoEquipo
                            ? null
                            : _probarYSincronizarConEquipo,
                        icon: _probandoEquipo
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.sync),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 16,
                          ),
                        ),
                        label: Text(
                          _probandoEquipo
                              ? 'Sincronizando con 192.168.2.108...'
                              : 'Probar Conexión y Sincronizar Socios al Equipo',
                        ),
                      ),
                      const SizedBox(width: 14),
                      ElevatedButton.icon(
                        onPressed: _guardando ? null : _guardarConfiguracion,
                        icon: const Icon(Icons.save),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF28A745),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 16,
                          ),
                        ),
                        label: Text(
                          _guardando
                              ? 'Guardando...'
                              : 'Guardar Configuración',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}