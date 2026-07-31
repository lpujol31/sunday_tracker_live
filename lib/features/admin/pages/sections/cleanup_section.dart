// lib/features/admin/pages/sections/cleanup_section.dart
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart'; // DateFormat utilisé dans _exportCsv et _fmtDate
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../core/auth/auth_service.dart';
import '../../../../core/theme/admin_theme.dart';

// Message unique : sans is_admin(), la RLS renvoie des tableaux vides et chaque
// panneau conclurait « rien à nettoyer » alors qu'il ne voit simplement rien.
// L'email connecté est rappelé — c'est presque toujours lui le coupable.
String get _kNotAdminError =>
    'Compte « ${AuthService.currentUser?.email ?? '?'} » sans droits admin côté '
    'Supabase : is_admin() renvoie false, la RLS masque donc toutes les lignes. '
    'Des compteurs à 0 ne signifient PAS que la base est propre. '
    'Connecte-toi avec le compte inscrit dans public.admins.';

// PostgREST plafonne chaque réponse (1000 lignes par défaut). Sans pagination,
// une analyse ne voit qu'un échantillon arbitraire : elle rate des orphelines,
// et un contrôle d'existence tronqué en invente de fausses.
const int _kPageSize = 1000;

// Un filtre `in` voyage dans l'URL : au-delà de quelques centaines d'IDs la
// requête est rejetée. On interroge par lots.
const int _kInChunk = 200;

/// Enchaîne les pages de [page] jusqu'à ce qu'une page incomplète signale la fin.
Future<List<Map<String, dynamic>>> _fetchAllPages(
  PostgrestTransformBuilder<PostgrestList> Function(int from, int to) page,
) async {
  final all = <Map<String, dynamic>>[];
  var from = 0;
  while (true) {
    final rows = await page(from, from + _kPageSize - 1);
    all.addAll(rows);
    if (rows.length < _kPageSize) break;
    from += _kPageSize;
  }
  return all;
}

class CleanupSection extends StatefulWidget {
  const CleanupSection({super.key});
  @override
  State<CleanupSection> createState() => _CleanupSectionState();
}

class _CleanupSectionState extends State<CleanupSection> {
  // Bucket Supabase Storage qui héberge les photos de waypoint (miroir du mobile).
  static const String _kWaypointBucket = 'waypoint-photos';

