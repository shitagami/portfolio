import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/firebase_service.dart';

class VisitorManagementScreen extends StatefulWidget {
  final String? targetBoothId; // 特定ブースに絞る場合
  const VisitorManagementScreen({super.key, this.targetBoothId});

  @override
  State<VisitorManagementScreen> createState() => _VisitorManagementScreenState();
}

class _VisitorManagementScreenState extends State<VisitorManagementScreen> {
  final AuthService _authService = AuthService();
  final FirebaseService _firebaseService = FirebaseService();
  List<Map<String, dynamic>> _visitors = [];
  List<Map<String, dynamic>> _reservations = [];
  bool _isLoading = false;
  String _userName = '';
  String _filterType = 'all'; // 'all', 'prospects', 'non-prospects', 'reservations'

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final userName = await _authService.getUserName();
      final visitors = await _firebaseService.getAllVisitors(
        targetBoothId: widget.targetBoothId,
      );
      final reservations = await _firebaseService.getAllReservations();
      
      // 来場者データに予約情報を追加
      for (final visitor in visitors) {
        final userId = visitor['userId'];
        final reservation = reservations.firstWhere(
          (r) => r['userId'] == userId,
          orElse: () => {},
        );
        visitor['hasReservation'] = reservation.isNotEmpty;
        if (reservation.isNotEmpty) {
          visitor['reservedBoothId'] = reservation['boothId'];
        }
      }
      
