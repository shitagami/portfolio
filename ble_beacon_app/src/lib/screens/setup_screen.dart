import 'package:flutter/material.dart';
import '../utils/setup_test_users.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  bool _isLoading = false;
  String _status = '';

  Future<void> _setupTestUsers() async {
    setState(() {
      _isLoading = true;
      _status = 'テストユーザーデータを追加中...';
    });

    try {
      await SetupTestUsers.setupTestUsers();
      setState(() {
        _status = 'テストユーザーデータの追加が完了しました！';
      });
    } catch (e) {
      setState(() {
        _status = 'エラーが発生しました: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _cleanupTestUsers() async {
    setState(() {
      _isLoading = true;
      _status = 'テストユーザーデータを削除中...';
    });

    try {
      await SetupTestUsers.cleanupTestUsers();
      setState(() {
        _status = 'テストユーザーデータの削除が完了しました！';
      });
    } catch (e) {
      setState(() {
        _status = 'エラーが発生しました: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('セットアップ'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Firebase セットアップ',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),
            
            const Text(
              'テスト用アカウント',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            
            // 出展者
            _buildAccountInfo('出展者', [
              'exhibitor001 / password123',
              'exhibitor002 / password123',
            ]),
            
            // 主催者
            _buildAccountInfo('主催者', [
              'organizer001 / password123',
              'organizer002 / password123',
            ]),
            
            // スタッフ
            _buildAccountInfo('スタッフ', [
              'staff001 / password123',
              'staff002 / password123',
            ]),
            
            const SizedBox(height: 32),
            
            // ボタン
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _setupTestUsers,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                ),
                child: _isLoading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text(
                        'テストユーザーデータを追加',
                        style: TextStyle(fontSize: 16),
                      ),
              ),
            ),
            
            const SizedBox(height: 16),
            
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _cleanupTestUsers,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: _isLoading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text(
                        'テストユーザーデータを削除',
                        style: TextStyle(fontSize: 16),
                      ),
              ),
            ),
            
            const SizedBox(height: 24),
            
            if (_status.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _status.contains('エラー') ? Colors.red.shade50 : Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _status.contains('エラー') ? Colors.red : Colors.green,
                  ),
                ),
                child: Text(
                  _status,
                  style: TextStyle(
                    color: _status.contains('エラー') ? Colors.red : Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountInfo(String role, List<String> accounts) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              role,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ...accounts.map((account) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '• $account',
                style: const TextStyle(fontSize: 14),
              ),
            )),
          ],
        ),
      ),
    );
  }
} 