  // Réplique exacte de la sanitisation mobile (_sanitize dans photo_sync_service) :
  // le dossier d'un ride est `$userId/${sanitize(startTime)}`. Doit rester
  // identique, sinon on ne retrouve pas les dossiers.
  String _sanitizeRideId(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');

  // Seuils configurables (remplacent les constantes en dur)
  int _thresholdInProgressHours = 48;
  int _thresholdPausedDays = 7;

  // ── État ───────────────────────────────────────────────────────────────────
  bool _analyzed = false;
  bool _analyzing = false;
  bool _purging = false;
  String? _error;

  // ── Résultats ──────────────────────────────────────────────────────────────
  int _orphanPositions = 0;
  int _ghostSessions = 0;
  int _orphanRides = 0;
  // Suivis écartés du lot parce qu'ils émettent encore (cf. _kLiveGrace).
  int _liveProtected = 0;
  double _estimatedMb = 0;
  final List<_PreviewRow> _previewRows = [];

  // Détail des sessions fantômes récupérées depuis Supabase
  final List<Map<String, dynamic>> _ghostDetails = [];

  // IDs de sessions référencées dans rides mais inexistantes dans safety_sessions.
  // Ces rides seront RÉPARÉS (safetySessionId mis à null), pas supprimés.
  final List<String> _orphanRideSessionIds = [];

  // Fichiers Storage orphelins : dossiers `waypoint-photos/$user/$ride` qui ne
  // correspondent à aucune ligne `rides` (typiquement une sortie supprimée
  // hors-ligne dont seul le nettoyage réseau a échoué). Chemins d'objets complets.
  int _orphanStorageFiles = 0;
  double _orphanStorageMb = 0;
  final List<String> _orphanStoragePaths = [];

  // Sessions référencées par des positions mais absentes de safety_sessions.
  // Mémorisé à l'analyse pour que la purge supprime par filtre POSITIF
  // (`session_id IN (...)`) au lieu d'un « tout sauf les valides » qui, sur une
  // liste de sessions tronquée, effacerait les positions de sorties bien vivantes.
  final List<String> _orphanPositionSessionIds = [];

  // Garde-fou « suivi actif ». À seuil 0 toute session non terminée devient
  // fantôme, y compris celle qui remonte des positions en ce moment même. L'app
  // mobile pousse un point toutes les ~15 s : 30 min de silence, c'est 120
  // points manqués — largement au-delà d'un tunnel ou d'une zone blanche, alors
  // qu'un suivi mort (app tuée, batterie à plat) n'émet plus jamais.
  // Une session `paused` n'émet rien : elle n'est donc protégée que dans les
  // 30 min suivant la pause. C'est voulu — ne pas couper une pause café, sans
  // prétendre couvrir une pause d'une nuit.
  static const Duration _kLiveGrace = Duration(minutes: 30);

  /// Sessions parmi [ids] ayant reçu une position après [since].
  Future<Set<String>> _sessionsWithRecentPosition(
      SupabaseClient supabase, List<String> ids, DateTime since) async {
    final live = <String>{};
    for (var i = 0; i < ids.length; i += _kInChunk) {
      final end = (i + _kInChunk < ids.length) ? i + _kInChunk : ids.length;
      final rows = await _fetchAllPages((f, t) => supabase
          .from('safety_positions')
          .select('session_id')
          .inFilter('session_id', ids.sublist(i, end))
          .gt('created_at', since.toIso8601String())
          .range(f, t));
      live.addAll(rows.map((r) => r['session_id'] as String));
    }
    return live;
  }

  /// Sous-ensemble de [ids] réellement présent dans `safety_sessions`.
  Future<Set<String>> _existingSessionIds(
      SupabaseClient supabase, List<String> ids) async {
    final found = <String>{};
    for (var i = 0; i < ids.length; i += _kInChunk) {
      final end = (i + _kInChunk < ids.length) ? i + _kInChunk : ids.length;
      final rows = await _fetchAllPages((f, t) => supabase
          .from('safety_sessions')
          .select('id')
          .inFilter('id', ids.sublist(i, end))
          .range(f, t));
      found.addAll(rows.map((r) => r['id'] as String));
    }
    return found;
  }

  // ── Analyse ────────────────────────────────────────────────────────────────
  Future<void> _analyze() async {
    setState(() {
      _analyzing = true; _analyzed = false; _error = null;
      _ghostDetails.clear(); _orphanStoragePaths.clear();
      _orphanPositionSessionIds.clear(); _liveProtected = 0;
    });

    try {
      // Trancher AVANT de compter : « rien à purger » et « rien de visible »
      // se ressemblent trop pour être laissés indistincts.
      if (!await AuthService.isServerAdmin()) {
        setState(() => _error = _kNotAdminError);
        return;
      }

      final supabase = Supabase.instance.client;
      // .toUtc() indispensable : `started_at` est un timestamptz, et un ISO local
      // sans fuseau serait lu comme de l'UTC — en France le seuil dériverait de
      // 1 à 2 h, dans le sens qui purge trop tôt.
      final now = DateTime.now().toUtc();
      final cutoff48h = now.subtract(Duration(hours: _thresholdInProgressHours));
      final cutoff7d  = now.subtract(Duration(days: _thresholdPausedDays));

      // 1. Positions orphelines
      final allPositionSessionIds = await _fetchAllPages((f, t) =>
          supabase.from('safety_positions').select('session_id').range(f, t));

      final sessionIds = allPositionSessionIds
          .map((r) => r['session_id'] as String?)
          .whereType<String>()
          .toSet()
          .toList();

      int orphanCount = 0;
      final orphanSessionIds = <String>[];
      if (sessionIds.isNotEmpty) {
        final validIds = await _existingSessionIds(supabase, sessionIds);
        orphanSessionIds.addAll(sessionIds.where((id) => !validIds.contains(id)));
        for (var i = 0; i < orphanSessionIds.length; i += _kInChunk) {
          final end = (i + _kInChunk < orphanSessionIds.length) ? i + _kInChunk : orphanSessionIds.length;
          final res = await supabase
              .from('safety_positions')
              .select('id')
              .inFilter('session_id', orphanSessionIds.sublist(i, end))
              .count(CountOption.exact);
          orphanCount += res.count;
        }
      }

      // 2. Sessions fantômes in_progress > 48h — avec détails
      final ghostInProgressList = await _fetchAllPages((f, t) => supabase
          .from('safety_sessions')
          .select('id, share_code, started_at, status')
          .isFilter('ended_at', null)
          .eq('status', 'in_progress')
          .lt('started_at', cutoff48h.toIso8601String())
          .order('started_at', ascending: false)
          .range(f, t));

      // 3. Sessions fantômes paused > 7j — avec détails
      final ghostPausedList = await _fetchAllPages((f, t) => supabase
          .from('safety_sessions')
          .select('id, share_code, started_at, status')
          .isFilter('ended_at', null)
          .eq('status', 'paused')
          .lt('started_at', cutoff7d.toIso8601String())
          .order('started_at', ascending: false)
          .range(f, t));

      // 3bis. Écarter les suivis encore vivants (cf. _kLiveGrace).
      final candidateIds = [...ghostInProgressList, ...ghostPausedList]
          .map((s) => s['id'] as String)
          .toList();
      final liveIds = candidateIds.isEmpty
          ? <String>{}
          : await _sessionsWithRecentPosition(
              supabase, candidateIds, now.subtract(_kLiveGrace));
      ghostInProgressList.removeWhere((s) => liveIds.contains(s['id']));
      ghostPausedList.removeWhere((s) => liveIds.contains(s['id']));

      final allGhosts = [...ghostInProgressList, ...ghostPausedList];

      // 4. Rides avec safetySessionId inexistant dans safety_sessions.
      //    On récupère aussi user_id/started_at : nécessaires pour retrouver le
      //    dossier Storage (étape 5) et pour la réparation lors de la purge.
      final allRidesJson = await _fetchAllPages((f, t) =>
          supabase.from('rides').select('ride_json, user_id, started_at').range(f, t));
      final rideSessionRefs = allRidesJson
          .map((r) => (r['ride_json'] as Map?)?['safetySessionId'] as String?)
          .whereType<String>()
          .toSet()
          .toList();

      final deadRideSessionIds = <String>[];
      if (rideSessionRefs.isNotEmpty) {
        final existingIds = await _existingSessionIds(supabase, rideSessionRefs);
        deadRideSessionIds.addAll(rideSessionRefs.where((ref) => !existingIds.contains(ref)));
      }

      // 5. Fichiers Storage orphelins. On construit l'ensemble des dossiers
      //    légitimes `$user/${sanitize(started_at)}`, puis on balaie le bucket :
      //    tout dossier absent de cet ensemble n'appartient à aucune sortie.
      final validFolderKeys = <String>{};
      for (final r in allRidesJson) {
        final uid = r['user_id'] as String?;
        final startedAt = r['started_at'] as String?;
        if (uid != null && startedAt != null) {
          validFolderKeys.add('$uid/${_sanitizeRideId(startedAt)}');
        }
      }
      final orphanStoragePaths = <String>[];
      double orphanStorageBytes = 0;
      try {
        final storage = supabase.storage.from(_kWaypointBucket);
        final userFolders = await storage.list();
        for (final uf in userFolders) {
          if (uf.metadata != null) continue; // fichier au niveau racine → ignore
          final userId = uf.name;
          final rideFolders = await storage.list(path: userId);
          for (final rf in rideFolders) {
            if (rf.metadata != null) continue; // fichier, pas un dossier de ride
            final folderKey = '$userId/${rf.name}';
            if (validFolderKeys.contains(folderKey)) continue; // rattaché à un ride → on garde
            final files = await storage.list(path: folderKey);
            for (final f in files) {
              if (f.metadata == null) continue; // sous-dossier inattendu → ignore
              orphanStoragePaths.add('$folderKey/${f.name}');
              final size = f.metadata?['size'];
              if (size is num) orphanStorageBytes += size.toDouble();
            }
          }
        }
      } catch (e) {
        debugPrint('[CLEANUP] analyse Storage: $e');
      }

      final estimatedBytes = orphanCount * 200 + allGhosts.length * 500 +
          deadRideSessionIds.length * 5000 + orphanStorageBytes;

      setState(() {
        _orphanPositions = orphanCount;
        _ghostSessions = allGhosts.length;
        _liveProtected = liveIds.length;
        _orphanRides = deadRideSessionIds.length;
        _orphanStorageFiles = orphanStoragePaths.length;
        _orphanStorageMb = orphanStorageBytes / (1024 * 1024);
        _estimatedMb = estimatedBytes / (1024 * 1024);
        _ghostDetails
          ..clear()
          ..addAll(allGhosts);
        _orphanRideSessionIds
          ..clear()
          ..addAll(deadRideSessionIds);
        _orphanPositionSessionIds
          ..clear()
          ..addAll(orphanSessionIds);
        _orphanStoragePaths
          ..clear()
          ..addAll(orphanStoragePaths);
        _previewRows
          ..clear()
          ..addAll([
            if (orphanCount > 0)
              _PreviewRow('safety_positions sans session (session_id introuvable)', orphanCount),
            if (ghostInProgressList.isNotEmpty)
              _PreviewRow('safety_sessions statut in_progress > ${_thresholdInProgressHours}h', ghostInProgressList.length),
            if (ghostPausedList.isNotEmpty)
              _PreviewRow('safety_sessions statut paused > $_thresholdPausedDays jours', ghostPausedList.length),
            if (deadRideSessionIds.isNotEmpty)
              _PreviewRow('rides à réparer (safetySessionId orphelin → nettoyé)', deadRideSessionIds.length),
            if (orphanStoragePaths.isNotEmpty)
              _PreviewRow('photos Storage orphelines (dossier sans ride)', orphanStoragePaths.length),
          ]);
        _analyzed = true;
      });
    } catch (e) {
      setState(() => _error = 'Erreur lors de l\'analyse : $e');
    } finally {
      setState(() => _analyzing = false);
    }
  }

  // ── Purge ──────────────────────────────────────────────────────────────────
  Future<void> _purge() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(
        total: _totalRows,
        // À seuil 0, un tracking encore actif entre dans le lot : l'admin doit
        // le voir sur l'écran de confirmation, pas le découvrir après coup.
        includesLive: _thresholdInProgressHours == 0 || _thresholdPausedDays == 0,
      ),
    );
    if (confirmed != true) return;

