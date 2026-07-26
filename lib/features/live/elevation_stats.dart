// Calcul du dénivelé (D+) : la logique vit désormais dans le package partagé
// `sunday_core`, commune au viewer live et à l'app mobile. Ce fichier n'est plus
// qu'un ré-export, conservé pour ne pas toucher aux imports existants.
export 'package:sunday_core/elevation_stats.dart';
