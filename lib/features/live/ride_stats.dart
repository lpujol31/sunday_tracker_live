import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'elevation_stats.dart';

/// Statistiques dérivées d'un ride, recalculées côté web.
///
/// L'app mobile calcule D+, D−, vitesse max et temps en mouvement pendant la
/// sortie, mais ne les transmet PAS au live : `liveSessionRideJson()` n'envoie
/// dans `safety_sessions.ride_json` qu'une charge allégée (points, waypoints,
/// distance, durée, pauses). En revanche chaque point porte son altitude et son
/// horodatage — de quoi tout reconstituer ici, à partir de la même série de
/// mesures que celle vue par le téléphone.
///
/// Deux sources selon l'état du ride :
///   • terminé   → `ride_json.points` (dense, un point tous les ~5 m)
///   • en cours  → `safety_positions` (échantillonné toutes les ~15 s, et sans
///     altitude si la RPC ne projette pas la colonne : le dénivelé est alors
///     simplement indisponible, cf. [hasElevation])
class RideStats {
  /// Série d'altitudes (m), dans l'ordre chronologique.
  final List<double> altProfile;
  final double dPlus;
  final double dMinus;
  final double? altStart;
  final double? altEnd;

  /// Série de vitesses (km/h) entre points consécutifs.
  final List<double> speedProfile;
  final double avgSpeedKmh;
  final Duration movingTime;
  final Duration stoppedTime;

  const RideStats({
    required this.altProfile,
    required this.dPlus,
    required this.dMinus,
    required this.altStart,
    required this.altEnd,
    required this.speedProfile,
    required this.avgSpeedKmh,
    required this.movingTime,
    required this.stoppedTime,
  });

  static const empty = RideStats(
    altProfile: [],
    dPlus: 0,
    dMinus: 0,
    altStart: null,
    altEnd: null,
    speedProfile: [],
    avgSpeedKmh: 0,
    movingTime: Duration.zero,
    stoppedTime: Duration.zero,
  );

  /// Un profil plat à altitude constante = pas de vraie mesure GPS d'altitude
  /// (certains appareils renvoient 0). On préfère masquer la carte que d'afficher
  /// une ligne droite trompeuse.
  bool get hasElevation {
    if (altProfile.length < 2) return false;
    final range = altProfile.reduce(math.max) - altProfile.reduce(math.min);
    return range >= 1.0 || dPlus > 0;
  }

  bool get hasSpeed => speedProfile.length >= 2;

  bool get isEmpty => !hasElevation && !hasSpeed;

  /// Au-delà de ce trou entre deux points, la sortie était en pause : l'intervalle
  /// ne compte ni en mouvement ni à l'arrêt (le tracking était coupé).
  static const Duration _kPauseGap = Duration(seconds: 60);

  /// En-deçà, on considère l'utilisateur à l'arrêt (bruit GPS résiduel).
  static const double _kMovingThresholdKmh = 1.0;

  /// Vitesse aberrante : point GPS sauté, on l'écarte du profil.
  static const double _kMaxPlausibleKmh = 200.0;

