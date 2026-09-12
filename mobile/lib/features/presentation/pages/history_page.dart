import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/services/hive_service.dart';
import '../../../../core/services/route_launcher.dart';
import '../widgets/glass_card.dart';
import '../widgets/grain_overlay.dart';
import '../widgets/center_toast.dart';
import '../../../l10n/app_localizations.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  AppLocalizations get l10n => AppLocalizations.of(context)!;

  bool _isLoading = true;
  List<RouteHistoryEntry> _entries = const [];

  /// Şu an "tekrar başlat" ile yeniden başlatılmakta olan kaydın id'si —
  /// yalnızca o satırda küçük bir yükleniyor göstergesi için kullanılır.
  String? _launchingId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    // Geçmiş, sunucudan değil cihazın kendi hafızasından (Hive) okunur —
    // böylece backend'in ücretsiz katmanı uykuya geçse veya internet
    // olmasa bile geçmiş rotalar kaybolmaz.
    final entries = await HiveService.getHistory();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _isLoading = false;
    });
  }

  Future<void> _deleteEntry(RouteHistoryEntry entry) async {
    final removed = entry;
    final removedIndex = _entries.indexOf(entry);
    setState(() => _entries = _entries.where((e) => e.id != entry.id).toList());
    await HiveService.removeHistoryEntry(entry.id);
    if (!mounted) return;
    CenterToast.show(
      context,
      message: l10n.historyDeletedToast(removed.destinationName),
      type: ToastType.error,
      actionLabel: l10n.commonUndo,
      onAction: () async {
        final restored = [..._entries];
        final insertAt = removedIndex.clamp(0, restored.length);
        restored.insert(insertAt, removed);
        setState(() => _entries = restored);
        await HiveService.addHistoryEntry(removed);
      },
    );
  }

  /// Bu geçmiş kaydındaki hedefi aynen kullanarak yeni bir takip oturumu
  /// başlatır — map_page.dart'taki "Konumu Onayla ve Başlat" ile birebir
  /// aynı akışı (RouteLauncher) izler.
  Future<void> _restartRoute(RouteHistoryEntry entry) async {
    setState(() => _launchingId = entry.id);
    await RouteLauncher.launch(
      context: context,
      destName: entry.destinationName,
      lat: entry.lat,
      lng: entry.lng,
    );
    if (mounted) setState(() => _launchingId = null);
  }

  Future<void> _confirmClearAll() async {
    if (_entries.isEmpty) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.historyClearAllTitle),
        content: Text(l10n.historyClearAllContent),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.commonCancel)),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.historyClearAllConfirm, style: const TextStyle(color: AppColors.neonPink)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await HiveService.clearHistory();
    if (!mounted) return;
    setState(() => _entries = const []);
  }

  ({Color color, String label}) _statusVisual(RouteHistoryEntry entry) {
    switch (entry.status) {
      case 'ARRIVED':
        // Not: Bu durum gerçek varışta (5m) değil, "yakın" eşiğinde
        // (varsayılan 250m, kullanıcı tarafından ayarlanabilir) set edilir —
        // bu yüzden etiket "yaklaşıldı" diyor, "vardı" değil.
        return (color: AppColors.neonCyan, label: l10n.historyStatusApproached);
      case 'ACTIVE':
        return (color: AppColors.neonBlue, label: l10n.historyStatusActive);
      case 'MUTED':
        return (
          color: AppColors.neonPink,
          label: entry.isMuted ? l10n.historyStatusMuted : l10n.historyStatusCancelled,
        );
      default:
        return (color: AppColors.textGrey, label: l10n.historyStatusNotStarted);
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
        title: Text(l10n.historyTitle),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (_entries.isNotEmpty)
            IconButton(
              tooltip: l10n.historyClearAllTooltip,
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _confirmClearAll,
            ),
        ],
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
      return const Center(child: CircularProgressIndicator());
    }
    if (_entries.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 80),
          const Icon(Icons.history_rounded, color: AppColors.textGrey, size: 40),
          const SizedBox(height: 16),
          Text(
            l10n.historyEmptyHint,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textGrey),
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
        return Dismissible(
          key: ValueKey(entry.id),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: BoxDecoration(
              color: AppColors.neonPink.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.delete_outline_rounded, color: AppColors.neonPink),
          ),
          onDismissed: (_) => _deleteEntry(entry),
          child: GlassCard(
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
                      Row(
                        children: [
                          Text(_formatDate(entry.createdAt),
                              style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              visual.label,
                              style: TextStyle(color: visual.color, fontSize: 12, fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (_launchingId == entry.id)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    tooltip: l10n.historyRestartTooltip,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.replay_rounded, size: 20, color: AppColors.neonCyan),
                    onPressed: _launchingId == null ? () => _restartRoute(entry) : null,
                  ),
                IconButton(
                  tooltip: l10n.historyDeleteTooltip,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.textGrey),
                  onPressed: () => _deleteEntry(entry),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
