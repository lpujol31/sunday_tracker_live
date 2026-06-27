import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../../core/theme/admin_theme.dart';
import '../../../core/auth/auth_service.dart';

class AdminSidebar extends StatefulWidget {
  final String activeSection;
  final ValueChanged<String> onSectionChanged;
  const AdminSidebar({super.key, required this.activeSection, required this.onSectionChanged});

  @override
  State<AdminSidebar> createState() => _AdminSidebarState();
}

class _AdminSidebarState extends State<AdminSidebar> {
  static const _items = [
    _NavItem('cleanup', Icons.delete_sweep_outlined, 'Nettoyage'),
    _NavItem('users',   Icons.people_outline,        'Utilisateurs'),
    _NavItem('jobs',    Icons.terminal_outlined,      'Jobs'),
    _NavItem('logs',    Icons.receipt_long_outlined,  'Logs'),
  ];

  String? _version;
  String? _buildNumber;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      final raw = info.buildNumber;
      final formatted = raw.length == 10
          ? '${raw.substring(0, 8)}.${raw.substring(8)}'
          : raw;
      setState(() { _version = info.version; _buildNumber = formatted; });
    }).catchError((_) {
      if (mounted) setState(() { _version = '—'; _buildNumber = ''; });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      decoration: const BoxDecoration(color: AdminColors.surface, border: Border(right: BorderSide(color: AdminColors.border))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(width: 8, height: 8, decoration: const BoxDecoration(color: AdminColors.accent, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              const Text('SUNDAY TRACKER', style: TextStyle(color: AdminColors.textSecondary, fontSize: 10, letterSpacing: 1.8, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 4),
            const Text('Admin', style: TextStyle(color: AdminColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.5)),
          ]),
        ),
        const Divider(color: AdminColors.border, height: 1),
        const SizedBox(height: 12),
        ..._items.map((item) => _SidebarTile(item: item, isActive: widget.activeSection == item.id, onTap: () => widget.onSectionChanged(item.id))),
        const Spacer(),
        if (_version != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              _buildNumber != null && _buildNumber!.isNotEmpty
                  ? 'v$_version\nbuild $_buildNumber'
                  : 'v$_version',
              style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 11, letterSpacing: 0.2, height: 1.5),
            ),
          ),
        const Divider(color: AdminColors.border, height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: _SidebarTile(
            item: const _NavItem('logout', Icons.logout, 'Déconnexion'),
            isActive: false, isDanger: true,
            onTap: () async => AuthService.signOut(),
          ),
        ),
      ]),
    );
  }
}

class _NavItem {
  final String id; final IconData icon; final String label;
  const _NavItem(this.id, this.icon, this.label);
}

class _SidebarTile extends StatefulWidget {
  final _NavItem item; final bool isActive; final VoidCallback onTap; final bool isDanger;
  const _SidebarTile({required this.item, required this.isActive, required this.onTap, this.isDanger = false});
  @override
  State<_SidebarTile> createState() => _SidebarTileState();
}

class _SidebarTileState extends State<_SidebarTile> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    final color = widget.isDanger ? AdminColors.danger
        : widget.isActive ? AdminColors.accent
        : _hovered ? AdminColors.textPrimary
        : AdminColors.textSecondary;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.isActive ? AdminColors.accentDim : _hovered ? AdminColors.surfaceHover : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            Icon(widget.item.icon, size: 17, color: color),
            const SizedBox(width: 10),
            Text(widget.item.label, style: TextStyle(color: color, fontSize: 13, fontWeight: widget.isActive ? FontWeight.w600 : FontWeight.w400)),
            if (widget.isActive) ...[const Spacer(), Container(width: 4, height: 4, decoration: const BoxDecoration(color: AdminColors.accent, shape: BoxShape.circle))],
          ]),
        ),
      ),
    );
  }
}