  /// [samples] doit être trié chronologiquement.
  /// [distanceMeters] / [duration] sont les valeurs déjà affichées par la page :
  /// on en dérive la vitesse moyenne plutôt que de la recalculer, pour qu'elle
  /// reste cohérente avec la distance et la durée montrées juste à côté.
  /// [altitudeOffsetMeters] : décalage GPS ↔ niveau de la mer établi par l'app à
  /// la sauvegarde (le GPS mesure au-dessus de l'ellipsoïde WGS84, ~50 m trop
  /// haut en Ariège). Sans lui, le live afficherait des altitudes différentes de
  /// celles du téléphone pour la même sortie.
  factory RideStats.fromSamples(
    List<RideSample> samples, {
    required double distanceMeters,
    required Duration duration,
    double? altitudeOffsetMeters,
  }) {
    if (samples.length < 2) return empty;

    // Dénivelé : exactement la même chaîne de filtrage que le mobile
    // (elevation_stats.dart, copie miroir). Cumuler les altitudes brutes point à
    // point transformait le bruit GPS en dénivelé — un col de 990 m rendait
    // +2796 m de D+. Le profil tracé est la série filtrée, pas les mesures.
    final elevSamples = <ElevationSample>[];
    for (final s in samples) {
      final alt = s.altitude;
      final t = s.time;
      if (alt == null || t == null) continue;
      elevSamples.add(ElevationSample(t, alt));
    }
    final elev =
        computeElevationStats(elevSamples).shifted(altitudeOffsetMeters);
    final alts = elev.smoothed;

    final speeds = <double>[];
    var moving = Duration.zero;
    for (var i = 1; i < samples.length; i++) {
      final prev = samples[i - 1];
      final cur = samples[i];
      final t1 = prev.time;
      final t2 = cur.time;
      if (t1 == null || t2 == null) continue;
      final step = t2.difference(t1);
      if (step <= Duration.zero || step > _kPauseGap) continue;
      final meters = _haversineMeters(prev.lat, prev.lng, cur.lat, cur.lng);
      final kmh = (meters / (step.inMilliseconds / 1000)) * 3.6;
      if (kmh < 0 || kmh >= _kMaxPlausibleKmh) continue;
      speeds.add(kmh);
      if (kmh > _kMovingThresholdKmh) moving += step;
    }

    // Le temps à l'arrêt se déduit de la durée affichée (et non de la somme des
    // intervalles) : les deux valeurs se recomposent alors exactement en la durée
    // que l'utilisateur voit juste au-dessus.
    if (moving > duration) moving = duration;
    final stopped = duration - moving;

    final hours = duration.inMilliseconds / 3600000;
    final avgSpeedKmh = hours > 0 ? (distanceMeters / 1000) / hours : 0.0;

    return RideStats(
      altProfile: alts,
      dPlus: elev.gain,
      dMinus: elev.loss,
      altStart: elev.altStart,
      altEnd: elev.altEnd,
      speedProfile: speeds,
      avgSpeedKmh: avgSpeedKmh,
      movingTime: moving,
      stoppedTime: stopped,
    );
  }

  static double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final p1 = lat1 * math.pi / 180;
    final p2 = lat2 * math.pi / 180;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLng = (lng2 - lng1) * math.pi / 180;
    final sinLat = math.sin(dLat / 2);
    final sinLng = math.sin(dLng / 2);
    final h = sinLat * sinLat + math.cos(p1) * math.cos(p2) * sinLng * sinLng;
    return 2 * r * math.asin(math.sqrt(h));
  }
}

/// Une mesure GPS, quelle que soit sa provenance (ride_json ou safety_positions).
class RideSample {
  final double lat;
  final double lng;
  final double? altitude;
  final DateTime? time;

  const RideSample({required this.lat, required this.lng, this.altitude, this.time});

  /// Point de `ride_json.points` : `{lat, lng, alt, ts}` (ride terminé).
  static RideSample? fromRideJsonPoint(Map<String, dynamic> p) {
    final lat = p['lat'] as num?;
    final lng = p['lng'] as num?;
    if (lat == null || lng == null) return null;
    // 'ts' est la clé écrite par l'app ; 'time'/'timestamp' couvrent les sorties
    // enregistrées par d'anciennes versions.
    final rawTime = p['ts'] ?? p['time'] ?? p['timestamp'];
    return RideSample(
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      altitude: (p['alt'] as num?)?.toDouble(),
      time: rawTime is String ? DateTime.tryParse(rawTime) : null,
    );
  }

