# T3 Code Enhanced (Windows)

Outils, intégration Explorateur Windows et optimisations de démarrage pour **T3 Code** (`pingdotgg/t3code`) sur Windows.

---

## 1. Menu contextuel Windows (« Ouvrir dans T3 Code »)

Ajoute une entrée **Ouvrir dans T3 Code** (avec l'icône T3 Code) dans le clic droit de l'Explorateur Windows :
- Clic droit **sur un dossier** (`HKCU\Software\Classes\Directory\shell\T3CodeOpen`)
- Clic droit **dans le vide d'un dossier** (`HKCU\Software\Classes\Directory\Background\shell\T3CodeOpen`)
- Clic droit **sur un lecteur** (`HKCU\Software\Classes\Drive\shell\T3CodeOpen`)

> **Sans droits administrateur** (registre utilisateur `HKCU`). Sur Windows 11, l'entrée apparaît dans *Afficher plus d'options* (ou `Maj + Clic droit`).

### Fonctionnement technique
- Utilise le CLI officiel embarqué dans l'installation de T3 Code (`t3 app "<dossier>"`) sans dépendance `npm`/`npx` :
  ```
  ELECTRON_RUN_AS_NODE=1 "T3 Code (Beta).exe" "resources\server.asar\apps\server\dist\bin.mjs" app "<dossier>"
  ```
- Le lanceur silencieux [`open-in-t3code.vbs`](open-in-t3code.vbs) est copié dans `%LOCALAPPDATA%\t3code-context-menu\open-in-t3code.vbs` :
  - Aucune fenêtre de console visible (`wscript.exe //B //NoLogo`).
  - Gère les espaces, accents et racines de lecteur (`C:\` → `C:\\`).
  - Si T3 Code est déjà ouvert : activation immédiate (< 1 s).
  - Si T3 Code est fermé : supprime `ELECTRON_RUN_AS_NODE`, lance `T3 Code (Beta).exe`, puis interroge `t3 app` jusqu'à ce que l'application soit prête.
  - Journalise chaque exécution dans `%LOCALAPPDATA%\t3code-context-menu\last-run.log`.

### Installation / Désinstallation

```powershell
# Installer le raccourci clic droit
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

# Désinstaller proprement (registre + dossier AppData)
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

---

## 2. Optimisation Windows Defender

Sur Windows, l'analyse en temps réel de Windows Defender sur les binaires Electron (`app.asar`, `server.asar`) et les sous-processus Node/CLI (`codex`, `claude`, `git`) est l'une des causes principales de lenteur au démarrage à froid.

```powershell
# Ajouter les exclusions (%LOCALAPPDATA%\Programs\t3code et %USERPROFILE%\.t3) — demande l'élévation UAC
powershell -NoProfile -ExecutionPolicy Bypass -File .\add-defender-exclusions.ps1

# Retirer les exclusions
powershell -NoProfile -ExecutionPolicy Bypass -File .\remove-defender-exclusions.ps1
```

---

## 3. Audit de performance du démarrage (mesures réelles)

Mesures relevées avant optimisation depuis `%LOCALAPPDATA%\t3code-context-menu\last-run.log`, `%USERPROFILE%\.t3\userdata\logs\desktop.trace.ndjson` et `server.trace.ndjson` :

| Étape / Composant | Temps mesuré | Observation |
| --- | --- | --- |
| `open-in-t3code.vbs` — Étape 1 (`t3 app` à froid) | **~20 s** | Timeout `CLI_RESPONSE_TIMEOUT_MS` (17 s) avant même de lancer l'exe quand l'app est fermée |
| Démarrage à froid de `T3 Code (Beta).exe` + ouverture dossier | **~22 s** | Electron + backend local + renderer + sondes providers |
| Backend local (`DesktopBackendManager.waitForReady`) | **~1,9 s** | Relativement rapide une fois le processus lancé |
| Sondes providers au démarrage (`check*ProviderStatus`) | **2,0 – 2,9 s** chacune | Codex (`2,9 s`), Grok (`2,2 s`), Claude (`2,0 s`) |
| Données locales `%USERPROFILE%\.t3\userdata` | `logs/` **124 Mo**, `statev2.sqlite` **64 Mo** | À surveiller / nettoyer |

---

## 4. Pistes d'optimisation à poursuivre (depuis un terminal externe)

> **Pourquoi depuis un terminal externe ?** Fermer `T3 Code (Beta).exe` coupe le backend et les agents exécutés à l'intérieur de T3 Code. Un terminal externe permet de fermer/relancer T3 Code et de mesurer précisément les temps de démarrage à froid.

1. **Supprimer les 20 s perdues dans `open-in-t3code.vbs` à froid** : vérifier rapidement si le named pipe `\\.\pipe\t3code-app-*` (ou une fenêtre T3 Code active) existe avant d'appeler `t3 app`, afin de lancer `T3 Code (Beta).exe` immédiatement en 0 ms quand il est fermé.
2. **Mesurer l'impact avant/après** des exclusions Windows Defender sur un démarrage à froid réel.
3. **Alléger le boot de T3 Code** :
   - Désactiver `enableProviderUpdateChecks` et les providers inutilisés.
   - Purger/limiter la rotation des logs (`124 Mo`) et archiver les anciens threads (`statev2.sqlite`).
4. **Mode instantané** : tester le démarrage automatique en arrière-plan (ou en service persistant `t3 service` + interface web `http://localhost:3773`) pour un accès < 1 s en permanence.
5. **Menu contextuel Windows 11 natif (optionnel)** : évaluer un wrapper MSIX/sparse package pour apparaître directement dans le premier niveau du clic droit Windows 11 sans passer par *Afficher plus d'options*.

---

## Fichiers du dépôt

- [`open-in-t3code.vbs`](open-in-t3code.vbs) — Lanceur silencieux appelé par l'Explorateur Windows
- [`install.ps1`](install.ps1) — Installation du menu contextuel (registre `HKCU` + copie dans `AppData\Local`)
- [`uninstall.ps1`](uninstall.ps1) — Désinstallation complète du menu contextuel
- [`add-defender-exclusions.ps1`](add-defender-exclusions.ps1) — Ajout des exclusions Windows Defender (avec élévation UAC)
- [`remove-defender-exclusions.ps1`](remove-defender-exclusions.ps1) — Suppression des exclusions Windows Defender
