# Implementierungsplan: Provider-Auswahl beim Start (Ticket CLI-2429)

Status: ENTWURF, zur Review durch Codex (Direktfixes erlaubt und erwuenscht).
Autor: Claude, 2026-07-02. Arbeitsdokument, wird nicht committed (oder erst nach Freigabe).

## 1. Anforderungen (User, Christoph)

- **A1:** Beim Start muss gefragt werden, ob Claude Code mit den **Anthropic-Modellen**
  gestartet werden soll (dann Anthropic-Login), oder mit **Senity als Provider**.
- **A2:** Bei Senity: nur den **API-Key aus dem SDRv4** eingeben. Keine URL, nichts
  weiter manuell vorschreiben. Default-Proxy-URL wird still verwendet.
- **A3:** Bei Senity muss **sichergestellt** sein, dass Claude Code mit dem
  Senity-Modell **qwen3.6** aus der Senity-API laeuft.
- **A4 (Nachtrag):** Zusaetzlich ein **Custom Provider**: User uebergibt API-Endpunkt
  und API-Key selbst.

## 2. Ist-Zustand

### Kunden-CLI `senity-cli/senity.ps1` (+ `.sh`-Pendant, Paritaetspflicht)

- Agent-Modi: `senity` (Default), `claude`, `codex`, `antigravity`. Ohne Argument
  startet stumm der `senity`-Modus; die interaktive Auswahl gibt es nur ueber das
  explizite Argument `select` (`Select-AgentMode`, senity.ps1:106-126;
  senity.sh:148-160).
- Der Argument-Parser kennt `custom` nicht. PowerShell erkennt Agent-Tokens nur in
  `@("senity","claude","codex","antigravity","agy","select")`
  (senity.ps1:180-200), Bash analog in den Cases `senity` bis `select`
  (senity.sh:174-181).
- `senity login` (`Invoke-Login`, senity.ps1:276-307) fragt **URL und Key** ab.
  Der URL-Prompt verletzt A2 (User soll nichts ausser dem Key eingeben).
- Bash-Paritaetsluecke: `senity-cli/senity.sh` fragt ebenfalls die URL ab
  (`cmd_login`, senity.sh:222-253), validiert den Key dort aber gar nicht.
  `load_env` liest nur Datei/Default und prueft auf leeren Key (senity.sh:434-445).
- `Invoke-Container`/`run_container`: im `senity`-Modus werden
  `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY` auf Proxy-URL/Key gesetzt
  (senity.ps1:408-449; senity.sh:498-542); im `claude`-Modus werden Host-Env-Vars
  (`ANTHROPIC_*`, `CLAUDE_CODE_OAUTH_TOKEN`, ...) nur durchgereicht, falls gesetzt.
  Einen gefuehrten Custom-Endpoint-Flow gibt es nicht.