    setState(() { _purging = true; _error = null; });
    try {
      final supabase = Supabase.instance.client;

      // Les IDs figés par l'analyse : le lot purgé est celui qui a été affiché.
      final ghostIds = _ghostDetails.map((s) => s['id'] as String).toList();

      // ÉTAPE 0 — RÉPARER (et non supprimer) les rides liés à une session
      // fantôme/morte. Le ride EST la donnée utilisateur ; la session n'est
      // qu'un échafaudage de tracking live. On retire donc le safetySessionId
      // orphelin et on conserve le ride (et ses photos).
      int repairedRides = 0;
      final allDeadSessionIds = {...ghostIds, ..._orphanRideSessionIds};
      if (allDeadSessionIds.isNotEmpty) {
        final ridesData = await _fetchAllPages((f, t) =>
            supabase.from('rides').select('ride_json, user_id, started_at').range(f, t));
        for (final r in ridesData) {
          final rawJson = r['ride_json'];
          if (rawJson is! Map) continue;
          final sessionId = rawJson['safetySessionId'] as String?;
          if (sessionId != null && allDeadSessionIds.contains(sessionId)) {
            final rideJson = Map<String, dynamic>.from(rawJson.cast<String, dynamic>());
            rideJson['safetySessionId'] = null;
            await supabase.from('rides').update({'ride_json': rideJson})
                .eq('user_id', r['user_id'] as String)
                .eq('started_at', r['started_at'] as String);
            repairedRides++;
          }
        }
      }

      // ÉTAPE 1 — Supprimer d'abord les positions liées aux sessions fantômes
      // (contrainte FK : safety_positions.session_id → safety_sessions.id)
      if (ghostIds.isNotEmpty) {
        await supabase
            .from('safety_positions')
            .delete()
            .inFilter('session_id', ghostIds);
      }

      // ÉTAPE 2 — Supprimer les positions orphelines (sans session du tout).
      // Filtre POSITIF sur les session_id identifiés à l'analyse : un « tout
      // sauf les sessions valides » s'appuierait sur une liste plafonnée par
      // PostgREST et effacerait les positions de sorties bien vivantes.
      for (var i = 0; i < _orphanPositionSessionIds.length; i += _kInChunk) {
        final end = (i + _kInChunk < _orphanPositionSessionIds.length)
            ? i + _kInChunk
            : _orphanPositionSessionIds.length;
        await supabase.from('safety_positions').delete()
            .inFilter('session_id', _orphanPositionSessionIds.sublist(i, end));
      }

      // ÉTAPE 3 — Supprimer les sessions fantômes (maintenant sans positions).
      // On supprime EXACTEMENT les IDs retenus par l'analyse. Rejouer ici les
      // filtres de date emporterait les sessions devenues fantômes depuis —
      // dont un suivi actif que le garde-fou venait d'écarter.
      int totalDeleted = 0;
      for (var i = 0; i < ghostIds.length; i += _kInChunk) {
        final end = (i + _kInChunk < ghostIds.length) ? i + _kInChunk : ghostIds.length;
        final deleted = await supabase.from('safety_sessions')
            .delete()
            .inFilter('id', ghostIds.sublist(i, end))
            .select('id');
        totalDeleted += (deleted as List).length;
      }

      // ÉTAPE 4 — Supprimer les fichiers Storage orphelins (dossiers sans ride).
      // Best-effort, par lots (l'API remove accepte une liste de chemins).
      int deletedStorageFiles = 0;
      if (_orphanStoragePaths.isNotEmpty) {
        try {
          final storage = supabase.storage.from(_kWaypointBucket);
          const chunk = 100;
          for (var i = 0; i < _orphanStoragePaths.length; i += chunk) {
            final end = (i + chunk < _orphanStoragePaths.length) ? i + chunk : _orphanStoragePaths.length;
            final slice = _orphanStoragePaths.sublist(i, end);
            await storage.remove(slice);
            deletedStorageFiles += slice.length;
          }
        } catch (e) {
          debugPrint('[CLEANUP] purge Storage: $e');
        }
      }

      setState(() {
        _orphanPositions = 0; _ghostSessions = 0; _orphanRides = 0; _estimatedMb = 0;
        _orphanStorageFiles = 0; _orphanStorageMb = 0; _liveProtected = 0;
        _previewRows.clear(); _ghostDetails.clear(); _orphanRideSessionIds.clear();
        _orphanPositionSessionIds.clear();
        _orphanStoragePaths.clear(); _analyzed = false;
      });

      if (mounted) {
        final parts = <String>[
          if (totalDeleted > 0) '$totalDeleted session(s)',
          if (repairedRides > 0) '$repairedRides ride(s) réparé(s)',
          if (deletedStorageFiles > 0) '$deletedStorageFiles photo(s) Storage',
        ];
        final nothingDone = totalDeleted == 0 && repairedRides == 0 && deletedStorageFiles == 0;
        final msg = nothingDone
            ? 'Aucune ligne supprimée — vérifie les politiques RLS Supabase (DELETE sur safety_sessions / Storage)'
            : 'Purge effectuée : ${parts.join(' · ')} ✓';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          backgroundColor: nothingDone ? AdminColors.warning : AdminColors.accent,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: nothingDone ? 8 : 4),
        ));
      }
    } catch (e) {
      setState(() => _error = 'Erreur lors de la purge : $e');
    } finally {
      setState(() => _purging = false);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  String _fmtDate(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '—';
    return DateFormat('dd/MM/yyyy HH:mm').format(dt);
  }

  int get _totalRows => _previewRows.fold(0, (s, r) => s + r.count);

  // ── Export CSV ────────────────────────────────────────────────────────────
  void _exportCsv() {
    final lines = <String>[];
    // En-tête
    lines.add("type,id,statut,started_at,share_code");
    // Lignes sessions fantômes
    for (final s in _ghostDetails) {
      final id = s["id"] ?? "";
      final status = s["status"] ?? "";
      final startedAt = s["started_at"] ?? "";
      final shareCode = s["share_code"] ?? "";
      lines.add("session_fantome,\"$id\",\"$status\",\"$startedAt\",\"$shareCode\"");
    }
    // Note positions orphelines (pas de détail ligne par ligne — trop volumineux)
    if (_orphanPositions > 0) {
      lines.add("positions_orphelines,(voir Supabase),,$_orphanPositions lignes,");
    }
    final csv = lines.join("\n");
    final bytes = html.Blob([csv], "text/csv;charset=utf-8");
    final url = html.Url.createObjectUrlFromBlob(bytes);
    final now = DateFormat("yyyyMMdd_HHmm").format(DateTime.now());
    html.AnchorElement(href: url)
      ..setAttribute("download", "purge_admin_$now.csv")
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // Titre + badge
        Row(children: [
          const Text('Nettoyage & purge',
              style: TextStyle(color: AdminColors.textPrimary, fontSize: 20,
                  fontWeight: FontWeight.w700, letterSpacing: -0.3)),
          const Spacer(),
          if (_analyzed && _totalRows > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(color: AdminColors.dangerDim,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AdminColors.danger, width: 0.5)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.warning_amber_rounded, color: AdminColors.danger, size: 14),
                const SizedBox(width: 6),
                Text('$_totalRows orphelines',
                    style: const TextStyle(color: AdminColors.danger, fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
            ),
        ]),
        const SizedBox(height: 20),

        // Bouton Analyser
        SizedBox(
          width: double.infinity,
          height: 44,
          child: ElevatedButton.icon(
            onPressed: _analyzing ? null : _analyze,
            style: ElevatedButton.styleFrom(
              backgroundColor: AdminColors.surface, foregroundColor: AdminColors.textPrimary,
              side: const BorderSide(color: AdminColors.border),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: _analyzing
                ? const SizedBox(width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AdminColors.accent))
                : const Icon(Icons.refresh, size: 16),
            label: const Text('Analyser', style: TextStyle(fontSize: 13)),
          ),
        ),
        const SizedBox(height: 16),

        // Seuils configurables
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AdminColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AdminColors.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.tune, color: AdminColors.textSecondary, size: 14),
              SizedBox(width: 6),
              Text('Seuils de détection des fantômes',
                  style: TextStyle(color: AdminColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w500)),
            ]),
            const SizedBox(height: 14),

            // in_progress
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AdminColors.dangerDim,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('in_progress',
                      style: TextStyle(color: AdminColors.danger, fontSize: 11, fontWeight: FontWeight.w500)),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('considéré fantôme après',
                      style: TextStyle(color: AdminColors.textSecondary, fontSize: 12)),
                ),
                _ThresholdInputField(
                  value: _thresholdInProgressHours,
                  units: const ['heures', 'jours'],
                  max: 720,
                  onChanged: (v) => setState(() => _thresholdInProgressHours = v),
                ),
              ]),
              _ThresholdHint(
                zero: _thresholdInProgressHours == 0,
                zeroLabel: '0 h = toute session non terminée, y compris un suivi en cours',
              ),
            ]),
            const SizedBox(height: 14),

            // paused
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AdminColors.warningDim,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('paused',
                      style: TextStyle(color: AdminColors.warning, fontSize: 11, fontWeight: FontWeight.w500)),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('considéré fantôme après',
                      style: TextStyle(color: AdminColors.textSecondary, fontSize: 12)),
                ),
                _ThresholdInputField(
                  value: _thresholdPausedDays,
                  units: const ['jours', 'semaines'],
                  max: 90,
                  onChanged: (v) => setState(() => _thresholdPausedDays = v),
                ),
              ]),
              _ThresholdHint(
                zero: _thresholdPausedDays == 0,
                zeroLabel: '0 j = toute session en pause, même mise en pause à l\'instant',
              ),
            ]),
          ]),
        ),

        // Erreur
        if (_error != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AdminColors.dangerDim,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AdminColors.danger, width: 0.5)),
            child: Row(children: [
              const Icon(Icons.error_outline, color: AdminColors.danger, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(_error!, style: const TextStyle(color: AdminColors.danger, fontSize: 13))),
            ]),
          ),
        ],

        // Résultats
        if (_analyzed) ...[
          const SizedBox(height: 20),

          // Métriques avec tooltip
          Row(children: [
            Expanded(child: _MetricCard(
              label: 'Positions orphelines',
              value: '$_orphanPositions',
              sub: 'sans session parente',
              valueColor: AdminColors.danger,
              tooltip: 'Lignes dans safety_positions dont le session_id\nne correspond à aucune session existante.\nCes points GPS ne sont rattachés à rien.',
            )),
            const SizedBox(width: 10),
            Expanded(child: _MetricCard(
              label: 'Sessions fantômes',
              value: '$_ghostSessions',
              sub: 'in_progress > ${_thresholdInProgressHours}h ou paused > ${_thresholdPausedDays}j',
              valueColor: AdminColors.warning,
              tooltip: 'Sessions dans safety_sessions dont le statut\nest resté bloqué (ended_at IS NULL) :\n• in_progress depuis plus de ${_thresholdInProgressHours}h\n• paused depuis plus de ${_thresholdPausedDays} jours\nCe sont généralement des tests non terminés.',
            )),
            const SizedBox(width: 10),
            Expanded(child: _MetricCard(
              label: 'Rides à réparer',
              value: '$_orphanRides',
              sub: 'safetySessionId orphelin',
              valueColor: AdminColors.warning,
              tooltip: 'Entrées dans rides dont le champ\nride_json->safetySessionId pointe vers\nune session qui n\'existe plus.\nCes rides ne sont PAS supprimés :\nle safetySessionId orphelin est mis à null,\nle ride et ses photos sont conservés.',
            )),
            const SizedBox(width: 10),
            Expanded(child: _MetricCard(
              label: 'Photos Storage orphelines',
              value: '$_orphanStorageFiles',
              sub: _orphanStorageMb < 0.1 ? 'dossier sans ride' : '~${_orphanStorageMb.toStringAsFixed(1)} Mo · sans ride',
              valueColor: AdminColors.danger,
              tooltip: 'Fichiers du bucket $_kWaypointBucket rangés\nsous \$user/\$ride mais dont aucune ligne rides\nne correspond (ex. sortie supprimée hors-ligne).\nCes fichiers seront supprimés du Storage.',
            )),
            const SizedBox(width: 10),
            Expanded(child: _MetricCard(
              label: 'Espace libérable',
              value: _estimatedMb < 0.1 ? '< 0.1 Mo' : '~${_estimatedMb.toStringAsFixed(1)} Mo',
              sub: 'estimé (positions, sessions, photos)',
              valueColor: AdminColors.textPrimary,
              tooltip: 'Estimation basée sur :\n~200 octets par position GPS\n~500 octets par session\n+ taille réelle des photos Storage orphelines',
            )),
          ]),

          // Suivis actifs écartés : sans ce retour, l'admin croirait à une
          // détection défaillante alors que le garde-fou a fait son travail.
          if (_liveProtected > 0) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AdminColors.warningDim,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AdminColors.warning, width: 0.5)),
              child: Row(children: [
                const Icon(Icons.podcasts, color: AdminColors.warning, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  '$_liveProtected suivi(s) actif(s) écarté(s) — position reçue il y a '
                  'moins de ${_kLiveGrace.inMinutes} min. Non compté, non supprimé.',
                  style: const TextStyle(color: AdminColors.warning, fontSize: 13),
                )),
              ]),
            ),
          ],

          // Aperçu résumé
          if (_previewRows.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: AdminColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AdminColors.border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Aperçu — lignes qui seront supprimées',
                    style: TextStyle(color: AdminColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w500)),
                const SizedBox(height: 12),
                ..._previewRows.map((r) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    Expanded(child: Text(r.label,
                        style: const TextStyle(color: AdminColors.textPrimary, fontSize: 13))),
                    Text('${r.count} lignes',
                        style: const TextStyle(color: AdminColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                  ]),
                )),
              ]),
            ),
          ],

          // Détail des sessions fantômes
          if (_ghostDetails.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: AdminColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AdminColors.border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.list_alt_outlined, color: AdminColors.textSecondary, size: 14),
                  const SizedBox(width: 8),
                  const Text('Détail des sessions fantômes',
                      style: TextStyle(color: AdminColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w500)),
                  const Spacer(),
                  Tooltip(
                    message: 'Sessions bloquées qui seront supprimées.\nShare code = code de partage du ride.',
                    child: const Icon(Icons.help_outline, color: AdminColors.textSecondary, size: 14),
                  ),
                ]),
                const SizedBox(height: 12),
                // En-tête
                const Row(children: [
                  SizedBox(width: 120, child: Text('ID (court)', style: TextStyle(color: AdminColors.textSecondary, fontSize: 11, fontWeight: FontWeight.w600))),
                  SizedBox(width: 100, child: Text('Statut', style: TextStyle(color: AdminColors.textSecondary, fontSize: 11, fontWeight: FontWeight.w600))),
                  Expanded(child: Text('Démarré le', style: TextStyle(color: AdminColors.textSecondary, fontSize: 11, fontWeight: FontWeight.w600))),
                  SizedBox(width: 120, child: Text('Share code', style: TextStyle(color: AdminColors.textSecondary, fontSize: 11, fontWeight: FontWeight.w600))),
                ]),
                const SizedBox(height: 8),
                const Divider(color: AdminColors.border, height: 1),
                const SizedBox(height: 8),
                // Lignes
                ..._ghostDetails.map((s) {
                  final id = (s['id'] as String? ?? '').substring(0, 8);
                  final status = s['status'] as String? ?? '—';
                  final startedAt = _fmtDate(s['started_at'] as String?);
                  final shareCode = s['share_code'] as String? ?? '—';
                  final isInProgress = status == 'in_progress';
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      SizedBox(width: 120, child: Text('$id…',
                          style: const TextStyle(color: AdminColors.textPrimary, fontSize: 12, fontFamily: 'monospace'))),
                      SizedBox(width: 100, child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: isInProgress ? AdminColors.dangerDim : AdminColors.warningDim,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(status,
                            style: TextStyle(
                              color: isInProgress ? AdminColors.danger : AdminColors.warning,
                              fontSize: 11, fontWeight: FontWeight.w500,
                            )),
                      )),
                      Expanded(child: Text(startedAt,
                          style: const TextStyle(color: AdminColors.textPrimary, fontSize: 12))),
                      SizedBox(width: 120, child: Text(shareCode,
                          style: const TextStyle(color: AdminColors.textSecondary, fontSize: 12, fontFamily: 'monospace'),
                          overflow: TextOverflow.ellipsis)),
                    ]),
                  );
                }),
              ]),
            ),
          ],

          if (_previewRows.isEmpty) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: AdminColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AdminColors.accent, width: 0.5)),
              child: const Row(children: [
                Icon(Icons.check_circle_outline, color: AdminColors.accent, size: 18),
                SizedBox(width: 10),
                Text('Aucune trace orpheline détectée — base propre ✓',
                    style: TextStyle(color: AdminColors.accent, fontSize: 13)),
              ]),
            ),
          ],

          // Actions
          const SizedBox(height: 20),
          Row(children: [
            ElevatedButton.icon(
              onPressed: (_purging || _totalRows == 0) ? null : _purge,
              style: ElevatedButton.styleFrom(
                backgroundColor: AdminColors.danger, foregroundColor: Colors.white,
                disabledBackgroundColor: AdminColors.border,
                disabledForegroundColor: AdminColors.textSecondary,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: _purging
                  ? const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.delete_outline, size: 16),
              label: const Text('Purger la sélection',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: _totalRows == 0 ? null : _exportCsv,
              style: OutlinedButton.styleFrom(
                foregroundColor: AdminColors.textPrimary,
                side: const BorderSide(color: AdminColors.border),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.download_outlined, size: 16),
              label: const Text('Exporter la liste', style: TextStyle(fontSize: 13)),
            ),
          ]),
        ],

        // État vide
        if (!_analyzed && !_analyzing && _error == null) ...[
          const SizedBox(height: 48),
          const Center(child: Column(children: [
            Icon(Icons.manage_search, color: AdminColors.border, size: 40),
            SizedBox(height: 12),
            Text('Lance une analyse pour voir les données à purger',
                style: TextStyle(color: AdminColors.textSecondary, fontSize: 13)),
          ])),
        ],

        // Purge par identité (rides orphelins des anciennes identités anonymes)
        const SizedBox(height: 24),
        const _IdentitiesPurgePanel(),

        // Sessions sans propriétaire (user_id NULL) — non couvertes ailleurs
        const SizedBox(height: 16),
        const _NullSessionsPanel(),

        const SizedBox(height: 40),
        const Center(child: Icon(Icons.keyboard_arrow_down, color: AdminColors.border, size: 28)),
      ]),
    );
  }
}

