// Uniform look of one form (font + colors), shared by the builder preview and the public portal.
// Portal_Appearance__c holds { font, question, section, accent }; every missing key means the
// standard look. Only the fixed font stacks below and #rrggbb colors ever reach an inline style,
// set as CSS variables (--duc-*) that the portal's CSS reads with the standard look as fallback.
// FONTS keys must match APPEARANCE_FONTS in DataUpdateFormAdminController.

export const FONTS = [
    { key: 'standard', label: 'Standard', stack: "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif" },
    { key: 'modern', label: 'Moderne / Modern', stack: "system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif" },
    { key: 'verdana', label: 'Verdana', stack: 'Verdana, Geneva, Tahoma, sans-serif' },
    { key: 'trebuchet', label: 'Trebuchet', stack: "'Trebuchet MS', 'Lucida Grande', sans-serif" },
    { key: 'georgia', label: 'Georgia', stack: "Georgia, 'Times New Roman', serif" },
    { key: 'palatino', label: 'Palatino', stack: "'Palatino Linotype', Palatino, 'Book Antiqua', serif" }
];

export const DEFAULTS = { font: 'standard', question: '#3e3e3c', section: '#181818', accent: '#0176d3' };
export const COLOR_KEYS = ['question', 'section', 'accent'];

const HEX = /^#[0-9a-f]{6}$/;

export function cleanHex(value) {
    let v = (value || '').trim().toLowerCase();
    if (v && v[0] !== '#') v = '#' + v;
    if (/^#[0-9a-f]{3}$/.test(v)) v = '#' + v[1] + v[1] + v[2] + v[2] + v[3] + v[3];
    return HEX.test(v) ? v : null;
}

// Always a complete object (defaults filled in), whatever the stored JSON holds.
export function parseAppearance(json) {
    const a = { ...DEFAULTS };
    let raw = {};
    try {
        raw = json ? JSON.parse(json) || {} : {};
    } catch (e) {
        raw = {};
    }
    if (FONTS.some((f) => f.key === raw.font)) a.font = raw.font;
    COLOR_KEYS.forEach((k) => {
        const hex = cleanHex(raw[k]);
        if (hex) a[k] = hex;
    });
    return a;
}

// Same canonical JSON as the server's normalizeAppearance (fixed key order, defaults left out
// except colors explicitly set), or '' for the standard look.
export function serializeAppearance(a) {
    const out = {};
    if (a && a.font && a.font !== 'standard' && FONTS.some((f) => f.key === a.font)) out.font = a.font;
    COLOR_KEYS.forEach((k) => {
        const hex = a ? cleanHex(a[k]) : null;
        if (hex && hex !== DEFAULTS[k]) out[k] = hex;
    });
    return Object.keys(out).length ? JSON.stringify(out) : '';
}

export function isDefaultAppearance(a) {
    return serializeAppearance(a) === '';
}

// Inline style for the portal container (or the builder's preview paper).
export function appearanceStyle(a) {
    const ap = a || DEFAULTS;
    const font = (FONTS.find((f) => f.key === ap.font) || FONTS[0]).stack;
    const color = (k) => cleanHex(ap[k]) || DEFAULTS[k];
    return `--duc-font: ${font}; --duc-question: ${color('question')}; --duc-section: ${color('section')}; --duc-accent: ${color('accent')};`;
}

export function fontStack(key) {
    return (FONTS.find((f) => f.key === key) || FONTS[0]).stack;
}

// WCAG contrast ratio against white (text on the white form, white text on the accent button).
export function contrastOnWhite(hex) {
    const v = cleanHex(hex);
    if (!v) return 21;
    const channel = (i) => {
        const c = parseInt(v.substr(i, 2), 16) / 255;
        return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    };
    const lum = 0.2126 * channel(1) + 0.7152 * channel(3) + 0.0722 * channel(5);
    return 1.05 / (lum + 0.05);
}

export const MIN_CONTRAST = 4.5;
