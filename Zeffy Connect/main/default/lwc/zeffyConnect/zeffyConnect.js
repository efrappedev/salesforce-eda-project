import { LightningElement, track } from 'lwc';
import loadConfig  from '@salesforce/apex/ZeffyConnectConfigService.loadConfig';
import saveConfig  from '@salesforce/apex/ZeffyConnectConfigService.saveConfig';

export default class ZeffyConnect extends LightningElement {
    @track apiKey        = '';
    @track webhookSecret = '';
    @track isActive      = true;
    @track isConfigured  = false;
    @track isSaving      = false;
    @track saveSuccess   = false;
    @track saveError     = '';
    @track urlCopied     = false;

    connectedCallback() {
        this.loadSettings();
    }

    loadSettings() {
        loadConfig()
            .then(cfg => {
                this.apiKey        = cfg.apiKey        || '';
                this.webhookSecret = cfg.webhookSecret || '';
                this.isActive      = cfg.isActive === 'true';
                this.isConfigured  = cfg.isConfigured === 'true';
            })
            .catch(err => { console.error('loadConfig error', err); });
    }

    get statusBannerClass() {
        return 'zc-status ' +
            (this.isConfigured
                ? (this.isActive ? 'zc-status--ok' : 'zc-status--paused')
                : 'zc-status--unconfigured');
    }

    get statusLabel() {
        if (!this.isConfigured) return 'No configurado — ingresa el Webhook Secret para activar el robot';
        return this.isActive ? 'Robot activo — procesando webhooks de Zeffy Connect' : 'Robot pausado — webhooks aceptados pero no procesados';
    }

    get activeLabel()  { return this.isActive ? 'Procesando webhooks' : 'Pausado (acepta pero no procesa)'; }
    get saveBtnLabel() { return this.isSaving ? 'Guardando…' : 'Guardar configuración'; }
    get copyBtnLabel() { return this.urlCopied ? '✓ Copiado' : 'Copiar'; }

    get webhookUrl() {
        const origin = window.location.origin;
        // Replace lightning.force.com with salesforce-sites.com pattern when using a Site
        return origin.replace('.lightning.force.com', '.my.salesforce-sites.com')
                     + '/services/apexrest/zeffy/webhook';
    }

    handleInput(evt) {
        const field = evt.currentTarget.dataset.field;
        this[field] = evt.target.value;
        this.saveSuccess = false;
        this.saveError   = '';
    }

    handleToggle(evt) {
        this.isActive    = evt.target.checked;
        this.saveSuccess = false;
        this.saveError   = '';
    }

    handleSave() {
        this.isSaving    = true;
        this.saveSuccess = false;
        this.saveError   = '';

        saveConfig({
            apiKey:        this.apiKey,
            webhookSecret: this.webhookSecret,
            isActive:      this.isActive
        })
        .then(() => {
            this.isSaving    = false;
            this.saveSuccess = true;
            this.loadSettings(); // refresh to show masked values
            setTimeout(() => { this.saveSuccess = false; }, 4000);
        })
        .catch(err => {
            this.isSaving  = false;
            this.saveError = (err.body && err.body.message) ? err.body.message : String(err);
        });
    }

    handleCopyUrl() {
        try {
            navigator.clipboard.writeText(this.webhookUrl);
        } catch (e) {
            const tmp = document.createElement('input');
            tmp.value = this.webhookUrl;
            document.body.appendChild(tmp);
            tmp.select();
            document.execCommand('copy');
            document.body.removeChild(tmp);
        }
        this.urlCopied = true;
        setTimeout(() => { this.urlCopied = false; }, 2500);
    }
}
