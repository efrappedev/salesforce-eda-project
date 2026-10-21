// Text palette of the form builder, shared by the builder preview and the public portal.
// Portal_Text_Styles__c holds, per portal text key, a whole-text style plus styled word
// ranges per language:
//   { formTitle: { style: { b, i, u, color, bg, size, align },
//                  marks: { fr: [{ start, end, s: { b, i, u, color, bg } }], en: [...] } } }
// Only the fixed palette values below ever reach an inline style, whatever the JSON holds.

export const TEXT_COLORS = [
    { key: 'default', value: null },
    { key: 'black', value: '#111827' },
    { key: 'gray', value: '#6b7280' },
    { key: 'blue', value: '#2457c5' },
    { key: 'green', value: '#1e7a4c' },
    { key: 'orange', value: '#b45309' },
    { key: 'red', value: '#b42318' },
    { key: 'burgundy', value: '#8c2a3c' },
    { key: 'purple', value: '#6d28d9' }
];

export const HIGHLIGHTS = [
    { key: 'none', value: null },
    { key: 'yellow', value: '#fff3b0' },
    { key: 'green', value: '#d9f2e3' },
    { key: 'blue', value: '#dde8fb' },
    { key: 'pink', value: '#fde2e4' }
];

export const SIZES = ['S', 'M', 'L'];
export const ALIGNS = ['left', 'center'];

const MAX_MARKS = 40;
const COLOR_SET = new Set(TEXT_COLORS.map((c) => c.value).filter(Boolean));
const BG_SET = new Set(HIGHLIGHTS.map((c) => c.value).filter(Boolean));
const SIZE_EM = { S: '0.85em', L: '1.25em' };

function cleanStyle(s, withBlock) {
    const out = {};
    if (!s || typeof s !== 'object') return out;
    if (s.b === true || s.b === false) out.b = s.b;
    if (s.i === true || s.i === false) out.i = s.i;
    if (s.u === true || s.u === false) out.u = s.u;
    if (s.color === null || COLOR_SET.has(s.color)) out.color = s.color;
    if (s.bg === null || BG_SET.has(s.bg)) out.bg = s.bg;
    if (withBlock) {
        if (SIZES.includes(s.size) && s.size !== 'M') out.size = s.size;
        if (ALIGNS.includes(s.align) && s.align !== 'left') out.align = s.align;
    }
    return out;
}

function cleanMarks(list) {
    if (!Array.isArray(list)) return [];
    return list
        .filter((m) => m && Number.isInteger(m.start) && Number.isInteger(m.end) && m.end > m.start && m.start >= 0)
        .map((m) => ({ start: m.start, end: m.end, s: cleanStyle(m.s, false) }))
        .filter((m) => Object.keys(m.s).length > 0)
        .slice(-MAX_MARKS);
}

// One text entry with only valid values, or null when it styles nothing.
export function cleanEntry(entry) {
    if (!entry || typeof entry !== 'object') return null;
    const style = cleanStyle(entry.style, true);
    // Whole-text "off" values (b: false, color: null…) are the default look: drop them.
    Object.keys(style).forEach((k) => {
        if (style[k] === false || style[k] === null) delete style[k];
    });
    const marks = { fr: cleanMarks(entry.marks && entry.marks.fr), en: cleanMarks(entry.marks && entry.marks.en) };
    const out = {};
    if (Object.keys(style).length) out.style = style;
    if (marks.fr.length || marks.en.length) out.marks = marks;
    return Object.keys(out).length ? out : null;
}

// Map of key -> entry, in the given key order (stable JSON for change detection).
export function cleanStyles(styles, keys) {
    const out = {};
    keys.forEach((k) => {
        const e = cleanEntry(styles && styles[k]);
        if (e) out[k] = e;
    });
    return out;
}

export function parseStyles(json, keys) {
    if (!json) return {};
    try {
        return cleanStyles(JSON.parse(json), keys);
    } catch (e) {
        return {};
    }
}

export function serializeStyles(styles, keys) {
    const clean = cleanStyles(styles, keys);
    return Object.keys(clean).length ? JSON.stringify(clean) : '';
}

function runCss(e) {
    const parts = [];
    if (e.color) parts.push(`color: ${e.color}`);
    // false only comes from a word range un-styling part of a styled text.
    if (e.b === true) parts.push('font-weight: 700');
    else if (e.b === false) parts.push('font-weight: 400');
    if (e.i === true) parts.push('font-style: italic');
    else if (e.i === false) parts.push('font-style: normal');
    if (e.u === true) parts.push('text-decoration: underline');
    else if (e.u === false) parts.push('text-decoration: none');
    if (e.bg) parts.push(`background: ${e.bg}; border-radius: 3px; padding: 0 2px`);
    return parts.join('; ');
}

// Style of the element holding the text (alignment and size apply to the whole text).
export function blockStyle(entry) {
    const st = (entry && entry.style) || {};
    const parts = [];
    if (st.align === 'center') parts.push('text-align: center');
    if (SIZE_EM[st.size]) parts.push(`font-size: ${SIZE_EM[st.size]}`);
    return parts.join('; ');
}

// The text cut into styled runs. Word ranges only apply to a custom text (useMarks): they were
// taken on that text, not on the standard one shown when it's blank.
export function buildRuns(text, entry, lang, useMarks) {
    const value = text || '';
    const st = cleanStyle(entry && entry.style, false);
    const marks = useMarks ? cleanMarks(entry && entry.marks && entry.marks[lang]) : [];
    const cuts = new Set([0, value.length]);
    marks.forEach((m) => {
        cuts.add(Math.min(m.start, value.length));
        cuts.add(Math.min(m.end, value.length));
    });
    const pts = Array.from(cuts).sort((a, z) => a - z);
    const runs = [];
    for (let k = 0; k < pts.length - 1; k++) {
        const a = pts[k];
        const z = pts[k + 1];
        if (z <= a) continue;
        const eff = { ...st };
        marks.forEach((m) => {
            if (m.start <= a && m.end >= z) Object.assign(eff, m.s);
        });
        runs.push({ key: `r${k}`, t: value.slice(a, z), style: runCss(eff) });
    }
    if (!runs.length) runs.push({ key: 'r0', t: value, style: runCss(st) });
    return runs;
}

// Effective inline style at one character (used to toggle B/I/U on a word range).
export function styleAt(entry, lang, pos) {
    const eff = cleanStyle(entry && entry.style, false);
    cleanMarks(entry && entry.marks && entry.marks[lang]).forEach((m) => {
        if (m.start <= pos && m.end > pos) Object.assign(eff, m.s);
    });
    return eff;
}
