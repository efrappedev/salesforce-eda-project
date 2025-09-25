import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';

import PROV_NUMBER from '@salesforce/schema/Account.Registro_Provincial_Estatal__c';
import PROV_URL    from '@salesforce/schema/Account.Registro_Provincial_Estatal_URL__c';

export default class RegistroHyperlink extends LightningElement {
  @api recordId;

  @wire(getRecord, { recordId: '$recordId', fields: [PROV_NUMBER, PROV_URL] })
  record;

  get number() { return getFieldValue(this.record?.data, PROV_NUMBER) || ''; }
  get url()    { return getFieldValue(this.record?.data, PROV_URL) || ''; }
  get hasUrl() { return !!(this.url && this.url.trim()); }
}
