#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════
// patch-claude-header.js
//
// Patcht im @anthropic-ai/claude-code-Paket:
//   - Welcome-Box-Strings (englisch -> Senity-deutsch)
//   - Anthropic-Orange Hex/RGB Farb-Codes -> Senity-Farben aus senity-theme.conf
//
// Unterstuetzt:
//   - JS-Bundles (.js/.mjs/.cjs) - klassisches Search-Replace
//   - Natives Binary (bin/claude.exe als ELF/PE) - LAENGEN-ERHALTENDES Patching
//
// Bei Binary-Patches muss der Ersatz-String exakt dieselbe Byte-Laenge haben
// wie das Original (sonst zerschiesst es Offset-Tabellen). Text-Replacements
// werden automatisch mit Spaces auf Originallaenge gepaddet bzw. abgeschnitten.
//
// Laeuft einmalig im Docker-Build. Idempotent.
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
    for (let raw of lines) {
        const line = raw.trim();
        if (line.startsWith('#') || line === '') continue;
        // 1. Quoted Wert: KEY="value" (Wert darf '#' enthalten, wichtig fuer Hex)
        let m = line.match(/^([A-Z0-9_]+)\s*=\s*"([^"]*)"\s*(#.*)?$/);
        if (m) { theme[m[1]] = m[2]; continue; }
        // 2. Unquoted Wert: KEY=value (kein '#' im Wert erlaubt, Rest ist Kommentar)
        m = line.match(/^([A-Z0-9_]+)\s*=\s*([^"#\s]+)\s*(#.*)?$/);
        if (m) { theme[m[1]] = m[2]; continue; }
    }
    console.log(`[patch] Theme geladen: ${themePath} (PRIMARY_HEX=${theme.PRIMARY_HEX})`);
} else {
    console.log('[patch] Theme-File fehlt, nutze Defaults');
}

const P = theme.PRIMARY_256;
const S = theme.SECONDARY_256;
const PR = theme.PRIMARY_RGB;
const SR = theme.SECONDARY_RGB;
const PH = theme.PRIMARY_HEX;
const SH = theme.SECONDARY_HEX;

// ─── Text-Ersetzungen ───────────────────────────────────────────
// Reihenfolge wichtig: laengere Patterns zuerst, sonst frisst der kuerzere
// den laengeren auf ("Welcome back" frisst "Welcome back!").
const textReplacements = [
    ['Run /init to create a CLAUDE.md file with instructions for Claude',
     'Tippe /init zum Anlegen einer CLAUDE.md mit Senity-Hinweisen'],
    ['Tips for getting started',   'Senity Quick-Start-Tipps'],
    ['API Usage Billing',          'Senity Chat Proxy'],
    ['Welcome back!',              'Willkommen!'],     // 13B -> 11B + 2 Spaces padding
    ["What's new",                 'Neuheiten'],       // 10B -> 9B + 1 Space padding
    // Welcome-Box-Titel: "Claude Code" (11B) -> "Senity Wksp" (11B). Voller String
    // "Senity Workspace v1.0" passt nicht in den Binary-Slot ohne Code-Surgery.
    // Mehrere Slots: ,"Claude Code") , title:"Claude Code" , name:"Claude Code"
    [',"Claude Code")',            ',"Senity Wksp")'],   // 15B -> 15B
    ['title:"Claude Code"',        'title:"Senity Wksp"'], // 19B -> 19B
    ['name:"Claude Code"',         'name:"Senity Wksp"'],  // 18B -> 18B
    // Version-Konstante: "2.1.143" (7B) -> "1.0    " (7B mit Trailing-Spaces).
    // dimColor im Welcome-Box rendert Trailing-Spaces unsichtbar.
    ['VERSION:"2.1.143"',          'VERSION:"1.0    "'], // 17B -> 17B
];

// ─── Farb-Ersetzungen ───────────────────────────────────────────
// Anthropic-CLI nutzt aktuell genau ein Orange (#da7756 via chalk.hex)
// plus diverse 256-color und truecolor Codes in legacy-Builds. Wir
// ersetzen alle bekannten Varianten auf Senity-Lila (PRIMARY).
const colorReplacements = [
    // ─ Named theme colors (welcome-box border/title/headlines) ─
    // Claude Code 2.x nutzt "claude" / "claudeShimmer" Theme-Tokens, die
    // intern als "rgb(R,G,B)"-Strings vorliegen (3 Theme-Varianten).
    ['rgb(215,119,87)',  `rgb(${PR.replace(/;/g, ',')})`],  // claude (light + dark)
    ['rgb(245,149,117)', `rgb(${SR.replace(/;/g, ',')})`],  // claudeShimmer light
    ['rgb(235,159,127)', `rgb(${SR.replace(/;/g, ',')})`],  // claudeShimmer dark
    ['rgb(255,153,51)',  `rgb(${PR.replace(/;/g, ',')})`],  // claude bright
    ['rgb(255,183,101)', `rgb(${SR.replace(/;/g, ',')})`],  // claudeShimmer bright
    // ─ Hex-Literale (chalk.hex('#...')) ─
    ['#da7756', PH.toLowerCase()],   // aktueller Anthropic-Orange
    ['#DA7756', PH],
    ['#d97757', PH.toLowerCase()],
    ['#D97757', PH],
    ['#cc5834', PH.toLowerCase()],
    ['#CC5834', PH],
    ['#d7875f', PH.toLowerCase()],
    ['#D7875F', PH],
    ['#e68a6c', SH.toLowerCase()],
    ['#E68A6C', SH],
    ['#ff875f', SH.toLowerCase()],
    ['#FF875F', SH],
    // ─ 256-color foreground ─
    ['38;5;208',  `38;5;${P}`],
    ['38;5;202',  `38;5;${P}`],
    ['38;5;166',  `38;5;${P}`],
    ['38;5;172',  `38;5;${P}`],
    ['38;5;173',  `38;5;${P}`],
    ['38;5;214',  `38;5;${S}`],
    ['38;5;209',  `38;5;${S}`],
    ['38;5;215',  `38;5;${S}`],
    // ─ 256-color background ─
    ['48;5;208',  `48;5;${P}`],
    ['48;5;202',  `48;5;${P}`],
    ['48;5;173',  `48;5;${P}`],
    ['48;5;214',  `48;5;${S}`],
    // ─ Truecolor Foreground ─
    ['38;2;218;119;86',  `38;2;${PR}`],  // #da7756
    ['38;2;217;119;87',  `38;2;${PR}`],
    ['38;2;204;88;52',   `38;2;${PR}`],
    ['38;2;215;135;95',  `38;2;${PR}`],
    ['38;2;230;138;108', `38;2;${SR}`],
    ['38;2;255;135;95',  `38;2;${SR}`],
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

// ─── File-Sammlung ──────────────────────────────────────────────
function walk(dir, out = []) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        if (entry.name.startsWith('.')) continue;
        const p = path.join(dir, entry.name);
        if (entry.isDirectory()) {
            walk(p, out);
        } else if (entry.isFile()) {
            out.push(p);
        }
    }
    return out;
}

