import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../services/auth_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _idController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authService = AuthService();
  
  UserRole _selectedRole = UserRole.exhibitor;
  bool _isLoading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _idController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
    });

    try {
      bool success = false;
      
      switch (_selectedRole) {
        case UserRole.exhibitor:
          success = await _authService.loginExhibitor(
            _idController.text.trim(),
            _passwordController.text,
          );
          break;
        case UserRole.organizer:
          success = await _authService.loginOrganizer(
            _idController.text.trim(),
            _passwordController.text,
          );
          break;
        case UserRole.staff:
          success = await _authService.loginStaff(
            _idController.text.trim(),
            _passwordController.text,
          );
          break;
        case UserRole.visitor:
          success = await _authService.loginVisitor();
          break;
      }

      if (success) {
        if (mounted) {
          // ログイン成功時の画面遷移
          _navigateToHome();
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('ログインに失敗しました。IDとパスワードを確認してください。'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('エラーが発生しました: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _navigateToHome() {
    // ログイン成功後の画面遷移
    switch (_authService.currentUserRole) {
      case UserRole.exhibitor:
        Navigator.of(context).pushReplacementNamed('/exhibitor');
        break;
      case UserRole.organizer:
        // Webの場合はWebダッシュボードに遷移
        if (kIsWeb) {
          Navigator.of(context).pushReplacementNamed('/web_dashboard');
        } else {
          Navigator.of(context).pushReplacementNamed('/organizer');
        }
        break;
      case UserRole.staff:
        Navigator.of(context).pushReplacementNamed('/staff');
        break;
      case UserRole.visitor:
        Navigator.of(context).pushReplacementNamed('/visitor_form');
        break;
      default:
        Navigator.of(context).pushReplacementNamed('/home');
    }
  }

  void _navigateToVisitorHome() async {
    // 来場者としてログイン
    try {
      setState(() {
        _isLoading = true;
      });
      
      final success = await _authService.loginVisitor();
      
      if (success && mounted) {
        Navigator.of(context).pushReplacementNamed('/visitor_form');
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('来場者ログインに失敗しました'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('エラーが発生しました: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ログイン'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // アプリタイトル
              const Text(
                'BLEビーコン受信アプリ',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 32),

              // 来場者ログインボタン
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _navigateToVisitorHome,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text(
                    '来場者としてログイン',
                    style: TextStyle(fontSize: 16),
                  ),
                ),
              ),
              
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 24),

              // 管理者ログインセクション
              const Text(
                '管理者ログイン',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),

              // ロール選択
              DropdownButtonFormField<UserRole>(
                value: _selectedRole,
                decoration: const InputDecoration(
                  labelText: 'ロール',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: UserRole.exhibitor,
                    child: Text('出展者'),
                  ),
                  DropdownMenuItem(
                    value: UserRole.organizer,
                    child: Text('主催者'),
                  ),
                  DropdownMenuItem(
                    value: UserRole.staff,
                    child: Text('スタッフ'),
                  ),
                ],
                onChanged: (value) {
                  setState(() {
                    _selectedRole = value!;
                  });
                },
              ),
              
              const SizedBox(height: 16),

              // ID入力
              TextFormField(
                controller: _idController,
                decoration: const InputDecoration(
                  labelText: 'ID',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'IDを入力してください';
                  }
                  return null;
                },
              ),
              
              const SizedBox(height: 16),

              // パスワード入力
              TextFormField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'パスワード',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscurePassword = !_obscurePassword;
                      });
                    },
                  ),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'パスワードを入力してください';
                  }
                  return null;
                },
              ),
              
              const SizedBox(height: 24),

              // ログインボタン
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _login,
                  child: _isLoading
                      ? const CircularProgressIndicator()
                      : const Text(
                          'ログイン',
                          style: TextStyle(fontSize: 16),
                        ),
                ),
              ),
              
              const SizedBox(height: 24),
              
              // セットアップ画面へのリンク（開発用）
              TextButton(
                onPressed: () {
                  Navigator.of(context).pushNamed('/setup');
                },
                child: const Text(
                  'セットアップ（開発用）',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
} 