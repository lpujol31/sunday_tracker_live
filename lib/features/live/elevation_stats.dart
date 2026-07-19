import 'dart:math';

// ⚠️ COPIE MIROIR de sunday_tracker/lib/services/elevation_stats.dart.
// Le live et le mobile sont deux projets Flutter distincts, sans package
// commun : ce fichier doit rester identique à son jumeau, sans quoi la même
// sortie affichera deux dénivelés différents selon qu'on la regarde sur le
// téléphone ou sur la page live. Toute modification ici se reporte là-bas, et
// réciproquement.

/// Calcul du dénivelé à partir d'une trace GPS.
///
/// Le problème n'est pas celui qu'on croit. Le récepteur lui-même est bon : sur
/// une sortie réelle de 2 h 20, le bruit des altitudes vaut σ ≈ 1,35 m. Ce qui
/// détruit le calcul, c'est qu'**une mesure sur trois n'en est pas une** : entre
/// deux fixes GNSS, le fused provider Android ressert la dernière valeur connue,
/// à l'identique jusqu'au dernier bit, parfois pendant plusieurs minutes. Ces
/// paliers font 30 à 40 m de marche. Additionner naïvement chaque différence
/// point à point les compte en D+ *et* en D− : une sortie au col de Marrous
/// (600 m de D+ réel) rendait ainsi +2709 m.
///
/// La chaîne appliquée ici, dans l'ordre — le premier maillon est le seul qui
/// compte vraiment, les autres ne font que polir :
///   1. rejet des paliers figés (valeurs répétées bit à bit) ;
///   2. rejet des variations physiquement impossibles (vitesse verticale) ;
///   3. filtre médian court, pour les rares aberrations isolées ;
///   4. lissage de Kalman 1D bidirectionnel, qui absorbe le bruit résiduel sans
///      retarder le signal ;
///   5. accumulation à hystérésis : on ne compte un mètre que lorsque
///      l'altitude s'est écartée d'au moins [_kHysteresisMeters] du dernier
///      palier retenu.
///
/// Réglé contre une vérité terrain barométrique : la même sortie enregistrée en
/// parallèle sur un Garmin (altimètre à pression, autrement plus fiable qu'un
/// GPS) donne D+ 669 m et sommet 989 m. Cette chaîne rend **665 m et 991 m**,
/// soit 0,6 % d'écart — tout en produisant **0 m** de D+ sur 2 h de plat bruité.
/// Le harness `tool/replay_elevation.dart` rejoue n'importe quelle trace.
///
/// ⚠️ Les altitudes rendues ici restent celles du GPS, donc **au-dessus de
/// l'ellipsoïde WGS84**, pas du niveau de la mer : en Ariège elles sont ~50 m
/// trop hautes (le col de Marrous, 990 m, se mesure à 1041 m). Ce biais est
/// constant, donc sans effet sur le D+, mais il fausse les altitudes affichées.
/// Sa correction (ondulation du géoïde) n'est pas faite ici.
class ElevationSample {
  final DateTime time;
  final double altitude;
  const ElevationSample(this.time, this.altitude);
}

class ElevationStats {
  /// D+ cumulé, en mètres.
  final double gain;

  /// D− cumulé, en mètres (valeur positive).
  final double loss;

  final double? altMin;
  final double? altMax;
  final double? altStart;
  final double? altEnd;

  /// Série d'altitude filtrée, dans l'ordre des échantillons fournis. C'est
  /// elle qu'il faut tracer : le profil brut est illisible.
  final List<double> smoothed;

  const ElevationStats({
    required this.gain,
    required this.loss,
    required this.altMin,
    required this.altMax,
    required this.altStart,
    required this.altEnd,
    required this.smoothed,
  });

  static const ElevationStats empty = ElevationStats(
    gain: 0,
    loss: 0,
    altMin: null,
    altMax: null,
    altStart: null,
    altEnd: null,
    smoothed: <double>[],
  );

