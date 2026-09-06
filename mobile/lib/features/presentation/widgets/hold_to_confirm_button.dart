import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/theme/app_theme.dart';

/// Yanlışlıkla (örn. cepte, yarı uykulu bir dokunuşla) tetiklenmemesi gereken
/// yıkıcı eylemler için: kullanıcı [holdDuration] boyunca basılı tutmazsa
/// hiçbir şey olmaz. Erken bırakma dolum animasyonunu geri sarar.
class HoldToConfirmButton extends StatefulWidget {
  final String text;
  final String holdingText;
  final Gradient gradient;
  final Duration holdDuration;
  final VoidCallback onConfirmed;

  const HoldToConfirmButton({
    super.key,
    required this.text,
    required this.holdingText,
    required this.onConfirmed,
    required this.gradient,
    this.holdDuration = const Duration(seconds: 3),
  });

  @override
  State<HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

class _HoldToConfirmButtonState extends State<HoldToConfirmButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.holdDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          HapticFeedback.heavyImpact();
          widget.onConfirmed();
          _controller.reset();
        }
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _start() {
    HapticFeedback.selectionClick();
    _controller.forward();
  }

  void _cancel() {
    if (_controller.status == AnimationStatus.forward) {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (_) => _start(),
      onLongPressEnd: (_) => _cancel(),
      onLongPressCancel: _cancel,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final double progress = _controller.value;
          return Container(
            height: 60,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              gradient: widget.gradient,
              borderRadius: BorderRadius.circular(30),
              boxShadow: [
                BoxShadow(
                  color: widget.gradient.colors.first.withOpacity(0.4),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: progress,
                    child: Container(color: Colors.white.withOpacity(0.35)),
                  ),
                ),
                Text(
                  progress > 0.02 ? widget.holdingText : widget.text,
                  textAlign: TextAlign.center,
                  style: AppTheme.sora(color: Colors.white, fontSize: 15, letterSpacing: 1.0),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
