import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:math' as math;

/// Firebaseにテスト用のユーザーデータを追加するスクリプト
/// このスクリプトは開発時のみ使用してください
class SetupTestUsers {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// テスト用のユーザーデータをFirebaseに追加
  static Future<void> setupTestUsers() async {
    try {
      // 出展者データ
      await _firestore.collection('exhibitors').doc('exhibitor001').set({
        'id': 'exhibitor001',
        'name': 'テスト出展者1',
        'password': 'password123',
        'company': 'テスト株式会社',
        'createdAt': FieldValue.serverTimestamp(),
      });

      await _firestore.collection('exhibitors').doc('exhibitor002').set({
        'id': 'exhibitor002',
        'name': 'テスト出展者2',
        'password': 'password123',
        'company': 'サンプル企業',
        'createdAt': FieldValue.serverTimestamp(),
      });

      // 主催者データ
      await _firestore.collection('organizers').doc('organizer001').set({
        'id': 'organizer001',
        'name': 'テスト主催者1',
        'password': 'password123',
        'role': 'admin',
        'createdAt': FieldValue.serverTimestamp(),
      });

      await _firestore.collection('organizers').doc('organizer002').set({
        'id': 'organizer002',
        'name': 'テスト主催者2',
        'password': 'password123',
        'role': 'manager',
        'createdAt': FieldValue.serverTimestamp(),
      });

      // スタッフデータ
      await _firestore.collection('staff').doc('staff001').set({
        'id': 'staff001',
        'name': 'テストスタッフ1',
        'password': 'password123',
        'department': '運営部',
        'createdAt': FieldValue.serverTimestamp(),
      });

      await _firestore.collection('staff').doc('staff002').set({
        'id': 'staff002',
        'name': 'テストスタッフ2',
        'password': 'password123',
        'department': '技術部',
        'createdAt': FieldValue.serverTimestamp(),
      });

      // 来場者テストデータを追加
      await setupTestVisitors();

      print('テストユーザーデータの追加が完了しました');
    } catch (e) {
      print('テストユーザーデータの追加中にエラーが発生しました: $e');
    }
  }

  /// テスト用の来場者データをFirebaseに追加
  static Future<void> setupTestVisitors() async {
    try {
      final random = math.Random();
      
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
      final companies = ['株式会社ABC', '株式会社XYZ', 'テクノロジー株式会社', '〇〇大学', 'フリーランス', 'デザイン事務所', 'スタートアップ企業', '大手メーカー'];
      final positions = ['部長', '課長', '主任', '担当者', '学生', '代表取締役', 'マネージャー', 'ディレクター', '一般社員', '専門職'];
      final industries = ['IT・情報通信', '製造業', '金融・保険', '商社・卸売', '小売業', 'サービス業', '建設・不動産', '医療・福祉', '教育・研究', '官公庁・公共', 'メディア・広告', '運輸・物流', 'その他'];
      final sources = ['Web', 'SNS', '友人・知人', '新聞・雑誌', '企業からの案内', 'テレビ・ラジオ'];
      final interestsList = [
        ['テクノロジー', 'ビジネス'],
        ['教育', 'アート・デザイン'],
        ['健康・医療', 'スポーツ'],
        ['エンターテイメント', '旅行'],
        ['環境・サステナビリティ', 'ビジネス'],
      ];

      // 20人のテスト来場者を生成
      for (int i = 1; i <= 20; i++) {
        final userId = 'test_visitor_${DateTime.now().millisecondsSinceEpoch}_$i';
        final age = 20 + random.nextInt(41); // 20-60歳
        
        await _firestore.collection('visitors').doc(userId).set({
          'userId': userId,
          'displayName': 'テスト来場者$i',
          'email': 'visitor$i@example.com',
          'age': age,
          'gender': genders[random.nextInt(genders.length)],
          'job': jobs[random.nextInt(jobs.length)],
          'company': companies[random.nextInt(companies.length)],
          'position': positions[random.nextInt(positions.length)],
          'industry': industries[random.nextInt(industries.length)],
          'eventSource': sources[random.nextInt(sources.length)],
          'interests': interestsList[random.nextInt(interestsList.length)],
          'createdAt': FieldValue.serverTimestamp(),
          'isTestData': true,
        });
      }

      print('テスト来場者データの追加が完了しました（20件）');
    } catch (e) {
      print('テスト来場者データの追加中にエラーが発生しました: $e');
    }
  }

  /// テスト用のユーザーデータを削除
  static Future<void> cleanupTestUsers() async {
    try {
      // 出展者データを削除
      await _firestore.collection('exhibitors').doc('exhibitor001').delete();
      await _firestore.collection('exhibitors').doc('exhibitor002').delete();

      // 主催者データを削除
      await _firestore.collection('organizers').doc('organizer001').delete();
      await _firestore.collection('organizers').doc('organizer002').delete();

      // スタッフデータを削除
      await _firestore.collection('staff').doc('staff001').delete();
      await _firestore.collection('staff').doc('staff002').delete();

      // テスト来場者データを削除
      final visitorQuery = await _firestore
          .collection('visitors')
          .where('isTestData', isEqualTo: true)
          .get();
      
      for (final doc in visitorQuery.docs) {
        await doc.reference.delete();
      }

      print('テストユーザーデータの削除が完了しました');
    } catch (e) {
      print('テストユーザーデータの削除中にエラーが発生しました: $e');
    }
  }
} 