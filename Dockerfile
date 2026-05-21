FROM node:22-bookworm-slim

# System-Abhaengigkeiten + Build-Tools + Chromium/Puppeteer-Libs
RUN apt-get update && apt-get install -y \
    git openssh-client curl jq python3 \
    build-essential make g++ \
    libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 libgbm1 \
    libpango-1.0-0 libcairo2 libasound2 \
    fonts-liberation fontconfig \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI installieren
RUN npm install -g @anthropic-ai/claude-code

# Codex CLI (OpenAI / ChatGPT-Account) — Login via OAuth-Device-Flow.
# Tokens landen in $HOME/.codex/ (= /workspace/.codex/), persistieren also
# automatisch ueber den /workspace-Mount. Soft-Fail, damit das Image auch
# baut, wenn das Paket temporaer nicht erreichbar ist.
RUN npm install -g @openai/codex || echo "[WARN] @openai/codex install failed (codex CLI nicht verfuegbar)"

# Gemini CLI (Google-Account) — Login via OAuth. Tokens landen in
# $HOME/.gemini/ (= /workspace/.gemini/). Ebenfalls soft-fail.
RUN npm install -g @google/gemini-cli || echo "[WARN] @google/gemini-cli install failed (gemini CLI nicht verfuegbar)"

# Senity Theme (zentrale Farb-Konfiguration) ins Image kopieren.
# CRLF defensiv strippen, falls die Datei auf einem Host mit core.autocrlf=true
# ausgecheckt wurde (bash wuerde sonst an "$'\r': command not found" sterben).
COPY senity-theme.conf /etc/senity-theme.conf
RUN sed -i 's/\r$//' /etc/senity-theme.conf

# Welcome-Box-Strings + Anthropic-Orange auf Senity-Farben patchen
COPY patch-claude-header.js /tmp/patch-claude-header.js
RUN SENITY_THEME_FILE=/etc/senity-theme.conf node /tmp/patch-claude-header.js \
    && rm /tmp/patch-claude-header.js

COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY senity-mascot-filter.py /usr/local/bin/senity-mascot-filter
RUN chmod +x /docker-entrypoint.sh /usr/local/bin/senity-mascot-filter

# Benutzer anlegen (node:22-Image bringt node-User bereits mit)
RUN id -u node >/dev/null 2>&1 || useradd -m -s /bin/bash node

# SSH-Verzeichnis fuer node-User anlegen
RUN mkdir -p /home/node/.ssh && chown -R node:node /home/node

# Standard-Umgebung
ENV HOME=/workspace
ENV TERM=xterm-256color
ENV PATH="/home/node/.local/bin:$PATH"

WORKDIR /workspace

USER node

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["senity-mascot-filter", "claude"]
