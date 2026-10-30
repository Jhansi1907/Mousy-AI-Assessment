
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MousyApp());
}

class MousyApp extends StatelessWidget {
  const MousyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Mousy AI',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF40A9E8),
        ),
        scaffoldBackgroundColor: const Color(0xFFF2F9FF),
      ),
      home: const CompanionHomePage(),
    );
  }
}

class CompanionHomePage extends StatefulWidget {
  const CompanionHomePage({super.key});

  @override
  State<CompanionHomePage> createState() =>
      _CompanionHomePageState();
}

class _CompanionHomePageState extends State<CompanionHomePage> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _flutterTts = FlutterTts();

  // Existing local backend. Change after public deployment.
  static const String backendUrl = 'https://mousy-ai-backend.onrender.com';

  late final WebViewController _webController;

  bool _viewerReady = false;
  String _viewerMessage = 'Loading 3D mouse...';

  bool isListening = false;
  bool isLoading = false;
  bool isSpeaking = false;
  bool _requestSent = false;

  bool newsLoading = false;
  bool weatherLoading = false;

  String recognizedText = '';
  String aiReply = '';
  String statusText = 'Tap the microphone to talk';
  String weatherText = 'Loading weather...';
  String selectedCity = 'Hyderabad';

  int selectedTab = 0;

  List<Map<String, String>> newsArticles = [];

  final List<String> cities = [
    'Hyderabad',
    'Vijayawada',
    'Tirupati',
    'Bengaluru',
    'Chennai',
    'Mumbai',
    'Delhi',
  ];

  @override
  void initState() {
    super.initState();
    initializeViewer();
    initializeTts();
    refreshLocationData();
  }

  // --------------------------------------------------
  // 3D MOUSE VIEWER - EXISTING MODEL PRESERVED
  // --------------------------------------------------

  Future<void> initializeViewer() async {
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFF5F0FF))
      ..addJavaScriptChannel(
        'FlutterViewer',
        onMessageReceived: (message) {
          if (!mounted) return;

          final ready =
              message.message.startsWith('Loaded animations:');

          setState(() {
            _viewerMessage = message.message;
            _viewerReady = ready;
          });

          if (ready) {
            updateMouthAnimation();
          }
        },
      );

    try {
      final html = await rootBundle.loadString(
        'assets/models/mouse_viewer.html',
      );

      final modelData = await rootBundle.load(
        'assets/models/Cute_Mouse_Animated.glb',
      );

      final modelBytes = modelData.buffer.asUint8List(
        modelData.offsetInBytes,
        modelData.lengthInBytes,
      );

      final updatedHtml = html.replaceFirst(
        "'Cute_Mouse_Animated.glb'",
        "'data:model/gltf-binary;base64,${base64Encode(modelBytes)}'",
      );

      if (!mounted) return;

      await _webController.loadHtmlString(updatedHtml);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _viewerMessage = '3D viewer error: $e';
      });
    }
  }

  Future<void> updateMouthAnimation() async {
    if (!_viewerReady) return;

    try {
      await _webController.runJavaScript(
        'window.setSpeaking(${isSpeaking ? 'true' : 'false'});',
      );
    } catch (e) {
      debugPrint('Mouth animation error: $e');
    }
  }

  // --------------------------------------------------
  // TEXT TO SPEECH + WORD-LEVEL MOUTH ANIMATION
  // --------------------------------------------------

  Future<void> initializeTts() async {
    await _flutterTts.setLanguage('en-US');
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setPitch(1.0);
    await _flutterTts.setVolume(1.0);

    _flutterTts.setProgressHandler(
      (String text, int start, int end, String word) {
        if (!mounted || !isSpeaking || !_viewerReady) return;

        _webController.runJavaScript(
          'window.onSpokenWord(${jsonEncode(word)});',
        );
      },
    );

    _flutterTts.setStartHandler(() {
      if (!mounted) return;

      setState(() {
        isSpeaking = true;
        statusText = 'Mousy is speaking...';
      });

      updateMouthAnimation();
    });

    _flutterTts.setCompletionHandler(() {
      if (!mounted) return;

      setState(() {
        isSpeaking = false;
        statusText = 'Tap the microphone to talk';
      });

      updateMouthAnimation();
    });

    _flutterTts.setCancelHandler(() {
      if (!mounted) return;

      setState(() {
        isSpeaking = false;
      });

      updateMouthAnimation();
    });

    _flutterTts.setErrorHandler((message) {
      if (!mounted) return;

      setState(() {
        isSpeaking = false;
        statusText = 'Voice error: $message';
      });

      updateMouthAnimation();
    });
  }

  Future<void> speakResponse(String reply) async {
    if (reply.trim().isEmpty) return;

    try {
      await _flutterTts.stop();
      await _flutterTts.speak(reply);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        isSpeaking = false;
        statusText = 'Unable to speak: $e';
      });

      updateMouthAnimation();
    }
  }

  // --------------------------------------------------
  // BACKEND
  // --------------------------------------------------

  Future<Map<String, dynamic>> askBackend(
    String message,
  ) async {
    final response = await http
        .post(
          Uri.parse('$backendUrl/api/chat'),
          headers: {
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'message': message,
          }),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception(
        'Backend error: ${response.statusCode}',
      );
    }

    return jsonDecode(response.body)
        as Map<String, dynamic>;
  }

  Future<void> refreshLocationData() async {
    await Future.wait([
      loadNews(),
      loadWeather(),
    ]);
  }

  Future<void> loadNews() async {
    final city = selectedCity;

    setState(() {
      newsLoading = true;
    });

    try {
      final data = await askBackend(
        'Latest news in $city',
      );

      if (!mounted || city != selectedCity) return;

      final sources = data['sources'];
      final articles = <Map<String, String>>[];

      if (sources is List) {
        for (final source in sources) {
          if (source is Map && source['title'] != null) {
            articles.add({
              'title': source['title'].toString(),
              'url': source['url']?.toString() ?? '',
              'published':
                  source['published']?.toString() ?? '',
              'image_url':
                  source['image_url']?.toString() ?? '',
            });
          }
        }
      }

      setState(() {
        newsArticles = articles;
      });
    } catch (e) {
      debugPrint('News error: $e');

      if (mounted && city == selectedCity) {
        setState(() {
          newsArticles = [];
        });
      }
    } finally {
      if (mounted && city == selectedCity) {
        setState(() {
          newsLoading = false;
        });
      }
    }
  }

  Future<void> loadWeather() async {
    final city = selectedCity;

    setState(() {
      weatherLoading = true;
    });

    try {
      final data = await askBackend(
        'Weather in $city',
      );

      if (!mounted || city != selectedCity) return;

      setState(() {
        weatherText =
            data['reply']?.toString() ??
            'Weather unavailable.';
      });
    } catch (e) {
      if (mounted && city == selectedCity) {
        setState(() {
          weatherText =
              'Could not load weather. Please retry.';
        });
      }
    } finally {
      if (mounted && city == selectedCity) {
        setState(() {
          weatherLoading = false;
        });
      }
    }
  }

  Future<void> sendToBackend(String message) async {
    if (message.trim().isEmpty || _requestSent) return;

    _requestSent = true;

    setState(() {
      isLoading = true;
      statusText = 'Thinking...';
      aiReply = '';
    });

    try {
      final data = await askBackend(message);

      if (!mounted) return;

      final reply =
          data['reply']?.toString() ??
          'No reply received';

      setState(() {
        aiReply = reply;
        statusText = 'Response received';
      });

      await speakResponse(reply);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        statusText = 'Cannot connect to backend: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  // --------------------------------------------------
  // MICROPHONE
  // --------------------------------------------------

  Future<void> startListening() async {
    if (isLoading || isListening) return;

    try {
      await _flutterTts.stop();

      if (!mounted) return;

      setState(() {
        isSpeaking = false;
      });

      updateMouthAnimation();

      final available = await _speech.initialize(
        onStatus: (status) {
          if (!mounted) return;

          if (status == 'done' ||
              status == 'notListening') {
            setState(() {
              isListening = false;
            });

            if (recognizedText.trim().isNotEmpty &&
                !_requestSent) {
              sendToBackend(recognizedText);
            }
          }
        },
        onError: (error) {
          if (!mounted) return;

          setState(() {
            isListening = false;
            statusText =
                'Speech error: ${error.errorMsg}';
          });
        },
      );

      if (!mounted) return;

      if (!available) {
        setState(() {
          statusText =
              'Speech recognition unavailable';
        });
        return;
      }

      _requestSent = false;

      setState(() {
        isListening = true;
        recognizedText = '';
        aiReply = '';
        statusText = 'Listening...';
        selectedTab = 0;
      });

      await _speech.listen(
        onResult: (result) {
          if (!mounted) return;

          setState(() {
            recognizedText = result.recognizedWords;
          });

          if (result.finalResult && !_requestSent) {
            setState(() {
              isListening = false;
            });

            sendToBackend(result.recognizedWords);
          }
        },
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        localeId: 'en_US',
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        isListening = false;
        statusText = 'Microphone error: $e';
      });
    }
  }

  Future<void> stopListening() async {
    await _speech.stop();

    if (!mounted) return;

    setState(() {
      isListening = false;
    });

    if (recognizedText.trim().isNotEmpty &&
        !_requestSent) {
      await sendToBackend(recognizedText);
    } else if (recognizedText.trim().isEmpty) {
      setState(() {
        statusText =
            'No speech detected. Please try again.';
      });
    }
  }

  // --------------------------------------------------
  // NEW: SPORTS, HISTORY, GENERAL KNOWLEDGE
  // --------------------------------------------------

  Future<void> askTopicQuestion(String question) async {
    if (isLoading || isListening) return;

    await _flutterTts.stop();

    if (!mounted) return;

    setState(() {
      isSpeaking = false;
      recognizedText = question;
      aiReply = '';
      selectedTab = 0;
    });

    updateMouthAnimation();

    _requestSent = false;
    await sendToBackend(question);
  }

  Widget buildLearningTopics() {
    final topics = [
      {
        'title': 'Sports',
        'icon': Icons.sports_soccer,
        'color': const Color(0xFFE6F5E9),
        'questions': [
          'Explain the basic rules of cricket.',
          'What is the difference between football and cricket?',
          'Tell me five interesting facts about the Olympics.',
          'Who are some famous Indian badminton players?',
        ],
      },
      {
        'title': 'History',
        'icon': Icons.account_balance,
        'color': const Color(0xFFFFF2E2),
        'questions': [
          'Tell me about the history of India.',
          'Who was Rani Lakshmibai of Jhansi?',
          'Explain the Indian independence movement.',
          'Tell me about the history of the Taj Mahal.',
        ],
      },
      {
        'title': 'General Knowledge',
        'icon': Icons.lightbulb_outline,
        'color': const Color(0xFFECEBFF),
        'questions': [
          'Tell me five interesting science facts.',
          'What are the seven continents?',
          'How does artificial intelligence work?',
          'Who invented the telephone?',
        ],
      },
    ];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.auto_stories,
                color: Color(0xFF40A9E8),
              ),
              SizedBox(width: 8),
              Text(
                'Explore & Learn',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF17405C),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...topics.map((topic) {
            final title = topic['title'] as String;
            final icon = topic['icon'] as IconData;
            final color = topic['color'] as Color;
            final questions =
                topic['questions'] as List<String>;

            return Card(
              color: color,
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 10),
              child: ExpansionTile(
                leading: Icon(
                  icon,
                  color: const Color(0xFF168CB5),
                  size: 30,
                ),
                title: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF17405C),
                  ),
                ),
                subtitle: const Text(
                  'Tap to explore questions',
                  style: TextStyle(fontSize: 12),
                ),
                children: questions.map((question) {
                  return ListTile(
                    leading: const Icon(
                      Icons.play_circle_outline,
                      color: Color(0xFF168CB5),
                    ),
                    title: Text(
                      question,
                      style: const TextStyle(fontSize: 13),
                    ),
                    onTap: () => askTopicQuestion(question),
                  );
                }).toList(),
              ),
            );
          }),
        ],
      ),
    );
  }

  // --------------------------------------------------
  // LOCATION
  // --------------------------------------------------

  void changeCity(String city) {
    if (city == selectedCity) return;

    setState(() {
      selectedCity = city;
      newsArticles = [];
      weatherText = 'Loading weather...';
    });

    refreshLocationData();
  }

  // --------------------------------------------------
  // NEWS ARTICLES
  // --------------------------------------------------

  Future<void> openArticle(String url) async {
    final uri = Uri.tryParse(url);

    if (uri == null ||
        !['https', 'http'].contains(uri.scheme)) {
      return;
    }

    try {
      await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      debugPrint('Article open error: $e');
    }
  }

  Widget newsThumbnail(String imageUrl) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 94,
        height: 88,
        child: imageUrl.isEmpty
            ? const ColoredBox(
                color: Color(0xFFDDF3FF),
                child: Center(
                  child: Icon(
                    Icons.newspaper,
                    color: Color(0xFF40A9E8),
                    size: 35,
                  ),
                ),
              )
            : Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, error, stackTrace) {
                  return const ColoredBox(
                    color: Color(0xFFDDF3FF),
                    child: Center(
                      child: Icon(
                        Icons.newspaper,
                        color: Color(0xFF40A9E8),
                        size: 35,
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget newsCard(Map<String, String> article) {
    final title = article['title'] ?? '';
    final date = article['published'] ?? '';
    final imageUrl = article['image_url'] ?? '';
    final url = article['url'] ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7FBFF),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          newsThumbnail(imageUrl),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF17405C),
                  ),
                ),
                if (date.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    date,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.blueGrey,
                    ),
                  ),
                ],
                const SizedBox(height: 5),
                InkWell(
                  onTap: url.isEmpty
                      ? null
                      : () => openArticle(url),
                  child: const Text(
                    'Read More',
                    style: TextStyle(
                      color: Color(0xFF168CB5),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildNewsPreview() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.newspaper,
                color: Color(0xFF40A9E8),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$selectedCity - Latest News',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF17405C),
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    selectedTab = 1;
                  });
                },
                child: const Text('See all'),
              ),
            ],
          ),
          if (newsLoading)
            const Padding(
              padding: EdgeInsets.all(15),
              child: Center(
                child: CircularProgressIndicator(),
              ),
            )
          else if (newsArticles.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'No news available. Tap refresh.',
              ),
            )
          else
            ...newsArticles.take(3).map(newsCard),
        ],
      ),
    );
  }

  // --------------------------------------------------
  // HOME SCREEN
  // --------------------------------------------------

  Widget buildHome() {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              children: [
                const SizedBox(height: 8),

                // City selector
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius:
                        BorderRadius.circular(18),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.location_on,
                        color: Color(0xFF40A9E8),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: selectedCity,
                            isExpanded: true,
                            items: cities.map((city) {
                              return DropdownMenuItem(
                                value: city,
                                child: Text(city),
                              );
                            }).toList(),
                            onChanged: (city) {
                              if (city != null) {
                                changeCity(city);
                              }
                            },
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: refreshLocationData,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // Full-body mouse: unchanged.
                Container(
                  height: 300,
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                  ),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F0FF),
                    borderRadius:
                        BorderRadius.circular(24),
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: WebViewWidget(
                          controller: _webController,
                        ),
                      ),
                      if (!_viewerReady)
                        Positioned(
                          bottom: 8,
                          left: 8,
                          right: 8,
                          child: Text(
                            _viewerMessage,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 11,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 10),

                AudioWaveform(
                  active: isListening || isSpeaking,
                ),

                const SizedBox(height: 8),

                const Text(
                  'Hello! I am Mousy',
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF17405C),
                  ),
                ),

                const SizedBox(height: 6),

                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                  ),
                  child: Text(
                    statusText,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.blueGrey,
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Conversation card
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                  ),
                  padding: const EdgeInsets.all(15),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius:
                        BorderRadius.circular(18),
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'You said',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF318FC8),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          recognizedText.isEmpty
                              ? 'Your speech appears here.'
                              : recognizedText,
                        ),
                        const Divider(height: 22),
                        const Text(
                          'Mousy AI',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF318FC8),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          aiReply.isEmpty
                              ? 'Ask me anything!'
                              : aiReply,
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                buildNewsPreview(),

                const SizedBox(height: 14),

                // NEW: Sports, History, GK
                buildLearningTopics(),

                const SizedBox(height: 20),
              ],
            ),
          ),
        ),

        // Fixed microphone.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            vertical: 9,
          ),
          color: const Color(0xFFF2F9FF),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoading)
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: LinearProgressIndicator(),
                ),
              FloatingActionButton(
                heroTag: 'mousyMic',
                onPressed: isLoading
                    ? null
                    : () {
                        if (isListening) {
                          stopListening();
                        } else {
                          startListening();
                        }
                      },
                backgroundColor:
                    const Color(0xFF40A9E8),
                foregroundColor: Colors.white,
                child: Icon(
                  isListening
                      ? Icons.stop
                      : Icons.mic,
                  size: 29,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --------------------------------------------------
  // NEWS TAB
  // --------------------------------------------------

  Widget buildNewsTab() {
    return RefreshIndicator(
      onRefresh: loadNews,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '$selectedCity - Latest News',
            style: const TextStyle(
              fontSize: 23,
              fontWeight: FontWeight.bold,
              color: Color(0xFF17405C),
            ),
          ),
          const SizedBox(height: 12),
          if (newsLoading)
            const Center(
              child: CircularProgressIndicator(),
            ),
          if (!newsLoading && newsArticles.isEmpty)
            const Padding(
              padding: EdgeInsets.all(18),
              child: Text(
                'No headlines available. Tap refresh.',
              ),
            ),
          ...newsArticles.map(newsCard),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: newsLoading ? null : loadNews,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh News'),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------
  // WEATHER TAB
  // --------------------------------------------------

  Widget buildWeatherTab() {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const SizedBox(height: 25),
        const Icon(
          Icons.cloud,
          size: 80,
          color: Color(0xFF40A9E8),
        ),
        const SizedBox(height: 15),
        Text(
          '$selectedCity Weather',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 18),
        Card(
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: weatherLoading
                ? const Center(
                    child: CircularProgressIndicator(),
                  )
                : Text(
                    weatherText,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 18,
                      height: 1.5,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 15),
        FilledButton.icon(
          onPressed: weatherLoading
              ? null
              : loadWeather,
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh Weather'),
        ),
      ],
    );
  }

  // --------------------------------------------------
  // SETTINGS TAB
  // --------------------------------------------------

  Widget buildSettingsTab() {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text(
          'Settings',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 18),
        Card(
          color: Colors.white,
          child: ListTile(
            leading: const Icon(Icons.location_city),
            title: const Text('Selected city'),
            subtitle: Text(selectedCity),
          ),
        ),
        const Card(
          color: Colors.white,
          child: ListTile(
            leading: Icon(Icons.record_voice_over),
            title: Text('Voice language'),
            subtitle: Text('English (US)'),
          ),
        ),
        const Card(
          color: Colors.white,
          child: ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('About'),
            subtitle: Text(
              'Mousy AI - 3D Talking Companion',
            ),
          ),
        ),
      ],
    );
  }

  // --------------------------------------------------
  // MAIN APP LAYOUT
  // --------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F9FF),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF2F9FF),
        title: const Row(
          children: [
            CircleAvatar(
              backgroundColor: Color(0xFFDDF3FF),
              child: Icon(
                Icons.pets,
                color: Color(0xFF318FC8),
              ),
            ),
            SizedBox(width: 10),
            Text(
              'Mousy AI',
              style: TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: refreshLocationData,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: IndexedStack(
          index: selectedTab,
          children: [
            buildHome(),
            buildNewsTab(),
            buildWeatherTab(),
            buildSettingsTab(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedTab,
        backgroundColor: Colors.white,
        onDestinationSelected: (index) {
          setState(() {
            selectedTab = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.newspaper_outlined),
            selectedIcon: Icon(Icons.newspaper),
            label: 'News',
          ),
          NavigationDestination(
            icon: Icon(Icons.cloud_outlined),
            selectedIcon: Icon(Icons.cloud),
            label: 'Weather',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _speech.cancel();
    _flutterTts.stop();
    super.dispose();
  }
}

// --------------------------------------------------
// ANIMATED AUDIO WAVEFORM
// --------------------------------------------------

class AudioWaveform extends StatefulWidget {
  final bool active;

  const AudioWaveform({
    super.key,
    required this.active,
  });

  @override
  State<AudioWaveform> createState() =>
      _AudioWaveformState();
}

class _AudioWaveformState extends State<AudioWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );

    if (widget.active) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(
    covariant AudioWaveform oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);

    if (widget.active &&
        !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.active &&
        _controller.isAnimating) {
      _controller.stop();
      _controller.reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return SizedBox(
          height: 35,
          child: Row(
            mainAxisAlignment:
                MainAxisAlignment.center,
            children: List.generate(15, (index) {
              final wave = math.sin(
                _controller.value * math.pi * 2 +
                    index * 0.55,
              );

              final height = widget.active
                  ? 7.0 + 25.0 * ((wave + 1) / 2)
                  : 5.0;

              return Container(
                width: 4,
                height: height,
                margin: const EdgeInsets.symmetric(
                  horizontal: 2,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF40A9E8),
                  borderRadius:
                      BorderRadius.circular(8),
                ),
              );
            }),
          ),
        );
      },
    );
  }
}