  /// Recale toutes les altitudes de [offset] mètres, sans toucher au D+/D− :
  /// le décalage GPS↔niveau de la mer est constant sur une sortie, donc il
  /// s'annule dans les différences (cf. AltitudeReferenceService). Un [offset]
  /// nul ou absent laisse les altitudes telles quelles.
  ElevationStats shifted(double? offset) {
    if (offset == null || offset == 0) return this;
    return ElevationStats(
      gain: gain,
      loss: loss,
      altMin: altMin == null ? null : altMin! - offset,
      altMax: altMax == null ? null : altMax! - offset,
      altStart: altStart == null ? null : altStart! - offset,
      altEnd: altEnd == null ? null : altEnd! - offset,
      smoothed: smoothed.map((a) => a - offset).toList(),
    );
  }
}

/// Vitesse verticale au-delà de laquelle une variation d'altitude ne peut pas
/// être réelle. Une descente à 80 km/h dans une pente à 12 % ne fait que
/// 2,7 m/s ; au-delà de 3 m/s c'est le capteur qui saute, pas le terrain.
const double _kMaxVerticalSpeedMs = 3.0;

/// Tolérance minimale accordée quel que soit l'intervalle : sans elle, deux
/// mesures rapprochées (1 s) rejetteraient un simple bruit de ±4 m.
const double _kMinJumpToleranceMeters = 8.0;

/// Au-delà de cet intervalle, on ne sait plus rien de ce qui s'est passé
/// (tunnel, perte de signal) : on se resynchronise sur la nouvelle mesure sans
/// compter le saut.
const Duration _kResyncGap = Duration(seconds: 45);

/// Fenêtre courte, volontairement : elle ne sert plus qu'à tuer les rares
/// aberrations isolées. Une fenêtre large écraserait les vrais changements
/// brusques — sur la trace du col de Marrous, une fenêtre de 5 supprimait la
/// descente finale sur Brassac, qui ne tenait qu'en deux mesures.
const int _kMedianWindow = 3;

/// Bruit de mesure (écart-type, en m) et bruit de process (m/√s) du Kalman.
///
/// Le R n'est pas deviné : une fois les paliers figés écartés, le bruit réel
/// des altitudes mesuré sur une trace de 2 h 20 (écart interquartile des
/// différences secondes, donc insensible aux aberrations restantes) vaut
/// σ ≈ 1,35 m. On prend 2 m pour garder une marge. C'est très loin des ±10 m
/// habituellement prêtés au GPS : ce chiffre-là décrivait en réalité les
/// valeurs collées, pas le récepteur — d'où l'importance de les retirer AVANT
/// de régler quoi que ce soit.
const double _kMeasurementNoise = 2.0;
const double _kProcessNoise = 1.0;

/// Hystérésis d'accumulation : en dessous, on considère qu'on est sur le même
/// palier. C'est le paramètre le plus sensible du lot — il arbitre directement
/// entre « compter du bruit » et « rater les vraies ondulations ». À 5 m, on
/// perdait 44 m de D+ sur la trace de référence en rabotant les faux plats ; à
/// 1 ou 2 m, le bruit repasse (jusqu'à +82 m de D+ sur du plat parfait). 3 m est
/// le seul point qui satisfait les deux.
const double _kHysteresisMeters = 3.0;

ElevationStats computeElevationStats(List<ElevationSample> samples) {
  if (samples.isEmpty) return ElevationStats.empty;

  // Les mesures figées sont écartées d'abord : elles ne sont pas du bruit à
  // lisser mais des non-mesures, et les laisser passer fausse tout ce qui suit.
  final real = _dropStale(samples);
  if (real.isEmpty) return ElevationStats.empty;

  final plausible = _rejectImplausibleJumps(real);
  final median = _medianFilter(plausible, _kMedianWindow);
  final smoothed = _kalmanSmooth(median, real);

  double gain = 0, loss = 0;
  double reference = smoothed.first;
  for (final alt in smoothed) {
    final delta = alt - reference;
    if (delta.abs() < _kHysteresisMeters) continue;
    if (delta > 0) {
      gain += delta;
    } else {
      loss += -delta;
    }
    reference = alt;
  }

  // Le profil doit rester aligné sur la liste de points d'origine (le graphe
  // trace un point par mesure GPS) : on ré-étale la série filtrée sur tous les
  // index, en interpolant là où la mesure avait été écartée.
  final profile = _resampleOnto(samples, real, smoothed);

  return ElevationStats(
    gain: gain,
    loss: loss,
    altMin: smoothed.reduce(min),
    altMax: smoothed.reduce(max),
    altStart: smoothed.first,
    altEnd: smoothed.last,
    smoothed: profile,
  );
}

