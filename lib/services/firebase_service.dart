import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:math' as math;
import 'package:intl/intl.dart'; // DateFormatを追加

class FirebaseService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  // ユーザーが同じビーコンに短時間でアクセスしたかどうかを記録するマップ
  final Map<String, DateTime> _lastProcessedUserBeacon = {};
  // 最適ルート計算の際に使用する最大全探索件数
  static const int _tspExactLimit = 8;
  
  // ビーコンの物理名からブースIDへのマッピング
  static const Map<String, String> beaconNameMapping = {
    'FSC-BP104D': 'FSC-BP104D',  // 1台目: A09
    'FSC-BP103B': 'FSC-BP103B',   // 2台目: A08
  };

  /// デフォルトのRSSI閾値
  static const Map<String, int> _defaultRssiThresholds = {
    'FSC-BP104D': -92,
    'FSC-BP103B': -92,
  };

  /// 全ビーコンのRSSI閾値を取得
  Future<Map<String, int>> getAllBeaconRssiThresholds() async {
    try {
      // 新スキーマ: system_settings/rssi_thresholds ドキュメント
      final doc = await _firestore.collection('system_settings').doc('rssi_thresholds').get();
      if (doc.exists) {
        final data = doc.data() ?? {};
        final result = <String, int>{};
        for (final entry in data.entries) {
          if (entry.value is int) {
            result[entry.key] = entry.value as int;
          }
        }
        // デフォルトがあれば補完
        _defaultRssiThresholds.forEach((k, v) {
          result.putIfAbsent(k, () => v);
        });
        return result;
      }

      // 旧スキーマ: beacon_rssi_thresholds コレクション
      final snapshot = await _firestore.collection('beacon_rssi_thresholds').get();
      if (snapshot.docs.isNotEmpty) {
        final result = <String, int>{};
        for (final d in snapshot.docs) {
          final data = d.data();
          final threshold = data['threshold'];
          if (threshold is int) {
            result[d.id] = threshold;
          }
        }
        _defaultRssiThresholds.forEach((k, v) {
          result.putIfAbsent(k, () => v);
        });
        return result;
      }

      // どちらも無い場合はデフォルト
      return Map<String, int>.from(_defaultRssiThresholds);
    } catch (e) {
      print('RSSI閾値取得中にエラー: $e');
      return Map<String, int>.from(_defaultRssiThresholds);
    }
  }

  /// RSSI閾値の変更を監視
  Stream<Map<String, int>> watchBeaconRssiThresholds() {
    return _firestore.collection('system_settings').doc('rssi_thresholds').snapshots().map((doc) {
      final result = <String, int>{};
      if (doc.exists) {
        final data = doc.data() ?? {};
        data.forEach((key, value) {
          if (value is int) {
            result[key] = value;
          }
        });
      }
      _defaultRssiThresholds.forEach((k, v) {
        result.putIfAbsent(k, () => v);
      });
      return result;
    });
  }

  /// ビーコンごとのRSSI閾値を設定
  Future<void> setBeaconRssiThreshold(String beaconName, int threshold) async {
    try {
      // 新スキーマ: system_settings/rssi_thresholds ドキュメントにマージ
      await _firestore
          .collection('system_settings')
          .doc('rssi_thresholds')
          .set({
            beaconName: threshold,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
      print('RSSI閾値を保存 (system_settings): $beaconName => $threshold');
    } catch (e) {
      print('RSSI閾値保存中にエラー: $e');
      rethrow;
    }
  }

  // ------------------------------
  // お気に入り（ブースToDoリスト）
  // ------------------------------

  /// 指定ユーザーのブースお気に入り一覧を取得
  Future<List<String>> getBookmarkedBoothIds(String userId) async {
    try {
      final doc = await _firestore.collection('user_bookmarks').doc(userId).get();
      if (!doc.exists) return [];
      final data = doc.data() ?? {};
      final booths = data['booths'];
      if (booths is List) {
        return booths.whereType<String>().toList();
      }
      return [];
    } catch (e) {
      print('お気に入り取得中にエラー: $e');
      return [];
    }
  }

  /// ブースをお気に入りに追加
  Future<void> addBoothBookmark(String userId, String boothId) async {
    try {
      await _firestore.collection('user_bookmarks').doc(userId).set({
        'booths': FieldValue.arrayUnion([boothId]),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      print('お気に入り追加: $boothId');
    } catch (e) {
      print('お気に入り追加中にエラー: $e');
      rethrow;
    }
  }

  /// ブースをお気に入りから削除
  Future<void> removeBoothBookmark(String userId, String boothId) async {
    try {
      await _firestore.collection('user_bookmarks').doc(userId).set({
        'booths': FieldValue.arrayRemove([boothId]),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      print('お気に入り削除: $boothId');
    } catch (e) {
      print('お気に入り削除中にエラー: $e');
      rethrow;
    }
  }

  /// トグル（追加/削除）して結果を返す
  Future<bool> toggleBoothBookmark(String userId, String boothId) async {
    final current = await getBookmarkedBoothIds(userId);
    final isFavorite = current.contains(boothId);
    if (isFavorite) {
      await removeBoothBookmark(userId, boothId);
      return false;
    } else {
      await addBoothBookmark(userId, boothId);
      return true;
    }
  }

  // ------------------------------
  // 巡回ルート最適化（簡易TSP）
  // ------------------------------

  /// ブースID一覧から座標マップを生成
  Future<Map<String, Map<String, double>>> _fetchBoothPositions(Set<String> boothIds) async {
    final booths = await getAllBooths();
    final pos = <String, Map<String, double>>{};
    for (final b in booths) {
      final id = b['id']?.toString();
      if (id == null) continue;
      if (!boothIds.contains(id)) continue;
      final x = (b['x'] as num?)?.toDouble();
      final y = (b['y'] as num?)?.toDouble();
      if (x != null && y != null) {
        pos[id] = {'x': x, 'y': y};
      }
    }
    return pos;
  }

  double _dist(Map<String, double> a, Map<String, double> b) {
    final dx = (a['x'] ?? 0) - (b['x'] ?? 0);
    final dy = (a['y'] ?? 0) - (b['y'] ?? 0);
    return math.sqrt(dx * dx + dy * dy);
  }

  double _routeLength(List<String> order, Map<String, Map<String, double>> pos, Map<String, double> start) {
    double sum = 0;
    Map<String, double> current = start;
    for (final id in order) {
      final p = pos[id];
      if (p == null) continue;
      sum += _dist(current, p);
      current = p;
    }
    return sum;
  }

  /// 2-optで経路を局所改善
  List<String> _twoOpt(List<String> route, Map<String, Map<String, double>> pos, Map<String, double> start) {
    bool improved = true;
    while (improved) {
      improved = false;
      for (int i = 0; i < route.length - 1; i++) {
        for (int k = i + 1; k < route.length; k++) {
          final newRoute = [
            ...route.sublist(0, i),
            ...route.sublist(i, k + 1).reversed,
            ...route.sublist(k + 1)
          ];
          if (_routeLength(newRoute, pos, start) + 1e-6 < _routeLength(route, pos, start)) {
            route = newRoute;
            improved = true;
          }
        }
      }
    }
    return route;
  }

  /// 近傍挿入法で初期経路を構築
  List<String> _nearestInsertion(List<String> targets, Map<String, Map<String, double>> pos, Map<String, double> start) {
    if (targets.isEmpty) return [];
    final unvisited = List<String>.from(targets);
    // startに最も近い点を初期とする
    unvisited.sort((a, b) {
      final da = _dist(start, pos[a]!);
      final db = _dist(start, pos[b]!);
      return da.compareTo(db);
    });
    final route = <String>[unvisited.removeAt(0)];
    while (unvisited.isNotEmpty) {
      // 最も近い未訪問を選ぶ
      unvisited.sort((a, b) {
        final da = _dist(pos[route.last]!, pos[a]!);
        final db = _dist(pos[route.last]!, pos[b]!);
        return da.compareTo(db);
      });
      final next = unvisited.removeAt(0);
      // ベストな挿入位置を探す
      double bestIncrease = double.infinity;
      int bestIdx = 0;
      for (int i = 0; i <= route.length; i++) {
        final prev = i == 0 ? start : pos[route[i - 1]]!;
        final nxt = i == route.length ? null : pos[route[i]]!;
        final increase = _dist(prev, pos[next]!) + (nxt != null ? _dist(pos[next]!, nxt) - _dist(prev, nxt) : _dist(prev, pos[next]!));
        if (increase < bestIncrease) {
          bestIncrease = increase;
          bestIdx = i;
        }
      }
      route.insert(bestIdx, next);
    }
    return route;
  }

  /// 最適または準最適の巡回順を計算する（現在地→全ブースを回る順）
  /// currentPosition: {'x': double, 'y': double}（なければ(0,0)）
  Future<Map<String, dynamic>> computeOptimalRoute({
    required List<String> targetBoothIds,
    Map<String, double>? currentPosition,
  }) async {
    if (targetBoothIds.isEmpty) {
      return {'order': <String>[], 'totalDistance': 0.0};
    }

    final start = currentPosition ?? {'x': 0.0, 'y': 0.0};
    final positions = await _fetchBoothPositions(targetBoothIds.toSet());

    // 座標が取れないブースを除外
    final validTargets = targetBoothIds.where((id) => positions.containsKey(id)).toList();
    if (validTargets.isEmpty) {
      return {'order': <String>[], 'totalDistance': 0.0};
    }

    List<String> bestOrder = [];

    if (validTargets.length <= _tspExactLimit) {
      // 全探索
      double best = double.infinity;
      void permute(List<String> list, int l) {
        if (l == list.length) {
          final len = _routeLength(list, positions, start);
          if (len < best) {
            best = len;
            bestOrder = List<String>.from(list);
          }
          return;
        }
        for (int i = l; i < list.length; i++) {
          final tmp = list[l];
          list[l] = list[i];
          list[i] = tmp;
          permute(list, l + 1);
          list[i] = list[l];
          list[l] = tmp;
        }
      }
      permute(List<String>.from(validTargets), 0);
    } else {
      // 近傍挿入 + 2-opt
      var route = _nearestInsertion(validTargets, positions, start);
      route = _twoOpt(route, positions, start);
      bestOrder = route;
    }

    final totalDistance = _routeLength(bestOrder, positions, start);
    return {
      'order': bestOrder,
      'totalDistance': totalDistance,
    };
  }
  
  /// ビーコンの物理名をブースIDに変換
  String getBoothIdFromBeaconName(String beaconName) {
    return beaconNameMapping[beaconName] ?? beaconName;
  }

  /// 既存の来場者のタイムスタンプのみを更新（カウントは増やさない）
  Future<void> updateVisitorTimestamp(String deviceName, String userId, {String eventType = 'visit'}) async {
    try {
      final now = DateTime.now();
      final dateString = DateFormat('yyyy-MM-dd').format(now);
      print('=== updateVisitorTimestamp開始: $deviceName (ユーザー: $userId) ===');
      
      final docRef = _firestore
          .collection('beacon_counts')
          .doc(dateString)
          .collection('devices')
          .doc(deviceName);

      await _firestore.runTransaction((transaction) async {
        final doc = await transaction.get(docRef);
        
        if (doc.exists) {
          final rawVisitors = doc.data()?['visitors'];
          final existingVisitors = <Map<String, dynamic>>[];
          bool updated = false;
          
          if (rawVisitors != null && rawVisitors is List) {
            // 最新のレコードを探してlastDetectedAtを更新
            DateTime? latestTimestamp;
            int latestIndex = -1;
            
            for (int i = 0; i < rawVisitors.length; i++) {
              final visitor = rawVisitors[i];
              if (visitor is Map<String, dynamic>) {
                if (visitor['userId'] == userId && visitor['eventType'] == eventType) {
                  final timestamp = visitor['timestamp'];
                  if (timestamp is Timestamp) {
                    final visitTime = timestamp.toDate();
                    if (latestTimestamp == null || visitTime.isAfter(latestTimestamp)) {
                      latestTimestamp = visitTime;
                      latestIndex = i;
                    }
                  }
                }
                existingVisitors.add(visitor);
              }
            }
            
            // 最新のレコードのlastDetectedAtを更新
            if (latestIndex >= 0) {
              existingVisitors[latestIndex] = Map<String, dynamic>.from(existingVisitors[latestIndex]);
              final ts = existingVisitors[latestIndex]['timestamp'];
              if (ts is Timestamp) {
                final visitTime = ts.toDate();
                final stayMinutes = ((now.difference(visitTime).inSeconds) / 60).ceil();
                existingVisitors[latestIndex]['lastDetectedAt'] = Timestamp.now();
                existingVisitors[latestIndex]['totalTime'] = stayMinutes;
                print('最新レコード（インデックス$latestIndex）のlastDetectedAtとtotalTimeを更新: ${stayMinutes}分');
              } else {
                existingVisitors[latestIndex]['lastDetectedAt'] = Timestamp.now();
                print('最新レコード（インデックス$latestIndex）のlastDetectedAtを更新（timestamp型不明）');
              }
              updated = true;
            }
          }
          
          if (updated) {
            transaction.update(docRef, {
              'visitors': existingVisitors,
              'lastSeen': FieldValue.serverTimestamp(),
            });
            print('タイムスタンプ更新完了');
          } else {
            print('更新対象のレコードが見つかりませんでした');
          }
        }
      });
      
      print('=== updateVisitorTimestamp完了 ===');
    } catch (e) {
      print('タイムスタンプ更新中にエラーが発生しました: $e');
    }
  }

  /// BLEビーコン受信時にカウントと来場者属性をFirebaseに保存
  Future<void> incrementBeaconCount(String deviceName, {String? userId, String eventType = 'visit'}) async {
    try {
      final now = DateTime.now();
      final dateString = DateFormat('yyyy-MM-dd').format(now);
      print('=== incrementBeaconCount開始: $deviceName (ユーザー: $userId) ===');
      print('日付: $dateString, 時刻: ${now.toString()}');
      
      // 重複チェック: 同じユーザーが同じビーコンに短時間でアクセスしていないかチェック
      if (userId != null) {
        final userBeaconKey = '${userId}_$deviceName';
        final lastProcessedTime = _lastProcessedUserBeacon[userBeaconKey];
        
        if (lastProcessedTime != null && now.difference(lastProcessedTime) < const Duration(seconds: 5)) {
          print('重複防止: ユーザー $userId のビーコン $deviceName は最近処理されました。スキップします。');
          print('前回処理時刻: $lastProcessedTime, 経過時間: ${now.difference(lastProcessedTime).inSeconds}秒');
          return;
        }
        
        // 処理時刻を記録
        _lastProcessedUserBeacon[userBeaconKey] = now;
        print('重複防止: ユーザー $userId のビーコン $deviceName の処理時刻を記録しました');
      }
      
      // 来場者の属性情報を取得
      Map<String, dynamic>? visitorData;
      if (userId != null) {
        visitorData = await getVisitorData(userId);
        print('来場者属性データ: $visitorData');
      }
      
      // デバイス名と日付でドキュメントを参照
      final docRef = _firestore
          .collection('beacon_counts')
          .doc(dateString)
          .collection('devices')
          .doc(deviceName);

      // トランザクションを使用してカウントを安全にインクリメント
      await _firestore.runTransaction((transaction) async {
        final doc = await transaction.get(docRef);
        
        // 来場者の記録データを準備
        Map<String, dynamic>? visitorRecord;
        if (userId != null) {
          // visitorDataがnullでも、基本的な訪問者情報は記録する
          if (visitorData != null) {
            visitorRecord = {
              'userId': userId,
              'timestamp': Timestamp.now(),
              'lastDetectedAt': Timestamp.now(), // 最終検出時刻を追加
              'totalTime': 0, // 滞在時間（分）
              'microsecondsSinceEpoch': DateTime.now().microsecondsSinceEpoch, // 一意性を確保
              'eventType': eventType,
              'age': visitorData['age'],
              'gender': visitorData['gender'],
              'job': visitorData['job'],
              'company': visitorData['company'],
              'position': visitorData['position'],
              'industry': visitorData['industry'],
              'eventSource': visitorData['eventSource'],
              'interests': visitorData['interests'],
            };
          } else {
            // visitorDataがnullの場合の基本的な記録
            visitorRecord = {
              'userId': userId,
              'timestamp': Timestamp.now(),
              'lastDetectedAt': Timestamp.now(), // 最終検出時刻を追加
              'totalTime': 0, // 滞在時間（分）
              'microsecondsSinceEpoch': DateTime.now().microsecondsSinceEpoch, // 一意性を確保
              'eventSource': 'BLE_Detection',
              'eventType': eventType,
              'detectedAt': now.toString(),
            };
            print('visitorDataがnullのため、基本的な訪問者情報を作成: $visitorRecord');
          }
        }
        
        if (doc.exists) {
          // 既存のドキュメントがある場合はカウントをインクリメント
          final currentCount = doc.data()?['count'] ?? 0;
          final existingFirstSeen = doc.data()?['firstSeen']; // 既存のfirstSeenを保持
          print('既存のドキュメントを更新: 現在のカウント = $currentCount, 既存のfirstSeen = $existingFirstSeen');
          
          // 既存のvisitors配列を取得
          final rawVisitors = doc.data()?['visitors'];
          print('生のvisitorsデータ: $rawVisitors (型: ${rawVisitors.runtimeType})');
          
          final existingVisitors = <Map<String, dynamic>>[];
          bool shouldUpdateTimestamp = false;
          DateTime? latestVisitTimestamp;
          
          if (rawVisitors != null && rawVisitors is List) {
            // 同じuserIdとeventTypeの最新のレコードを探す
            for (final visitor in rawVisitors) {
              if (visitor is Map<String, dynamic>) {
                if (visitor['userId'] == userId && visitor['eventType'] == eventType) {
                  final timestamp = visitor['timestamp'];
                  if (timestamp is Timestamp) {
                    final visitTime = timestamp.toDate();
                    if (latestVisitTimestamp == null || visitTime.isAfter(latestVisitTimestamp)) {
                      latestVisitTimestamp = visitTime;
                    }
                  }
                }
                existingVisitors.add(visitor);
              }
            }
          }
          
          // 最新の訪問から30秒以内なら、lastDetectedAtのみ更新
          // 30秒以上経過していれば、新しい訪問として記録
          if (latestVisitTimestamp != null) {
            final timeSinceLastVisit = now.difference(latestVisitTimestamp);
            if (timeSinceLastVisit <= const Duration(seconds: 30)) {
              // 短時間内の再検出 → 最新レコードのlastDetectedAtを更新
              shouldUpdateTimestamp = true;
              print('短時間内の再検出 (${timeSinceLastVisit.inSeconds}秒前): lastDetectedAtを更新');
              
              // 最新のレコードを探して更新
              for (int i = existingVisitors.length - 1; i >= 0; i--) {
                final visitor = existingVisitors[i];
                if (visitor['userId'] == userId && visitor['eventType'] == eventType) {
                  final timestamp = visitor['timestamp'];
                  if (timestamp is Timestamp && timestamp.toDate() == latestVisitTimestamp) {
                    existingVisitors[i] = Map<String, dynamic>.from(visitor);
                    final visitTime = timestamp.toDate();
                    final stayMinutes = ((now.difference(visitTime).inSeconds) / 60).ceil();
                    existingVisitors[i]['lastDetectedAt'] = Timestamp.now();
                    existingVisitors[i]['totalTime'] = stayMinutes;
                    print('最新レコードの lastDetectedAt と totalTime を更新: ${stayMinutes}分');
                    break;
                  }
                }
              }
            } else {
              print('30秒以上経過 (${timeSinceLastVisit.inSeconds}秒前): 新しい訪問として記録');
            }
          }
          
          print('処理後の既存visitors: ${existingVisitors.length}件');
          
          // 新しい訪問者データを追加（初回訪問、または30秒以上経過後の再訪問）
          if (visitorRecord != null && !shouldUpdateTimestamp) {
            existingVisitors.add(visitorRecord);
            print('新しい訪問レコードを追加: ${visitorRecord['userId']}');
            print('更新後のvisitors総数: ${existingVisitors.length}件');
          } else if (shouldUpdateTimestamp) {
            print('既存レコードのタイムスタンプを更新しました（新しいレコードは追加せず）');
          }
          
          // long_stayの場合、または既存訪問者のタイムスタンプ更新の場合はcountをインクリメントしない
          final shouldIncrementCount = visitorRecord != null && 
                                        !shouldUpdateTimestamp && 
                                        visitorRecord['eventType'] != 'long_stay';
          final newCount = shouldIncrementCount ? currentCount + 1 : currentCount;
          
          final updateData = {
            'count': newCount,
            'firstSeen': existingFirstSeen, // 既存のfirstSeenを保持
            'lastSeen': FieldValue.serverTimestamp(),
            'deviceName': deviceName,
            'visitors': existingVisitors, // 更新された配列を設定
          };
          
          transaction.update(docRef, updateData);
          print('新しいカウント: $newCount, 訪問者数: ${existingVisitors.length}, firstSeen保持: $existingFirstSeen');
        } else {
          // 新しいドキュメントを作成
          print('新しいドキュメントを作成');
          
          // long_stayの場合はcountを1にしない
          final initialCount = visitorRecord?['eventType'] == 'long_stay' ? 0 : 1;
          
          final newDocData = {
            'count': initialCount,
            'firstSeen': FieldValue.serverTimestamp(),
            'lastSeen': FieldValue.serverTimestamp(),
            'deviceName': deviceName,
            'visitors': visitorRecord != null ? [visitorRecord] : [],
          };
          
          transaction.set(docRef, newDocData);
          print('初期カウント: $initialCount');
        }
      });

      print('=== Firebase保存完了: $deviceName ===');
    } catch (e) {
      print('Firebaseへの保存中にエラーが発生しました: $e');
    }
  }

  /// テストユーザーデータを取得
  Future<List<Map<String, dynamic>>> getTestUsers() async {
    try {
      print('=== getTestUsers開始 ===');
      
      // テストユーザーコレクションからデータを取得
      final querySnapshot = await _firestore.collection('test_users').get();
      
      final testUsers = <Map<String, dynamic>>[];
      for (final doc in querySnapshot.docs) {
        final userData = doc.data();
        testUsers.add(userData);
        print('テストユーザー: ${userData['userId']} - ${userData['name']}');
      }
      
      print('=== getTestUsers完了: ${testUsers.length}件 ===');
      return testUsers;
    } catch (e) {
      print('テストユーザーデータの取得中にエラーが発生しました: $e');
      // エラーの場合はデフォルトのテストユーザーを返す
      return [
        {
          'userId': 'visitor_1755849847010',
          'name': 'テストユーザー1',
          'age': 25,
          'gender': '男性',
          'job': '会社員',
          'eventSource': 'Web',
          'interests': ['テクノロジー'],
        },
        {
          'userId': 'visitor_1755849847011',
          'name': 'テストユーザー2',
          'age': 30,
          'gender': '女性',
          'job': 'エンジニア',
          'eventSource': 'Web',
          'interests': ['ビジネス'],
        },
      ];
    }
  }

  /// 指定した日付のビーコン受信統計を取得
  Future<Map<String, dynamic>> getBeaconStats(String dateString) async {
    try {
      print('=== getBeaconStats開始: $dateString ===');
      final querySnapshot = await _firestore
          .collection('beacon_counts')
          .doc(dateString)
          .collection('devices')
          .get();

      print('取得されたドキュメント数: ${querySnapshot.docs.length}');
      
      final stats = <String, dynamic>{};
      final now = DateTime.now();
      const activeThreshold = Duration(seconds: 20); // 20秒以内をアクティブと判定
      
      for (final doc in querySnapshot.docs) {
        final rawData = doc.data();
        print('ドキュメントID: ${doc.id}, 生データ: $rawData');
        
        final isTestData = rawData['isTestData'] == true;
        int displayCount = 0;
        
        if (isTestData) {
          // テストデータの場合は、countフィールドをそのまま使用
          displayCount = rawData['count'] ?? 0;
          print('テストデータ: countをそのまま使用 = $displayCount');
        } else {
          // 実際のデータの場合は、アクティブな来場者をカウント（最終検出時刻が20秒以内）
          final visitors = rawData['visitors'];
          if (visitors != null && visitors is List) {
            for (final visitor in visitors) {
              if (visitor is Map<String, dynamic>) {
                final lastDetectedAt = visitor['lastDetectedAt'];
                if (lastDetectedAt is Timestamp) {
                  final lastDetectedTime = lastDetectedAt.toDate();
                  final timeDiff = now.difference(lastDetectedTime);
                  if (timeDiff <= activeThreshold) {
                    displayCount++;
                  }
                }
              }
            }
          }
          print('実データ: アクティブ訪問者 = $displayCount');
        }
        
        // Timestampやその他のFirebase特有の型を安全な形式に変換
        final cleanData = <String, dynamic>{
          'count': displayCount,
          'totalVisits': rawData['count'] ?? 0, // 累計訪問数も保持
          'deviceName': rawData['deviceName'] ?? doc.id,
          'firstSeen': rawData['firstSeen']?.toString() ?? '',
          'lastSeen': rawData['lastSeen']?.toString() ?? '',
          'isTestData': isTestData,
        };
        
        print('変換後データ: $cleanData');
        stats[doc.id] = cleanData;
      }
      
      print('=== getBeaconStats完了: stats = $stats ===');
      return stats;
    } catch (e) {
      print('統計データの取得中にエラーが発生しました: $e');
      return {};
    }
  }

  /// 最新のビーコン受信統計を取得（日付に関係なく最新データを取得）
  Future<Map<String, dynamic>> getTodayStats() async {
    try {
      print('=== 最新データの検索開始 ===');
      
      // まず今日の日付でチェック
      final today = DateTime.now();
      final todayString = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      print('今日の日付でチェック: $todayString');
      
      Map<String, dynamic> result = await getBeaconStats(todayString);
      
      // 今日のデータがない場合、最新のデータを検索
      if (result.isEmpty) {
        print('今日のデータがないため、最新データを検索中...');
        result = await getLatestStats();
      }
      
      print('=== 最終取得結果: $result ===');
      return result;
    } catch (e) {
      print('最新データ取得中にエラー: $e');
      return {};
    }
  }

  /// リアルタイムでビーコン統計を監視（他のデバイスの更新も取得）
  Stream<Map<String, dynamic>> watchTodayStats() {
    try {
      final today = DateTime.now();
      final todayString = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      
      print('=== リアルタイムリスナー開始: $todayString ===');
      
      return _firestore
          .collection('beacon_counts')
          .doc(todayString)
          .collection('devices')
          .snapshots()
          .map((querySnapshot) {
        final stats = <String, dynamic>{};
        final now = DateTime.now();
        const activeThreshold = Duration(seconds: 20); // 20秒以内をアクティブと判定
        
        for (final doc in querySnapshot.docs) {
          final rawData = doc.data();
          final isTestData = rawData['isTestData'] == true;
          int displayCount = 0;
          
          if (isTestData) {
            // テストデータの場合は、countフィールドをそのまま使用
            displayCount = rawData['count'] ?? 0;
          } else {
            // 実際のデータの場合は、アクティブな来場者をカウント（最終検出時刻が20秒以内）
            final visitors = rawData['visitors'];
            if (visitors != null && visitors is List) {
              for (final visitor in visitors) {
                if (visitor is Map<String, dynamic>) {
                  final lastDetectedAt = visitor['lastDetectedAt'];
                  if (lastDetectedAt is Timestamp) {
                    final lastDetectedTime = lastDetectedAt.toDate();
                    final timeDiff = now.difference(lastDetectedTime);
                    if (timeDiff <= activeThreshold) {
                      displayCount++;
                    }
                  }
                }
              }
            }
          }
          
          final cleanData = <String, dynamic>{
            'count': displayCount,
            'totalVisits': rawData['count'] ?? 0,
            'deviceName': rawData['deviceName'] ?? doc.id,
            'firstSeen': rawData['firstSeen']?.toString() ?? '',
            'lastSeen': rawData['lastSeen']?.toString() ?? '',
            'isTestData': isTestData,
          };
          
          stats[doc.id] = cleanData;
        }
        
        print('リアルタイム更新: ${stats.length}件のビーコンデータ');
        return stats;
      });
    } catch (e) {
      print('リアルタイムリスナー設定中にエラー: $e');
      return Stream.value({});
    }
  }

  /// 最新のビーコンデータを取得（過去7日間から検索）
  Future<Map<String, dynamic>> getLatestStats() async {
    try {
      print('=== 過去7日間の最新データを検索 ===');
      
      final today = DateTime.now();
      Map<String, dynamic> latestData = {};
      
      // 過去7日間を検索
      for (int i = 0; i < 7; i++) {
        final checkDate = today.subtract(Duration(days: i));
        final dateString = '${checkDate.year}-${checkDate.month.toString().padLeft(2, '0')}-${checkDate.day.toString().padLeft(2, '0')}';
        
        print('検索中の日付: $dateString');
        final dayData = await getBeaconStats(dateString);
        
        if (dayData.isNotEmpty) {
          print('データが見つかりました: $dateString (${dayData.length}件)');
          
          // 複数日のデータをマージ（最新の値を優先）
          dayData.forEach((key, value) {
            if (!latestData.containsKey(key) || 
                (value['lastSeen'] != null && latestData[key]['lastSeen'] != null &&
                 value['lastSeen'].compareTo(latestData[key]['lastSeen']) > 0)) {
              latestData[key] = value;
            }
          });
        }
      }
      
      print('=== 最新データの検索完了: ${latestData.length}件 ===');
      return latestData;
    } catch (e) {
      print('最新データ検索中にエラー: $e');
      return {};
    }
  }

  /// 来場者データをFirestoreに保存
  Future<void> saveVisitorData(String userId, Map<String, dynamic> visitorData) async {
    try {
      // ユーザーIDを使ってドキュメントIDを指定して保存
      await _firestore.collection('visitors').doc(userId).set(visitorData);
      print('来場者データを保存しました: $userId - ${visitorData['email']}');
    } catch (e) {
      print('来場者データの保存中にエラーが発生しました: $e');
      throw Exception('来場者データの保存に失敗しました: $e');
    }
  }

  /// 来場者の属性情報を取得
  Future<Map<String, dynamic>?> getVisitorData(String userId) async {
    try {
      final doc = await _firestore.collection('visitors').doc(userId).get();
      if (doc.exists) {
        return doc.data();
      }
      return null;
    } catch (e) {
      print('来場者データの取得中にエラーが発生しました: $e');
      return null;
    }
  }

  /// 特定のビーコンの来場者属性情報を取得
  Future<List<Map<String, dynamic>>> getBeaconVisitorDetails(String deviceName, String dateString) async {
    try {
      final doc = await _firestore
          .collection('beacon_counts')
          .doc(dateString)
          .collection('devices')
          .doc(deviceName)
          .get();
      
      if (doc.exists && doc.data() != null) {
        final data = doc.data()!;
        if (data['visitors'] != null && data['visitors'] is List) {
          return List<Map<String, dynamic>>.from(data['visitors']);
        }
      }
      return [];
    } catch (e) {
      print('ビーコン来場者詳細の取得中にエラーが発生しました: $e');
      return [];
    }
  }

  /// テスト用の混雑データを生成
  Future<void> generateTestCrowdData() async {
    try {
      final today = DateTime.now();
      final dateString = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      
      // 実際の会場のビーコンID一覧
      final beaconIds = [
        'Entrance-Main',
        'Entrance-Side',
        'FSC-BP104D', // 実際のビーコン（ブースA1）
        'Booth-A2', 
        'Booth-A3',
        'Booth-B1',
        'Booth-B2',
        'Booth-B3',
        'Booth-C1',
        'Booth-C2',
        'Booth-C3',
        'Rest-Area1',
        'Rest-Area2',
        'Food-Court',
        'Info-Desk',
      ];

      final random = math.Random();
      final batch = _firestore.batch();

      for (final beaconId in beaconIds) {
        // ランダムな混雑度を生成（0-50人の範囲）
        final count = random.nextInt(51);
        
        final docRef = _firestore
            .collection('beacon_counts')
            .doc(dateString)
            .collection('devices')
            .doc(beaconId);

        // テスト用の来場者データを生成
        final visitors = <Map<String, dynamic>>[];
        final genders = ['男性', '女性', 'その他'];
        final jobs = [
          '会社員',
          '公務員',
          '自営業',
          '学生',
          '主婦・主夫',
          'フリーランス',
          '医師・看護師',
          'エンジニア',
          '教師・講師',
          'その他'
        ];
        final sources = ['SNS', 'ウェブサイト', '友人紹介', 'チラシ'];
        final interests = [['IT', 'ビジネス'], ['アート', 'デザイン'], ['教育', '学習'], ['健康', '美容']];
        final companies = ['株式会社ABC', '株式会社XYZ', 'テクノロジー株式会社', '〇〇大学', 'フリーランス', 'スタートアップ企業', '大手メーカー'];
        final positions = ['部長', '課長', '主任', '担当者', '学生', '代表取締役', 'マネージャー', 'ディレクター', '一般社員'];
        final industries = ['IT・情報通信', '製造業', '金融・保険', '商社・卸売', '小売業', 'サービス業', '教育・研究', '建設・不動産', '医療・福祉', 'メディア・広告'];
        
        for (int i = 0; i < count; i++) {
          final userId = 'test_visitor_${random.nextInt(100000)}';
          final age = 20 + random.nextInt(41); // 20-60歳
          final gender = genders[random.nextInt(genders.length)];
          final job = jobs[random.nextInt(jobs.length)];
          final source = sources[random.nextInt(sources.length)];
          final interest = interests[random.nextInt(interests.length)];
          final company = companies[random.nextInt(companies.length)];
          final position = positions[random.nextInt(positions.length)];
          final industry = industries[random.nextInt(industries.length)];
          
          // visitorsコレクションにも保存（見込み客リスト用）
          await _firestore.collection('visitors').doc(userId).set({
            'userId': userId,
            'displayName': 'テストユーザー${i + 1}',
            'email': 'test${i + 1}@example.com',
            'age': age,
            'gender': gender,
            'job': job,
            'company': company,
            'position': position,
            'industry': industry,
            'eventSource': source,
            'interests': interest,
          });
          
          // 見込み客の条件を満たすデータを生成
          final visitTime = today.subtract(Duration(minutes: random.nextInt(480))); // 8時間前まで
          final eventType = random.nextDouble() < 0.1 ? 'long_stay' : 'visit'; // 10%の確率でlong_stay
          
          // 100%アクティブ（すべて現在その場にいる状態）
          final lastDetectedAt = Timestamp.fromDate(today.subtract(Duration(seconds: random.nextInt(15)))); // 0-15秒前（アクティブ）
          
          visitors.add({
            'userId': userId,
            'timestamp': Timestamp.fromDate(visitTime),
            'lastDetectedAt': lastDetectedAt, // 最終検出時刻を追加
            'age': age,
            'gender': gender,
            'job': job,
            'company': company,
            'position': position,
            'industry': industry,
            'eventSource': source,
            'interests': interest,
            'eventType': eventType,
          });
          
          // 再訪問のテストデータを追加（30%の確率）
          if (random.nextDouble() < 0.3) {
            final revisitTime = visitTime.add(Duration(minutes: random.nextInt(60) + 30)); // 30分後から90分後
            
            // 再訪問も100%アクティブ
            final revisitLastDetectedAt = Timestamp.fromDate(today.subtract(Duration(seconds: random.nextInt(15)))); // 0-15秒前（アクティブ）
            
            visitors.add({
              'userId': userId,
              'timestamp': Timestamp.fromDate(revisitTime),
              'lastDetectedAt': revisitLastDetectedAt, // 最終検出時刻を追加
              'age': age,
              'gender': gender,
              'job': job,
              'company': company,
              'position': position,
              'industry': industry,
              'eventSource': source,
              'interests': interest,
              'eventType': 'visit',
            });
          }
        }

        batch.set(docRef, {
          'count': count,
          'deviceName': beaconId,
          'visitors': visitors, // 来場者データを追加
          'firstSeen': Timestamp.fromDate(
            today.subtract(Duration(hours: random.nextInt(8) + 1))
          ),
          'lastSeen': Timestamp.fromDate(
            today.subtract(Duration(minutes: random.nextInt(30)))
          ),
          'generatedAt': FieldValue.serverTimestamp(),
          'isTestData': true,
        });
      }

      await batch.commit();
      print('テスト用混雑データを生成しました');
    } catch (e) {
      print('テストデータ生成中にエラーが発生しました: $e');
      throw Exception('テストデータの生成に失敗しました: $e');
    }
  }

  /// テストデータをクリア
  Future<void> clearTestData() async {
    try {
      final today = DateTime.now();
      final dateString = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      
      final querySnapshot = await _firestore
          .collection('beacon_counts')
          .doc(dateString)
          .collection('devices')
          .where('isTestData', isEqualTo: true)
          .get();

      final batch = _firestore.batch();
      for (final doc in querySnapshot.docs) {
        batch.delete(doc.reference);
      }

      await batch.commit();
      print('テストデータをクリアしました');
    } catch (e) {
      print('テストデータクリア中にエラーが発生しました: $e');
      throw Exception('テストデータのクリアに失敗しました: $e');
    }
  }

  /// 存在するすべての日付のビーコンデータを確認
  Future<void> debugAllDates() async {
    try {
      print('=== 全日付データの確認開始 ===');
      final collectionSnapshot = await _firestore.collection('beacon_counts').get();
      
      print('見つかった日付の数: ${collectionSnapshot.docs.length}');
      
      for (final dateDoc in collectionSnapshot.docs) {
        final dateString = dateDoc.id;
        print('--- 日付: $dateString ---');
        
        final devicesSnapshot = await dateDoc.reference.collection('devices').get();
        print('  この日付のデバイス数: ${devicesSnapshot.docs.length}');
        
        for (final deviceDoc in devicesSnapshot.docs) {
          final deviceData = deviceDoc.data();
          print('  デバイス: ${deviceDoc.id}, カウント: ${deviceData['count']}');
        }
      }
      print('=== 全日付データの確認完了 ===');
    } catch (e) {
      print('全日付データ確認中にエラー: $e');
    }
  }

  /// 特定の日付のデータを取得（デバッグ用）
  Future<Map<String, dynamic>> getStatsForDate(String dateString) async {
    try {
      print('=== 指定日付のデータ取得: $dateString ===');
      final result = await getBeaconStats(dateString);
      return result;
    } catch (e) {
      print('指定日付データ取得中にエラー: $e');
      return {};
    }
  }

  /// ブース情報をFirebaseに保存
  Future<void> saveBoothInfo(String boothId, Map<String, dynamic> boothData) async {
    try {
      await _firestore.collection('booths').doc(boothId).set(boothData);
      print('ブース情報を保存しました: $boothId');
    } catch (e) {
      print('ブース情報の保存中にエラーが発生しました: $e');
    }
  }

  /// 全ブース情報をFirebaseから取得
  Future<List<Map<String, dynamic>>> getAllBooths() async {
    try {
      final querySnapshot = await _firestore.collection('booths').get();
      final booths = <Map<String, dynamic>>[];
      
      for (final doc in querySnapshot.docs) {
        final boothData = doc.data();
        boothData['id'] = doc.id; // ドキュメントIDを追加
        booths.add(boothData);
      }
      
      print('ブース情報を取得しました: ${booths.length}件');
      return booths;
    } catch (e) {
      print('ブース情報の取得中にエラーが発生しました: $e');
      return [];
    }
  }

  /// 特定のブース情報を取得
  Future<Map<String, dynamic>?> getBoothInfo(String boothId) async {
    try {
      final doc = await _firestore.collection('booths').doc(boothId).get();
      if (doc.exists) {
        final boothData = doc.data()!;
        boothData['id'] = doc.id;
        return boothData;
      }
      return null;
    } catch (e) {
      print('ブース情報の取得中にエラーが発生しました: $e');
      return null;
    }
  }

  /// テスト用のブース情報をFirebaseに保存
  Future<void> initializeBoothData() async {
    try {
      print('=== ブース情報の初期化を開始 ===');
      
      // ブースA1 (FSC-BP104D)
      await saveBoothInfo('FSC-BP104D', {
        'displayName': 'TechInnovate 2024',
        'company': '株式会社テックイノベーション',
        'description': 'AI・IoT技術で未来を創造する最先端企業です。次世代スマートデバイスから産業用IoTソリューションまで、幅広い革新的な製品を展示しています。',
        'products': [
          'スマートビーコン FSC-BP104D',
          'AIコンパニオンロボット',
          '産業用IoTセンサー',
          'リアルタイム位置追跡システム',
          'スマートホーム統合プラットフォーム',
        ],
        'contactEmail': 'info@tech-innovate.jp',
        'website': 'https://tech-innovate.jp',
        'features': [
          '業界最高精度の位置検知技術',
          'AI搭載による自動最適化',
          '低消費電力設計',
          '24時間365日の技術サポート',
          '導入実績500社以上',
        ],
        'type': 'booth',
        'x': 80,
        'y': 150,
        'name': 'ブースA1 (FSC-BP104D)',
      });

      // ブースA2
      await saveBoothInfo('Booth-A2', {
        'displayName': 'デジタルライフ 2024',
        'company': '株式会社デジタルライフソリューションズ',
        'description': '日常生活をより便利で快適にするスマートホーム・デジタルソリューションの総合企業です。IoTデバイスから統合プラットフォームまで、家庭のデジタル化を包括的にサポートします。',
        'products': [
          'スマートホーム統合システム',
          '音声制御アシスタント',
          'IoTセンサーネットワーク',
          'スマート家電連携アプリ',
          'エネルギー管理ダッシュボード',
        ],
        'contactEmail': 'contact@digital-life.co.jp',
        'website': 'https://digital-life.co.jp',
        'features': [
          '直感的な音声・ジェスチャー操作',
          'Amazon Alexa・Google Assistant連携',
          '業界最高レベルのセキュリティ',
          '24時間365日サポート',
          '設置から運用まで一括サポート',
        ],
        'type': 'booth',
        'x': 200,
        'y': 150,
        'name': 'ブースA2',
      });

      // ブースA3
      await saveBoothInfo('Booth-A3', {
        'displayName': 'グリーンテック ソリューション',
        'company': '環境テクノロジー株式会社',
        'description': '持続可能な社会を実現する環境技術のパイオニア企業です。太陽光発電からスマートグリッド、環境データ分析まで、地球環境保護と経済効果を両立するソリューションを提供しています。',
        'products': [
          '次世代ソーラー発電システム',
          'スマートグリッド制御システム',
          'AI環境予測・分析プラットフォーム',
          'カーボンニュートラル支援ツール',
          '企業向け環境データダッシュボード',
        ],
        'contactEmail': 'info@green-tech.co.jp',
        'website': 'https://green-tech.co.jp',
        'features': [
          'CO2削減効果最大85%を実現',
          '発電効率従来比40%向上',
          '環境省・経産省認定技術',
          '導入企業1,500社突破',
          '投資回収期間平均3.2年',
        ],
        'type': 'booth',
        'x': 320,
        'y': 150,
        'name': 'ブースA3',
      });

      // ブースB1
      await saveBoothInfo('Booth-B1', {
        'displayName': 'HealthTech Innovation',
        'company': '株式会社ヘルステックイノベーション',
        'description': '医療・ヘルスケア分野におけるデジタル変革を推進する企業です。AI診断技術からウェアラブルデバイス、遠隔医療ソリューションまで、最先端の医療技術を展示しています。',
        'products': [
          'AI画像診断システム',
          'スマートウェアラブルデバイス',
          '遠隔診療プラットフォーム',
          '健康管理アプリケーション',
          '医療データ分析ツール',
        ],
        'contactEmail': 'info@healthtech-innovation.jp',
        'website': 'https://healthtech-innovation.jp',
        'features': [
          '医師監修の高精度AI診断',
          '24時間健康モニタリング',
          '厚生労働省認証取得',
          '全国200病院導入実績',
          'プライバシー完全保護',
        ],
        'type': 'booth',
        'x': 80,
        'y': 250,
        'name': 'ブースB1',
      });

      // ブースB2
      await saveBoothInfo('Booth-B2', {
        'displayName': 'SmartEducation 2024',
        'company': '株式会社エデュケーショナルAI',
        'description': '教育現場のデジタル化を支援する次世代教育プラットフォームを提供しています。AI個別指導システムから学習データ分析まで、一人ひとりに最適化された学習環境を実現します。',
        'products': [
          'AI個別指導システム',
          'オンライン授業プラットフォーム',
          '学習進捗分析ダッシュボード',
          'VR・AR教材コンテンツ',
          '多言語対応学習支援ツール',
        ],
        'contactEmail': 'contact@edu-ai.co.jp',
        'website': 'https://smarteducation-ai.co.jp',
        'features': [
          '一人ひとりに最適化された学習',
          '全国1,000校導入実績',
          '学習効果30%向上を実証',
          '文部科学省推奨システム',
          '多言語対応（10カ国語）',
        ],
        'type': 'booth',
        'x': 200,
        'y': 250,
        'name': 'ブースB2',
      });

      // その他のブース（基本情報のみ）
      final List<Map<String, dynamic>> basicBooths = [
        {'id': 'Booth-B3', 'x': 320, 'y': 250, 'name': 'ブースB3'},
        {'id': 'Booth-C1', 'x': 80, 'y': 350, 'name': 'ブースC1'},
        {'id': 'Booth-C2', 'x': 200, 'y': 350, 'name': 'ブースC2'},
        {'id': 'Booth-C3', 'x': 320, 'y': 350, 'name': 'ブースC3'},
      ];

      for (final booth in basicBooths) {
        await saveBoothInfo(booth['id'] as String, {
          'displayName': booth['name'] as String,
          'company': '出展企業',
          'description': '詳細情報は準備中です。',
          'products': ['準備中'],
          'contactEmail': 'info@example.com',
          'website': 'https://example.com',
          'features': ['準備中'],
          'type': 'booth',
          'x': booth['x'] as int,
          'y': booth['y'] as int,
          'name': booth['name'] as String,
        });
      }

      print('=== ブース情報の初期化が完了しました ===');
    } catch (e) {
      print('ブース情報の初期化中にエラーが発生しました: $e');
    }
  }

  /// 見込み客リストを取得
  Future<List<Map<String, dynamic>>> getProspectList() async {
    try {
      print('=== 見込み客リストの取得開始 ===');
      
      final today = DateTime.now();
      final dateString = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      
      // 今日の全ビーコンデータを取得
      final allDevices = await _firestore
          .collection('beacon_counts')
          .doc(dateString)
          .collection('devices')
          .get();
      
      print('取得したデバイス数: ${allDevices.docs.length}');
      
      // 見込み客の条件を満たすユーザーを抽出
      final prospects = <String, Map<String, dynamic>>{};
      
      for (final device in allDevices.docs) {
        final deviceData = device.data();
        final visitors = deviceData['visitors'] as List<dynamic>?;
        final boothId = device.id;
        final boothName = deviceData['deviceName'] ?? boothId;
        
        if (visitors == null || visitors.isEmpty) continue;
        
        print('デバイス $boothId の来場者数: ${visitors.length}');
        
        // ユーザーごとに時系列で処理
        final List<Map<String, dynamic>> normalized = visitors
            .whereType<Map<String, dynamic>>()
            .map((v) => {
                  ...v,
                  'timestamp': (v['timestamp'] is Timestamp)
                      ? (v['timestamp'] as Timestamp).toDate()
                      : DateTime.tryParse(v['timestamp']?.toString() ?? '') ?? DateTime.now(),
                  'eventType': (v['eventType'] ?? 'visit').toString(),
                })
            .toList()
          ..sort((a, b) => (a['timestamp'] as DateTime).compareTo(b['timestamp'] as DateTime));
        
        for (final v in normalized) {
          final userId = v['userId'] as String?;
          if (userId == null) continue;
          
          if (!prospects.containsKey(userId)) {
            prospects[userId] = {
              'userId': userId,
              'visits': <Map<String, dynamic>>[],
              'boothVisitEvents': <String, int>{}, // boothId -> visitイベント回数
              'boothLastTimestamp': <String, DateTime>{},
              'boothLastVisitTs': <String, DateTime>{},
              'totalTime': 0,
            };
          }
          final u = prospects[userId]!;
          (u['visits'] as List<Map<String, dynamic>>).add({
            'boothId': boothId,
            'timestamp': v['timestamp'],
            'boothName': boothName,
            'eventType': v['eventType'],
            'totalTime': v['totalTime'] ?? 0,
          });
          
          // 個別レコードにtotalTimeがあれば保持（最大値を採用）
          final recordTotalTime = v['totalTime'] as int? ?? 0;
          if (recordTotalTime > (u['totalTime'] as int)) {
            u['totalTime'] = recordTotalTime;
          }
          
          // 再訪問カウントは eventType == 'visit' のみ対象（同一ブースで30秒以上間隔が空いた場合のみカウント）
          if (v['eventType'] == 'visit') {
            final lastVisitMap = (u['boothLastVisitTs'] as Map<String, DateTime>);
            final prev = lastVisitMap[boothId];
            final current = v['timestamp'] as DateTime;
            if (prev == null || current.difference(prev) >= const Duration(seconds: 30)) {
              final map = (u['boothVisitEvents'] as Map<String, int>);
              map[boothId] = (map[boothId] ?? 0) + 1;
            } else {
              print('短時間の重複visitを無視: $boothId (${current.difference(prev).inSeconds}秒差)');
            }
            lastVisitMap[boothId] = current;
          }
        }
      }
      
      // 見込み客の条件をチェック
      final qualifiedProspects = <Map<String, dynamic>>[];
      
      for (final u in prospects.values) {
        final visits = (u['visits'] as List<Map<String, dynamic>>);
        final byBoothCounts = (u['boothVisitEvents'] as Map<String, int>);
        final totalTime = (u['totalTime'] as int);
        
        final bool hasLongStayEvent = visits.any((e) => e['eventType'] == 'long_stay');
        // 再訪問 + 5分以上滞在（またはlong_stayイベント）の両方を満たす場合のみ見込み客
        final hasRevisit = byBoothCounts.values.any((c) => c >= 2);
        final hasLongStay = totalTime >= 5 || hasLongStayEvent;
        
        print('ユーザー ${u['userId']}: 再訪問=$hasRevisit, 長時間滞在=$hasLongStay, 総時間=${totalTime}分');
        
        if (hasRevisit && hasLongStay) {
          final visitorInfo = await _getVisitorInfo(u['userId']);
          if (visitorInfo != null) {
            final int visitEventCount = visits.where((e) => e['eventType'] == 'visit').length;
            qualifiedProspects.add({
              ...visitorInfo,
              'totalTime': totalTime,
              'visitCount': visitEventCount,
              'revisitCount': byBoothCounts.values.where((c) => c >= 2).length,
              'boothVisits': byBoothCounts.keys.toList(),
              'lastVisit': visits.isNotEmpty ? visits.last['timestamp'] : null,
              'hasLongStay': hasLongStay,
              'hasRevisit': hasRevisit,
            });
          }
        }
      }
      
      qualifiedProspects.sort((a, b) => (b['totalTime'] as int).compareTo(a['totalTime'] as int));
      print('=== 見込み客リストの取得完了: ${qualifiedProspects.length}件 ===');
      return qualifiedProspects;
      
    } catch (e) {
      print('見込み客リストの取得中にエラーが発生しました: $e');
      return [];
    }
  }
  
  /// 来場者情報を取得
  Future<Map<String, dynamic>?> _getVisitorInfo(String userId) async {
    try {
      final visitorDoc = await _firestore.collection('visitors').doc(userId).get();
      if (visitorDoc.exists) {
        return {
          'id': userId,
          ...visitorDoc.data()!,
        };
      }
      return null;
    } catch (e) {
      print('来場者情報の取得エラー: $e');
      return null;
    }
  }

  /// 全来場者リストを取得（見込み客条件に関係なく）
  Future<List<Map<String, dynamic>>> getAllVisitors({String? targetBoothId}) async {
    try {
      print('=== 全来場者リストの取得開始 ===');
      
      final today = DateTime.now();
      final dateString = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      
      // 今日の全ビーコンデータを取得
      final allDevices = await _firestore
          .collection('beacon_counts')
          .doc(dateString)
          .collection('devices')
          .get();
      
      print('取得したデバイス数: ${allDevices.docs.length}');
      
      // 全来場者を抽出
      final allVisitors = <String, Map<String, dynamic>>{};
      
      for (final device in allDevices.docs) {
        final deviceData = device.data();
        final visitors = deviceData['visitors'] as List<dynamic>?;
        final boothId = device.id;
        final boothName = deviceData['deviceName'] ?? boothId;
        
        if (visitors == null || visitors.isEmpty) continue;
        
        print('デバイス $boothId の来場者数: ${visitors.length}');
        
        // ユーザーごとに時系列で処理
        final List<Map<String, dynamic>> normalized = visitors
            .whereType<Map<String, dynamic>>()
            .map((v) => {
                  ...v,
                  'timestamp': (v['timestamp'] is Timestamp)
                      ? (v['timestamp'] as Timestamp).toDate()
                      : DateTime.tryParse(v['timestamp']?.toString() ?? '') ?? DateTime.now(),
                  'eventType': (v['eventType'] ?? 'visit').toString(),
                })
            .toList()
          ..sort((a, b) => (a['timestamp'] as DateTime).compareTo(b['timestamp'] as DateTime));
        
        for (final v in normalized) {
          final userId = v['userId'] as String?;
          if (userId == null) continue;
          
          if (!allVisitors.containsKey(userId)) {
            allVisitors[userId] = {
              'userId': userId,
              'visits': <Map<String, dynamic>>[],
              'boothVisitEvents': <String, int>{}, // boothId -> visitイベント回数
              'boothLastTimestamp': <String, DateTime>{},
              'boothLastVisitTs': <String, DateTime>{},
              'totalTime': 0,
            };
          }
          final u = allVisitors[userId]!;
          (u['visits'] as List<Map<String, dynamic>>).add({
            'boothId': boothId,
            'timestamp': v['timestamp'],
            'boothName': boothName,
            'eventType': v['eventType'],
            'totalTime': v['totalTime'] ?? 0,
          });
          
          // 個別レコードにtotalTimeがあれば保持（最大値を採用）
          final recordTotalTime = v['totalTime'] as int? ?? 0;
          if (recordTotalTime > (u['totalTime'] as int)) {
            u['totalTime'] = recordTotalTime;
          }
          
          // 再訪問カウントは eventType == 'visit' のみ対象（同一ブースで30秒以上間隔が空いた場合のみカウント）
          if (v['eventType'] == 'visit') {
            final lastVisitMap = (u['boothLastVisitTs'] as Map<String, DateTime>);
            final prev = lastVisitMap[boothId];
            final current = v['timestamp'] as DateTime;
            if (prev == null || current.difference(prev) >= const Duration(seconds: 30)) {
              final map = (u['boothVisitEvents'] as Map<String, int>);
              map[boothId] = (map[boothId] ?? 0) + 1;
            } else {
              print('短時間の重複visitを無視: $boothId (${current.difference(prev).inSeconds}秒差)');
            }
            lastVisitMap[boothId] = current;
          }
        }
      }
      
      // 全来場者の情報を取得
      final visitorList = <Map<String, dynamic>>[];
      
      for (final u in allVisitors.values) {
        final visits = (u['visits'] as List<Map<String, dynamic>>);
        final byBoothCounts = (u['boothVisitEvents'] as Map<String, int>);
        final totalTime = (u['totalTime'] as int);
        // 対象ブースのみで再訪/長滞を判定（指定なしの場合は従来通り全ブース）
        final int targetVisitCount = targetBoothId != null
            ? (byBoothCounts[targetBoothId] ?? 0)
            : byBoothCounts.values.fold(0, (p, e) => p + e);
        final bool hasLongStayEvent = visits.any((e) => e['eventType'] == 'long_stay');
        final bool hasRevisit = targetBoothId != null
            ? targetVisitCount >= 2
            : byBoothCounts.values.any((c) => c >= 2);
        final hasLongStay = totalTime >= 5 || hasLongStayEvent;
        
        final visitorInfo = await _getVisitorInfo(u['userId']);
        if (visitorInfo != null) {
          final int visitEventCount = visits.where((e) => e['eventType'] == 'visit').length;
          final int targetVisitEventCount = targetBoothId != null
              ? visits.where((e) => e['eventType'] == 'visit' && e['boothId'] == targetBoothId).length
              : visitEventCount;
          visitorList.add({
            ...visitorInfo,
            'totalTime': totalTime,
            'visitCount': visitEventCount,
            'revisitCount': targetBoothId != null
                ? ((targetVisitCount >= 2) ? 1 : 0)
                : byBoothCounts.values.where((c) => c >= 2).length,
            'boothVisits': byBoothCounts.keys.toList(),
            'lastVisit': visits.isNotEmpty ? visits.last['timestamp'] : null,
            'hasLongStay': hasLongStay,
            'hasRevisit': hasRevisit,
            // 見込み客: 同一ブースで再訪 + 5分以上滞在
            'isProspect': hasRevisit && hasLongStay,
          });
        }
      }
      
      visitorList.sort((a, b) => (b['totalTime'] as int).compareTo(a['totalTime'] as int));
      print('=== 全来場者リストの取得完了: ${visitorList.length}件 ===');
      return visitorList;
      
    } catch (e) {
      print('全来場者リストの取得中にエラーが発生しました: $e');
      return [];
    }
  }

  /// ブース予約を保存
  Future<bool> saveBoothReservation(String userId, String boothId) async {
    try {
      print('=== ブース予約の保存開始: userId=$userId, boothId=$boothId ===');
      
      // 既に予約済みかチェック
      final isReserved = await checkReservation(userId, boothId);
      if (isReserved) {
        print('既に予約済みです');
        return false;
      }
      
      // 来場者の属性情報を取得
      final visitorData = await getVisitorData(userId);
      
      // 来場者データがない場合でも基本情報で予約を保存
      final reservationData = {
        'userId': userId,
        'boothId': boothId,
        'displayName': visitorData?['displayName'] ?? '来場者',
        'email': visitorData?['email'] ?? '未登録',
        'age': visitorData?['age'] ?? 0,
        'gender': visitorData?['gender'] ?? '未設定',
        'job': visitorData?['job'] ?? '未設定',
        'eventSource': visitorData?['eventSource'] ?? 'BLE検知',
        'interests': visitorData?['interests'] ?? [],
        'reservedAt': FieldValue.serverTimestamp(),
        'hasVisitorInfo': visitorData != null, // 来場者情報があるかのフラグ
      };
      
      // booth_reservationsコレクションに保存（ドキュメントIDは userId_boothId）
      final docId = '${userId}_$boothId';
      await _firestore.collection('booth_reservations').doc(docId).set(reservationData);
      
      print('=== ブース予約の保存完了 ===');
      print('来場者情報の有無: ${visitorData != null}');
      return true;
    } catch (e) {
      print('ブース予約の保存中にエラーが発生しました: $e');
      return false;
    }
  }

  /// 予約済みかチェック
  Future<bool> checkReservation(String userId, String boothId) async {
    try {
      final docId = '${userId}_$boothId';
      final doc = await _firestore.collection('booth_reservations').doc(docId).get();
      return doc.exists;
    } catch (e) {
      print('予約チェック中にエラーが発生しました: $e');
      return false;
    }
  }

  /// 特定ブースの予約情報を取得
  Future<List<Map<String, dynamic>>> getBoothReservations(String boothId) async {
    try {
      print('=== ブース予約情報の取得開始: boothId=$boothId ===');
      
      final querySnapshot = await _firestore
          .collection('booth_reservations')
          .where('boothId', isEqualTo: boothId)
          .get();
      
      final reservations = <Map<String, dynamic>>[];
      for (final doc in querySnapshot.docs) {
        final data = doc.data();
        reservations.add({
          ...data,
          'id': doc.id,
        });
      }
      
      print('=== ブース予約情報の取得完了: ${reservations.length}件 ===');
      return reservations;
    } catch (e) {
      print('ブース予約情報の取得中にエラーが発生しました: $e');
      return [];
    }
  }

  /// 全予約情報を取得
  Future<List<Map<String, dynamic>>> getAllReservations() async {
    try {
      print('=== 全予約情報の取得開始 ===');
      
      final querySnapshot = await _firestore.collection('booth_reservations').get();
      
      final reservations = <Map<String, dynamic>>[];
      for (final doc in querySnapshot.docs) {
        final data = doc.data();
        reservations.add({
          ...data,
          'id': doc.id,
        });
      }
      
      print('=== 全予約情報の取得完了: ${reservations.length}件 ===');
      return reservations;
    } catch (e) {
      print('全予約情報の取得中にエラーが発生しました: $e');
      return [];
    }
  }

  /// 企業属性統計を取得
  Future<Map<String, dynamic>> getCompanyAttributeStats() async {
    try {
      print('=== 企業属性統計の取得開始 ===');
      
      final visitors = await getAllVisitors();
      
      // 業種別集計
      final industryCount = <String, int>{};
      // 役職別集計
      final positionCount = <String, int>{};
      // 職業別集計
      final jobCount = <String, int>{};
      // 興味分野別集計
      final interestCount = <String, int>{};
      
      for (final visitor in visitors) {
        // 業種
        final industry = visitor['industry']?.toString() ?? '未設定';
        industryCount[industry] = (industryCount[industry] ?? 0) + 1;
        
        // 役職
        final position = visitor['position']?.toString() ?? '未設定';
        positionCount[position] = (positionCount[position] ?? 0) + 1;
        
        // 職業
        final job = visitor['job']?.toString() ?? '未設定';
        jobCount[job] = (jobCount[job] ?? 0) + 1;
        
        // 興味のある分野（複数選択可能なので各要素をカウント）
        final interests = visitor['interests'];
        if (interests != null && interests is List) {
          for (final interest in interests) {
            final interestStr = interest.toString();
            interestCount[interestStr] = (interestCount[interestStr] ?? 0) + 1;
          }
        }
      }
      
      print('業種別集計: $industryCount');
      print('役職別集計: $positionCount');
      print('職業別集計: $jobCount');
      print('興味分野別集計: $interestCount');
      
      return {
        'industry': industryCount,
        'position': positionCount,
        'job': jobCount,
        'interests': interestCount,
        'totalVisitors': visitors.length,
      };
    } catch (e) {
      print('企業属性統計の取得中にエラーが発生しました: $e');
      return {
        'industry': <String, int>{},
        'position': <String, int>{},
        'job': <String, int>{},
        'interests': <String, int>{},
        'totalVisitors': 0,
      };
    }
  }

  /// ブース別滞在時間を集計（実データ版）
  Future<Map<String, double>> getBoothStayTimeStats() async {
    try {
      print('=== ブース別滞在時間の集計開始 ===');
      final visitors = await getAllVisitors();
      final boothStayTimes = <String, List<int>>{}; // ブースID -> 滞在時間リスト（分）

      // ビーコンIDからブース名のマッピングを取得
      final booths = await getAllBooths();
      final boothNameMap = <String, String>{};
      for (final booth in booths) {
        if (booth['id'] != null) {
          boothNameMap[booth['id']] = booth['displayName'] ?? booth['name'] ?? booth['id'];
        }
      }

      // 各来場者のデータから滞在時間を集計
      for (final visitor in visitors) {
        // visitCountが2以上、またはtotalTimeが1分以上のデータを使用
        if ((visitor['visitCount'] as int? ?? 0) < 2 && (visitor['totalTime'] as int? ?? 0) < 1) {
          continue;
        }

        // ここでは簡易的に、totalTimeを訪問したブース数で割って配分する
        // 本来は時系列ログから詳細に計算すべきだが、現状のデータ構造に合わせて簡易実装
        final totalTime = visitor['totalTime'] as int? ?? 0;
        final visitedBooths = visitor['boothVisits'] as List<dynamic>? ?? [];
        
        if (totalTime > 0 && visitedBooths.isNotEmpty) {
          final timePerBooth = totalTime / visitedBooths.length;
          
          for (final boothId in visitedBooths) {
            final boothName = boothNameMap[boothId] ?? boothId;
            if (!boothStayTimes.containsKey(boothName)) {
              boothStayTimes[boothName] = [];
            }
            // 分単位で記録（切り上げ）
            boothStayTimes[boothName]!.add(timePerBooth.ceil());
          }
        }
      }

      // 平均値を計算
      final result = <String, double>{};
      boothStayTimes.forEach((boothName, times) {
        if (times.isNotEmpty) {
          final sum = times.fold(0, (prev, curr) => prev + curr);
          result[boothName] = sum / times.length;
        }
      });

      // 降順にソートして上位5件を返す
      final sortedEntries = result.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      
      final top5 = Map.fromEntries(sortedEntries.take(5));
      print('=== ブース別滞在時間の集計完了: $top5 ===');
      return top5;
    } catch (e) {
      print('滞在時間の集計中にエラーが発生しました: $e');
      return {};
    }
  }

  /// よくある移動パターンを集計（実データ版）
  Future<List<Map<String, dynamic>>> getMovementPatterns() async {
    try {
      print('=== 移動パターンの集計開始 ===');
      
      // 見込み客リストの抽出ロジックを流用して、詳細な訪問履歴を取得
      // getAllVisitorsだと時系列ログが失われている可能性があるため、getProspectListのロジックの一部を再利用
      
      final today = DateTime.now();
      final dateString = DateFormat('yyyy-MM-dd').format(today);
      
      // 今日の全ビーコンデータを取得
      final allDevices = await _firestore
          .collection('beacon_counts')
          .doc(dateString)
          .collection('devices')
          .get();
      
      // ユーザーごとの時系列ログを構築
      final userLogs = <String, List<Map<String, dynamic>>>{}; // userId -> [{boothId, timestamp}]
      
      // ビーコンIDからブース名のマッピングを取得
      final booths = await getAllBooths();
      final boothNameMap = <String, String>{};
      for (final booth in booths) {
        if (booth['id'] != null) {
          boothNameMap[booth['id']] = booth['displayName'] ?? booth['name'] ?? booth['id'];
        }
      }

      for (final device in allDevices.docs) {
        final deviceData = device.data();
        final visitors = deviceData['visitors'] as List<dynamic>?;
        final boothId = device.id;
        
        if (visitors == null) continue;
        
        for (final v in visitors) {
          if (v is Map<String, dynamic>) {
            final userId = v['userId'] as String?;
            if (userId == null) continue;
            
            // timestampの型変換
            DateTime? ts;
            if (v['timestamp'] is Timestamp) {
              ts = (v['timestamp'] as Timestamp).toDate();
            } else if (v['timestamp'] is String) {
              ts = DateTime.tryParse(v['timestamp']);
            }
            
            if (ts == null) continue;
            
            if (!userLogs.containsKey(userId)) {
              userLogs[userId] = [];
            }
            
            userLogs[userId]!.add({
              'boothId': boothId,
              'timestamp': ts,
            });
          }
        }
      }
      
      // パターン集計
      final patternCounts = <String, int>{};
      
      for (final userId in userLogs.keys) {
        final logs = userLogs[userId]!;
        // 時系列でソート
        logs.sort((a, b) => (a['timestamp'] as DateTime).compareTo(b['timestamp'] as DateTime));
        
        // 重複を除去しつつ遷移を抽出（A -> A -> B は A -> B とする）
        String? lastBoothId;
        for (int i = 0; i < logs.length; i++) {
          final currentBoothId = logs[i]['boothId'];
          
          if (lastBoothId != null && lastBoothId != currentBoothId) {
            // 遷移発生
            final fromName = boothNameMap[lastBoothId] ?? lastBoothId;
            final toName = boothNameMap[currentBoothId] ?? currentBoothId;
            final patternKey = '$fromName -> $toName';
            
            patternCounts[patternKey] = (patternCounts[patternKey] ?? 0) + 1;
          }
          
          lastBoothId = currentBoothId;
        }
      }
      
      // 集計結果を整形
      final result = <Map<String, dynamic>>[];
      patternCounts.forEach((key, count) {
        final parts = key.split(' -> ');
        if (parts.length == 2) {
          result.add({
            'from': parts[0],
            'to': parts[1],
            'count': count,
          });
        }
      });
      
      // カウント順にソートして上位5件を返す
      result.sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));
      
      final top5 = result.take(5).toList();
      print('=== 移動パターンの集計完了: $top5 ===');
      return top5;
      
    } catch (e) {
      print('移動パターンの集計中にエラーが発生しました: $e');
      return [];
    }
  }

  /// 現在アクティブな展示会レイアウトを取得
  Future<Map<String, dynamic>?> getActiveEventLayout() async {
    try {
      print('=== アクティブな展示会レイアウトの取得開始 ===');
      
      final querySnapshot = await _firestore
          .collection('event_layouts')
          .where('active', isEqualTo: true)
          .limit(1)
          .get();
      
      if (querySnapshot.docs.isEmpty) {
        print('アクティブな展示会レイアウトが見つかりません');
        return null;
      }
      
      final doc = querySnapshot.docs.first;
      final data = doc.data();
      data['id'] = doc.id;
      
      print('アクティブな展示会レイアウトを取得: ${data['eventName']}');
      return data;
    } catch (e) {
      print('展示会レイアウトの取得中にエラーが発生しました: $e');
      return null;
    }
  }

  /// 特定の展示会のマップ要素を取得
  Future<List<Map<String, dynamic>>> getMapElements(String eventId) async {
    try {
      print('=== マップ要素の取得開始: eventId=$eventId ===');
      
      final querySnapshot = await _firestore
          .collection('map_elements')
          .where('eventId', isEqualTo: eventId)
          .get();
      
      final elements = <Map<String, dynamic>>[];
      for (final doc in querySnapshot.docs) {
        final data = doc.data();
        data['id'] = doc.id;
        elements.add(data);
      }
      
      // zIndexでソート（クライアント側）
      elements.sort((a, b) {
        final aIndex = a['zIndex'] as int? ?? 0;
        final bIndex = b['zIndex'] as int? ?? 0;
        return aIndex.compareTo(bIndex);
      });
      
      print('マップ要素を取得: ${elements.length}件');
      return elements;
    } catch (e) {
      print('マップ要素の取得中にエラーが発生しました: $e');
      return [];
    }
  }

  /// マップレイアウトを初期化（現在のハードコードされたレイアウトをDBに保存）
  Future<void> initializeMapLayout() async {
    try {
      print('=== マップレイアウトの初期化開始 ===');
      
      // まず既存のアクティブなレイアウトを非アクティブにする
      final existingLayouts = await _firestore
          .collection('event_layouts')
          .where('active', isEqualTo: true)
          .get();
      
      final batch = _firestore.batch();
      for (final doc in existingLayouts.docs) {
        batch.update(doc.reference, {'active': false});
      }
      await batch.commit();
      
      // 新しい展示会レイアウトを作成
      final eventRef = _firestore.collection('event_layouts').doc('event_2025_default');
      await eventRef.set({
        'eventName': '2025年デフォルト展示会',
        'eventDate': '2025-01-01',
        'mapWidth': 700,
        'mapHeight': 500,
        'backgroundColor': '#FAFAFA',
        'gridSize': 10,
        'active': true,
        'createdAt': FieldValue.serverTimestamp(),
      });
      
      print('展示会レイアウトを作成: event_2025_default');
      
      // マップ要素を作成
      final mapElements = <Map<String, dynamic>>[
        // 背景
        {
          'eventId': 'event_2025_default',
          'type': 'background',
          'shape': 'rect',
          'x': 0,
          'y': 0,
          'width': 700,
          'height': 500,
          'color': '#FAFAFA',
          'label': '背景',
          'zIndex': 0,
        },
        
        // 会場の外枠
        {
          'eventId': 'event_2025_default',
          'type': 'wall',
          'shape': 'rect',
          'x': 20,
          'y': 20,
          'width': 660,
          'height': 460,
          'color': '#BDBDBD',
          'strokeWidth': 2,
          'filled': false,
          'label': '会場外枠',
          'zIndex': 1,
        },
        
        // エントランス
        {
          'eventId': 'event_2025_default',
          'type': 'entrance',
          'shape': 'rect',
          'x': 80,
          'y': 20,
          'width': 40,
          'height': 20,
          'color': '#A1887F',
          'label': '正面エントランス',
          'zIndex': 2,
        },
        {
          'eventId': 'event_2025_default',
          'type': 'entrance',
          'shape': 'rect',
          'x': 580,
          'y': 20,
          'width': 40,
          'height': 20,
          'color': '#A1887F',
          'label': 'サイドエントランス',
          'zIndex': 2,
        },
        
        // 横通路
        {
          'eventId': 'event_2025_default',
          'type': 'corridor',
          'shape': 'rect',
          'x': 20,
          'y': 80,
          'width': 660,
          'height': 30,
          'color': '#EEEEEE',
          'label': '横通路1',
          'zIndex': 1,
        },
        {
          'eventId': 'event_2025_default',
          'type': 'corridor',
          'shape': 'rect',
          'x': 20,
          'y': 200,
          'width': 660,
          'height': 30,
          'color': '#EEEEEE',
          'label': '横通路2',
          'zIndex': 1,
        },
        {
          'eventId': 'event_2025_default',
          'type': 'corridor',
          'shape': 'rect',
          'x': 20,
          'y': 320,
          'width': 660,
          'height': 30,
          'color': '#EEEEEE',
          'label': '横通路3',
          'zIndex': 1,
        },
        
        // 縦通路
        {
          'eventId': 'event_2025_default',
          'type': 'corridor',
          'shape': 'rect',
          'x': 140,
          'y': 20,
          'width': 30,
          'height': 460,
          'color': '#EEEEEE',
          'label': '縦通路1',
          'zIndex': 1,
        },
        {
          'eventId': 'event_2025_default',
          'type': 'corridor',
          'shape': 'rect',
          'x': 240,
          'y': 20,
          'width': 30,
          'height': 460,
          'color': '#EEEEEE',
          'label': '縦通路2',
          'zIndex': 1,
        },
        {
          'eventId': 'event_2025_default',
          'type': 'corridor',
          'shape': 'rect',
          'x': 540,
          'y': 20,
          'width': 30,
          'height': 460,
          'color': '#EEEEEE',
          'label': '縦通路3',
          'zIndex': 1,
        },
      ];
      
      // バッチで保存
      final elementBatch = _firestore.batch();
      int elementIndex = 0;
      for (final element in mapElements) {
        final elementRef = _firestore.collection('map_elements').doc('element_${elementIndex++}');
        elementBatch.set(elementRef, element);
      }
      await elementBatch.commit();
      
      print('=== マップレイアウトの初期化完了: ${mapElements.length}件の要素を保存 ===');
    } catch (e) {
      print('マップレイアウトの初期化中にエラーが発生しました: $e');
      throw Exception('マップレイアウトの初期化に失敗しました: $e');
    }
  }

  /// 新しい展示会レイアウトを作成
  Future<String?> createEventLayout(Map<String, dynamic> layoutData) async {
    try {
      print('=== 新しい展示会レイアウトの作成開始 ===');
      
      final docRef = await _firestore.collection('event_layouts').add({
        ...layoutData,
        'createdAt': FieldValue.serverTimestamp(),
      });
      
      print('展示会レイアウトを作成: ${docRef.id}');
      return docRef.id;
    } catch (e) {
      print('展示会レイアウトの作成中にエラーが発生しました: $e');
      return null;
    }
  }

  /// マップ要素を追加
  Future<String?> addMapElement(Map<String, dynamic> elementData) async {
    try {
      final docRef = await _firestore.collection('map_elements').add(elementData);
      print('マップ要素を追加: ${docRef.id}');
      return docRef.id;
    } catch (e) {
      print('マップ要素の追加中にエラーが発生しました: $e');
      return null;
    }
  }

  /// マップ要素を更新
  Future<bool> updateMapElement(String elementId, Map<String, dynamic> updates) async {
    try {
      await _firestore.collection('map_elements').doc(elementId).update(updates);
      print('マップ要素を更新: $elementId');
      return true;
    } catch (e) {
      print('マップ要素の更新中にエラーが発生しました: $e');
      return false;
    }
  }

  /// マップ要素を削除
  Future<bool> deleteMapElement(String elementId) async {
    try {
      await _firestore.collection('map_elements').doc(elementId).delete();
      print('マップ要素を削除: $elementId');
      return true;
    } catch (e) {
      print('マップ要素の削除中にエラーが発生しました: $e');
      return false;
    }
  }

  /// 展示会レイアウトをアクティブに設定
  Future<bool> setActiveEventLayout(String eventId) async {
    try {
      print('=== 展示会レイアウトのアクティブ化開始: $eventId ===');
      
      final batch = _firestore.batch();
      
      // すべてのレイアウトを非アクティブにする
      final allLayouts = await _firestore.collection('event_layouts').get();
      for (final doc in allLayouts.docs) {
        batch.update(doc.reference, {'active': false});
      }
      
      // 指定されたレイアウトをアクティブにする
      final targetRef = _firestore.collection('event_layouts').doc(eventId);
      batch.update(targetRef, {'active': true});
      
      await batch.commit();
      
      print('=== 展示会レイアウトをアクティブ化完了 ===');
      return true;
    } catch (e) {
      print('展示会レイアウトのアクティブ化中にエラーが発生しました: $e');
      return false;
    }
  }

  // ========================
  // ブースサイズ管理
  // ========================

  /// ブースのサイズと形状を更新
  Future<bool> updateBoothSize({
    required String boothId,
    double? width,
    double? height,
    String? shape,
  }) async {
    try {
      print('=== ブースサイズの更新開始: $boothId ===');
      
      final updateData = <String, dynamic>{};
      if (width != null) updateData['width'] = width;
      if (height != null) updateData['height'] = height;
      if (shape != null) updateData['shape'] = shape;
      
      await _firestore
          .collection('booths')
          .doc(boothId)
          .update(updateData);
      
      print('ブースサイズを更新: $boothId - $updateData');
      return true;
    } catch (e) {
      print('ブースサイズの更新中にエラーが発生しました: $e');
      return false;
    }
  }

  /// すべてのブースにデフォルトのサイズ情報を追加
  Future<void> initializeBoothSizes() async {
    try {
      print('=== ブースサイズの初期化開始 ===');
      
      final booths = await _firestore.collection('booths').get();
      final batch = _firestore.batch();
      
      for (final doc in booths.docs) {
        final data = doc.data();
        
        // サイズ情報がない場合のみ追加
        if (!data.containsKey('width') || !data.containsKey('height') || !data.containsKey('shape')) {
          batch.update(doc.reference, {
            'width': data['width'] ?? 30,
            'height': data['height'] ?? 30,
            'shape': data['shape'] ?? 'circle',
          });
        }
      }
      
      await batch.commit();
      print('=== ブースサイズの初期化完了: ${booths.docs.length}件 ===');
    } catch (e) {
      print('ブースサイズの初期化中にエラーが発生しました: $e');
      throw Exception('ブースサイズの初期化に失敗しました: $e');
    }
  }

  /// 特定のブースに異なるサイズを設定するサンプル
  Future<void> setCustomBoothSizes() async {
    try {
      print('=== カスタムブースサイズの設定開始 ===');
      
      // サンプル: ブースごとに異なるサイズと形状を設定
      final customSizes = {
        'FSC-BP104D': {
          'width': 50,
          'height': 60,
          'shape': 'rect', // 長方形
        },
        'Booth-A2': {
          'width': 40,
          'height': 40,
          'shape': 'square', // 正方形
        },
        'Booth-A3': {
          'width': 45,
          'height': 45,
          'shape': 'circle', // 円形（widthが直径になる）
        },
        'Booth-B1': {
          'width': 35,
          'height': 50,
          'shape': 'rect',
        },
        'Booth-B2': {
          'width': 60,
          'height': 40,
          'shape': 'rect', // 横長の長方形
        },
      };
      
      int successCount = 0;
      int skipCount = 0;
      
      for (final entry in customSizes.entries) {
        final boothId = entry.key;
        final sizeData = entry.value;
        
        final docRef = _firestore.collection('booths').doc(boothId);
        
        // ドキュメントの存在確認
        final docSnapshot = await docRef.get();
        
        if (docSnapshot.exists) {
          // 存在する場合は更新
          await docRef.update(sizeData);
          print('✅ ブースサイズを更新: $boothId - $sizeData');
          successCount++;
        } else {
          // 存在しない場合はスキップ
          print('⚠️ ブースが存在しないためスキップ: $boothId');
          skipCount++;
        }
      }
      
      print('=== カスタムブースサイズの設定完了 ===');
      print('成功: $successCount件, スキップ: $skipCount件');
      
      if (skipCount > 0) {
        throw Exception('一部のブースが見つかりませんでした。先に「ブース情報初期化」を実行してください。(成功: $successCount件, スキップ: $skipCount件)');
      }
    } catch (e) {
      print('カスタムブースサイズの設定中にエラーが発生しました: $e');
      rethrow;
    }
  }

  // ========================
  // 展示会場レイアウト初期化
  // ========================

  /// 展示会場レイアウトの初期化（2025年発表会）
  Future<void> initializeExhibitionLayout() async {
    try {
      print('=== 展示会場レイアウトの初期化開始 ===');

      // ステップ0: 既存のアクティブなレイアウトを無効化
      final existingLayouts = await _firestore
          .collection('event_layouts')
          .where('active', isEqualTo: true)
          .get();
      
      final deactivateBatch = _firestore.batch();
      for (final doc in existingLayouts.docs) {
        deactivateBatch.update(doc.reference, {'active': false});
      }
      await deactivateBatch.commit();
      print('既存のアクティブレイアウトを無効化: ${existingLayouts.docs.length}件');

      // ステップ1: イベントレイアウトのサイズを更新（縦長）
      final eventRef = _firestore.collection('event_layouts').doc('event_2025_exhibition');
      await eventRef.set({
        'eventName': '2025年 プロジェクト演習発表会',
        'eventDate': '2025-12-06',
        'mapWidth': 450, // 右側の机が収まるように拡大
        'mapHeight': 700,
        'backgroundColor': '#FAFAFA',
        'gridSize': 10,
        'active': true,
        'createdAt': FieldValue.serverTimestamp(),
      });
      print('イベントレイアウトを作成: 450x700（縦長）');

      // ステップ2: 既存のマップ要素をすべて削除
      final existingElements = await _firestore.collection('map_elements').get();
      final deleteBatch = _firestore.batch();
      for (final doc in existingElements.docs) {
        deleteBatch.delete(doc.reference);
      }
      await deleteBatch.commit();
      print('既存のマップ要素を削除: ${existingElements.docs.length}件');

      // ステップ3: 新しい展示会場レイアウトのマップ要素を作成
      final exhibitionElements = <Map<String, dynamic>>[
        // 背景
        {
          'eventId': 'event_2025_exhibition',
          'type': 'background',
          'shape': 'rect',
          'x': 0,
          'y': 0,
          'width': 450,
          'height': 700,
          'color': '#FAFAFA',
          'label': '背景',
          'zIndex': 0,
        },

        // 会場の外枠
        {
          'eventId': 'event_2025_exhibition',
          'type': 'wall',
          'shape': 'rect',
          'x': 10,
          'y': 10,
          'width': 430,
          'height': 680,
          'color': '#9E9E9E',
          'strokeWidth': 2,
          'filled': false,
          'label': '会場外枠',
          'zIndex': 1,
        },

        // === 机（5つ）===
        // A15: 左端の細長い縦長の机（他の机の2倍の長さ、幅は1/2）
        {
          'eventId': 'event_2025_exhibition',
          'type': 'wall',
          'shape': 'rect',
          'x': 30,
          'y': 100,
          'width': 40,
          'height': 500,
          'color': '#B0BEC5',
          'label': '机A15',
          'zIndex': 3,
        },

        // A08: 中央左上の机
        {
          'eventId': 'event_2025_exhibition',
          'type': 'wall',
          'shape': 'rect',
          'x': 130,
          'y': 60,
          'width': 80,
          'height': 180,
          'color': '#B0BEC5',
          'label': '机A08',
          'zIndex': 3,
        },

        // A09: 中央左下の机
        {
          'eventId': 'event_2025_exhibition',
          'type': 'wall',
          'shape': 'rect',
          'x': 130,
          'y': 300,
          'width': 80,
          'height': 180,
          'color': '#B0BEC5',
          'label': '机A09',
          'zIndex': 3,
        },

        // A14: 右上の机
        {
          'eventId': 'event_2025_exhibition',
          'type': 'wall',
          'shape': 'rect',
          'x': 280,
          'y': 60,
          'width': 80,
          'height': 180,
          'color': '#B0BEC5',
          'label': '机A14',
          'zIndex': 3,
        },

        // A13: 右下の机
        {
          'eventId': 'event_2025_exhibition',
          'type': 'wall',
          'shape': 'rect',
          'x': 280,
          'y': 300,
          'width': 80,
          'height': 180,
          'color': '#B0BEC5',
          'label': '机A13',
          'zIndex': 3,
        },

        // === 通路（縦）===
        // 左の縦通路（A15とA08/A09の間）
        {
          'eventId': 'event_2025_exhibition',
          'type': 'corridor',
          'shape': 'rect',
          'x': 70,
          'y': 50,
          'width': 60,
          'height': 600,
          'color': '#EEEEEE',
          'label': '左縦通路',
          'zIndex': 1,
        },

        // 中央の縦通路（A08/A09とA14/A13の間）
        {
          'eventId': 'event_2025_exhibition',
          'type': 'corridor',
          'shape': 'rect',
          'x': 210,
          'y': 50,
          'width': 70,
          'height': 600,
          'color': '#EEEEEE',
          'label': '中央縦通路',
          'zIndex': 1,
        },

        // === 通路（横）===
        // 横通路1（A08とA09の間）
        {
          'eventId': 'event_2025_exhibition',
          'type': 'corridor',
          'shape': 'rect',
          'x': 130,
          'y': 240,
          'width': 230,
          'height': 60,
          'color': '#EEEEEE',
          'label': '横通路1',
          'zIndex': 1,
        },
      ];

      final elementBatch = _firestore.batch();
      int elementIndex = 0;
      for (final element in exhibitionElements) {
        final elementRef = _firestore.collection('map_elements').doc('exhibition_element_${elementIndex++}');
        elementBatch.set(elementRef, element);
      }
      await elementBatch.commit();
      print('展示会場レイアウトのマップ要素を作成: ${exhibitionElements.length}件');

      print('=== 展示会場レイアウトの初期化完了 ===');
    } catch (e) {
      print('展示会場レイアウトの初期化中にエラーが発生しました: $e');
      throw Exception('展示会場レイアウトの初期化に失敗しました: $e');
    }
  }

  /// 展示会場の全ブース座標を設定
  Future<void> setupExhibitionBooths() async {
    try {
      print('=== 展示会場ブース座標の設定開始 ===');

      // ステップ1: 既存のブースをすべて削除
      final existingBooths = await _firestore.collection('booths').get();
      final batch = _firestore.batch();
      for (final doc in existingBooths.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
      print('既存のブースを削除: ${existingBooths.docs.length}件');

      // 展示会場レイアウトに基づくブース座標マッピング
      // ブースは机と机の間の通路に配置（PDFの画像に基づく）
      final boothPositions = {
        // 左の通路（A15とA08/A09の間）- 上から下へ
        'Booth-A15': {'x': 90, 'y': 130, 'name': 'ブースA15', 'width': 25, 'height': 25},
        'Booth-A14': {'x': 90, 'y': 200, 'name': 'ブースA14', 'width': 25, 'height': 25},
        'Booth-A13': {'x': 90, 'y': 400, 'name': 'ブースA13', 'width': 25, 'height': 25},
        'Booth-A12': {'x': 90, 'y': 470, 'name': 'ブースA12', 'width': 25, 'height': 25},

        // 中央上の通路（A08とA14の間）- 上から下へ
        'FSC-BP103B': {'x': 240, 'y': 130, 'name': 'ブースA08', 'width': 25, 'height': 25},  // A08（ビーコン2）
        'FSC-BP104D': {'x': 240, 'y': 190, 'name': 'ブースA09', 'width': 25, 'height': 25},  // A09（ビーコン1）

        // 中央下の通路（A09とA13の間）- 上から下へ
        'Booth-A10': {'x': 240, 'y': 400, 'name': 'ブースA10', 'width': 25, 'height': 25},
        'Booth-A11': {'x': 240, 'y': 460, 'name': 'ブースA11', 'width': 25, 'height': 25},
      };

      final addBatch = _firestore.batch();
      for (final entry in boothPositions.entries) {
        final boothId = entry.key;
        final position = entry.value;

        final docRef = _firestore.collection('booths').doc(boothId);
        addBatch.set(docRef, {
          'id': boothId,
          'name': position['name'],
          'displayName': position['name'],
          'x': position['x'],
          'y': position['y'],
          'width': position['width'],
          'height': position['height'],
          'shape': 'circle', // ブースは円形
          'type': 'booth',
          'company': '出展企業',
          'description': '詳細情報は準備中です。',
          'products': ['準備中'],
          'contactEmail': 'info@example.com',
          'website': 'https://example.com',
          'features': ['準備中'],
        });
      }
      await addBatch.commit();
      print('展示会場ブース座標の設定完了: ${boothPositions.length}件作成 ===');
    } catch (e) {
      print('展示会場ブース座標の設定中にエラーが発生しました: $e');
      throw Exception('展示会場ブース座標の設定に失敗しました: $e');
    }
  }

  /// 展示会場に追加の通路を追加（既存のデータを保持）
  Future<void> addExhibitionCorridors() async {
    try {
      print('=== 展示会場に通路を追加開始 ===');

      // 追加する通路のリスト
      final additionalCorridors = <Map<String, dynamic>>[
        // 上部の通路
        {
          'eventId': 'event_2025_exhibition',
          'type': 'corridor',
          'shape': 'rect',
          'x': 70,
          'y': 30,
          'width': 340,
          'height': 30,
          'color': '#EEEEEE',
          'label': '上部通路',
          'zIndex': 1,
        },

        // 下部の通路
        {
          'eventId': 'event_2025_exhibition',
          'type': 'corridor',
          'shape': 'rect',
          'x': 70,
          'y': 630,
          'width': 340,
          'height': 30,
          'color': '#EEEEEE',
          'label': '下部通路',
          'zIndex': 1,
        },

        // 右側の通路
        {
          'eventId': 'event_2025_exhibition',
          'type': 'corridor',
          'shape': 'rect',
          'x': 410,
          'y': 50,
          'width': 30,
          'height': 600,
          'color': '#EEEEEE',
          'label': '右側通路',
          'zIndex': 1,
        },
      ];

      final batch = _firestore.batch();
      int corridorIndex = 100; // 既存の要素と重複しないようにインデックスを100から開始
      
      for (final corridor in additionalCorridors) {
        final corridorRef = _firestore.collection('map_elements').doc('exhibition_corridor_${corridorIndex++}');
        batch.set(corridorRef, corridor);
      }
      
      await batch.commit();
      print('展示会場に通路を追加完了: ${additionalCorridors.length}件追加');
    } catch (e) {
      print('展示会場に通路を追加中にエラーが発生しました: $e');
      throw Exception('展示会場に通路を追加に失敗しました: $e');
    }
  }

  /// 展示会場のマップサイズを更新（既存のマップ要素とブースを保持）
  Future<void> updateExhibitionMapSize({required int width, required int height}) async {
    try {
      print('=== 展示会場のマップサイズを更新開始 ===');

      // イベントレイアウトのサイズを更新
      final eventRef = _firestore.collection('event_layouts').doc('event_2025_exhibition');
      await eventRef.update({
        'mapWidth': width,
        'mapHeight': height,
      });
      print('イベントレイアウトのサイズを更新: ${width}x${height}');

      // 背景と外枠のサイズも更新
      final batch = _firestore.batch();
      
      // 背景のサイズを更新
      final backgroundQuery = await _firestore
          .collection('map_elements')
          .where('eventId', isEqualTo: 'event_2025_exhibition')
          .where('type', isEqualTo: 'background')
          .get();
      
      for (final doc in backgroundQuery.docs) {
        batch.update(doc.reference, {
          'width': width,
          'height': height,
        });
      }
      print('背景のサイズを更新: ${backgroundQuery.docs.length}件');

      // 外枠のサイズを更新
      final wallQuery = await _firestore
          .collection('map_elements')
          .where('eventId', isEqualTo: 'event_2025_exhibition')
          .where('label', isEqualTo: '会場外枠')
          .get();
      
      for (final doc in wallQuery.docs) {
        batch.update(doc.reference, {
          'width': width - 20,  // 左右に10pxずつの余白
          'height': height - 20,
        });
      }
      print('外枠のサイズを更新: ${wallQuery.docs.length}件');

      await batch.commit();
      
      print('展示会場のマップサイズを更新完了: ${width}x${height}');
    } catch (e) {
      print('展示会場のマップサイズを更新中にエラーが発生しました: $e');
      throw Exception('展示会場のマップサイズを更新に失敗しました: $e');
    }
  }

  // ========================
  // 教室レイアウト初期化
  // ========================

  /// 教室レイアウトに変更（既存のブース情報は保持）
  Future<void> initializeClassroomLayout() async {
    try {
      print('=== 教室レイアウトの初期化開始 ===');
      
      // ステップ1: イベントレイアウトのサイズを更新（スクロール可能なサイズ）
      final eventRef = _firestore.collection('event_layouts').doc('event_2025_default');
      await eventRef.update({
        'mapWidth': 400,  // 机の見切れを防ぐために幅を広げる
        'mapHeight': 650,
        'eventName': '2025年 教室実験',
      });
      print('マップサイズを更新: 700x900');
      
      // ステップ2: 既存のマップ要素を削除
      final existingElements = await _firestore
          .collection('map_elements')
          .where('eventId', isEqualTo: 'event_2025_default')
          .get();
      
      final deleteBatch = _firestore.batch();
      for (final doc in existingElements.docs) {
        deleteBatch.delete(doc.reference);
      }
      await deleteBatch.commit();
      print('既存のマップ要素を削除: ${existingElements.docs.length}件');
      
      // ステップ3: 新しい教室レイアウトのマップ要素を作成（iPhone画面サイズに最適化）
      final classroomElements = <Map<String, dynamic>>[
        // 背景
        {
          'eventId': 'event_2025_default',
          'type': 'background',
          'shape': 'rect',
          'x': 0,
          'y': 0,
          'width': 400,
          'height': 650,
          'color': '#FAFAFA',
          'label': '背景',
          'zIndex': 0,
        },
        
        // 教室の外枠
        {
          'eventId': 'event_2025_default',
          'type': 'wall',
          'shape': 'rect',
          'x': 10,
          'y': 5,
          'width': 380,
          'height': 640,
          'color': '#BDBDBD',
          'strokeWidth': 2,
          'filled': false,
          'label': '教室外枠',
          'zIndex': 1,
        },
        
        // 教壇（上部中央）
        {
          'eventId': 'event_2025_default',
          'type': 'entrance',
          'shape': 'rect',
          'x': 80,
          'y': 30,
          'width': 160,
          'height': 30,
          'color': '#A1887F',
          'label': '教壇',
          'zIndex': 2,
        },
        
        // 横通路（上段と下段の机の間）
        {
          'eventId': 'event_2025_default',
          'type': 'corridor',
          'shape': 'rect',
          'x': 10,
          'y': 215,
          'width': 380,
          'height': 20,
          'color': '#EEEEEE',
          'label': '横通路（上段と下段の間）',
          'zIndex': 1,
        },
        
        // 縦通路1（左の通路：左端の細長い机と左の太い机の間）
        {
          'eventId': 'event_2025_default',
          'type': 'corridor',
          'shape': 'rect',
          'x': 60,
          'y': 5,
          'width': 30,
          'height': 640,
          'color': '#EEEEEE',
          'label': '左縦通路（ブース配置）',
          'zIndex': 1,
        },
        
        // 縦通路2（中央の通路：左の太い机と中央の太い机の間）
        {
          'eventId': 'event_2025_default',
          'type': 'corridor',
          'shape': 'rect',
          'x': 170,
          'y': 5,
          'width': 20,
          'height': 640,
          'color': '#EEEEEE',
          'label': '中央縦通路（ブース配置）',
          'zIndex': 1,
        },
        
        // 縦通路3（右の通路：中央の太い机と右端の細長い机の間）
        {
          'eventId': 'event_2025_default',
          'type': 'corridor',
          'shape': 'rect',
          'x': 270,
          'y': 5,
          'width': 20,
          'height': 640,
          'color': '#EEEEEE',
          'label': '右縦通路（ブース配置）',
          'zIndex': 1,
        },
        
        // === 机（マップ要素として描画）=== 合計8つ
        
        // 上段（教壇の下）- 4つの机
        // 1. 左端の細長い机
        {
          'eventId': 'event_2025_default',
          'type': 'wall',
          'shape': 'rect',
          'x': 25,
          'y': 80,
          'width': 30,
          'height': 130,
          'color': '#E0E0E0',
          'strokeWidth': 2,
          'filled': true,
          'label': '左端上段机（細長い）',
          'zIndex': 1,
        },
        // 2. 左の太い机（A09/A1用）
        {
          'eventId': 'event_2025_default',
          'type': 'wall',
          'shape': 'rect',
          'x': 95,
          'y': 80,
          'width': 70,
          'height': 130,
          'color': '#E0E0E0',
          'strokeWidth': 2,
          'filled': true,
          'label': '左列上段机（太い）',
          'zIndex': 1,
        },
        // 3. 中央の太い机（A10/A8用）
        {
          'eventId': 'event_2025_default',
          'type': 'wall',
          'shape': 'rect',
          'x': 195,
          'y': 80,
          'width': 70,
          'height': 130,
          'color': '#E0E0E0',
          'strokeWidth': 2,
          'filled': true,
          'label': '中央列上段机（太い）',
          'zIndex': 1,
        },
        // 4. 右端の細長い机
        {
          'eventId': 'event_2025_default',
          'type': 'wall',
          'shape': 'rect',
          'x': 295,
          'y': 80,
          'width': 30,
          'height': 130,
          'color': '#E0E0E0',
          'strokeWidth': 2,
          'filled': true,
          'label': '右端上段机（細長い）',
          'zIndex': 1,
        },
        
        // 下段（横通路の下）- 4つの机（上段より縦に長い）
        // 5. 左端の細長い机
        {
          'eventId': 'event_2025_default',
          'type': 'wall',
          'shape': 'rect',
          'x': 25,
          'y': 240,
          'width': 30,
          'height': 380,
          'color': '#E0E0E0',
          'strokeWidth': 2,
          'filled': true,
          'label': '左端下段机（細長い）',
          'zIndex': 1,
        },
        // 6. 左の太い机（A2/A3/A4用）
        {
          'eventId': 'event_2025_default',
          'type': 'wall',
          'shape': 'rect',
          'x': 95,
          'y': 240,
          'width': 70,
          'height': 380,
          'color': '#E0E0E0',
          'strokeWidth': 2,
          'filled': true,
          'label': '左列下段机（太い）',
          'zIndex': 1,
        },
        // 7. 中央の太い机（A7/A6/A5用）
        {
          'eventId': 'event_2025_default',
          'type': 'wall',
          'shape': 'rect',
          'x': 195,
          'y': 240,
          'width': 70,
          'height': 380,
          'color': '#E0E0E0',
          'strokeWidth': 2,
          'filled': true,
          'label': '中央列下段机（太い）',
          'zIndex': 1,
        },
        // 8. 右端の細長い机
        {
          'eventId': 'event_2025_default',
          'type': 'wall',
          'shape': 'rect',
          'x': 295,
          'y': 240,
          'width': 30,
          'height': 380,
          'color': '#E0E0E0',
          'strokeWidth': 2,
          'filled': true,
          'label': '右端下段机（細長い）',
          'zIndex': 1,
        },
      ];
      
      // バッチで保存
      final elementBatch = _firestore.batch();
      int elementIndex = 0;
      for (final element in classroomElements) {
        final elementRef = _firestore.collection('map_elements').doc('classroom_element_${elementIndex++}');
        elementBatch.set(elementRef, element);
      }
      await elementBatch.commit();
      print('教室レイアウトのマップ要素を作成: ${classroomElements.length}件');
      
      // ステップ4: FSC-BP104Dの位置を左上（A09）に更新（左端の細長い机と左の太い机の間の通路の中央）
      final fscBooth = await _firestore.collection('booths').doc('FSC-BP104D').get();
      if (fscBooth.exists) {
        await _firestore.collection('booths').doc('FSC-BP104D').update({
          'x': 75,
          'y': 105,
          'width': 20,
          'height': 20,
          'shape': 'circle',
          'name': 'ブースA09 (FSC-BP104D)',
          'displayName': 'ブースA09',
        });
        print('FSC-BP104DをブースA09（左上、机の間の縦通路の中央）に配置');
      }
      
      print('=== 教室レイアウトの初期化完了 ===');
    } catch (e) {
      print('教室レイアウトの初期化中にエラーが発生しました: $e');
      throw Exception('教室レイアウトの初期化に失敗しました: $e');
    }
  }

  /// 教室の全ブース座標を設定（8ブース版）
  Future<void> setupClassroomBooths() async {
    try {
      print('=== 教室ブース座標の設定開始 ===');
      
      // ステップ1: 既存のブースをすべて削除
      print('既存のブースを削除中...');
      final existingBooths = await _firestore.collection('booths').get();
      final batch = _firestore.batch();
      for (final doc in existingBooths.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
      print('既存のブースを削除しました: ${existingBooths.docs.length}件');
      
      // ステップ2: 教室レイアウトに基づくブース座標マッピング（8ブース）
      // 2列構成: 左列(A15→A14→A13)、右列(A08→A09→A10→A11→A12)
      // 座標はシンプルな縦並びで再配置（400x650の目安）
      final boothPositions = {
        // 左列
        'Booth-A15': {'x': 80, 'y': 110, 'name': 'ブースA15', 'width': 20, 'height': 20},
        'Booth-A14': {'x': 80, 'y': 240, 'name': 'ブースA14', 'width': 20, 'height': 20},
        'Booth-A13': {'x': 80, 'y': 370, 'name': 'ブースA13', 'width': 20, 'height': 20},
        'Booth-A12': {'x': 80, 'y': 500, 'name': 'ブースA12', 'width': 20, 'height': 20},

        // 右列
        'FSC-BP103B': {'x': 240, 'y': 110, 'name': 'ブースA08', 'width': 20, 'height': 20},  // A08（ビーコン2）
        'FSC-BP104D': {'x': 240, 'y': 190, 'name': 'ブースA09', 'width': 20, 'height': 20},  // A09（ビーコン1）
        'Booth-A10': {'x': 240, 'y': 270, 'name': 'ブースA10', 'width': 20, 'height': 20},
        'Booth-A11': {'x': 240, 'y': 350, 'name': 'ブースA11', 'width': 20, 'height': 20},
      };
      
      // ステップ3: 新しいブースを作成
      int createCount = 0;
      final createBatch = _firestore.batch();
      
      for (final entry in boothPositions.entries) {
        final boothId = entry.key;
        final position = entry.value;
        
        final boothData = {
          'x': position['x'],
          'y': position['y'],
          'name': position['name'],
          'displayName': position['name'],
          'width': position['width'],
          'height': position['height'],
          'shape': 'circle',
          'type': 'booth',
          'company': '準備中',
          'description': '説明準備中',
          'products': ['準備中'],
          'contactEmail': 'info@example.com',
          'website': 'https://example.com',
          'features': [],
        };
        
        final boothRef = _firestore.collection('booths').doc(boothId);
        createBatch.set(boothRef, boothData);
        print('🆕 ${position['name']} (${boothId}) を作成準備');
        createCount++;
      }
      
      await createBatch.commit();
      print('=== 教室ブース座標の設定完了: ${createCount}件新規作成 ===');
    } catch (e) {
      print('教室ブース座標の設定中にエラーが発生しました: $e');
      throw Exception('教室ブース座標の設定に失敗しました: $e');
    }
  }
}
