// Shared helpers for the Data Update Center redesign (status colors, ticket numbers, initials, dates).
// Colors come from the --duc-* tokens defined on the dataUpdateCenter root.

const STATUS_KEYS = {
    New: 'new',
    'In Review': 'review',
    'On Hold': 'hold',
    Reopened: 'reopen',
    Applied: 'applied',
    Ignored: 'ignored',
    Closed: 'ignored',
    Error: 'error'
};

export const OPEN_STATUSES = ['New', 'In Review', 'On Hold', 'Reopened', 'Error'];

export function isOpenStatus(status) {
    return OPEN_STATUSES.includes(status);
}

export function statusKey(status) {
    return STATUS_KEYS[status] || 'ignored';
}

// Inline style that feeds --sc / --sbg to ticket pills and dots — always neutral gray.
// Colors are only used on the dashboard bars (see DEFAULT_DASH_COLORS).
export function statusStyle() {
    return '--sc:var(--duc-neutral);--sbg:var(--duc-neutral-bg)';
}

// Dashboard "By status" bar colors (status key -> hex), editable in the color panel.
export const DEFAULT_DASH_COLORS = {
    new: '#0b5cab',
    review: '#7a4cc2',
    hold: '#b26b00',
    reopen: '#c2410c',
    applied: '#1f7a3f',
    ignored: '#5d6b7e',
    error: '#b42318'
};

const DASH_COLORS_KEY = 'dataUpdateCenter_dashColors';
const HEX = /^#[0-9a-f]{6}$/i;

// Colors chosen by this user, kept in this browser only; bad/missing values fall back to defaults.
export function loadDashColors() {
    const colors = { ...DEFAULT_DASH_COLORS };
    try {
        const raw = JSON.parse(localStorage.getItem(DASH_COLORS_KEY) || '{}') || {};
        Object.keys(colors).forEach((k) => { if (HEX.test(raw[k] || '')) colors[k] = raw[k]; });
    } catch (e) {
        // storage unavailable — defaults
    }
    return colors;
}

export function saveDashColors(colors) {
    try {
        localStorage.setItem(DASH_COLORS_KEY, JSON.stringify(colors || {}));
    } catch (e) {
        // storage unavailable — colors only kept for this session
    }
}

export function toneStyle(key) {
    return `--sc:var(--duc-${key});--sbg:var(--duc-${key}-bg)`;
}

export function statusLabel(i18n, status) {
    switch (status) {
        case 'New': return i18n.statusNew;
        case 'In Review': return i18n.statusInReview;
        case 'On Hold': return i18n.statusOnHold;
        case 'Applied': return i18n.statusApplied;
        case 'Ignored': return i18n.statusIgnored;
        case 'Closed': return i18n.statusClosed;
        case 'Reopened': return i18n.statusReopened;
        case 'Error': return i18n.statusError;
        default: return status || '';
    }
}

// '000000013' -> { zeros: '0000000', digits: '13' } so the leading zeros can be dimmed.
export function ticketNumber(value) {
    const raw = value || '';
    const m = /^(0*)(\d+)$/.exec(raw);
    return m ? { zeros: m[1], digits: m[2], full: raw } : { zeros: '', digits: raw, full: raw };
}

export function initials(name) {
    return String(name || '')
        .replace(/^Église\s+/i, '')
        .split(/\s+/)
        .filter((w) => /^[A-ZÀ-ÖØ-Þ]/.test(w))
        .slice(0, 2)
        .map((w) => w[0])
        .join('') || String(name || '?').trim().charAt(0).toUpperCase();
}

function locale(lang) {
    return lang === 'en' ? 'en-CA' : 'fr-CA';
}

export function formatDateTime(value, lang) {
    if (!value) return '';
    return new Date(value).toLocaleString(locale(lang), {
        month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'
    });
}

export function formatDate(value, lang) {
    if (!value) return '';
    return new Date(value).toLocaleDateString(locale(lang), {
        year: 'numeric', month: 'short', day: 'numeric'
    });
}
