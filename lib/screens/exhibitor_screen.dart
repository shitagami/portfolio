import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/firebase_service.dart';
import 'visitor_management_screen.dart';

class ExhibitorScreen extends StatefulWidget {
  const ExhibitorScreen({super.key});

  @override
  State<ExhibitorScreen> createState() => _ExhibitorScreenState();
}

class _ExhibitorScreenState extends State<ExhibitorScreen>
    with TickerProviderStateMixin {
  final AuthService _authService = AuthService();
  final FirebaseService _firebaseService = FirebaseService();
  Map<String, dynamic> _todayStats = {};
  List<Map<String, dynamic>> _visitors = [];
  bool _isLoading = false;
  String _userName = '';
  late TabController _tabController;
  int _selectedTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      setState(() {
        _selectedTabIndex = _tabController.index;
      });
    });
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final userName = await _authService.getUserName();
      final stats = await _firebaseService.getTodayStats();
      // 出展ブース（FSC-BP104D）におけるユニーク来場者
      final visitors = await _firebaseService.getAllVisitors(targetBoothId: 'FSC-BP104D');
      
      setState(() {
        _userName = userName;
        _todayStats = stats;
        _visitors = visitors;
        _isLoading = false;
      });
    } catch (e) {
      print('データ読み込みエラー: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _logout() {
    _authService.logout();
    Navigator.of(context).pushReplacementNamed('/login');
  }

  int _getTotalCount() {
    // 出展ブース（FSC-BP104D）のユニーク来場者数を表示
    return _visitors.length;
  }

  @override
  Widget build(BuildContext context) {
    final totalCount = _getTotalCount();

    return Scaffold(
      appBar: AppBar(
        title: const Text('出展者管理画面'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(text: 'ダッシュボード'),
            Tab(text: '来場者管理'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                final isWideScreen = constraints.maxWidth > 900;
                if (isWideScreen) {
                  return Row(
                    children: [
                      Container(
                        width: 220,
                        color: Colors.blue.shade50,
                        child: ListView(
                          children: [
                            _buildTabButton(0, 'ダッシュボード', Icons.dashboard),
                            _buildTabButton(1, '来場者管理', Icons.people),
                          ],
                        ),
                      ),
                      Expanded(
                        child: IndexedStack(
                          index: _selectedTabIndex,
                          children: [
                            _buildDashboardTab(totalCount, isWideScreen),
                            _buildVisitorManageTab(),
                          ],
                        ),
                      ),
                    ],
                  );
                }
                return TabBarView(
                  controller: _tabController,
                  children: [
                    _buildDashboardTab(totalCount, isWideScreen),
                    _buildVisitorManageTab(),
                  ],
                );
              },
            ),
    );
  }

  Widget _buildTabButton(int index, String label, IconData icon) {
    final isSelected = _selectedTabIndex == index;
    return InkWell(
      onTap: () {
        setState(() {
          _selectedTabIndex = index;
        });
        _tabController.animateTo(index);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        color: isSelected ? Colors.blue.shade100 : Colors.transparent,
        child: Row(
          children: [
            Icon(icon, color: isSelected ? Colors.blue : Colors.grey),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? Colors.blue : Colors.black87,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDashboardTab(int totalCount, bool isWideScreen) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Card(
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      children: [
                        const Icon(Icons.person, size: 48, color: Colors.blue),
                        const SizedBox(width: 16),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _userName,
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Text(
                              '出展者アカウント',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (isWideScreen) ...[
                const SizedBox(width: 16),
                Expanded(
                  child: Card(
                    color: Colors.blue.shade50,
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Row(
                        children: [
                          const Icon(Icons.analytics, size: 48, color: Colors.blue),
                          const SizedBox(width: 16),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '今日の総受信数',
                                style: TextStyle(fontSize: 16, color: Colors.grey),
                              ),
                              Text(
                                '$totalCount回',
                                style: const TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blue,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 24),
          const Text(
            '管理機能',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: isWideScreen ? 3 : 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: isWideScreen ? 1.6 : 1.2,
            children: [
              _buildActionCard(
                icon: Icons.people,
                iconColor: Colors.blue,
                title: '来場者管理',
                subtitle: '見込み客リストを確認',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => VisitorManagementScreen(
                        targetBoothId: 'FSC-BP104D',
                      ),
                    ),
                  );
                },
              ),
              _buildActionCard(
                icon: Icons.store,
                iconColor: Colors.orange,
                title: 'ブース詳細',
                subtitle: '準備中',
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('ブース詳細機能は準備中です')),
                  );
                },
              ),
              _buildActionCard(
                icon: Icons.refresh,
                iconColor: Colors.green,
                title: '最新データ取得',
                subtitle: '手動で更新する',
                onTap: _loadData,
              ),
            ],
          ),
          const SizedBox(height: 24),
          // ビーコン別受信統計は非表示
        ],
      ),
    );
  }

  Widget _buildVisitorManageTab() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '来場者管理',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              'PCでも大きな画面で来場者リストを閲覧できます。',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => VisitorManagementScreen(
                      targetBoothId: 'FSC-BP104D',
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('来場者管理を開く'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              CircleAvatar(
                backgroundColor: iconColor.withOpacity(0.1),
                foregroundColor: iconColor,
                child: Icon(icon),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
