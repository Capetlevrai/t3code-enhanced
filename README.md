# T3 Code Enhanced (Windows)

Outils, intégration Explorateur Windows ultra-rapide et optimisations de démarrage pour **T3 Code** (`pingdotgg/t3code`) sur Windows.

---

## Benchmarks réels (Avant / Après)

Mesures relevées sur Windows (`%LOCALAPPDATA%\t3code-context-menu\last-run.log`, `desktop.trace.ndjson`, `server.trace.ndjson`) :

| Scénario / Étape | Avant (VBS + `t3 app`) | Après (`open-in-t3code.exe` + optimisations) | Gain |
| --- | --- | --- | --- |
| **Warm start** (T3 Code ouvert → clic droit Explorateur) | **12,53 s** | **0,07 s** (60–76 ms, 33 ms interne) | **~170× plus rapide** |
| **Cold start complet** (T3 Code fermé → dossier ouvert) | **36–42 s** | **5,44 s** (6,27 s wall time, 1er essai IPC) | **~6,6–7,7× plus rapide** |
| Détection app fermée (Étape 1) | **~21 000 ms** (timeout `CLI_RESPONSE_TIMEOUT_MS`) | **14–33 ms** (`File.Exists` sur named pipe) | **~630× plus rapide** |
| Apparition du named pipe + backend local prêt | **~15–22 s** | **~4,22 s** (pipe `+0,91 s`, HTTP 200 `+4,22 s`) | **~3,5–5× plus rapide** |
| Logs `%USERPROFILE%\.t3\userdata\logs` | **131,9 Mo** (13 fichiers en rotation) | **~10 Mo** (**129,3 Mo** libérés) | **-92 %** |

---

## 1. Menu contextuel Windows (« Ouvrir dans T3 Code »)