// ── Modèles ─────────────────────────────────────────────────────────────────

class _PreviewRow {
  final String label;
  final int count;
  _PreviewRow(this.label, this.count);
}

// ── Widgets ─────────────────────────────────────────────────────────────────


class _ThresholdInputField extends StatefulWidget {
  final int value; // always in base unit (units[0])
  final List<String> units;
  final int max; // in base unit
  final ValueChanged<int> onChanged; // always in base unit

  const _ThresholdInputField({
    required this.value,
    required this.units,
    required this.max,
    required this.onChanged,
  });

  @override
  State<_ThresholdInputField> createState() => _ThresholdInputFieldState();
}

class _ThresholdInputFieldState extends State<_ThresholdInputField> {
  late String _selectedUnit;
  late TextEditingController _ctrl;
  late FocusNode _focus;

  // Conversion factor: base unit → selected unit
  int get _factor {
    final base = widget.units.first;
    if (base == 'heures' && _selectedUnit == 'jours') return 24;
    if (base == 'jours' && _selectedUnit == 'semaines') return 7;
    return 1;
  }

  int get _displayValue => widget.value ~/ _factor;

  @override
  void initState() {
    super.initState();
    _selectedUnit = widget.units.first;
    _ctrl = TextEditingController(text: '${widget.value}');
    // Une saisie invalide (vide, 0, au-delà du max) est refusée par
    // _onTextChanged : sans resynchro, le champ continue d'afficher une valeur
    // qui n'est PAS celle utilisée par l'analyse. On réaligne à la sortie du
    // champ pour que l'affiché soit toujours l'effectif.
    _focus = FocusNode()..addListener(() {
      if (!_focus.hasFocus) _syncText();
    });
  }

