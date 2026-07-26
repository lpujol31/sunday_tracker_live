// Nature des points de passage : l'enum, le rendu de pastille et la règle de
// masquage des pauses auto courtes vivent dans le package partagé `sunday_core`
// (source unique avec l'app mobile). Ne reste ici que l'extraction des champs
// depuis un checkpoint live, dont la forme (`comment` / `created_at`) diffère de
// celle du mobile (`note` / `timestamp`).
import 'package:sunday_core/waypoint_kind.dart';
export 'package:sunday_core/waypoint_kind.dart';

/// Nature d'un checkpoint live parsé (depuis `safety_sessions.ride_json`).
WaypointKind waypointKindOf(Map cp) =>
    waypointKindFromFields(kind: cp['kind'], note: cp['comment']?.toString());

/// Durée d'une pause auto live : `resumedAt − created_at`.
Duration? autoPauseDuration(Map cp) => autoPauseDurationFromFields(
      start: cp['created_at']?.toString(),
      end: cp['resumedAt']?.toString(),
    );

/// Vrai si [cp] est une pause auto assez brève pour être masquée sur la carte.
bool isShortAutoPause(Map cp,
        {Duration threshold = kShortAutoPauseHideThreshold}) =>
    isShortAutoPauseFromFields(
      kind: cp['kind'],
      note: cp['comment']?.toString(),
      start: cp['created_at']?.toString(),
      end: cp['resumedAt']?.toString(),
      threshold: threshold,
    );
