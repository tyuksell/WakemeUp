import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../../core/theme/app_colors.dart';
import '../../../../core/services/hive_service.dart';
import '../../../../core/services/background_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/grain_overlay.dart';

class _HistoryEntry {
  final String destinationName;
  final String status;
  final bool isMuted;
  final DateTime createdAt;

  _HistoryEntry({
    required this.destinationName,
    required this.status,
    required this.isMuted,
    required this.createdAt,
  });

  factory _HistoryEntry.fromJson(Map<String, dynamic> json) => _HistoryEntry(
        destinationName: json['destination_name'] as String? ?? 'Hedef',
        status: json['status'] as String? ?? 'PENDING',
        isMuted: json['is_muted'] as bool? ?? false,
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? '')?.toLocal() ?? DateTime.now(),
      );
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  bool _isLoading = true;
  String? _error;
  List<_HistoryEntry> _entries = const [];

  /// SORUN 6 DÜZELTMESİ: Render'ın ücretsiz katmanı 15 dakika hareketsizlikten
  /// sonra uykuya geçer; ilk isteğe cevap 30-50sn gecikebilir. İlk deneme kısa
  /// zaman aşımıyla (8sn) başarısız olursa bunu "internet yok" gibi göstermek
  /// yanıltıcıdır — kullanıcıya sunucunun uyanmakta olduğunu belirtip daha
  /// uzun bir zaman aşımıyla bir kez daha deneriz.
  bool _isWakingServer = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool isRetry = false}) async {
    setState(() {
      _isLoading = true;
      _error = null;
      if (!isRetry) _isWakingServer = false;
    });
    try {
      final deviceId = await HiveService.getOrCreateDeviceId();
      final response = await http.get(
        Uri.parse('${MyBackgroundService.serverBaseUrl}/api/routes/'),
        headers: {'X-Device-Id': deviceId},
      ).timeout(Duration(seconds: isRetry ? 45 : 8));

      if (response.statusCode == 200) {
        final List raw = jsonDecode(response.body) as List;
        setState(() {
          _entries = raw
              .whereType<Map<String, dynamic>>()
              .map(_HistoryEntry.fromJson)
              .toList(growable: false);
          _isLoading = false;
          _isWakingServer = false;
        });
      } else {
        setState(() {
          _error = 'Geçmiş yüklenemedi (${response.statusCode}).';
          _isLoading = false;
          _isWakingServer = false;
        });
      }
    } on TimeoutException {
      if (!isRetry) {
        // İlk deneme zaman aşımına uğradı: bu genelde soğuk başlangıç
        // (cold start) belirtisidir, gerçek bağlantı sorunundan çok daha
        // olasıdır. Kullanıcıyı bilgilendirip daha uzun zaman aşımıyla
        // tek seferlik bir retry yapıyoruz.
        setState(() => _isWakingServer = true);
        await _load(isRetry: true);
      } else if (mounted) {
        setState(() {
          _error = 'Sunucuya ulaşılamadı. Lütfen birazdan tekrar deneyin.';
          _isLoading = false;
          _isWakingServer = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'İnternet bağlantısı olmadan geçmiş rotalar görüntülenemez.';
        _isLoading = false;
        _isWakingServer = false;
      });
    }
  }

  ({Color color, String label}) _statusVisual(_HistoryEntry entry) {
    switch (entry.status) {
      case 'ARRIVED':
        // Not: Backend bu durumu gerçek varışta (5m) değil, "yakın" eşiğinde
        // (varsayılan 250m, kullanıcı tarafından ayarlanabilir) set ediyor —
        // bu yüzden etiket "yaklaşıldı" diyor, "vardı" değil.
        return (color: AppColors.neonCyan, label: 'Hedefe Yaklaşıldı');
      case 'ACTIVE':
        return (color: AppColors.neonBlue, label: 'Takip Ediliyor');
      case 'MUTED':
        return (color: AppColors.neonPink, label: entry.isMuted ? 'Susturuldu' : 'İptal Edildi');
      default:
        return (color: AppColors.textGrey, label: 'Başlatılmadı');
    }
  }

  String _formatDate(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}.${two(dt.month)}.${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Geçmiş Rotalar'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Stack(
        children: [
          const GrainOverlay(),
          SafeArea(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _buildBody(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            if (_isWakingServer) ...[
              const SizedBox(height: 16),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'Sunucu uyanıyor, tekrar deneniyor...',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textGrey, fontSize: 13),
                ),
              ),
            ],
          ],
        ),
      );
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 80),
          Icon(Icons.wifi_off_rounded, color: AppColors.textGrey, size: 40),
          const SizedBox(height: 16),
          Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textGrey)),
        ],
      );
    }
    if (_entries.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: const [
          SizedBox(height: 80),
          Icon(Icons.history_rounded, color: AppColors.textGrey, size: 40),
          SizedBox(height: 16),
          Text(
            'Henüz bir rota geçmişiniz yok.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textGrey),
          ),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(24),
      itemCount: _entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final entry = _entries[index];
        final visual = _statusVisual(entry);
        return GlassCard(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(right: 14),
                decoration: BoxDecoration(color: visual.color, shape: BoxShape.circle),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.destinationName,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(_formatDate(entry.createdAt),
                        style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                  ],
                ),
              ),
              Text(
                visual.label,
                style: TextStyle(color: visual.color, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        );
      },
    );
  }
}