  void _syncText() {
    final shown = '$_displayValue';
    if (_ctrl.text != shown) _ctrl.text = shown;
  }

  @override
  void didUpdateWidget(_ThresholdInputField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      final shown = int.tryParse(_ctrl.text) ?? 0;
      if (shown != _displayValue) _ctrl.text = '$_displayValue';
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _onTextChanged(String text) {
    final v = int.tryParse(text);
    // 0 est une valeur légitime : « tout ce qui n'est pas terminé est fantôme ».
    // Seuls le vide (saisie en cours) et le négatif sont ignorés — la resynchro
    // sur perte de focus rétablit alors l'affichage de la valeur effective.
    if (v == null || v < 0) return;
    final base = v * _factor;
    if (base <= widget.max) widget.onChanged(base);
  }

  void _onUnitChanged(String? unit) {
    if (unit == null || unit == _selectedUnit) return;
    setState(() {
      _selectedUnit = unit;
      _ctrl.text = '$_displayValue';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: 72,
        height: 36,
        child: TextField(
          controller: _ctrl,
          focusNode: _focus,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AdminColors.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AdminColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AdminColors.accent),
            ),
            filled: true,
            fillColor: AdminColors.surface,
          ),
          onChanged: _onTextChanged,
        ),
      ),
      const SizedBox(width: 8),
      Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: AdminColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AdminColors.border),
        ),
        alignment: Alignment.center,
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _selectedUnit,
            dropdownColor: AdminColors.surface,
            iconEnabledColor: AdminColors.textSecondary,
            iconSize: 16,
            style: const TextStyle(color: AdminColors.textSecondary, fontSize: 13),
            items: widget.units.map((u) =>
                DropdownMenuItem(value: u, child: Text(u))).toList(),
            onChanged: _onUnitChanged,
          ),
        ),
      ),
    ]);
  }
}

