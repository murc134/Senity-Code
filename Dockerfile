FROM node:22-bookworm-slim

# System-Abhaengigkeiten + Build-Tools + Chromium/Puppeteer-Libs + PDF-Toolchain
# poppler-utils liefert pdftotext/pdftoppm/pdfimages (vom pdf-Skill genutzt),
# python3-pip wird fuer die PDF-Python-Libs gebraucht (#862).
RUN apt-get update && apt-get install -y \
    git openssh-client curl ca-certificates jq python3 python3-pip python3-venv python3-dev \
    poppler-utils \
    ffmpeg libgl1 libglib2.0-0 \
    build-essential make g++ \
    libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 libgbm1 \
    libpango-1.0-0 libcairo2 libasound2 \
    fonts-liberation fontconfig \
    && rm -rf /var/lib/apt/lists/*

# Python-PDF-Libraries fuer den pdf-Skill (#862). --break-system-packages, weil
# Debian bookworm PEP 668 (externally-managed-environment) erzwingt und ein
# globaler Install im Image hier gewollt ist. pdf2image ruft intern pdftoppm
# (poppler-utils) auf.
RUN pip3 install --no-cache-dir --break-system-packages \
    pypdf pdfplumber pdf2image Pillow

# ComfyUI fuer lokale Bildgenerierung. Eigenes venv, damit die ML-Abhaengigkeiten
# nicht mit den System-/Skill-Python-Paketen kollidieren. Default ist CPU-PyTorch
# fuer breite Plattform-Kompatibilitaet; NVIDIA-Nutzer koennen beim Rebuild z.B.
# COMFYUI_TORCH_INDEX_URL=https://download.pytorch.org/whl/cu130 setzen.
ARG COMFYUI_TORCH_INDEX_URL=https://download.pytorch.org/whl/cpu
RUN python3 -m venv /opt/comfyui/venv \
    && /opt/comfyui/venv/bin/pip install --no-cache-dir --upgrade pip setuptools wheel \
    && /opt/comfyui/venv/bin/pip install --no-cache-dir torch torchvision torchaudio --index-url "${COMFYUI_TORCH_INDEX_URL}" \
    && git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git /opt/comfyui/ComfyUI \
    && /opt/comfyui/venv/bin/pip install --no-cache-dir -r /opt/comfyui/ComfyUI/requirements.txt \
    && chown -R node:node /opt/comfyui

# Claude Code CLI installieren. Globale npm-Pakete landen in einem
# node-eigenen Prefix (/opt/senity/npm), damit der Entrypoint als USER node
# bei jedem Container-Start ein Update auf @latest installieren kann
# (Ticket #2428) — /usr/local gehoert root und waere zur Laufzeit nicht
# beschreibbar. Der Prefix liegt via ENV PATH vor /usr/local/bin.
# Eine unveraenderte Kopie des Pakets bleibt unter /opt/senity/claude-upstream
# erhalten und wird ueber den Wrapper /usr/local/bin/claude-upstream
# gestartet; das normale `claude` wird unten fuer Senity gebrandet.
ENV NPM_CONFIG_PREFIX=/opt/senity/npm
# Der Wrapper ist layout-agnostisch: neue claude-code-Versionen (>= 2.1.19x)
# liefern ein natives Binary (bin/claude.exe, per postinstall entpackt),
# aeltere ein JS-Bundle (cli.js). cli-wrapper.cjs ist der offizielle
# Node-Fallback des Pakets, falls postinstall nicht lief.
RUN mkdir -p /opt/senity/npm \
    && npm install -g @anthropic-ai/claude-code@latest \
    && cp -R /opt/senity/npm/lib/node_modules/@anthropic-ai/claude-code /opt/senity/claude-upstream \
    && printf '%s\n' \
       '#!/bin/sh' \
       'd=/opt/senity/claude-upstream' \
       'if [ -x "$d/bin/claude.exe" ]; then exec "$d/bin/claude.exe" "$@"; fi' \
       'if [ -f "$d/cli.js" ]; then exec node "$d/cli.js" "$@"; fi' \
       'exec node "$d/cli-wrapper.cjs" "$@"' \
       > /usr/local/bin/claude-upstream \
    && chmod +x /usr/local/bin/claude-upstream

# Codex CLI (OpenAI / ChatGPT-Account) — Login via OAuth-Device-Flow.
# Tokens landen in $HOME/.codex/ (= /workspace/.codex/), persistieren also
# automatisch ueber den /workspace-Mount. Soft-Fail, damit das Image auch
# baut, wenn das Paket temporaer nicht erreichbar ist.
RUN npm install -g @openai/codex@latest || echo "[WARN] @openai/codex install failed (codex CLI nicht verfuegbar)"

# Google Antigravity CLI (Befehl: agy). Tokens/Settings landen unter
# $HOME/.gemini/ (= /workspace/.gemini/) und persistieren damit wie Codex.
RUN mkdir -p /home/node/.local/bin \
    && curl -fsSL https://antigravity.google/cli/install.sh | bash -s -- --dir /home/node/.local/bin \
    && chown -R node:node /home/node/.local \
    || echo "[WARN] Antigravity CLI install failed (agy CLI nicht verfuegbar)"

# Gemini CLI (Google-Account) — Login via OAuth. Tokens landen in
# $HOME/.gemini/ (= /workspace/.gemini/). Ebenfalls soft-fail.
RUN npm install -g @google/gemini-cli || echo "[WARN] @google/gemini-cli install failed (gemini CLI nicht verfuegbar)"

# Senity Theme (zentrale Farb-Konfiguration) ins Image kopieren.
# CRLF defensiv strippen, falls die Datei auf einem Host mit core.autocrlf=true
# ausgecheckt wurde (bash wuerde sonst an "$'\r': command not found" sterben).
COPY senity-theme.conf /etc/senity-theme.conf
RUN sed -i 's/\r$//' /etc/senity-theme.conf

# Natives Custom-Theme (Ebene 2: CLI-Farb-Token). Claude Code laedt
# Custom-Themes aus ~/.claude/themes/*.json; der Entrypoint kopiert diese
# Datei beim Start dorthin und setzt sie als Default via activeCustomTheme.
COPY senity-theme.json /etc/senity-theme.json

# Welcome-Box-Strings + Anthropic-Orange auf Senity-Farben patchen.
# Das Script bleibt an einem persistenten Pfad im Image, damit der Entrypoint
# es nach dem Startzeit-Update erneut anwenden kann (Ticket #2428). Der
# Build-Lauf brandet die Image-Version als Offline-Fallback; der Marker
# haelt fest, welche Paket-Version zuletzt gepatcht wurde.
COPY patch-claude-header.js /usr/local/lib/senity/patch-claude-header.js
RUN sed -i 's/\r$//' /usr/local/lib/senity/patch-claude-header.js \
    && SENITY_THEME_FILE=/etc/senity-theme.conf node /usr/local/lib/senity/patch-claude-header.js \
    && node -p "require('/opt/senity/npm/lib/node_modules/@anthropic-ai/claude-code/package.json').version" \
       > /opt/senity/.senity-patched-version

COPY senity-sync-models.js /usr/local/bin/senity-sync-models
RUN sed -i 's/\r$//' /usr/local/bin/senity-sync-models \
    && chmod +x /usr/local/bin/senity-sync-models

COPY senity-comfyui /usr/local/bin/senity-comfyui
RUN sed -i 's/\r$//' /usr/local/bin/senity-comfyui \
    && chmod +x /usr/local/bin/senity-comfyui

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN sed -i 's/\r$//' /docker-entrypoint.sh
COPY senity-mascot-filter.py /usr/local/bin/senity-mascot-filter
# CRLF strippen, falls die Datei auf einem Windows-Host mit core.autocrlf=true
# ausgecheckt wurde (Shebang scheitert sonst mit 'python3\r': Exit 127).
RUN sed -i 's/\r$//' /usr/local/bin/senity-mascot-filter \
    && chmod +x /docker-entrypoint.sh /usr/local/bin/senity-mascot-filter

# Benutzer anlegen (node:22-Image bringt node-User bereits mit)
RUN id -u node >/dev/null 2>&1 || useradd -m -s /bin/bash node

# SSH-Verzeichnis fuer node-User anlegen
RUN mkdir -p /home/node/.ssh && chown -R node:node /home/node

# /opt/senity dem node-User uebergeben: der Entrypoint aktualisiert dort bei
# jedem Container-Start Claude Code (npm-Prefix), die claude-upstream-Kopie
# und den Patch-Marker (Ticket #2428).
RUN chown -R node:node /opt/senity

# Standard-Umgebung
ENV HOME=/workspace
ENV TERM=xterm-256color
ENV PATH="/opt/senity/npm/bin:/home/node/.local/bin:$PATH"
# Selbst-Update von Claude Code in der Session deaktivieren: Updates laufen
# ausschliesslich beim Container-Start (Entrypoint), sonst wuerde der
# Autoupdater den Senity-Branding-Patch unbemerkt ueberschreiben.
ENV DISABLE_AUTOUPDATER=1

WORKDIR /workspace

USER node

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["senity-mascot-filter", "claude"]
