import { LightningElement, api } from 'lwc';
import { getLabels } from 'c/i18n';

const OVERWRITE = '__overwrite__';

export default class MergeComparisonMatrix extends LightningElement {
    @api matrix;
    @api masterId;
    @api fieldDecisions;
    @api loserIds;
    @api emailRescues = [];
    @api lang = 'fr';

    // Email rescue dropdown: only one open at a time, floats over the table (position: fixed)
    _openRescueField = null;
    _rescueMenuStyle = '';
    _closeRescueMenu = () => { if (this._openRescueField) this._openRescueField = null; };

    connectedCallback() {
        window.addEventListener('click', this._closeRescueMenu);
        window.addEventListener('scroll', this._closeRescueMenu, true);
        window.addEventListener('resize', this._closeRescueMenu);
    }

    disconnectedCallback() {
        window.removeEventListener('click', this._closeRescueMenu);
        window.removeEventListener('scroll', this._closeRescueMenu, true);
        window.removeEventListener('resize', this._closeRescueMenu);
    }

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

    // ── Email rescue map: computes available rescue targets per email field ────

    get emailRescueMap() {
        if (!this.matrix) return {};
        const decisions = this.fieldDecisions || {};
        const rescues   = this.emailRescues   || [];

        // Current rescue targets already chosen: sourceField → targetField
        const chosenBySource = {};
        for (const r of rescues) {
            chosenBySource[r.sourceField] = r.targetField;
        }

        // All updateable email-type rows
        const emailRows = this.matrix.rows.filter(
            r => r.fieldType === 'EMAIL' && r.isUpdateable !== false
        );

        // Email fields that are empty on master = available rescue targets
        const emptyOnMaster = emailRows
            .filter(r => {
                const v = r.valuesByRecordId?.[this.masterId];
                return !v || v === '—';
            })
            .map(r => ({ label: r.fieldLabel, value: r.fieldApiName }));

        // Targets already taken by another source field (one rescue per target)
        const takenTargets = {};
        for (const r of rescues) takenTargets[r.targetField] = r.sourceField;

        const result = {};
        for (const row of emailRows) {
            if (!row.hasConflict) continue;
            const selectedId = decisions[row.fieldApiName] || this.masterId;
            const masterVal  = row.valuesByRecordId?.[this.masterId];
            if (!masterVal || masterVal === '—') continue; // master empty → normal radio is enough

            // Find the loser with a non-empty value
            const loserId = this.filteredRecordIds.find(id => {
                const v = row.valuesByRecordId?.[id];
                return String(id) !== String(this.masterId) && v && v !== '—';
            });
            if (!loserId) continue;
            const loserVal = row.valuesByRecordId?.[loserId];

            const i = this.i18n;
            // Picklist inside the loser cell: discard / overwrite / save into an empty email field
            const options = [
                { label: i.rescueKeepMaster || 'Do not keep', value: '' },
                ...emptyOnMaster
                    .filter(t => t.value !== row.fieldApiName
                              && (!takenTargets[t.value] || takenTargets[t.value] === row.fieldApiName))
                    .map(t => ({ label: `${i.rescueSaveIn || 'Save to'} → ${t.label}`, value: t.value }))
            ];

            const loserChosen = String(selectedId) === String(loserId);
            const current     = loserChosen ? OVERWRITE : (chosenBySource[row.fieldApiName] || '');
            result[row.fieldApiName] = {
                loserId,
                loserVal,
                options: options.map(o => ({ ...o, key: 'opt_' + o.value, selected: o.value === current, ariaChecked: o.value === current ? 'true' : 'false' })),
                currentChoice: current,
                isRescued:     !!current && current !== OVERWRITE,
                needsAction:   !current,
                isOpen:        this._openRescueField === row.fieldApiName,
                ariaExpanded:  this._openRescueField === row.fieldApiName ? 'true' : 'false',
                optCount:      options.length,
                menuStyle:     this._rescueMenuStyle,
                dotClass:      'rescue-dot' + (loserChosen ? ' rescue-dot_on' : ''),
                btnClass:      'rescue-drop' + (current && current !== OVERWRITE ? ' rescue-drop_active' : '')
            };
        }
        return result;
    }

    // targetField → rescued value (shown as pending in the target row's master cell)
    get pendingRescueByTarget() {
        const out = {};
        if (!this.matrix) return out;
        for (const r of this.emailRescues || []) {
            const srcRow = this.matrix.rows.find(x => x.fieldApiName === r.sourceField);
            const v = srcRow?.valuesByRecordId?.[r.sourceRecordId];
            if (v) out[r.targetField] = v;
        }
        return out;
    }

    // ── Body rows ─────────────────────────────────────────────────────────────

