import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../services/auth_service.dart';
import '../services/firebase_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, DateTime> _deviceNames = {};
  final FirebaseService _firebaseService = FirebaseService();
  final AuthService _authService = AuthService();
  Map<String, dynamic> _todayStats = {};
  bool _isLoading = false;
  String _userName = '';

  // 追加: 今日カウント済みのデバイス名
  Set<String> _countedToday = {};

  @override
  void initState() {
    super.initState();
    _loadUserData();
    startScan();
    loadTodayStats();
  }

  Future<void> _loadUserData() async {
    try {
      final userName = await _authService.getUserName();
      setState(() {
        _userName = userName;
      });
    } catch (e) {
      print('ユーザー名の読み込みエラー: $e');
    }
  }

  void startScan() {
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 3));

    FlutterBluePlus.scanResults.listen((results) {
      final now = DateTime.now();
      for (ScanResult r in results) {
        final name = r.advertisementData.advName;
        if (name != null && name.isNotEmpty) {
          _deviceNames[name] = now;

          // ここで一度だけカウント
          if (!_countedToday.contains(name)) {
            _firebaseService.incrementBeaconCount(name);
            _countedToday.add(name);
          }
        }
      }
      _deviceNames.removeWhere((key, time) => now.difference(time).inSeconds > 5);
      setState(() {});
    });

    Future.delayed(const Duration(seconds: 3), () {
      FlutterBluePlus.stopScan();
      startScan();
    });
  }

  Future<void> loadTodayStats() async {
    setState(() {
      _isLoading = true;
    });
    
    try {
      final stats = await _firebaseService.getTodayStats();
      setState(() {
        _todayStats = stats;
        _isLoading = false;
      });
    } catch (e) {
      print('統計データの読み込み中にエラーが発生しました: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _logout() {
    _authService.logout();
    Navigator.of(context).pushReplacementNamed('/login');
  }

  String _getRoleText() {
    switch (_authService.currentUserRole) {
      case UserRole.exhibitor:
        return '出展者';
      case UserRole.organizer:
        return '主催者';
      case UserRole.staff:
        return 'スタッフ';
      case UserRole.visitor:
        return '来場者';
      default:
        return 'ゲスト';
    }
  }

  Color _getRoleColor() {
    switch (_authService.currentUserRole) {
      case UserRole.exhibitor:
        return Colors.blue;
      case UserRole.organizer:
        return Colors.purple;
      case UserRole.staff:
        return Colors.orange;
      case UserRole.visitor:
        return Colors.green;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('BLEビーコン受信アプリ'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: loadTodayStats,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // ユーザー情報
            if (_authService.isLoggedIn)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      Icon(
                        Icons.person,
                        size: 40,
                        color: _getRoleColor(),
                      ),
                      const SizedBox(width: 16),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _userName,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            _getRoleText(),
                            style: TextStyle(
                              fontSize: 16,
                              color: _getRoleColor(),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            
            const SizedBox(height: 24),
            
            const Text(
              "現在受信中のビーコン:",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ..._deviceNames.keys.map((name) => 
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.bluetooth, color: Colors.blue, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      name, 
                      style: const TextStyle(fontSize: 16),
                    ),
                  ],
                ),
              )
            ),
            if (_deviceNames.isEmpty)
              const Text(
                "受信中のビーコンはありません",
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
            
            const SizedBox(height: 24),
            const Text(
              "今日の受信統計:",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (_isLoading)
              const Center(child: CircularProgressIndicator())
            else if (_todayStats.isEmpty)
              const Text(
                "今日の統計データはありません",
                style: TextStyle(fontSize: 16, color: Colors.grey),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: _todayStats.length,
                  itemBuilder: (context, index) {
                    final deviceName = _todayStats.keys.elementAt(index);
                    final data = _todayStats[deviceName] as Map<String, dynamic>;
                    final count = data['count'] ?? 0;
                    
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.bluetooth, color: Colors.blue),
                        title: Text(deviceName),
                        subtitle: Text('受信回数: $count回'),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: _getRoleColor(),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            count.toString(),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
} 