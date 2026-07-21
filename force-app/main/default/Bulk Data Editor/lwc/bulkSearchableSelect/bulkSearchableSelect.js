import { LightningElement, api } from 'lwc';

// Type-to-filter combobox. Native lightning-combobox has no built-in
// search/filter for long option lists, so this replaces it wherever a
// picklist can realistically have dozens+ of options (objects, fields,
// picklist values) — typing "S" narrows the list to every option whose
// label contains "S", instead of forcing the user to scroll.
export default class BulkSearchableSelect extends LightningElement {
    @api label;
    @api placeholder = 'Search...';
    @api disabled = false;

    _options = [];
    @api
    get options() {
        return this._options;
    }
    set options(value) {
        this._options = value || [];
        this.syncSearchTermFromValue();
    }

    _value;
    @api
    get value() {
        return this._value;
    }
    set value(val) {
        this._value = val;
        this.syncSearchTermFromValue();
    }

    searchTerm = '';
    isOpen = false;

    syncSearchTermFromValue() {
        const found = this._options.find((o) => o.value === this._value);
        this.searchTerm = found ? found.label : '';
    }

    get filteredOptions() {
        const term = (this.searchTerm || '').trim().toLowerCase();
        const selectedLabel = this.selectedLabel;
        // searchTerm still holds the previously-selected label until the user
        // actually types something new (e.g. right after handleFocus reopens
        // the dropdown) — don't filter against it, otherwise reopening a
        // populated field shows only the current selection instead of the
        // full list.
        if (!term || term === (selectedLabel || '').toLowerCase()) {
            return this._options;
        }
        return this._options.filter((o) => o.label.toLowerCase().includes(term));
    }

    get selectedLabel() {
        const found = this._options.find((o) => o.value === this._value);
        return found ? found.label : '';
    }

    get showNoResults() {
        return this.isOpen && this.filteredOptions.length === 0;
    }

    get hasValue() {
        return !!(this.searchTerm && this.searchTerm.length);
    }

    get comboboxClass() {
        const base = 'slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click';
        return this.isOpen ? `${base} slds-is-open` : base;
    }

    handleFocus() {
        if (this.disabled) {
            return;
        }
        this.isOpen = true;
    }

    handleInput(event) {
        this.searchTerm = event.target.value;
        this.isOpen = true;
    }

    handleBlur() {
        // Delay so a click on an option (which also fires blur first) still
        // registers before the dropdown is torn down.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        window.setTimeout(() => {
            this.isOpen = false;
            this.syncSearchTermFromValue();
        }, 200);
    }

    handleOptionMouseDown(event) {
        event.preventDefault();
    }

    handleClearMouseDown(event) {
        // Same race as handleOptionMouseDown: without preventDefault the
        // input's blur fires first and tears the dropdown down before the
        // click is registered.
        event.preventDefault();
    }

    handleClear(event) {
        event.preventDefault();
        event.stopPropagation();
        // Only clears the typed/displayed text so the user can search again
        // without backspacing a long label — it does not unselect the bound
        // value. If they click away without picking a new option,
        // handleBlur's syncSearchTermFromValue() restores the current
        // selection's label, same as native combobox behavior.
        this.searchTerm = '';
        this.isOpen = true;
        const input = this.template.querySelector('input');
        if (input) {
            input.focus();
        }
    }

    handleOptionClick(event) {
        const val = event.currentTarget.dataset.value;
        this._value = val;
        this.isOpen = false;
        this.syncSearchTermFromValue();
        this.dispatchEvent(new CustomEvent('change', { detail: { value: val } }));
    }
}
