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

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Benutzer anlegen (node:22-Image bringt node-User bereits mit)
RUN id -u node >/dev/null 2>&1 || useradd -m -s /bin/bash node

# Config-Verzeichnisse erstellen und Eigentuemer setzen
RUN mkdir -p /home/node/.claude /home/node/.ssh && chown -R node:node /home/node

# Standard-Umgebung
ENV HOME=/workspace
ENV TERM=xterm-256color
ENV PATH="/home/node/.local/bin:$PATH"

WORKDIR /workspace

USER node

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["claude"]
