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
    // Version-Konstante: "2.1.143" (7B) -> "1.0    " (7B mit Trailing-Spaces).
    // dimColor im Welcome-Box rendert Trailing-Spaces unsichtbar.
    ['VERSION:"2.1.143"',          'VERSION:"1.0    "'], // 17B -> 17B
    // ─ Generisches Branding-Rewrite ─
    // Jedes exakte "Claude" -> "Senity" (auch "Claude Code" -> "Senity Code",
    // Welcome-Box-Titel, System-Prompt, Hilfe-/Abrechnungstexte).
    // MUSS die letzte Regel sein, damit die spezifischen Phrasen oben zuerst
    // greifen. "Claude" und "Senity" sind beide 6 Byte -> binary-safe, kein
    // Padding. Case-sensitiv: "claude" (CLI-Befehl, npm-Pfad @anthropic-ai/
    // claude-code, Theme-Tokens) und "CLAUDE" (CLAUDE.md, /init) bleiben
    // bewusst unberuehrt — ihre Ersetzung wuerde Funktionalitaet zerstoeren.
    ['Claude',                     'Senity'],
];

// ─── Spinner-Woerter (Senity) ──────────────────────────────────
// Ersetzt Claude Codes ~187 englische Arbeits-Gerundien ("Osmosing",
// "Pondering", ...) durch Senity-eigene Begriffe. Laengenerhaltend:
// "Original" -> "Custom", rechts mit Spaces auf die Original-Byte-
// Laenge gepaddet (Space landet AUSSERHALB der Quotes -> gueltiges
// JSON, der angezeigte String-Wert bleibt sauber). Custom-Wort muss
// <= Original sein; zu kurze Slots ("Doing" etc.) -> Fallback.
const SPINNER_ORIGINALS = [
  "Accomplishing","Actioning","Actualizing","Architecting","Baking","Beaming",
  "Beboppin'","Befuddling","Billowing","Blanching","Bloviating","Boogieing",
  "Boondoggling","Booping","Bootstrapping","Brewing","Bunning","Burrowing",
  "Calculating","Canoodling","Caramelizing","Cascading","Catapulting","Cerebrating",
  "Channeling","Channelling","Choreographing","Churning","Clauding","Coalescing",
  "Cogitating","Combobulating","Composing","Computing","Concocting","Considering",
  "Contemplating","Cooking","Crafting","Creating","Crunching","Crystallizing",
  "Cultivating","Deciphering","Deliberating","Determining","Dilly-dallying","Discombobulating",
  "Doing","Doodling","Drizzling","Ebbing","Effecting","Elucidating",
  "Embellishing","Enchanting","Envisioning","Evaporating","Fermenting","Fiddle-faddling",
  "Finagling","Flamb\xE9ing","Flibbertigibbeting","Flowing","Flummoxing","Fluttering",
  "Forging","Forming","Frolicking","Frosting","Gallivanting","Galloping",
  "Garnishing","Generating","Gesticulating","Germinating","Gitifying","Grooving",
  "Gusting","Harmonizing","Hashing","Hatching","Herding","Honking",
  "Hullaballooing","Hyperspacing","Ideating","Imagining","Improvising","Incubating",
  "Inferring","Infusing","Ionizing","Jitterbugging","Julienning","Kneading",
  "Leavening","Levitating","Lollygagging","Manifesting","Marinating","Meandering",
  "Metamorphosing","Misting","Moonwalking","Moseying","Mulling","Mustering",
  "Musing","Nebulizing","Nesting","Newspapering","Noodling","Nucleating",
  "Orbiting","Orchestrating","Osmosing","Perambulating","Percolating","Perusing",
  "Philosophising","Photosynthesizing","Pollinating","Pondering","Pontificating","Pouncing",
  "Precipitating","Prestidigitating","Processing","Proofing","Propagating","Puttering",
  "Puzzling","Quantumizing","Razzle-dazzling","Razzmatazzing","Recombobulating","Reticulating",
  "Roosting","Ruminating","Saut\xE9ing","Scampering","Schlepping","Scurrying",
  "Seasoning","Shenaniganing","Shimmying","Simmering","Skedaddling","Sketching",
  "Slithering","Smooshing","Sock-hopping","Spelunking","Spinning","Sprouting",
  "Stewing","Sublimating","Swirling","Swooping","Symbioting","Synthesizing",
  "Tempering","Thinking","Thundering","Tinkering","Tomfoolering","Topsy-turvying",
  "Transfiguring","Transmuting","Twisting","Undulating","Unfurling","Unravelling",
  "Vibing","Waddling","Wandering","Warping","Whatchamacalliting","Whirlpooling",
  "Whirring","Whisking","Wibbling","Working","Wrangling","Zesting",
  "Zigzagging",
];
const SPINNER_CUSTOM = [
  "Zaubern","Lösen","Erschaffen","Kreieren","Optimieren",
  "Verbessern","Weiterentwickeln","Senitieren","Sinnieren","Kombinieren",
  "Veredeln","Entschlüsseln","Begeistern","Beschleunigen","Vereinfachen"
];
const SPINNER_FALLBACK = "Denkt";
{
  const _bl = (s) => Buffer.byteLength(s, "utf8");
  let _ci = 0;
  for (const _orig of SPINNER_ORIGINALS) {
    const _slot = _bl('"' + _orig + '"');
    let _pick = null;
    for (let _k = 0; _k < SPINNER_CUSTOM.length; _k++) {
      const _cand = SPINNER_CUSTOM[(_ci + _k) % SPINNER_CUSTOM.length];
      if (_bl('"' + _cand + '"') <= _slot) { _pick = _cand; _ci = (_ci + _k + 1) % SPINNER_CUSTOM.length; break; }
    }
    if (!_pick && _bl('"' + SPINNER_FALLBACK + '"') <= _slot) _pick = SPINNER_FALLBACK;
    if (_pick) textReplacements.push(['"' + _orig + '"', '"' + _pick + '"']);
  }
}


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

