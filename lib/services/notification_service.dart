import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart'; // Added for Color

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

  // 混雑度の閾値設定
  int _crowdingThreshold = 25; // デフォルトは25人以上で混雑とみなす

  Future<void> initialize() async {
    try {
      // 権限をリクエスト
      await _requestPermissions();
      
      // ローカル通知の初期化
      await _initializeLocalNotifications();
      
      // Firebase Cloud Messagingの初期化
      await _initializeFirebaseMessaging();
      
      // バックグラウンドメッセージハンドラーを設定
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
      
      // フォアグラウンドメッセージハンドラーを設定
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
      
      print('通知サービス初期化完了');
    } catch (e) {
      print('通知サービス初期化エラー: $e');
      // 初期化に失敗してもアプリは動作する
    }
  }

  Future<void> _requestPermissions() async {
    // 通知権限をリクエスト
    final notificationStatus = await Permission.notification.request();
    print('通知権限の状態: $notificationStatus');
    
    // FCM権限をリクエスト
    final messagingSettings = await _firebaseMessaging.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
      sound: true,
    );
    print('FCM権限の状態: ${messagingSettings.authorizationStatus}');
  }

  Future<void> _initializeLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    
    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );
  }

  Future<void> _initializeFirebaseMessaging() async {
    try {
      // FCMトークンを取得
      final token = await _firebaseMessaging.getToken();
      print('FCMトークン: $token');
      
      // トピックを購読（スタッフ向け）
      await _firebaseMessaging.subscribeToTopic('staff_notifications');
    } catch (e) {
      print('FCM初期化エラー: $e');
      // FCM初期化に失敗しても続行
    }
  }

  void _onNotificationTapped(NotificationResponse response) {
    print('通知がタップされました: ${response.payload}');
    // 必要に応じて画面遷移などの処理を追加
  }

  // 混雑度に基づく通知を送信
  // 注意: このメソッドは既に閾値チェック後に呼ばれるため、ここでの閾値チェックは不要
  Future<void> sendCrowdingNotification(String boothName, int visitorCount) async {
    final title = '混雑警報';
    final body = '$boothNameが混雑しています（現在${visitorCount}人）';
    
    await _showLocalNotification(title, body, boothName);
    print('混雑通知を送信: $boothName - ${visitorCount}人（閾値: ${_crowdingThreshold}人）');
  }

  // ローカル通知を表示
  Future<void> _showLocalNotification(String title, String body, String payload) async {
    const androidDetails = AndroidNotificationDetails(
      'crowding_channel',
      '混雑警報',
      channelDescription: 'ブースの混雑状況に関する通知',
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
      enableVibration: true,
      enableLights: true,
      color: Color(0xFFE57373), // 赤色
    );
    
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );
    
    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
      payload: payload,
    );
  }

  // フォアグラウンドメッセージを処理
  void _handleForegroundMessage(RemoteMessage message) {
    print('フォアグラウンドメッセージを受信: ${message.notification?.title}');
    
    if (message.notification != null) {
      _showLocalNotification(
        message.notification!.title ?? '通知',
        message.notification!.body ?? '',
        message.data['booth_name'] ?? '',
      );
    }
  }

  // 通知をクリア
  Future<void> clearAllNotifications() async {
    await _localNotifications.cancelAll();
  }

  // 特定の通知をクリア
  Future<void> clearNotification(int id) async {
    await _localNotifications.cancel(id);
  }

  // 混雑度の閾値を取得
  int get crowdingThreshold => _crowdingThreshold;

  // 混雑度の閾値を設定
  Future<void> setCrowdingThreshold(int threshold) async {
    _crowdingThreshold = threshold;
    print('混雑度閾値を${threshold}人に設定しました');
  }
}

// バックグラウンドメッセージハンドラー
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print('バックグラウンドメッセージを受信: ${message.notification?.title}');
  
  // バックグラウンドでの通知表示
  final notificationService = NotificationService();
  await notificationService.initialize();
  
  if (message.notification != null) {
    await notificationService._showLocalNotification(
      message.notification!.title ?? '通知',
      message.notification!.body ?? '',
      message.data['booth_name'] ?? '',
    );
  }
} 