function isLikelyBinary(buf) {
    // ELF (0x7F 'E' 'L' 'F')
    if (buf.length >= 4 && buf[0] === 0x7F && buf[1] === 0x45 && buf[2] === 0x4C && buf[3] === 0x46) return true;
    // PE (MZ)
    if (buf.length >= 2 && buf[0] === 0x4D && buf[1] === 0x5A) return true;
    // Mach-O
    if (buf.length >= 4 && ((buf[0] === 0xCF || buf[0] === 0xCE) && buf[1] === 0xFA && buf[2] === 0xED && buf[3] === 0xFE)) return true;
    if (buf.length >= 4 && (buf[0] === 0xFE && buf[1] === 0xED && buf[2] === 0xFA && (buf[3] === 0xCF || buf[3] === 0xCE))) return true;
    return false;
}

function isTextFile(name) {
    return /\.(js|mjs|cjs|json|md)$/i.test(name);
}

// ─── Patching ───────────────────────────────────────────────────
function patchTextFile(file) {
    let content;
    try { content = fs.readFileSync(file, 'utf8'); } catch { return [0, 0]; }
    let textHits = 0, colorHits = 0;
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
    if (textHits + colorHits > 0) fs.writeFileSync(file, content);
    return [textHits, colorHits];
}

// Padding: ergaenzt Replacement auf exakte Byte-Laenge des Originals.
// - Wenn replacement kuerzer -> mit Spaces rechts auffuellen
// - Wenn replacement laenger -> Warnung + skip (zerstoert Binary)
function padToLength(replacement, targetLen, label) {
    const repBuf = Buffer.from(replacement, 'utf8');
    if (repBuf.length === targetLen) return repBuf;
    if (repBuf.length < targetLen) {
        const pad = Buffer.alloc(targetLen - repBuf.length, 0x20);
        return Buffer.concat([repBuf, pad]);
    }
    console.warn(`[patch]   SKIP ${label}: replacement (${repBuf.length}B) > original (${targetLen}B)`);
    return null;
}