/// Légende sous un champ de seuil. À 0 le seuil n'exclut plus rien : on passe
/// en avertissement, parce qu'une session « fantôme » devient alors n'importe
/// quelle session non terminée — y compris un tracking en cours.
class _ThresholdHint extends StatelessWidget {
  final bool zero;
  final String zeroLabel;
  const _ThresholdHint({required this.zero, required this.zeroLabel});

  @override
  Widget build(BuildContext context) {
    final color = zero ? AdminColors.warning : AdminColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(top: 5, left: 2),
      child: Row(children: [
        Icon(zero ? Icons.warning_amber_rounded : Icons.info_outline, size: 11, color: color),
        const SizedBox(width: 4),
        Expanded(child: Text(zero ? zeroLabel : 'Valeur personnalisable',
            style: TextStyle(color: color, fontSize: 11))),
      ]),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final Color valueColor;
  final String tooltip;
  const _MetricCard({
    required this.label, required this.value,
    required this.sub, required this.valueColor,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AdminColors.surface,
            borderRadius: BorderRadius.circular(10), border: Border.all(color: AdminColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(label,
                style: const TextStyle(color: AdminColors.textSecondary, fontSize: 11))),
            const Icon(Icons.help_outline, color: AdminColors.border, size: 12),
          ]),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(color: valueColor, fontSize: 26,
              fontWeight: FontWeight.w700, letterSpacing: -0.5)),
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(color: AdminColors.textSecondary, fontSize: 11)),
        ]),
      ),
    );
  }
}

class _ConfirmDialog extends StatelessWidget {
  final int total;
  final bool includesLive;
  const _ConfirmDialog({required this.total, this.includesLive = false});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AdminColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AdminColors.border)),
      title: const Row(children: [
        Icon(Icons.warning_amber, color: AdminColors.warning, size: 20),
        SizedBox(width: 10),
        Text('Confirmer la purge',
            style: TextStyle(color: AdminColors.textPrimary, fontSize: 16)),
      ]),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        RichText(text: TextSpan(
          style: const TextStyle(color: AdminColors.textSecondary, fontSize: 13, height: 1.6),
          children: [
            TextSpan(text: '$total éléments',
                style: const TextStyle(color: AdminColors.danger, fontWeight: FontWeight.w600)),
            const TextSpan(text: ' seront traités : sessions/positions orphelines et photos Storage supprimées définitivement, rides à safetySessionId orphelin réparés (conservés).\n\nLes suppressions sont irréversibles.'),
          ],
        )),
        if (includesLive) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AdminColors.warningDim,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AdminColors.warning, width: 0.5)),
            child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.podcasts, color: AdminColors.warning, size: 15),
              SizedBox(width: 8),
              Expanded(child: Text(
                'Seuil à 0 : un suivi encore actif entre dans le lot. La sortie en cours '
                'perdrait son partage live et ses positions GPS déjà enregistrées.',
                style: TextStyle(color: AdminColors.warning, fontSize: 12, height: 1.4),
              )),
            ]),
          ),
        ],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler', style: TextStyle(color: AdminColors.textSecondary))),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: ElevatedButton.styleFrom(backgroundColor: AdminColors.danger, foregroundColor: Colors.white),
          child: const Text('Purger'),
        ),
      ],
    );
  }
}

// ── Purge par identité ───────────────────────────────────────────────────────
// Les rides s'accumulent sous plusieurs `user_id` anonymes (chaque réinstall de
// l'app mobile crée une nouvelle identité). Les rides des anciennes identités
// deviennent orphelins : invisibles et indélébiles côté client (RLS). L'admin
// (is_admin()) peut ici les voir groupés par identité et purger des identités
// entières (rides + sessions + positions + photos Storage).

class _Identity {
  final String userId;
  int rides = 0;
  int photos = 0;
  DateTime? first;
  DateTime? last;
  _Identity(this.userId);
}

class _IdentitiesPurgePanel extends StatefulWidget {
  const _IdentitiesPurgePanel();
  @override
  State<_IdentitiesPurgePanel> createState() => _IdentitiesPurgePanelState();
}

class _IdentitiesPurgePanelState extends State<_IdentitiesPurgePanel> {
  static const String _kWaypointBucket = 'waypoint-photos';

