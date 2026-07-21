import { LightningElement, api, track } from 'lwc';
import { getLabels } from 'c/i18n';

const PAGE_SIZE = 4;

export default class MergeRelatedCarousel extends LightningElement {
    @track _items  = [];
    @track startIdx = 0;
    @api lang = 'en';

    @api
    get items() { return this._items; }
    set items(val) {
        this._items  = val || [];
        this.startIdx = 0;
    }

    get i18n()         { return getLabels(this.lang); }
    get visibleItems() { return this._items.slice(this.startIdx, this.startIdx + PAGE_SIZE); }
    get showArrows()      { return this._items.length > PAGE_SIZE; }
    get isPrevDisabled()  { return this.startIdx === 0; }
    get isNextDisabled()  { return this.startIdx + PAGE_SIZE >= this._items.length; }

    handlePrev(event) {
        event.stopPropagation();
        if (!this.isPrevDisabled) this.startIdx = Math.max(0, this.startIdx - 1);
    }

    handleNext(event) {
        event.stopPropagation();
        if (!this.isNextDisabled) {
            this.startIdx = Math.min(this._items.length - PAGE_SIZE, this.startIdx + 1);
        }
    }
}
