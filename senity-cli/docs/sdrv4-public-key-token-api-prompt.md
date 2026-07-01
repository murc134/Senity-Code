# Prompt fuer SDRv4: Public-Key-mediierte Gitea-Token-API

## Kontext fuer das SDRv4-Team

Das Senity-Workspace-Container-Setup (Repo `senity/senity-code`, Master-Epic
#1030) verteilt das Container-Image zukuenftig per Gitea-Registry
(`git.senity.ai/senity-admin/senity-claude-code:<tag>`, siehe Ticket #1031).
Parallel laeuft die globale `senity`-CLI (Ticket #1041), die das Image
ad-hoc fuer einzelne Arbeitsverzeichnisse startet.

Beides braucht clientseitig einen Gitea-Token mit Scope `read:package` (fuer
das Image-Pull) bzw. SSH-Zugriff (fuer Skill- und MCP-Repo-Pulls). Heute
muss jeder Kunde diesen Token manuell in Gitea generieren und in
`docker login` bzw. SSH-Config ablegen. Onboarding-Friction = hoch.

## Vision

Der Kunde hinterlegt seine SSH-Public-Keys einmalig in seinem
SDRv4-Profil. Beim ersten Container-Start auf einer neuen Maschine ruft die
`senity`-CLI eine SDRv4-API auf, signiert den Request lokal mit dem
zugehoerigen Private Key, und SDRv4 mintet daraufhin einen kurzlebigen
Gitea-Token (oder gibt einen vorher gespeicherten Service-Token zurueck)
und liefert ihn an den Client. Der Client schreibt den Token in
`~/.docker/config.json` und ist sofort einsatzbereit. Kein manuelles
Gitea-Login, kein Token-Management durch den Kunden.

## Anforderungen

### 1. Public-Key-Management im SDRv4-Profil

- Neuer Tab im User-Profil: `SSH Keys`.
- Upload-Form fuer OpenSSH-Format-Keys (ssh-ed25519, ssh-rsa, ecdsa-sha2-*).
- Pflichtfelder: `label` (z.B. "Laptop Marco"), `public_key`, `created_at`.
- Optional: `expires_at`, `last_used_at` (vom System gepflegt).
- Multiple Keys pro User erlaubt. Sortierung: zuletzt benutzt zuerst.
- Loeschen/Sperren per UI moeglich (Sperren = Soft-Delete, Audit-Trail).
- Audit-Log: wer wann welchen Key hinzugefuegt/entfernt hat.

### 2. Token-Mint-Endpunkt

`POST /api/v1/gitea-tokens/mint`

**Request-Body:**
```json
{
  "username": "marco@senity.ai",
  "scope": "read:package",
  "ttl_seconds": 3600,
  "machine_id": "laptop-marco-2024",
  "nonce": "<random-bytes-hex>",
  "timestamp": "2026-05-24T10:15:30Z",
  "signature": "<base64(ed25519-signature)>",
  "signature_key_fingerprint": "SHA256:abc123..."
}
```

**Signatur-Berechnung clientseitig:**

```
payload = username + "|" + scope + "|" + ttl_seconds + "|" + machine_id + "|" + nonce + "|" + timestamp
signature = sign(private_key, sha256(payload))
```

**Server-Validierung:**

1. `username` aufloesen, aktive Public-Keys laden.
2. Key mit passendem `signature_key_fingerprint` finden. Wenn nicht
   vorhanden -> `401 unknown_key`.
3. `timestamp` darf max. 60 Sekunden von Serverzeit abweichen.
4. `nonce` darf in den letzten 5 Minuten nicht schon gesehen worden sein
   (Replay-Schutz, Redis-Cache reicht).
5. Signature gegen `payload` validieren. Bei Failure -> `403 invalid_signature`.
6. `scope` gegen Whitelist pruefen (initial: `read:package`,
   `read:repository`). Andere Scopes -> `403 scope_not_allowed`.
7. `ttl_seconds` clampen auf `[60, 86400]`.
8. Gitea-API aufrufen (Service-User mit Admin-Scope):
   `POST /api/v1/users/{target_user}/tokens` -> erzeugter Token zurueck.
9. Token im Audit-Log eintragen (User, Key, Scope, TTL, Machine-ID,
   Issuer-Timestamp). **Token selbst nicht persistieren**, nur Hash zur
   Wiedererkennung beim Revoke.

**Response 200:**
```json
{
  "token": "<gitea-personal-access-token>",
  "expires_at": "2026-05-24T11:15:30Z",
  "scope": "read:package",
  "token_id": "tk_abc123",
  "revoke_url": "/api/v1/gitea-tokens/tk_abc123"
}
```

**Response Fehlercodes:**
- `400 invalid_request` - fehlende Felder, falsches Format
- `401 unknown_key` - kein Match fuer `signature_key_fingerprint`
- `401 unknown_user` - User existiert nicht
- `403 invalid_signature` - Signatur stimmt nicht
- `403 scope_not_allowed` - Scope nicht in Whitelist
- `409 replay_detected` - nonce wiederverwendet
- `429 rate_limit` - zu viele Token-Mints (siehe Rate-Limit)
- `500 gitea_unreachable` - Gitea-Upstream down

### 3. Token-Revoke-Endpunkt

`DELETE /api/v1/gitea-tokens/{token_id}`

- Auth via Public-Key-Signatur (gleicher Mechanismus wie Mint).
- Ruft `DELETE /api/v1/users/{user}/tokens/{name}` in Gitea auf.
- Audit-Log-Eintrag mit Reason (optional Body: `{"reason": "..."}`).
- Idempotent: bereits geloeschte Token -> `204 no_content`.

### 4. Token-List-Endpunkt

`GET /api/v1/gitea-tokens?username=...`

- Auth via Public-Key-Signatur (in Headern, nicht Body).
- Liefert aktive Tokens des Users (Token-ID, Scope, expires_at, machine_id,
  last_used_at). Token-Wert NIE rausgeben.

### 5. Rate-Limiting und Abuse-Protection

- Pro User max. 10 Token-Mints pro Stunde (config). Ueberschritten -> 429.
- Pro Key max. 20 fehlgeschlagene Signature-Validierungen pro 15 Minuten,
  danach Key temporaer gesperrt + Alert an Admin.
- Total max. 1000 aktive Token pro User (verhindert Token-Spam).

### 6. Service-User in Gitea

- Ein Service-Account `sdrv4-token-broker` mit Admin-Scope in Gitea
  einrichten (in der Senity-Gitea-Instanz, separat vom SDRv4).
- Dessen Admin-PAT als Secret in der SDRv4-Konfig (`GITEA_BROKER_TOKEN`,
  `GITEA_BROKER_URL`).
- Bei Token-Rotation: zweistufiger Cutover (zwei Broker-Token parallel
  akzeptieren).

### 7. Client-Library / CLI-Helper

In der `senity`-CLI (Repo `senity/senity-code`, Pfad `senity-cli/senity.sh`
und `senity-cli/senity.ps1`):

- Neuer Subcommand `senity gitea-login`:
  1. Liest SDRv4-URL aus `~/.senity/.env`
     (`SENITY_SDRV4_URL=https://sdr.senity.ai`).
  2. Liest Username (interaktiv abfragen oder aus `.env`).
  3. Findet Private-Key (`~/.ssh/id_ed25519`, `~/.ssh/id_rsa`, oder per
     `--key`-Flag).
  4. Berechnet Public-Key-Fingerprint.
  5. POSTet an `<sdrv4>/api/v1/gitea-tokens/mint` mit signiertem Payload.
  6. Schreibt Token nach `~/.docker/config.json` via `docker login`-Aufruf
     (oder direkt JSON-Manipulation).
  7. Optional: Token-ID nach `~/.senity/gitea-token.id` (fuer spaeteren
     Revoke).

- Auto-Trigger: `senity` ohne explizites `gitea-login` ruft beim ersten
  `docker pull`-Fehler (`401 unauthorized`) automatisch `gitea-login` auf
  und versucht den Pull erneut.

### 8. Security-Constraints

- **Privater Schluessel verlaesst nie den Client.** SDRv4 sieht ausschliesslich Public-Key + Signaturen.
- Token sind kurzlebig (Default 1 h, Max 24 h).
- Signatur deckt Username, Scope, TTL, Machine-ID, Nonce, Timestamp ab. Aenderung eines Feldes invalidiert Signatur.
- Audit-Log unveraenderlich (append-only Tabelle, getrennte DB-Rolle ohne UPDATE/DELETE-Rechte).
- Public-Keys werden client-seitig in OpenSSH-Format akzeptiert,
  server-seitig in DER konvertiert und mit Algorithmus-Tag persistiert.
- Algorithmen-Whitelist: Ed25519 bevorzugt, RSA min. 3072 Bit, ECDSA
  P-256/P-384. Andere -> `400 algorithm_not_allowed`.

### 9. Datenmodell-Skizze

```sql
CREATE TABLE user_ssh_keys (
  id              BIGSERIAL PRIMARY KEY,
  user_id         BIGINT NOT NULL REFERENCES users(id),
  label           TEXT NOT NULL,
  algorithm       TEXT NOT NULL,                  -- 'ssh-ed25519' etc.
  public_key      TEXT NOT NULL,                  -- OpenSSH format
  fingerprint     TEXT NOT NULL UNIQUE,           -- 'SHA256:...'
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_used_at    TIMESTAMPTZ,
  expires_at      TIMESTAMPTZ,
  revoked_at      TIMESTAMPTZ,
  revoke_reason   TEXT
);

CREATE TABLE gitea_token_mints (
  id                     BIGSERIAL PRIMARY KEY,
  user_id                BIGINT NOT NULL REFERENCES users(id),
  key_id                 BIGINT NOT NULL REFERENCES user_ssh_keys(id),
  gitea_token_id         TEXT NOT NULL,
  gitea_token_hash       TEXT NOT NULL,                -- sha256(token)
  scope                  TEXT NOT NULL,
  ttl_seconds            INT NOT NULL,
  machine_id             TEXT,
  nonce                  TEXT NOT NULL,
  issued_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at             TIMESTAMPTZ NOT NULL,
  revoked_at             TIMESTAMPTZ,
  revoke_reason          TEXT
);
CREATE UNIQUE INDEX ON gitea_token_mints (user_id, nonce);

CREATE TABLE token_mint_audit (
  id              BIGSERIAL PRIMARY KEY,
  event_type      TEXT NOT NULL,                       -- 'mint', 'revoke', 'replay_blocked', 'invalid_sig', 'key_locked'
  user_id         BIGINT,
  key_id          BIGINT,
  token_id        BIGINT,
  remote_ip       INET,
  user_agent      TEXT,
  details         JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### 10. Akzeptanz-Kriterien

- [ ] User kann im SDRv4-UI Public-Keys hinzufuegen/sperren/loeschen.
- [ ] `POST /api/v1/gitea-tokens/mint` liefert validen Gitea-Token bei korrekter Signatur.
- [ ] Replay-Schutz wirkt (gleicher Nonce zweimal -> 409).
- [ ] Falsche Signatur wird abgelehnt (403).
- [ ] Rate-Limit wirkt (11. Mint in 1 h -> 429).
- [ ] Token-Lifetime laeuft ab (clientseitig nach `expires_at` erkennbar).
- [ ] Revoke-Endpunkt loescht Token in Gitea und im Audit-Log markiert.
- [ ] Audit-Log fuer jeden Mint/Revoke/Failure befuellt.
- [ ] `senity gitea-login`-Subcommand laeuft auf Linux, macOS, Windows (pwsh).
- [ ] Auto-Trigger bei `401`-Pull funktioniert (Test: Token revoken, `senity` aufrufen, neuer Token wird automatisch geholt).
- [ ] Algorithmen-Whitelist greift (RSA-1024 abgelehnt).
- [ ] OpenAPI-Spec generiert + in SDRv4-Docs verlinkt.

### 11. Out-of-Scope (spaetere Iterationen)

- WebAuthn/FIDO2 als Alternative zur SSH-Key-Signatur.
- Self-Service-Onboarding per Email-Bestaetigung beim Key-Upload.
- Multi-Tenancy (mehrere Gitea-Instanzen / Registries pro User).
- mTLS als zusaetzlicher Layer.

### 12. Open Questions fuer den SDRv4-Architekten

1. Soll die Signatur-Berechnung canonical JSON nutzen oder das Pipe-separated
   Format (siehe oben)? Pipe ist simpler, JSON robuster gegen Feldumstellung.
2. Sollen Tokens in `gitea_token_mints` mit Hash bleiben, oder reicht `gitea_token_id` plus Gitea-API-Lookup zum Revoke-Zeitpunkt?
3. Wie soll der Service-Account-Token (`GITEA_BROKER_TOKEN`) rotiert werden?
   Vorschlag: zweistufiger Cutover ueber Feature-Flag `GITEA_BROKER_TOKEN_FALLBACK`.
4. Brauchen wir client-seitige PKCE-aehnliche Bindung (Pre-Auth +
   Post-Auth-Exchange), um Man-in-the-Middle-Token-Diebstahl noch enger
   einzuschnueren? Vorschlag: nicht in MVP, TLS reicht.

### 13. Aufwands-Schaetzung (grob)

- Datenmodell + Migration: 1 PT
- UI Public-Key-Management: 2 PT
- Mint-/Revoke-/List-Endpunkte inkl. Audit: 3 PT
- Rate-Limit + Replay-Schutz: 1 PT
- Gitea-Adapter (Service-Account, Token-CRUD): 1 PT
- CLI-Integration (Bash + pwsh): 2 PT
- Tests (Unit + Integration mit Test-Gitea): 2 PT
- Doku + OpenAPI: 1 PT

**Gesamt: ~13 PT** (1 Sprint).

### 14. Ticket-Vorschlag fuer das SDRv4-Backlog

```
project_key: SDRv4
type_code:   FEAT
priority:    P2
title:       Public-Key-mediierte Gitea-Token-API fuer Container-Bootstrap
parent:      None (eigenes Mini-Epic, ggf. Sub-Tasks)
metadata:
  related_external_tickets: [STS-1030, STS-1031, STS-1041]
  estimate_pt: 13
```

Sub-Task-Vorschlag:
1. Datenmodell + Migration
2. UI Public-Key-Tab
3. Mint-/Revoke-/List-Endpunkte
4. Rate-Limit + Replay-Schutz
5. Gitea-Adapter
6. CLI-Integration `senity gitea-login`
7. End-to-End-Tests
8. OpenAPI + Docs

## Referenzen

- Senity-Code Master-Epic: STS-1030
- Image-Distribution: STS-1031
- Globale CLI: STS-1041
- Gitea Docs - Personal Access Tokens: https://docs.gitea.io/en-us/api-usage/
- OpenSSH Public-Key-Format: RFC 4253 + 4716
- Ed25519: RFC 8032