  bool _loading = false;
  bool _loaded = false;
  bool _purging = false;
  String? _error;
  final List<_Identity> _identities = [];
  final Set<String> _selected = {};

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      if (!await AuthService.isServerAdmin()) {
        setState(() => _error = _kNotAdminError);
        return;
      }
      final supabase = Supabase.instance.client;
      final rides = await _fetchAllPages((f, t) =>
          supabase.from('rides').select('user_id, started_at, ride_json').range(f, t));
      final map = <String, _Identity>{};
      for (final r in rides) {
        final uid = r['user_id'] as String?;
        if (uid == null) continue;
        final id = map.putIfAbsent(uid, () => _Identity(uid));
        id.rides++;
        final sa = DateTime.tryParse(r['started_at'] as String? ?? '');
        if (sa != null) {
          if (id.first == null || sa.isBefore(id.first!)) id.first = sa;
          if (id.last == null || sa.isAfter(id.last!)) id.last = sa;
        }
        final rj = r['ride_json'];
        if (rj is Map) {
          final wps = rj['waypoints'];
          if (wps is List) {
            for (final w in wps) {
              if (w is Map && w['photos'] is List) id.photos += (w['photos'] as List).length;
            }
          }
        }
      }
      final list = map.values.toList()
        ..sort((a, b) => (b.last ?? DateTime(0)).compareTo(a.last ?? DateTime(0)));
      setState(() {
        _identities..clear()..addAll(list);
        _selected.clear();
        _loaded = true;
      });
    } catch (e) {
      setState(() => _error = 'Erreur de chargement : $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _selectedRides =>
      _identities.where((i) => _selected.contains(i.userId)).fold(0, (s, i) => s + i.rides);

  Future<void> _purge() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AdminColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: AdminColors.border)),
        title: const Row(children: [
          Icon(Icons.warning_amber, color: AdminColors.danger, size: 20),
          SizedBox(width: 10),
          Expanded(child: Text('Supprimer ces identités ?', style: TextStyle(color: AdminColors.textPrimary, fontSize: 16))),
        ]),
        content: Text(
          '${_selected.length} identité(s) et leurs $_selectedRides ride(s) '
          '(+ sessions, positions GPS et photos Storage) seront supprimés DÉFINITIVEMENT.',
          style: const TextStyle(color: AdminColors.textSecondary, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler', style: TextStyle(color: AdminColors.textSecondary))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AdminColors.danger, foregroundColor: Colors.white),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() { _purging = true; _error = null; });
    try {
      final supabase = Supabase.instance.client;
      int deletedRides = 0;
      for (final uid in _selected.toList()) {
        // 1. Sessions de cette identité (pour supprimer leurs positions d'abord).
        final sessions = await _fetchAllPages((f, t) =>
            supabase.from('safety_sessions').select('id').eq('user_id', uid).range(f, t));
        final sessionIds = sessions.map((s) => s['id'] as String).toList();
        // 2. Positions rattachées (contrainte FK) — avant les sessions, par lots.
        for (var i = 0; i < sessionIds.length; i += _kInChunk) {
          final end = (i + _kInChunk < sessionIds.length) ? i + _kInChunk : sessionIds.length;
          await supabase.from('safety_positions').delete()
              .inFilter('session_id', sessionIds.sublist(i, end));
        }
        // 3. Sessions.
        await supabase.from('safety_sessions').delete().eq('user_id', uid);
        // 4. Rides.
        final deleted = await supabase.from('rides').delete().eq('user_id', uid).select('started_at');
        deletedRides += (deleted as List).length;
        // 5. Dossier Storage `$uid/*` (best-effort).
        try {
          final storage = supabase.storage.from(_kWaypointBucket);
          final rideFolders = await storage.list(path: uid);
          for (final rf in rideFolders) {
            if (rf.metadata != null) continue; // fichier au niveau racine → ignore
            final files = await storage.list(path: '$uid/${rf.name}');
            final paths = files
                .where((f) => f.metadata != null)
                .map((f) => '$uid/${rf.name}/${f.name}')
                .toList();
            if (paths.isNotEmpty) await storage.remove(paths);
          }
        } catch (e) {
          debugPrint('[CLEANUP] purge identité Storage $uid: $e');
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$deletedRides ride(s) supprimé(s) sur ${_selected.length} identité(s) ✓'),
          backgroundColor: AdminColors.accent, behavior: SnackBarBehavior.floating,
        ));
      }
      await _load(); // recharge la liste
    } catch (e) {
      setState(() => _error = 'Erreur lors de la purge : $e');
    } finally {
      if (mounted) setState(() => _purging = false);
    }
  }

  String _fmtDate(DateTime? dt) {
    if (dt == null) return '—';
    final l = dt.toLocal();
    return '${l.day.toString().padLeft(2, '0')}/${l.month.toString().padLeft(2, '0')}/${l.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AdminColors.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: AdminColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.badge_outlined, color: AdminColors.textSecondary, size: 15),
          const SizedBox(width: 8),
          const Text('Rides par identité', style: TextStyle(color: AdminColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
          const Spacer(),
          TextButton.icon(
            onPressed: _loading ? null : _load,
            icon: _loading
                ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: AdminColors.accent))
                : const Icon(Icons.refresh, size: 14, color: AdminColors.textSecondary),
            label: Text(_loaded ? 'Recharger' : 'Charger', style: const TextStyle(color: AdminColors.textSecondary, fontSize: 12)),
          ),
        ]),
        const SizedBox(height: 4),
        const Text(
          'Chaque réinstall de l\'app mobile crée une nouvelle identité anonyme. '
          'Les rides des anciennes identités sont orphelins : coche-les pour les purger entièrement.',
          style: TextStyle(color: AdminColors.textSecondary, fontSize: 12, height: 1.5),
        ),

        if (_error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AdminColors.dangerDim, borderRadius: BorderRadius.circular(8), border: Border.all(color: AdminColors.danger, width: 0.5)),
            child: Row(children: [
              const Icon(Icons.error_outline, color: AdminColors.danger, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(_error!, style: const TextStyle(color: AdminColors.danger, fontSize: 13))),
            ]),
          ),
        ],

        if (_loaded && _identities.isNotEmpty) ...[
          const SizedBox(height: 14),
          const Row(children: [
            SizedBox(width: 34),
            Expanded(flex: 3, child: Text('Identité (user_id)', style: TextStyle(color: AdminColors.textSecondary, fontSize: 11, fontWeight: FontWeight.w600))),
            SizedBox(width: 54, child: Text('Rides', style: TextStyle(color: AdminColors.textSecondary, fontSize: 11, fontWeight: FontWeight.w600))),
            SizedBox(width: 54, child: Text('Photos', style: TextStyle(color: AdminColors.textSecondary, fontSize: 11, fontWeight: FontWeight.w600))),
            Expanded(flex: 3, child: Text('Période', style: TextStyle(color: AdminColors.textSecondary, fontSize: 11, fontWeight: FontWeight.w600))),
          ]),
          const SizedBox(height: 6),
          const Divider(color: AdminColors.border, height: 1),
          ..._identities.map((id) {
            final sel = _selected.contains(id.userId);
            return InkWell(
              onTap: () => setState(() => sel ? _selected.remove(id.userId) : _selected.add(id.userId)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  SizedBox(width: 34, child: Icon(sel ? Icons.check_box : Icons.check_box_outline_blank, size: 18, color: sel ? AdminColors.accent : AdminColors.textSecondary)),
                  Expanded(flex: 3, child: Text('${id.userId.length >= 8 ? id.userId.substring(0, 8) : id.userId}…', style: const TextStyle(color: AdminColors.textPrimary, fontSize: 12, fontFamily: 'monospace'))),
                  SizedBox(width: 54, child: Text('${id.rides}', style: const TextStyle(color: AdminColors.textPrimary, fontSize: 12))),
                  SizedBox(width: 54, child: Text('${id.photos}', style: const TextStyle(color: AdminColors.textSecondary, fontSize: 12))),
                  Expanded(flex: 3, child: Text('${_fmtDate(id.first)} → ${_fmtDate(id.last)}', style: const TextStyle(color: AdminColors.textSecondary, fontSize: 11))),
                ]),
              ),
            );
          }),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: Text('${_identities.length} identité(s) · ${_identities.fold(0, (s, i) => s + i.rides)} rides au total',
                style: const TextStyle(color: AdminColors.textSecondary, fontSize: 12))),
            const SizedBox(width: 10),
            ElevatedButton.icon(
              onPressed: (_purging || _selected.isEmpty) ? null : _purge,
              style: ElevatedButton.styleFrom(
                backgroundColor: AdminColors.danger, foregroundColor: Colors.white,
                disabledBackgroundColor: AdminColors.border, disabledForegroundColor: AdminColors.textSecondary,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: _purging
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.delete_outline, size: 16),
              label: Text(
                _selected.isEmpty ? 'Purger la sélection' : 'Purger ${_selected.length} identité(s) · $_selectedRides rides',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ]),
        ],

        if (_loaded && _identities.isEmpty) ...[
          const SizedBox(height: 12),
          const Text('Aucun ride en base.', style: TextStyle(color: AdminColors.textSecondary, fontSize: 13)),
        ],
      ]),
    );
  }
}