  /// Ligne de `safety_positions` (ride en cours). La colonne `altitude` existe en
  /// base mais peut ne pas être projetée par la RPC : on la lit défensivement.
  static RideSample? fromPosition(Map<String, dynamic> p) {
    final lat = p['latitude'] as num?;
    final lng = p['longitude'] as num?;
    if (lat == null || lng == null) return null;
    return RideSample(
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      altitude: (p['altitude'] as num?)?.toDouble(),
      time: DateTime.tryParse(p['created_at'] ?? ''),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// PAINTER : profil altimétrique — porté de l'écran détail du ride (mobile)
// ════════════════════════════════════════════════════════════════════════════
class AltitudeProfilePainter extends CustomPainter {
  final List<double> alts;
  final double? altStart;
  final double? altEnd;

  const AltitudeProfilePainter(this.alts, {this.altStart, this.altEnd});

  @override
  void paint(Canvas canvas, Size size) {
    if (alts.length < 2) return;

    final minAlt = alts.reduce(math.min);
    final maxAlt = alts.reduce(math.max);
    final range = (maxAlt - minAlt).clamp(1.0, double.infinity);

    // Espace réservé : en haut pour ALT MAX + badges coins,
    // en bas pour ALT MIN placé sous le point minimum.
    const topPad = 50.0;
    const botPad = 46.0;
    final drawH = size.height - topPad - botPad;

    double xOf(int i) => i / (alts.length - 1) * size.width;
    double yOf(double alt) => topPad + drawH - ((alt - minAlt) / range) * drawH;

    final linePath = ui.Path()..moveTo(xOf(0), yOf(alts[0]));
    for (var i = 1; i < alts.length; i++) {
      linePath.lineTo(xOf(i), yOf(alts[i]));
    }

    canvas.drawPath(
      ui.Path.from(linePath)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close(),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, topPad),
          Offset(0, size.height),
          [
            const Color(0xFFfb923c).withValues(alpha: 0.40),
            const Color(0xFFfb923c).withValues(alpha: 0.01),
          ],
        )
        ..style = PaintingStyle.fill,
    );

    canvas.drawPath(
      linePath,
      Paint()
        ..color = const Color(0xFFfb923c)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    var maxIdx = 0, minIdx = 0;
    for (var i = 1; i < alts.length; i++) {
      if (alts[i] > alts[maxIdx]) maxIdx = i;
      if (alts[i] < alts[minIdx]) minIdx = i;
    }

    TextPainter tp(String text, double fs, Color color,
            {FontWeight fw = FontWeight.w600, double ls = 0}) =>
        TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(fontSize: fs, fontWeight: fw, color: color, letterSpacing: ls),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

    void drawMarker(double x, double y, {double r = 4.5, double alpha = 1.0}) {
      canvas.drawCircle(Offset(x, y), r, Paint()..color = const Color(0xFF111111));
      canvas.drawCircle(
        Offset(x, y),
        r,
        Paint()
          ..color = const Color(0xFFfb923c).withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
    }

    void drawConnector(double x1, double y1, double x2, double y2, {double alpha = 0.35}) {
      canvas.drawLine(
        Offset(x1, y1),
        Offset(x2, y2),
        Paint()
          ..color = const Color(0xFFfb923c).withValues(alpha: alpha)
          ..strokeWidth = 0.8,
      );
    }

    // Badge coin (DÉPART / ARRIVÉE) : ancré au coin, relié au vrai point par un
    // trait discret — priorité visuelle secondaire.
    void drawCornerBadge(int idx, String label, String value, {required bool isLeft}) {
      final px = xOf(idx);
      final py = yOf(alts[idx]);

      final tpL = tp(label, 8, const Color(0xFF777777), ls: 0.3);
      final tpV = tp(value, 10, const Color(0xFFCCCCCC), fw: FontWeight.w700);

      const hP = 6.0;
      const vP = 3.5;
      const lG = 1.5;
      final bw = math.max(tpL.width, tpV.width) + hP * 2;
      final bh = tpL.height + lG + tpV.height + vP * 2;
      final bx = isLeft ? 2.0 : size.width - bw - 2;
      const by = 2.0;

      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(bx, by, bw, bh), const Radius.circular(6)),
        Paint()..color = const Color(0xFF1A1E22).withValues(alpha: 0.88),
      );
      tpL.paint(canvas, Offset(bx + (bw - tpL.width) / 2, by + vP));
      tpV.paint(canvas, Offset(bx + (bw - tpV.width) / 2, by + vP + tpL.height + lG));

      final anchorX = bx + (isLeft ? bw : 0);
      final anchorY = by + bh / 2;
      drawConnector(anchorX, anchorY, px, py, alpha: 0.25);
      drawMarker(px, py, r: 3.5, alpha: 0.55);
    }

    // Badge principal (ALT MAX / ALT MIN) — priorité forte, dessiné par-dessus.
    void drawMainBadge(int idx, String label, String value,
        {required bool above, bool highlighted = false}) {
      final x = xOf(idx);
      final y = yOf(alts[idx]);

      const hP = 8.0;
      const vP = 5.0;
      const lG = 2.0;
      const gap = 7.0;

      final tpL = tp(label, 9,
          highlighted ? Colors.white.withValues(alpha: 0.92) : const Color(0xFFbbbbbb),
          ls: 0.3);
      final tpV = tp(value, 13, Colors.white, fw: FontWeight.bold);

      final bw = math.max(tpL.width, tpV.width) + hP * 2;
      final bh = tpL.height + lG + tpV.height + vP * 2;

      final bx = (x - bw / 2).clamp(2.0, math.max(2.0, size.width - bw - 2)).toDouble();
      final by = (above
              ? (y - 4.5 - gap - bh).clamp(0.0, math.max(0.0, size.height - bh - 2))
              : (y + 4.5 + gap).clamp(0.0, math.max(0.0, size.height - bh - 2)))
          .toDouble();

      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(bx, by, bw, bh), const Radius.circular(8)),
        Paint()..color = highlighted ? const Color(0xFFe07820) : const Color(0xFF21262D),
      );
      tpL.paint(canvas, Offset(bx + (bw - tpL.width) / 2, by + vP));
      tpV.paint(canvas, Offset(bx + (bw - tpV.width) / 2, by + vP + tpL.height + lG));

      final connY1 = above ? by + bh + 1 : by - 1;
      final connY2 = above ? y - 4.5 : y + 4.5;
      drawConnector(x, connY1, x, connY2, alpha: highlighted ? 0.55 : 0.35);
      drawMarker(x, y, alpha: highlighted ? 1.0 : 0.8);
    }

