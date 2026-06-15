# Senity Code - Customer Deployment

Kunden ziehen das fertige Senity-Code-Image aus der Senity-Gitea-Registry
und betreiben es per `docker compose`. Source-Repo nicht erforderlich.

## Voraussetzungen

- Docker Engine 24+ oder Docker Desktop
- Gitea-Account auf `git.senity.ai` (kein Personal Access Token mehr noetig,
  Login laeuft jetzt ueber OAuth2 Device-Flow)
- `senity`-CLI installiert (siehe `senity-cli/install.sh` bzw. `install.ps1`)
- SSH-Key fuer Skill-Pulls aus `murc134/Claude-*` (optional, nur falls Auto-Update gewuenscht)

## Setup

```bash
# 1. Files aus dem Customer-Bundle entpacken
unzip senity-code-customer.zip
cd senity-code/

# 2. Env-Template kopieren und ausfuellen
cp .env.example .env
$EDITOR .env

# 3. Container starten (Host-Wrapper macht alles)
./scripts/senity-start.sh
```

Auf Windows:

```powershell
.\scripts\senity-start.ps1
# oder per Doppelklick:
scripts\senity-start.bat
```

## Was der Host-Wrapper macht

`senity-start.{sh,ps1,bat}` arbeitet vollautomatisch und benoetigt nur einen
einzigen User-Klick. Reihenfolge:

1. Pre-Check `senity`-CLI vorhanden + Docker-Daemon laeuft.
2. `senity gitea-token --ensure-fresh --write-docker-config`
   - Erneuert den Access-Token wenn noetig (Default-TTL 1h, Refresh
     bei Restlaufzeit unter 60s).
   - Schreibt den Token atomar als `oauth2:<at>` in `~/.docker/config.json`
     unter `auths."git.senity.ai"`.
3. Bei fehlendem oder ungueltigem Refresh-Token (Exit 2/3) ruft der Wrapper
   automatisch `senity gitea-login` und startet den Device-Flow (Browser
   oeffnet sich, Code im Terminal sichtbar, QR-Code falls `qrencode`
   verfuegbar). Danach ein automatischer Retry.
4. `docker compose pull senity-code && docker compose up -d senity-code`.
5. Interaktive Session via `docker compose exec -it senity-code
   senity-mascot-filter claude`.

Es gibt keine Stelle, an der der Wrapper nach einem Personal Access Token
fragt - der gesamte Auth-Flow laeuft ueber OAuth2 mit kurzlebigen Tokens.

## Daily Use

```bash
# Interaktive Senity-Session (bevorzugt)
./scripts/senity-start.sh

# Direkt im laufenden Container
docker compose exec senity-code senity-mascot-filter claude

# Container-Status
docker compose ps

# Logs
docker compose logs -f senity-code

# Update auf neueste Image-Version
./scripts/senity-start.sh   # pulls + up -d ohnehin enthalten
```

Alternativ: globaler `senity`-Befehl (siehe `senity-cli/`) startet
Ad-hoc-Container im jeweiligen Arbeitsverzeichnis - ohne `docker compose`.

## Datei-Layout

```
senity-code/
+-- docker-compose.yml      # Service-Definition (nicht editieren)
+-- .env                    # Proxy-Key, Tag-Pinning (gitignored)
+-- .env.example            # Template
+-- scripts/
    +-- senity-start.sh     # Host-Wrapper (Linux / macOS)
    +-- senity-start.ps1    # Host-Wrapper (Windows / pwsh)
    +-- senity-start.bat    # cmd-Shim, delegiert nach .ps1
+-- workspace/              # Persistente Daten (Skills, Settings, Projekte)
+-- mcp-config.json         # optional, eigene MCP-Server (siehe Beispiel)
```

## Wo liegen meine Credentials?

| Pfad                       | Inhalt                          | Permissions |
|----------------------------|---------------------------------|-------------|
| `~/.senity/auth.json`      | Refresh-Token + User-Metadata   | 0600 (Linux), ACL-restricted auf $USER (Windows) |
| `~/.docker/config.json`    | Access-Token als `oauth2:<at>`  | gemaess Docker-Default (0600) |

Der Refresh-Token verlaesst niemals den Client. Der Access-Token ist
kurzlebig (1h Default, 24h Maximum) und wird vom Host-Wrapper bei jedem
Start frisch erneuert.

## CI / Headless-Setups

Fuer CI / Auto-Pull ohne Browser:

```bash
export SENITY_GITEA_RT="<long-lived-refresh-token>"
./scripts/senity-start.sh
```

