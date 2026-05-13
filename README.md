# claude-msh

CLI-Shortcut, der Claude Code gegen die Self-Hosted MSH-Modelle laufen laesst.
Spricht das oeffentliche Gateway `https://gateway.missionstarkeshandwerk.de` —
**kein SSH-Tunnel, kein Docker noetig**, nur die Claude Code CLI plus ein
Auth-Token.

## Was das Script macht

1. Liest den Auth-Token (`LITELLM_MASTER_KEY`) aus Env-Var oder Config-Datei.
2. Setzt `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`.
3. Startet `claude --model <gewaehlt>` und reicht alle weiteren Args durch.

## Voraussetzungen

- Node.js + Claude Code:
  ```bash
  npm install -g @anthropic-ai/claude-code
  ```
- Auth-Token. Steht auf opus in `/home/msh/gateway-stack/.env` unter
  `LITELLM_MASTER_KEY=`. Beginnt mit `sk-msh-local-…`.

## Installation auf Linux / macOS / opus

```bash
# 1. Script global verfuegbar machen
sudo cp scripts/claude-msh/claude-msh.sh /usr/local/bin/claude-msh
sudo chmod +x /usr/local/bin/claude-msh

# 2. Token einmalig hinterlegen — eine der beiden Varianten:

# Variante A: Env-Var in ~/.bashrc oder ~/.zshrc
echo 'export LITELLM_MASTER_KEY="sk-msh-local-..."' >> ~/.bashrc

# Variante B: Config-Datei (chmod 600)
mkdir -p ~/.config/claude-msh
echo 'sk-msh-local-...' > ~/.config/claude-msh/auth
chmod 600 ~/.config/claude-msh/auth

# 3. Test
claude-msh --list           # Modelle vom Gateway
claude-msh                  # startet Claude Code mit qwen3.6
```

Auf opus selbst: gleiche Schritte, der Endpoint zeigt eh auf den lokalen
Caddy → Gateway. Wenn du lokal direkt am LiteLLM andocken willst, geht auch
`claude-msh -e http://127.0.0.1:4000`.

## Installation auf Windows

```powershell
# 1. Token als User-Env-Var setzen (PowerShell als normaler User reicht)
[Environment]::SetEnvironmentVariable('LITELLM_MASTER_KEY','sk-msh-local-...','User')

# 2. Script-Ordner ins PATH aufnehmen — z.B. nach %USERPROFILE%\bin kopieren
mkdir "$env:USERPROFILE\bin" -ErrorAction SilentlyContinue
copy scripts\claude-msh\claude-msh.bat "$env:USERPROFILE\bin\"
copy scripts\claude-msh\claude-msh.ps1 "$env:USERPROFILE\bin\"

# Pfad einmalig in User-PATH ergaenzen, falls noch nicht drin:
$old = [Environment]::GetEnvironmentVariable('Path','User')
if ($old -notlike "*$env:USERPROFILE\bin*") {
    [Environment]::SetEnvironmentVariable('Path', "$old;$env:USERPROFILE\bin", 'User')
}

# 3. Neues Terminal oeffnen (damit PATH + Env-Var greifen)
# 4. Test
claude-msh -List
claude-msh
```

Alternative ohne PATH: einfach `claude-msh.bat` per Doppelklick oder via
voll qualifiziertem Pfad starten.

## Verwendung

```bash
claude-msh                           # Default-Modell qwen3.6
claude-msh -m gpt-4o                 # anderes Modell waehlen
claude-msh -m gemini-2.5-pro
claude-msh -m qwen3-coder-next       # Coding-Spezialist
claude-msh --list                    # alle Modelle vom Gateway
claude-msh -e http://127.0.0.1:4000  # anderen Endpoint (z.B. lokal auf opus)
claude-msh -p "kurzer prompt"        # alles nach den eigenen Optionen geht 1:1 an `claude`
```

Auf Windows lauten die Optionen `-Model`, `-Endpoint`, `-List` (PowerShell-Stil),
sonst identisch.

## Verfuegbare Modelle (Stand 2026-05-03)

Self-Hosted (laufen auf opus, kostenlos, DSGVO-konform):
- `qwen3.6` / `qwen3.6:35b` — Default, hybrid Mamba+Transformer MoE (35B/3B)
- `qwen3.6-abliterated:35b` — uncensored Variante
- `qwen3-coder-next` / `qwen3-coder-next:latest` — Coding-Spezialist
- `gemma4` — Google Gemma 4

Cloud (gehen ueber LiteLLM, kosten Geld):
- `gpt-4.1`, `gpt-4o`, `gpt-4o-mini`, `o1`, `o3`, `o3-mini`, `o4-mini`
- `gemini-2.5-pro`, `gemini-2.5-flash`, `gemini-2.5-flash-lite`

## Troubleshooting

**`FEHLER: Kein Auth-Token gefunden`**
→ `LITELLM_MASTER_KEY` ist nicht gesetzt und `~/.config/claude-msh/auth`
existiert nicht. Schritt 2 der Installation nachholen.

**`401 Unauthorized` vom Gateway**
→ Token ist falsch oder veraltet. Auf opus checken:
`grep LITELLM_MASTER_KEY /home/msh/gateway-stack/.env`.

**Claude Code zeigt komische Tool-Call-Fehler**
→ Das Anthropic-Format auf Port 11434 (LiteLLM-Proxy) hat eine bekannte
Streaming-Inkompatibilitaet. Deshalb routet Caddy `/v1/messages` auf den
cc-adapter (Port 8765). Sollte transparent sein — wenn nicht, oeffne
ein Ticket.

**`thinking`-Mode aktivieren**
→ Geht aktuell nicht ueber den Anthropic-Pfad (LiteLLM droppt
`extra_body` bei der Konvertierung). Wer Reasoning braucht, ruft
`/v1/chat/completions` direkt auf — das ist kein Claude-Code-Use-Case.
