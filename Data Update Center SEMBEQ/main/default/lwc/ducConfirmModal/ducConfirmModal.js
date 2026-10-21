import { api } from 'lwc';
import LightningModal from 'lightning/modal';

// Drop-in replacement for LightningConfirm whose buttons follow the app language
// (LightningConfirm always uses the Salesforce user locale, so FR screens got "Cancel/OK").
// Usage: await DucConfirmModal.open({ label, message, okLabel, cancelLabel, theme }) → true/false.
export default class DucConfirmModal extends LightningModal {
    // `label` is inherited from LightningModal (modal title + accessible name).
    @api message;
    @api headerless = false;
    @api okLabel;
    @api cancelLabel;
    @api theme;

    get showHeader() {
        return !this.headerless && !!this.label;
    }

    get okVariant() {
        return this.theme === 'warning' ? 'destructive' : 'brand';
    }

    handleCancel() {
        this.close(false);
    }

    handleOk() {
        this.close(true);
    }
}
