import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'dart:async';
import '../services/auth_service.dart';
import '../services/firebase_service.dart';
import '../services/notification_service.dart';

class StaffScreen extends StatefulWidget {
  const StaffScreen({super.key});

  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends State<StaffScreen> {
  final AuthService _authService = AuthService();
  final FirebaseService _firebaseService = FirebaseService();
  final NotificationService _notificationService = NotificationService();
  
  Map<String, dynamic> _todayStats = {};
  bool _isLoading = false;
  String _userName = '';
  
  // ヒートマップ用の状態変数
  List<BeaconLocation> _beaconLocations = [];
  bool _showHeatmap = true;
  int _crowdingThreshold = 25;
  
  // マップレイアウト情報（Firebaseから動的に取得）
  Map<String, dynamic>? _eventLayout;
  List<Map<String, dynamic>> _mapElements = [];
  
  // 混雑監視用の状態変数
  Map<String, bool> _crowdingAlerts = {};
  Timer? _monitoringTimer;

  @override
  void initState() {
    super.initState();
    _loadData();
    _initializeNotifications();
    _startCrowdingMonitoring();
  }

  @override
  void dispose() {
    _monitoringTimer?.cancel();
    super.dispose();
  }

  Future<void> _initializeNotifications() async {
    try {
      await _notificationService.initialize();
      print('通知サービスが初期化されました');
    } catch (e) {
      print('通知サービスの初期化に失敗: $e');
    }
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final userName = await _authService.getUserName();
      final stats = await _firebaseService.getTodayStats();
      final booths = await _firebaseService.getAllBooths();
      
      // マップレイアウトを読み込み
      await _loadMapLayout();
      
      // ブース情報を設定
      _beaconLocations = _convertBoothsToLocations(booths);
      
      setState(() {
        _userName = userName;
        _todayStats = stats;
        _isLoading = false;
      });
      
      // 混雑度チェックを実行
      _checkCrowdingLevels();
    } catch (e) {
      print('データ読み込みエラー: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Firebaseからマップレイアウト情報を読み込む
  Future<void> _loadMapLayout() async {
    try {
      print('=== マップレイアウトの読み込み開始 ===');
      
      // アクティブな展示会レイアウトを取得
      final eventLayout = await _firebaseService.getActiveEventLayout();
      
      if (eventLayout == null) {
        print('アクティブな展示会レイアウトがありません（デフォルトレイアウトを使用）');
        setState(() {
          _eventLayout = null;
          _mapElements = [];
        });
        return;
      }
      
      print('展示会レイアウトを取得: ${eventLayout['eventName']}');
      
      // マップ要素を取得
      final mapElements = await _firebaseService.getMapElements(eventLayout['id']);
      print('マップ要素を取得: ${mapElements.length}件');
      
      setState(() {
        _eventLayout = eventLayout;
        _mapElements = mapElements;
      });
      
      print('=== マップレイアウトの読み込み完了 ===');
    } catch (e) {
      print('マップレイアウトの読み込み中にエラーが発生しました: $e');
      // エラーの場合はデフォルトのレイアウトを使用
      setState(() {
        _eventLayout = null;
        _mapElements = [];
      });
    }
  }

  List<BeaconLocation> _convertBoothsToLocations(List<Map<String, dynamic>> booths) {
    final locations = <BeaconLocation>[];
    
    // Firebaseから取得したブース情報のみを使用（デフォルトのブース情報は追加しない）
    for (final booth in booths) {
      final location = BeaconLocation(
        booth['id'] ?? '',
        booth['x']?.toDouble() ?? 0.0,
        booth['y']?.toDouble() ?? 0.0,
        booth['displayName'] ?? booth['name'] ?? '',
        _getBoothTypeFromString(booth['type'] ?? 'booth'),
      );
      locations.add(location);
    }
    
    return locations;
  }

  BeaconType _getBoothTypeFromString(String type) {
    switch (type) {
      case 'entrance':
        return BeaconType.entrance;
      case 'booth':
        return BeaconType.booth;
      case 'restArea':
        return BeaconType.restArea;
      case 'foodCourt':
        return BeaconType.foodCourt;
      case 'infoDesk':
        return BeaconType.infoDesk;
      default:
        return BeaconType.booth;
    }
  }

  void _startCrowdingMonitoring() {
    // 30秒ごとに混雑度をチェック
    _monitoringTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (mounted) {
        _checkCrowdingLevels();
      }
    });
  }

  void _checkCrowdingLevels() {
    final newAlerts = <String, bool>{};
    
    for (final beacon in _beaconLocations) {
      if (beacon.type == BeaconType.booth) {
        final count = _todayStats[beacon.id]?['count'] ?? 0;
        final isCrowded = count >= _crowdingThreshold;
        
        newAlerts[beacon.id] = isCrowded;
        
        // 新しく混雑になった場合、通知を送信
        if (isCrowded && !(_crowdingAlerts[beacon.id] ?? false)) {
          _notificationService.sendCrowdingNotification(beacon.name, count);
        }
      }
    }
    
    setState(() {
      _crowdingAlerts = newAlerts;
    });
  }

  // 混雑度に基づく色を取得
  Color _getCrowdColor(int count) {
    if (count == 0) return Colors.blue.shade100;
    if (count <= 5) return Colors.green.shade300;
    if (count <= 15) return Colors.yellow.shade400;
    if (count <= 30) return Colors.orange.shade500;
    return Colors.red.shade600;
  }

  // 混雑度のテキストを取得
  String _getCrowdText(int count) {
    if (count == 0) return '空いています';
    if (count <= 5) return 'やや空いています';
    if (count <= 15) return '適度な混雑';
    if (count <= 30) return 'やや混雑';
    return '混雑中';
  }

  void _logout() {
    _authService.logout();
    Navigator.of(context).pushReplacementNamed('/login');
  }

  void _toggleHeatmap() {
    setState(() {
      _showHeatmap = !_showHeatmap;
    });
  }

  void _showThresholdSettings() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        int tempThreshold = _crowdingThreshold;
        
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return AlertDialog(
              title: const Text('混雑度閾値設定'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('何人の来場者で混雑とみなしますか？'),
                  const SizedBox(height: 16),
                  Slider(
                    value: tempThreshold.toDouble(),
                    min: 1,
                    max: 50,
                    divisions: 49,
                    label: '${tempThreshold}人',
                    onChanged: (value) {
                      setDialogState(() {
                        tempThreshold = value.round();
                      });
                    },
                  ),
                  Text('${tempThreshold}人', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('キャンセル'),
                ),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _crowdingThreshold = tempThreshold;
                    });
                    _notificationService.setCrowdingThreshold(tempThreshold);
                    Navigator.of(context).pop();
                    _checkCrowdingLevels(); // 新しい閾値で再チェック
                  },
                  child: const Text('設定'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('スタッフ管理画面'),
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(_showHeatmap ? Icons.map : Icons.map_outlined),
            onPressed: _toggleHeatmap,
            tooltip: 'ヒートマップ表示切替',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showThresholdSettings,
            tooltip: '混雑度設定',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ユーザー情報
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Row(
                        children: [
                          const Icon(Icons.support_agent, size: 40, color: Colors.orange),
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
                              const Text(
                                'スタッフ',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                          const Spacer(),
                          // 混雑警報の概要
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '混雑警報: ${_crowdingAlerts.values.where((alert) => alert).length}件',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: _crowdingAlerts.values.any((alert) => alert) 
                                      ? Colors.red 
                                      : Colors.green,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                '閾値: ${_crowdingThreshold}人',
                                style: const TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 24),
                  
                  // ヒートマップ表示
                  if (_showHeatmap) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.map, color: Colors.orange),
                                const SizedBox(width: 8),
                                const Text(
                                  '会場混雑状況ヒートマップ',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const Spacer(),
                                // 凡例
                                Row(
                                  children: [
                                    _buildLegendItem(Colors.blue.shade100, '空'),
                                    _buildLegendItem(Colors.green.shade300, '空き'),
                                    _buildLegendItem(Colors.yellow.shade400, '普通'),
                                    _buildLegendItem(Colors.orange.shade500, '混雑'),
                                    _buildLegendItem(Colors.red.shade600, '大混雑'),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Container(
                              height: _eventLayout?['mapHeight']?.toDouble() ?? 400,
                              width: _eventLayout?['mapWidth']?.toDouble() ?? double.infinity,
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey.shade300),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: CustomPaint(
                                painter: StaffHeatmapPainter(
                                  _beaconLocations,
                                  _todayStats,
                                  _crowdingAlerts,
                                  _crowdingThreshold,
                                  mapElements: _mapElements,
                                  eventLayout: _eventLayout,
                                ),
                                size: Size(
                                  _eventLayout?['mapWidth']?.toDouble() ?? 380,
                                  _eventLayout?['mapHeight']?.toDouble() ?? 400,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                  
                  // 混雑警報一覧
                  if (_crowdingAlerts.values.any((alert) => alert)) ...[
                    Card(
                      color: Colors.red.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.warning, color: Colors.red.shade700),
                                const SizedBox(width: 8),
                                Text(
                                  '混雑警報 - ${_crowdingAlerts.values.where((alert) => alert).length}件',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.red.shade700,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            ..._crowdingAlerts.entries
                                .where((entry) => entry.value)
                                .map((entry) {
                              final beacon = _beaconLocations.firstWhere(
                                (b) => b.id == entry.key,
                                orElse: () => BeaconLocation('', 0, 0, '不明', BeaconType.booth),
                              );
                              final count = _todayStats[entry.key]?['count'] ?? 0;
                              
                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: Colors.red.shade600,
                                  child: const Icon(Icons.warning, color: Colors.white),
                                ),
                                title: Text(
                                  beacon.name,
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                                subtitle: Text('現在${count}人 - 閾値${_crowdingThreshold}人を超過'),
                                trailing: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.red.shade600,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    '$count人',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                  
                  // 今日の統計
                  const Text(
                    '今日のビーコン受信状況',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  if (_todayStats.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text(
                          '今日の統計データはありません',
                          style: TextStyle(fontSize: 16, color: Colors.grey),
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      height: 300, // 固定の高さを設定
                      child: ListView.builder(
                        itemCount: _todayStats.length,
                        itemBuilder: (context, index) {
                          final deviceName = _todayStats.keys.elementAt(index);
                          final data = _todayStats[deviceName] as Map<String, dynamic>;
                          final count = data['count'] ?? 0;
                          final isCrowded = _crowdingAlerts[deviceName] ?? false;
                          
                          return Card(
                            color: isCrowded ? Colors.red.shade50 : null,
                            child: ListTile(
                              leading: Icon(
                                Icons.bluetooth,
                                color: isCrowded ? Colors.red : Colors.orange,
                              ),
                              title: Text(
                                deviceName,
                                style: TextStyle(
                                  fontWeight: isCrowded ? FontWeight.bold : FontWeight.normal,
                                  color: isCrowded ? Colors.red.shade700 : Colors.black,
                                ),
                              ),
                              subtitle: Text('受信回数: $count回'),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (isCrowded)
                                    Icon(
                                      Icons.warning,
                                      color: Colors.red,
                                      size: 20,
                                    ),
                                  const SizedBox(width: 8),
                                  Icon(
                                    count > 0 ? Icons.check_circle : Icons.error,
                                    color: count > 0 ? Colors.green : Colors.red,
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isCrowded ? Colors.red : Colors.orange,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text(
                                      count.toString(),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
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

  Widget _buildLegendItem(Color color, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 10),
          ),
        ],
      ),
    );
  }
}

// ビーコンの位置情報を管理するクラス
class BeaconLocation {
  final String id;
  final double x;
  final double y;
  final String name;
  final BeaconType type;

  BeaconLocation(this.id, this.x, this.y, this.name, this.type);
}

enum BeaconType {
  entrance,
  booth,
  restArea,
  foodCourt,
  infoDesk,
}

// スタッフ用ヒートマップペインター
class StaffHeatmapPainter extends CustomPainter {
  final List<BeaconLocation> beacons;
  final Map<String, dynamic> crowdData;
  final Map<String, bool> crowdingAlerts;
  final int crowdingThreshold;
  final List<Map<String, dynamic>> mapElements; // マップ要素（Firebaseから取得）
  final Map<String, dynamic>? eventLayout; // イベントレイアウト情報

  StaffHeatmapPainter(
    this.beacons,
    this.crowdData,
    this.crowdingAlerts,
    this.crowdingThreshold, {
    this.mapElements = const [],
    this.eventLayout,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    
    // マップ要素がある場合は動的に描画、ない場合はデフォルトのハードコードされたレイアウトを使用
    if (mapElements.isNotEmpty) {
      // Firebaseから取得したマップ要素を描画
      _drawMapElementsFromFirebase(canvas, size, paint);
    } else {
      // デフォルトのハードコードされたレイアウトを描画
      _drawDefaultLayout(canvas, size, paint);
    }
    
    // ビーコンと混雑状況を描画
    for (final beacon in beacons) {
      final beaconData = crowdData[beacon.id];
      int count = 0;
      if (beaconData is Map<String, dynamic> && beaconData['count'] is int) {
        count = beaconData['count'] as int;
      }

      final crowdColor = _getCrowdColor(count);
      final isCrowded = crowdingAlerts[beacon.id] ?? false;
      
      // 混雑度に応じた円を描画（ヒートマップ効果）
      final radius = math.max(20.0, math.min(50.0, count.toDouble() * 2 + 20));
      
      // グラデーション効果のために複数の円を描画
      for (int i = 3; i >= 1; i--) {
        paint.color = crowdColor.withOpacity(0.1 * i);
        paint.style = PaintingStyle.fill;
        canvas.drawCircle(
          Offset(beacon.x, beacon.y),
          radius * i / 3,
          paint,
        );
      }
      
      // ビーコンアイコンを描画
      paint.color = Colors.white;
      canvas.drawCircle(Offset(beacon.x, beacon.y), 15, paint);
      
      paint.color = isCrowded ? Colors.red : crowdColor;
      paint.strokeWidth = 2;
      paint.style = PaintingStyle.stroke;
      canvas.drawCircle(Offset(beacon.x, beacon.y), 15, paint);
      
      // 混雑警報の場合は赤い枠を追加
      if (isCrowded) {
        paint.color = Colors.red;
        paint.strokeWidth = 3;
        paint.style = PaintingStyle.stroke;
        canvas.drawCircle(Offset(beacon.x, beacon.y), 25, paint);
      }
      
      // ビーコン名を描画
      final textPainter = TextPainter(
        text: TextSpan(
          text: beacon.name,
          style: TextStyle(
            color: isCrowded ? Colors.red.shade700 : Colors.black87,
            fontSize: 10,
            fontWeight: isCrowded ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(beacon.x - textPainter.width / 2, beacon.y + 20),
      );
      
      // 人数を描画
      final countPainter = TextPainter(
        text: TextSpan(
          text: '$count',
          style: TextStyle(
            color: isCrowded ? Colors.red.shade700 : Colors.black,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      countPainter.layout();
      
      final textOffset = Offset(beacon.x - countPainter.width / 2, beacon.y - 6);
      countPainter.paint(canvas, textOffset);
    }
    
    // 閾値ラインを描画（混雑度の参考）
    _drawThresholdLines(canvas, size);
  }

  void _drawThresholdLines(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red.shade300
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    
    // 右側に閾値情報を表示
    final textPainter = TextPainter(
      text: TextSpan(
        text: '混雑閾値: ${crowdingThreshold}人',
        style: TextStyle(
          color: Colors.red.shade600,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(size.width - textPainter.width - 10, 30),
    );
  }

  /// Firebaseから取得したマップ要素を描画
  void _drawMapElementsFromFirebase(Canvas canvas, Size size, Paint paint) {
    // zIndexでソート（小さい値から順に描画）
    final sortedElements = List<Map<String, dynamic>>.from(mapElements);
    sortedElements.sort((a, b) {
      final zA = (a['zIndex'] as num?)?.toInt() ?? 0;
      final zB = (b['zIndex'] as num?)?.toInt() ?? 0;
      return zA.compareTo(zB);
    });
    
    for (final element in sortedElements) {
      final shape = element['shape'] as String? ?? 'rect';
      final x = (element['x'] as num?)?.toDouble() ?? 0.0;
      final y = (element['y'] as num?)?.toDouble() ?? 0.0;
      final width = (element['width'] as num?)?.toDouble() ?? 0.0;
      final height = (element['height'] as num?)?.toDouble() ?? 0.0;
      final colorHex = element['color'] as String? ?? '#EEEEEE';
      final filled = element['filled'] as bool? ?? true;
      final strokeWidth = (element['strokeWidth'] as num?)?.toDouble() ?? 1.0;
      
      // 16進数カラーをColorオブジェクトに変換
      final color = _parseColor(colorHex);
      
      paint.color = color;
      paint.style = filled ? PaintingStyle.fill : PaintingStyle.stroke;
      paint.strokeWidth = strokeWidth;
      
      // 図形の種類に応じて描画
      if (shape == 'rect') {
        canvas.drawRect(Rect.fromLTWH(x, y, width, height), paint);
      } else if (shape == 'circle') {
        final radius = width / 2;
        canvas.drawCircle(Offset(x + radius, y + radius), radius, paint);
      }
    }
  }

  /// デフォルトのハードコードされたレイアウトを描画
  void _drawDefaultLayout(Canvas canvas, Size size, Paint paint) {
    // 背景を描画
    paint.color = Colors.grey.shade50;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
    
    // 会場の外枠を描画
    paint.color = Colors.grey.shade400;
    paint.style = PaintingStyle.stroke;
    paint.strokeWidth = 2;
    canvas.drawRect(Rect.fromLTWH(20, 20, size.width - 40, size.height - 40), paint);
    
    // エントランスを描画
    paint.color = Colors.brown.shade300;
    paint.style = PaintingStyle.fill;
    canvas.drawRect(Rect.fromLTWH(80, 20, 40, 20), paint);
    canvas.drawRect(Rect.fromLTWH(280, 20, 40, 20), paint);
    
    // 通路を描画
    paint.color = Colors.grey.shade200;
    canvas.drawRect(Rect.fromLTWH(20, 80, size.width - 40, 30), paint);
    canvas.drawRect(Rect.fromLTWH(20, 200, size.width - 40, 30), paint);
    canvas.drawRect(Rect.fromLTWH(20, 320, size.width - 40, 30), paint);
    canvas.drawRect(Rect.fromLTWH(140, 20, 30, size.height - 40), paint);
    canvas.drawRect(Rect.fromLTWH(240, 20, 30, size.height - 40), paint);
  }

  /// 16進数カラー文字列をColorオブジェクトに変換
  Color _parseColor(String colorHex) {
    try {
      // "#RRGGBB" 形式を "0xFFRRGGBB" 形式に変換
      String hexColor = colorHex.replaceAll('#', '');
      if (hexColor.length == 6) {
        hexColor = 'FF$hexColor';
      }
      return Color(int.parse(hexColor, radix: 16));
    } catch (e) {
      // パースエラーの場合はグレーを返す
      return Colors.grey.shade200;
    }
  }

  Color _getCrowdColor(int count) {
    if (count == 0) return Colors.blue.shade100;
    if (count <= 5) return Colors.green.shade300;
    if (count <= 15) return Colors.yellow.shade400;
    if (count <= 30) return Colors.orange.shade500;
    return Colors.red.shade600;
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) {
    return true;
  }
} 