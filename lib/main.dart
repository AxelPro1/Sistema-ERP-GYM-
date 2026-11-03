import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart'; // <-- 1. Agrega esta importación

import 'presentation/screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // <-- 2. Agrega esta línea para inicializar el idioma español
  await initializeDateFormatting('es_ES', null);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gym ERP Biométrico',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF28A745),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: LoginScreen(),
    );
  }
}
