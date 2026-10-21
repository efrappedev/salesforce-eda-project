import { LightningElement, api, track } from 'lwc';
import { getLabels } from 'c/i18n';

// Page size adapts to the card width: each item needs at least MIN_ITEM_PX,
// and the arrows take ARROWS_PX when not everything fits.
const MIN_ITEM_PX  = 78;
const ARROWS_PX    = 52;
const MAX_PAGE     = 6;
const DEFAULT_PAGE = 4;

export default class MergeRelatedCarousel extends LightningElement {
    @track _items  = [];
    @track startIdx = 0;
    @track pageSize = DEFAULT_PAGE;
    @api lang = 'en';

    _resizeObserver;
    _width = 0;

    @api
    get items() { return this._items; }
    set items(val) {
        this._items  = val || [];
        this.startIdx = 0;
        this._recalcPageSize();
    }

    get i18n()         { return getLabels(this.lang); }
    get visibleItems() { return this._items.slice(this.startIdx, this.startIdx + this.pageSize); }
    get showArrows()      { return this._items.length > this.pageSize; }
    get isPrevDisabled()  { return this.startIdx === 0; }
    get isNextDisabled()  { return this.startIdx + this.pageSize >= this._items.length; }

    renderedCallback() {
        if (this._resizeObserver || typeof ResizeObserver === 'undefined') return;
        const wrap = this.template.querySelector('.carousel-wrap');
        if (!wrap) return;
        this._resizeObserver = new ResizeObserver(entries => {
            const w = entries && entries[0] ? entries[0].contentRect.width : 0;
            if (w && Math.abs(w - this._width) >= 1) {
                this._width = w;
                this._recalcPageSize();
            }
        });
        this._resizeObserver.observe(wrap);
    }

    disconnectedCallback() {
        if (this._resizeObserver) {
            this._resizeObserver.disconnect();
            this._resizeObserver = null;
        }
    }

    _recalcPageSize() {
        if (!this._width) return;
        const total = this._items.length;
        let size;
        if (total * MIN_ITEM_PX <= this._width) {
            size = total;
        } else {
            size = Math.floor((this._width - ARROWS_PX) / MIN_ITEM_PX);
        }
        size = Math.max(1, Math.min(size, MAX_PAGE, Math.max(total, 1)));
        if (size !== this.pageSize) this.pageSize = size;
        const maxStart = Math.max(0, total - this.pageSize);
        if (this.startIdx > maxStart) this.startIdx = maxStart;
    }

    handlePrev(event) {
        event.stopPropagation();
        if (!this.isPrevDisabled) this.startIdx = Math.max(0, this.startIdx - 1);
    }

    handleNext(event) {
        event.stopPropagation();
        if (!this.isNextDisabled) {
            this.startIdx = Math.min(this._items.length - this.pageSize, this.startIdx + 1);
        }
    }
}
