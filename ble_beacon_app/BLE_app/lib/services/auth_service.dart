import 'package:cloud_firestore/cloud_firestore.dart';

enum UserRole {
  exhibitor,    // 出展者
  organizer,    // 主催者
  staff,        // スタッフ
  visitor       // 来場者
}

class AuthService {
  // Singletonパターンの実装
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  
  // 現在ログイン中のユーザー情報
  UserRole? _currentUserRole;
  String? _currentUserId;
  
  UserRole? get currentUserRole => _currentUserRole;
  String? get currentUserId => _currentUserId;
  bool get isLoggedIn => _currentUserRole != null;

  /// 出展者ログイン
  Future<bool> loginExhibitor(String id, String password) async {
    try {
      final doc = await _firestore
          .collection('exhibitors')
          .doc(id)
          .get();
      
      if (doc.exists && doc.data()?['password'] == password) {
        _currentUserRole = UserRole.exhibitor;
        _currentUserId = id;
        return true;
      }
      return false;
    } catch (e) {
      print('出展者ログインエラー: $e');
      return false;
    }
  }

  /// 主催者ログイン
  Future<bool> loginOrganizer(String id, String password) async {
    try {
      final doc = await _firestore
          .collection('organizers')
          .doc(id)
          .get();
      
      if (doc.exists && doc.data()?['password'] == password) {
        _currentUserRole = UserRole.organizer;
        _currentUserId = id;
        return true;
      }
      return false;
    } catch (e) {
      print('主催者ログインエラー: $e');
      return false;
    }
  }

  /// スタッフログイン
  Future<bool> loginStaff(String id, String password) async {
    try {
      final doc = await _firestore
          .collection('staff')
          .doc(id)
          .get();
      
      if (doc.exists && doc.data()?['password'] == password) {
        _currentUserRole = UserRole.staff;
        _currentUserId = id;
        return true;
      }
      return false;
    } catch (e) {
      print('スタッフログインエラー: $e');
      return false;
    }
  }

  /// 来場者ログイン（簡易版）
  Future<bool> loginVisitor() async {
    _currentUserRole = UserRole.visitor;
    _currentUserId = 'visitor_${DateTime.now().millisecondsSinceEpoch}';
    return true;
  }

  /// ログアウト
  void logout() {
    _currentUserRole = null;
    _currentUserId = null;
  }

  /// ユーザー名を取得
  Future<String> getUserName() async {
    if (_currentUserId == null || _currentUserRole == null) {
      return 'ゲスト';
    }

    try {
      String collectionName;
      switch (_currentUserRole!) {
        case UserRole.exhibitor:
          collectionName = 'exhibitors';
          break;
        case UserRole.organizer:
          collectionName = 'organizers';
          break;
        case UserRole.staff:
          collectionName = 'staff';
          break;
        case UserRole.visitor:
          return '来場者';
      }

      final doc = await _firestore
          .collection(collectionName)
          .doc(_currentUserId)
          .get();
      
      return doc.data()?['name'] ?? '不明';
    } catch (e) {
      return '不明';
    }
  }
} 