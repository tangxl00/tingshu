import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import '../core/network/bili_client.dart';
import 'audio_handler.dart';
import 'discover_screen.dart';
import 'mine_screen.dart';
import 'playback_manager.dart';
import 'player_screen.dart';
import 'shelf_screen.dart';
import 'source_router.dart';
import 'storage.dart';
import 'widgets.dart';

Future<void> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await SystemChrome.setPreferredOrientations(DeviceOrientation.values);

  await Future.wait([
    LocalStore.instance.load(),
    BiliClient.instance.initLocal(),
  ]);

  try {
    final handler = await AudioService.init(
      builder: () => IosAudioHandler(PlaybackManager.instance),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'dev.pages.tingyou.channel.audio',
        androidNotificationChannelName: '听书',
        androidNotificationChannelDescription: '播放有声小说',
        androidNotificationIcon: 'mipmap/ic_launcher',
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: false,
        androidNotificationClickStartsActivity: true,
      ),
    ).timeout(const Duration(seconds: 6));
    PlaybackManager.instance.addListener(() {
      if (handler is IosAudioHandler) handler.sync();
    });
  } catch (e) {
    debugPrint('[bootstrap] audio service failed: $e');
  }

  unawaited(PlaybackManager.instance.restoreLastSession());
  unawaited(SourceRouter(importedBooks: () => LocalStore.instance.importedBooks)
      .warmupBili());
}

class TingYouApp extends StatelessWidget {
  const TingYouApp({super.key});

  @override
  Widget build(BuildContext context) {
    final router = SourceRouter(
      importedBooks: () => LocalStore.instance.importedBooks,
    );
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: LocalStore.instance),
        ChangeNotifierProvider.value(value: PlaybackManager.instance),
        Provider<SourceRouter>.value(value: router),
      ],
      child: Consumer<LocalStore>(
        builder: (context, store, _) {
          ThemeMode themeMode;
          switch (store.themeMode) {
            case 0:
              themeMode = ThemeMode.light;
              break;
            case 1:
              themeMode = ThemeMode.dark;
              break;
            default:
              themeMode = ThemeMode.system;
          }
          return MaterialApp(
            title: '听书',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              colorSchemeSeed: const Color(0xFF3F6ED8),
              brightness: Brightness.light,
            ),
            darkTheme: ThemeData(
              useMaterial3: true,
              colorSchemeSeed: const Color(0xFF3F6ED8),
              brightness: Brightness.dark,
            ),
            themeMode: themeMode,
            home: const HomeShell(),
          );
        },
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _tab = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      PlaybackManager.instance.flushProgress();
    }
  }

  void _openPlayer() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const PlayerScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pm = context.watch<PlaybackManager>();
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          ShelfScreen(onOpenPlayer: _openPlayer),
          const DiscoverScreen(),
          MineScreen(
            onOpenShelf: () => setState(() => _tab = 0),
          ),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pm.hasMedia) MiniPlayerBar(onTap: _openPlayer),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.menu_book_outlined),
                  selectedIcon: Icon(Icons.menu_book),
                  label: '书架'),
              NavigationDestination(
                  icon: Icon(Icons.explore_outlined),
                  selectedIcon: Icon(Icons.explore),
                  label: '发现'),
              NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: '我的'),
            ],
          ),
        ],
      ),
    );
  }
}
