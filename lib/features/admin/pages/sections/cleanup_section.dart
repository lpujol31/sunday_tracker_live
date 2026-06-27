// lib/features/admin/pages/sections/cleanup_section.dart
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart'; // DateFormat utilisé dans _exportCsv et _fmtDate
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../core/theme/admin_theme.dart';

class CleanupSection extends StatefulWidget {
  const CleanupSection({super.key});
  @override
  State<CleanupSection> createState() => _CleanupSectionState();
}

class _CleanupSectionState extends State<CleanupSection> {
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
  double _estimatedMb = 0;
  final List<_PreviewRow> _previewRows = [];

  // Détail des sessions fantômes récupérées depuis Supabase
  final List<Map<String, dynamic>> _ghostDetails = [];

  // IDs de sessions référencées dans rides mais inexistantes dans safety_sessions
  final List<String> _orphanRideSessionIds = [];

  // ── Analyse ────────────────────────────────────────────────────────────────
  Future<void> _analyze() async {
    setState(() { _analyzing = true; _analyzed = false; _error = null; _ghostDetails.clear(); });

    try {
      final supabase = Supabase.instance.client;
      final cutoff48h = DateTime.now().subtract(Duration(hours: _thresholdInProgressHours));
      final cutoff7d  = DateTime.now().subtract(Duration(days: _thresholdPausedDays));

      // 1. Positions orphelines
      final allPositionSessionIds = await supabase
          .from('safety_positions')
          .select('session_id');

      final sessionIds = (allPositionSessionIds as List)
          .map((r) => r['session_id'] as String?)
          .whereType<String>()
          .toSet()
          .toList();

      int orphanCount = 0;
      if (sessionIds.isNotEmpty) {
        final validSessions = await supabase
            .from('safety_sessions')
            .select('id')
            .inFilter('id', sessionIds);
        final validIds = (validSessions as List).map((r) => r['id'] as String).toSet();
        final orphanSessionIds = sessionIds.where((id) => !validIds.contains(id)).toList();
        if (orphanSessionIds.isNotEmpty) {
          final orphanResult = await supabase
              .from('safety_positions')
              .select('id')
              .inFilter('session_id', orphanSessionIds)
              .count(CountOption.exact);
          orphanCount = orphanResult.count;
        }
      }

      // 2. Sessions fantômes in_progress > 48h — avec détails
      final ghostInProgressRows = await supabase
          .from('safety_sessions')
          .select('id, share_code, started_at, status')
          .isFilter('ended_at', null)
          .eq('status', 'in_progress')
          .lt('started_at', cutoff48h.toIso8601String())
          .order('started_at', ascending: false);

      // 3. Sessions fantômes paused > 7j — avec détails
      final ghostPausedRows = await supabase
          .from('safety_sessions')
          .select('id, share_code, started_at, status')
          .isFilter('ended_at', null)
          .eq('status', 'paused')
          .lt('started_at', cutoff7d.toIso8601String())
          .order('started_at', ascending: false);

      final ghostInProgressList = List<Map<String, dynamic>>.from(ghostInProgressRows);
      final ghostPausedList = List<Map<String, dynamic>>.from(ghostPausedRows);
      final allGhosts = [...ghostInProgressList, ...ghostPausedList];

      // 4. Rides avec safetySessionId inexistant dans safety_sessions
      final ridesData = await supabase.from('rides').select('ride_json');
      final allRidesJson = List<Map<String, dynamic>>.from(ridesData);
      final rideSessionRefs = allRidesJson
          .map((r) => (r['ride_json'] as Map?)?['safetySessionId'] as String?)
          .whereType<String>()
          .toSet()
          .toList();

      final deadRideSessionIds = <String>[];
      if (rideSessionRefs.isNotEmpty) {
        final existingSessions = await supabase
            .from('safety_sessions')
            .select('id')
            .inFilter('id', rideSessionRefs);
        final existingIds = (existingSessions as List).map((r) => r['id'] as String).toSet();
        deadRideSessionIds.addAll(rideSessionRefs.where((ref) => !existingIds.contains(ref)));
      }

      final estimatedBytes = orphanCount * 200 + allGhosts.length * 500 + deadRideSessionIds.length * 5000;

      setState(() {
        _orphanPositions = orphanCount;
        _ghostSessions = allGhosts.length;
        _orphanRides = deadRideSessionIds.length;
        _estimatedMb = estimatedBytes / (1024 * 1024);
        _ghostDetails
          ..clear()
          ..addAll(allGhosts);
        _orphanRideSessionIds
          ..clear()
          ..addAll(deadRideSessionIds);
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
              _PreviewRow('rides avec safetySessionId introuvable', deadRideSessionIds.length),
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
      builder: (_) => _ConfirmDialog(total: _totalRows),
    );
    if (confirmed != true) return;

    setState(() { _purging = true; _error = null; });
    try {
      final supabase = Supabase.instance.client;
      final cutoff48h = DateTime.now().subtract(Duration(hours: _thresholdInProgressHours));
      final cutoff7d  = DateTime.now().subtract(Duration(days: _thresholdPausedDays));

      // Récupère les IDs des sessions fantômes à supprimer
      final ghostIds = _ghostDetails.map((s) => s['id'] as String).toList();

      // ÉTAPE 0 — Supprimer les rides liés à des sessions fantômes ou à des sessions mortes
      final allDeadSessionIds = {...ghostIds, ..._orphanRideSessionIds};
      if (allDeadSessionIds.isNotEmpty) {
        final ridesData = await supabase.from('rides').select('ride_json, user_id, started_at');
        for (final r in (ridesData as List)) {
          final sessionId = (r['ride_json'] as Map?)?['safetySessionId'] as String?;
          if (sessionId != null && allDeadSessionIds.contains(sessionId)) {
            await supabase.from('rides').delete()
                .eq('user_id', r['user_id'] as String)
                .eq('started_at', r['started_at'] as String);
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

      // ÉTAPE 2 — Supprimer les positions orphelines (sans session du tout)
      if (_orphanPositions > 0) {
        final validSessions = await supabase.from('safety_sessions').select('id');
        final validIds = (validSessions as List).map((r) => r['id'] as String).toList();
        if (validIds.isNotEmpty) {
          await supabase.from('safety_positions').delete()
              .not('session_id', 'in', '(${validIds.map((id) => '"$id"').join(',')})');
        } else {
          await supabase.from('safety_positions').delete().neq('id', 0);
        }
      }

      // ÉTAPE 3 — Supprimer les sessions fantômes (maintenant sans positions)
      final deletedInProgress = await supabase.from('safety_sessions')
          .delete()
          .isFilter('ended_at', null).eq('status', 'in_progress')
          .lt('started_at', cutoff48h.toIso8601String())
          .select('id');

      final deletedPaused = await supabase.from('safety_sessions')
          .delete()
          .isFilter('ended_at', null).eq('status', 'paused')
          .lt('started_at', cutoff7d.toIso8601String())
          .select('id');

      final totalDeleted = (deletedInProgress as List).length + (deletedPaused as List).length;

      setState(() {
        _orphanPositions = 0; _ghostSessions = 0; _orphanRides = 0; _estimatedMb = 0;
        _previewRows.clear(); _ghostDetails.clear(); _orphanRideSessionIds.clear(); _analyzed = false;
      });

      if (mounted) {
        final msg = totalDeleted == 0
            ? 'Aucune ligne supprimée — vérifie les politiques RLS Supabase (DELETE sur safety_sessions)'
            : 'Purge effectuée : $totalDeleted session(s) supprimée(s) ✓';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          backgroundColor: totalDeleted == 0 ? AdminColors.warning : AdminColors.accent,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: totalDeleted == 0 ? 8 : 4),
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
              const Padding(
                padding: EdgeInsets.only(top: 5, left: 2),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 11, color: AdminColors.textSecondary),
                  SizedBox(width: 4),
                  Text('Valeur personnalisable',
                      style: TextStyle(color: AdminColors.textSecondary, fontSize: 11)),
                ]),
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
              const Padding(
                padding: EdgeInsets.only(top: 5, left: 2),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 11, color: AdminColors.textSecondary),
                  SizedBox(width: 4),
                  Text('Valeur personnalisable',
                      style: TextStyle(color: AdminColors.textSecondary, fontSize: 11)),
                ]),
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
              label: 'Rides incohérents',
              value: '$_orphanRides',
              sub: 'safetySessionId introuvable',
              valueColor: AdminColors.danger,
              tooltip: 'Entrées dans rides dont le champ\nride_json->safetySessionId pointe vers\nune session qui n\'existe plus.\nCes rides seront supprimés lors de la purge.',
            )),
            const SizedBox(width: 10),
            Expanded(child: _MetricCard(
              label: 'Espace libérable',
              value: _estimatedMb < 0.1 ? '< 0.1 Mo' : '~${_estimatedMb.toStringAsFixed(1)} Mo',
              sub: 'estimé (~200o/pos, ~500o/session, ~5ko/ride)',
              valueColor: AdminColors.textPrimary,
              tooltip: 'Estimation basée sur :\n~200 octets par position GPS\n~500 octets par session\n~5 000 octets par ride',
            )),
          ]),

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
    _ctrl.dispose();
    super.dispose();
  }

  void _onTextChanged(String text) {
    final v = int.tryParse(text);
    if (v == null || v < 1) return;
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
  const _ConfirmDialog({required this.total});

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
      content: RichText(text: TextSpan(
        style: const TextStyle(color: AdminColors.textSecondary, fontSize: 13, height: 1.6),
        children: [
          TextSpan(text: '$total lignes',
              style: const TextStyle(color: AdminColors.danger, fontWeight: FontWeight.w600)),
          const TextSpan(text: ' seront supprimées définitivement de Supabase.\n\nCette action est irréversible.'),
        ],
      )),
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