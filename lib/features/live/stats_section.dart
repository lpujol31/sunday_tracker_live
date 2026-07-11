import 'package:flutter/material.dart';

import 'ride_stats.dart';

/// Cartes « Dénivelé » et « Vitesse », reprises de l'écran détail du ride de
/// l'app mobile. Partagées par le volet desktop et le panneau smartphone.
///
/// Volontairement, aucune de ces cartes ne répète la distance, la durée ni
/// l'heure de départ : elles sont déjà affichées ailleurs sur la page (barre du
/// bas en desktop, en-tête du panneau en mobile).
class RideStatsSection extends StatelessWidget {
  final RideStats stats;

  /// `true` tant que la sortie n'est pas terminée : les stats sont alors
  /// calculées sur les positions de suivi (échantillon plus grossier que le
  /// tracé final) et continueront d'évoluer.
  final bool live;

  const RideStatsSection({super.key, required this.stats, required this.live});

  @override
  Widget build(BuildContext context) {
    if (stats.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text(
          'Statistiques indisponibles : pas encore assez de points GPS.',
          style: TextStyle(color: Colors.white38, fontSize: 13, height: 1.5),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (stats.hasElevation) ...[
          _buildElevationCard(),
          const SizedBox(height: 10),
        ],
        if (stats.hasSpeed) ...[
          _buildSpeedCard(),
          const SizedBox(height: 10),
        ],
        if (live) _buildLiveNotice(),
      ],
    );
  }

  /// Pendant la sortie, les stats reposent sur les positions envoyées toutes les
  /// ~15 s (et non sur le tracé dense) : on le dit plutôt que de laisser croire à
  /// des valeurs définitives.
  Widget _buildLiveNotice() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 13, color: Colors.white30),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Estimations en cours de sortie, affinées à l\'arrivée.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 11, height: 1.4),
          ),
        ),
      ],
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF171B1F),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: child,
    );
  }

  Widget _cardTitle(IconData icon, Color color, String label) {
    return Row(children: [
      Icon(icon, size: 15, color: color),
      const SizedBox(width: 7),
      Text(label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
    ]);
  }

  // ── Dénivelé ───────────────────────────────────────────────────────────────
  Widget _buildElevationCard() {
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _cardTitle(Icons.trending_up, const Color(0xFFfb923c), 'Dénivelé'),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(
            child: SizedBox(
              height: 180,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: ColoredBox(
                  color: const Color(0xFF111111),
                  child: CustomPaint(
                    painter: AltitudeProfilePainter(
                      stats.altProfile,
                      altStart: stats.altStart,
                      altEnd: stats.altEnd,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _elevStatItem('+${stats.dPlus.toStringAsFixed(0)} m', 'D+', const Color(0xFFfb923c)),
              const SizedBox(height: 20),
              _elevStatItem('−${stats.dMinus.toStringAsFixed(0)} m', 'D−', const Color(0xFFa78bfa)),
            ],
          ),
        ]),
      ]),
    );
  }

  Widget _elevStatItem(String value, String label, Color color) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value,
          style: TextStyle(
              fontSize: 18, fontWeight: FontWeight.w800, color: color, letterSpacing: -0.5)),
      const SizedBox(height: 2),
      Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF666666))),
    ]);
  }

  // ── Vitesse ────────────────────────────────────────────────────────────────
  Widget _buildSpeedCard() {
    final movingSec = stats.movingTime.inSeconds;
    final stoppedSec = stats.stoppedTime.inSeconds;

    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _cardTitle(Icons.speed_outlined, const Color(0xFF60a5fa), 'Vitesse'),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('VITESSE MOYENNE',
                style: TextStyle(fontSize: 10, color: Color(0xFF666666), letterSpacing: 0.5)),
            const SizedBox(height: 6),
            Text('${stats.avgSpeedKmh.toStringAsFixed(1)} km/h',
                style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF60a5fa),
                    letterSpacing: -1)),
          ]),
          const SizedBox(width: 14),
          Expanded(
            child: SizedBox(
              height: 110,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CustomPaint(
                  painter: SpeedProfilePainter(stats.speedProfile),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 16),
        // Barre mouvement / arrêt : les deux se recomposent en la durée affichée
        // par ailleurs, on ne répète donc pas cette dernière ici.
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Row(children: [
            Expanded(
              flex: movingSec.clamp(1, 1 << 30),
              child: Container(height: 6, color: const Color(0xFF60a5fa)),
            ),
            if (stoppedSec > 0)
              Expanded(
                flex: stoppedSec,
                child: Container(height: 6, color: const Color(0xFF252525)),
              ),
          ]),
        ),
        const SizedBox(height: 8),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 5, children: [
          Text(_fmtCompactTime(movingSec),
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF60a5fa))),
          const Text('en mouvement', style: TextStyle(fontSize: 12, color: Color(0xFF8899aa))),
          const SizedBox(width: 5),
          Text(_fmtCompactTime(stoppedSec),
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFaabbcc))),
          const Text('arrêté', style: TextStyle(fontSize: 12, color: Color(0xFF8899aa))),
        ]),
      ]),
    );
  }

  String _fmtCompactTime(int seconds) {
    final d = Duration(seconds: seconds);
    if (d.inHours > 0) {
      return '${d.inHours}h${(d.inMinutes % 60).toString().padLeft(2, '0')}';
    }
    return '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }
}
