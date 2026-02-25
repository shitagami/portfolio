import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../services/auth_service.dart';
import '../services/firebase_service.dart';
import 'package:fl_chart/fl_chart.dart';

/// Web用のダッシュボード画面（PC画面向けに最適化）
class WebDashboardScreen extends StatefulWidget {
  const WebDashboardScreen({super.key});

  @override
  State<WebDashboardScreen> createState() => _WebDashboardScreenState();
}

class _WebDashboardScreenState extends State<WebDashboardScreen> with TickerProviderStateMixin {
  final AuthService _authService = AuthService();
  final FirebaseService _firebaseService = FirebaseService();
  Map<String, dynamic> _todayStats = {};
  List<Map<String, dynamic>> _visitorData = [];
  Map<String, dynamic> _companyAttributeStats = {};
  bool _isLoading = false;
  String _userName = '';
  int _selectedTabIndex = 0;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _tabController.addListener(() {
      setState(() {
        _selectedTabIndex = _tabController.index;
      });
    });
    _loadData();
    // 自動更新は無効化（手動更新ボタンで更新可能）
    // _startAutoRefresh();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _startAutoRefresh() {
    Future.delayed(const Duration(seconds: 30), () {
      if (mounted) {
        _loadData();
        _startAutoRefresh();
      }
    });
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final userName = await _authService.getUserName();
      final stats = await _firebaseService.getTodayStats();
      final visitors = await _firebaseService.getAllVisitors();
      final companyStats = await _firebaseService.getCompanyAttributeStats();
      
      setState(() {
        _userName = userName;
        _todayStats = stats;
        _visitorData = visitors;
        _companyAttributeStats = companyStats;
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
    int total = 0;
    for (final data in _todayStats.values) {
      total += (data['count'] as int? ?? 0);
    }
    return total;
  }

  int _getTotalVisitors() {
    return _visitorData.length;
  }

  Map<String, int> _getGenderDistribution() {
    final genderCount = <String, int>{};
    for (final visitor in _visitorData) {
      final gender = visitor['gender']?.toString() ?? '不明';
      genderCount[gender] = (genderCount[gender] ?? 0) + 1;
    }
    return genderCount;
  }

  Map<String, int> _getAgeDistribution() {
    final ageCount = <String, int>{};
    for (final visitor in _visitorData) {
      final age = visitor['age'] as int? ?? 0;
      String ageGroup;
      if (age < 20) {
        ageGroup = '10代';
      } else if (age < 30) {
        ageGroup = '20代';
      } else if (age < 40) {
        ageGroup = '30代';
      } else if (age < 50) {
        ageGroup = '40代';
      } else if (age < 60) {
        ageGroup = '50代';
      } else if (age < 70) {
        ageGroup = '60代';
      } else {
        ageGroup = '70歳以上';
      }
      ageCount[ageGroup] = (ageCount[ageGroup] ?? 0) + 1;
    }
    return ageCount;
  }

  @override
  Widget build(BuildContext context) {
    final totalCount = _getTotalCount();
    final totalVisitors = _getTotalVisitors();
    final genderData = _getGenderDistribution();
    final ageData = _getAgeDistribution();
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('ダッシュボード - BLE Beacon 管理システム'),
        backgroundColor: Colors.purple,
        foregroundColor: Colors.white,
        elevation: 2,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
            tooltip: 'データを更新',
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
            tooltip: 'ログアウト',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          isScrollable: true,
          labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          tabs: const [
            Tab(text: '📊 ヒートマップ'),
            Tab(text: '👥 属性分析'),
            Tab(text: '🏢 企業属性'),
            Tab(text: '🎯 興味分野'),
            Tab(text: '⚡ パフォーマンス'),
            Tab(text: '🔥 人気度'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                // PC画面向けのレイアウト（幅が広い場合）
                if (constraints.maxWidth > 1200) {
                  return _buildDesktopLayout(totalCount, totalVisitors, genderData, ageData);
                } else {
                  // タブレット/モバイル向けのレイアウト
                  return TabBarView(
                    controller: _tabController,
                    children: [
                      _buildHeatmapTab(),
                      _buildAttributeTab(totalVisitors, genderData, ageData),
                      _buildCompanyAttributeTab(),
                      _buildInterestTab(),
                      _buildPerformanceTab(),
                      _buildPopularityTab(),
                    ],
                  );
                }
              },
            ),
    );
  }

