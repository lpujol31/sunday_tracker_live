/* eslint-disable */
// Garde-fou pre-deploiement, lance automatiquement avant chaque "firebase deploy"
// (branche via "predeploy" dans firebase.json). Il fait deux choses :
//
//  1. VALIDE le build : refuse de deployer un build web Flutter incomplet
//     (assets/ vide, manifest manquant...) qui provoquerait une page blanche.
//
//  2. NEUTRALISE le service worker : l'app est 100% en ligne et n'utilise plus
//     de SW (build --pwa-strategy=none genere un flutter_service_worker.js vide).
//     On le remplace par un SW "auto-destructeur" : quand le navigateur d'un
//     utilisateur encore coince sur un ancien SW re-verifie ce fichier (il est
//     en no-cache), ce nouveau SW s'active immediatement, vide les caches, se
//     desinscrit et recharge la page -> l'utilisateur est debloque sans aucune
//     manip. Les nouveaux visiteurs n'enregistrent aucun SW (loader.load() est
//     appele sans serviceWorkerSettings), donc ce fichier ne leur sert jamais.

const fs = require('fs');
const path = require('path');

const webDir = path.join(__dirname, '..', 'build', 'web');

// Fichiers indispensables. NB: pas de flutter_service_worker.js (build --pwa-strategy=none).
const required = [
  'index.html',
  'main.dart.js',
  'flutter_bootstrap.js',
  'flutter.js',
  'manifest.json',
  'version.json',
  'assets/AssetManifest.bin.json',
  'assets/FontManifest.json',
];

const MIN_FILES = 25; // un build sain en contient ~40

if (!fs.existsSync(webDir)) {
  console.error('\n[check_build] ERREUR: build/web introuvable. Lance "flutter build web --pwa-strategy=none" d\'abord.\n');
  process.exit(1);
}

const missing = required.filter((f) => !fs.existsSync(path.join(webDir, f.split('/').join(path.sep))));

function countFiles(dir) {
  let n = 0;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) n += countFiles(path.join(dir, e.name));
    else n++;
  }
  return n;
}
const total = countFiles(webDir);

if (missing.length || total < MIN_FILES) {
  console.error('\n[check_build] ❌ Build web INCOMPLET — deploiement BLOQUE.');
  if (missing.length) console.error('   Fichiers critiques manquants: ' + missing.join(', '));
  if (total < MIN_FILES) console.error('   Seulement ' + total + ' fichiers (attendu >= ' + MIN_FILES + ').');
  console.error('   -> Corrige avec: flutter clean && flutter build web --pwa-strategy=none\n');
  process.exit(1);
}

// --- Installe le service worker auto-destructeur (migration hors-SW) ---
const selfDestroyingSW = `// Service worker auto-destructeur (genere par scripts/check_build.js).
// Sunday Tracker Live n'utilise plus de service worker. Ce fichier sert uniquement
// a debloquer les utilisateurs encore controles par un ancien SW : il s'active
// aussitot, vide les caches, se desinscrit et recharge les onglets ouverts.
self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (event) {
  event.waitUntil((async function () {
    try {
      const keys = await caches.keys();
      await Promise.all(keys.map(function (k) { return caches.delete(k); }));
    } catch (e) {}
    try { await self.registration.unregister(); } catch (e) {}
    try {
      const clients = await self.clients.matchAll({ type: 'window' });
      clients.forEach(function (c) { c.navigate(c.url); });
    } catch (e) {}
  })());
});
`;
fs.writeFileSync(path.join(webDir, 'flutter_service_worker.js'), selfDestroyingSW);

// --- Cache-busting des fichiers d'entree a nom fixe ---
// main.dart.js et flutter_bootstrap.js ont un nom fixe. Sans SW, un navigateur
// qui les a un jour mis en cache "immutable" (ancien bug d'en-tetes) les garde
// epingles jusqu'a 1 an et ne verrait jamais une mise a jour. En ajoutant
// ?v=<build> (change a chaque build), l'URL change -> le navigateur est force de
// re-telecharger, ce qui debloque automatiquement les utilisateurs coinces.
// index.html est toujours en no-cache, donc il porte toujours la derniere valeur.
let cacheBust = 'dev';
try {
  const version = JSON.parse(fs.readFileSync(path.join(webDir, 'version.json'), 'utf8'));
  cacheBust = String(version.build_number || version.version || Date.now());
} catch (e) { cacheBust = String(Date.now()); }

const indexPath = path.join(webDir, 'index.html');
let indexHtml = fs.readFileSync(indexPath, 'utf8');
indexHtml = indexHtml.replace(
  /src="flutter_bootstrap\.js(?:\?v=[^"]*)?"/,
  'src="flutter_bootstrap.js?v=' + cacheBust + '"'
);
fs.writeFileSync(indexPath, indexHtml);

const bootstrapPath = path.join(webDir, 'flutter_bootstrap.js');
let bootstrap = fs.readFileSync(bootstrapPath, 'utf8');
bootstrap = bootstrap.replace(
  /"mainJsPath":"main\.dart\.js(?:\?v=[^"]*)?"/,
  '"mainJsPath":"main.dart.js?v=' + cacheBust + '"'
);
fs.writeFileSync(bootstrapPath, bootstrap);

console.log('[check_build] ✅ Build web OK (' + total + ' fichiers). SW auto-destructeur + cache-busting v=' + cacheBust + ' installes.');
