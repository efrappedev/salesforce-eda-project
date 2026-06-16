import { LightningElement, api } from 'lwc';
import { getLabels } from 'c/i18n';

export default class MergeComparisonMatrix extends LightningElement {
    @api matrix;
    @api masterId;
    @api fieldDecisions;
    @api loserIds;
    @api lang = 'fr';

    get i18n() { return getLabels(this.lang); }

    // ── Filtered record IDs: only master + selected losers ───────────────────

    get filteredRecordIds() {
        if (!this.matrix) return [];
        const all = this.matrix.recordIds;
        const losers = this.loserIds;
        if (losers && losers.length > 0) {
            return all.filter(id => id === this.masterId || losers.includes(id));
        }
        return all;
    }

    // ── Column headers ────────────────────────────────────────────────────────

    get columns() {
        if (!this.matrix) return [];
        return this.filteredRecordIds.map(id => {
            const i      = this.matrix.recordIds.indexOf(id);
            const isMaster = id === this.masterId;
            const rc       = this.matrix.relatedCountsByRecordId?.[id] || {};
            return {
                recordId:             id,
                recordName:           this.matrix.recordNames[i],
                isMaster,
                hasActiveEnrollments: rc.hasActiveRecords,
                headerClass:          isMaster
                    ? 'matrix-table__record-col matrix-table__record-col_master'
                    : 'matrix-table__record-col'
            };
        });
    }

    // ── Body rows ─────────────────────────────────────────────────────────────

    get tableRows() {
        if (!this.matrix) return [];
        const decisions = this.fieldDecisions || {};

        return this.matrix.rows.map(row => {
            const selectedId    = decisions[row.fieldApiName] || this.masterId;
            // Apply same '—' fallback as displayValue so null==null → same, null≠'X' → different
            const selectedValue = row.valuesByRecordId?.[selectedId] ?? '—';
            const isReadOnly    = row.isUpdateable === false;

            const cells = this.filteredRecordIds.map(id => {
                const displayValue = row.valuesByRecordId?.[id] ?? '—';
                const isSelected   = id === selectedId;
                // Amber tint: conflict row, not the selected cell, value differs from selected
                const isDifferent  = row.hasConflict && !isSelected
                                     && displayValue !== selectedValue;

                let cellClass = 'matrix-table__value-col';
                if (isSelected)       cellClass += ' matrix-table__value-col_selected';
                else if (isDifferent) cellClass += ' matrix-table__value-col_different';

                return { recordId: id, displayValue, isSelected, isDifferent, cellClass };
            });

            return {
                fieldApiName:   row.fieldApiName,
                fieldLabel:     row.fieldLabel,
                isEdaField:     row.isEdaField,
                hasConflict:    row.hasConflict && !isReadOnly,
                isReadOnly,
                cells,
                radioGroupName: `f_${row.fieldApiName}`,
                rowClass:       row.isEdaField
                    ? 'matrix-table__row matrix-table__row_eda'
                    : (row.hasConflict && !isReadOnly)
                        ? 'matrix-table__row matrix-table__row_conflict'
                        : 'matrix-table__row'
            };
        });
    }

    // ── Related counts section ────────────────────────────────────────────────

    get showRelatedSection() {
        if (!this.matrix) return false;
        return Object.values(this.matrix.relatedCountsByRecordId || {})
            .some(rc => rc.counts && rc.counts.length > 0);
    }

    get relatedColumns() {
        if (!this.matrix) return [];
        return this.filteredRecordIds.map(id => {
            const i        = this.matrix.recordIds.indexOf(id);
            const rc       = this.matrix.relatedCountsByRecordId?.[id]
                             || { counts: [], totalRelated: 0, hasActiveRecords: false };
            const isMaster = id === this.masterId;
            const showLoserWarning = rc.hasActiveRecords && !isMaster;

            return {
                recordId:   id,
                recordName: this.matrix.recordNames[i],
                isMaster,
                relatedCounts: (rc.counts || []).map(c => ({
                    label:      c.label,
                    total:      c.total || 0,
                    active:     c.active || 0,
                    hasActive:  c.hasActive,
                    countClass: c.active > 0
                        ? 'slds-text-heading_medium eda-count eda-count_active'
                        : 'slds-text-heading_medium eda-count'
                })),
                hasActiveRecords: rc.hasActiveRecords,
                showLoserWarning,
                relatedCardClass: showLoserWarning
                    ? 'slds-box slds-box_x-small eda-card eda-card_warning'
                    : isMaster
                        ? 'slds-box slds-box_x-small eda-card eda-card_master'
                        : 'slds-box slds-box_x-small eda-card'
            };
        });
    }

    // ── Related Contacts section (Account merges) ─────────────────────────────

    get showRelatedContactsSection() {
        return this.matrix?.objectType === 'Account'
            && Object.keys(this.matrix.relatedContactsByRecordId || {}).length > 0;
    }

    get relatedContactColumns() {
        if (!this.matrix) return [];
        return this.filteredRecordIds.map(id => {
            const i = this.matrix.recordIds.indexOf(id);
            const contacts = (this.matrix.relatedContactsByRecordId || {})[id] || [];
            const isMaster = id === this.masterId;
            const activeCount = contacts.filter(c => c.relatedCounts?.hasActiveRecords).length;
            return {
                recordId:    id,
                recordName:  this.matrix.recordNames[i],
                isMaster,
                contactCount: contacts.length,
                activeCount,
                contacts: contacts.map(c => {
                    const rc     = c.relatedCounts || {};
                    const counts = rc.counts || [];
                    const get    = label => (counts.find(x => x.label === label)?.total || 0);
                    return {
                        contactId:    c.contactId,
                        contactName:  c.contactName,
                        courses:      get('Cours'),
                        programs:     get('Programmes'),
                        affiliations: get('Affiliations'),
                        hasActive:    rc.hasActiveRecords,
                        rowClass:     rc.hasActiveRecords
                            ? 'contact-row contact-row_active' : 'contact-row'
                    };
                }),
                colHeaderClass: isMaster
                    ? 'related-contact-col related-contact-col_master'
                    : 'related-contact-col'
            };
        });
    }

    // ── Event handlers ────────────────────────────────────────────────────────

    handleMasterChange(event) {
        this.dispatchEvent(new CustomEvent('masterchange', {
            detail: { masterId: event.target.value }
        }));
    }

    handleFieldDecisionChange(event) {
        const fieldName = event.target.dataset.field;
        const recordId  = event.target.value;
        this.dispatchEvent(new CustomEvent('fielddecisionchange', {
            detail: { fieldName, recordId }
        }));
    }
}
