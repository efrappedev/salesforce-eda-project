import { LightningElement, api, wire } from 'lwc';
import { getObjectInfo }              from 'lightning/uiObjectInfoApi';

export default class MergeObjectConfigRow extends LightningElement {
    @api apiName;

    @wire(getObjectInfo, { objectApiName: '$apiName' })
    _info;

    get iconUrl() {
        return this._info?.data?.themeInfo?.iconUrl;
    }

    get iconBgStyle() {
        const color = this._info?.data?.themeInfo?.color;
        return `background:#${color || 'dddbda'};border-radius:4px`;
    }

    get hasIcon() {
        return !!this.iconUrl;
    }
}