function patchBinaryFile(file) {
    let buf;
    try { buf = fs.readFileSync(file); } catch { return [0, 0]; }
    let textHits = 0, colorHits = 0;
    let changed = false;

    // Text-Patches: laengenerhaltend mit Space-Padding
    for (const [from, to] of textReplacements) {
        const fromBuf = Buffer.from(from, 'utf8');
        const toBuf = padToLength(to, fromBuf.length, `"${from}"`);
        if (!toBuf) continue;
        let offset = 0;
        while ((offset = buf.indexOf(fromBuf, offset)) !== -1) {
            toBuf.copy(buf, offset);
            textHits++;
            offset += fromBuf.length;
            changed = true;
        }
    }

    // Color-Patches: muessen sowieso gleiche Laenge haben
    for (const [from, to] of colorReplacements) {
        const fromBuf = Buffer.from(from, 'utf8');
        const toBuf = Buffer.from(to, 'utf8');
        if (fromBuf.length !== toBuf.length) {
            console.warn(`[patch]   SKIP color ${from}->${to}: length mismatch (${fromBuf.length} vs ${toBuf.length})`);
            continue;
        }
        let offset = 0;
        while ((offset = buf.indexOf(fromBuf, offset)) !== -1) {
            toBuf.copy(buf, offset);
            colorHits++;
            offset += fromBuf.length;
            changed = true;
        }
    }

    if (changed) fs.writeFileSync(file, buf);
    return [textHits, colorHits];
}

// ─── Main ───────────────────────────────────────────────────────
const files = walk(pkgDir);
let totalText = 0, totalColor = 0, touchedFiles = 0;

for (const file of files) {
    let kind = null;
    if (isTextFile(file)) {
        kind = 'text';
    } else {
        // unbekannte Extension -> Magic-Bytes pruefen
        try {
            const head = Buffer.alloc(4);
            const fd = fs.openSync(file, 'r');
            fs.readSync(fd, head, 0, 4, 0);
            fs.closeSync(fd);
            if (isLikelyBinary(head)) kind = 'binary';
        } catch { /* skip */ }
    }
    if (!kind) continue;

    const [t, c] = kind === 'binary' ? patchBinaryFile(file) : patchTextFile(file);
    if (t + c > 0) {
        const rel = path.relative(pkgDir, file);
        console.log(`[patch] ${rel} (${kind}): text=${t}, color=${c}`);
        totalText += t;
        totalColor += c;
        touchedFiles++;
    }
}

console.log(`[patch] Gesamt: text=${totalText}, color=${totalColor} in ${touchedFiles} Datei(en)`);
if (totalText === 0 && totalColor === 0) {
    console.warn('[patch] WARN: keine Treffer. CLI evtl. veraendert (Update?).');
}
