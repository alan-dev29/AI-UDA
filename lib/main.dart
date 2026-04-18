import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark().copyWith(
      // Usamos el azul claro del logo como color de acento
      primaryColor: const Color(0xFF81D4FA), 
      scaffoldBackgroundColor: Colors.black,
    ),
    home: TakePictureScreen(camera: cameras.first),
  ));
}

class TakePictureScreen extends StatefulWidget {
  final CameraDescription camera;
  const TakePictureScreen({super.key, required this.camera});

  @override
  TakePictureScreenState createState() => TakePictureScreenState();
}

class TakePictureScreenState extends State<TakePictureScreen> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  final FlutterTts _flutterTts = FlutterTts();
  final stt.SpeechToText _speech = stt.SpeechToText();
  
  String _resultadoIA = "1. Toma una foto.\n2. Escucha.\n3. Responde.";
  String _estadoVoz = "Esperando acción...";
  bool _cargando = false;
  bool _estaGrabando = false;
  bool _mostrarBotonEmergencia = false;
  List<Map<String, String>> _historialChat = [];

  @override
  void initState() {
    super.initState();
    _controller = CameraController(widget.camera, ResolutionPreset.low);
    _initializeControllerFuture = _controller.initialize();
    _configurarApp();
  }

  Future<void> _configurarApp() async {
    await [Permission.microphone, Permission.camera].request();
    await _flutterTts.setLanguage("es-MX");
    await _flutterTts.setSpeechRate(0.5);
    
    _flutterTts.setCompletionHandler(() {
      // Si no es una emergencia crítica, activamos el micro automáticamente
      if (!_mostrarBotonEmergencia) {
        Future.delayed(const Duration(milliseconds: 800), () => _activarMicrofono());
      }
    });
    await _speech.initialize();
  }

  Future<void> _hacerLlamadaEmergencia() async {
    final Uri url = Uri.parse('tel:911');
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    }
  }

  void _activarMicrofono() async {
    bool disponible = await _speech.initialize();
    if (disponible && !_cargando) {
      setState(() { 
        _estaGrabando = true; 
        _estadoVoz = "Te escucho, habla ahora..."; 
      });
      _speech.listen(
        localeId: "es_MX",
        onResult: (val) {
          setState(() {
            _estadoVoz = val.recognizedWords;
          });
        },
      );
    }
  }

  // BOTÓN MANUAL: Detiene el micro y envía lo que escuchó inmediatamente
  void _detenerYEnviar() {
    if (_estaGrabando) {
      String mensajeRecibido = _estadoVoz;
      _speech.stop();
      setState(() => _estaGrabando = false);
      if (mensajeRecibido.isNotEmpty && mensajeRecibido != "Te escucho, habla ahora...") {
        _enviarVozIA(mensajeRecibido);
      }
    }
  }

  Future<void> _enviarVozIA(String texto) async {
    _historialChat.add({"role": "user", "content": texto});
    await _llamarGroq(null); 
  }

  Future<void> _llamarGroq(String? path) async {
    const String apiKey = "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";
    const String url = "https://api.groq.com/openai/v1/chat/completions";

    setState(() {
      _cargando = true;
      _estadoVoz = "Analizando riesgo vital...";
    });

    List<Map<String, dynamic>> msgs = [
      {
        "role": "system", 
        "content": "Eres un paramédico interactivo. Si la situación es 'CRÍTICO', da instrucciones de auxilio directas y NO hagas preguntas. Si es 'LEVE', da un paso de auxilio y haz una pregunta corta para seguimiento. Inicia siempre con la etiqueta correspondiente."
      }
    ];

    if (path != null) {
      final bytes = await File(path).readAsBytes();
      msgs.add({
        "role": "user",
        "content": [
          {"type": "text", "text": "Evalúa esta emergencia visualmente e inicia el triaje."},
          {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,${base64Encode(bytes)}"}}
        ]
      });
    } else {
      for (var m in _historialChat) {
        msgs.add({"role": m["role"], "content": m["content"]});
      }
    }

    try {
      final res = await http.post(Uri.parse(url),
          headers: {"Authorization": "Bearer $apiKey", "Content-Type": "application/json"},
          body: jsonEncode({"model": "meta-llama/llama-4-scout-17b-16e-instruct", "messages": msgs, "temperature": 0.2}));

      if (res.statusCode == 200) {
        String textoRaw = jsonDecode(res.body)['choices'][0]['message']['content'];
        _historialChat.add({"role": "assistant", "content": textoRaw});
        bool esCritico = textoRaw.toUpperCase().contains("CRÍTICO");
        
        setState(() {
          // Limpieza de etiquetas para mostrar al usuario
          _resultadoIA = textoRaw.replaceFirst("CRÍTICO", "⚠️ EMERGENCIA CRÍTICA ⚠️")
                                .replaceFirst("LEVE", "✅ SITUACIÓN ESTABLE");
          _mostrarBotonEmergencia = esCritico;
          _estadoVoz = esCritico ? "Prioridad: Soporte Vital" : "Procesado.";
        });
        
        // El TTS lee la respuesta limpia
        await _flutterTts.speak(_resultadoIA.replaceAll('*', '').replaceAll('⚠️', '').replaceAll('✅', ''));
      }
    } catch (e) {
      setState(() => _resultadoIA = "Error de conexión. Intenta de nuevo.");
    } finally {
      setState(() => _cargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // LOGO EN EL APPBAR
            Image.asset('assets/logo.png', height: 28), 
            const SizedBox(width: 10),
            const Text('AI-UDA', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
          ],
        ),
        backgroundColor: Colors.red[900],
        centerTitle: true,
        elevation: 8,
      ),
      body: Column(
        children: [
          Expanded(
            flex: 2,
            child: Stack(
              children: [
                FutureBuilder<void>(
                  future: _initializeControllerFuture,
                  builder: (ctx, snap) {
                    if (snap.connectionState == ConnectionState.done) {
                      return CameraPreview(_controller);
                    } else {
                      // LOGO GRANDE MIENTRAS CARGA LA CÁMARA
                      return Container(
                        color: Colors.black,
                        child: Center(
                          child: Image.asset('assets/logo.png', height: 120), 
                        ),
                      );
                    }
                  },
                ),
                // Superposición cuando está grabando audio
                if (_estaGrabando)
                  Container(
                    color: Colors.black.withOpacity(0.6),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Icono de ondas de voz en azul claro (como el logo)
                          const Icon(Icons.graphic_eq, size: 100, color: Color(0xFF81D4FA)), 
                          const SizedBox(height: 10),
                          Text(_estadoVoz, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
                // Botón de emergencia real (Solo en casos CRÍTICOS)
                if (_mostrarBotonEmergencia)
                  Positioned(
                    bottom: 20,
                    left: 20,
                    right: 20,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.all(20),
                        elevation: 10,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))
                      ),
                      onPressed: _hacerLlamadaEmergencia,
                      icon: const Icon(Icons.emergency, color: Colors.white, size: 30),
                      label: const Text("LLAMAR AL 911", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                    ),
                  ),
              ],
            ),
          ),
          // Barra de estado de voz
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: _estaGrabando ? Colors.red[900] : const Color(0xFF1A237E), // Azul oscuro para contraste
            child: Row(
              children: [
                Icon(_estaGrabando ? Icons.mic : Icons.mic_none, color: Colors.white70),
                const SizedBox(width: 10),
                Expanded(child: Text(_estadoVoz, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white))),
              ],
            ),
          ),
          // Panel de instrucciones de la IA
          Expanded(
            flex: 1,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              color: Colors.black87,
              child: SingleChildScrollView(
                child: Text(_resultadoIA, style: const TextStyle(fontSize: 17, height: 1.4)),
              ),
            ),
          ),
        ],
      ),
      // Botones de acción inferiores
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Botón de Cámara (Reinicia chat)
          FloatingActionButton.large(
            backgroundColor: Colors.redAccent,
            onPressed: _cargando ? null : () async {
              try {
                await _initializeControllerFuture;
                final img = await _controller.takePicture();
                _historialChat.clear(); // Nueva emergencia, borramos historial
                setState(() => _mostrarBotonEmergencia = false); 
                await _llamarGroq(img.path);
              } catch (e) {
                print(e);
              }
            },
            child: _cargando 
                ? const CircularProgressIndicator(color: Colors.white) 
                : const Icon(Icons.camera_alt, size: 40),
          ),
          // Botón manual para enviar respuesta de voz (Solo visible al grabar)
          if (_estaGrabando)
            FloatingActionButton.extended(
              backgroundColor: const Color(0xFF00C853), // Verde esmeralda
              onPressed: _detenerYEnviar,
              icon: const Icon(Icons.check_circle, size: 28),
              label: const Text("LISTO", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _flutterTts.stop();
    _speech.stop();
    super.dispose();
  }
}