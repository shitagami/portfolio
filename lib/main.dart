/// BLEビーコンを使用した会場混雑状況監視アプリ
/// 
/// 主な機能:
/// - BLEビーコンの検出と来場者数のカウント
/// - リアルタイム混雑状況の表示
/// - ユーザー属性情報の収集（年齢、性別、職業など）
/// - 複数ユーザーロール（来場者、スタッフ、主催者、出展者）
/// - 混雑警報とプッシュ通知機能

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/staff_screen.dart';
import 'screens/organizer_screen.dart';
import 'screens/exhibitor_screen.dart';
import 'screens/visitor_form_screen.dart';
import 'screens/crowd_heatmap_screen.dart';
import 'screens/visitor_management_screen.dart';
import 'screens/web_dashboard_screen.dart';
import 'services/notification_service.dart';
import 'package:flutter/foundation.dart';

/// アプリケーションのエントリーポイント
/// Firebaseと通知サービスの初期化を行う
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AppStarter());
}

/// アプリ起動時の初期化処理を行うウィジェット
/// Firebaseと通知サービスの初期化を管理
class AppStarter extends StatefulWidget {
  const AppStarter({super.key});

  @override
  State<AppStarter> createState() => _AppStarterState();
}

class _AppStarterState extends State<AppStarter> {
  /// アプリの初期化が完了したかどうか
  bool _initialized = false;
  
  /// Firebaseの初期化が成功したかどうか
  bool _firebaseInitialized = false;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  /// アプリの初期化処理
  /// Firebaseと通知サービスを順次初期化する
  Future<void> _initializeApp() async {
    bool firebaseInitResult = false;
    try {
      // Firebaseの初期化
      final options = DefaultFirebaseOptions.currentPlatform;
      
      // Web用の設定が正しく設定されているか確認
      if (kIsWeb) {
        final webOptions = options as FirebaseOptions;
        if (webOptions.appId.contains('YOUR-WEB-APP-ID') || 
            webOptions.apiKey.contains('YOUR-WEB-API-KEY')) {
          print('警告: Web用のFirebase設定が正しく設定されていません。');
          print('FirebaseコンソールでWebアプリを追加し、flutterfire configure --platforms=web を実行してください。');
          // 設定が不完全な場合は初期化をスキップ
          firebaseInitResult = false;
        } else {
          await Firebase.initializeApp(options: options);
          firebaseInitResult = true;
          print('Firebase初期化成功 (Web)');
        }
      } else {
        await Firebase.initializeApp(options: options);
        firebaseInitResult = true;
        print('Firebase初期化成功');
      }
    } catch (e, stackTrace) {
      print('Firebase初期化エラー: $e');
      print('スタックトレース: $stackTrace');
      // Firebase初期化に失敗してもアプリは起動する
      firebaseInitResult = false;
      if (kIsWeb) {
        print('注意: Web用のFirebase設定が正しく設定されていない可能性があります。');
        print('FirebaseコンソールでWebアプリを追加し、flutterfire configure --platforms=web を実行してください。');
      }
    }
    
    try {
      // 通知サービスを初期化（Webではスキップ）
      // ローカル通知とFCM（Firebase Cloud Messaging）を設定
      if (!kIsWeb) {
        await NotificationService().initialize();
        print('通知サービス初期化成功');
      }
    } catch (e) {
      print('通知サービス初期化エラー: $e');
      // 通知サービス初期化に失敗してもアプリは起動する
    }

    if (mounted) {
      setState(() {
        _firebaseInitialized = firebaseInitResult;
        _initialized = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                const Text('アプリを起動中...', style: TextStyle(fontSize: 16)),
                const SizedBox(height: 8),
                // 長時間ロードが終わらない場合のメッセージ
                TextButton(
                  onPressed: () {
                    setState(() {
                      _initialized = true;
                      _firebaseInitialized = false;
                    });
                  },
                  child: const Text('ロードが終わらない場合はこちらをタップ'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    
    return MyApp(firebaseInitialized: _firebaseInitialized);
  }
}

void setup() async {
  // Bluetoothが有効でパーミッションが許可されるまで待機
  // await FlutterBluePlus.adapterState
  //     .where((val) => val == BluetoothAdapterState.on)
  //     .first;
}

class MyApp extends StatelessWidget {
  final bool firebaseInitialized;
  
  const MyApp({super.key, this.firebaseInitialized = false});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Beacon App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      // デバッグ用：主催者画面を直接表示
      home: const OrganizerScreen(),
      routes: {
        '/login': (context) => const LoginScreen(),
        '/home': (context) => const HomeScreen(),
        '/setup': (context) => const SetupScreen(),
        '/staff': (context) => const StaffScreen(),
        '/organizer': (context) => const OrganizerScreen(),
        '/exhibitor': (context) => const ExhibitorScreen(),
        '/visitor_form': (context) => const VisitorFormScreen(),
        '/crowd_heatmap': (context) => const CrowdHeatmapScreen(),
        '/visitor_management': (context) => const VisitorManagementScreen(),
        '/web_dashboard': (context) => const WebDashboardScreen(),
      },
    );
  }
}

/// Firebase初期化エラー時の画面
class _FirebaseErrorScreen extends StatelessWidget {
  const _FirebaseErrorScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Firebase設定エラー'),
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                size: 80,
                color: Colors.red,
              ),
              const SizedBox(height: 24),
              const Text(
                'Firebaseの初期化に失敗しました',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Web用のFirebase設定が正しく設定されていません。',
                style: TextStyle(fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              const Text(
                '以下のコマンドを実行して、Firebase設定を更新してください：',
                style: TextStyle(fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const SelectableText(
                  'flutterfire configure --platforms=web',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () {
                  // とりあえずログイン画面に進む（Firebaseなしで動作する可能性がある）
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (context) => const LoginScreen()),
                  );
                },
                child: const Text('とりあえず続行（Firebase機能は使用できません）'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