/// Écarte les altitudes « collées » : sur Android, le fused provider ressert la
/// dernière valeur connue entre deux vrais fixes GNSS, à l'identique jusqu'au
/// dernier bit. Sur la trace du col de Marrous, un tiers des points étaient dans
/// ce cas — la même valeur `1044.699951171875` revenait 80 fois pendant qu'on
/// roulait. Un récepteur qui mesure vraiment ne rend jamais deux fois le même
/// flottant : l'égalité binaire exacte est donc une signature fiable, et bien
/// plus sûre qu'un seuil sur l'amplitude (ces paliers font 30 à 40 m, soit très
/// au-delà du bruit, mais très en-deçà d'un saut « impossible »).
///
/// Le palier saute *en entier*, première occurrence comprise : si une valeur est
/// ensuite répétée, c'est qu'elle était déjà tenue, et sa première apparition
/// n'est pas plus une mesure que les suivantes. Ne retirer que les répétitions
/// laissait un point fantôme en tête de chaque palier — dont un à 533 m juste
/// avant l'arrivée à Brassac, qui suffisait à fausser l'altitude d'arrivée.
List<ElevationSample> _dropStale(List<ElevationSample> samples) {
  final out = <ElevationSample>[];
  for (int i = 0; i < samples.length;) {
    int j = i;
    while (j + 1 < samples.length &&
        samples[j + 1].altitude == samples[i].altitude) {
      j++;
    }
    if (j == i) out.add(samples[i]);
    i = j + 1;
  }
  return out;
}

/// Interpole la série filtrée (calculée sur les seules vraies mesures) sur
/// l'ensemble des échantillons d'origine, par le temps.
List<double> _resampleOnto(
  List<ElevationSample> all,
  List<ElevationSample> kept,
  List<double> values,
) {
  if (kept.length == 1) {
    return List<double>.filled(all.length, values.first);
  }
  final out = List<double>.filled(all.length, values.first);
  int j = 0;
  for (int i = 0; i < all.length; i++) {
    final t = all[i].time;
    while (j + 1 < kept.length && kept[j + 1].time.isBefore(t)) {
      j++;
    }
    if (j + 1 >= kept.length) {
      out[i] = values.last;
      continue;
    }
    final t0 = kept[j].time;
    final t1 = kept[j + 1].time;
    final span = t1.difference(t0).inMilliseconds;
    if (span <= 0) {
      out[i] = values[j];
      continue;
    }
    final f = (t.difference(t0).inMilliseconds / span).clamp(0.0, 1.0);
    out[i] = values[j] + (values[j + 1] - values[j]) * f;
  }
  return out;
}

/// Remplace toute altitude qui impliquerait une vitesse verticale absurde par
/// la dernière altitude crédible. Après [_kResyncGap] sans mesure fiable, on
/// accepte la nouvelle valeur : le capteur a peut-être raison et nous tort.
List<double> _rejectImplausibleJumps(List<ElevationSample> samples) {
  final out = <double>[];
  double reference = samples.first.altitude;
  DateTime referenceTime = samples.first.time;

  for (final s in samples) {
    final gap = s.time.difference(referenceTime);
    final budget = _kMinJumpToleranceMeters +
        _kMaxVerticalSpeedMs * gap.inMilliseconds / 1000.0;

    if ((s.altitude - reference).abs() <= budget || gap >= _kResyncGap) {
      reference = s.altitude;
      referenceTime = s.time;
    }
    out.add(reference);
  }
  return out;
}