// ── Sessions sans propriétaire ───────────────────────────────────────────────
// Anciennes sessions terminées dont `user_id` est NULL (créées avant que l'app
// mobile ne renseigne l'identité sur les sessions). Elles échappent à la purge
// par identité (pas de user_id à matcher) ET à la détection de fantômes (elles
// sont `finished`). Ce panneau les supprime + leurs positions GPS.

class _NullSessionsPanel extends StatefulWidget {
  const _NullSessionsPanel();
  @override
  State<_NullSessionsPanel> createState() => _NullSessionsPanelState();
}

class _NullSessionsPanelState extends State<_NullSessionsPanel> {
  bool _loading = false;
  bool _loaded = false;
  bool _purging = false;
  String? _error;
  int _sessionCount = 0;
  int _positionCount = 0;
  List<String> _sessionIds = [];

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      if (!await AuthService.isServerAdmin()) {
        setState(() => _error = _kNotAdminError);
        return;
      }
      final supabase = Supabase.instance.client;
      final sessions = await _fetchAllPages((f, t) =>
          supabase.from('safety_sessions').select('id').isFilter('user_id', null).range(f, t));
      final ids = sessions.map((s) => s['id'] as String).toList();
      var posCount = 0;
      for (var i = 0; i < ids.length; i += _kInChunk) {
        final end = (i + _kInChunk < ids.length) ? i + _kInChunk : ids.length;
        final res = await supabase
            .from('safety_positions')
            .select('id')
            .inFilter('session_id', ids.sublist(i, end))
            .count(CountOption.exact);
        posCount += res.count;
      }
      setState(() {
        _sessionIds = ids;
        _sessionCount = ids.length;
        _positionCount = posCount;
        _loaded = true;
      });
    } catch (e) {
      setState(() => _error = 'Erreur de chargement : $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _purge() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AdminColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: AdminColors.border)),
        title: const Row(children: [
          Icon(Icons.warning_amber, color: AdminColors.danger, size: 20),
          SizedBox(width: 10),
          Expanded(child: Text('Supprimer ces sessions ?', style: TextStyle(color: AdminColors.textPrimary, fontSize: 16))),
        ]),
        content: Text(
          '$_sessionCount session(s) sans propriétaire et leurs $_positionCount position(s) GPS '
          'seront supprimées DÉFINITIVEMENT.',
          style: const TextStyle(color: AdminColors.textSecondary, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler', style: TextStyle(color: AdminColors.textSecondary))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AdminColors.danger, foregroundColor: Colors.white),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() { _purging = true; _error = null; });
    try {
      final supabase = Supabase.instance.client;
      // 1. Positions rattachées (contrainte FK) — par lots pour éviter une
      //    liste d'IDs trop longue dans le filtre.
      for (var i = 0; i < _sessionIds.length; i += _kInChunk) {
        final end = (i + _kInChunk < _sessionIds.length) ? i + _kInChunk : _sessionIds.length;
        await supabase.from('safety_positions').delete()
            .inFilter('session_id', _sessionIds.sublist(i, end));
      }
      // 2. Sessions à user_id NULL.
      final deleted = await supabase.from('safety_sessions').delete().isFilter('user_id', null).select('id');
      final n = (deleted as List).length;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$n session(s) sans propriétaire supprimée(s) ✓'),
          backgroundColor: AdminColors.accent, behavior: SnackBarBehavior.floating,
        ));
      }
      await _load();
    } catch (e) {
      setState(() => _error = 'Erreur lors de la purge : $e');
    } finally {
      if (mounted) setState(() => _purging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AdminColors.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: AdminColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.link_off, color: AdminColors.textSecondary, size: 15),
          const SizedBox(width: 8),
          const Text('Sessions sans propriétaire', style: TextStyle(color: AdminColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
          const Spacer(),
          TextButton.icon(
            onPressed: _loading ? null : _load,
            icon: _loading
                ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: AdminColors.accent))
                : const Icon(Icons.refresh, size: 14, color: AdminColors.textSecondary),
            label: Text(_loaded ? 'Recharger' : 'Analyser', style: const TextStyle(color: AdminColors.textSecondary, fontSize: 12)),
          ),
        ]),
        const SizedBox(height: 4),
        const Text(
          'Anciennes sessions terminées à `user_id` NULL (d\'avant le suivi d\'identité). '
          'Ni la purge par identité ni la détection de fantômes ne les couvrent.',
          style: TextStyle(color: AdminColors.textSecondary, fontSize: 12, height: 1.5),
        ),

        if (_error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AdminColors.dangerDim, borderRadius: BorderRadius.circular(8), border: Border.all(color: AdminColors.danger, width: 0.5)),
            child: Row(children: [
              const Icon(Icons.error_outline, color: AdminColors.danger, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(_error!, style: const TextStyle(color: AdminColors.danger, fontSize: 13))),
            ]),
          ),
        ],

        if (_loaded) ...[
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: Text(
              _sessionCount == 0
                  ? 'Aucune session sans propriétaire — rien à nettoyer ✓'
                  : '$_sessionCount session(s) · $_positionCount position(s) GPS',
              style: TextStyle(color: _sessionCount == 0 ? AdminColors.accent : AdminColors.textPrimary, fontSize: 13),
            )),
            const SizedBox(width: 10),
            if (_sessionCount > 0)
              ElevatedButton.icon(
                onPressed: _purging ? null : _purge,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AdminColors.danger, foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: _purging
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.delete_outline, size: 16),
                label: const Text('Purger', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
          ]),
        ],
      ]),
    );
  }
}