// ─── Theme-Token: jetzt ueber natives Custom-Theme, NICHT mehr hier ──
// Frueher injizierte dieser Patch ein eigenes "senity"-Theme in den Resolver-
// Switch des Bundles (case"senity" + GS1-Liste + Picker-Eintrag, gestuetzt auf
// minifizierte Variablennamen GS1/_N_/AN_). Seit Claude Code als kompiliertes
// Native-Binary ausgeliefert wird, existiert dieser JS-Switch im Artefakt nicht
// mehr (0 Treffer), und laengenerhaltendes rgb()-Recoloring im Binary scheitert
// an unterschiedlichen Byte-Laengen (z.B. warning rgb(255,193,7) -> rgb(255,90,200)).
//
// Die Ebene-2-Farb-Token liefert daher das native Custom-Theme-Feature:
// senity-theme.json -> ~/.claude/themes/senity.json, aktiviert per
// activeCustomTheme="custom:senity" (siehe docker-entrypoint.sh). Update-fest,
// keine Abhaengigkeit von minifizierten Symbolen, keine Laengen-Limits.
//
// Dieser Patch beschraenkt sich auf Branding (textReplacements: "Claude"->
// "Senity", Spinner-Woerter) und das laengenerhaltende Orange->Lila-Recoloring
// (colorReplacements) als sane Fallback-Basis, falls das Custom-Theme einmal
// nicht laedt.

// ─── npm root finden ────────────────────────────────────────────
let root;
try {
    root = execSync('npm root -g', { encoding: 'utf8' }).trim();
} catch (e) {
    console.error('[patch] npm root -g fehlgeschlagen:', e.message);
    process.exit(1);
}

const pkgDir = path.join(root, '@anthropic-ai', 'claude-code');
if (!fs.existsSync(pkgDir)) {
    console.error('[patch] claude-code Package nicht gefunden unter', pkgDir);
    process.exit(1);
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
console.log('[patch] Ebene-2-Farb-Token kommen vom nativen Custom-Theme '
    + '(senity-theme.json, aktiviert via entrypoint).');
