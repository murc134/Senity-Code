#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════
// patch-claude-header.js
//
// Ueberschreibt im @anthropic-ai/claude-code-Bundle:
//   - Welcome-Box-Strings (englisch -> Senity-deutsch)
//   - Anthropic-Orange Farb-Codes -> Senity-Farben aus senity-theme.conf
//
// Laeuft einmalig im Docker-Build (nach `npm install -g claude-code`).
// Idempotent: zweiter Lauf macht nichts (Strings/Codes sind weg).
//
// Theme-File: /tmp/senity-theme.conf (Build-Time)
// ════════════════════════════════════════════════════════════════
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// ─── Theme laden ────────────────────────────────────────────────
const themePath = process.env.SENITY_THEME_FILE || '/tmp/senity-theme.conf';
const theme = {
    PRIMARY_256:   '99',
    PRIMARY_HEX:   '#875FAF',
    PRIMARY_RGB:   '135;95;175',
    SECONDARY_256: '141',
    SECONDARY_HEX: '#AF87FF',
    SECONDARY_RGB: '175;135;255',
    ACCENT_256:    '199',
    ACCENT_HEX:    '#FF00AF',
    ACCENT_RGB:    '255;0;175',
};
if (fs.existsSync(themePath)) {
    const lines = fs.readFileSync(themePath, 'utf8').split(/\r?\n/);
    for (const raw of lines) {
        const line = raw.replace(/#.*$/, '').trim();
        if (!line) continue;
        const m = line.match(/^([A-Z0-9_]+)\s*=\s*"?([^"]*)"?\s*$/);
        if (!m) continue;
        theme[m[1]] = m[2];
    }
    console.log(`[patch] Theme geladen: ${themePath}`);
} else {
    console.log('[patch] Theme-File fehlt, nutze Defaults');
}

// ─── Text-Ersetzungen ───────────────────────────────────────────
const textReplacements = [
    ['Welcome back!',              'Willkommen bei Senity!'],
    ['Tips for getting started',   'Senity Hinweise'],
    ["What's new",                 'Senity Updates'],
    ['API Usage Billing',          'Senity Chat Proxy'],
    ['Run /init to create a CLAUDE.md file with instructions for Claude',
     'Tippe /init um eine CLAUDE.md mit Senity-Anweisungen anzulegen'],
];

// ─── Farb-Ersetzungen (Anthropic-Orange -> Senity-Theme) ────────
// Mapping: helles/mittleres Orange -> SECONDARY, dunkles/sattes Orange -> PRIMARY
const P = theme.PRIMARY_256;
const S = theme.SECONDARY_256;
const PR = theme.PRIMARY_RGB;
const SR = theme.SECONDARY_RGB;
const PH = theme.PRIMARY_HEX;
const SH = theme.SECONDARY_HEX;

const colorReplacements = [
    // ─ 256-color foreground ─
    ['38;5;208',  `38;5;${P}`],   // bright orange #ff8700
    ['38;5;202',  `38;5;${P}`],   // deep orange #ff5f00
    ['38;5;166',  `38;5;${P}`],   // dark orange-red #d75f00
    ['38;5;172',  `38;5;${P}`],   // dark orange #d78700
    ['38;5;173',  `38;5;${P}`],   // muted orange #d7875f (Anthropic-Look)
    ['38;5;130',  `38;5;${P}`],
    ['38;5;131',  `38;5;${P}`],
    ['38;5;214',  `38;5;${S}`],   // yellow-orange #ffaf00
    ['38;5;209',  `38;5;${S}`],   // light coral #ff875f
    ['38;5;215',  `38;5;${S}`],   // peach #ffaf5f
    ['38;5;216',  `38;5;${S}`],   // light peach #ffaf87
    ['38;5;217',  `38;5;${S}`],   // pinkish #ffafaf
    // ─ 256-color background ─
    ['48;5;208',  `48;5;${P}`],
    ['48;5;202',  `48;5;${P}`],
    ['48;5;173',  `48;5;${P}`],
    ['48;5;214',  `48;5;${S}`],
    // ─ Truecolor Foreground ─
    ['38;2;217;119;87',  `38;2;${PR}`],   // #D97757 Anthropic-Orange
    ['38;2;204;88;52',   `38;2;${PR}`],   // dunkler
    ['38;2;215;135;95',  `38;2;${PR}`],   // #D7875F
    ['38;2;230;138;108', `38;2;${SR}`],   // heller
    ['38;2;255;135;95',  `38;2;${SR}`],   // #FF875F
    ['38;2;255;175;0',   `38;2;${SR}`],
    ['38;2;255;135;0',   `38;2;${PR}`],
    // ─ Hex-Literale (chalk.hex('#...')) ─
    ['#D97757', PH],
    ['#d97757', PH.toLowerCase()],
    ['#CC5834', PH],
    ['#cc5834', PH.toLowerCase()],
    ['#D7875F', PH],
    ['#d7875f', PH.toLowerCase()],
    ['#E68A6C', SH],
    ['#e68a6c', SH.toLowerCase()],
    ['#FF875F', SH],
    ['#ff875f', SH.toLowerCase()],
];

// ─── npm root finden ────────────────────────────────────────────
let root;
try {
    root = execSync('npm root -g', { encoding: 'utf8' }).trim();
} catch (e) {
    console.error('[patch] npm root -g fehlgeschlagen:', e.message);
    process.exit(0);
}

const pkgDir = path.join(root, '@anthropic-ai', 'claude-code');
if (!fs.existsSync(pkgDir)) {
    console.error('[patch] claude-code Package nicht gefunden unter', pkgDir);
    process.exit(0);
}

function walk(dir) {
    const out = [];
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        if (entry.name === 'node_modules' || entry.name.startsWith('.')) continue;
        const p = path.join(dir, entry.name);
        if (entry.isDirectory()) {
            out.push(...walk(p));
        } else if (entry.isFile() && /\.(js|mjs|cjs)$/.test(entry.name)) {
            out.push(p);
        }
    }
    return out;
}

const files = walk(pkgDir);
let totalText = 0;
let totalColor = 0;
let touchedFiles = 0;

for (const file of files) {
    let content;
    try {
        content = fs.readFileSync(file, 'utf8');
    } catch (e) {
        continue;
    }

    let textHits = 0;
    let colorHits = 0;

    for (const [from, to] of textReplacements) {
        if (!content.includes(from)) continue;
        const parts = content.split(from);
        content = parts.join(to);
        textHits += parts.length - 1;
    }
    for (const [from, to] of colorReplacements) {
        if (!content.includes(from)) continue;
        const parts = content.split(from);
        content = parts.join(to);
        colorHits += parts.length - 1;
    }

    if (textHits + colorHits > 0) {
        fs.writeFileSync(file, content);
        const rel = path.relative(pkgDir, file);
        console.log(`[patch] ${rel}: text=${textHits}, color=${colorHits}`);
        totalText += textHits;
        totalColor += colorHits;
        touchedFiles++;
    }
}

console.log(`[patch] Gesamt: text=${totalText}, color=${totalColor} in ${touchedFiles} Datei(en)`);
if (totalText === 0 && totalColor === 0) {
    console.warn('[patch] WARN: keine Treffer. CLI evtl. veraendert (Update?).');
}