List<double> _medianFilter(List<double> values, int window) {
  if (values.length < window) return List<double>.from(values);
  final half = window ~/ 2;
  final out = List<double>.filled(values.length, 0);
  for (int i = 0; i < values.length; i++) {
    final lo = max(0, i - half);
    final hi = min(values.length - 1, i + half);
    final slice = values.sublist(lo, hi + 1)..sort();
    out[i] = slice[slice.length ~/ 2];
  }
  return out;
}

/// Lissage bidirectionnel : le même Kalman est passé dans le sens du temps puis
/// à rebours, et les deux estimations sont moyennées. Un filtre récursif seul
/// traîne derrière le signal — il écrête les sommets et rabote le début des
/// montées ; la passe arrière a un retard exactement opposé, donc la moyenne
/// des deux est sans déphasage. On peut se le permettre : le dénivelé est
/// recalculé sur la trace complète, jamais échantillon par échantillon.
List<double> _kalmanSmooth(List<double> values, List<ElevationSample> samples) {
  final forward = _kalmanPass(values, samples, reverse: false);
  final backward = _kalmanPass(values, samples, reverse: true);
  return List<double>.generate(
    values.length,
    (i) => (forward[i] + backward[i]) / 2,
  );
}

/// Kalman scalaire à marche aléatoire : l'incertitude croît avec le temps
/// écoulé, ce qui laisse le filtre reprendre la main après un trou de signal.
List<double> _kalmanPass(
  List<double> values,
  List<ElevationSample> samples, {
  required bool reverse,
}) {
  final n = values.length;
  final out = List<double>.filled(n, 0);
  final r = _kMeasurementNoise * _kMeasurementNoise;

  double estimate = values[reverse ? n - 1 : 0];
  double variance = r;

  for (int step = 0; step < n; step++) {
    final i = reverse ? n - 1 - step : step;
    final prev = reverse ? i + 1 : i - 1;
    final dt = (prev < 0 || prev >= n)
        ? 1.0
        : max(
            0.5,
            (samples[i].time.difference(samples[prev].time)).inMilliseconds
                    .abs() /
                1000.0,
          );
    variance += _kProcessNoise * _kProcessNoise * dt;
    final k = variance / (variance + r);
    estimate += k * (values[i] - estimate);
    variance *= (1 - k);
    out[i] = estimate;
  }
  return out;
}

/// Recalcule les stats d'altitude d'une sortie à partir de sa liste de points
/// (`{ts, lat, lng, alt}`), telle que stockée dans `ride_json.points`.
ElevationStats elevationStatsFromPoints(List<dynamic> points) {
  // Cadence nominale du tracker, utilisée quand un point n'a pas d'horodatage
  // exploitable. Le Kalman a besoin d'un dt : sans repli, ces sorties étaient
  // écartées en bloc et gardaient leur D+ gonflé (11 des 15 sorties du device
  // de test). Un dt approché vaut mieux qu'un dénivelé faux d'un facteur 4.
  const fallbackCadence = Duration(seconds: 5);

  final samples = <ElevationSample>[];
  DateTime? last;
  for (final p in points) {
    if (p is! Map) continue;
    final alt = p['alt'];
    if (alt is! num) continue;

    // 'ts' est la clé écrite aujourd'hui ; 'time' et 'timestamp' couvrent les
    // sorties enregistrées par d'anciennes versions (le viewer web accepte déjà
    // les trois — les deux lectures doivent rester d'accord).
    final raw = p['ts'] ?? p['time'] ?? p['timestamp'];
    final parsed = raw is String ? DateTime.tryParse(raw) : null;
    final time = parsed ?? (last?.add(fallbackCadence) ?? DateTime(2000));

    last = time;
    samples.add(ElevationSample(time, alt.toDouble()));
  }
  return computeElevationStats(samples);
}
