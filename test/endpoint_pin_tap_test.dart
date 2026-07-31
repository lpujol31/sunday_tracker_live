import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// La pastille Départ tombe presque toujours dans la bande haute de la carte,
/// sous le voile dégradé de l'en-tête. Or un `Container` décoré est
/// hit-testable (`RenderDecoratedBox.hitTestSelf` interroge le `BoxDecoration`,
/// qui répond vrai dans tout son rectangle) : posé tel quel au-dessus de la
/// carte, le voile avale les clics sur les markers.
///
/// D'où le motif retenu dans `_buildTopOverlay` / `_buildMobileTopOverlay` :
/// voile décoratif isolé dans un `IgnorePointer`, contenu de l'en-tête à côté.
const _pinKey = Key('pin');

Widget _scrim() => Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.55), Colors.transparent],
        ),
      ),
    );

/// Reproduit la page : carte plein écran + marker dans la bande haute, en-tête
/// par-dessus. Renvoie `true` si le marker a bien reçu le clic.
Future<bool> _markerReceivesTap(WidgetTester tester, Widget header) async {
  var tapped = false;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Stack(fit: StackFit.expand, children: [
        FlutterMap(
          options: const MapOptions(initialCenter: LatLng(43.0, 1.6), initialZoom: 13),
          children: [
            MarkerLayer(markers: [
              Marker(
                // ≈ 370 px au-dessus du centre : dans la bande de l'en-tête.
                point: const LatLng(43.0465, 1.6),
                width: 44, height: 44,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => tapped = true,
                  child: const SizedBox.expand(key: _pinKey),
                ),
              ),
            ]),
          ],
        ),
        Positioned(top: 0, left: 0, right: 0, child: header),
      ]),
    ),
  ));
  await tester.pumpAndSettle();
  final pin = tester.renderObject<RenderBox>(find.byKey(_pinKey));
  await tester.tapAt(pin.localToGlobal(pin.size.center(Offset.zero)));
  await tester.pump();
  return tapped;
}

void main() {
  testWidgets('l\'en-tête ne mange pas les clics sur les markers', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Le piège : voile et contenu dans un seul Container décoré.
    final naif = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.55), Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 40),
      child: const Row(children: [Text('Sunday Tracker Live'), Spacer()]),
    );
    expect(await _markerReceivesTap(tester, naif), isFalse,
        reason: 'témoin : un en-tête décoré d\'un seul bloc capte bien le clic');

    // Le motif de la page live.
    final corrige = Stack(children: [
      Positioned.fill(child: IgnorePointer(child: _scrim())),
      const Padding(
        padding: EdgeInsets.fromLTRB(24, 18, 24, 40),
        child: Row(children: [Text('Sunday Tracker Live'), Spacer()]),
      ),
    ]);
    expect(await _markerReceivesTap(tester, corrige), isTrue,
        reason: 'le voile est décoratif : il doit laisser passer les clics carte');
  });
}
