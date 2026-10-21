import { LightningElement, api } from 'lwc';

// Stroke icons used by the Data Update Center redesign (same set as the approved mockup).
// Usage: <c-data-update-icon name="lock" size="14"></c-data-update-icon>
export default class DataUpdateIcon extends LightningElement {
    @api name;
    @api size = 14;

    get is_inbox() { return this.name === 'inbox'; }
    get is_search() { return this.name === 'search'; }
    get is_pen() { return this.name === 'pen'; }
    get is_lock() { return this.name === 'lock'; }
    get is_gear() { return this.name === 'gear'; }
    get is_form() { return this.name === 'form'; }
    get is_chart() { return this.name === 'chart'; }
    get is_eye() { return this.name === 'eye'; }
    get is_play() { return this.name === 'play'; }
    get is_rewind() { return this.name === 'rewind'; }
    get is_pause() { return this.name === 'pause'; }
    get is_x() { return this.name === 'x'; }
    get is_check() { return this.name === 'check'; }
    get is_undo() { return this.name === 'undo'; }
    get is_chev() { return this.name === 'chev'; }
    get is_chevleft() { return this.name === 'chevleft'; }
    get is_chevright() { return this.name === 'chevright'; }
    get is_refresh() { return this.name === 'refresh'; }
    get is_clock() { return this.name === 'clock'; }
    get is_list() { return this.name === 'list'; }
    get is_info() { return this.name === 'info'; }
    get is_warn() { return this.name === 'warn'; }
    get is_unlock() { return this.name === 'unlock'; }
}
