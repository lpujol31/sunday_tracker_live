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

/// Onglets du volet desktop, dans leur ordre d'affichage : le récapitulatif de
/// la sortie, ses points de passage, puis les statistiques détaillées.
enum _SidePanel { overview, waypoints, stats }

// ── Marqueur « recherche en cours » de la position courante ───────
/// Icône location_searching magenta posée à même la trace — pas de pastille
/// pleine — entourée de deux cercles concentriques qui s'étalent en boucle.
/// Même marqueur que sur la carte de l'app pendant la sortie.
class _PulsingPositionMarker extends StatefulWidget {
  /// Cap en degrés quand la sortie avance : le cœur devient une flèche orientée.
  /// null (à l'arrêt) → cœur en icône de recherche GPS.
  final double? headingDeg;

  const _PulsingPositionMarker({this.headingDeg});

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
          if (widget.headingDeg == null)
            const Stack(
              alignment: Alignment.center,
              children: [
                // Liseré blanc : l'icône seule se perd sur les tuiles claires.
                Icon(Icons.location_searching, color: Colors.white, size: 30),
                Icon(Icons.location_searching, color: _color, size: 24),
              ],
            )
          else
            Transform.rotate(
              angle: widget.headingDeg! * math.pi / 180,
              child: const Stack(
                alignment: Alignment.center,
                children: [
                  // Liseré blanc : la flèche seule se perd sur les tuiles claires.
                  Icon(Icons.navigation, color: Colors.white, size: 33),
                  Icon(Icons.navigation, color: _color, size: 26),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Bouton plat des blocs desktop (« Ouvrir la position », « Voir les détails ») :
/// pleine largeur de son bloc, souligné au survol — la souris attend un retour
/// que le tactile n'exige pas.
class _DesktopFlatButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  /// Forme du fond au survol : angles bas du bloc quand le bouton le ferme,
  /// pastille arrondie quand il est posé au milieu d'un panneau.
  final BorderRadius borderRadius;

  /// Contour permanent, pour un bouton posé seul au milieu d'un panneau.
  final BoxBorder? border;

  const _DesktopFlatButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.borderRadius = const BorderRadius.vertical(bottom: Radius.circular(18)),
    this.border,
  });

  @override
  State<_DesktopFlatButton> createState() => _DesktopFlatButtonState();
}

class _DesktopFlatButtonState extends State<_DesktopFlatButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            color: _hover ? widget.color.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: widget.borderRadius,
            border: widget.border,
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(widget.icon, color: widget.color, size: 18),
            const SizedBox(width: 9),
            Text(widget.label,
                style: TextStyle(color: widget.color, fontSize: 14.5, fontWeight: FontWeight.w700)),
          ]),
        ),
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
  /// Le dernier rafraîchissement de fond a échoué alors qu'on affiche déjà des
  /// données valides : on ne détruit pas l'écran, on teinte le bouton sync.
  /// Remis à false dès qu'un chargement aboutit.
  bool _refreshFailed = false;

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

  /// Distance cumulée le long du tracé, horodatée : (instant du point, mètres
  /// depuis le départ). Construite en même temps que la distance totale, sur la
  /// même source qu'elle — d'où le « 43,5 km » de l'arrivée qui tombe juste. Sert
  /// à situer un point de passage dans la sortie (cf. [_distanceAtTime]).
  List<(DateTime, double)> _distanceMarks = const [];

  Timer? _tickerTimer;
  Duration _sinceLastUpdate = Duration.zero;

  MapController mapController = MapController();
  int _mapStyleIndex = 0;
  bool _initialCameraDone = false;
  bool _mapReady = false;

  /// Zoom de la vue d'ouverture et du bouton « recentrer ».
  static const double _kDefaultZoom = 15.0;

  double _savedZoom = _kDefaultZoom;
  LatLng? _savedCenter;

  Timer? refreshTimer;
  int refreshIntervalSeconds = 30;

  final shareCode = Uri.base.queryParameters['code'];

  List<Map<String, dynamic>> _checkpoints = [];
  /// Onglet affiché par le volet desktop.
  _SidePanel _openPanel = _SidePanel.overview;
  /// Volet desktop replié contre le bord droit : la carte reprend toute la
  /// largeur, une poignée verticale permet de le rouvrir.
  bool _panelCollapsed = false;
  // Point de passage mis en évidence dans le volet desktop (tap sur sa pastille
  // carte). Index dans _checkpoints ; null = aucun. _highlightKey est attachée à
  // l'item correspondant pour l'y faire défiler automatiquement.
  int? _highlightedCheckpoint;
  // Même mise en évidence, pour les deux bouts de la trace : 'start' ou 'end'
  // (l'arrivée, ou la dernière position tant que la sortie tourne). Exclusif de
  // _highlightedCheckpoint — un seul point est surligné à la fois.
  String? _highlightedEndpoint;
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
  // Blocs desktop posés sur la carte : on mesure leurs bords pour savoir quelles
  // colonnes sont occupées (en-tête et contrôles à gauche, volet à droite).
  final GlobalKey _desktopControlsKey = GlobalKey();
  final GlobalKey _desktopHeaderKey = GlobalKey();
  final GlobalKey _desktopPanelKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _stripCacheBustParam();
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

  /// Pastille de statut du ride. [compact] réduit typo et rembourrage pour le
  /// bandeau flottant mobile, où elle partage la ligne avec la batterie et le
  /// signal. [large] est la version desktop posée à côté du titre : fond sombre
  /// plutôt que teinté, pour tenir à côté d'un titre de 40 px sans crier.
  Widget _buildStatusPill({bool compact = false, bool large = false, bool mobile = false}) {
    final color = getStatusColor();
    final icon = getStatusIcon();
    final label = _isFinished ? 'Ride terminé'
        : rideStatus == 'in_progress' ? 'Ride en cours'
        : rideStatus == 'paused' ? 'Ride en pause'
        : 'Statut du ride indisponible';
    if (large) {
      // Pastille pleine du volet desktop : le statut est l'information la plus
      // forte de l'onglet, elle porte la couleur en aplat. Sur le jaune de la
      // pause, le texte passe en sombre — le blanc y serait illisible.
      final onColor = rideStatus == 'paused' ? const Color(0xFF231705) : Colors.white;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 16, offset: const Offset(0, 4))],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(rideStatus == 'in_progress' ? Icons.directions_bike : icon, color: onColor, size: 18),
          const SizedBox(width: 10),
          Text(label,
            style: TextStyle(color: onColor, fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 0.1)),
        ]),
      );
    }
    // [mobile] : même pastille cerclée que la version courte, à la taille des
    // autres indicateurs de la carte d'état du téléphone.
    return Container(
      padding: mobile
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 6)
          : compact
              ? const EdgeInsets.symmetric(horizontal: 8, vertical: 3)
              : const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: mobile ? 0.13 : 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: compact ? 9 : (mobile ? 14 : 13)),
          SizedBox(width: compact ? 4 : 6),
          Text(label,
              style: TextStyle(
                color: color,
                fontSize: compact ? 10 : (mobile ? 13.5 : 12),
                fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  bool get _isFinished => rideStatus == 'finished';

  /// Durée totale depuis le départ, pauses comprises — le simple temps écoulé,
  /// à ne pas confondre avec `_rideDuration` qui, lui, retire les pauses.
  /// Sortie en cours : jusqu'à maintenant (le ticker d'une seconde la fait
  /// avancer) ; sortie terminée : jusqu'au dernier point reçu, c.-à-d. l'arrivée.
  Duration? get _elapsedSinceStart {
    final start = rideStartTime;
    if (start == null) return null;
    final end = _isFinished ? lastUpdate : DateTime.now();
    if (end == null) return null;
    final elapsed = end.difference(start);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

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

  /// [large] : version desktop du volet — barres de réseau plutôt qu'une simple
  /// pastille, à la taille des autres lignes de l'aperçu.
  Widget _buildSignalIndicator({bool large = false}) {
    final color = _getSignalColor();
    return Tooltip(
      message: '< 2 min : Signal reçu\n2–5 min : Signal faible\n> 5 min : Signal perdu',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (large)
            Icon(Icons.signal_cellular_alt, color: color, size: 18)
          else
            Container(
              width: 7, height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          SizedBox(width: large ? 8 : 5),
          Text(_getSignalLabel(),
            style: TextStyle(color: color, fontSize: large ? 15 : 10, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  /// Pastille de version, calée au pied du titre desktop. Un clic déplie les
  /// détails sous le titre (cf. [_buildVersionDetails]) plutôt que dans la
  /// pastille elle-même, dont la croissance ferait sauter la ligne de titre.
  Widget _buildVersionBadge() {
    final version = appVersion.split('+').first.trim();
    if (version.isEmpty) return const SizedBox.shrink();
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _versionExpanded = !_versionExpanded),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Text(version,
              style: const TextStyle(color: Colors.white70, fontSize: 12.5, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  /// Détails de version dépliés sous le titre : numéro de build et actualisation
  /// forcée. Cette dernière doit rester atteignable même quand la page est figée
  /// sur une ancienne version — d'où sa présence dans l'en-tête, et non dans le
  /// menu du bouton sync qui disparaît sur un ride terminé.
  Widget _buildVersionDetails() {
    final build = _formattedBuild;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (build.isNotEmpty)
            Text('build $build', style: const TextStyle(color: Colors.white54, fontSize: 11)),
          const SizedBox(height: 7),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _forcingUpdate ? null : _forceUpdate,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _forcingUpdate
                    ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFFFF8A00)))
                    : const Icon(Icons.refresh, size: 14, color: Color(0xFFFF8A00)),
                const SizedBox(width: 6),
                Text(_forcingUpdate ? 'Actualisation…' : 'Forcer l\'actualisation de la page',
                    style: const TextStyle(color: Color(0xFFFF8A00), fontSize: 11, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ],
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

  /// Cap à afficher sur le repère de position (degrés, 0 = nord), ou null si
  /// l'orientation n'est pas exploitable → pastille cible à la place.
  ///
  /// Le live ne reçoit pas le heading GPS du téléphone (absent de
  /// safety_positions) : on le déduit de la fin du tracé. Comme sur l'app, le
  /// cap n'a de sens qu'en mouvement, d'où les trois garde-fous : ride en cours,
  /// signal frais, et un dernier segment assez long (au repos le GPS gigote de
  /// quelques mètres, ce qui ferait tourner la flèche dans le vide).
  double? get _markerHeading {
    if (rideStatus != 'in_progress') return null;
    // Même seuil que l'indicateur de signal (« Signal reçu » < 2 min) : au-delà
    // le cap décrit un passé trop lointain pour être affirmé. Un seuil plus
    // serré rendait la flèche clignotante — le live n'interroge la base que
    // toutes les 30 s, une position en retard suffisait à l'éteindre.
    if (lastUpdate == null ||
        DateTime.now().difference(lastUpdate!) > const Duration(minutes: 2)) {
      return null;
    }
    final points = tracePoints;
    if (points.length < 2) return null;
    final to = points.last;
    // Remonte le tracé jusqu'à trouver un point assez éloigné pour donner une
    // direction fiable. Fenêtre bornée : au-delà, on décrirait un cap périmé.
    const minMeters = 15.0;
    const maxLookBack = 6;
    LatLng? from;
    for (int i = points.length - 2;
        i >= 0 && i >= points.length - 2 - maxLookBack;
        i--) {
      if (_haversineMeters(points[i], to) >= minMeters) {
        from = points[i];
        break;
      }
    }
    if (from == null) return null;
    return _bearingDegrees(from, to);
  }

  /// Cap initial du segment [a] → [b], en degrés depuis le nord (sens horaire).
  double _bearingDegrees(LatLng a, LatLng b) {
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  void _computeStats(List<Map<String, dynamic>> positions) {
    // Distance : utilise ride_json.points (dense, toutes les 5m) si dispo, sinon safety_positions (toutes les 15s)
    final fromRideJson = _isFinished && _rideJsonPoints.isNotEmpty;
    final distPoints = fromRideJson
        ? _rideJsonPoints.map((p) => LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble())).toList()
        : positions.reversed.map((p) => LatLng((p['latitude'] as num).toDouble(), (p['longitude'] as num).toDouble())).toList();
    // Horodatage du même point, au même rang : c'est ce qui permet de dire à
    // quelle distance du départ se trouve un point de passage. `ts` est la clé
    // de ride_json (`time`/`timestamp` pour les vieilles sorties).
    final distTimes = fromRideJson
        ? _rideJsonPoints
            .map((p) => DateTime.tryParse('${p['ts'] ?? p['time'] ?? p['timestamp'] ?? ''}')?.toLocal())
            .toList()
        : positions.reversed
            .map((p) => DateTime.tryParse(p['created_at'] ?? '')?.toLocal())
            .toList();
    double dist = 0;
    final marks = <(DateTime, double)>[];
    if (distTimes.isNotEmpty && distTimes.first != null) marks.add((distTimes.first!, 0));
    for (int i = 1; i < distPoints.length; i++) {
      dist += _haversineMeters(distPoints[i - 1], distPoints[i]);
      final t = distTimes[i];
      if (t != null) marks.add((t, dist));
    }
    _totalDistanceMeters = dist;
    _distanceMarks = marks;
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
    return '${(meters / 1000).toStringAsFixed(2).replaceAll('.', ',')} km';
  }

  /// Distance en une valeur courte, pour les listes : « 8,4 km ».
  String _formatDistanceShort(double meters) {
    if (meters < 1000) return '${meters.toStringAsFixed(0)} m';
    return '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
  }

  /// Distance parcourue à l'instant [t], lue dans [_distanceMarks] : le dernier
  /// point du tracé antérieur à [t]. Null si l'instant est inconnu ou tombe hors
  /// du tracé (sortie sans horodatage exploitable) — l'appelant n'affiche alors
  /// simplement rien.
  double? _distanceAtTime(DateTime? t) {
    if (t == null || _distanceMarks.isEmpty) return null;
    final target = t.toLocal();
    if (target.isBefore(_distanceMarks.first.$1)) return null;
    double? found;
    for (final (markTime, meters) in _distanceMarks) {
      if (markTime.isAfter(target)) break;
      found = meters;
    }
    return found;
  }

  String _formatDuration(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
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

  /// Abscisse du bord droit d'un bloc posé sur la carte, ou null s'il n'est pas
  /// (encore) affiché.
  double? _blockRightEdge(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero).dx + box.size.width;
  }

  /// Zones libres candidates pour cadrer le tracé, exprimées en marges à retirer
  /// de la carte (qui occupe tout l'écran, les panneaux la recouvrant).
  ///
  /// En mobile les panneaux sont des bandeaux pleine largeur : la seule zone
  /// libre est la bande horizontale entre les deux. En desktop les blocs sont
  /// dans les coins (titre en haut à gauche, contrôles en bas à gauche, volet à
  /// droite) : réserver la hauteur du titre sur *toute* la largeur ampute la
  /// carte pour rien. On propose donc aussi une zone « pleine hauteur, colonne
  /// du titre réservée », et [_fitBounds] garde celle qui permet le plus gros
  /// zoom — c'est-à-dire celle dont le rapport de forme colle le mieux au tracé
  /// (bande large pour un tracé étiré, colonne haute pour un tracé compact ou
  /// vertical).
  ///
  /// Chaque marge est bornée pour ne jamais dévorer la carte (sinon le fit
  /// renvoie un zoom aberrant).
  List<EdgeInsets> _mapFitCandidates() {
    const margin = 24.0;
    final size = MediaQuery.sizeOf(context);
    final isMobileLayout = size.width < 900;
    final top = _overlayHeight(_topOverlayKey).clamp(0.0, size.height * 0.30);
    final bottom = _overlayHeight(_bottomOverlayKey).clamp(0.0, size.height * 0.50);

    if (isMobileLayout) {
      // Les deux bandeaux mobiles sont pleine largeur (contrôles carte compris,
      // portés par celui du bas) : la seule zone libre est entre les deux.
      return [EdgeInsets.fromLTRB(margin, top + 16, margin, bottom + 16)];
    }

    // Colonne de droite : le volet flottant, replié ou non.
    final panelLeft = _panelCollapsed ? null : _blockLeftEdge(_desktopPanelKey);
    final rightColumn = (panelLeft != null ? size.width - panelLeft + margin : margin)
        .clamp(0.0, size.width * 0.55);
    // Colonne de gauche : les contrôles carte, et l'échelle sous eux.
    final controlsRight = _blockRightEdge(_desktopControlsKey);
    final leftColumn = ((controlsRight ?? margin) + margin).clamp(0.0, size.width * 0.20);

    return [
      // Bande entre le titre et le bas de l'écran.
      EdgeInsets.fromLTRB(leftColumn, top + 16, rightColumn, margin + 24),
      // Pleine hauteur, la colonne du titre en moins.
      EdgeInsets.fromLTRB(
        math.max(leftColumn, ((_blockRightEdge(_desktopHeaderKey) ?? 0) + margin))
            .clamp(0.0, size.width * 0.45),
        margin,
        rightColumn,
        margin + 24,
      ),
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
      _moveTo(points.first, _kDefaultZoom);
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
      _moveTo(points.first, _kDefaultZoom);
      return false;
    }
    _moveTo(best.center, best.zoom);
    return true;
  }

  /// Vue d'ouverture : la dernière position connue au zoom [_kDefaultZoom],
  /// exactement le cadrage du bouton « recentrer ». Ce qu'on veut voir en
  /// arrivant sur un live, c'est où en est la sortie — pas la forme de tout le
  /// parcours, qui reste à un clic sur « cadrer le tracé ».
  void _applyInitialCamera() {
    if (!_mapReady || _initialCameraDone) return;
    if (latitude == null || longitude == null) return;
    if (_moveTo(LatLng(latitude!, longitude!), _kDefaultZoom)) {
      _initialCameraDone = true;
    } else {
      // Carte pas encore dimensionnée (timing web) : on réessaie au frame suivant.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyInitialCamera();
      });
    }
  }

  /// Déplace la caméra ; `false` si la carte n'est pas encore en état de bouger.
  bool _moveTo(LatLng center, double zoom) {
    try {
      mapController.move(center, zoom);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _recenter() {
    if (latitude == null || longitude == null) return;
    _moveTo(LatLng(latitude!, longitude!), _kDefaultZoom);
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

  /// Appel de l'RPC, avec une seconde tentative quand [allowRetry].
  ///
  /// `Failed to fetch` est un échec réseau du navigateur, sans code HTTP :
  /// micro-coupure Wi-Fi, onglet réveillé après veille, requête avortée…
  /// Ponctuel par nature, donc une retentative courte l'absorbe presque
  /// toujours. On ne l'active que sur le chargement initial : pour un poll de
  /// fond, l'échéance suivante joue déjà ce rôle.
  Future<dynamic> _fetchLiveSession({required bool allowRetry}) async {
    final supabase = Supabase.instance.client;
    final params = {'p_share_code': shareCode!};
    try {
      return await supabase.rpc('get_live_session', params: params);
    } catch (_) {
      if (!allowRetry) rethrow;
      await Future.delayed(const Duration(seconds: 2));
      return await supabase.rpc('get_live_session', params: params);
    }
  }

  Future<void> loadLastPosition({bool manual = false}) async {
    if (shareCode == null) {
      setState(() { errorMessage = 'missing_code'; isLoading = false; });
      return;
    }
    final isInitialLoad = tracePositions.isEmpty;
    if (!isLoading) setState(() => isRefreshing = true);
    try {
      final result = await _fetchLiveSession(allowRetry: isInitialLoad);
      if (!mounted) return;
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
      // Les waypoints vivent sur le téléphone et arrivent par
      // safety_sessions.ride_json['waypoints'], que l'app republie à chaque
      // modification pendant la sortie (pose, pause, reprise, note, photo).
      // Pendant le direct, ce ride_json ne contient QUE les waypoints — la
      // trace passe par safety_positions ; le payload complet (points, stats)
      // n'est écrit qu'au finish. D'où le garde-fou `_isFinished` partout où on
      // lit `points` ou les stats de ride_json.
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
      // Toujours recalculé, même quand ride_json fournit les totaux : c'est ce
      // parcours du tracé qui produit `_distanceMarks`, seule façon de situer un
      // point de passage dans la sortie (« au km 12,4 »). Le sauter laissait la
      // liste des points sans distance sur les sorties terminées.
      _computeStats(parsedPositions);
      // Ride terminé : les stats de ride_json font foi et écrasent les valeurs
      // recalculées (chrono exact de l'app, distance mesurée sur le tracé dense).
      if (newStatus == 'finished') {
        try {
          final rideJson = session['ride_json'] as Map<String, dynamic>?;
          final distM = rideJson?['distanceMeters'];
          final durS = rideJson?['durationSeconds'];
          if (distM != null && durS != null) {
            _totalDistanceMeters = (distM as num).toDouble();
            _rideDuration = Duration(seconds: (durS as num).toInt());
          }
        } catch (_) {}
      }
      _computeRideStats(parsedPositions);
      final latestPosition = parsedPositions.first;
      setState(() {
        tracePositions = parsedPositions;
        _checkpoints = parsedCheckpoints;
        latitude = (latestPosition['latitude'] as num).toDouble();
        longitude = (latestPosition['longitude'] as num).toDouble();
        lastUpdate = DateTime.tryParse(latestPosition['created_at']);
        _batteryLevel = _latestBatteryLevel(parsedPositions);
        // Un chargement qui aboutit efface l'erreur précédente : le polling
        // continue de tourner derrière l'écran d'erreur, c'est lui qui remet
        // l'affichage d'aplomb sans que l'utilisateur ait à taper « Réessayer ».
        errorMessage = null;
        errorDetails = null;
        _refreshFailed = false;
        isLoading = false;
        isRefreshing = false;
      });
      _stopPollingIfFinished();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_initialCameraDone) {
          _applyInitialCamera();
        } else {
          double z = 15;
          try {
            final current = mapController.camera.zoom;
            if (current.isFinite) z = current;
          } catch (_) {}
          _moveTo(LatLng(latitude!, longitude!), z);
        }
      });
      if (manual) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Position mise à jour'), behavior: SnackBarBehavior.floating, duration: Duration(seconds: 2)));
      }
    } catch (e) {
      if (!mounted) return;
      // On a déjà une carte, une trace et des stats à l'écran : un blip réseau
      // sur un poll de fond ne justifie pas de tout effacer. On garde
      // l'affichage, on teinte le bouton sync, et l'échéance suivante répare.
      // Seul un tap explicite mérite un retour immédiat.
      if (!isInitialLoad) {
        setState(() { _refreshFailed = true; isRefreshing = false; });
        if (manual) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Serveur injoignable — nouvelle tentative automatique'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ));
        }
        return;
      }
      setState(() { errorMessage = 'system_error'; errorDetails = e.toString(); isLoading = false; isRefreshing = false; });
    }
  }

  /// Menu contextuel de rafraîchissement, accolé au bouton sync du côté où il y
  /// a la place : à sa gauche quand les contrôles sont au bord droit (mobile), à
  /// sa droite quand ils sont dans le coin bas gauche (desktop). Il se déplie
  /// vers le haut si le bouton est dans la moitié basse de l'écran, sans quoi il
  /// sortirait par le bas.
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
    const gap = 8.0;
    const margin = 12.0;

    // Assez de place à gauche du bouton ? Sinon on ouvre à sa droite.
    final openOnLeft = btnPos.dx >= menuWidth + gap + margin;
    final double? right = openOnLeft ? overlaySize.width - btnPos.dx + gap : null;
    final double? left = openOnLeft ? null : btnPos.dx + btnBox.size.width + gap;

    // Bouton dans la moitié basse : le menu monte depuis son bord bas. Sinon il
    // descend depuis son bord haut.
    final anchorFromBottom = btnPos.dy > overlaySize.height / 2;
    final double? top = anchorFromBottom ? null : math.max(margin, btnPos.dy);
    final double? bottom = anchorFromBottom
        ? math.max(margin, overlaySize.height - btnPos.dy - btnBox.size.height)
        : null;

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
          left: left,
          right: right,
          top: top,
          bottom: bottom,
          width: menuWidth,
          child: TweenAnimationBuilder<double>(
            duration: const Duration(milliseconds: 130),
            curve: Curves.easeOut,
            tween: Tween(begin: 0, end: 1),
            builder: (_, t, child) => Opacity(
              opacity: t,
              child: Transform.scale(
                // L'agrandissement part du bouton, pas du vide.
                alignment: openOnLeft ? Alignment.centerRight : Alignment.centerLeft,
                scale: 0.96 + 0.04 * t,
                child: child,
              ),
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
          const SizedBox(height: 12),
          Container(height: 1, color: Colors.white12),
          const SizedBox(height: 10),
          // Recharge complète de l'app (et non des seules données) : la sortie de
          // secours quand la page semble figée sur une ancienne version.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _forcingUpdate ? null : () { _removeRefreshMenu(); _forceUpdate(); },
            child: Row(children: [
              _forcingUpdate
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF8A00)))
                  : const Icon(Icons.autorenew, color: Color(0xFFFF8A00), size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_forcingUpdate ? 'Actualisation…' : 'Forcer l\'actualisation',
                  style: const TextStyle(color: Color(0xFFFF8A00), fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
          const SizedBox(height: 4),
          const Text('Recharge l\'app depuis le serveur',
            style: TextStyle(color: Colors.white38, fontSize: 10.5)),
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
  /// Côté de la boîte des markers Départ / Arrivée. La pastille visible fait
  /// [_kEndpointPinSize] ; le reste de la boîte est une marge de clic, la
  /// pastille seule étant une cible trop fine à la souris.
  static const double _kEndpointMarkerBox = 44;
  static const double _kEndpointPinSize = 26;

  /// Pastille Départ / Arrivée posée sur la carte : cliquable comme celles des
  /// points de passage (elle ouvre les infos du point).
  Widget _endpointPin({
    required Color color,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        // Sans `opaque`, seul le glyphe de l'icône serait cliquable : un
        // Container décoré ne se teste pas lui-même, il défère à ses enfants.
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: Container(
            width: _kEndpointPinSize,
            height: _kEndpointPinSize,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 8)],
            ),
            child: Icon(icon, color: Colors.white, size: 16),
          ),
        ),
      ),
    );
  }

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
                // Toute la pastille cliquable, pas seulement le chiffre.
                behavior: HitTestBehavior.opaque,
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
    // Échelle : sous les contrôles carte en desktop. En mobile le bas de l'écran
    // est déjà pris par les cartes stats.
    final showScalebar = MediaQuery.sizeOf(context).width >= 900;
    return FlutterMap(
        key: ValueKey('map_$_mapStyleIndex'),
        mapController: mapController,
        options: MapOptions(
          initialCenter: _savedCenter ?? currentPosition,
          initialZoom: _savedZoom,
          onMapReady: () {
            _mapReady = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _applyInitialCamera();
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
                point: points.first,
                width: _kEndpointMarkerBox, height: _kEndpointMarkerBox,
                child: _endpointPin(
                  color: const Color(0xFFFF8A00),
                  icon: Icons.play_arrow,
                  onTap: () => _showEndpointInfo('start'),
                ),
              ),
            // Arrivée (pin damier) : uniquement sur un ride terminé. Tant que le
            // ride tourne, la dernière position n'est pas une arrivée — seul le
            // point rouge de position courante la marque.
            if (_isFinished && points.length > 1)
              Marker(
                point: points.last,
                width: _kEndpointMarkerBox, height: _kEndpointMarkerBox,
                child: _endpointPin(
                  color: const Color(0xFF6D28D9),
                  icon: Icons.sports_score_sharp,
                  onTap: () => _showEndpointInfo('end'),
                ),
              ),
            // Position courante (repère magenta pulsé) : uniquement pendant le
            // ride. Sur un ride terminé, la dernière position EST l'arrivée,
            // déjà marquée par le pin damier — le repère serait redondant.
            // #D946EF = couleur intermédiaire du dégradé Départ → Arrivée.
            // Flèche orientée quand ça avance, cible à l'arrêt : même repère que
            // la carte de l'app pendant la sortie (cf. _markerHeading).
            if (!_isFinished)
              Marker(
                point: currentPosition,
                width: _PulsingPositionMarker.size,
                height: _PulsingPositionMarker.size,
                child: _PulsingPositionMarker(headingDeg: _markerHeading),
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
          if (showScalebar)
            Scalebar(
              alignment: Alignment.bottomLeft,
              padding: const EdgeInsets.only(left: 24, bottom: 12),
              lineColor: Colors.white.withValues(alpha: 0.85),
              strokeWidth: 2,
              lineHeight: 6,
              textStyle: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 12,
                fontWeight: FontWeight.w600,
                shadows: const [Shadow(color: Colors.black87, blurRadius: 4)],
              ),
            ),
        ],
    );
  }

  /// En-tête desktop : le titre et la version, rien d'autre — tout l'état de la
  /// sortie vit dans le volet de droite. Le mobile a le sien (cf.
  /// _buildMobileTopOverlay).
  Widget _buildTopOverlay(double topPadding) {
    return Stack(children: [
      // Le voile n'est que décoratif : sans IgnorePointer il avalerait les clics
      // sur toute la bande haute de la carte (un BoxDecoration se teste
      // lui-même au pointeur) — la pastille Départ y tombe très souvent.
      Positioned.fill(child: IgnorePointer(child: _headerScrim())),
      Padding(
        padding: EdgeInsets.fromLTRB(24, topPadding + 18, 24, 40),
        child: Row(children: [
        Column(
          // Pastille de version chevauchant le bas de « Live », comme une
          // signature posée sur le titre. Le décalage est peint, pas mis en
          // page : le bloc garde une hauteur stable et le titre ne bouge pas
          // quand les détails de version se déplient.
          key: _desktopHeaderKey,
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Sunday Tracker Live',
                style: GoogleFonts.robotoCondensed(
                  color: Colors.white,
                  fontSize: 40,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                  shadows: [const Shadow(color: Colors.black87, blurRadius: 10)],
                )),
            Transform.translate(
              offset: const Offset(8, -10),
              child: _buildVersionBadge(),
            ),
            if (_versionExpanded)
              Transform.translate(
                offset: const Offset(0, -6),
                child: _buildVersionDetails(),
              ),
          ],
        ),
          const Spacer(),
        ]),
      ),
    ]);
  }

  /// Voile sombre du haut de l'écran : c'est lui qui rend le titre lisible
  /// quelles que soient les tuiles dessous. Purement décoratif — à poser dans un
  /// IgnorePointer, sans quoi il capte les clics de la carte.
  Widget _headerScrim({double opacity = 0.55}) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: opacity), Colors.transparent],
        ),
      ),
    );
  }

  /// Pastille batterie du téléphone : un live qui s'arrête à 4 % s'interprète
  /// autrement qu'un live qui s'arrête à 80 %. [large] est la version desktop,
  /// posée dans la carte d'en-tête à côté du signal — d'où le vert franc au lieu
  /// du blanc effacé quand la charge est bonne.
  Widget _buildBatteryChip(int level, {bool large = false}) {
    final color = level <= 10
        ? const Color(0xFFEF4444)
        : level <= 20
            ? const Color(0xFFFF8A00)
            : large
                ? const Color(0xFF4ADE80)
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
        Icon(icon, color: color, size: large ? 19 : 12),
        SizedBox(width: large ? 7 : 3),
        Text('$level %',
          style: TextStyle(color: color, fontSize: large ? 15 : 10, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  /// Contrôles carte flottants — même look que l'app mobile (ride en cours /
  /// détail du ride) : un bloc sombre flouté, boutons collés. Rafraîchir (avec
  /// son menu : intervalle auto, mise à jour forcée), cadrer le tracé, cycler
  /// les fonds de carte (Plan → Satellite → Topo, icône du style courant),
  /// recentrer. Pas de zoom au bouton : molette et pincement s'en chargent.
  ///
  /// [compact] : version mobile, plus étroite et plus transparente pour masquer
  /// le moins de tracé possible.
  Widget _buildMapControls({bool compact = false}) {
    final side = compact ? 38.0 : 46.0;
    final iconSize = compact ? 18.0 : 22.0;
    final radius = compact ? 13.0 : 16.0;

    Widget btn({Key? key, required Widget child, required VoidCallback onTap}) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: SizedBox(key: key, width: side, height: side, child: Center(child: child)),
        ),
      );
    }

    Widget separator() => Container(
      height: 1,
      margin: EdgeInsets.symmetric(horizontal: compact ? 7 : 0),
      color: Colors.white.withValues(alpha: 0.09),
    );

    Widget block(List<Widget> children) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            width: side,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: compact ? 0.52 : 0.70),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: compact ? 0.3 : 0.4),
                  blurRadius: compact ? 12 : 18,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      );
    }

    // Une seule des deux variantes est construite à la fois (mobile OU
    // desktop) : la clé du bouton sync peut donc être portée par les deux.
    final sync = btn(
      key: _refreshBtnKey,
      onTap: _toggleRefreshMenu,
      child: isRefreshing
          ? SizedBox(width: iconSize - 2, height: iconSize - 2, child: const CircularProgressIndicator(strokeWidth: 2, color: Colors.orange))
          // Dernier poll en échec : la trace affichée date un peu, on le dit
          // sans masquer la carte pour autant.
          : Icon(_refreshFailed ? Icons.sync_problem : Icons.sync,
              color: _refreshFailed ? const Color(0xFFF87171) : Colors.white, size: iconSize),
    );

    return block([
      // Ride terminé : plus rien à rafraîchir, le bouton sync disparaît.
      if (!_isFinished) ...[sync, separator()],
      btn(
        onTap: () { final pts = tracePoints; if (pts.isNotEmpty) _fitBounds(pts); },
        child: Icon(Icons.fit_screen, color: Colors.white, size: iconSize),
      ),
      separator(),
      // Cycle de fond de carte — icône du style courant
      btn(
        onTap: () => _changeMapStyle((_mapStyleIndex + 1) % kMapStyles.length),
        child: Icon(kMapStyles[_mapStyleIndex]['icon'] as IconData, color: Colors.white, size: iconSize),
      ),
      separator(),
      btn(onTap: _recenter, child: Icon(Icons.my_location, color: Colors.white, size: iconSize)),
    ]);
  }

  /// Date complète : « 27 juil. 2026 ». Le volet desktop est assez large pour
  /// l'année, contrairement aux blocs flottants mobiles.
  String _formatLongDateFr(DateTime? dt) {
    if (dt == null) return '--';
    const months = ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin',
                    'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'];
    final l = dt.toLocal();
    return '${l.day} ${months[l.month - 1]} ${l.year}';
  }

  /// Heure à la seconde : sur un direct, la seconde dit si le point vient
  /// d'arriver.
  String _formatHms(DateTime? dt) {
    if (dt == null) return '--:--:--';
    final l = dt.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}:${l.second.toString().padLeft(2, '0')}';
  }

  // ── Interface mobile : la carte d'abord ───────────────────────────────────
  // Plus de grand panneau noir en bas : uniquement des blocs flottants posés sur
  // la carte (bandeau d'état sous le titre, quatre cartes stats et deux boutons
  // au-dessus du bord bas). Tout le détail part dans la feuille « Voir les
  // détails » et les contrôles carte dans le menu « … » de l'en-tête.

  /// Bloc flottant translucide : fond sombre semi-transparent, angles arrondis,
  /// ombre discrète. [blur] n'est activé que pour le bandeau d'état (un
  /// BackdropFilter par carte coûterait cher sur mobile web).
  Widget _glassBox({
    required Widget child,
    required EdgeInsets padding,
    double radius = 14,
    double opacity = 0.62,
    bool blur = false,
  }) {
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: opacity),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.32), blurRadius: 14, offset: const Offset(0, 4)),
        ],
      ),
      child: child,
    );
    if (!blur) return box;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: box,
      ),
    );
  }

  /// Pastille de version, au coin haut droit de l'en-tête mobile. Un tap ouvre les détails
  /// (build complet + forçage de mise à jour) : voir [_showVersionSheet].
  Widget _buildMobileVersionChip() {
    final version = appVersion.split('+').first.trim();
    if (version.isEmpty) return const SizedBox.shrink();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _showVersionSheet,
      // La zone tactile déborde un peu de la pastille, trop petite au doigt.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Text(version,
            style: const TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  /// En-tête mobile : le titre à gauche, la version au coin haut droit, puis la
  /// carte d'état. Même partition que le desktop, aux tailles près.
  Widget _buildMobileTopOverlay(double topPadding) {
    return Stack(children: [
      // Cf. _headerScrim : décoratif, donc neutralisé au pointeur — sans quoi il
      // avalerait les taps sur les markers de la bande haute.
      Positioned.fill(child: IgnorePointer(child: _headerScrim())),
      Padding(
        padding: EdgeInsets.fromLTRB(14, topPadding + 10, 14, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          // Titre à gauche, version au coin haut droit : la pastille ne mange ni
          // le titre ni une ligne du bandeau d'état, et le coin droit était de
          // toute façon vide. L'Expanded pousse la pastille contre la marge.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text('Sunday Tracker Live',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.robotoCondensed(
                    color: Colors.white, fontSize: 27, height: 1, fontWeight: FontWeight.w700,
                    shadows: [const Shadow(color: Colors.black87, blurRadius: 8)])),
              ),
              const SizedBox(width: 8),
              _buildMobileVersionChip(),
            ],
          ),
          const SizedBox(height: 4),
          _buildMobilePositionCard(),
        ]),
      ),
    ]);
  }

  /// Carte d'état mobile : heure du dernier point, statut, batterie et signal,
  /// puis l'ouverture dans une app de navigation. Reprise de l'aperçu desktop,
  /// en plus dense.
  Widget _buildMobilePositionCard() {
    final accent = _isFinished ? const Color(0xFF8B5CF6) : const Color(0xFFD946EF);
    final unknown = rideStatus == 'unknown' || lastUpdate == null;

    final title = Row(children: [
      Icon(_isFinished ? Icons.sports_score_sharp : Icons.place, color: accent, size: 20),
      const SizedBox(width: 9),
      Expanded(
        child: Text(
          unknown
              ? 'Position inconnue'
              : '${_isFinished ? 'Arrivée' : 'Dernière position connue'} à ${_formatHms(lastUpdate)}',
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w600)),
      ),
    ]);
    final indicators = <Widget>[
      _buildStatusPill(mobile: true),
      if (_batteryLevel != null) _buildBatteryChip(_batteryLevel!, large: true),
      if (!_isFinished) _buildSignalIndicator(large: true),
    ];

    return _glassBox(
      padding: EdgeInsets.zero,
      radius: 18,
      opacity: 0.74,
      blur: true,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
          // L'heure du dernier point est l'information la plus utile de l'écran :
          // elle garde sa ligne entière. Les indicateurs (statut, batterie,
          // signal) passent toujours dessous, quitte à prendre deux lignes —
          // les partager avec le titre le rognait à « Positi… » dès 380 px.
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            title,
            const SizedBox(height: 9),
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: indicators),
          ]),
        ),
        Container(height: 1, color: Colors.white.withValues(alpha: 0.09)),
        _buildPanelActionRow(
          icon: Icons.map_outlined,
          label: 'Ouvrir la position',
          onTap: () => _showNavigationSheet(context),
        ),
      ]),
    );
  }

  /// Ligne d'action pleine largeur d'un panneau : icône, libellé, chevron.
  Widget _buildPanelActionRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
        child: Row(children: [
          Icon(icon, color: Colors.white70, size: 18),
          const SizedBox(width: 11),
          Expanded(
            child: Text(label,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          const Icon(Icons.chevron_right, color: Colors.white38, size: 20),
        ]),
      ),
    );
  }

  /// Bas de l'écran mobile : les contrôles carte, puis le panneau à onglets —
  /// même contenu que le volet desktop (aperçu, points de passage, stats), posé
  /// à plat en bas de l'écran.
  Widget _buildMobileBottomOverlay(double bottomPadding) {
    final maxPanelHeight = MediaQuery.sizeOf(context).height * 0.44;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12, 10 + bottomPadding),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        _buildMapControls(compact: true),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxPanelHeight),
          child: _glassBox(
            padding: EdgeInsets.zero,
            radius: 20,
            opacity: 0.80,
            blur: true,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _buildMobileTabs(),
              Container(height: 1, color: Colors.white.withValues(alpha: 0.07)),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
                  child: switch (_mobilePanel) {
                    _SidePanel.overview => _buildMobileOverview(),
                    _SidePanel.waypoints => _buildMobileWaypointList(),
                    _SidePanel.stats => RideStatsSection(stats: _stats, live: !_isFinished),
                  },
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  /// Onglet mobile réellement affichable : « + d'infos » disparaît tant qu'il
  /// n'y a pas assez de points GPS pour calculer des statistiques.
  _SidePanel get _mobilePanel =>
      (_openPanel == _SidePanel.stats && _stats.isEmpty) ? _SidePanel.overview : _openPanel;

  Widget _buildMobileTabs() {
    final tabs = <(_SidePanel, String)>[
      (_SidePanel.overview, 'Aperçu'),
      (_SidePanel.waypoints, 'Points de passage'),
      if (!_stats.isEmpty) (_SidePanel.stats, "+ d'infos"),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final (panel, label) in tabs)
            _buildPanelTab(label: label, panel: panel, active: panel == _mobilePanel, compact: true),
        ],
      ),
    );
  }

  /// Onglet « Aperçu » mobile : les mesures de la sortie en grille 2 × 2.
  ///
  /// Première ligne, en gros : ce qu'on vient chercher d'abord sur un direct —
  /// combien de kilomètres, depuis combien de temps. Seconde ligne, en plus
  /// petit : le contexte de ces deux chiffres — depuis quelle heure, et quelle
  /// part de ce temps a réellement été roulée.
  ///
  /// L'heure du dernier point n'y figure pas : la carte d'état, juste au-dessus,
  /// l'annonce déjà (« Position actualisée à … »).
  Widget _buildMobileOverview() {
    const blue = Color(0xFF38BDF8);
    final elapsed = _elapsedSinceStart;

    // IntrinsicHeight : les deux cartes d'une ligne font la même hauteur, même
    // si l'une des valeurs a dû rétrécir.
    Widget row(List<Widget> cards) => IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: cards[0]),
        const SizedBox(width: 10),
        Expanded(child: cards[1]),
      ]),
    );

    return Column(mainAxisSize: MainAxisSize.min, children: [
      row([
        _buildOverviewCard(
          icon: Icons.place,
          iconColor: blue,
          label: 'Distance',
          value: _formatDistance(_totalDistanceMeters),
          valueColor: blue,
          hero: true,
        ),
        _buildOverviewCard(
          icon: Icons.timer_outlined,
          iconColor: blue,
          label: 'Durée totale',
          // Sortie sans heure de départ exploitable : la carte garde sa place
          // dans la grille plutôt que de la laisser béante.
          value: elapsed == null ? '--:--:--' : _formatDuration(elapsed),
          valueColor: Colors.white,
          hero: true,
        ),
      ]),
      const SizedBox(height: 10),
      row([
        _buildOverviewCard(
          icon: Icons.schedule,
          iconColor: const Color(0xFFFF8A00),
          label: 'Départ',
          value: _formatHms(rideStartTime),
          valueColor: const Color(0xFFFF8A00),
        ),
        _buildOverviewCard(
          icon: Icons.monitor_heart_outlined,
          iconColor: const Color(0xFF4ADE80),
          label: 'Mouvement',
          value: _formatDuration(_rideDuration),
          valueColor: const Color(0xFF4ADE80),
        ),
      ]),
    ]);
  }

  /// Carte d'une mesure de l'aperçu mobile : icône dans la couleur de la mesure,
  /// libellé discret et valeur en gras.
  ///
  /// [hero] intervertit l'ordre de lecture — valeur d'abord, en plus gros, puis
  /// le libellé dessous — pour les deux mesures de la première ligne.
  Widget _buildOverviewCard({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
    required Color valueColor,
    bool hero = false,
  }) {
    final labelText = Text(label,
      maxLines: 1, overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w500));
    // La valeur rétrécit plutôt que de déborder sur la carte voisine.
    final valueText = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(value,
        style: TextStyle(
          color: valueColor, fontSize: hero ? 23 : 17, height: 1.1,
          fontWeight: FontWeight.w700, letterSpacing: -0.3)),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(13, 12, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // L'icône se cale sur la première ligne de texte et non au milieu de la
        // carte : cette première ligne n'est pas la même d'une ligne à l'autre
        // de la grille (la valeur en haut, le libellé en bas).
        Padding(
          padding: EdgeInsets.only(top: hero ? 3 : 1),
          child: Icon(icon, color: iconColor, size: hero ? 20 : 15),
        ),
        SizedBox(width: hero ? 9 : 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
            children: hero
              ? [valueText, const SizedBox(height: 3), labelText]
              : [labelText, const SizedBox(height: 3), valueText]),
        ),
      ]),
    );
  }

  /// Onglet « Points de passage » mobile : une liste compacte, un tap ouvre la
  /// fiche du point. Les deux bouts de la trace y figurent aussi, comme dans le
  /// volet desktop.
  Widget _buildMobileWaypointList() {
    if (tracePositions.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Text('Aucun point disponible',
          style: TextStyle(color: Colors.white38, fontSize: 13)),
      );
    }
    // Les lignes se construisent en différé : chacune doit savoir si elle ferme
    // la chronologie (le fil vertical s'arrête au dernier point), ce qu'on ne
    // sait qu'une fois la liste complète.
    final rows = <Widget Function(bool isLast)>[];

    rows.add((isLast) => _buildMobileWaypointRow(
      color: const Color(0xFFFF8A00),
      badge: const Icon(Icons.play_arrow, color: Colors.white, size: 15),
      label: 'Départ',
      time: _formatHms(rideStartTime),
      distance: null,
      isLast: isLast,
      onTap: () => _showEndpointInfo('start'),
    ));

    for (final (i, cp) in _checkpoints.indexed) {
      final kind = waypointKindOf(cp);
      final dt = DateTime.tryParse(cp['created_at'] ?? '')?.toLocal();
      final comment = (cp['comment'] as String?)?.trim() ?? '';
      rows.add((isLast) => _buildMobileWaypointRow(
        color: kind.color,
        // Numéro centré, plus l'étincelle quand le point a été posé par l'app :
        // même vocabulaire que les pins de carte et le volet desktop
        // (cf. waypointBadgeContent). 24 = diamètre intérieur de la pastille.
        badge: waypointBadgeContent(
          kind: kind, size: 24, color: Colors.white,
          child: Text('${i + 1}',
            style: TextStyle(
              color: Colors.white, fontSize: i >= 9 ? 12 : 13,
              fontWeight: FontWeight.w800, height: 1)),
        ),
        // Le nom du point suffit : son numéro est déjà dans la pastille, et sa
        // nature (posé au doigt ou détecté par l'app) n'apprend rien au lecteur
        // du live — d'où la disparition des puces « auto ».
        label: comment.isNotEmpty ? comment : (kind.isPause ? 'Pause' : 'Point de passage'),
        time: _formatHms(dt),
        distance: _distanceAtTime(dt),
        isLast: isLast,
        onTap: () => _showCheckpointInfo(cp, i + 1),
      ));
    }

    if (tracePositions.length > 1 || _isFinished) {
      rows.add((isLast) => _buildMobileWaypointRow(
        color: _isFinished ? const Color(0xFF6D28D9) : const Color(0xFFD946EF),
        badge: Icon(_isFinished ? Icons.sports_score_sharp : Icons.my_location,
          color: Colors.white, size: 15),
        label: _isFinished ? 'Arrivée' : 'Dernière position',
        time: _formatHms(lastUpdate),
        // Le dernier point ferme le tracé : sa distance est le total de la
        // sortie, pas une valeur interpolée.
        distance: _totalDistanceMeters > 0 ? _totalDistanceMeters : null,
        isLast: isLast,
        onTap: () => _showEndpointInfo('end'),
      ));
    }

    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < rows.length; i++) ...[
        if (i > 0) Container(height: 1, color: Colors.white.withValues(alpha: 0.06)),
        rows[i](i == rows.length - 1),
      ],
    ]);
  }

  /// Une ligne de l'onglet mobile : pastille reliée à la suivante par le fil de
  /// la chronologie, nom du point à gauche, heure et distance depuis le départ
  /// alignées à droite.
  Widget _buildMobileWaypointRow({
    required Color color,
    required Widget badge,
    required String label,
    required String time,
    required double? distance,
    required bool isLast,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: 30,
            child: Column(children: [
              Container(
                width: 28, height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 2),
                ),
                child: badge,
              ),
              // Le fil ne descend pas sous le dernier point : la chronologie
              // s'arrête là, elle ne pointe pas dans le vide.
              if (!isLast)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Container(width: 2, color: Colors.white12),
                  ),
                ),
            ]),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 4, 0, 14),
              child: Text(label,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 10),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 2, 0, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              Text(time,
                style: const TextStyle(color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w700)),
              if (distance != null) ...[
                const SizedBox(height: 2),
                Text(_formatDistanceShort(distance),
                  style: const TextStyle(color: Colors.white38, fontSize: 12.5, fontWeight: FontWeight.w500)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }

  /// Numéro de build lisible : `2026072603` → `20260726.03`.
  String get _formattedBuild {
    final parts = appVersion.split('+');
    final raw = parts.length > 1 ? parts[1].split(' ').first : '';
    return raw.length == 10 ? '${raw.substring(0, 8)}.${raw.substring(8)}' : raw;
  }

  /// Détails de version, ouverts au tap sur la pastille de l'en-tête mobile :
  /// build complet et mise à jour forcée. Cette dernière doit rester atteignable
  /// même quand le bouton sync disparaît (ride terminé) ou que l'app est figée
  /// sur une ancienne version — d'où sa présence ici, et non dans la barre de
  /// carte. Les détails du ride ont déjà leur bouton en bas d'écran.
  void _showVersionSheet() {
    final build = _formattedBuild;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF18181B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(
              child: Container(
                width: 48, height: 4,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(999)),
              ),
            ),
            const SizedBox(height: 18),
            Text(appVersion.split('+').first.trim(),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
            if (build.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('build $build',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
            const SizedBox(height: 18),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                Navigator.pop(sheetCtx);
                _forceUpdate();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(10)),
                child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.autorenew, color: Color(0xFFFF8A00), size: 18),
                  SizedBox(width: 8),
                  Text('Forcer l\'actualisation de la page',
                    style: TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
            const SizedBox(height: 10),
            const Text('À utiliser si l\'app semble bloquée sur une ancienne version',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white30, fontSize: 11)),
          ]),
        ),
      ),
    );
  }

  bool _forcingUpdate = false;

  /// Paramètre de cache-busting ajouté à l'URL par [_forceUpdate], puis effacé
  /// de la barre d'adresse au démarrage pour que le lien reste partageable.
  static const _cacheBustParam = 'fr';

  /// Vide le service worker + tous les caches puis recharge la page.
  /// Équivaut à un "hard refresh" mais déclenché par l'utilisateur en un tap,
  /// ce qui est bien plus simple à expliquer (et faisable sur mobile/tablette).
  ///
  /// `location.reload()` seul ne suffit pas toujours : Safari iOS notamment
  /// resert volontiers l'ancien document depuis son cache mémoire. On recharge
  /// donc vers une URL portant un paramètre unique — impossible à servir depuis
  /// le cache — via `replace()` pour ne pas empiler d'entrée d'historique.
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
    // Nouvelle URL = URL courante + jeton unique, en conservant le code de ride
    // et tous les autres paramètres.
    final uri = Uri.parse(html.window.location.href);
    final params = Map<String, String>.from(uri.queryParameters)
      ..[_cacheBustParam] = DateTime.now().millisecondsSinceEpoch.toString();
    html.window.location.replace(uri.replace(queryParameters: params).toString());
  }

  /// Retire le jeton de cache-busting de la barre d'adresse (sans recharger) :
  /// l'utilisateur qui copie le lien après une mise à jour forcée partage une
  /// URL propre.
  void _stripCacheBustParam() {
    try {
      final uri = Uri.parse(html.window.location.href);
      if (!uri.queryParameters.containsKey(_cacheBustParam)) return;
      final params = Map<String, String>.from(uri.queryParameters)
        ..remove(_cacheBustParam);
      final cleaned = uri.replace(queryParameters: params.isEmpty ? null : params);
      html.window.history.replaceState(null, '', cleaned.toString());
    } catch (_) {}
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
  /// Tap sur la pastille Départ ou Arrivée de la carte : même comportement que
  /// pour un point de passage — le volet desktop surligne la ligne
  /// correspondante de la timeline, le mobile ouvre une feuille de détail.
  /// [which] vaut 'start' ou 'end'.
  void _showEndpointInfo(String which) {
    final isMobileLayout = MediaQuery.sizeOf(context).width < 900;
    if (isMobileLayout) {
      showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF18181B),
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
              _buildEndpointDetail(which),
            ]),
          ),
        ),
      );
      return;
    }
    setState(() {
      _highlightedCheckpoint = null;
      _highlightedEndpoint = which;
      _openPanel = _SidePanel.waypoints;
      _panelCollapsed = false;
    });
    _scrollToHighlight();
  }

  /// Détail d'un bout de trace, pour la feuille mobile : libellé, date et heure
  /// à la seconde, coordonnées.
  Widget _buildEndpointDetail(String which) {
    final isStart = which == 'start';
    final dt = isStart ? rideStartTime : lastUpdate;
    final color = isStart
        ? const Color(0xFFFF8A00)
        : _isFinished ? const Color(0xFF6D28D9) : const Color(0xFFD946EF);
    final icon = isStart
        ? Icons.play_arrow
        : _isFinished ? Icons.sports_score_sharp : Icons.my_location;
    final label = isStart ? 'Départ' : (_isFinished ? 'Arrivée' : 'Dernière position');
    // Le départ est le premier point de la trace, l'autre bout le dernier.
    final points = tracePoints;
    final at = points.isEmpty ? null : (isStart ? points.first : points.last);

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          width: 26, height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white, size: 15),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text('$label · ${_formatHms(dt)}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
        ),
      ]),
      const SizedBox(height: 12),
      Text(_formatLongDateFr(dt), style: const TextStyle(fontSize: 15, color: Colors.white70, height: 1.4)),
      if (at != null) ...[
        const SizedBox(height: 16),
        Text('Lat ${at.latitude.toStringAsFixed(6)}  ·  Long ${at.longitude.toStringAsFixed(6)}',
          style: const TextStyle(fontSize: 12, color: Colors.white38)),
      ],
    ]);
  }

  /// Amène la ligne surlignée dans la partie visible du volet, une fois celui-ci
  /// en place.
  void _scrollToHighlight() {
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
        _highlightedEndpoint = null;
        _openPanel = _SidePanel.waypoints;
        _panelCollapsed = false;
      });
      _scrollToHighlight();
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
    double? distance,
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
    final timeStr = _formatHms(time);

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
                  // Libellé (+ puce) dans un Expanded, l'heure derrière : c'est
                  // ce qui cale toutes les heures sur la même colonne, quelle
                  // que soit la longueur du libellé. Un Spacer partagerait
                  // l'espace libre avec le libellé et décalerait l'heure d'une
                  // ligne à l'autre.
                  Row(children: [
                    Expanded(
                      child: Text(label,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 10),
                    Text(timeStr, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    if (distance != null) ...[
                      const SizedBox(width: 8),
                      Text(_formatDistanceShort(distance),
                        style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    ],
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

    final startHighlighted = _highlightedEndpoint == 'start';
    widgets.add(KeyedSubtree(
      key: startHighlighted ? _highlightKey : null,
      child: _buildTimelinePoint(
        type: 'start', label: 'Départ', time: departureTime,
        isLast: ++idx == total,
        highlighted: startHighlighted,
      ),
    ));

    for (final (i, cp) in _checkpoints.indexed) {
      final dt = DateTime.tryParse(cp['created_at'] ?? '')?.toLocal();
      final isHighlighted = _highlightedCheckpoint == i;
      final kind = waypointKindOf(cp);
      widgets.add(KeyedSubtree(
        key: isHighlighted ? _highlightKey : null,
        child: _buildTimelinePoint(
          // Pause au bouton ou pause détectée par l'app : c'est une pause, point.
          // La distinction ne dit rien à qui suit la sortie.
          type: 'checkpoint', label: kind.isPause ? 'Pause' : kind.label,
          time: dt, kind: kind,
          comment: cp['comment'] as String?,
          photoUrls: (cp['photo_urls'] as List?)?.cast<String>() ?? const [],
          number: i + 1,
          distance: _distanceAtTime(dt),
          isLast: ++idx == total,
          highlighted: isHighlighted,
        ),
      ));
    }

    if (hasEndPoint) {
      final endHighlighted = _highlightedEndpoint == 'end';
      widgets.add(KeyedSubtree(
        key: endHighlighted ? _highlightKey : null,
        child: _buildTimelinePoint(
          type: _isFinished ? 'end' : 'current',
          label: _isFinished ? 'Arrivée' : 'Dernière position',
          time: latestTime,
          distance: _totalDistanceMeters > 0 ? _totalDistanceMeters : null,
          isLast: true,
          highlighted: endHighlighted,
        ),
      ));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: widgets);
  }

  /// Largeur du volet desktop, bords compris.
  static const double _kPanelWidth = 430;

  /// Volet flottant du bord droit : trois onglets (aperçu de la sortie, points
  /// de passage, statistiques) dans une seule carte, qui s'étire jusqu'à la
  /// hauteur disponible puis fait défiler son contenu. L'onglet « + d'infos »
  /// disparaît tant qu'il n'y a pas assez de points GPS pour calculer quoi que
  /// ce soit.
  Widget _buildDesktopPanel() {
    final tabs = <(_SidePanel, String)>[
      (_SidePanel.overview, 'Aperçu'),
      (_SidePanel.waypoints, 'Points de passage'),
      if (!_stats.isEmpty) (_SidePanel.stats, '+ d\'infos'),
    ];
    // Le tracé peut perdre ses stats entre deux rafraîchissements : on ne laisse
    // pas l'onglet actif pointer dans le vide.
    final active = tabs.any((t) => t.$1 == _openPanel) ? _openPanel : _SidePanel.overview;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0E1013).withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 30, offset: const Offset(0, 12)),
            ],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 10, 0),
              child: Row(children: [
                for (final (panel, label) in tabs)
                  _buildPanelTab(label: label, panel: panel, active: panel == active),
                const Spacer(),
                _buildPanelCollapseButton(),
              ]),
            ),
            Container(height: 1, color: Colors.white.withValues(alpha: 0.07)),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                child: switch (active) {
                  _SidePanel.overview => _buildOverviewTab(),
                  _SidePanel.waypoints => _buildWaypointTimeline(),
                  _SidePanel.stats => RideStatsSection(stats: _stats, live: !_isFinished),
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// Un onglet du volet : libellé souligné de violet quand il est actif.
  /// [compact] : version mobile, où les trois onglets se partagent la largeur
  /// de l'écran et se placent donc eux-mêmes (pas de marge à droite).
  Widget _buildPanelTab({
    required String label,
    required _SidePanel panel,
    required bool active,
    bool compact = false,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() {
          _highlightedCheckpoint = null;
          _highlightedEndpoint = null;
          _openPanel = panel;
        }),
        child: Padding(
          padding: EdgeInsets.only(right: compact ? 0 : 22),
          // IntrinsicWidth : le trait actif prend exactement la largeur du
          // libellé, que la Row ne contraint pas.
          child: IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: active ? Colors.white : Colors.white54,
                        fontSize: compact ? 13 : 14.5,
                        // Graisse constante : une graisse variable changerait la
                        // largeur du libellé et ferait danser les onglets.
                        fontWeight: FontWeight.w600,
                      )),
                ),
                Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: active ? const Color(0xFF8B5CF6) : Colors.transparent,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Bouton de repli du volet, à droite des onglets.
  Widget _buildPanelCollapseButton() {
    return Tooltip(
      message: 'Replier le volet',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => setState(() => _panelCollapsed = true),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            width: 30, height: 30,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(Icons.chevron_right, color: Colors.white60, size: 18),
          ),
        ),
      ),
    );
  }

  /// Poignée verticale du bord droit, seule trace du volet quand il est replié.
  Widget _buildPanelHandle() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _panelCollapsed = false),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 9),
          decoration: BoxDecoration(
            color: const Color(0xFF0E1013).withValues(alpha: 0.92),
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 16)],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.chevron_left, color: Colors.white70, size: 18),
            const SizedBox(height: 10),
            RotatedBox(
              quarterTurns: 3,
              child: Text('Détails',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 0.2,
                  )),
            ),
            const SizedBox(height: 8),
            // Le libellé pivoté se lit de bas en haut : l'icône est donc placée
            // en bas de la colonne pour précéder le mot « Détails ».
            const Icon(Icons.info_outline, color: Colors.white70, size: 18),
          ]),
        ),
      ),
    );
  }

  /// Onglet « Aperçu » : l'état du direct (heure du dernier point, statut,
  /// batterie, signal), l'ouverture dans une app de navigation, puis le résumé
  /// chiffré de la sortie.
  Widget _buildOverviewTab() {
    const violet = Color(0xFF8B5CF6);
    final unknown = rideStatus == 'unknown' || lastUpdate == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          unknown
              ? 'Position inconnue'
              : '${_isFinished ? 'Arrivée' : 'Position actualisée'} à ${_formatHms(lastUpdate)}',
          style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 14),
        _buildStatusPill(large: true),
        if (_batteryLevel != null) ...[
          const SizedBox(height: 14),
          _buildBatteryChip(_batteryLevel!, large: true),
        ],
        if (!_isFinished) ...[
          const SizedBox(height: 10),
          _buildSignalIndicator(large: true),
        ],
        const SizedBox(height: 18),
        _DesktopFlatButton(
          icon: Icons.map_outlined,
          label: 'Ouvrir la position',
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          onTap: () => _showNavigationSheet(context),
        ),
        const SizedBox(height: 18),
        Container(height: 1, color: Colors.white.withValues(alpha: 0.08)),
        const SizedBox(height: 6),
        _buildOverviewRow(
          icon: Icons.play_arrow,
          color: const Color(0xFFFF8A00),
          label: 'Départ',
          sub: _formatLongDateFr(rideStartTime),
          value: _formatHms(rideStartTime),
        ),
        // Pas de ligne pour le dernier point : son heure est déjà en tête de
        // l'onglet (« Position actualisée à … »), la répéter ici n'apprend rien.
        _buildOverviewRow(
          icon: Icons.add_road,
          color: violet,
          label: 'Distance',
          value: _formatDistance(_totalDistanceMeters),
        ),
        // Mêmes libellés et icônes que l'app mobile : chronomètre vert pour le
        // temps de roulage, horloge blanche pour le temps écoulé.
        _buildOverviewRow(
          icon: Icons.timer_outlined,
          color: const Color(0xFF4ADE80),
          label: 'Durée mouv.',
          value: _formatDuration(_rideDuration),
        ),
        if (_elapsedSinceStart != null)
          _buildOverviewRow(
            icon: Icons.schedule,
            color: Colors.white,
            label: 'Durée totale',
            value: _formatDuration(_elapsedSinceStart!),
          ),
      ],
    );
  }

  /// Une ligne du résumé : pastille d'icône, libellé (+ date au besoin), valeur
  /// calée à droite dans la couleur de la ligne.
  Widget _buildOverviewRow({
    required IconData icon,
    required Color color,
    required String label,
    String? sub,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w500)),
              if (sub != null) ...[
                const SizedBox(height: 2),
                Text(sub,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
              ],
            ],
          ),
        ),
        const SizedBox(width: 10),
        Text(value,
            style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: -0.2)),
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
              child: isMobileLayout
                  ? _buildMobileTopOverlay(topPadding)
                  : _buildTopOverlay(topPadding),
            ),
          ),
          // Desktop : contrôles carte en bas à gauche, coin resté libre depuis
          // que tout l'état de la sortie est dans le volet. En mobile ils sont
          // portés par le bas d'écran, juste au-dessus du panneau.
          if (!isMobileLayout)
            Positioned(
              left: 22,
              bottom: 46 + bottomPadding,
              child: KeyedSubtree(key: _desktopControlsKey, child: _buildMapControls()),
            ),
          if (isMobileLayout)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: KeyedSubtree(
                key: _bottomOverlayKey,
                child: _buildMobileBottomOverlay(bottomPadding),
              ),
            ),
          // Desktop : volet flottant à droite, et sa poignée quand il est replié.
          if (!isMobileLayout) ...[
            AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeInOut,
              top: topPadding + 84,
              bottom: 28 + bottomPadding,
              right: _panelCollapsed ? -(_kPanelWidth + 30) : 24,
              width: _kPanelWidth,
              // Le volet s'arrête à la hauteur de son contenu, centré dans la
              // place disponible, et ne défile qu'au-delà.
              child: Center(
                child: KeyedSubtree(key: _desktopPanelKey, child: _buildDesktopPanel()),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeInOut,
              top: topPadding + 84,
              right: _panelCollapsed ? 0 : -80,
              child: _buildPanelHandle(),
            ),
          ],
        ],
      ),
    );
  }
}
