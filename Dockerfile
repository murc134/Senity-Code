FROM node:22-bookworm-slim

# System-Abhaengigkeiten
RUN apt-get update && apt-get install -y \
    git openssh-client curl jq python3 \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI installieren
RUN npm install -g @anthropic-ai/claude-code

# Benutzer anlegen
RUN useradd -m -s /bin/bash node

# Standard-Umgebung
ENV ANTHROPIC_BASE_URL=https://gateway.missionstarkeshandwerk.de
ENV ANTHROPIC_API_KEY=ollama
ENV HOME=/workspace
ENV TERM=xterm-256color
ENV PATH="/home/node/.local/bin:$PATH"

WORKDIR /workspace

USER node

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["claude", "--model", "qwen3.6"]
