import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

import '../../infrastructure/database/mysql_repository.dart';

import 'package:intl/intl.dart';

class DashboardPrincipalWidget extends StatefulWidget {
  @override
  _DashboardPrincipalWidgetState createState() =>
      _DashboardPrincipalWidgetState();
}

class _DashboardPrincipalWidgetState extends State<DashboardPrincipalWidget> {
  late Future<Map<String, dynamic>> _metricasFuture;

  @override
  void initState() {
    super.initState();
    _cargarMetricas();
  }

  void _cargarMetricas() {
    setState(() {
      _metricasFuture = SocioRepository().obtenerMetricasDashboard();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _metricasFuture,
      builder: (context, snapshot) {
        // Estado de carga
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFF28A745)),
          );
        }

        // Error o base de datos apagada
        if (snapshot.hasError || !snapshot.hasData || snapshot.data!.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 60, color: Colors.red),
                const SizedBox(height: 10),
                const Text('Error al conectar con la base de datos.'),
                ElevatedButton(
                  onPressed: _cargarMetricas,
                  child: const Text('Reintentar'),
                ),
              ],
            ),
          );
        }

        final metricas = snapshot.data!;

        // Extracción de datos
        final int sociosActivos = metricas['socios_activos'] ?? 0;
        final int accesosHoy = metricas['accesos_hoy'] ?? 0;
        final int vencidos = metricas['vencidos'] ?? 0;
        final int vigentes = metricas['vigentes'] ?? 0;
        final int bajas = metricas['bajas'] ?? 0;
        final double ingresosHoy = metricas['ingresos_hoy'] ?? 0.0;
        final List<int> asistenciaSemanal =
            metricas['asistencia_semanal'] ?? List.filled(7, 0);

        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Visión General (Tiempo Real)',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: _cargarMetricas,
                    tooltip: 'Actualizar Datos',
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // --- FILA 1: KPIs ---
              Row(
                children: [
                  _buildKpiCard(
                    titulo: 'Socios Activos',
                    valor: sociosActivos.toString(),
                    icono: Icons.people,
                    color: Colors.blue,
                  ),
                  const SizedBox(width: 15),
                  _buildKpiCard(
                    titulo: 'Accesos Hoy',
                    valor: accesosHoy.toString(),
                    icono: Icons.fingerprint,
                    color: Colors.green,
                  ),
                  const SizedBox(width: 15),
                  _buildKpiCard(
                    titulo: 'Mensualidades Vencidas',
                    valor: vencidos.toString(),
                    icono: Icons.warning_amber_rounded,
                    color: Colors.red,
                  ),
                  const SizedBox(width: 15),
                  _buildKpiCard(
                    titulo: 'Ingresos del Día',
                    valor: 'Bs ${ingresosHoy.toStringAsFixed(2)}',
                    icono: Icons.attach_money,
                    color: Colors.orange,
                  ),
                ],
              ),

              const SizedBox(height: 30),

              // --- FILA 2: GRÁFICOS ---
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Gráfico de Barras: Asistencia Semanal
                  Expanded(
                    flex: 2,
                    child: Container(
                      height: 350,
                      padding: const EdgeInsets.all(20),
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
                          const Text(
                            'Asistencia de los últimos 7 días',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 30),
                          Expanded(
                            child: BarChart(
                              BarChartData(
                                alignment: BarChartAlignment.spaceAround,
                                maxY:
                                    (asistenciaSemanal.reduce(
                                              (a, b) => a > b ? a : b,
                                            ) +
                                            10)
                                        .toDouble(), // Se ajusta al día con más asistencia
                                barTouchData: BarTouchData(enabled: true),
                                titlesData: FlTitlesData(
                                  show: true,
                                  bottomTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      getTitlesWidget: (value, meta) {
                                        // Calcular nombres de los días hacia atrás
                                        DateTime dia = DateTime.now().subtract(
                                          Duration(days: 6 - value.toInt()),
                                        );
                                        String nombreDia = DateFormat(
                                          'E',
                                          'es_ES',
                                        ).format(dia); // Ej: Lun, Mar
                                        return Text(
                                          nombreDia,
                                          style: const TextStyle(
                                            color: Colors.grey,
                                            fontSize: 12,
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  leftTitles: AxisTitles(
                                    sideTitles: SideTitles(showTitles: false),
                                  ),
                                  topTitles: AxisTitles(
                                    sideTitles: SideTitles(showTitles: false),
                                  ),
                                  rightTitles: AxisTitles(
                                    sideTitles: SideTitles(showTitles: false),
                                  ),
                                ),
                                gridData: FlGridData(show: false),
                                borderData: FlBorderData(show: false),
                                barGroups: [
                                  for (int i = 0; i < 7; i++)
                                    _makeBarData(
                                      i,
                                      asistenciaSemanal[i].toDouble(),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(width: 20),

                  // Gráfico Circular: Estado de Mensualidades
                  Expanded(
                    flex: 1,
                    child: Container(
                      height: 350,
                      padding: const EdgeInsets.all(20),
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
                          const Text(
                            'Estado de Mensualidades',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Expanded(
                            child:
                                (vigentes == 0 && vencidos == 0 && bajas == 0)
                                ? const Center(
                                    child: Text(
                                      "No hay datos",
                                      style: TextStyle(color: Colors.grey),
                                    ),
                                  )
                                : PieChart(
                                    PieChartData(
                                      sectionsSpace: 2,
                                      centerSpaceRadius: 40,
                                      sections: [
                                        if (vigentes > 0)
                                          PieChartSectionData(
                                            color: Colors.green,
                                            value: vigentes.toDouble(),
                                            title: '$vigentes',
                                            radius: 50,
                                            titleStyle: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        if (vencidos > 0)
                                          PieChartSectionData(
                                            color: Colors.red,
                                            value: vencidos.toDouble(),
                                            title: '$vencidos',
                                            radius: 50,
                                            titleStyle: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        if (bajas > 0)
                                          PieChartSectionData(
                                            color: Colors.grey,
                                            value: bajas.toDouble(),
                                            title: '$bajas',
                                            radius: 50,
                                            titleStyle: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                          ),
                          // Leyenda
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _buildLeyenda(Colors.green, 'Vigentes'),
                              _buildLeyenda(Colors.red, 'Vencidos'),
                              _buildLeyenda(Colors.grey, 'Bajas'),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLeyenda(Color color, String texto) {
    return Row(
      children: [
        Container(width: 10, height: 10, color: color),
        const SizedBox(width: 5),
        Text(texto, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  Widget _buildKpiCard({
    required String titulo,
    required String valor,
    required IconData icono,
    required Color color,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border(left: BorderSide(color: color, width: 4)),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 5),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titulo,
                  style: const TextStyle(
                    color: Colors.grey,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  valor,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            CircleAvatar(
              backgroundColor: color.withOpacity(0.1),
              radius: 20,
              child: Icon(icono, color: color, size: 24),
            ),
          ],
        ),
      ),
    );
  }

  BarChartGroupData _makeBarData(int x, double y) {
    return BarChartGroupData(
      x: x,
      barRods: [
        BarChartRodData(
          toY: y,
          color: const Color(0xFF28A745),
          width: 22,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(6),
            topRight: Radius.circular(6),
          ),
        ),
      ],
    );
  }
}