- PowerShell-Key-Validierung inkl. Lizenz-Gate existiert bereits
  (`Test-SenityProxyKey`, senity.ps1:249-273, Aufrufe in `Invoke-Login` und
  `Get-Env` bei senity.ps1:293 und 325, Ticket #2444): POST `/v1/messages`
  Mini-Request, 401/403 = blockend. Bash muss diese Semantik erst erhalten.
- `Save-EnvFile` schreibt die Datei aus der uebergebenen Hashtable komplett neu
  (senity.ps1:238-240). Fuer neue Keys wie `SENITY_PROVIDER` und
  `SENITY_CUSTOM_*` darf die Implementierung bestehende unbekannte Keys nicht
  versehentlich loeschen.

### SDRv4 Claude-Proxy (Server)

- `v1/messages/route.ts`: Das vom Client gesendete `model`-Feld wird **ignoriert**.
  Geroutet wird immer ueber die Fallback-Chain `cli_chat`
  (`resolveFallbackChain('chat', 'cli_chat')`, route.ts:657-660). Ein
  `fixed_model`-Override existiert nur pro `cli_server`-Container
  (`cli_server.fallback_chain_override`, route.ts:541-588, 665-672), nicht fuer
  den User-Token-Pfad der Kunden-CLI.
- Das tatsaechlich verwendete Modell kommt in der Response als Header
  `X-Senity-Model: <provider>/<model>` zurueck (route.ts:695-700).
- Konsequenz: **Die qwen3.6-Garantie ist primaer eine Server-Eigenschaft**
  (erster wirksamer Entry der globalen `cli_chat`-Chain), nicht per Client-Env
  erzwingbar. `ANTHROPIC_MODEL` oder `--model qwen3.6` im Container sind fuer den
  Proxy keine Durchsetzung.

### Entwickler-Launcher `claude-senity.ps1`/`.sh` (Repo-Root)

- Gleiche Agent-Modi, eigenes `select`-Menue ohne Custom
  (`claude-senity.ps1`:179-199; `claude-senity.sh`:368-383).
- Proxy-Credentials kommen aus repo-lokaler `.env`; beide Launcher fragen beim
  Erstsetup noch eine Proxy-URL ab und setzen ein kosmetisches Default-Modell
  `qwen3.6:35b` (`claude-senity.ps1`:854-963; `claude-senity.sh`:468-590).
- Beide Entwickler-Launcher validieren den Senity-Key bereits
  (`claude-senity.ps1`:519-560; `claude-senity.sh`:122-160), lesen aber noch
  keinen `X-Senity-Model`-Header aus.
- Muss funktional nachziehen (Paritaetsregel `.sh`/`.ps1`, siehe CLAUDE.md).

### Container `docker-entrypoint.sh`

- `SENITY_BRANDED_MODE` ist intern nur bei `SENITY_AGENT_MODE=senity` aktiv
  (docker-entrypoint.sh:6-13).
- Onboarding-Suppression (`hasCompletedOnboarding=true`) und das Leeren von
  `customApiKeyResponses.rejected` sind aktuell an `SENITY_BRANDED_MODE` gekoppelt
  (docker-entrypoint.sh:121-149, 161-166). Das ist korrekt fuer Anthropic, kann
  aber einen Custom-Provider mit `ANTHROPIC_API_KEY` blockieren, wenn Claude Code
  sonst den API-Key-Login/Approve-Screen anzeigt.
- Model-Sync und Banner laufen ebenfalls nur im Senity-Branded-Modus
  (docker-entrypoint.sh:221-222, 239 ff.).

## 3. Soll-Design

### 3.1 Provider-Begriff und Persistenz

Neuer Config-Key in `~/.senity/.env`. Schreiben immer als Merge/Upsert, nicht als
blindes `Save-EnvFile`-Overwrite:

```
SENITY_PROVIDER=senity
# erlaubte Werte: senity, anthropic, custom

# nur bei custom:
SENITY_CUSTOM_BASE_URL=<https://...>   # gleiche Semantik wie ANTHROPIC_BASE_URL
SENITY_CUSTOM_API_KEY=<key>
SENITY_CUSTOM_MODEL=<optional, setzt ANTHROPIC_MODEL>
```

Regeln:

- Provider ist orthogonal zum Agent. `codex`/`antigravity` bleiben unberuehrt.
  Provider betrifft nur Claude-Code-Starts.
- Prozess-Env darf Dateiwerte ueberschreiben (`SENITY_PROVIDER`,
  `SENITY_CUSTOM_*`, `SENITY_CHAT_PROXY_URL`, `SENITY_CHAT_PROXY_KEY`), wird aber
  nicht ungefragt persistiert.
- Ungueltiger `SENITY_PROVIDER` wird interaktiv mit Warnung auf `senity`
  normalisiert; non-interaktiv ist `senity` der Default.
- Explizite Provider-Starts (`senity senity`, `senity claude`, `senity custom`)
  aktualisieren `SENITY_PROVIDER`. Starts von `codex`, `antigravity`, `comfyui`
  und Login-/Gitea-Subcommands tun das nicht.

| Provider    | Startziel | AgentMode im Container | Env-Injektion |
|-------------|-----------|------------------------|----------------|
| `senity`    | `senity`  | `senity` | `SENITY_PROVIDER=senity`, `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY` = Proxy-URL/Key, Senity-Branding aktiv |
| `anthropic` | `claude`  | `claude` | `SENITY_PROVIDER=anthropic`, keine Senity-Credentials; Claude-Code-eigener Login im Container, Host-`ANTHROPIC_*` wie heute optional durchreichen |
| `custom`    | `custom`  | `claude` | `SENITY_PROVIDER=custom`, `ANTHROPIC_BASE_URL=SENITY_CUSTOM_BASE_URL`, `ANTHROPIC_API_KEY=SENITY_CUSTOM_API_KEY`, optional `ANTHROPIC_MODEL=SENITY_CUSTOM_MODEL`; kein Senity-Branding, kein Model-Sync |

Wichtig fuer `custom`: Host-`ANTHROPIC_*` und `CLAUDE_CODE_OAUTH_TOKEN` duerfen
nicht zusaetzlich durchgereicht werden, weil sie die gespeicherten
`SENITY_CUSTOM_*`-Werte ueberdecken oder Claude Code in den Anthropic-OAuth-Flow
ziehen koennen. Nur explizite Custom-Werte injizieren.

### 3.2 Start-Frage und `select`-Menue (A1)

Neue Funktion `Select-Provider` (ps1) / `select_provider` (sh):

```
Wie soll Claude Code starten?
  1) Senity     Senity-API, erwartetes Modell qwen3.6
  2) Anthropic  Anthropic-Modelle, Login mit Anthropic-Konto oder API-Key
  3) Custom     Eigener Anthropic-kompatibler API-Endpunkt + API-Key
Auswahl [<zuletzt genutzt, initial 1>]:
```

Trigger-Logik:

- Frage erscheint bei jedem interaktiven Start ohne explizites Agent-/Provider-
  Argument und ohne Subcommand. Beispiel: `senity`, `senity -SkipUpdate` und
  `senity --skip-update` fragen; `senity login`, `senity comfyui`,
  `senity gitea-token`, `senity codex` fragen nicht.
- Interaktiv heisst PowerShell: `-not [Console]::IsInputRedirected -and -not
  [Console]::IsOutputRedirected`; Bash: `[[ -t 0 && -t 1 ]]`.
- Enter uebernimmt den zuletzt genutzten Provider aus `SENITY_PROVIDER`
  (initial `senity`). Das erfuellt A1 ohne Zwang zur Neueingabe.
- Nicht-interaktiv: keine Frage, gespeicherter Provider bzw. Default `senity`.
  Wenn der gespeicherte Provider `custom` ist, aber Pflichtwerte fehlen, wird
  non-interaktiv mit klarer Fehlermeldung abgebrochen.
- `senity select` bleibt ein bewusstes Startziel-Menue, wird aber auf **ein**
  Menue mit 5 Punkten umgestellt: `Senity`, `Anthropic`, `Custom`, `Codex`,
  `Antigravity`. Damit gibt es nicht zwei verschiedene Menue-Konzepte.
- Explizite Argumente ueberspringen die Frage: `senity senity`, `senity claude`,
  `senity custom`, `senity codex`, `senity antigravity`.
- `custom` wird **nicht** als neuer Docker-AgentMode eingefuehrt. Parser setzt
  `Provider=custom` und `AgentMode=claude`.
- Parser-Kollisionen:
  - `senity login custom` ist Login-Submode, kein Claude-Tool-Argument.
  - `senity custom --relogin` / PowerShell `senity custom -Relogin` erzwingt den
    Custom-Dialog und entfernt das Flag vor der Weitergabe an Claude Code.
  - Alles nach `--` bleibt Tool-Argument und darf nicht mehr als Provider,
    Agent oder Login-Submode interpretiert werden.

### 3.3 Senity-Flow ohne URL-Eingabe (A2)

- `Invoke-Login`/`cmd_login`: **URL-Prompt entfernen.** URL ist per Default
  `$DefaultProxyUrl` / `DEFAULT_PROXY_URL`
  (`https://sdr.senity.ai/api/claude-proxy`).
- Override nur ueber bestehende Datei/Env `SENITY_CHAT_PROXY_URL` oder explizites
  Entwickler-/Test-Flag: PowerShell `-ProxyUrl <url>`, Bash `--proxy-url <url>`.
  Kein Standard-Prompt fuer Endanwender.
- Ablauf im Senity-Zweig, wenn kein Key gespeichert: direkt Key-Prompt
  ("Senity API-Key aus dem SDR:"), danach Validierung gegen den gewaehlten URL.
- Bestehende `.env`-Dateien mit abweichender gespeicherter URL bleiben gueltig
  (Backwards-Kompatibilitaet, kein Migrationszwang). Ein neuer Login ohne
  `-ProxyUrl`/`--proxy-url` soll diese URL nicht ungefragt anzeigen, aber als
  technische Override-Quelle weiter nutzen.
- PowerShell und Bash muessen dieselbe Validierungssemantik haben:
  401/403/404 blocken; 5xx/offline bleiben nur mit Warnung fail-open wie heute
  in PowerShell. Bash erhaelt die bisher fehlende Validierung.
- Schreiben der `.env` immer per Upsert/Merge, mit Dateirechten 0600 in Bash und
  ohne Logging von Secrets. Werte mit CR/LF werden abgelehnt.

### 3.4 qwen3.6 sicherstellen (A3)

Zweistufig, weil die Modellwahl serverseitig ist:

1. **Serverseitig (SDRv4, eigentliche Durchsetzung):** Verifizieren bzw.
   konfigurieren, dass die globale `cli_chat`-Fallback-Chain als ersten wirksamen
   Entry `qwen3.6` (MSH/vLLM-Provider) hat. A3 gilt nur als erfuellt, wenn ein
   erfolgreicher CLI-Request nicht still auf ein Fremdmodell fallen kann. Falls
   Fallback-Eintraege existieren, muessen sie bewusst dokumentiert werden:
   - strikte A3: nur qwen3.6-kompatible Entries oder fail-closed,
   - bewusstes Degradationsverhalten: Fremdmodell-Fallback ist Produktentscheid
     und verletzt die harte qwen3.6-Zusage.
2. **Clientseitig (Transparenz + Verifikation):**
   - `Test-SenityProxyKey` und die Bash-/Entwickler-Validatoren lesen zusaetzlich
     den Response-Header `X-Senity-Model` (`Invoke-WebRequest.Headers` bzw.
     `curl -D`) und geben ihn im Result zurueck.
   - Start-Ausgabe im Senity-Modus: `Modell: <X-Senity-Model>` wenn bekannt,
     sonst `Modell: unbekannt (Proxy-Header nicht erhalten)`.
   - Wenn der Header vorhanden ist und der Modellteil nicht `qwen3.6` enthaelt,
     wird der Senity-Start blockiert: "Proxy routet aktuell auf <modell>,
     erwartet war qwen3.6. Server-Fallback-Chain pruefen."
   - Wenn der Proxy offline ist und die bestehende fail-open-Regel greift, kann
     A3 clientseitig nicht bewiesen werden. Das wird als Warnung ausgegeben.
   - Kosten: der Validierungs-Ping (max_tokens 1) laeuft ohnehin schon.

Nicht geplant (bewusst): `ANTHROPIC_MODEL` oder Claude-Code-`--model` als
Erzwingung zu verkaufen. Der Proxy ignoriert das Client-Modell; ein
Client-seitiges "Erzwingen" waere Scheinsicherheit.

### 3.5 Custom Provider (A4)

- Neues Provider-Argument `custom`: `senity custom`. Es mappt intern auf
  `AgentMode=claude`, nicht auf einen neuen Container-AgentMode.
- Erststart-Dialog: Prompt `API-Basis-URL (Anthropic-kompatibel, ohne /v1/messages)`
  und `API-Key` (SecureString/maskiert), optional
  `Modell (leer = Default des Endpunkts)`.
- Persistenz in `~/.senity/.env` (`SENITY_CUSTOM_*`). Kanonischer Aenderungsweg:
  `senity login custom`; Direktstart kann mit `senity custom --relogin` bzw.
  PowerShell `-Relogin` denselben Dialog erzwingen.
- Wenn `SENITY_PROVIDER=custom`, aber `SENITY_CUSTOM_BASE_URL` oder
  `SENITY_CUSTOM_API_KEY` fehlt:
  - interaktiv: Custom-Dialog starten,
  - non-interaktiv: abbrechen mit Hinweis auf `senity login custom` oder die
    noetigen Env-Vars.
- URL-Normalisierung: gespeicherter Wert ist die Basis, die direkt als
  `ANTHROPIC_BASE_URL` in den Container geht. Validierung bildet daraus den
  Messages-Endpunkt. Eingaben mit `/v1/messages` werden interaktiv normalisiert
  oder mit klarer Meldung abgelehnt.
- Validierung: Mini-Request gegen den Custom-Endpunkt, aber **ohne**
  Senity-Lizenz-Semantik und ohne `X-Senity-Model`-Erwartungscheck.
  401/403 = Key-Fehler (blockend), 404 = URL/Endpoint-Fehler (blockend),
  400/422/429 = Auth hat den Endpoint erreicht (ok), 5xx/offline nur interaktiv
  nach Rueckfrage weiter; non-interaktiv fail-closed, ausser ein expliziter
  Skip-Validation-Schalter ist gesetzt.
- Container-Start: upstream Claude Code (`claude-upstream`), kein
  Senity-Branding, `SENITY_MODEL_SYNC=0`, Env-Injektion siehe Tabelle 3.1.
- Entrypoint-Anpassung: Fuer `SENITY_PROVIDER=custom` darf die nicht-branded
  API-Key-Nutzung das Claude-Code-Onboarding abschliessen und
  `customApiKeyResponses.rejected` leeren, ohne Senity-Theme, Banner oder
  Model-Sync zu aktivieren. Fuer `anthropic` bleibt Onboarding-Suppression aus.
- Sicherheit: Key niemals loggen; nur maskiert anzeigen (`sk-...abcd`). Keine
  Secret-Werte in Fehlermeldungen, Debug-Ausgaben oder Review-Logs.

### 3.6 Anthropic-Flow (Login)

- `senity claude` bzw. Provider `anthropic`: keine Senity-Env-Injektion (heute
  schon so). Claude Code zeigt beim ersten Start seinen eigenen Login
  (OAuth/Browser bzw. API-Key-Eingabe); Tokens persistieren via
  `/workspace`-Mount unter `workspace/.claude/`.
- Onboarding-Suppression im `docker-entrypoint.sh` darf fuer Anthropic nicht
  greifen. Ist-Zustand ist korrekt, weil sie an `SENITY_BRANDED_MODE` haengt;
  beim neuen Custom-Sonderfall darf diese Trennung nicht aufgeweicht werden.

### 3.7 Paritaet, Doku, Verteilung

- `senity-cli/senity.sh` funktional identisch nachziehen:
  `select_provider`, Login ohne URL-Prompt, fehlende Senity-Key-Validierung,
  Custom-Flow, Non-TTY-Erkennung, Parser-Regeln, `X-Senity-Model`-Auswertung
  via `curl -D`.
- Entwickler-Launcher `claude-senity.ps1`/`.sh`: Menuepunkt/Provider Custom,
  Login ohne URL-Prompt, `X-Senity-Model`-Anzeige und gleiche Env-Logik
  ergaenzen. Repo-lokale `.env` bleibt dort der Speicherort.
- `README.md`, `senity-cli/docs/user-guide.html/pdf` aktualisieren.
- Installer-Rebuild (`installer/build.ps1`) nach Abschluss, damit
  `senity-setup.exe` den neuen Flow enthaelt.

## 4. Implementierungsschritte (Reihenfolge)

1. `senity.ps1`: Env-Upsert-Helfer statt blindem `Save-EnvFile` fuer neue Writes;
   erlaubte Provider-Werte normalisieren; `SENITY_PROVIDER` lesen/schreiben.
2. `senity.ps1`: Parser erweitern fuer `custom`, `login custom`, `-Relogin`,
   `-ProxyUrl`; `custom` intern als `Provider=custom` und `AgentMode=claude`
   abbilden, nicht an `Normalize-AgentMode`/Container als AgentMode weitergeben.
3. `senity.ps1`: `Select-Provider` und neues 5-Punkte-`Select-AgentMode`
   implementieren; Trigger nur bei interaktivem Start ohne Subcommand und ohne
   explizites Agent-/Provider-Argument.
4. `senity.ps1`: `Invoke-Login` ohne URL-Prompt; Senity-Key-Prompt und
   Custom-Login-Dialog; Pflichtwerte fuer `custom` validieren; Secrets nicht
   loggen und CR/LF ablehnen.
5. `senity.ps1`: `Test-SenityProxyKey` um `X-Senity-Model` erweitern; Start im
   Senity-Modus bei bekanntem Nicht-qwen3.6-Modell blocken; Header im Log
   anzeigen.
6. `senity.ps1`: `Invoke-Container` Custom-Zweig: saubere Env-Injektion ohne
   Host-`ANTHROPIC_*`/OAuth-Passthrough, `SENITY_PROVIDER=custom`,
   `SENITY_MODEL_SYNC=0`, `SENITY_THEME_DEFAULT=0`.
7. `senity.sh`: Punkte 1 bis 6 spiegeln, inklusive bisher fehlender
   Senity-Key-Validierung und `curl -D`-Headerauswertung.
8. `docker-entrypoint.sh`: separate, nicht-branded Onboarding-Suppression fuer
   `SENITY_PROVIDER=custom` ergaenzen; Anthropic-Login unveraendert lassen.
9. Entwickler-Launcher `claude-senity.ps1`/`.sh`: gleiche Provider-/Custom-Logik
   repo-lokal nachziehen, inklusive URL-Prompt-Entfernung und Headeranzeige.
10. SDRv4: `cli_chat`-Chain auf qwen3.6-first und A3-konformes Fallback-Verhalten
    verifizieren/konfigurieren (Betriebs-Task, kein Code in diesem Repo;
    Ergebnis im Ticket dokumentieren).
11. Doku + Installer-Rebuild + manuelle Testmatrix.

## 5. Testmatrix (manuell)

| # | Szenario | Erwartung |
|---|----------|-----------|
| 1 | Erststart interaktiv `senity`, Enter | Provider-Frage erscheint, Default Senity, Key-Prompt ohne URL, Validierung, Start nur wenn Header qwen3.6 oder Header unbekannt mit Warnung |
| 2 | Zweitstart nach Provider `anthropic` | Frage mit Default Anthropic, Enter startet Claude upstream ohne Senity-Credentials |
| 3 | `senity -SkipUpdate` / `senity --skip-update` ohne Agent | Provider-Frage erscheint trotzdem, Update wird uebersprungen |
| 4 | `senity claude` | keine Frage, `SENITY_PROVIDER=anthropic`, Anthropic-Login-Screen im Container |
| 5 | `senity custom` Erststart | Endpunkt+Key-Prompt, Validierung, Start gegen Custom-Endpunkt ohne Senity-Branding |
| 6 | `senity login custom` | schreibt/aktualisiert nur `SENITY_CUSTOM_*`, startet keinen Container und konsumiert `custom` nicht als Tool-Arg |
| 7 | `senity custom --relogin` / `-Relogin` | Custom-Dialog erneut, Flag wird nicht an Claude Code weitergereicht |
| 8 | `SENITY_PROVIDER=custom` ohne Custom-Key, interaktiv | Custom-Dialog startet |
| 9 | `SENITY_PROVIDER=custom` ohne Custom-Key, non-TTY | Abbruch mit Hinweis auf `senity login custom`/Env-Vars |
| 10 | Ungueltiger Senity-Key | Blockade mit Server-Fehlermeldung (#2444-Verhalten unveraendert), in ps1 und sh |
| 11 | Proxy offline | Warnung, bestehendes fail-open nur mit Hinweis "qwen3.6 nicht verifizierbar" |
| 12 | Chain liefert `msh/qwen3.6...` | Modell im Log, Start erlaubt |
| 13 | Chain liefert nicht-qwen3.6 | Start blockiert mit Hinweis auf SDRv4-Chain |
| 14 | `senity select` | ein 5-Punkte-Menue, Auswahl `Custom` startet Custom-Provider, Auswahl `Codex` bleibt provider-unabhaengig |
| 15 | `senity login` | nur Key-Prompt, kein URL-Prompt, bestehende `SENITY_PROVIDER`/`SENITY_CUSTOM_*` bleiben erhalten |
| 16 | Bestehende `.env` mit abweichender `SENITY_CHAT_PROXY_URL` | bleibt gueltig, wird nicht ungefragt geloescht oder angezeigt |
| 17 | Host hat `ANTHROPIC_BASE_URL`/`CLAUDE_CODE_OAUTH_TOKEN`, Provider `custom` | Host-Werte werden nicht durchgereicht; Custom-Werte gewinnen |
| 18 | Host hat `ANTHROPIC_API_KEY`, Provider `anthropic` | Host-Wert wird wie bisher optional durchgereicht |
| 19 | Bash- und PowerShell-Paritaet | Gleiche Parser-, Login-, Validierungs- und Container-Env-Ergebnisse |
| 20 | Entwickler-Launcher ps1/sh | Gleicher Provider-Flow repo-lokal, Anthropic-Login nicht unterdrueckt |

## 6. Offene Punkte / Risiken

- **Globale Chain:** `cli_chat` gilt fuer alle CLI-User gemeinsam. Ein
  per-User-Modell-Override (analog `fallback_chain_override` fuer Container)
  waere ein SDRv4-Folgefeature, hier out of scope.
- **A3 vs. Fail-open:** Bei Proxy-Netzwerkfehlern kann der Client qwen3.6 nicht
  beweisen. Wenn A3 absolut fail-closed gemeint ist, muss die bestehende
  fail-open-Regel fuer Senity-Starts geaendert werden.
- **Custom-Kompatibilitaet:** Nicht jeder "Custom Provider" spricht wirklich
  Anthropic-kompatible `/v1/messages`. Der Dialog und die Doku muessen das klar
  sagen; OpenAI-kompatible Provider brauchen einen Anthropic-Adapter.
- **Docker-Env-Secrets:** API-Keys werden weiterhin als Container-Env gesetzt und
  koennen fuer lokale Docker-Administratoren sichtbar sein. Das ist der heutige
  Mechanismus, darf aber nicht zusaetzlich in Logs erscheinen.
- **PowerShell-Dateirechte:** Bash kann `chmod 600` setzen; Windows verlaesst sich
  auf das Benutzerprofil/ACLs. Falls hoehere Geheimhaltung gefordert ist, waere
  DPAPI ein separates Folgefeature.

## Review-Log (Codex)

- 2026-07-02: Ist-Zustand gegen `senity.ps1`, `senity.sh`, Entwickler-Launcher,
  `docker-entrypoint.sh` und SDRv4-Route verifiziert; Zeilenangaben korrigiert.
- 2026-07-02: Bash-Paritaetsluecke ergaenzt: Kunden-`senity.sh` validiert den
  Senity-Key bisher nicht.
- 2026-07-02: Provider-/Agent-Konzept geschaerft: `custom` ist Provider, kein
  Docker-AgentMode; `select` wird zu einem einheitlichen 5-Punkte-Menue.
- 2026-07-02: Edge Cases ergaenzt fuer Non-TTY, fehlende Custom-Secrets,
  `login custom`, Secret-Handling, Env-Upsert und Host-Env-Kollisionen.
- 2026-07-02: qwen3.6-Absicherung korrigiert: Nicht-qwen3.6-Header blockiert den
  Senity-Start; `ANTHROPIC_MODEL` bleibt nur kosmetisch.