Ajoute une entrée **Ouvrir dans T3 Code** (avec l'icône T3 Code) dans le clic droit de l'Explorateur Windows :
- Clic droit **sur un dossier** (`HKCU\Software\Classes\Directory\shell\T3CodeOpen`)
- Clic droit **dans le vide d'un dossier** (`HKCU\Software\Classes\Directory\Background\shell\T3CodeOpen`)
- Clic droit **sur un lecteur** (`HKCU\Software\Classes\Drive\shell\T3CodeOpen`)

> **Sans droits administrateur** (registre utilisateur `HKCU`). Sur Windows 11, l'entrée apparaît dans *Afficher plus d'options* (ou `Maj + Clic droit`).

### Architecture ultra-rapide (IPC direct sur named pipe)
- **Pourquoi l'ancienne méthode était lente :** lancer `ELECTRON_RUN_AS_NODE=1 "T3 Code (Beta).exe" "...\bin.mjs" app "<dossier>"` démarre le binaire Electron (~200 Mo) + charge `server.asar` à chaque clic droit (5 à 15 s même à chaud, et ~21 s de timeout à froid).
- **Nouveau lanceur natif [`open-in-t3code.cs`](open-in-t3code.cs)** compilé automatiquement en `open-in-t3code.exe` (~8 Ko, WinExe sans fenêtre console) par [`install.ps1`](install.ps1) via le compilateur `.NET Framework 4` intégré à Windows (`csc.exe`) :
  - Calcule le nom exact du named pipe de contrôle T3 Code : `\\.\pipe\t3code-app-<sha256_24(stateDir)>` (compatible `T3CODE_HOME` + fallback `dev`).
  - **À chaud (~70 ms) :** détecte le pipe en `< 20 ms` et envoie directement la requête JSON officielle `open-workspace` (protocole v1) via `NamedPipeClientStream`.
  - **À froid (~5,4 s) :** détecte l'absence du pipe en `~15–30 ms`, lance immédiatement `T3 Code (Beta).exe` (sans `ELECTRON_RUN_AS_NODE`), attend le pipe (`~0,9 s`) puis la disponibilité HTTP du backend local (`http://127.0.0.1:3773/.well-known/t3/environment`, `~3,3 s`) avant d'envoyer l'IPC au premier essai sans timeout interne.
  - Journalise chaque étape à la milliseconde dans `%LOCALAPPDATA%\t3code-context-menu\last-run.log`.
- **Fallback [`open-in-t3code.vbs`](open-in-t3code.vbs)** également optimisé (détection `fso.FileExists` du pipe en `0 ms` injectée par `install.ps1`) si `csc.exe` n'est pas présent.

### Installation / Désinstallation

```powershell
# Installer (compile open-in-t3code.exe + configure le registre HKCU)
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

# Désinstaller proprement (registre + dossier AppData)
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

---

## 2. Optimisation de T3 Code (`optimize-t3code.ps1`)

Le script [`optimize-t3code.ps1`](optimize-t3code.ps1) applique des optimisations sûres sans supprimer aucune donnée utilisateur :
1. **`enableProviderUpdateChecks: false`** dans `%USERPROFILE%\.t3\userdata\settings.json` (supprime les vérifications réseau de mises à jour providers au boot).
2. **Purge des logs en rotation** (`*.ndjson.1` .. `.10` dans `%USERPROFILE%\.t3\userdata\logs`) tout en conservant les traces actives.
3. **Maintenance SQLite** (`PRAGMA wal_checkpoint(TRUNCATE); PRAGMA optimize;` sur `statev2.sqlite` lorsque T3 Code est fermé).
4. **Mode instantané optionnel (`-EnableAutostart`)** : ajoute T3 Code au démarrage de session Windows (`HKCU\...\Run`, sans droits admin) pour bénéficier d'ouvertures à **~70 ms** en permanence.

```powershell
# Appliquer les optimisations locales (settings + logs + SQLite si T3 Code est fermé)
powershell -NoProfile -ExecutionPolicy Bypass -File .\optimize-t3code.ps1

# Optionnel : activer / désactiver le démarrage automatique avec Windows
powershell -NoProfile -ExecutionPolicy Bypass -File .\optimize-t3code.ps1 -EnableAutostart
powershell -NoProfile -ExecutionPolicy Bypass -File .\optimize-t3code.ps1 -DisableAutostart
```

---

## 3. Optimisation Windows Defender

Sur Windows, l'analyse en temps réel de Windows Defender sur les binaires Electron (`T3 Code (Beta).exe`, `app.asar`, `server.asar`) et les sous-processus CLI (`codex`, `claude`, `git`) ralentit fortement le démarrage à froid.

```powershell
# Ajouter les exclusions (%LOCALAPPDATA%\Programs\t3code et %USERPROFILE%\.t3) — demande l'élévation UAC
powershell -NoProfile -ExecutionPolicy Bypass -File .\add-defender-exclusions.ps1

# Retirer les exclusions
powershell -NoProfile -ExecutionPolicy Bypass -File .\remove-defender-exclusions.ps1
```

> **Note :** La lecture des exclusions actives via `Get-MpPreference` nécessite une console Administrateur (`Must be an administrator to view exclusions`).

---

## 4. Analyse détaillée des traces de boot (`desktop.trace.ndjson` & `server.trace.ndjson`)

Principaux postes de temps identifiés lors d'un démarrage à froid de `T3 Code (Beta).exe` :

| Composant / Span | Durée mesurée | Remarque |
| --- | --- | --- |
| Spawn Node + chargement `server.asar` | **~1,47 s** | Temps entre démarrage Electron et premier span serveur |
| `desktop.shellEnvironment.refresh` (Windows) | **1,07 s** | Exécuté en parallèle du démarrage backend |
| `makeCodexInstallation` (`CodexInstallation.resolveLocal`) | **0,78 s** | Sonde CLI `codex` au démarrage serveur |
| `VcsProcess.spawn` (`gh`) | **0,18 s** | Sonde CLI GitHub |
| `Sqlite.setup` (`statev2.sqlite`, 65 Mo) | **7,7 ms** | Très rapide au boot (compaction officielle disponible via `t3 doctor`) |
| Sondes post-boot en parallèle (non bloquantes pour l'ouverture) | **1,1–1,7 s** | `withCodexAppServerClient` (`1,46 s`), `runClaudeCommand` (`1,19 s`), `runGrokCliCommand` (`1,15 s`), `tailscale` (`1,04 s`), `git` repo identity (`1,1 s`) |

---

## Fichiers du dépôt

- [`open-in-t3code.cs`](open-in-t3code.cs) — Source du lanceur natif C# WinExe (IPC direct sur named pipe, ~70 ms à chaud / ~5,4 s à froid)
- [`open-in-t3code.vbs`](open-in-t3code.vbs) — Lanceur VBScript de secours avec détection pipe `0 ms`
- [`install.ps1`](install.ps1) — Compilation de `open-in-t3code.exe` + installation du menu contextuel (`HKCU`)
- [`uninstall.ps1`](uninstall.ps1) — Désinstallation complète du menu contextuel
- [`optimize-t3code.ps1`](optimize-t3code.ps1) — Optimisations locales (`enableProviderUpdateChecks`, purge logs, SQLite, autostart optionnel)
- [`add-defender-exclusions.ps1`](add-defender-exclusions.ps1) — Ajout des exclusions Windows Defender (avec élévation UAC)
- [`remove-defender-exclusions.ps1`](remove-defender-exclusions.ps1) — Suppression des exclusions Windows Defender