  /// PC画面向けのレイアウト（複数のタブを同時表示）
  Widget _buildDesktopLayout(int totalCount, int totalVisitors, Map<String, int> genderData, Map<String, int> ageData) {
    return Row(
      children: [
        // サイドバー（タブ選択）
        Container(
          width: 200,
          color: Colors.grey.shade100,
          child: ListView(
            children: [
              _buildTabButton(0, '📊 ヒートマップ', Icons.map),
              _buildTabButton(1, '👥 属性分析', Icons.people),
              _buildTabButton(2, '🏢 企業属性', Icons.business),
              _buildTabButton(3, '🎯 興味分野', Icons.interests),
              _buildTabButton(4, '⚡ パフォーマンス', Icons.speed),
              _buildTabButton(5, '🔥 人気度', Icons.trending_up),
            ],
          ),
        ),
        // メインコンテンツ
        Expanded(
          child: IndexedStack(
            index: _selectedTabIndex,
            children: [
              _buildHeatmapTab(),
              _buildAttributeTab(totalVisitors, genderData, ageData),
              _buildCompanyAttributeTab(),
              _buildInterestTab(),
              _buildPerformanceTab(),
              _buildPopularityTab(),
            ],
          ),
        ),
      ],
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
        color: isSelected ? Colors.purple.shade100 : Colors.transparent,
        child: Row(
          children: [
            Icon(icon, color: isSelected ? Colors.purple : Colors.grey),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? Colors.purple : Colors.black87,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeatmapTab() {
    final totalCount = _getTotalCount();
    
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ユーザー情報と統計カード
          Row(
            children: [
              Expanded(
                child: Card(
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Row(
                      children: [
                        const Icon(Icons.admin_panel_settings, size: 48, color: Colors.purple),
                        const SizedBox(width: 20),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _userName,
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Text(
                              '主催者',
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
              const SizedBox(width: 16),
              Expanded(
                child: Card(
                  elevation: 2,
                  color: Colors.purple.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Row(
                      children: [
                        const Icon(Icons.analytics, size: 48, color: Colors.purple),
                        const SizedBox(width: 20),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '今日の総受信数',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey,
                              ),
                            ),
                            Text(
                              '$totalCount回',
                              style: const TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                                color: Colors.purple,
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
          ),
          
          const SizedBox(height: 32),
          
          // ビーコン別受信統計
          const Text(
            'ビーコン別受信統計',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          
          if (_todayStats.isEmpty)
            Card(
              elevation: 2,
              child: const Padding(
                padding: EdgeInsets.all(32.0),
                child: Center(
                  child: Text(
                    '今日の統計データはありません',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                ),
              ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: 2.5,
              ),
              itemCount: _todayStats.length,
              itemBuilder: (context, index) {
                final deviceName = _todayStats.keys.elementAt(index);
                final data = _todayStats[deviceName] as Map<String, dynamic>;
                final count = data['count'] ?? 0;
                final percentage = totalCount > 0 
                    ? ((count / totalCount) * 100).toStringAsFixed(1)
                    : '0.0';
                
                return Card(
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.bluetooth, color: Colors.purple, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                deviceName,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '$count回',
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.purple,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.purple.shade100,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '$percentage%',
                                style: const TextStyle(
                                  color: Colors.purple,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildAttributeTab(int totalVisitors, Map<String, int> genderData, Map<String, int> ageData) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 総来場者数カード
          Card(
            elevation: 2,
            color: Colors.red.shade50,
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Row(
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.people,
                      color: Colors.white,
                      size: 40,
                    ),
                  ),
                  const SizedBox(width: 24),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        totalVisitors.toString(),
                        style: const TextStyle(
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                          color: Colors.red,
                        ),
                      ),
                      const Text(
                        '総来場者数',
                        style: TextStyle(
                          fontSize: 20,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 32),
          
          // 性別分布と年齢分布を横並び
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Card(
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '性別分布',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 24),
                        if (genderData.isEmpty)
                          const Center(
                            child: Text(
                              '性別データがありません',
                              style: TextStyle(color: Colors.grey),
                            ),
                          )
                        else
                          SizedBox(
                            height: 300,
                            child: Row(
                              children: [
                                Expanded(
                                  flex: 2,
                                  child: CustomPaint(
                                    painter: GenderPieChartPainter(genderData, totalVisitors),
                                    size: const Size(300, 300),
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: genderData.entries.map((entry) {
                                      final color = _getGenderColor(entry.key);
                                      final percentage = totalVisitors > 0 
                                          ? ((entry.value / totalVisitors) * 100).toStringAsFixed(0)
                                          : '0';
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 8),
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 16,
                                              height: 16,
                                              decoration: BoxDecoration(
                                                color: color,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Text(
                                              '${entry.key} ${percentage}%',
                                              style: const TextStyle(fontSize: 16),
                                            ),
                                          ],
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Card(
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '年齢分布',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 24),
                        if (ageData.isEmpty)
                          const Center(
                            child: Text(
                              '年齢データがありません',
                              style: TextStyle(color: Colors.grey),
                            ),
                          )
                        else
                          SizedBox(
                            height: 300,
                            child: CustomPaint(
                              painter: AgeBarChartPainter(ageData),
                              size: const Size(double.infinity, 300),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 32),
          
          // 詳細統計
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '詳細統計',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (totalVisitors > 0) ...[
                    _buildStatRow('平均年齢', '${_getAverageAge().toStringAsFixed(1)}歳'),
                    _buildStatRow('最多年齢層', _getMostCommonAgeGroup()),
                    _buildStatRow('男性比率', '${_getGenderPercentage('男性')}%'),
                    _buildStatRow('女性比率', '${_getGenderPercentage('女性')}%'),
                  ] else
                    const Text(
                      '来場者データがありません',
                      style: TextStyle(color: Colors.grey),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompanyAttributeTab() {
    final industryData = _companyAttributeStats['industry'] as Map<String, int>? ?? {};
    final positionData = _companyAttributeStats['position'] as Map<String, int>? ?? {};
    final jobData = _companyAttributeStats['job'] as Map<String, int>? ?? {};
    final totalVisitors = _companyAttributeStats['totalVisitors'] as int? ?? 0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ヘッダー
          Card(
            elevation: 2,
            color: Colors.purple.shade50,
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Row(
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: Colors.purple,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.business_center,
                      color: Colors.white,
                      size: 40,
                    ),
                  ),
                  const SizedBox(width: 24),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        totalVisitors.toString(),
                        style: const TextStyle(
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                          color: Colors.purple,
                        ),
                      ),
                      const Text(
                        '来場者の企業属性分析',
                        style: TextStyle(
                          fontSize: 20,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 32),
          
          // 業種別分布（円グラフ）
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '業種別分布',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (industryData.isEmpty)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32.0),
                        child: Text(
                          '業種データがありません',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: SizedBox(
                            height: 350,
                            child: PieChart(
                              PieChartData(
                                sections: _createIndustryPieChartSections(industryData, totalVisitors),
                                sectionsSpace: 2,
                                centerSpaceRadius: 60,
                                borderData: FlBorderData(show: false),
                                pieTouchData: PieTouchData(
                                  touchCallback: (FlTouchEvent event, pieTouchResponse) {},
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          child: _buildLegend(industryData, totalVisitors, _getIndustryColor),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 32),
          
          // 役職別分布と職業別分布を横並び
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Card(
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '役職別分布',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 24),
                        if (positionData.isEmpty)
                          const Center(
                            child: Padding(
                              padding: EdgeInsets.all(32.0),
                              child: Text(
                                '役職データがありません',
                                style: TextStyle(color: Colors.grey),
                              ),
                            ),
                          )
                        else
                          SizedBox(
                            height: 350,
                            child: BarChart(
                              BarChartData(
                                alignment: BarChartAlignment.spaceAround,
                                maxY: positionData.values.reduce(math.max).toDouble() * 1.2,
                                barTouchData: BarTouchData(
                                  enabled: true,
                                  touchTooltipData: BarTouchTooltipData(
                                    getTooltipItem: (group, groupIndex, rod, rodIndex) {
                                      final position = positionData.keys.elementAt(groupIndex);
                                      return BarTooltipItem(
                                        '$position\n${rod.toY.toInt()}人',
                                        const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                      );
                                    },
                                  ),
                                ),
                                titlesData: FlTitlesData(
                                  show: true,
                                  bottomTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      getTitlesWidget: (value, meta) {
                                        final index = value.toInt();
                                        if (index >= 0 && index < positionData.length) {
                                          final position = positionData.keys.elementAt(index);
                                          return Padding(
                                            padding: const EdgeInsets.only(top: 8.0),
                                            child: Text(
                                              position,
                                              style: const TextStyle(fontSize: 12),
                                              textAlign: TextAlign.center,
                                            ),
                                          );
                                        }
                                        return const Text('');
                                      },
                                      reservedSize: 40,
                                    ),
                                  ),
                                  leftTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 50,
                                      getTitlesWidget: (value, meta) {
                                        return Text(
                                          value.toInt().toString(),
                                          style: const TextStyle(fontSize: 12),
                                        );
                                      },
                                    ),
                                  ),
                                  topTitles: const AxisTitles(
                                    sideTitles: SideTitles(showTitles: false),
                                  ),
                                  rightTitles: const AxisTitles(
                                    sideTitles: SideTitles(showTitles: false),
                                  ),
                                ),
                                borderData: FlBorderData(show: false),
                                barGroups: _createPositionBarGroups(positionData),
                                gridData: FlGridData(
                                  show: true,
                                  drawVerticalLine: false,
                                  horizontalInterval: 5,
                                  getDrawingHorizontalLine: (value) {
                                    return FlLine(
                                      color: Colors.grey.shade300,
                                      strokeWidth: 1,
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Card(
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '職業別分布',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 24),
                        if (jobData.isEmpty)
                          const Center(
                            child: Padding(
                              padding: EdgeInsets.all(32.0),
                              child: Text(
                                '職業データがありません',
                                style: TextStyle(color: Colors.grey),
                              ),
                            ),
                          )
                        else
                          SizedBox(
                            height: 350,
                            child: BarChart(
                              BarChartData(
                                alignment: BarChartAlignment.spaceAround,
                                maxY: jobData.values.reduce(math.max).toDouble() * 1.2,
                                barTouchData: BarTouchData(
                                  enabled: true,
                                  touchTooltipData: BarTouchTooltipData(
                                    getTooltipItem: (group, groupIndex, rod, rodIndex) {
                                      final job = jobData.keys.elementAt(groupIndex);
                                      return BarTooltipItem(
                                        '$job\n${rod.toY.toInt()}人',
                                        const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                      );
                                    },
                                  ),
                                ),
                                titlesData: FlTitlesData(
                                  show: true,
                                  bottomTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      getTitlesWidget: (value, meta) {
                                        final index = value.toInt();
                                        if (index >= 0 && index < jobData.length) {
                                          final job = jobData.keys.elementAt(index);
                                          return Padding(
                                            padding: const EdgeInsets.only(top: 8.0),
                                            child: Text(
                                              job,
                                              style: const TextStyle(fontSize: 12),
                                              textAlign: TextAlign.center,
                                            ),
                                          );
                                        }
                                        return const Text('');
                                      },
                                      reservedSize: 40,
                                    ),
                                  ),
                                  leftTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 50,
                                      getTitlesWidget: (value, meta) {
                                        return Text(
                                          value.toInt().toString(),
                                          style: const TextStyle(fontSize: 12),
                                        );
                                      },
                                    ),
                                  ),
                                  topTitles: const AxisTitles(
                                    sideTitles: SideTitles(showTitles: false),
                                  ),
                                  rightTitles: const AxisTitles(
                                    sideTitles: SideTitles(showTitles: false),
                                  ),
                                ),
                                borderData: FlBorderData(show: false),
                                barGroups: _createJobBarGroups(jobData),
                                gridData: FlGridData(
                                  show: true,
                                  drawVerticalLine: false,
                                  horizontalInterval: 5,
                                  getDrawingHorizontalLine: (value) {
                                    return FlLine(
                                      color: Colors.grey.shade300,
                                      strokeWidth: 1,
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInterestTab() {
    final interestData = _companyAttributeStats['interests'] as Map<String, int>? ?? {};
    final totalVisitors = _companyAttributeStats['totalVisitors'] as int? ?? 0;
    final totalSelections = interestData.values.fold<int>(0, (sum, count) => sum + count);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            elevation: 2,
            color: Colors.orange.shade50,
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Row(
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: Colors.orange,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.interests,
                      color: Colors.white,
                      size: 40,
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          totalVisitors.toString(),
                          style: const TextStyle(
                            fontSize: 48,
                            fontWeight: FontWeight.bold,
                            color: Colors.orange,
                          ),
                        ),
                        const Text(
                          '来場者の興味分野分析',
                          style: TextStyle(
                            fontSize: 20,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 24),
          
          Card(
            elevation: 2,
            color: Colors.blue.shade50,
            child: const Padding(
              padding: EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue, size: 24),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '複数選択可能なため、合計が総来場者数を超える場合があります',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.blue,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 32),
          
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '興味のある分野別分布',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (interestData.isEmpty)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32.0),
                        child: Text(
                          '興味分野データがありません',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      height: math.max(400, interestData.length * 50.0),
                      child: BarChart(
                        BarChartData(
                          alignment: BarChartAlignment.spaceAround,
                          maxY: interestData.values.reduce(math.max).toDouble() * 1.2,
                          barTouchData: BarTouchData(
                            enabled: true,
                            touchTooltipData: BarTouchTooltipData(
                              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                                final interest = interestData.keys.elementAt(groupIndex);
                                final percentage = totalSelections > 0 
                                    ? ((rod.toY / totalSelections) * 100).toStringAsFixed(1)
                                    : '0.0';
                                return BarTooltipItem(
                                  '$interest\n${rod.toY.toInt()}人 ($percentage%)',
                                  const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                );
                              },
                            ),
                          ),
                          titlesData: FlTitlesData(
                            show: true,
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                getTitlesWidget: (value, meta) {
                                  final index = value.toInt();
                                  if (index >= 0 && index < interestData.length) {
                                    final interest = interestData.keys.elementAt(index);
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 8.0),
                                      child: Text(
                                        interest,
                                        style: const TextStyle(fontSize: 12),
                                        textAlign: TextAlign.center,
                                      ),
                                    );
                                  }
                                  return const Text('');
                                },
                                reservedSize: 50,
                              ),
                            ),
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 50,
                                getTitlesWidget: (value, meta) {
                                  return Text(
                                    value.toInt().toString(),
                                    style: const TextStyle(fontSize: 12),
                                  );
                                },
                              ),
                            ),
                            topTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                            rightTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                          ),
                          borderData: FlBorderData(show: false),
                          barGroups: _createInterestBarGroups(interestData),
                          gridData: FlGridData(
                            show: true,
                            drawVerticalLine: false,
                            horizontalInterval: 10,
                            getDrawingHorizontalLine: (value) {
                              return FlLine(
                                color: Colors.grey.shade300,
                                strokeWidth: 1,
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 32),
          
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'サマリー統計',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (totalVisitors > 0 && interestData.isNotEmpty) ...[
                    _buildStatRow('最多興味分野', _getMostCommon(interestData)),
                    _buildStatRow('総来場者数', '$totalVisitors人'),
                    _buildStatRow('総選択数', '$totalSelections回'),
                    _buildStatRow('1人あたり平均', '${(totalSelections / totalVisitors).toStringAsFixed(1)}個'),
                    _buildStatRow('分野数', '${interestData.length}種類'),
                  ] else
                    const Text(
                      '興味分野データがありません',
                      style: TextStyle(color: Colors.grey),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPerformanceTab() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32.0),
        child: Text(
          'パフォーマンス分析\n(準備中)',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 24, color: Colors.grey),
        ),
      ),
    );
  }

  Widget _buildPopularityTab() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32.0),
        child: Text(
          '人気度分析\n(準備中)',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 24, color: Colors.grey),
        ),
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 18),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.purple,
            ),
          ),
        ],
      ),
    );
  }

  double _getAverageAge() {
    if (_visitorData.isEmpty) return 0;
    final totalAge = _visitorData.fold<int>(0, (sum, visitor) => sum + (visitor['age'] as int? ?? 0));
    return totalAge / _visitorData.length;
  }

  String _getMostCommonAgeGroup() {
    final ageData = _getAgeDistribution();
    if (ageData.isEmpty) return 'データなし';
    return ageData.entries.reduce((a, b) => a.value > b.value ? a : b).key;
  }

  double _getGenderPercentage(String gender) {
    if (_visitorData.isEmpty) return 0;
    final count = _visitorData.where((v) => v['gender'] == gender).length;
    return ((count / _visitorData.length) * 100);
  }

  List<PieChartSectionData> _createIndustryPieChartSections(Map<String, int> data, int total) {
    final sections = <PieChartSectionData>[];
    int index = 0;
    
    for (final entry in data.entries) {
      final percentage = total > 0 ? (entry.value / total * 100) : 0.0;
      final showTitle = percentage >= 8.0;
      
      sections.add(
        PieChartSectionData(
          color: _getIndustryColor(entry.key, index),
          value: entry.value.toDouble(),
          title: showTitle ? '${percentage.toStringAsFixed(1)}%' : '',
          radius: 100,
          titleStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
          titlePositionPercentageOffset: 0.55,
        ),
      );
      index++;
    }
    
    return sections;
  }

  List<BarChartGroupData> _createPositionBarGroups(Map<String, int> data) {
    final groups = <BarChartGroupData>[];
    int index = 0;
    
    for (final entry in data.entries) {
      groups.add(
        BarChartGroupData(
          x: index,
          barRods: [
            BarChartRodData(
              toY: entry.value.toDouble(),
              color: Colors.purple,
              width: 20,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(4),
              ),
            ),
          ],
        ),
      );
      index++;
    }
    
    return groups;
  }

  List<BarChartGroupData> _createJobBarGroups(Map<String, int> data) {
    final groups = <BarChartGroupData>[];
    int index = 0;
    
    for (final entry in data.entries) {
      groups.add(
        BarChartGroupData(
          x: index,
          barRods: [
            BarChartRodData(
              toY: entry.value.toDouble(),
              color: Colors.teal,
              width: 20,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(4),
              ),
            ),
          ],
        ),
      );
      index++;
    }
    
    return groups;
  }

  List<BarChartGroupData> _createInterestBarGroups(Map<String, int> data) {
    final groups = <BarChartGroupData>[];
    int index = 0;
    
    for (final entry in data.entries) {
      groups.add(
        BarChartGroupData(
          x: index,
          barRods: [
            BarChartRodData(
              toY: entry.value.toDouble(),
              color: Colors.orange,
              width: 20,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(4),
              ),
            ),
          ],
        ),
      );
      index++;
    }
    
    return groups;
  }

  Widget _buildLegend(Map<String, int> data, int total, Color Function(String, int) getColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: data.entries.map((entry) {
        final index = data.keys.toList().indexOf(entry.key);
        final color = getColor(entry.key, index);
        final percentage = total > 0 
            ? ((entry.value / total) * 100).toStringAsFixed(1)
            : '0.0';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${entry.key} $percentage% (${entry.value}人)',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Color _getIndustryColor(String industry, int index) {
    final colors = [
      Colors.blue,
      Colors.red,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
      Colors.amber,
      Colors.cyan,
      Colors.lime,
      Colors.deepOrange,
      Colors.lightBlue,
      Colors.brown,
    ];
    return colors[index % colors.length];
  }

  String _getMostCommon(Map<String, int> data) {
    if (data.isEmpty) return 'データなし';
    return data.entries.reduce((a, b) => a.value > b.value ? a : b).key;
  }

  Color _getGenderColor(String gender) {
    switch (gender) {
      case '男性':
        return Colors.blue;
      case '女性':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }
}

class GenderPieChartPainter extends CustomPainter {
  final Map<String, int> genderData;
  final int totalVisitors;

  GenderPieChartPainter(this.genderData, this.totalVisitors);

  @override
  void paint(Canvas canvas, Size size) {
    if (totalVisitors == 0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 20;
    
    double startAngle = -math.pi / 2;
    
    final colors = [Colors.blue, Colors.red, Colors.grey];
    int colorIndex = 0;
    
    for (final entry in genderData.entries) {
      final sweepAngle = (entry.value / totalVisitors) * 2 * math.pi;
      
      final paint = Paint()
        ..color = colors[colorIndex % colors.length]
        ..style = PaintingStyle.fill;
      
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        true,
        paint,
      );
      
      startAngle += sweepAngle;
      colorIndex++;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class AgeBarChartPainter extends CustomPainter {
  final Map<String, int> ageData;

  AgeBarChartPainter(this.ageData);

  @override
  void paint(Canvas canvas, Size size) {
    if (ageData.isEmpty) return;

    final paint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;

    final maxValue = ageData.values.isNotEmpty ? ageData.values.reduce(math.max) : 1;
    final barWidth = size.width / (ageData.length + 1);
    final maxHeight = size.height - 40;

    final ageGroups = ['10代', '20代', '30代', '40代', '50代', '60代', '70歳以上'];
    
    for (int i = 0; i < ageGroups.length; i++) {
      final ageGroup = ageGroups[i];
      final value = ageData[ageGroup] ?? 0;
      final barHeight = (value / maxValue) * maxHeight;
      
      final x = (i + 0.5) * barWidth;
      final y = size.height - barHeight - 20;
      
      canvas.drawRect(
        Rect.fromLTWH(x - barWidth * 0.3, y, barWidth * 0.6, barHeight),
        paint,
      );
      
      final textPainter = TextPainter(
        text: TextSpan(
          text: ageGroup,
          style: const TextStyle(fontSize: 12, color: Colors.black),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(x - textPainter.width / 2, size.height - 15),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

