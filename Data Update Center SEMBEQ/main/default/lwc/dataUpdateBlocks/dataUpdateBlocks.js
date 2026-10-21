// Design blocks of the form builder's Tools tab, shared by the builder and the public portal.
// Portal_Blocks__c holds a JSON array of blocks:
//   [{ id, type, screen: 'login'|'form'|'locked'|'pending'|'confirm', after, afterVisible?, section?, fr, en, st, url, altFr, altEn, size, align }]
// "after" anchors a block right after a fixed item ("@lookupTitle"…), the start of a section
// ("s:<FR title>|<EN title>"), a question ("q:<field key>") or another block ("b:<id>").
// "afterVisible" is the nearest previous item the respondent actually sees (hidden questions
// never reach the portal); the portal uses it, the builder uses "after". "section" is the
// block's section, the fallback when its question is removed outside the builder.
import { cleanEntry } from 'c/dataUpdateTextStyle';

export const PAGE_TYPES = ['banner', 'logo', 'spacer'];
export const CONTENT_TYPES = ['title', 'text', 'image', 'video', 'divider'];
export const BLOCK_TYPES = [...PAGE_TYPES, ...CONTENT_TYPES];
export const TEXT_TYPES = ['title', 'text'];
export const IMAGE_TYPES = ['banner', 'logo', 'image'];
export const BLOCK_SIZES = ['S', 'M', 'L'];
export const BLOCK_ALIGNS = ['left', 'center'];
export const LOGIN_ANCHORS = ['@start', '@lookupTitle', '@lookupSubtitle', '@idField', '@button'];
// Message screens of the portal (record locked, request already pending, request sent): each
// has a fixed title and message, with blocks around them like the Login screen.
export const MESSAGE_SCREENS = {
    locked: ['@start', '@lockedTitle', '@lockedMessage'],
    pending: ['@start', '@pendingTitle', '@pendingMessage'],
    confirm: ['@start', '@confirmTitle', '@confirmMessage']
};
const BLOCK_SCREENS = ['login', 'form', ...Object.keys(MESSAGE_SCREENS)];
export const TEXT_MAX_LENGTH = 1000;
// Recommended upload sizes (px) per block size: twice what the portal shows in its 480 px wide
// card, so pictures stay sharp on phones and retina screens. Banner = width × height (cropped to
// fit), logo = minimum height, image = minimum width.
export const BLOCK_RECOMMENDED = {
    banner: { S: { w: 1000, h: 250 }, M: { w: 1000, h: 375 }, L: { w: 1000, h: 500 } },
    logo: { S: { h: 100 }, M: { h: 150 }, L: { h: 210 } },
    image: { S: { w: 400 }, M: { w: 600 }, L: { w: 1000 } }
};
const ALT_MAX_LENGTH = 200;
const URL_MAX_LENGTH = 1000;
// Same hosts as DataUpdateFormAdminController.BLOCK_URL_HOST_SUFFIXES.
const IMAGE_HOSTS = ['force.com', 'salesforce.com'];

const str = (v, max) => (typeof v === 'string' ? v.slice(0, max) : '');

