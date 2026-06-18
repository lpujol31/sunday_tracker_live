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
  // ── Filtres ────────────────────────────────────────────────────────────────
  String _selectedTable = 'safety_positions';
  String _selectedStatus = 'Tous les statuts';

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
  double _estimatedMb = 0;
  final List<_PreviewRow> _previewRows = [];

  // Détail des sessions fantômes récupérées depuis Supabase
  final List<Map<String, dynamic>> _ghostDetails = [];

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

      final estimatedBytes = orphanCount * 200 + allGhosts.length * 500;

      setState(() {
        _orphanPositions = orphanCount;
        _ghostSessions = allGhosts.length;
        _estimatedMb = estimatedBytes / (1024 * 1024);
        _ghostDetails
          ..clear()
          ..addAll(allGhosts);
        _previewRows
          ..clear()
          ..addAll([
            if (orphanCount > 0)
              _PreviewRow('safety_positions sans session (session_id introuvable)', orphanCount),
            if (ghostInProgressList.isNotEmpty)
              _PreviewRow('safety_sessions statut in_progress > 48h', ghostInProgressList.length),
            if (ghostPausedList.isNotEmpty)
              _PreviewRow('safety_sessions statut paused > 7 jours', ghostPausedList.length),
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
      await supabase.from('safety_sessions').delete()
          .isFilter('ended_at', null).eq('status', 'in_progress')
          .lt('started_at', cutoff48h.toIso8601String());

      await supabase.from('safety_sessions').delete()
          .isFilter('ended_at', null).eq('status', 'paused')
          .lt('started_at', cutoff7d.toIso8601String());

      setState(() {
        _orphanPositions = 0; _ghostSessions = 0; _estimatedMb = 0;
        _previewRows.clear(); _ghostDetails.clear(); _analyzed = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Purge effectuée avec succès ✓'),
          backgroundColor: AdminColors.accent,
          behavior: SnackBarBehavior.floating,
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

        // Dropdowns
        _Dropdown(value: _selectedTable,
            items: const ['safety_positions', 'safety_sessions', 'Toutes les tables'],
            onChanged: (v) => setState(() => _selectedTable = v)),
        const SizedBox(height: 10),
        _Dropdown(value: _selectedStatus,
            items: const ['Tous les statuts', 'in_progress', 'paused', 'finished'],
            onChanged: (v) => setState(() => _selectedStatus = v)),
        const SizedBox(height: 10),

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
              _ThresholdStepper(
                value: _thresholdInProgressHours,
                unit: 'heures',
                min: 1,
                max: 720,
                onChanged: (v) => setState(() => _thresholdInProgressHours = v),
              ),
            ]),
            const SizedBox(height: 12),

            // paused
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
              _ThresholdStepper(
                value: _thresholdPausedDays,
                unit: 'jours',
                min: 1,
                max: 90,
                onChanged: (v) => setState(() => _thresholdPausedDays = v),
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
              label: 'Espace libérable',
              value: _estimatedMb < 0.1 ? '< 0.1 Mo' : '~${_estimatedMb.toStringAsFixed(1)} Mo',
              sub: 'estimé (~200o/position, ~500o/session)',
              valueColor: AdminColors.textPrimary,
              tooltip: 'Estimation basée sur :\n~200 octets par position GPS\n~500 octets par session',
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

class _Dropdown extends StatelessWidget {
  final String value;
  final List<String> items;
  final ValueChanged<String> onChanged;
  const _Dropdown({required this.value, required this.items, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      decoration: BoxDecoration(color: AdminColors.surface,
          borderRadius: BorderRadius.circular(8), border: Border.all(color: AdminColors.border)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value, dropdownColor: AdminColors.surface,
          iconEnabledColor: AdminColors.textSecondary,
          style: const TextStyle(color: AdminColors.textPrimary, fontSize: 13),
          isExpanded: true,
          items: items.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
          onChanged: (v) { if (v != null) onChanged(v); },
        ),
      ),
    );
  }
}

class _ThresholdStepper extends StatelessWidget {
  final int value;
  final String unit;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  const _ThresholdStepper({
    required this.value, required this.unit,
    required this.min, required this.max, required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _StepBtn(
        icon: Icons.remove,
        onTap: value > min ? () => onChanged(value - 1) : null,
      ),
      Container(
        width: 44,
        height: 30,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          border: Border.symmetric(
            horizontal: BorderSide(color: AdminColors.border),
          ),
        ),
        child: Text('$value',
            style: const TextStyle(color: AdminColors.textPrimary, fontSize: 13)),
      ),
      _StepBtn(
        icon: Icons.add,
        onTap: value < max ? () => onChanged(value + 1) : null,
      ),
      const SizedBox(width: 6),
      Text(unit, style: const TextStyle(color: AdminColors.textSecondary, fontSize: 12)),
    ]);
  }
}

class _StepBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _StepBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: AdminColors.surface,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AdminColors.border),
        ),
        child: Icon(icon,
            size: 14,
            color: onTap != null ? AdminColors.textPrimary : AdminColors.textSecondary),
      ),
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