    get tableRows() {
        if (!this.matrix) return [];
        const decisions    = this.fieldDecisions || {};
        const rescueMap    = this.emailRescueMap;
        const pendingMap   = this.pendingRescueByTarget;

        return this.matrix.rows.map(row => {
            const rescueInfo  = rescueMap[row.fieldApiName] || null;
            const pendingVal  = pendingMap[row.fieldApiName] || null;
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

                const isRescueCell  = !!rescueInfo && String(id) === String(rescueInfo.loserId);
                const pendingRescue = (pendingVal && String(id) === String(this.masterId)) ? pendingVal : null;
                if (isRescueCell && rescueInfo.currentChoice && rescueInfo.currentChoice !== OVERWRITE) {
                    cellClass += ' matrix-table__value-col_rescued';
                }
                return {
                    recordId: id, displayValue, isSelected, isDifferent, cellClass,
                    isRescueCell, isNormalCell: !isRescueCell, pendingRescue
                };
            });

            return {
                fieldApiName:    row.fieldApiName,
                fieldLabel:      row.fieldLabel,
                isEdaField:      row.isEdaField,
                hasConflict:     row.hasConflict && !isReadOnly,
                isReadOnly,
                cells,
                radioGroupName:  `f_${row.fieldApiName}`,
                rowClass:        row.isEdaField
                    ? 'matrix-table__row matrix-table__row_eda'
                    : (row.hasConflict && !isReadOnly)
                        ? 'matrix-table__row matrix-table__row_conflict'
                        : 'matrix-table__row',
                rescueInfo
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
                recordId:     id,
                recordName:   this.matrix.recordNames[i],
                isMaster,
                contactCount: contacts.length,
                activeCount,
                contacts: contacts.map(c => {
                    const rc            = c.relatedCounts || {};
                    const counts        = rc.counts || [];
                    const carouselItems = counts.map(ct => ({
                        label:      ct.label,
                        total:      ct.total || 0,
                        countClass: (ct.active || 0) > 0
                            ? 'slds-text-heading_medium eda-count eda-count_active'
                            : 'slds-text-heading_medium eda-count'
                    }));
                    return {
                        contactId:    c.contactId,
                        contactName:  c.contactName,
                        hasActive:    rc.hasActiveRecords,
                        hasCarousel:  carouselItems.length > 0,
                        carouselItems,
                        rowClass:     rc.hasActiveRecords
                            ? 'contact-row contact-row_active slds-m-bottom_x-small'
                            : 'contact-row slds-m-bottom_x-small'
                    };
                }),
                colHeaderClass: isMaster
                    ? 'related-contact-col related-contact-col_master'
                    : 'related-contact-col'
            };
        });
    }

    // ── Related Account section (Contact merges, EDA only) ───────────────────

    get showRelatedAccountSection() {
        return this.matrix?.objectType === 'Contact'
            && Object.keys(this.matrix.relatedAccountByRecordId || {}).length > 0;
    }

    get relatedAccountColumns() {
        if (!this.matrix) return [];
        return this.filteredRecordIds.map(id => {
            const i        = this.matrix.recordIds.indexOf(id);
            const info     = (this.matrix.relatedAccountByRecordId || {})[id];
            const isMaster = id === this.masterId;
            const counts   = info?.relatedCounts?.counts || [];
            const carouselItems = counts.map(ct => ({
                label:      ct.label,
                total:      ct.total || 0,
                countClass: (ct.active || 0) > 0
                    ? 'slds-text-heading_medium eda-count eda-count_active'
                    : 'slds-text-heading_medium eda-count'
            }));
            return {
                recordId:      id,
                recordName:    this.matrix.recordNames[i],
                isMaster,
                hasAccount:    !!info,
                accountName:   info?.accountName || '',
                hasCarousel:   carouselItems.length > 0,
                carouselItems,
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

    // Loser email cell: the email itself is a button that opens a floating menu (row height never changes)
    handleRescueToggle(event) {
        event.stopPropagation();
        const field = event.currentTarget.dataset.sourcefield;
        if (this._openRescueField === field) {
            this._openRescueField = null;
            return;
        }
        const rect    = event.currentTarget.getBoundingClientRect();
        const count   = Number(event.currentTarget.dataset.optcount) || 4;
        const menuH   = count * 34 + 8;
        const openUp  = rect.bottom + menuH + 4 > window.innerHeight && rect.top > menuH;
        const top     = openUp ? rect.top - menuH - 4 : rect.bottom + 4;
        this._rescueMenuStyle = `top:${Math.round(top)}px;left:${Math.round(rect.left)}px;`;
        this._openRescueField = field;
    }

    handleRescuePick(event) {
        event.stopPropagation();
        const ds = event.currentTarget.dataset;
        this._openRescueField = null;
        this._applyRescueChoice(ds.sourcefield, ds.loserid, ds.value);
    }

    // The radio dot keeps working like every other row: click = overwrite with the loser's value
    handleRescueDot(event) {
        const ds = event.currentTarget.dataset;
        this._applyRescueChoice(ds.sourcefield, ds.loserid, OVERWRITE);
    }

    handleRescueMenuKeydown(event) {
        if (event.key === 'Escape') this._openRescueField = null;
    }

    // '' = discard, OVERWRITE = take loser value, else = rescue target field
    _applyRescueChoice(sourceField, sourceRecordId, choice) {
        if (choice === OVERWRITE) {
            this.dispatchEvent(new CustomEvent('fielddecisionchange', {
                detail: { fieldName: sourceField, recordId: sourceRecordId }
            }));
            return;
        }
        // Discard or rescue: master keeps its own value for this field
        this.dispatchEvent(new CustomEvent('fielddecisionchange', {
            detail: { fieldName: sourceField, recordId: this.masterId }
        }));
        this.dispatchEvent(new CustomEvent('emailrescuechange', {
            detail: { sourceField, targetField: choice, sourceRecordId }
        }));
    }
}
