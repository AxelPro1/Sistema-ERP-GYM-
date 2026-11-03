import 'package:flutter/material.dart';
import '../../infrastructure/database/mysql_repository.dart';

class PersonalWidget extends StatefulWidget {
  const PersonalWidget({Key? key}) : super(key: key);

  @override
  _PersonalWidgetState createState() => _PersonalWidgetState();
}

class _PersonalWidgetState extends State<PersonalWidget> {
  final SocioRepository _repository = SocioRepository();
  late Future<List<Map<String, dynamic>>> _personalFuture;

  final List<String> _rolesDisponibles = [
    'PERSONAL',
    'RECEPCIONISTA',
    'CAJERO',
    'ENTRENADOR',
    'ADMINISTRADOR',
  ];

  @override
  void initState() {
    super.initState();
    _cargarPersonal();
  }

  void _cargarPersonal() {
    setState(() {
      _personalFuture = _repository.obtenerListaPersonal();
    });
  }

  Future<void> _abrirModalPersonal({Map<String, dynamic>? miembro}) async {
    final bool esEdicion = miembro != null;
    final formKey = GlobalKey<FormState>();

    final TextEditingController nombreCtrl = TextEditingController(
      text: esEdicion ? (miembro['nombre'] ?? '').toString() : '',
    );
    final TextEditingController usuarioCtrl = TextEditingController(
      text: esEdicion ? (miembro['usuario'] ?? '').toString() : '',
    );
    final TextEditingController passwordCtrl = TextEditingController(
      text: esEdicion ? (miembro['password'] ?? '').toString() : '',
    );

    String rolInicial = esEdicion
        ? (miembro['rol'] ?? 'PERSONAL').toString().toUpperCase()
        : 'PERSONAL';
    if (!_rolesDisponibles.contains(rolInicial)) {
      rolInicial = 'PERSONAL';
    }

    bool activo = esEdicion ? (miembro['activo'] == true) : true;
    bool ocultarPassword = true;
    bool guardando = false;

    final List<String> modulosSeleccionados = [];
    if (rolInicial == 'ADMINISTRADOR') {
      modulosSeleccionados.addAll(SocioRepository.todosLosModulosSistema);
    } else if (esEdicion && miembro['modulos'] is List) {
      for (final m in (miembro['modulos'] as List)) {
        final canonico = SocioRepository.normalizarNombreModulo(m.toString());
        if (canonico != null && !modulosSeleccionados.contains(canonico)) {
          modulosSeleccionados.add(canonico);
        }
      }
    } else {
      modulosSeleccionados.addAll([
        'Dashboard',
        'Socios & Membresías',
        'Control de Asistencias',
      ]);
    }

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            Future<void> guardar() async {
              if (!formKey.currentState!.validate()) return;

              if (modulosSeleccionados.isEmpty) {
                ScaffoldMessenger.of(this.context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Debe asignar al menos 1 módulo del sistema al usuario.',
                    ),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }

              setModalState(() => guardando = true);

              final List<String> modulosOrdenados =
                  rolInicial == 'ADMINISTRADOR'
                      ? List<String>.from(
                          SocioRepository.todosLosModulosSistema,
                        )
                      : SocioRepository.todosLosModulosSistema
                            .where((m) => modulosSeleccionados.contains(m))
                            .toList();

              final bool ok = await _repository.guardarMiembroPersonal(
                id: esEdicion ? miembro['id'].toString() : null,
                nombre: nombreCtrl.text.trim(),
                usuario: usuarioCtrl.text.trim(),
                password: passwordCtrl.text.trim(),
                rol: rolInicial,
                modulosPermitidos: modulosOrdenados,
                activo: activo,
              );

              if (!mounted) return;

              if (ok) {
                Navigator.of(ctx).pop();
                _cargarPersonal();
                ScaffoldMessenger.of(this.context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Módulos de ${nombreCtrl.text.trim()} ($rolInicial): ${modulosOrdenados.join(", ")}',
                    ),
                    backgroundColor: Colors.green,
                  ),
                );
              } else {
                setModalState(() => guardando = false);
                ScaffoldMessenger.of(this.context).showSnackBar(
                  SnackBar(
                    content: Text(
                      _repository.ultimoError ??
                          'Error al guardar los módulos del personal.',
                    ),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            }

            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.badge, color: Color(0xFF28A745)),
                  const SizedBox(width: 10),
                  Text(
                    esEdicion
                        ? 'Editar Personal y Módulos Asignados'
                        : 'Nuevo Miembro del Personal',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              content: SizedBox(
                width: 640,
                child: SingleChildScrollView(
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: nombreCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Nombre Completo*',
                                  prefixIcon: Icon(Icons.person),
                                  border: OutlineInputBorder(),
                                ),
                                validator: (v) => v == null || v.trim().isEmpty
                                    ? 'Requerido'
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: TextFormField(
                                controller: usuarioCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Usuario de Acceso (Login)*',
                                  prefixIcon: Icon(Icons.account_circle),
                                  border: OutlineInputBorder(),
                                ),
                                validator: (v) => v == null || v.trim().isEmpty
                                    ? 'Requerido'
                                    : null,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: passwordCtrl,
                                obscureText: ocultarPassword,
                                decoration: InputDecoration(
                                  labelText: 'Contraseña*',
                                  prefixIcon: const Icon(Icons.lock),
                                  border: const OutlineInputBorder(),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      ocultarPassword
                                          ? Icons.visibility_off
                                          : Icons.visibility,
                                    ),
                                    onPressed: () {
                                      setModalState(
                                        () =>
                                            ocultarPassword = !ocultarPassword,
                                      );
                                    },
                                  ),
                                ),
                                validator: (v) => v == null || v.trim().isEmpty
                                    ? 'Requerido'
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                value: rolInicial,
                                decoration: const InputDecoration(
                                  labelText: 'Cargo / Rol',
                                  prefixIcon: Icon(Icons.security),
                                  border: OutlineInputBorder(),
                                ),
                                items: _rolesDisponibles.map((r) {
                                  return DropdownMenuItem<String>(
                                    value: r,
                                    child: Text(r),
                                  );
                                }).toList(),
                                onChanged: (nuevoRol) {
                                  if (nuevoRol != null) {
                                    setModalState(() {
                                      rolInicial = nuevoRol;
                                      if (rolInicial == 'ADMINISTRADOR') {
                                        modulosSeleccionados
                                          ..clear()
                                          ..addAll(
                                            SocioRepository
                                                .todosLosModulosSistema,
                                          );
                                      }
                                    });
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          activeColor: const Color(0xFF28A745),
                          title: const Text(
                            'Cuenta Activa (Permitir inicio de sesión)',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          value: activo,
                          onChanged: (val) {
                            setModalState(() => activo = val);
                          },
                        ),
                        const Divider(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Módulos Asignados para su Uso:',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                ),
                                Text(
                                  rolInicial == 'ADMINISTRADOR'
                                      ? 'ADMINISTRADOR tiene acceso total a los 7 módulos (al desmarcar uno cambiará a PERSONAL)'
                                      : 'Seleccionados: ${modulosSeleccionados.length} de ${SocioRepository.todosLosModulosSistema.length} módulos',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: Colors.green.shade800,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                TextButton.icon(
                                  onPressed: () {
                                    setModalState(() {
                                      modulosSeleccionados
                                        ..clear()
                                        ..addAll(
                                          SocioRepository
                                              .todosLosModulosSistema,
                                        );
                                    });
                                  },
                                  icon: const Icon(Icons.done_all, size: 16),
                                  label: const Text('Todos'),
                                ),
                                TextButton.icon(
                                  onPressed: () {
                                    setModalState(() {
                                      if (rolInicial == 'ADMINISTRADOR') {
                                        rolInicial = 'PERSONAL';
                                      }
                                      modulosSeleccionados.clear();
                                    });
                                  },
                                  icon: const Icon(
                                    Icons.clear_all,
                                    size: 16,
                                    color: Colors.red,
                                  ),
                                  label: const Text(
                                    'Limpiar',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.grey.shade300),
                          ),
                          child: Column(
                            children: SocioRepository.todosLosModulosSistema
                                .map((modulo) {
                                  final bool estaMarcado = modulosSeleccionados
                                      .contains(modulo);
                                  return CheckboxListTile(
                                    dense: true,
                                    activeColor: const Color(0xFF28A745),
                                    title: Text(
                                      modulo,
                                      style: TextStyle(
                                        fontWeight: estaMarcado
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        color: estaMarcado
                                            ? Colors.black87
                                            : Colors.grey.shade700,
                                      ),
                                    ),
                                    value: estaMarcado,
                                    onChanged: (bool? checked) {
                                      setModalState(() {
                                        if (checked == true) {
                                          if (!modulosSeleccionados.contains(
                                            modulo,
                                          )) {
                                            modulosSeleccionados.add(modulo);
                                          }
                                        } else {
                                          // Si desmarca algún módulo estando como ADMINISTRADOR,
                                          // cambia automáticamente a PERSONAL para aplicar la restricción
                                          if (rolInicial == 'ADMINISTRADOR') {
                                            rolInicial = 'PERSONAL';
                                          }
                                          modulosSeleccionados.remove(modulo);
                                        }
                                      });
                                    },
                                  );
                                })
                                .toList(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: guardando ? null : () => Navigator.of(ctx).pop(),
                  child: const Text(
                    'Cancelar',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: guardando ? null : guardar,
                  icon: guardando
                      ? const SizedBox.shrink()
                      : const Icon(Icons.save, size: 18),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF28A745),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 14,
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
                      : const Text('Guardar Asignación de Módulos'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _confirmarEliminar(Map<String, dynamic> miembro) async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar Personal'),
        content: Text(
          '¿Está seguro de eliminar a ${miembro['nombre']} (Usuario: ${miembro['usuario']})?',
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
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmar == true) {
      final ok = await _repository.eliminarMiembroPersonal(
        miembro['id'].toString(),
      );
      if (ok && mounted) {
        _cargarPersonal();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Miembro del personal eliminado correctamente.'),
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
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10),
        ],
      ),
      child: Column(
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
                      'Gestión de Personal y Permisos por Módulo',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Los Administradores tienen acceso total; el Personal accede solo a los módulos asignados.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
                ElevatedButton.icon(
                  onPressed: () => _abrirModalPersonal(),
                  icon: const Icon(Icons.person_add, size: 18),
                  label: const Text('+ Nuevo Personal'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF28A745),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                  ),
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
                  flex: 2,
                  child: Text(
                    'NOMBRE / USUARIO',
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
                    'ROL / CARGO',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.black54,
                    ),
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Text(
                    'MÓDULOS ASIGNADOS PARA SU USO',
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
                  flex: 1,
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
              future: _personalFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFF28A745)),
                  );
                }

                final lista = snapshot.data ?? [];
                if (lista.isEmpty) {
                  return const Center(
                    child: Text('No hay personal registrado.'),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  itemCount: lista.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = lista[index];
                    final bool activo = item['activo'] == true;
                    final List<String> modulos =
                        (item['modulos'] as List?)
                            ?.map((e) => e.toString())
                            .toList() ??
                        [];

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item['nombre'].toString(),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                Text(
                                  'Usuario: ${item['usuario']}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            flex: 1,
                            child: Text(
                              item['rol'].toString(),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 4,
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: modulos.map((mod) {
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.green.shade50,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: Colors.green.shade300,
                                    ),
                                  ),
                                  child: Text(
                                    mod,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.green.shade900,
                                    ),
                                  ),
                                );
                              }).toList(),
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
                                color: activo
                                    ? Colors.green.shade50
                                    : Colors.red.shade50,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: activo ? Colors.green : Colors.red,
                                ),
                              ),
                              child: Text(
                                activo ? 'Activo' : 'Inactivo',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: activo ? Colors.green : Colors.red,
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 1,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                IconButton(
                                  tooltip: 'Editar Módulos Asignados',
                                  onPressed: () =>
                                      _abrirModalPersonal(miembro: item),
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    color: Colors.blue,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Eliminar',
                                  onPressed: () => _confirmarEliminar(item),
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