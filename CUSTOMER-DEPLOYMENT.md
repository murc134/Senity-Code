# Senity Code - Customer Deployment

Kunden ziehen das fertige Senity-Code-Image aus der Senity-Gitea-Registry
und betreiben es per `docker compose`. Source-Repo nicht erforderlich.

## Voraussetzungen

- Docker Engine 24+ oder Docker Desktop
- Gitea-Account (`git.senity.ai`) mit Personal Access Token, Scope `read:package`
- SSH-Key fuer Skill-Pulls aus `murc134/Claude-*` (optional, nur falls Auto-Update gewuenscht)

## Setup

```bash
# 1. Files aus dem Customer-Bundle entpacken
unzip senity-code-customer.zip
cd senity-code/

# 2. Env-Template kopieren und ausfuellen
cp .env.example .env
$EDITOR .env

# 3. Bei Gitea-Registry einloggen
docker login git.senity.ai
# Username: dein-gitea-user
# Password: <Personal Access Token, Scope read:package>

# 4. Image pullen und Container starten
docker compose pull
docker compose up -d
```

## Daily Use

```bash
# Interaktive Senity-Session
docker compose exec senity-code senity-mascot-filter claude

# Container-Status
docker compose ps

# Logs
docker compose logs -f senity-code

# Update auf neueste Image-Version
docker compose pull && docker compose up -d
```

Alternativ: globaler `senity`-Befehl (siehe `senity-cli/`) startet
Ad-hoc-Container im jeweiligen Arbeitsverzeichnis - ohne `docker compose`.

## Datei-Layout

```
senity-code/
+-- docker-compose.yml      # Service-Definition (nicht editieren)
+-- .env                    # Proxy-Key, Tag-Pinning (gitignored)
+-- .env.example            # Template
+-- workspace/              # Persistente Daten (Skills, Settings, Projekte)
+-- mcp-config.json         # optional, eigene MCP-Server (siehe Beispiel)
```

## Update-Strategie

Default-Tag in `.env.example` ist `latest`. Fuer Production empfohlen:

```bash
# In .env explizit pinnen
SENITY_IMAGE_TAG=1.4.2
```

Major-Updates kommen mit Release-Notes im Senity-Customer-Channel.

## Troubleshooting

**`unauthorized: authentication required` beim Pull**
`docker login git.senity.ai` erneut. Token-Scope `read:package` pruefen.

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
- `docker-compose.yml` exposed standardmaessig keine Ports.
- `~/.ssh` ist read-only gemountet, der Container kann keine Keys aendern.
- Image wird signiert (Cosign), Signatur via `cosign verify` pruefbar
  (Public Key siehe Senity-Doku).