function hostOf(url) {
    // "\\", "@" or spaces could make the browser load another host than the one read here.
    if (/[\\@\s]/.test(url || '')) return '';
    const m = /^https:\/\/([^/?#:]+)/i.exec(url || '');
    return m ? m[1].toLowerCase() : '';
}

// Only https Salesforce Files links are shown as images (what the portal's CSP allows).
export function safeImageUrl(url) {
    const host = hostOf(url);
    return host && IMAGE_HOSTS.some((h) => host === h || host.endsWith('.' + h)) ? url : '';
}

// YouTube/Vimeo page link -> embeddable player URL, or '' when it isn't one.
export function videoEmbedUrl(url) {
    const u = (url || '').trim();
    let m = /^https:\/\/(?:www\.|m\.)?youtube\.com\/(?:watch\?(?:[^#]*&)?v=|embed\/|shorts\/|live\/)([\w-]{6,})/i.exec(u)
        || /^https:\/\/youtu\.be\/([\w-]{6,})/i.exec(u);
    if (m) return `https://www.youtube.com/embed/${m[1]}`;
    // Unlisted Vimeo links carry a privacy hash (vimeo.com/123/abc or ?h=abc) the player needs.
    m = /^https:\/\/(?:www\.|player\.)?vimeo\.com\/(?:video\/)?(\d+)(?:\/([\da-f]+))?(?:[^#]*[?&]h=([\da-f]+))?/i.exec(u);
    if (m) return `https://player.vimeo.com/video/${m[1]}` + (m[2] || m[3] ? `?h=${m[2] || m[3]}` : '');
    return '';
}

export function cleanBlock(b) {
    if (!b || typeof b !== 'object' || !BLOCK_TYPES.includes(b.type)) return null;
    const id = str(b.id, 40).replace(/[^\w-]/g, '');
    if (!id) return null;
    const out = { id, type: b.type, screen: BLOCK_SCREENS.includes(b.screen) ? b.screen : 'form', after: str(b.after, 300) || '' };
    if (b.afterVisible && b.afterVisible !== b.after) out.afterVisible = str(b.afterVisible, 300);
    if (b.section) out.section = str(b.section, 300);
    if (TEXT_TYPES.includes(b.type)) {
        out.fr = str(b.fr, TEXT_MAX_LENGTH);
        out.en = str(b.en, TEXT_MAX_LENGTH);
        const st = cleanEntry(b.st);
        if (st) out.st = st;
    }
    if (IMAGE_TYPES.includes(b.type)) {
        const url = safeImageUrl(str(b.url, URL_MAX_LENGTH));
        if (url) out.url = url;
        out.altFr = str(b.altFr, ALT_MAX_LENGTH);
        out.altEn = str(b.altEn, ALT_MAX_LENGTH);
    }
    if (b.type === 'video') {
        const url = str(b.url, URL_MAX_LENGTH).trim();
        if (url && videoEmbedUrl(url)) out.url = url;
    }
    if (BLOCK_SIZES.includes(b.size) && b.size !== 'M') out.size = b.size;
    if (BLOCK_ALIGNS.includes(b.align) && b.align !== 'center') out.align = b.align;
    return out;
}

// A block id is its render key and anchor: keep only the first block with a given id.
function uniqueIds(list) {
    const seen = new Set();
    return list.filter((b) => !seen.has(b.id) && seen.add(b.id));
}

export function parseBlocks(json) {
    if (!json) return [];
    try {
        const list = JSON.parse(json);
        return Array.isArray(list) ? uniqueIds(list.map(cleanBlock).filter(Boolean)) : [];
    } catch (e) {
        return [];
    }
}

export function serializeBlocks(blocks) {
    const list = uniqueIds((blocks || []).map(cleanBlock).filter(Boolean));
    return list.length ? JSON.stringify(list) : '';
}

export function sectionAnchor(fr, en) {
    return `s:${(fr || '').trim()}|${(en || '').trim()}`;
}

export function questionAnchor(key) {
    return key ? 'q:' + key.toLowerCase() : '';
}

// Places blocks on their anchors, given the anchors of one screen in display order.
// Returns anchor -> ordered blocks (a block's own followers right after it). A block whose
// anchor no longer exists falls back to its other anchor, then to the last anchor, so nothing
// published ever disappears.
export function placeBlocks(blocks, anchors, useVisible) {
    const placed = new Map();
    if (!anchors.length) return placed;
    const known = new Set(anchors);
    blocks.forEach((b) => known.add('b:' + b.id));
    const last = anchors[anchors.length - 1];
    const of = (b) => [useVisible ? b.afterVisible : null, b.after, b.afterVisible, b.section].find((a) => a && known.has(a)) || last;
    const seen = new Set();
    const chain = (anchor) => {
        const out = [];
        blocks.forEach((b) => {
            if (seen.has(b.id) || of(b) !== anchor) return;
            seen.add(b.id);
            out.push(b, ...chain('b:' + b.id));
        });
        return out;
    };
    anchors.forEach((a) => {
        if (!placed.has(a)) placed.set(a, chain(a));
    });
    blocks.forEach((b) => {
        if (seen.has(b.id)) return;
        seen.add(b.id);
        placed.get(last).push(b, ...chain('b:' + b.id));
    });
    return placed;
}

let seq = 0;
export function newBlockId() {
    seq++;
    return Date.now().toString(36) + seq.toString(36) + Math.floor(Math.random() * 1296).toString(36);
}