      setState(() {
        _userName = userName;
        _visitors = visitors;
        _reservations = reservations;
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

  List<Map<String, dynamic>> get _filteredVisitors {
    switch (_filterType) {
      case 'prospects':
        return _visitors.where((v) => v['isProspect'] == true).toList();
      case 'non-prospects':
        return _visitors.where((v) => v['isProspect'] == false).toList();
      case 'reservations':
        return _reservations;
      default:
        return _visitors;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('来場者管理'),
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
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // フィルター選択
                Container(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Text(
                            'フィルター: ',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: SegmentedButton<String>(
                              segments: const [
                                ButtonSegment(
                                  value: 'all',
                                  label: Text('全来場者'),
                                  icon: Icon(Icons.people),
                                ),
                                ButtonSegment(
                                  value: 'prospects',
                                  label: Text('見込み客'),
                                  icon: Icon(Icons.star),
                                ),
                                ButtonSegment(
                                  value: 'reservations',
                                  label: Text('予約者'),
                                  icon: Icon(Icons.event_available),
                                ),
                              ],
                              selected: {_filterType},
                              onSelectionChanged: (Set<String> selection) {
                                setState(() {
                                  _filterType = selection.first;
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                
                // 統計情報
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Card(
                          color: Colors.blue.shade50,
                          child: Padding(
                            padding: const EdgeInsets.all(12.0),
                            child: Column(
                              children: [
                                Text(
                                  '${_visitors.length}',
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue,
                                  ),
                                ),
                                const Text('総来場者数'),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Card(
                          color: Colors.orange.shade50,
                          child: Padding(
                            padding: const EdgeInsets.all(12.0),
                            child: Column(
                              children: [
                                Text(
                                  '${_visitors.where((v) => v['isProspect'] == true).length}',
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.orange,
                                  ),
                                ),
                                const Text('見込み客数'),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Card(
                          color: Colors.purple.shade50,
                          child: Padding(
                            padding: const EdgeInsets.all(12.0),
                            child: Column(
                              children: [
                                Text(
                                  '${_reservations.length}',
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.purple.shade700,
                                  ),
                                ),
                                const Text('予約者数'),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 16),
                
                // 来場者リスト
                Expanded(
                  child: _filteredVisitors.isEmpty
                      ? const Center(
                          child: Text(
                            '来場者データがありません',
                            style: TextStyle(fontSize: 16, color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _filteredVisitors.length,
                          itemBuilder: (context, index) {
                            final visitor = _filteredVisitors[index];
                            
                            // 予約者の場合
                            if (_filterType == 'reservations') {
                              return Card(
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 16.0,
                                  vertical: 4.0,
                                ),
                                child: ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: Colors.purple.shade700,
                                    child: const Icon(
                                      Icons.event_available,
                                      color: Colors.white,
                                    ),
                                  ),
                                  title: Text(
                                    visitor['displayName'] ?? '未設定',
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('${visitor['age'] ?? '未設定'}歳・${visitor['gender'] ?? '未設定'}'),
                                      Text('職業: ${visitor['job'] ?? '未設定'}'),
                                      Container(
                                        margin: const EdgeInsets.only(top: 4),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.purple.shade700,
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          '予約ブース: ${visitor['boothId'] ?? '未設定'}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  trailing: const Icon(Icons.arrow_forward_ios),
                                  onTap: () => _showReservationDetails(visitor),
                                ),
                              );
                            }
                            
                            // 通常の来場者の場合
                            final isProspect = visitor['isProspect'] == true;
                            
                            return Card(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 16.0,
                                vertical: 4.0,
                              ),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: isProspect ? Colors.orange : Colors.blue,
                                  child: Icon(
                                    isProspect ? Icons.star : Icons.person,
                                    color: Colors.white,
                                  ),
                                ),
                                title: Text(
                                  visitor['displayName'] ?? '未設定',
                                  style: TextStyle(
                                    fontWeight: isProspect ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('${visitor['age'] ?? '未設定'}歳・${visitor['gender'] ?? '未設定'}'),
                                    Text('${visitor['totalTime'] ?? 0}分滞在・${visitor['visitCount'] ?? 0}回訪問'),
                                    Row(
                                      children: [
                                        if (isProspect)
                                          Container(
                                            margin: const EdgeInsets.only(top: 4, right: 8),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.orange,
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                            child: const Text(
                                              '見込み客',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        if (visitor['hasReservation'] == true)
                                          Container(
                                            margin: const EdgeInsets.only(top: 4),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.blue,
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                            child: const Text(
                                              '予約済み',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                                trailing: const Icon(Icons.arrow_forward_ios),
                                onTap: () => _showVisitorDetails(visitor),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }

  void _showVisitorDetails(Map<String, dynamic> visitor) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(visitor['displayName'] ?? '来場者詳細'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildDetailRow('メールアドレス', visitor['email'] ?? '未設定'),
                _buildDetailRow('年齢', '${visitor['age'] ?? '未設定'}歳'),
                _buildDetailRow('性別', visitor['gender'] ?? '未設定'),
                _buildDetailRow('職業', visitor['job'] ?? '未設定'),
                _buildDetailRow('情報源', visitor['eventSource'] ?? '未設定'),
                _buildDetailRow('興味分野', (visitor['interests'] as List<dynamic>?)?.join(', ') ?? '未設定'),
                const Divider(),
                _buildDetailRow('総滞在時間', '${visitor['totalTime'] ?? 0}分'),
                _buildDetailRow('総訪問回数', '${visitor['visitCount'] ?? 0}回'),
                _buildDetailRow('再訪問ブース数', '${visitor['revisitCount'] ?? 0}箇所'),
                _buildDetailRow('訪問ブース', (visitor['boothVisits'] as List<dynamic>?)?.join(', ') ?? 'なし'),
                const Divider(),
                _buildDetailRow('5分以上滞在', visitor['hasLongStay'] == true ? 'はい' : 'いいえ'),
                _buildDetailRow('ブース再訪問', visitor['hasRevisit'] == true ? 'はい' : 'いいえ'),
                _buildDetailRow('見込み客', visitor['isProspect'] == true ? 'はい' : 'いいえ'),
                if (visitor['hasReservation'] == true) ...[
                  const Divider(),
                  _buildDetailRow('ブース予約', visitor['reservedBoothId'] ?? '未設定'),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text(value.isEmpty ? '未設定' : value),
          ),
        ],
      ),
    );
  }

  void _showReservationDetails(Map<String, dynamic> reservation) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.event_available, color: Colors.purple.shade700),
              const SizedBox(width: 8),
              const Text('予約者詳細'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildDetailRow('氏名', reservation['displayName'] ?? '未設定'),
                _buildDetailRow('メールアドレス', reservation['email'] ?? '未設定'),
                _buildDetailRow('年齢', '${reservation['age'] ?? '未設定'}歳'),
                _buildDetailRow('性別', reservation['gender'] ?? '未設定'),
                _buildDetailRow('職業', reservation['job'] ?? '未設定'),
                _buildDetailRow('情報源', reservation['eventSource'] ?? '未設定'),
                _buildDetailRow('興味分野', (reservation['interests'] as List<dynamic>?)?.join(', ') ?? '未設定'),
                const Divider(),
                _buildDetailRow('予約ブース', reservation['boothId'] ?? '未設定'),
                if (reservation['hasVisitorInfo'] == false)
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.orange.shade700, size: 20),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            '来場者情報未登録',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
  }
}
