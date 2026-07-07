# sunday_tracker_live

L'application Web affiche en temps réel sur une carte (OpenStreetMap/satellite & topo) la dernière position connue
et tracé GPS d'un pratiquant outdoor participants à une pratique en outdoor (vtt, cyclo, trail, enduro, promenade...) événement ou une ballade dominicale (outdoor) sportif dominical, alimentée par Supabase comme backend live. 

Ce tracé est partagé au départ par le participant 

## Déploiment auto
.\deploy.ps1
.\deploy.ps1 -NoBump → redéploie sans changer le numéro de version.

## Déploiment manuel
flutter clean
flutter pub get
flutter build web --release
flutter build web --release --no-wasm-dry-run
firebase deploy

flutter run -d chrome

## Debug si cache corrompu
flutter clean && flutter pub get && flutter build web --release --no-wasm-dry-run

## Stack
### Github
https://github.com/lpujol31/sunday_tracker_live
git add .
git commit -m "1.1.0+2026070502"
git push

### Firebase
https://console.firebase.google.com/project/sunday-tracker-live/overview

https://sunday-tracker-live.web.app
https://sunday-tracker-live.web.app/?code=coyj4tos

## Backlog
### BUGS
03/06/2026
Traces jogging llanca, je ne sais pas pourquoi il m'a enregistré que 2 positions uniques
Nb positions : 205
Nb positions uniques : 2

### v1
~~Version & date~~
~~Statut (En cours, en pause, terminé) / jolies icones~~
~~Dégradé de coulur pour voir les 5/10 dernières positions~~
Trace complète (idem sunday tracker)
Désactiver clignotement
Icones

### v1.1
Zoom/dézoom
Icone
Tracé, flèches (sens)

