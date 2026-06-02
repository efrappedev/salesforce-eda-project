import { LightningElement, api } from 'lwc';

export default class MergeComparisonMatrix extends LightningElement {
    /** ComparisonMatrix from Apex */
    @api matrix;
    /** Currently selected master record ID */
    @api masterId;
    /** { fieldApiName: sourceRecordId } — plain object, not reactive here */
    @api fieldDecisions;
    /** IDs explicitly marked as losers (3+ candidate case).
     *  When populated, only master + these IDs are shown as columns. */
    @api loserIds;

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
            const eda      = this.matrix.edaCountsByRecordId?.[id] || {};
            return {
                recordId:           id,
                recordName:         this.matrix.recordNames[i],
                isMaster,
                hasActiveEnrollments: eda.hasActiveEnrollments,
                headerClass:        isMaster
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

    // ── EDA section ───────────────────────────────────────────────────────────

    get showEdaSection() {
        return this.matrix
            && Object.keys(this.matrix.edaCountsByRecordId || {}).length > 0;
    }

    get edaColumns() {
        if (!this.matrix) return [];
        return this.filteredRecordIds.map(id => {
            const i       = this.matrix.recordIds.indexOf(id);
            const eda     = this.matrix.edaCountsByRecordId?.[id]
                            || { courseConnections: 0, activeCourseConnections: 0,
                                 programEnrollments: 0, activeProgramEnrollments: 0,
                                 affiliations: 0, hasActiveEnrollments: false };
            const isMaster = id === this.masterId;
            // Show loser warning only if this record has active enrollments AND is NOT master
            const showLoserWarning = eda.hasActiveEnrollments && !isMaster;

            return {
                recordId:   id,
                recordName: this.matrix.recordNames[i],
                isMaster,
                edaCounts:  eda,
                hasActiveEnrollments: eda.hasActiveEnrollments,
                showLoserWarning,
                edaCardClass: showLoserWarning
                    ? 'slds-box slds-box_x-small eda-card eda-card_warning'
                    : isMaster
                        ? 'slds-box slds-box_x-small eda-card eda-card_master'
                        : 'slds-box slds-box_x-small eda-card',
                courseClass:  eda.activeCourseConnections > 0
                    ? 'slds-text-heading_medium eda-count eda-count_active'
                    : 'slds-text-heading_medium eda-count',
                programClass: eda.activeProgramEnrollments > 0
                    ? 'slds-text-heading_medium eda-count eda-count_active'
                    : 'slds-text-heading_medium eda-count'
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
            const activeCount = contacts.filter(c => c.edaCounts?.hasActiveEnrollments).length;
            return {
                recordId:    id,
                recordName:  this.matrix.recordNames[i],
                isMaster,
                contactCount: contacts.length,
                activeCount,
                contacts: contacts.map(c => {
                    const eda = c.edaCounts || {};
                    return {
                        contactId:   c.contactId,
                        contactName: c.contactName,
                        courses:     eda.courseConnections || 0,
                        programs:    eda.programEnrollments || 0,
                        affiliations: eda.affiliations || 0,
                        hasActive:   eda.hasActiveEnrollments,
                        rowClass:    eda.hasActiveEnrollments
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
