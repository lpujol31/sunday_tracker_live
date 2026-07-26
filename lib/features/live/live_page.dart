import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';

import 'ride_stats.dart';
import 'stats_section.dart';
import 'waypoint_kind.dart';

const List<Map<String, dynamic>> kMapStyles = [
  {
    'label': 'Plan',
    'icon': Icons.map,
    'url': 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    'subdomains': <String>[],
    'maxZoom': 19,
  },
  {
    'label': 'Satellite',
    'icon': Icons.satellite_alt,
    'url':
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    'subdomains': <String>[],
    'maxZoom': 19,
  },
  {
    'label': 'Topo',
    'icon': Icons.terrain,
    'url': 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
    'subdomains': <String>['a', 'b', 'c'],
    'maxZoom': 17,
  },
];

List<Color> _buildGradientColors(int count) {
  const colors = [
    Color(0xFFFF8A00),
    Color(0xFFD946EF),
    Color(0xFF6D28D9),
  ];
  if (count <= 1) return [colors.first];
  return List.generate(count, (i) {
    final t = i / (count - 1);
    if (t <= 0.5) {
      return Color.lerp(colors[0], colors[1], t / 0.5)!;
    } else {
      return Color.lerp(colors[1], colors[2], (t - 0.5) / 0.5)!;
    }
  });
}

/// Au-delà de ce trou entre deux positions, on considère que la sortie était en
/// pause (le tracking envoie un point toutes les 5 à 15 s).
const Duration _kPauseGap = Duration(seconds: 60);

/// Contenu du volet latéral desktop, sélectionné par les onglets verticaux du
/// bord droit.
enum _SidePanel { waypoints, stats }

// ── Marqueur « recherche en cours » de la position courante ───────
/// Icône location_searching magenta posée à même la trace — pas de pastille
/// pleine — entourée de deux cercles concentriques qui s'étalent en boucle.
/// Même marqueur que sur la carte de l'app pendant la sortie.
class _PulsingPositionMarker extends StatefulWidget {
  const _PulsingPositionMarker();

  /// Côté du Marker : doit contenir le cercle à son extension maximale.
  static const double size = 64;

  @override
  State<_PulsingPositionMarker> createState() => _PulsingPositionMarkerState();
}

class _PulsingPositionMarkerState extends State<_PulsingPositionMarker>
    with SingleTickerProviderStateMixin {
  static const Color _color = Color(0xFFD946EF);
  static const double _core = 30;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  /// Un cercle : part du cœur et s'étale jusqu'au bord en s'effaçant.
  /// [phase] décale le second cercle d'un demi-cycle.
  Widget _wave(double phase) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final t = (_pulse.value + phase) % 1.0;
        final d = _core +
            (_PulsingPositionMarker.size - _core) * Curves.easeOutCubic.transform(t);
        final fade = 1 - t;
        return Container(
          width: d,
          height: d,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _color.withValues(alpha: 0.18 * fade),
            border: Border.all(color: _color.withValues(alpha: 0.55 * fade), width: 2),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(
        alignment: Alignment.center,
        children: [
          _wave(0),
          _wave(0.5),
          // Liseré blanc : l'icône seule se perd sur les tuiles claires.
          const Icon(Icons.location_searching, color: Colors.white, size: 30),
          const Icon(Icons.location_searching, color: _color, size: 24),
        ],
      ),
    );
  }
}