Der Wrapper benutzt den env-vorhandenen Refresh-Token, weicht auf den
Persistenz-Pfad aus wenn die Variable fehlt und failed deterministisch
mit Exit 3 wenn der Token revoked wurde.

## Update-Strategie

Default-Tag in `.env.example` ist `latest`. Fuer Production empfohlen:

```bash
# In .env explizit pinnen
SENITY_IMAGE_TAG=1.4.2
```

Major-Updates kommen mit Release-Notes im Senity-Customer-Channel.

## Troubleshooting

**`Auth-Recovery fehlgeschlagen (Exit 3 nach Re-Login)`**
Refresh-Token revoked und Re-Login hat keinen neuen geliefert. Manuell:
`senity gitea-logout && senity gitea-login`.

**`unauthorized: authentication required` beim Pull**
Access-Token abgelaufen. Im Normalfall faengt der Wrapper das ab; tritt
es trotzdem auf, hilft `senity gitea-token --ensure-fresh
--write-docker-config && docker compose pull`.

**`Device-Code abgelaufen, bitte Aufruf wiederholen.`**
Der User hat den Code nicht innerhalb von 15min eingeloest. Einfach
nochmal starten.

**`Netzwerkfehler beim Token-Refresh.`**
Verbindung zu `https://git.senity.ai` pruefen. TLS muss zwingend valide
sein, kein `--insecure`.

**`senity gitea-login` oeffnet keinen Browser**
Auf Headless-Hosts ist das normal - der Code + Direkt-Link werden im
Terminal angezeigt, manuell oeffnen.

**Container startet, aber `senity-mascot-filter` nicht gefunden**
Image-Tag zu alt. `docker compose pull` und neu starten.

**`SENITY_CHAT_PROXY_KEY` leer / 401 beim Proxy**
`.env` editieren, dann `docker compose up -d` (re-creates container with new env).

**Skills/Commands fehlen**
Auto-Update braucht SSH-Zugriff. `~/.ssh` ist read-only gemountet,
SSH-Agent oder Key in `~/.ssh/config` pruefen. Alternativ:
`docker compose exec senity-code bash` und manuell `git pull` in
`/workspace/.claude/skills/intern/`.

## Security

- `.env` enthaelt den Proxy-Key. Mode `600` (auf Unix), niemals einchecken.
- `~/.senity/auth.json` enthaelt den Refresh-Token. Permissions 0600.
- `~/.docker/config.json` enthaelt den Access-Token. Der Wrapper schreibt
  atomar (tmp + rename), kein In-Place-Edit.
- `docker-compose.yml` exposed standardmaessig keine Ports.
- `~/.ssh` ist read-only gemountet, der Container kann keine Keys aendern.
- TLS-Verifikation gegen `git.senity.ai` ist hart verdrahtet; jeder
  Versuch, `--insecure` o.ae. zu setzen, ist ein Bug-Report wert.
- Image wird signiert (Cosign), Signatur via `cosign verify` pruefbar
  (Public Key siehe Senity-Doku).

## Subcommand-Referenz (`senity gitea-*`)

| Befehl                                              | Zweck                                                |
|-----------------------------------------------------|------------------------------------------------------|
| `senity gitea-login`                                | OAuth2 Device-Flow (Browser + Code im Terminal)      |
| `senity gitea-token --ensure-fresh`                 | Access-Token sicherstellen (refresht wenn noetig)    |
| `senity gitea-token --ensure-fresh --write-docker-config` | Zusaetzlich `~/.docker/config.json` patchen     |
| `senity gitea-token --print`                        | Nur den Access-Token nach stdout (CI)                |
| `senity gitea-status`                               | User, Scopes, Token-Freshness (kein Token-Wert!)     |
| `senity gitea-logout`                               | Revoke + lokales `auth.json` und Docker-Auth loeschen |

Headless-Variante fuer alle Token-Operationen: vorher
`export SENITY_GITEA_RT="<rt>"`.

Exit-Codes (vollstaendige Liste):

| Code | Bedeutung                                             |
|------|-------------------------------------------------------|
| 0    | OK                                                    |
| 2    | `~/.senity/auth.json` fehlt (Login noetig)            |
| 3    | Refresh-Token `invalid_grant` (Re-Login noetig)       |
| 4    | Device-Code `expired_token`                           |
| 5    | User hat `access_denied` gewaehlt                     |
| 6    | Netzwerk- oder Lib-Lade-Fehler                        |
