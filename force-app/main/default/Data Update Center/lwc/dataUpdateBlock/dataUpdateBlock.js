import { LightningElement, api } from 'lwc';
import { getLabels } from 'c/dataUpdateI18n';
import { buildRuns, blockStyle } from 'c/dataUpdateTextStyle';
import { safeImageUrl, videoEmbedUrl, BLOCK_RECOMMENDED } from 'c/dataUpdateBlocks';

// Height (px) or width (%) per size, for each block type.
const IMAGE_WIDTH = { S: '33%', M: '60%', L: '100%' };
const BANNER_HEIGHT = { S: 120, M: 180, L: 240 };
const LOGO_HEIGHT = { S: 48, M: 72, L: 104 };
const SPACER_HEIGHT = { S: 12, M: 28, L: 56 };

// One design block (Tools tab) as the respondent sees it. In the builder (preview) the video
// is a placeholder — Lightning's CSP blocks YouTube/Vimeo frames — and empty blocks show a hint.
export default class DataUpdateBlock extends LightningElement {
    @api block;
    @api lang = 'fr';
    @api uiLang;
    // 'preview' in the builder, empty on the portal.
    @api mode;

    get preview() { return this.mode === 'preview'; }

    get b() { return this.block || {}; }
    get L() { return getLabels(this.uiLang || this.lang); }
    get size() { return this.b.size || 'M'; }

    get isTitle() { return this.b.type === 'title'; }
    get isText() { return this.b.type === 'text'; }
    get isPicture() { return ['image', 'banner', 'logo'].includes(this.b.type); }
    get isVideo() { return this.b.type === 'video'; }
    get isDivider() { return this.b.type === 'divider'; }
    get isSpacer() { return this.b.type === 'spacer'; }

    get rawText() { return (this.lang === 'en' ? this.b.en : this.b.fr) || ''; }
    get hasText() { return this.rawText.trim().length > 0; }
    get textEmpty() { return this.preview && !this.hasText; }
    get emptyText() { return this.isTitle ? this.L.builderBlockEmptyTitle : this.L.builderBlockEmptyText; }
    get textStyle() { return blockStyle(this.b.st); }
    get runs() { return buildRuns(this.rawText, this.b.st, this.lang, true); }

    get imageUrl() { return safeImageUrl(this.b.url); }
    get hasImage() { return !!this.imageUrl; }
    get showImage() { return this.isPicture && this.hasImage; }
    get showImageEmpty() { return this.isPicture && !this.hasImage && this.preview; }
    get imageAlt() { return (this.lang === 'en' ? this.b.altEn : this.b.altFr) || ''; }
    get pictureWrapStyle() {
        return `text-align: ${this.b.type === 'banner' ? 'center' : this.b.align === 'left' ? 'left' : 'center'}`;
    }
    get imageStyle() {
        const t = this.b.type;
        if (t === 'banner') return `width: 100%; height: ${BANNER_HEIGHT[this.size]}px; object-fit: cover; border-radius: 8px; display: block`;
        if (t === 'logo') return `height: ${LOGO_HEIGHT[this.size]}px; width: auto; max-width: 100%; display: inline-block`;
        return `width: ${IMAGE_WIDTH[this.size]}; height: auto; border-radius: 6px; display: inline-block`;
    }
    get emptyImageStyle() {
        const t = this.b.type;
        if (t === 'banner') return `height: ${BANNER_HEIGHT[this.size]}px`;
        if (t === 'logo') return `height: ${LOGO_HEIGHT[this.size]}px; width: ${LOGO_HEIGHT[this.size] * 2}px; display: inline-flex`;
        return `height: 120px; width: ${IMAGE_WIDTH[this.size]}; display: inline-flex`;
    }
    get emptyImageLabel() {
        const t = this.b.type;
        const name = t === 'banner' ? this.L.builderBlockBanner : t === 'logo' ? this.L.builderBlockLogo : this.L.builderBlockImage;
        // The empty placeholder tells the size to upload for the chosen S/M/L.
        const r = BLOCK_RECOMMENDED[t] && BLOCK_RECOMMENDED[t][this.size];
        if (!r) return name;
        const px = r.w && r.h ? `${r.w} × ${r.h} px` : r.h ? `↕ ${r.h} px` : `↔ ${r.w} px`;
        return `${name} · ${px}`;
    }

    get embedUrl() { return videoEmbedUrl(this.b.url); }
    get showFrame() { return this.isVideo && !this.preview && !!this.embedUrl; }
    get showVideoStub() { return this.isVideo && this.preview; }
    get videoStubText() { return this.b.url || this.L.builderVideoHint; }
    get videoTitle() { return this.L.blockVideoTitle; }

    get spacerStyle() { return `height: ${SPACER_HEIGHT[this.size]}px`; }
}