class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  bool isLoading = true;
  bool isRefreshing = false;
  String? errorMessage;
  String? errorDetails;
  bool _errorDetailsExpanded = false;

  double? latitude;
  double? longitude;
  DateTime? lastUpdate;

  /// Batterie du téléphone relevée sur la position la plus récente qui en porte
  /// une. Nul pour les sorties d'avant la fonctionnalité (colonne à NULL).
  int? _batteryLevel;

  String appVersion = '';
  String rideStatus = 'unknown';
  String? _previousRideStatus;

  List<Map<String, dynamic>> tracePositions = [];
  List<Map<String, dynamic>> _rideJsonPoints = [];

  /// Décalage GPS ↔ niveau de la mer, calculé par l'app et transmis dans
  /// `ride_json`. Nul tant que la sortie n'est pas terminée : pendant le direct,
  /// les altitudes restent brutes des deux côtés, donc cohérentes.
  double? _altitudeOffsetMeters;

  double _totalDistanceMeters = 0;
  Duration _rideDuration = Duration.zero;
  DateTime? rideStartTime;

  Timer? _tickerTimer;
  Duration _sinceLastUpdate = Duration.zero;

  MapController mapController = MapController();
  int _mapStyleIndex = 0;
  bool _mapFitDone = false;
  bool _mapReady = false;

  double _savedZoom = 15.0;
  LatLng? _savedCenter;

  Timer? refreshTimer;
  int refreshIntervalSeconds = 30;

  final shareCode = Uri.base.queryParameters['code'];

  List<Map<String, dynamic>> _checkpoints = [];
  /// Volet latéral desktop ouvert, ou null si replié. Les deux onglets verticaux
  /// du bord droit partagent le même volet glissant.
  _SidePanel? _openPanel;
  // Point de passage mis en évidence dans le volet desktop (tap sur sa pastille
  // carte). Index dans _checkpoints ; null = aucun. _highlightKey est attachée à
  // l'item correspondant pour l'y faire défiler automatiquement.
  int? _highlightedCheckpoint;
  final GlobalKey _highlightKey = GlobalKey();

  /// Dénivelé et vitesse, recalculés à chaque chargement depuis les points GPS
  /// (le mobile ne les transmet pas au live — cf. RideStats).
  RideStats _stats = RideStats.empty;
  bool _versionExpanded = false;

  final GlobalKey _refreshBtnKey = GlobalKey();
  OverlayEntry? _refreshMenuEntry;

  // Overlays posés sur la carte : leur géométrie réelle sert de marge au cadrage
  // du tracé, pour qu'il ne passe pas dessous.
  final GlobalKey _topOverlayKey = GlobalKey();
  final GlobalKey _bottomOverlayKey = GlobalKey();
  // Blocs ancrés en bas à droite en desktop (contrôles carte + carte position) :
  // on mesure leur bord gauche pour savoir quelle colonne de droite est occupée.
  final GlobalKey _desktopControlsKey = GlobalKey();
  final GlobalKey _desktopCardKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    loadAppVersion();
    loadLastPosition();
    startAutoRefresh();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (lastUpdate != null) setState(() { _sinceLastUpdate = DateTime.now().difference(lastUpdate!); });
    });
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    _tickerTimer?.cancel();
    _refreshMenuEntry?.remove();
    _refreshMenuEntry = null;
    super.dispose();
  }

  /// Titre du panneau : l'heure du point affiché (arrivée si le ride est
  /// terminé, dernière position reçue sinon). La fraîcheur du signal reste
  /// portée par l'indicateur de signal.
  String _formatSinceLastUpdate() {
    if (rideStatus == 'unknown' || lastUpdate == null) return 'Position inconnue';
    final dt = lastUpdate!.toLocal();
    final hhmm = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return _isFinished ? 'Arrivée à $hhmm' : 'Position actuelle à $hhmm';
  }

  Widget _buildStatusPill() {
    final color = getStatusColor();
    final icon = getStatusIcon();
    final label = _isFinished ? 'Ride terminé'
        : rideStatus == 'in_progress' ? 'Ride en cours'
        : rideStatus == 'paused' ? 'Ride en pause'
        : 'Statut du ride indisponible';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 13),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  bool get _isFinished => rideStatus == 'finished';

  void startAutoRefresh() {
    refreshTimer?.cancel();
    // Pas de polling si le ride est terminé ou si l'intervalle est désactivé
    if (refreshIntervalSeconds == 0 || _isFinished) return;
    refreshTimer = Timer.periodic(
      Duration(seconds: refreshIntervalSeconds),
      (_) => loadLastPosition(),
    );
  }

  void changeRefreshInterval(int seconds) {
    setState(() => refreshIntervalSeconds = seconds);
    startAutoRefresh();
  }

  void _stopPollingIfFinished() {
    if (_isFinished) {
      refreshTimer?.cancel();
      refreshTimer = null;
      _tickerTimer?.cancel();
      _tickerTimer = null;
    }
  }

  Future<void> loadAppVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final formattedDate = packageInfo.updateTime != null
        ? DateFormat('dd/MM/yyyy HH:mm').format(packageInfo.updateTime!)
        : null;
    setState(() {
      appVersion =
          'v${packageInfo.version}+${packageInfo.buildNumber}'
          '${formattedDate != null ? ' - $formattedDate' : ''}';
    });
  }

  IconData getStatusIcon() {
    switch (rideStatus) {
      case 'in_progress': return Icons.circle;
      case 'paused': return Icons.pause_circle;
      case 'finished': return Icons.check_circle;
      default: return Icons.help;
    }
  }

  Color getStatusColor() {
    switch (rideStatus) {
      // Violet : couleur du ride en cours (pastille « dernière position »).
      case 'in_progress': return const Color(0xFF8B5CF6);
      case 'paused': return const Color(0xFFFACC15);
      case 'finished': return const Color(0xFF4CAF50);
      default: return Colors.grey;
    }
  }

  String getStatusLabel() {
    switch (rideStatus) {
      case 'in_progress': return 'En cours';
      case 'paused': return 'En pause';
      case 'finished': return 'Terminé';
      default: return 'Inconnu';
    }
  }

  Color _getSignalColor() {
    if (_isFinished || lastUpdate == null) return const Color(0xFF4ADE80);
    final s = _sinceLastUpdate.inSeconds;
    if (s < 120) return const Color(0xFF4ADE80);
    if (s < 300) return const Color(0xFFFACC15);
    return const Color(0xFFF87171);
  }

  String _getSignalLabel() {
    if (_isFinished || lastUpdate == null) return 'Signal reçu';
    final s = _sinceLastUpdate.inSeconds;
    if (s < 120) return 'Signal reçu';
    if (s < 300) return 'Signal faible';
    return 'Signal perdu';
  }

  Widget _buildSignalIndicator() {
    final color = _getSignalColor();
    return Tooltip(
      message: '< 2 min : Signal reçu\n2–5 min : Signal faible\n> 5 min : Signal perdu',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(_getSignalLabel(), style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildVersionBadge() {
    final parts = appVersion.split('+');
    final version = parts.first;
    final rawBuild = parts.length > 1 ? parts[1].split(' ').first : '';
    final build = rawBuild.length == 10
        ? '${rawBuild.substring(0, 8)}.${rawBuild.substring(8)}'
        : rawBuild;
    return GestureDetector(
      onTap: () => setState(() => _versionExpanded = !_versionExpanded),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(version, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                  if (_versionExpanded && build.isNotEmpty)
                    Text('build $build', style: const TextStyle(color: Colors.white54, fontSize: 10)),
                  if (_versionExpanded) ...[
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: _forcingUpdate ? null : _forceUpdate,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        _forcingUpdate
                            ? const SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFFFF8A00)))
                            : const Icon(Icons.refresh, size: 13, color: Color(0xFFFF8A00)),
                        const SizedBox(width: 5),
                        Text(_forcingUpdate ? 'Actualisation…' : 'Forcer l\'actualisation de la page',
                            style: const TextStyle(color: Color(0xFFFF8A00), fontSize: 10, fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<LatLng> get tracePoints {
    if (_isFinished && _rideJsonPoints.isNotEmpty) {
      return _rideJsonPoints
          .map((p) => LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()))
          .toList();
    }
    return tracePositions.reversed
        .map((p) => LatLng(
              (p['latitude'] as num).toDouble(),
              (p['longitude'] as num).toDouble(),
            ))
        .toList();
  }

  double _haversineMeters(LatLng a, LatLng b) {
    const r = 6371000.0;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final sinLat = math.sin(dLat / 2);
    final sinLng = math.sin(dLng / 2);
    final h = sinLat * sinLat + math.cos(lat1) * math.cos(lat2) * sinLng * sinLng;
    return 2 * r * math.asin(math.sqrt(h));
  }

  void _computeStats(List<Map<String, dynamic>> positions) {
    // Distance : utilise ride_json.points (dense, toutes les 5m) si dispo, sinon safety_positions (toutes les 15s)
    final distPoints = (_isFinished && _rideJsonPoints.isNotEmpty)
        ? _rideJsonPoints.map((p) => LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble())).toList()
        : positions.reversed.map((p) => LatLng((p['latitude'] as num).toDouble(), (p['longitude'] as num).toDouble())).toList();
    double dist = 0;
    for (int i = 1; i < distPoints.length; i++) {
      dist += _haversineMeters(distPoints[i - 1], distPoints[i]);
    }
    _totalDistanceMeters = dist;
    // Durée : somme des intervalles entre positions consécutives, en excluant
    // les trous > _kPauseGap. Pendant une pause le tracking est coupé : aucune
    // position n'est envoyée, ce qui creuse un trou dans les timestamps. Prendre
    // « dernière - première » compterait la pause dans la durée (une pause de
    // 30 min affichait 44 min de sortie au lieu de 12).
    // Estimation à quelques dizaines de secondes près : le trou commence au
    // dernier fix GPS, pas au clic sur Pause. La valeur exacte (chrono de
    // l'app) remplace celle-ci dès que la sortie est terminée, via ride_json.
    final chronoPoints = positions.reversed.toList();
    var active = Duration.zero;
    for (int i = 1; i < chronoPoints.length; i++) {
      final prev = DateTime.tryParse(chronoPoints[i - 1]['created_at'] ?? '');
      final cur = DateTime.tryParse(chronoPoints[i]['created_at'] ?? '');
      if (prev == null || cur == null) continue;
      final step = cur.difference(prev);
      if (step <= Duration.zero || step > _kPauseGap) continue;
      active += step;
    }
    _rideDuration = active;
  }

  /// Dénivelé + vitesse. Sur un ride terminé on part du tracé dense de
  /// `ride_json` (un point tous les ~5 m, avec altitude) ; pendant la sortie on
  /// se rabat sur les positions de suivi (~15 s), dont l'altitude n'est présente
  /// que si la RPC projette la colonne — sinon le dénivelé est simplement masqué.
  /// À appeler après `_computeStats` : la vitesse moyenne se déduit de la
  /// distance et de la durée déjà calculées.
  void _computeRideStats(List<Map<String, dynamic>> positions) {
    final samples = <RideSample>[];
    if (_isFinished && _rideJsonPoints.isNotEmpty) {
      for (final p in _rideJsonPoints) {
        final s = RideSample.fromRideJsonPoint(p);
        if (s != null) samples.add(s);
      }
    } else {
      for (final p in positions.reversed) {
        final s = RideSample.fromPosition(p);
        if (s != null) samples.add(s);
      }
    }
    _stats = RideStats.fromSamples(
      samples,
      distanceMeters: _totalDistanceMeters,
      duration: _rideDuration,
      altitudeOffsetMeters: _altitudeOffsetMeters,
    );
  }

  String _formatDistance(double meters) {
    if (meters < 1000) return '${meters.toStringAsFixed(0)} m';
    return '${(meters / 1000).toStringAsFixed(2)} km';
  }

  String _formatDuration(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String _formatStartTime() {
    if (rideStartTime == null) return '--:--:--';
    final dt = rideStartTime!.toLocal();
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  double _overlayHeight(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return 0;
    return box.size.height;
  }

  /// Abscisse du bord gauche d'un bloc posé sur la carte, ou null s'il n'est pas
  /// (encore) affiché.
  double? _blockLeftEdge(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero).dx;
  }

  /// Zones libres candidates pour cadrer le tracé, exprimées en marges à retirer
  /// de la carte (qui occupe tout l'écran, les panneaux la recouvrant).
  ///
  /// En mobile les panneaux sont des bandeaux pleine largeur : la seule zone
  /// libre est la bande horizontale entre les deux. En desktop ils sont ancrés
  /// dans les coins (carte position + contrôles en bas à droite, volet à
  /// droite) : réserver la hauteur du bloc bas sur *toute* la largeur ampute la
  /// carte de moitié pour rien. On propose donc aussi une zone « pleine hauteur,
  /// colonne de droite réservée », et [_fitBounds] garde celle qui permet le
  /// plus gros zoom — c'est-à-dire celle dont le rapport de forme colle le mieux
  /// au tracé (bande large pour un tracé étiré, colonne haute pour un tracé
  /// compact ou vertical).
  ///
  /// Chaque marge est bornée pour ne jamais dévorer la carte (sinon le fit
  /// renvoie un zoom aberrant).
  List<EdgeInsets> _mapFitCandidates() {
    const margin = 24.0;
    final size = MediaQuery.sizeOf(context);
    final isMobileLayout = size.width < 900;
    final top = _overlayHeight(_topOverlayKey).clamp(0.0, size.height * 0.30);
    final bottom = _overlayHeight(_bottomOverlayKey).clamp(0.0, size.height * 0.50);
    // Le volet droit est opaque et pleine hauteur : il est toujours à exclure.
    final panel = (!isMobileLayout && _openPanel != null) ? 340.0 : 0.0;

    final horizontalBand = EdgeInsets.fromLTRB(
      margin,
      top + 16,
      panel.clamp(0.0, size.width * 0.40) + margin,
      bottom + 16,
    );
    if (isMobileLayout) return [horizontalBand];

    // Colonne de droite réellement occupée : bord gauche du bloc le plus large
    // (carte position ou contrôles carte, le volet étant déjà à leur droite).
    final edges = [_blockLeftEdge(_desktopCardKey), _blockLeftEdge(_desktopControlsKey)]
        .whereType<double>();
    if (edges.isEmpty) return [horizontalBand];
    final rightColumn = (size.width - edges.reduce(math.min) + margin)
        .clamp(0.0, size.width * 0.55);

    return [
      horizontalBand,
      EdgeInsets.fromLTRB(margin, top + 16, rightColumn, margin),
    ];
  }

  /// Ajuste la caméra aux points. Renvoie true si un vrai fit a eu lieu
  /// (zoom fini), false si on a dû retomber sur un recentrage de secours.
  bool _fitBounds(List<LatLng> points) {
    if (points.isEmpty) return false;
    // Bornes dégénérées (tous les points au même endroit) → CameraFit renvoie
    // un zoom infini (« Unsupported operation: Infinity »). On recentre à la
    // place sur ce point unique.
    final lats = points.map((p) => p.latitude);
    final lngs = points.map((p) => p.longitude);
    final spanLat = lats.reduce(math.max) - lats.reduce(math.min);
    final spanLng = lngs.reduce(math.max) - lngs.reduce(math.min);
    if (spanLat < 1e-6 && spanLng < 1e-6) {
      _safeMove(points.first, 15);
      return true; // positionné correctement, inutile de réessayer
    }
    final bounds = LatLngBounds.fromPoints(points);
    // On simule le cadrage dans chaque zone libre candidate (fit() ne bouge pas
    // la caméra, il renvoie celle qu'il faudrait) et on applique la meilleure.
    // Un zoom non fini = carte pas encore dimensionnée (timing web) : on écarte
    // le candidat, sinon la TileLayer plante au rendu.
    MapCamera? best;
    for (final padding in _mapFitCandidates()) {
      try {
        final cam = CameraFit.bounds(bounds: bounds, padding: padding)
            .fit(mapController.camera);
        if (!cam.zoom.isFinite) continue;
        if (best == null || cam.zoom > best.zoom) best = cam;
      } catch (_) {
        // candidat ignoré
      }
    }
    if (best == null) {
      _safeMove(points.first, 15);
      return false;
    }
    _safeMove(best.center, best.zoom);
    return true;
  }

  void _safeMove(LatLng center, double zoom) {
    try {
      mapController.move(center, zoom);
    } catch (_) {}
  }

  void _tryInitialFit() {
    if (!_mapReady || _mapFitDone) return;
    final points = tracePoints;
    if (points.isEmpty) return;
    if (_fitBounds(points)) {
      _mapFitDone = true;
    } else {
      // Carte pas encore dimensionnée (timing web) : on réessaie au frame suivant.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tryInitialFit();
      });
    }
  }

  void _recenter() {
    if (latitude == null || longitude == null) return;
    try {
      mapController.move(LatLng(latitude!, longitude!), 15);
    } catch (_) {}
  }

  void _updateDocumentMeta(String status) {
    try {
      final icon = status == 'finished'
          ? '🟢'
          : status == 'in_progress'
              ? '🔵'
              : status == 'paused'
                  ? '🟡'
                  : '⚪';
      final label = status == 'finished'
          ? 'Ride terminé'
          : status == 'in_progress'
              ? 'En cours'
              : status == 'paused'
                  ? 'En pause'
                  : 'Statut du ride indisponible';
      html.document.title = '$icon $label';
    } catch (_) {}
  }

  void _checkStatusChange(String newStatus) {
    _updateDocumentMeta(newStatus);
    if (_previousRideStatus != null && _previousRideStatus != newStatus) {
      final label = newStatus == 'in_progress' ? 'Le ride a repris ▶'
          : newStatus == 'paused' ? 'Le ride est en pause ⏸'
          : newStatus == 'finished' ? 'Le ride est terminé ✓'
          : 'Statut mis à jour';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(label),
        backgroundColor: getStatusColor(),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ));
    }
    _previousRideStatus = newStatus;
  }

  /// Dernier niveau de batterie connu (positions triées du plus récent au plus
  /// ancien). La batterie n'est relevée par le téléphone que toutes les 60 s,
  /// et pas du tout sur les plateformes sans info batterie : on remonte la
  /// trace jusqu'au premier point renseigné plutôt que d'afficher « — » dès
  /// que le tout dernier point est vide.
  int? _latestBatteryLevel(List<Map<String, dynamic>> positions) {
    for (final p in positions) {
      final raw = p['battery_level'];
      if (raw is num) return raw.round().clamp(0, 100);
    }
    return null;
  }

  Future<void> loadLastPosition({bool manual = false}) async {
    if (shareCode == null) {
      setState(() { errorMessage = 'missing_code'; isLoading = false; });
      return;
    }
    if (!isLoading) setState(() => isRefreshing = true);
    try {
      final supabase = Supabase.instance.client;
      final result = await supabase.rpc('get_live_session', params: {'p_share_code': shareCode!});
      if (result == null || result['session'] == null) {
        setState(() { errorMessage = 'missing_code'; isLoading = false; isRefreshing = false; });
        return;
      }
      final session = Map<String, dynamic>.from(result['session'] as Map);
      final newStatus = session['status'] ?? 'unknown';
      _checkStatusChange(newStatus);
      rideStatus = newStatus;
      final parsedPositions = ((result['positions'] as List?) ?? [])
          .map((p) => Map<String, dynamic>.from(p as Map))
          .toList();
      if (parsedPositions.isEmpty) {
        setState(() { errorMessage = 'Aucune position disponible'; isLoading = false; isRefreshing = false; });
        return;
      }
      // Heure de départ : `started_at` est posé par le téléphone, alors que le
      // `created_at` des positions est horodaté à l'insertion côté serveur. Les
      // deux horloges diffèrent, et sur un ride qui vient de démarrer la première
      // position pouvait apparaître AVANT le départ. On retient donc le plus
      // ancien des deux (positions triées du plus récent au plus ancien).
      final startedAt = DateTime.tryParse(session['started_at'] ?? '');
      final firstPointAt = DateTime.tryParse(parsedPositions.last['created_at'] ?? '');
      rideStartTime = startedAt == null || (firstPointAt != null && firstPointAt.isBefore(startedAt))
          ? firstPointAt
          : startedAt;
      // Les waypoints sont stockés localement sur le téléphone pendant le ride.
      // Ils arrivent dans safety_sessions.ride_json['waypoints'] uniquement à la fin.
      List<Map<String, dynamic>> parsedCheckpoints = [];
      List<Map<String, dynamic>> parsedRideJsonPoints = [];
      try {
        final rideJson = session['ride_json'] as Map<String, dynamic>?;
        final rawWaypoints = rideJson?['waypoints'] as List<dynamic>?;
        if (rawWaypoints != null) {
          parsedCheckpoints = rawWaypoints
              .whereType<Map<String, dynamic>>()
              .map((w) => {
                    'created_at': w['timestamp'] as String?,
                    // Heure de reprise d'une pause auto (écrite par l'app) : sert
                    // à calculer la durée de la pause pour masquer les plus
                    // courtes sur la carte. Cf. isShortAutoPause.
                    'resumedAt': w['resumedAt'] as String?,
                    'comment': (w['note'] as String? ?? '').isNotEmpty ? w['note'] : null,
                    // Photos uploadées sur le bucket public `waypoint-photos` : on ne
                    // garde que les URL distantes (les chemins 'local' pointent vers
                    // le téléphone et sont inaccessibles depuis le web).
                    'photo_urls': _waypointPhotoUrls(w['photos']),
                    'lat': w['lat'],
                    'lng': w['lng'],
                    // Nature du point (mémorisé / pause / pause auto) : écrite
                    // par l'app mobile, cf. waypoint_kind.dart.
                    'kind': w['kind'],
                  })
              .toList();
        }
        final rawPoints = rideJson?['points'] as List<dynamic>?;
        if (rawPoints != null) {
          parsedRideJsonPoints = rawPoints.whereType<Map<String, dynamic>>().toList();
        }
        _altitudeOffsetMeters =
            (rideJson?['altitudeOffsetMeters'] as num?)?.toDouble();
      } catch (_) {}
      _rideJsonPoints = parsedRideJsonPoints;
      // Ride terminé : lire les stats authoritatives depuis ride_json
      bool statsFromRideJson = false;
      if (newStatus == 'finished') {
        try {
          final rideJson = session['ride_json'] as Map<String, dynamic>?;
          final distM = rideJson?['distanceMeters'];
          final durS = rideJson?['durationSeconds'];
          if (distM != null && durS != null) {
            _totalDistanceMeters = (distM as num).toDouble();
            _rideDuration = Duration(seconds: (durS as num).toInt());
            statsFromRideJson = true;
          }
        } catch (_) {}
      }
      if (!statsFromRideJson) _computeStats(parsedPositions);
      _computeRideStats(parsedPositions);
      final latestPosition = parsedPositions.first;
      setState(() {
        tracePositions = parsedPositions;
        _checkpoints = parsedCheckpoints;
        latitude = (latestPosition['latitude'] as num).toDouble();
        longitude = (latestPosition['longitude'] as num).toDouble();
        lastUpdate = DateTime.tryParse(latestPosition['created_at']);
        _batteryLevel = _latestBatteryLevel(parsedPositions);
        isLoading = false;
        isRefreshing = false;
      });
      _stopPollingIfFinished();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_mapFitDone) {
          _tryInitialFit();
        } else {
          double z = 15;
          try {
            final current = mapController.camera.zoom;
            if (current.isFinite) z = current;
          } catch (_) {}
          _safeMove(LatLng(latitude!, longitude!), z);
        }
      });
      if (manual) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Position mise à jour'), behavior: SnackBarBehavior.floating, duration: Duration(seconds: 2)));
      }
    } catch (e) {
      setState(() { errorMessage = 'system_error'; errorDetails = e.toString(); isLoading = false; isRefreshing = false; });
    }
  }

  /// Menu contextuel de rafraîchissement, ancré à gauche du bouton sync.
  void _toggleRefreshMenu() {
    if (_refreshMenuEntry != null) {
      _removeRefreshMenu();
      return;
    }
    final overlay = Overlay.of(context);
    final btnCtx = _refreshBtnKey.currentContext;
    if (btnCtx == null) return;
    final btnBox = btnCtx.findRenderObject() as RenderBox?;
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (btnBox == null || overlayBox == null) return;
    final btnPos = btnBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    final overlaySize = overlayBox.size;
    const menuWidth = 240.0;
    // Aligné à droite du menu = bord gauche du bouton, avec 8px d'écart.
    final rightInset = overlaySize.width - btnPos.dx + 8;

    _refreshMenuEntry = OverlayEntry(
      builder: (_) => Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _removeRefreshMenu,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          right: rightInset,
          top: btnPos.dy,
          width: menuWidth,
          child: TweenAnimationBuilder<double>(
            duration: const Duration(milliseconds: 130),
            curve: Curves.easeOut,
            tween: Tween(begin: 0, end: 1),
            builder: (_, t, child) => Opacity(
              opacity: t,
              child: Transform.scale(alignment: Alignment.centerRight, scale: 0.96 + 0.04 * t, child: child),
            ),
            child: _buildRefreshMenuCard(),
          ),
        ),
      ]),
    );
    overlay.insert(_refreshMenuEntry!);
  }

  void _removeRefreshMenu() {
    _refreshMenuEntry?.remove();
    _refreshMenuEntry = null;
  }

  Widget _buildRefreshMenuCard() {
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1B1B1B),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 20, offset: const Offset(0, 8))],
        ),
        padding: const EdgeInsets.all(12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Rafraîchissement', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: isRefreshing ? null : () { _removeRefreshMenu(); loadLastPosition(manual: true); },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(10)),
              child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.refresh, color: Colors.orange, size: 18),
                SizedBox(width: 8),
                Text('Rafraîchir maintenant', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          const Text('Intervalle auto', style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final entry in {0: 'Off', 15: '15 s', 30: '30 s', 60: '60 s'}.entries)
              GestureDetector(
                onTap: () { _removeRefreshMenu(); changeRefreshInterval(entry.key); },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: refreshIntervalSeconds == entry.key ? Colors.orange : const Color(0xFF2A2A2A),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(entry.value, style: TextStyle(
                    color: refreshIntervalSeconds == entry.key ? Colors.black : Colors.white70,
                    fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ),
          ]),
        ]),
      ),
    );
  }

  /// Amélioration 7 : bottom sheet pour choisir l'app de navigation
  void _showNavigationSheet(BuildContext context) {
    final lat = latitude;
    final lng = longitude;
    if (lat == null || lng == null) return;

    final apps = [
      {'label': 'Google Maps', 'icon': Icons.map_outlined, 'url': 'https://www.google.com/maps/search/?api=1&query=$lat,$lng'},
      {'label': 'Waze', 'icon': Icons.navigation_outlined, 'url': 'https://waze.com/ul?ll=$lat,$lng&navigate=yes'},
      {'label': 'Apple Plans', 'icon': Icons.directions_outlined, 'url': 'https://maps.apple.com/?ll=$lat,$lng&q=Position'},
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B1B1B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Ouvrir la position dans…', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 16),
            for (final app in apps)
              ListTile(
                leading: Icon(app['icon'] as IconData, color: const Color(0xFFD7B8FF)),
                title: Text(app['label'] as String, style: const TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(context);
                  final uri = Uri.parse(app['url'] as String);
                  if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
                },
              ),
          ]),
        ),
      ),
    );
  }

  /// Change le fond de carte en préservant la position/zoom courants.
  /// La carte est recréée (nouveau MapController) car flutter_map ne permet
  /// pas de changer le maxZoom à chaud.
  void _changeMapStyle(int i) {
    if (i == _mapStyleIndex) return;
    final newMaxZoom = (kMapStyles[i]['maxZoom'] as int).toDouble();
    double currentZoom = _savedZoom;
    LatLng? currentCenter = _savedCenter;
    try {
      final z = mapController.camera.zoom;
      if (z.isFinite) currentZoom = z;
      currentCenter = mapController.camera.center;
    } catch (_) {}
    setState(() {
      _mapStyleIndex = i;
      _savedZoom = currentZoom > newMaxZoom ? newMaxZoom : currentZoom;
      _savedCenter = currentCenter;
      mapController = MapController();
      _mapReady = false;
    });
  }

  /// Direction unitaire (repère écran) PERPENDICULAIRE à la trace au niveau du
  /// waypoint `at`. Le pin est décalé sur le côté de la trace, du côté qui pointe
  /// vers l'EXTÉRIEUR (loin du barycentre) : sur une boucle, le pin sort donc de
  /// la boucle au lieu de tomber dedans. Repli sur un biais « vers le haut »
  /// (sinon vers la droite) quand le waypoint est ~au centre du tracé.
  Offset _leaderDirection(LatLng at) {
    final trace = tracePoints;
    if (trace.length < 2) return const Offset(0, -1);
    var nearest = 0;
    var best = double.infinity;
    for (var i = 0; i < trace.length; i++) {
      final dLat = trace[i].latitude - at.latitude;
      final dLng = trace[i].longitude - at.longitude;
      final d = dLat * dLat + dLng * dLng;
      if (d < best) { best = d; nearest = i; }
    }
    final a = trace[math.max(0, nearest - 2)];
    final b = trace[math.min(trace.length - 1, nearest + 2)];
    final latRad = at.latitude * math.pi / 180;
    final cosLat = math.cos(latRad);
    // Tangente en repère écran (mercator local) : x ∝ Δlng·cos(lat), y ∝ -Δlat.
    final tx = (b.longitude - a.longitude) * cosLat;
    final ty = -(b.latitude - a.latitude);
    final tlen = math.sqrt(tx * tx + ty * ty);
    if (tlen < 1e-12) return const Offset(0, -1);
    var px = -ty / tlen; // perpendiculaire = tangente tournée de 90°
    var py = tx / tlen;
    // Barycentre du tracé, puis vecteur « vers l'extérieur » = du barycentre
    // vers le waypoint (repère écran). On choisit la perpendiculaire de ce côté.
    var mLat = 0.0, mLng = 0.0;
    for (final p in trace) { mLat += p.latitude; mLng += p.longitude; }
    mLat /= trace.length; mLng /= trace.length;
    final outX = (at.longitude - mLng) * cosLat;
    final outY = -(at.latitude - mLat);
    if (outX * outX + outY * outY > 1e-12) {
      if (px * outX + py * outY < 0) { px = -px; py = -py; }
    } else {
      if (py > 1e-6) { px = -px; py = -py; } // vers le haut
      else if (py.abs() <= 1e-6 && px < 0) { px = -px; } // sinon vers la droite
    }
    return Offset(px, py);
  }

  /// Marker waypoint : pastille ronde numérotée décalée perpendiculairement à la
  /// trace, reliée par un fin trait de rappel à un point posé sur sa vraie
  /// position GPS. Même représentation que l'écran détail du ride de l'app mobile
  /// (pastille numérotée plutôt qu'une goutte). La boîte est centrée sur la
  /// coordonnée (alignment center) et assez grande pour contenir le décalage dans
  /// n'importe quelle direction.
  Marker _waypointMarker(Map cp, int number) {
    // Bleu = point mémorisé, orange = pause au bouton, orange + étincelle =
    // pause détectée par le mode auto de l'app (cf. WaypointKind).
    final kind = waypointKindOf(cp);
    final color = kind.color;
    const lead = 30.0;   // longueur du trait de rappel (px écran)
    const box = 120.0;
    const badge = 30.0;  // diamètre de la pastille numérotée
    final at = LatLng((cp['lat'] as num).toDouble(), (cp['lng'] as num).toDouble());
    final dir = _leaderDirection(at);
    final tip = Offset(dir.dx * lead, dir.dy * lead);
    final angle = math.atan2(tip.dy, tip.dx);
    return Marker(
      point: at,
      width: box,
      height: box,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Trait de rappel : du point GPS (centre) vers la pastille.
          Transform.translate(
            offset: Offset(tip.dx / 2, tip.dy / 2),
            child: Transform.rotate(
              angle: angle,
              child: Container(
                width: lead, height: 2,
                decoration: BoxDecoration(
                  color: color, borderRadius: BorderRadius.circular(1)),
              ),
            ),
          ),
          // Point posé sur la trace = vraie position GPS du waypoint.
          Container(
            width: 9, height: 9,
            decoration: BoxDecoration(
              color: color, shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
          ),
          // Pastille ronde numérotée, déportée au bout du trait. Chiffre gros et
          // centré → nettement plus lisible que le petit numéro logé dans la tête
          // d'une goutte location_on. Seule la pastille est cliquable (ouvre les
          // infos du point) : le reste de la boîte laisse passer les gestes carte.
          Transform.translate(
            offset: tip,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => _showCheckpointInfo(cp, number),
                child: Container(
                  width: badge, height: badge,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 4),
                    ],
                  ),
                  // Étincelle en haut à droite si le point vient du mode auto.
                  child: waypointBadgeContent(
                    kind: kind,
                    size: badge - 4, // hors bordure
                    color: Colors.white,
                    child: Text('$number',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: number >= 10 ? 13 : 16,
                        fontWeight: FontWeight.w800, height: 1),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMap() {
    final points = tracePoints;
    final currentPosition = LatLng(latitude!, longitude!);
    final gradientColors = _buildGradientColors(points.length);
    return FlutterMap(
        key: ValueKey('map_$_mapStyleIndex'),
        mapController: mapController,
        options: MapOptions(
          initialCenter: _savedCenter ?? currentPosition,
          initialZoom: _savedZoom,
          onMapReady: () {
            _mapReady = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _tryInitialFit();
            });
          },
        ),
        children: [
          TileLayer(urlTemplate: kMapStyles[_mapStyleIndex]['url'] as String, subdomains: kMapStyles[_mapStyleIndex]['subdomains'] as List<String>, maxZoom: (kMapStyles[_mapStyleIndex]['maxZoom'] as int).toDouble(), userAgentPackageName: 'com.example.sunday_tracker_live'),
          if (points.length >= 2)
            PolylineLayer(polylines: List.generate(points.length - 1, (i) => Polyline(points: [points[i], points[i + 1]], strokeWidth: 5, color: gradientColors[i]))),
          MarkerLayer(markers: [
            if (points.isNotEmpty)
              Marker(
                point: points.first, width: 26, height: 26,
                child: Container(
                  decoration: BoxDecoration(color: const Color(0xFFFF8A00), shape: BoxShape.circle, boxShadow: [BoxShadow(color: const Color(0xFFFF8A00).withValues(alpha: 0.6), blurRadius: 8)]),
                  child: const Icon(Icons.play_arrow, color: Colors.white, size: 16),
                ),
              ),
            // Arrivée (pin damier) : uniquement sur un ride terminé. Tant que le
            // ride tourne, la dernière position n'est pas une arrivée — seul le
            // point rouge de position courante la marque.
            if (_isFinished && points.length > 1)
              Marker(
                point: points.last, width: 26, height: 26,
                child: Container(
                  decoration: BoxDecoration(color: const Color(0xFF6D28D9), shape: BoxShape.circle, boxShadow: [BoxShadow(color: const Color(0xFF6D28D9).withValues(alpha: 0.6), blurRadius: 8)]),
                  child: const Icon(Icons.sports_score_sharp, color: Colors.white, size: 16),
                ),
              ),
            // Position courante (cible magenta pulsée) : uniquement pendant le
            // ride. Sur un ride terminé, la dernière position EST l'arrivée,
            // déjà marquée par le pin damier — la cible serait redondante.
            // #D946EF = couleur intermédiaire du dégradé Départ → Arrivée.
            if (!_isFinished)
              Marker(
                point: currentPosition,
                width: _PulsingPositionMarker.size,
                height: _PulsingPositionMarker.size,
                child: _PulsingPositionMarker(),
              ),
            // Waypoints dessinés en DERNIER (au-dessus de tout). Chaque WP est un
            // pin flottant décalé PERPENDICULAIREMENT à la trace, relié par une
            // fine ligne à un point posé sur sa vraie position GPS. Évite toute
            // superposition avec les markers départ/arrivée. Cf _waypointMarker.
            // Les pauses auto très courtes sont masquées sur la carte pour la
            // désencombrer ; elles restent dans le volet « Points de passage »,
            // d'où la numérotation calée sur l'index de la liste complète.
            for (final (i, cp) in _checkpoints.indexed)
              if (cp['lat'] != null &&
                  cp['lng'] != null &&
                  !isShortAutoPause(cp))
                _waypointMarker(cp, i + 1),
          ]),
        ],
    );
  }

  Widget _buildTopOverlay(bool isMobile, double topPadding) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.80), Colors.transparent],
        ),
      ),
      padding: EdgeInsets.fromLTRB(16, topPadding + 12, 12, 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Sunday Tracker Live',
                    style: GoogleFonts.robotoCondensed(color: Colors.white, fontSize: isMobile ? 14 : 36, fontWeight: FontWeight.w700, shadows: [const Shadow(color: Colors.black54, blurRadius: 4)])),
                const SizedBox(height: 6),
                _buildVersionBadge(),
              ],
            ),
          ),
          // Le rafraîchissement (manuel + intervalle auto) est géré par le bouton
          // sync du groupe de contrôles carte, en mobile comme en desktop.
        ],
      ),
    );
  }

  String _formatUpdateDateFr() {
    if (lastUpdate == null) return '';
    final dt = lastUpdate!.toLocal();
    const months = ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin',
                    'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  String _formatStartDateFr() {
    if (rideStartTime == null) return '--';
    final dt = rideStartTime!.toLocal();
    const months = ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin',
                    'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  /// Pastille de départ / arrivée / dernière position : cercle plein avec halo,
  /// mêmes couleurs que les markers de la carte. `tail` ajoute une courte
  /// traînée de pointillés sous la pastille (ride en cours, où les deux points
  /// sont côte à côte et non reliés entre eux).
  Widget _buildEndpointDot(Color color, IconData icon, {bool tail = false}) {
    final dot = Container(
      width: 38, height: 38,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 12, spreadRadius: 1)],
      ),
      child: Icon(icon, color: Colors.white, size: 20),
    );
    if (!tail) return dot;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      dot,
      const SizedBox(height: 5),
      for (var i = 0; i < 3; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.5),
          child: Container(
            width: 3, height: 3,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 1 - i * 0.25),
              shape: BoxShape.circle,
            ),
          ),
        ),
    ]);
  }

  /// Pointillés reliant la pastille de départ à celle d'arrivée, en dégradé
  /// orange → violet comme la trace sur la carte.
  Widget _buildEndpointConnector() {
    const start = Color(0xFFFF8A00);
    const end = Color(0xFF6D28D9);
    return SizedBox(
      width: 38,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: Container(
              width: 3, height: 3,
              decoration: BoxDecoration(
                color: Color.lerp(start, end, i / 2)!,
                shape: BoxShape.circle,
              ),
            ),
          )),
        ),
      ),
    );
  }

  /// Carte Départ / Arrivée / Dernière position : libellé coloré, puis date et
  /// heure sur une seule ligne (la date rétrécit plutôt que de déborder dans le
  /// volet droit, plus étroit).
  /// Pastille batterie du téléphone, affichée à droite du libellé de la carte
  /// « Dernière position » : un live qui s'arrête à 4 % s'interprète autrement
  /// qu'un live qui s'arrête à 80 %.
  Widget _buildBatteryChip(int level) {
    final color = level <= 10
        ? const Color(0xFFEF4444)
        : level <= 20
            ? const Color(0xFFFF8A00)
            : Colors.white54;
    final icon = level <= 10
        ? Icons.battery_alert
        : level <= 30
            ? Icons.battery_2_bar
            : level <= 60
                ? Icons.battery_4_bar
                : level <= 90
                    ? Icons.battery_6_bar
                    : Icons.battery_full;
    return Tooltip(
      message: 'Batterie du téléphone : $level %',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 12),
        const SizedBox(width: 3),
        Text('$level %',
          style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _buildEndpointCard({
    required String label,
    required Color color,
    required String date,
    required String time,
    int? battery,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 8, 11, 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Flexible(
              child: Text(label.toUpperCase(),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
            ),
            if (battery != null) ...[
              const SizedBox(width: 8),
              _buildBatteryChip(battery),
            ],
          ]),
          const SizedBox(height: 5),
          Row(children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.calendar_today_outlined, color: Colors.white38, size: 12),
                  const SizedBox(width: 6),
                  Text(date, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 10),
                  const Icon(Icons.access_time, color: Colors.white38, size: 12),
                  const SizedBox(width: 6),
                  Text(time, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                ]),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  /// Carte Distance / Durée : libellé + valeur orange, pastille d'icône à droite.
  Widget _buildMetricCard({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 1),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value,
                  style: const TextStyle(color: Color(0xFFFF8A00), fontSize: 20, fontWeight: FontWeight.bold, height: 1.2)),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.07), shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white54, size: 17),
        ),
      ]),
    );
  }

  /// Bilan d'un ride terminé : timeline départ → arrivée à gauche, distance /
  /// durée + bouton à droite. La carte fait 560 px en bas de l'écran desktop ;
  /// sous 400 px de contenu (volet droit de 340, mobile) les deux colonnes
  /// s'empilent au lieu de déborder.
  Widget _buildFinishedSummary() {
    final timeline = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          _buildEndpointDot(const Color(0xFFFF8A00), Icons.play_arrow),
          const SizedBox(width: 10),
          Expanded(child: _buildEndpointCard(
            label: 'Départ',
            color: const Color(0xFFFF8A00),
            date: _formatStartDateFr(),
            time: _formatStartTime(),
          )),
        ]),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _buildEndpointConnector(),
        ),
        Row(children: [
          _buildEndpointDot(const Color(0xFF6D28D9), Icons.sports_score_sharp),
          const SizedBox(width: 10),
          Expanded(child: _buildEndpointCard(
            label: 'Arrivée',
            color: const Color(0xFF6D28D9),
            date: _formatUpdateDateFr(),
            time: lastUpdate != null ? DateFormat('HH:mm:ss').format(lastUpdate!.toLocal()) : '--:--:--',
          )),
        ]),
      ],
    );

    final distance = _buildMetricCard(
      label: 'Distance',
      value: _formatDistance(_totalDistanceMeters),
      icon: Icons.add_road,
    );
    final duree = _buildMetricCard(
      label: 'Durée',
      value: _formatDuration(_rideDuration),
      icon: Icons.schedule,
    );

    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 400) {
        return Column(mainAxisSize: MainAxisSize.min, children: [
          timeline,
          const SizedBox(height: 8),
          distance,
          const SizedBox(height: 8),
          duree,
        ]);
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: timeline),
          const SizedBox(width: 12),
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              distance,
              const SizedBox(height: 8),
              duree,
            ]),
          ),
        ],
      );
    });
  }

  /// Bouton « Ouvrir la position ». Compact par défaut (calé à droite du titre
  /// dans l'en-tête) ; [fullWidth] le rend pleine largeur pour le panneau mobile,
  /// où il s'empile sous « Voir les détails ».
  Widget _buildOpenPositionButton({bool fullWidth = false}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showNavigationSheet(context),
      child: Container(
        width: fullWidth ? double.infinity : null,
        padding: fullWidth
            ? const EdgeInsets.symmetric(vertical: 9)
            : const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF6D28D9), Color(0xFFB026F0)]),
          borderRadius: BorderRadius.circular(fullWidth ? 12 : 10),
        ),
        child: Row(
          mainAxisSize: fullWidth ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: fullWidth ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: const [
            Icon(Icons.map_outlined, color: Colors.white, size: 16),
            SizedBox(width: 7),
            Text('Ouvrir la position',
              style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  /// Ride en cours : départ et dernière position côte à côte (chacun avec sa
  /// pastille et sa traînée de pointillés, comme les markers de la carte), puis
  /// distance / durée et le bouton. Sous 400 px de contenu, tout s'empile.
  Widget _buildLiveSummary() {
    final depart = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _buildEndpointDot(const Color(0xFFFF8A00), Icons.play_arrow, tail: true),
      const SizedBox(width: 10),
      Expanded(child: _buildEndpointCard(
        label: 'Départ',
        color: const Color(0xFFFF8A00),
        date: _formatStartDateFr(),
        time: _formatStartTime(),
      )),
    ]);
    final derniere = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _buildEndpointDot(const Color(0xFFD946EF), Icons.my_location, tail: true),
      const SizedBox(width: 10),
      Expanded(child: _buildEndpointCard(
        label: 'Dernière position',
        color: const Color(0xFFD946EF),
        date: _formatUpdateDateFr(),
        time: lastUpdate != null ? DateFormat('HH:mm:ss').format(lastUpdate!.toLocal()) : '--:--:--',
        battery: _batteryLevel,
      )),
    ]);
    final distance = _buildMetricCard(
      label: 'Distance',
      value: _formatDistance(_totalDistanceMeters),
      icon: Icons.add_road,
    );
    final duree = _buildMetricCard(
      label: 'Durée',
      value: _formatDuration(_rideDuration),
      icon: Icons.schedule,
    );

    return LayoutBuilder(builder: (context, constraints) {
      final narrow = constraints.maxWidth < 400;
      return Column(mainAxisSize: MainAxisSize.min, children: [
        if (narrow) ...[
          depart,
          const SizedBox(height: 8),
          derniere,
          const SizedBox(height: 8),
          distance,
          const SizedBox(height: 8),
          duree,
        ] else ...[
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: depart),
            const SizedBox(width: 12),
            Expanded(child: derniere),
          ]),
          const SizedBox(height: 8),
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: distance),
              const SizedBox(width: 12),
              Expanded(child: duree),
            ]),
          ),
        ],
      ]);
    });
  }

  /// Contenu du panneau du ride, dans les deux états : en direct (départ +
  /// dernière position) ou terminé (bilan départ → arrivée). Partagé par la
  /// carte flottante desktop et le panneau glissant mobile, qui apportent chacun
  /// leur propre fond.
  Widget _buildPositionCardContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          Text(_isFinished ? 'DERNIÈRE POSITION CONNUE' : 'POSITION EN DIRECT',
            style: const TextStyle(color: Color(0xFFFF8A00), fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.0)),
          const Spacer(),
          _buildStatusPill(),
        ]),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Icon(_isFinished ? Icons.sports_score_sharp : Icons.my_location, color: _isFinished ? const Color(0xFF8B5CF6) : const Color(0xFFD946EF), size: 20),
          const SizedBox(width: 6),
          // Titre + signal groupés à gauche ; l'Expanded pousse le bouton
          // « Ouvrir la position » contre le bord droit et laisse le titre
          // se réduire (FittedBox) quand la place manque en mode direct.
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(_formatSinceLastUpdate(),
                    style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold, height: 1.1)),
                ),
              ),
              // Fraîcheur du signal : seule info que les cartes date/heure ne donnent
              // pas d'un coup d'œil.
              if (!_isFinished) ...[
                const SizedBox(width: 8),
                _buildSignalIndicator(),
              ],
            ]),
          ),
          const SizedBox(width: 8),
          _buildOpenPositionButton(),
        ]),
        const SizedBox(height: 8),
        Container(height: 1, color: Colors.white12),
        const SizedBox(height: 10),
        if (_isFinished) _buildFinishedSummary() else _buildLiveSummary(),
      ],
    );
  }

  Widget _buildPositionCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1B1B),
        borderRadius: BorderRadius.circular(16),
      ),
      child: _buildPositionCardContent(),
    );
  }

  /// Bas de l'écran desktop : mêmes contrôles carte flottants qu'en mobile,
  /// empilés au-dessus de l'unique carte « dernière position » (qui embarque
  /// désormais les stats de la sortie). Quand le volet droit est ouvert, il
  /// reprend la carte position et les contrôles se décalent pour rester visibles
  /// à gauche du volet.
  Widget _buildDesktopBottomBar(double bottomPadding) {
    return AnimatedPadding(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      padding: EdgeInsets.fromLTRB(20, 0, 20 + (_openPanel != null ? 340 : 0), 14 + bottomPadding),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          KeyedSubtree(key: _desktopControlsKey, child: _buildMapControls()),
          const SizedBox(height: 10),
          // Le volet droit embarque déjà la carte position : on ne la duplique pas.
          if (_openPanel == null)
            SizedBox(
              key: _desktopCardKey,
              width: 560,
              child: _buildPositionCard(),
            ),
        ],
      ),
    );
  }

  /// Groupe de contrôles carte flottant, identique en mobile et en desktop —
  /// même look que l'app mobile (ride en cours / détail du ride) : un seul bloc
  /// sombre flouté, boutons collés. Le dernier bouton cycle entre les fonds de
  /// carte (Plan → Satellite → Topo) en affichant l'icône du style courant.
  Widget _buildMapControls() {
    Widget btn({Key? key, required Widget child, required VoidCallback onTap}) {
      return GestureDetector(
        onTap: onTap,
        child: SizedBox(key: key, width: 46, height: 46, child: Center(child: child)),
      );
    }

    Widget separator() => Container(height: 1, color: Colors.white.withValues(alpha: 0.09));

    final buttons = <Widget>[];
    if (!_isFinished) {
      buttons.add(btn(
        key: _refreshBtnKey,
        onTap: _toggleRefreshMenu,
        child: isRefreshing
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange))
            : const Icon(Icons.sync, color: Colors.white, size: 22),
      ));
      buttons.add(separator());
    }
    buttons.add(btn(
      onTap: () { final pts = tracePoints; if (pts.isNotEmpty) _fitBounds(pts); },
      child: const Icon(Icons.fit_screen, color: Colors.white, size: 22),
    ));
    buttons.add(separator());
    buttons.add(btn(onTap: _recenter, child: const Icon(Icons.my_location, color: Colors.white, size: 22)));
    buttons.add(separator());
    // Cycle de fond de carte — icône du style courant
    buttons.add(btn(
      onTap: () => _changeMapStyle((_mapStyleIndex + 1) % kMapStyles.length),
      child: Icon(kMapStyles[_mapStyleIndex]['icon'] as IconData, color: Colors.white, size: 22),
    ));

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: 46,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.70),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: buttons),
        ),
      ),
    );
  }

  /// Date + heure compactes, sans l'année : « 11 juil. 23:51 ». Les colonnes du
  /// bandeau mobile sont trop étroites pour la date complète.
  String _formatCompactDateTime(DateTime? dt) {
    if (dt == null) return '--';
    const months = ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin',
                    'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'];
    final l = dt.toLocal();
    final h = '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
    return '${l.day} ${months[l.month - 1]} $h';
  }

  /// Une colonne du bandeau compact mobile : icône + libellé, puis la valeur.
  Widget _buildMobileStatColumn({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
    Color valueColor = Colors.white,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          Icon(icon, size: 13, color: iconColor),
          const SizedBox(width: 4),
          Flexible(
            child: Text(label,
              style: const TextStyle(color: Colors.white60, fontSize: 11),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ]),
        const SizedBox(height: 5),
        // La date rétrécit plutôt que de déborder sur les colonnes voisines.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value,
            style: TextStyle(color: valueColor, fontSize: 14, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }

  /// Bandeau compact du panneau mobile : Départ / Dernière position (ou Arrivée)
  /// / Distance / Durée sur une seule ligne. Remplace les quatre cartes empilées
  /// du desktop, qui mangeaient plus de la moitié de l'écran sur téléphone.
  Widget _buildMobileSummaryStrip() {
    Widget divider() => Container(width: 1, color: Colors.white12);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: _buildMobileStatColumn(
              icon: Icons.play_circle,
              iconColor: const Color(0xFFFF8A00),
              label: 'Départ',
              value: _formatCompactDateTime(rideStartTime),
            ),
          ),
          divider(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 10),
              child: _buildMobileStatColumn(
                icon: _isFinished ? Icons.sports_score_sharp : Icons.my_location,
                iconColor: _isFinished ? const Color(0xFF8B5CF6) : const Color(0xFFD946EF),
                label: _isFinished ? 'Arrivée' : 'Dernière pos.',
                value: _formatCompactDateTime(lastUpdate),
              ),
            ),
          ),
          divider(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 10),
              child: _buildMobileStatColumn(
                icon: Icons.add_road,
                iconColor: Colors.white54,
                label: 'Distance',
                value: _formatDistance(_totalDistanceMeters),
                valueColor: const Color(0xFFFF8A00),
              ),
            ),
          ),
          divider(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 10),
              child: _buildMobileStatColumn(
                icon: Icons.schedule,
                iconColor: Colors.white54,
                label: 'Durée',
                value: _formatDuration(_rideDuration),
                valueColor: const Color(0xFFFF8A00),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  /// Panneau mobile compact : en-tête position, bandeau des 4 chiffres clés, puis
  /// deux actions. Tout le reste (points de passage, dénivelé, vitesse) part dans
  /// la feuille « Voir les détails » — le panneau tient ainsi en bas de l'écran
  /// sans jamais manger la carte.
  Widget _buildMobileBottomPanel(double bottomPadding) {
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, 14, 12 + bottomPadding),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1B1B1B),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text(_isFinished ? 'DERNIÈRE POSITION CONNUE' : 'POSITION EN DIRECT',
                style: const TextStyle(color: Color(0xFFFF8A00), fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.0)),
              const Spacer(),
              _buildStatusPill(),
            ]),
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Icon(_isFinished ? Icons.sports_score_sharp : Icons.my_location, color: _isFinished ? const Color(0xFF8B5CF6) : const Color(0xFFD946EF), size: 20),
              const SizedBox(width: 6),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(_formatSinceLastUpdate(),
                    style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold, height: 1.1)),
                ),
              ),
              // Le bandeau compact n'a pas la place d'une colonne batterie :
              // la pastille se place ici, à côté de la fraîcheur du signal.
              if (_batteryLevel != null) ...[
                const SizedBox(width: 8),
                _buildBatteryChip(_batteryLevel!),
              ],
              if (!_isFinished) ...[
                const SizedBox(width: 8),
                _buildSignalIndicator(),
              ],
            ]),
            const SizedBox(height: 12),
            _buildMobileSummaryStrip(),
            const SizedBox(height: 10),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _showDetailsSheet(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: const Row(children: [
                  Text('Voir les détails',
                    style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                  Spacer(),
                  Icon(Icons.chevron_right, color: Colors.white38, size: 20),
                ]),
              ),
            ),
            const SizedBox(height: 10),
            _buildOpenPositionButton(fullWidth: true),
          ],
        ),
      ),
    );
  }

  bool _forcingUpdate = false;

  /// Vide le service worker + tous les caches puis recharge la page.
  /// Équivaut à un "hard refresh" mais déclenché par l'utilisateur en un tap,
  /// ce qui est bien plus simple à expliquer (et faisable sur mobile/tablette).
  Future<void> _forceUpdate() async {
    if (_forcingUpdate) return;
    setState(() => _forcingUpdate = true);
    try {
      final sw = html.window.navigator.serviceWorker;
      if (sw != null) {
        final regs = await sw.getRegistrations();
        for (final reg in regs) {
          try { await reg.unregister(); } catch (_) {}
        }
      }
    } catch (_) {}
    try {
      final caches = html.window.caches;
      if (caches != null) {
        final keys = await caches.keys();
        for (final key in keys) {
          try { await caches.delete(key); } catch (_) {}
        }
      }
    } catch (_) {}
    // Recharge la page : le nouveau service worker et les nouveaux assets
    // seront re-téléchargés depuis le serveur.
    html.window.location.reload();
  }

  Widget _buildErrorScreen() {
    final isMissingCode = errorMessage == 'missing_code';
    final isNoPosition = errorMessage == 'Aucune position disponible';
    final isSystemError = errorMessage == 'system_error';
    final IconData icon = isMissingCode ? Icons.link_off : isNoPosition ? Icons.location_off : Icons.cloud_off;
    final Color iconBg = isMissingCode ? const Color(0xFF2D2010) : isNoPosition ? const Color(0xFF1A2030) : const Color(0xFF2A1A1A);
    final Color iconColor = isMissingCode ? const Color(0xFFFACC15) : isNoPosition ? const Color(0xFF60A5FA) : const Color(0xFFF87171);
    final String title = isMissingCode ? 'Lien de partage invalide' : isNoPosition ? 'Aucune position disponible' : 'Impossible de charger le ride';
    final String subtitle = isMissingCode
        ? 'Ce lien ne contient pas de code de ride. Il a peut-être expiré, été mal copié, ou tu l\'as ouvert directement sans paramètre.'
        : isNoPosition ? 'Le ride existe mais aucune position GPS n\'a encore été enregistrée. Attends quelques secondes et rafraîchis la page.'
        : 'Une erreur s\'est produite lors de la connexion au serveur. Vérifie ta connexion internet et réessaie.';

    return Column(children: [
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
        const SizedBox(height: 40),
        Container(width: 80, height: 80, decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle), child: Icon(icon, color: iconColor, size: 36)),
        const SizedBox(height: 24),
        Text(title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Text(subtitle, style: const TextStyle(color: Colors.white60, fontSize: 15, height: 1.6), textAlign: TextAlign.center),
        const SizedBox(height: 32),
        if (isMissingCode)
          Container(width: double.infinity, padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: const Color(0xFF1B1B1B), borderRadius: BorderRadius.circular(16)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Comment obtenir un lien valide ?', style: TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            _buildStep(1, 'Ouvre l\'application Sunday Tracker sur ton téléphone'),
            const SizedBox(height: 10),
            _buildStep(2, 'Lance ou sélectionne un ride en cours'),
            const SizedBox(height: 10),
            _buildStep(3, 'Appuie sur Partager le suivi pour générer ton lien'),
          ])),
        if (!isMissingCode) ...[
          SizedBox(width: double.infinity, child: ElevatedButton.icon(
            onPressed: () { setState(() { errorMessage = null; errorDetails = null; isLoading = true; }); loadLastPosition(); },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1B1B1B), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30))),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Réessayer'),
          )),
        ],
        if (isSystemError && errorDetails != null) ...[
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () => setState(() => _errorDetailsExpanded = !_errorDetailsExpanded),
            child: Container(width: double.infinity, decoration: BoxDecoration(color: const Color(0xFF1B1B1B), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white.withValues(alpha: 0.08))), child: Column(children: [
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), child: Row(children: [
                const Icon(Icons.bug_report_outlined, color: Colors.white60, size: 16),
                const SizedBox(width: 8),
                const Expanded(child: Text('Voir les détails techniques', style: TextStyle(color: Colors.white60, fontSize: 13))),
                Icon(_errorDetailsExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: Colors.white60, size: 18),
              ])),
              if (_errorDetailsExpanded)
                Container(width: double.infinity, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(8)), child: SelectableText(errorDetails!, style: const TextStyle(color: Colors.white54, fontSize: 11, fontFamily: 'monospace', height: 1.6)))),
            ])),
          ),
        ],
        const SizedBox(height: 24),
        TextButton.icon(
          onPressed: _forcingUpdate ? null : _forceUpdate,
          style: TextButton.styleFrom(foregroundColor: Colors.white54, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
          icon: _forcingUpdate
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54))
              : const Icon(Icons.refresh, size: 18),
          label: Text(_forcingUpdate ? 'Actualisation…' : 'Forcer l\'actualisation de la page'),
        ),
        const Text('À utiliser si l\'app semble bloquée sur une ancienne version', style: TextStyle(color: Colors.white30, fontSize: 11), textAlign: TextAlign.center),
      ]))),
      Padding(padding: const EdgeInsets.only(bottom: 16), child: Text(appVersion, style: const TextStyle(color: Colors.white38, fontSize: 11))),
    ]);
  }

  Widget _buildStep(int number, String text) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(width: 22, height: 22, decoration: const BoxDecoration(color: Color(0xFF1E3A5F), shape: BoxShape.circle), child: Center(child: Text('$number', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF60A5FA))))),
      const SizedBox(width: 12),
      Expanded(child: Text(text, style: const TextStyle(color: Colors.white60, fontSize: 13, height: 1.5))),
    ]);
  }

  // ── Waypoints ─────────────────────────────────────────────────────────────

  int get _waypointCount {
    int n = 0;
    if (tracePositions.isNotEmpty) n++;
    n += _checkpoints.length;
    if (tracePositions.length > 1 || _isFinished) n++;
    return n;
  }

  /// Extrait les URL publiques Supabase des photos d'un waypoint.
  /// Format mobile : `List<{'local': <chemin téléphone>, 'url': <http public>}>`.
  /// On ignore 'local' (inaccessible depuis le web) et les entrées legacy String
  /// (ancien format = simple chemin local, jamais uploadé).
  List<String> _waypointPhotoUrls(dynamic photos) {
    if (photos is! List) return const [];
    final urls = <String>[];
    for (final p in photos) {
      if (p is Map) {
        final u = p['url'];
        if (u is String && u.isNotEmpty) urls.add(u);
      }
    }
    return urls;
  }

  /// Visionneuse plein écran d'une galerie de photos (swipe entre les photos +
  /// pinch-to-zoom). Ouverte au tap sur une vignette de waypoint.
  void _openPhotoGallery(List<String> urls, int initialIndex) {
    final controller = PageController(initialPage: initialIndex);
    final pageNotifier = ValueNotifier<int>(initialIndex);
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.94),
      builder: (dialogCtx) => Stack(
        children: [
          PageView.builder(
            controller: controller,
            itemCount: urls.length,
            onPageChanged: (i) => pageNotifier.value = i,
            itemBuilder: (_, i) => InteractiveViewer(
              minScale: 0.8,
              maxScale: 4,
              child: Center(
                child: Image.network(
                  urls[i],
                  fit: BoxFit.contain,
                  loadingBuilder: (ctx, child, progress) => progress == null
                      ? child
                      : const Center(child: CircularProgressIndicator(color: Colors.white38)),
                  errorBuilder: (ctx, error, stack) => const Center(
                    child: Icon(Icons.broken_image, color: Colors.white24, size: 48),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: GestureDetector(
                  onTap: () => Navigator.of(dialogCtx).pop(),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), shape: BoxShape.circle),
                    child: const Icon(Icons.close, color: Colors.white, size: 22),
                  ),
                ),
              ),
            ),
          ),
          if (urls.length > 1)
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: ValueListenableBuilder<int>(
                    valueListenable: pageNotifier,
                    builder: (_, page, _) => Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(999)),
                      child: Text('${page + 1} / ${urls.length}',
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ).then((_) {
      controller.dispose();
      pageNotifier.dispose();
    });
  }

  /// Tap sur la pastille numérotée d'un point de passage sur la carte.
  /// - Smartphone : feuille modale glissante avec les infos du point (heure,
  ///   note, photos, coordonnées), calquée sur l'écran détail du ride mobile.
  /// - Navigateur : ouvre simplement le volet « Points de passage » et fait
  ///   défiler jusqu'au point cliqué, mis en évidence.
  void _showCheckpointInfo(Map cp, int number) {
    final isMobileLayout = MediaQuery.sizeOf(context).width < 900;
    if (isMobileLayout) {
      showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF18181B),
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        builder: (ctx) => SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 48, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(999))),
              const SizedBox(height: 16),
              _buildCheckpointDetail(cp, number),
            ]),
          ),
        ),
      );
    } else {
      setState(() {
        _highlightedCheckpoint = number - 1;
        _openPanel = _SidePanel.waypoints;
      });
      // Défilement vers l'item mis en évidence, une fois le volet en place.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _highlightKey.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              alignment: 0.3);
        }
      });
    }
  }

  /// Contenu partagé (feuille mobile / dialogue navigateur) des infos d'un point.
  Widget _buildCheckpointDetail(Map cp, int number) {
    final kind = waypointKindOf(cp);
    final color = kind.color;
    final dt = DateTime.tryParse(cp['created_at'] ?? '')?.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final timeStr = dt != null ? '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}' : '--:--:--';
    final comment = (cp['comment'] as String?)?.trim() ?? '';
    final photoUrls = (cp['photo_urls'] as List?)?.cast<String>() ?? const [];
    final lat = (cp['lat'] as num?)?.toDouble();
    final lng = (cp['lng'] as num?)?.toDouble();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          width: 26, height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
          child: waypointBadgeContent(
            kind: kind, size: 26, color: Colors.white,
            child: Text('$number',
              style: TextStyle(
                color: Colors.white,
                fontSize: number >= 10 ? 12 : 14, fontWeight: FontWeight.w800, height: 1)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text('${kind.label} · $timeStr',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
        ),
      ]),
      const SizedBox(height: 12),
      if (comment.isNotEmpty)
        Text(comment, style: const TextStyle(fontSize: 15, color: Colors.white70, height: 1.4))
      else
        const Text('Aucune note', style: TextStyle(fontSize: 15, color: Colors.white38, fontStyle: FontStyle.italic)),
      if (photoUrls.isNotEmpty) ...[
        const SizedBox(height: 16),
        SizedBox(
          height: 100,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: photoUrls.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) => GestureDetector(
              onTap: () => _openPhotoGallery(photoUrls, i),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  photoUrls[i], height: 100, width: 100, fit: BoxFit.cover,
                  loadingBuilder: (ctx, child, progress) => progress == null
                      ? child
                      : Container(
                          width: 100, height: 100,
                          color: const Color(0xFF2A2A2A),
                          alignment: Alignment.center,
                          child: const SizedBox(width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38)),
                        ),
                  errorBuilder: (ctx, error, stack) => Container(
                    width: 100, height: 100,
                    color: const Color(0xFF2A2A2A),
                    child: const Icon(Icons.broken_image, color: Colors.white24, size: 22),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
      if (lat != null && lng != null) ...[
        const SizedBox(height: 16),
        Text('Lat ${lat.toStringAsFixed(6)}  ·  Long ${lng.toStringAsFixed(6)}',
          style: const TextStyle(fontSize: 12, color: Colors.white38)),
      ],
    ]);
  }

  Widget _buildTimelinePoint({
    required String type,
    required String label,
    DateTime? time,
    String? comment,
    List<String> photoUrls = const [],
    int? number,
    required bool isLast,
    bool highlighted = false,
    WaypointKind kind = WaypointKind.memo,
  }) {
    final Color dotColor;
    final Widget dotInner;
    switch (type) {
      case 'start':
        dotColor = const Color(0xFFFF8A00);
        dotInner = const Icon(Icons.play_arrow, color: Colors.white, size: 12);
        break;
      case 'end':
        dotColor = const Color(0xFF6D28D9);
        dotInner = const Icon(Icons.sports_score_sharp, color: Colors.white, size: 12);
        break;
      case 'current':
        dotColor = const Color(0xFFD946EF);
        dotInner = const Icon(Icons.my_location, color: Colors.white, size: 12);
        break;
      default:
        // Bleu pour tous les points ; étincelle = détectée par l'app
        // (cf. WaypointKind).
        dotColor = const Color(0xFF3B82F6);
        dotInner = waypointBadgeContent(
          kind: kind, size: 22, color: Colors.white,
          child: number != null
              ? Text('$number', style: TextStyle(color: Colors.white, fontSize: number >= 10 ? 10 : 11, fontWeight: FontWeight.w700, height: 1))
              : Icon(kind.isPause ? Icons.pause_rounded : Icons.location_on, color: Colors.white, size: 12),
        );
    }
    final timeStr = time != null
        ? '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}'
        : '--:--';

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 26,
            child: Column(
              children: [
                Container(
                  width: 22, height: 22,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                  child: Center(child: dotInner),
                ),
                if (!isLast)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Center(child: Container(width: 2, color: Colors.white12)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: 1, bottom: isLast ? 0 : 20),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                padding: highlighted
                    ? const EdgeInsets.fromLTRB(10, 8, 10, 8)
                    : EdgeInsets.zero,
                decoration: highlighted
                    ? BoxDecoration(
                        color: const Color(0xFF2563EB).withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF2563EB).withValues(alpha: 0.5)),
                      )
                    : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                  Row(children: [
                    Flexible(child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700))),
                    // Puce « auto » : dit en toutes lettres ce que l'étincelle
                    // code graphiquement (pause détectée par l'app).
                    if (type == 'checkpoint' && kind.badgeLabel != null) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: dotColor, width: 1),
                        ),
                        child: Text(kind.badgeLabel!,
                          style: TextStyle(
                            fontSize: 9, fontWeight: FontWeight.w700, height: 1.2, color: dotColor)),
                      ),
                    ],
                    const Spacer(),
                    Text(timeStr, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                  ]),
                  if (comment != null && comment.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(comment, style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.4)),
                  ],
                  if (photoUrls.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 80,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: photoUrls.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 6),
                        itemBuilder: (_, i) => GestureDetector(
                          onTap: () => _openPhotoGallery(photoUrls, i),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              photoUrls[i], height: 80, width: 80, fit: BoxFit.cover,
                              loadingBuilder: (ctx, child, progress) => progress == null
                                  ? child
                                  : Container(
                                      width: 80, height: 80,
                                      color: const Color(0xFF2A2A2A),
                                      alignment: Alignment.center,
                                      child: const SizedBox(width: 16, height: 16,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38)),
                                    ),
                              errorBuilder: (context, error, stack) => Container(
                                width: 80, height: 80,
                                color: const Color(0xFF2A2A2A),
                                child: const Icon(Icons.broken_image, color: Colors.white24, size: 20),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaypointTimeline() {
    if (tracePositions.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Aucun point disponible', style: TextStyle(color: Colors.white38, fontSize: 13)),
      );
    }

    final departurePos = tracePositions.last;
    final latestPos = tracePositions.first;
    final departureTime = DateTime.tryParse(departurePos['created_at'] ?? '')?.toLocal();
    final latestTime = DateTime.tryParse(latestPos['created_at'] ?? '')?.toLocal();
    final hasEndPoint = tracePositions.length > 1 || _isFinished;
    final total = 1 + _checkpoints.length + (hasEndPoint ? 1 : 0);
    int idx = 0;

    final widgets = <Widget>[];

    widgets.add(_buildTimelinePoint(
      type: 'start', label: 'Départ', time: departureTime,
      isLast: ++idx == total,
    ));

    for (final (i, cp) in _checkpoints.indexed) {
      final dt = DateTime.tryParse(cp['created_at'] ?? '')?.toLocal();
      final isHighlighted = _highlightedCheckpoint == i;
      final kind = waypointKindOf(cp);
      widgets.add(KeyedSubtree(
        key: isHighlighted ? _highlightKey : null,
        child: _buildTimelinePoint(
          type: 'checkpoint', label: kind.label, time: dt, kind: kind,
          comment: cp['comment'] as String?,
          photoUrls: (cp['photo_urls'] as List?)?.cast<String>() ?? const [],
          number: i + 1,
          isLast: ++idx == total,
          highlighted: isHighlighted,
        ),
      ));
    }

    if (hasEndPoint) {
      widgets.add(_buildTimelinePoint(
        type: _isFinished ? 'end' : 'current',
        label: _isFinished ? 'Arrivée' : 'Dernière position',
        time: latestTime,
        isLast: true,
      ));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: widgets);
  }

  /// Feuille « Voir les détails » du panneau mobile : les points de passage, plus
  /// un bouton « + d'infos » qui déplie le dénivelé et la vitesse (l'équivalent
  /// du 2e onglet du volet desktop). Replié par défaut : la timeline reste
  /// l'information de premier plan.
  void _showDetailsSheet(BuildContext context) {
    var statsExpanded = false;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.45,
        minChildSize: 0.22,
        maxChildSize: 0.92,
        snap: true,
        snapSizes: const [0.22, 0.45, 0.92],
        builder: (ctx, scrollCtrl) => StatefulBuilder(
          builder: (ctx, setSheetState) => Container(
            decoration: const BoxDecoration(
              color: Color(0xFF18181B),
              borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
            ),
            child: Column(children: [
              const SizedBox(height: 10),
              Container(width: 48, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(999))),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  const Text('Points de passage', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 6),
                  Text('· $_waypointCount', style: const TextStyle(color: Colors.white38, fontSize: 14, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.pop(ctx),
                    child: Container(
                      width: 28, height: 28,
                      decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(8)),
                      child: const Icon(Icons.close, color: Colors.white60, size: 15),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildWaypointTimeline(),
                      if (!_stats.isEmpty) ...[
                        const SizedBox(height: 6),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setSheetState(() => statsExpanded = !statsExpanded),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: Row(children: [
                              const Icon(Icons.insights, color: Color(0xFF4F9CFF), size: 16),
                              const SizedBox(width: 8),
                              const Text('+ d\'infos',
                                style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                              const SizedBox(width: 6),
                              const Text('Dénivelé · Vitesse',
                                style: TextStyle(color: Colors.white38, fontSize: 12)),
                              const Spacer(),
                              Icon(statsExpanded ? Icons.expand_less : Icons.expand_more,
                                color: Colors.white38, size: 20),
                            ]),
                          ),
                        ),
                        if (statsExpanded) ...[
                          const SizedBox(height: 10),
                          RideStatsSection(stats: _stats, live: !_isFinished),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  /// Onglets verticaux du bord droit : « Points de passage », puis « Stats »
  /// juste en dessous. Chacun déplie le même volet glissant, sur son contenu.
  /// L'onglet Stats disparaît tant qu'il n'y a pas assez de points GPS pour
  /// calculer quoi que ce soit.
  Widget _buildSideTabs() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _buildSideTab(
          label: 'Points de passage · $_waypointCount',
          panel: _SidePanel.waypoints,
        ),
        if (!_stats.isEmpty) ...[
          const SizedBox(height: 8),
          _buildSideTab(label: '+ d\'infos', panel: _SidePanel.stats),
        ],
      ],
    );
  }

  Widget _buildSideTab({required String label, required _SidePanel panel}) {
    return GestureDetector(
      onTap: () => setState(() {
        _highlightedCheckpoint = null;
        _openPanel = panel;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1B1B1B),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(10),
            bottomLeft: Radius.circular(10),
          ),
          border: Border.all(color: Colors.white12),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 12)],
        ),
        child: RotatedBox(
          quarterTurns: 3,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.2),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopSidePanel(double topPadding, double bottomPadding) {
    final isStats = _openPanel == _SidePanel.stats;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D0D).withValues(alpha: 0.96),
        border: const Border(left: BorderSide(color: Colors.white12)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 20, offset: const Offset(-4, 0))],
      ),
      child: Column(children: [
        SizedBox(height: topPadding + 12),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: Row(children: [
            Text(isStats ? '+ d\'infos' : 'Points de passage',
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
            if (!isStats) ...[
              const SizedBox(width: 6),
              Text('· $_waypointCount', style: const TextStyle(color: Colors.white38, fontSize: 14, fontWeight: FontWeight.w600)),
            ],
            const Spacer(),
            GestureDetector(
              onTap: () => setState(() {
                _highlightedCheckpoint = null;
                _openPanel = null;
              }),
              child: Container(
                width: 28, height: 28,
                decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.close, color: Colors.white60, size: 15),
              ),
            ),
          ]),
        ),
        Container(height: 1, color: Colors.white12),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            child: isStats
                ? RideStatsSection(stats: _stats, live: !_isFinished)
                : _buildWaypointTimeline(),
          ),
        ),
        Container(height: 1, color: Colors.white12),
        Padding(
          padding: EdgeInsets.fromLTRB(14, 12, 14, 14 + bottomPadding),
          child: _buildPositionCard(),
        ),
      ]),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (errorMessage != null || latitude == null || longitude == null) {
      return Scaffold(backgroundColor: const Color(0xFF0D0D0D), body: SafeArea(child: _buildErrorScreen()));
    }
    final screenSize = MediaQuery.sizeOf(context);
    final isMobileLayout = screenSize.width < 900;
    final topPadding = MediaQuery.of(context).padding.top;
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildMap(),
          Positioned(
            top: 0, left: 0, right: 0,
            child: KeyedSubtree(
              key: _topOverlayKey,
              child: _buildTopOverlay(isMobileLayout, topPadding),
            ),
          ),
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: KeyedSubtree(
              key: _bottomOverlayKey,
              child: isMobileLayout
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Contrôles carte flottants, alignés au-dessus du panneau
                        Padding(
                          padding: const EdgeInsets.only(right: 14, bottom: 10),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: _buildMapControls(),
                          ),
                        ),
                        _buildMobileBottomPanel(bottomPadding),
                      ],
                    )
                  : _buildDesktopBottomBar(bottomPadding),
            ),
          ),
          // Desktop: onglets repliables + volet droit
          if (!isMobileLayout) ...[
            Positioned(
              right: 0,
              top: topPadding + 80,
              child: IgnorePointer(
                ignoring: _openPanel != null,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _openPanel != null ? 0.0 : 1.0,
                  child: _buildSideTabs(),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              top: 0,
              bottom: 0,
              right: _openPanel != null ? 0 : -340,
              width: 340,
              child: _buildDesktopSidePanel(topPadding, bottomPadding),
            ),
          ],
        ],
      ),
    );
  }
}
