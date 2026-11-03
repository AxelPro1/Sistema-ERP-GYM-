enum TipoPlan { quincenal, mensual, trimestral }

class CalcularVencimientoUseCase {
  /// Retorna la nueva fecha de vencimiento y el importe según el plan
  static Map<String, dynamic> ejecutar(
    TipoPlan plan,
    DateTime? vencimientoActual,
  ) {
    DateTime fechaBase = DateTime.now();

    // Regla 4.d: Mantener días restantes si renueva antes del vencimiento
    if (vencimientoActual != null && vencimientoActual.isAfter(fechaBase)) {
      fechaBase = vencimientoActual;
    }

    DateTime nuevaFecha;
    double importe;

    switch (plan) {
      case TipoPlan.quincenal:
        nuevaFecha = fechaBase.add(const Duration(days: 15));
        importe = 100.00; // Estos precios luego vendrán de la BD
        break;
      case TipoPlan.mensual:
        // Sumamos un mes calendario, manejando bisiestos/fin de mes
        nuevaFecha = DateTime(
          fechaBase.year,
          fechaBase.month + 1,
          fechaBase.day,
        );
        importe = 180.00;
        break;
      case TipoPlan.trimestral:
        nuevaFecha = DateTime(
          fechaBase.year,
          fechaBase.month + 3,
          fechaBase.day,
        );
        importe = 500.00;
        break;
    }

    return {'nueva_fecha': nuevaFecha, 'importe': importe};
  }
}