    drawCornerBadge(0, 'DÉPART', '${(altStart ?? alts.first).toStringAsFixed(0)} m', isLeft: true);
    drawCornerBadge(alts.length - 1, 'ARRIVÉE', '${(altEnd ?? alts.last).toStringAsFixed(0)} m',
        isLeft: false);
    drawMainBadge(minIdx, 'ALT MIN', '${alts[minIdx].toStringAsFixed(0)} m', above: false);
    drawMainBadge(maxIdx, 'ALT MAX', '${alts[maxIdx].toStringAsFixed(0)} m',
        above: true, highlighted: true);
  }

  @override
  bool shouldRepaint(AltitudeProfilePainter old) =>
      old.alts != alts || old.altStart != altStart || old.altEnd != altEnd;
}

// ════════════════════════════════════════════════════════════════════════════
// PAINTER : profil de vitesse — porté de l'écran détail du ride (mobile)
// ════════════════════════════════════════════════════════════════════════════
class SpeedProfilePainter extends CustomPainter {
  final List<double> speeds;

  const SpeedProfilePainter(this.speeds);

  /// Moyenne glissante (fenêtre 5) : la vitesse brute entre deux fixes GPS est
  /// trop bruitée pour être tracée telle quelle.
  List<double> _smooth(List<double> data) {
    const w = 5;
    final out = <double>[];
    for (var i = 0; i < data.length; i++) {
      final lo = (i - w ~/ 2).clamp(0, data.length - 1);
      final hi = (i + w ~/ 2).clamp(0, data.length - 1);
      var sum = 0.0;
      for (var j = lo; j <= hi; j++) {
        sum += data[j];
      }
      out.add(sum / (hi - lo + 1));
    }
    return out;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (speeds.length < 2) return;

    final smoothed = _smooth(speeds);

    // Le pic local sert TOUJOURS de référence d'échelle → le max est toujours en haut.
    final peak = smoothed.reduce(math.max).clamp(1.0, 300.0);

    const topPad = 54.0; // réservé au badge MAX + son connecteur
    const botPad = 4.0;
    final drawH = size.height - topPad - botPad;

    double xOf(int i) => i / (smoothed.length - 1) * size.width;
    double yOf(double s) => topPad + drawH - (s / peak) * drawH;

    final fillPath = ui.Path()..moveTo(xOf(0), yOf(smoothed[0]));
    for (var i = 1; i < smoothed.length; i++) {
      fillPath.lineTo(xOf(i), yOf(smoothed[i]));
    }
    fillPath
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, topPad),
          Offset(0, size.height),
          [
            const Color(0xFF60a5fa).withValues(alpha: 0.18),
            const Color(0xFF60a5fa).withValues(alpha: 0.01),
          ],
        )
        ..style = PaintingStyle.fill,
    );

    final linePath = ui.Path()..moveTo(xOf(0), yOf(smoothed[0]));
    for (var i = 1; i < smoothed.length; i++) {
      linePath.lineTo(xOf(i), yOf(smoothed[i]));
    }
    canvas.drawPath(
      linePath,
      Paint()
        ..color = const Color(0xFF60a5fa)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    var maxIdx = 0;
    for (var i = 1; i < smoothed.length; i++) {
      if (smoothed[i] > smoothed[maxIdx]) maxIdx = i;
    }
    final px = xOf(maxIdx);
    final py = yOf(smoothed[maxIdx]);

    final valStr = '${speeds.reduce(math.max).toStringAsFixed(1)} km/h';
    final tpLabel = TextPainter(
      text: const TextSpan(
        text: 'MAX',
        style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            color: Color(0xFFbfdbfe),
            letterSpacing: 1.0),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final tpVal = TextPainter(
      text: TextSpan(
        text: valStr,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.white),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    const hP = 10.0;
    const vP = 6.0;
    const lineGap = 2.0;
    final bw = math.max(tpLabel.width, tpVal.width) + hP * 2;
    final bh = tpLabel.height + lineGap + tpVal.height + vP * 2;

    const byFixed = 2.0;
    final bx = (px - bw / 2).clamp(2.0, math.max(2.0, size.width - bw - 2)).toDouble();

    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(bx, byFixed, bw, bh), const Radius.circular(8)),
      Paint()..color = const Color(0xFF1e3a8a),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(bx, byFixed, bw, bh), const Radius.circular(8)),
      Paint()
        ..color = const Color(0xFF60a5fa)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    tpLabel.paint(canvas, Offset(bx + (bw - tpLabel.width) / 2, byFixed + vP));
    tpVal.paint(
        canvas, Offset(bx + (bw - tpVal.width) / 2, byFixed + vP + tpLabel.height + lineGap));

    final connY1 = byFixed + bh + 1;
    final connY2 = py - 5;
    if (connY2 > connY1) {
      canvas.drawLine(
        Offset(px, connY1),
        Offset(px, connY2),
        Paint()
          ..color = const Color(0xFF60a5fa).withValues(alpha: 0.6)
          ..strokeWidth = 1.0,
      );
    }

    canvas.drawCircle(Offset(px, py), 4.5, Paint()..color = const Color(0xFF1e3a8a));
    canvas.drawCircle(
      Offset(px, py),
      4.5,
      Paint()
        ..color = const Color(0xFF93c5fd)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );
  }

  @override
  bool shouldRepaint(SpeedProfilePainter old) => old.speeds != speeds;
}
