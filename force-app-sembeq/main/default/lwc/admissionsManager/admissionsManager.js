import { LightningElement, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getApplications    from '@salesforce/apex/AdmissionsController.getApplications';
import getApplicationDetail from '@salesforce/apex/AdmissionsController.getApplicationDetail';
import assignReviewer     from '@salesforce/apex/AdmissionsController.assignReviewer';
import submitReview       from '@salesforce/apex/AdmissionsController.submitReview';
import makeDecision       from '@salesforce/apex/AdmissionsController.makeDecision';
import addDocument        from '@salesforce/apex/AdmissionsController.addDocument';
import updateDocumentStatus from '@salesforce/apex/AdmissionsController.updateDocumentStatus';
import updateApplicationStatus from '@salesforce/apex/AdmissionsController.updateApplicationStatus';

const STATUS_BADGE = {
    'Received' : 'badge badge-blue',
    'In Review': 'badge badge-yellow',
    'Accepted' : 'badge badge-green',
    'Rejected' : 'badge badge-red',
    'Waitlisted': 'badge badge-purple',
    'Deferred'  : 'badge badge-gray',
    'Withdrawn' : 'badge badge-gray',
    'Submitted' : 'badge badge-blue'
};

const DOC_STATUS_BADGE = {
    'Required': 'badge badge-red',
    'Received': 'badge badge-blue',
    'Verified': 'badge badge-green',
    'Waived'  : 'badge badge-gray'
};

const DECISION_BADGE = {
    'Admitted'                 : 'badge badge-green',
    'Admitted with Conditions' : 'badge badge-yellow',
    'Waitlisted'               : 'badge badge-purple',
    'Deferred'                 : 'badge badge-gray',
    'Rejected'                 : 'badge badge-red'
};

export default class AdmissionsManager extends LightningElement {

    @track statusFilter = 'All';
    @track searchTerm   = '';
    @track selectedAppId;
    @track loadingList   = false;
    @track loadingDetail = false;

    @track showStatusForm   = false;
    @track showReviewForm   = false;
    @track showDecisionForm = false;
    @track showDocumentForm = false;
    @track submitFormReviewId = null;

    @track newStatus = '';
    @track reviewForm    = { reviewerId: '', reviewType: 'Academic', dueDate: '' };
    @track submitForm    = { recommendation: '', score: null, comments: '' };
    @track decisionForm  = { decision: '', decisionDate: '', responseDeadline: '', scholarshipAmount: null, conditions: '', notes: '' };
    @track documentForm  = { documentName: '', documentType: '', documentUrl: '', repository: 'Repositorio 1', isRequired: true, notes: '' };

    _wiredApps;
    _rawApplications = [];
    _rawDetail       = null;

    // ─── Wire: Application List ───────────────────────────────────────────────

    @wire(getApplications, { statusFilter: '$statusFilter', searchTerm: '$searchTerm' })
    wiredApps(result) {
        this._wiredApps = result;
        this.loadingList = false;
        if (result.data) {
            this._rawApplications = result.data;
        } else if (result.error) {
            this._rawApplications = [];
            this.showError('Error al cargar solicitudes', result.error);
        }
    }

    // ─── Getters: List ────────────────────────────────────────────────────────

    get applications() {
        return (this._rawApplications || []).map(app => ({
            ...app,
            rowClass    : 'app-item' + (app.id === this.selectedAppId ? ' app-item-active' : ''),
            statusClass : STATUS_BADGE[app.status] || 'badge badge-gray'
        }));
    }

    get hasApplications() { return this.applications.length > 0; }

    // ─── Getters: Detail ──────────────────────────────────────────────────────

    get detail() {
        if (!this._rawDetail) return null;
        const d = this._rawDetail;
        return {
            ...d,
            statusClass          : STATUS_BADGE[d.status] || 'badge badge-gray',
            applicationDateStr   : d.applicationDate || '',
            dueDateStr           : d.dueDate || '',
            interviewRequiredLabel: d.interviewRequired ? 'Sí' : 'No',
            financialAidLabel    : d.financialAidRequested ? 'Sí' : 'No',
            reviews : (d.reviews || []).map(r => ({
                ...r,
                dueDateStr      : r.dueDate || '',
                completedDateStr: r.completedDate || '',
                isCompleted     : r.status === 'Completed',
                showSubmitForm  : this.submitFormReviewId === r.id,
                cardClass       : 'review-card' + (r.isOverdue ? ' review-card-overdue' : ''),
                statusBadgeClass: r.status === 'Completed' ? 'badge badge-green' : (r.status === 'In Progress' ? 'badge badge-yellow' : 'badge badge-gray')
            })),
            decision : d.decision ? {
                ...d.decision,
                badgeClass         : DECISION_BADGE[d.decision.decision] || 'badge badge-gray',
                decisionDateStr    : d.decision.decisionDate || '',
                responseDeadlineStr: d.decision.responseDeadline || ''
            } : null,
            documents : (d.documents || []).map(doc => ({
                ...doc,
                statusClass: DOC_STATUS_BADGE[doc.status] || 'badge badge-gray',
                isVerified : doc.status === 'Verified' || doc.status === 'Waived'
            }))
        };
    }

    get hasReviews()    { return this.detail && this.detail.reviews.length > 0; }
    get hasDocuments()  { return this.detail && this.detail.documents.length > 0; }

    // ─── Combobox Options ─────────────────────────────────────────────────────

    get statusOptions() {
        return [
            { label: 'Todas', value: 'All' },
            { label: 'Enviada', value: 'Submitted' },
            { label: 'Recibida', value: 'Received' },
            { label: 'En revisión', value: 'In Review' },
            { label: 'Aceptada', value: 'Accepted' },
            { label: 'Rechazada', value: 'Rejected' },
            { label: 'Lista de espera', value: 'Waitlisted' },
            { label: 'Diferida', value: 'Deferred' },
            { label: 'Retirada', value: 'Withdrawn' }
        ];
    }

    get statusUpdateOptions() {
        return this.statusOptions.filter(o => o.value !== 'All');
    }

    get reviewTypeOptions() {
        return ['Academic','Character','Interview','Financial','Other'].map(v => ({ label: v, value: v }));
    }

    get recommendationOptions() {
        return [
            'Strongly Recommend','Recommend','Neutral','Do Not Recommend'
        ].map(v => ({ label: v, value: v }));
    }

    get decisionOptions() {
        return [
            'Admitted','Admitted with Conditions','Waitlisted','Deferred','Rejected'
        ].map(v => ({ label: v, value: v }));
    }

    get documentTypeOptions() {
        return [
            'Transcript','Letter of Recommendation','CV-Resume','Personal Statement',
            'Test Score','Pastoral Reference','Church Membership Certificate','ID-Passport','Other'
        ].map(v => ({ label: v, value: v }));
    }

    get repositoryOptions() {
        return [
            { label: 'Repositorio 1', value: 'Repositorio 1' },
            { label: 'Repositorio 2', value: 'Repositorio 2' }
        ];
    }

    // ─── List Handlers ────────────────────────────────────────────────────────

    handleStatusChange(evt) {
        this.statusFilter = evt.detail.value;
        this.loadingList = true;
    }

    handleSearchChange(evt) {
        this.searchTerm = evt.detail.value;
        this.loadingList = true;
    }

    handleSelectApp(evt) {
        const id = evt.currentTarget.dataset.id;
        if (id === this.selectedAppId) return;
        this.selectedAppId = id;
        this._rawDetail = null;
        this.showStatusForm = false;
        this.showReviewForm = false;
        this.showDecisionForm = false;
        this.showDocumentForm = false;
        this.submitFormReviewId = null;
        this.loadDetail(id);
    }

    async loadDetail(id) {
        this.loadingDetail = true;
        try {
            this._rawDetail = await getApplicationDetail({ applicationId: id });
        } catch (e) {
            this.showError('Error al cargar detalle', e);
        } finally {
            this.loadingDetail = false;
        }
    }

    // ─── Status Change ────────────────────────────────────────────────────────

    handleToggleStatusForm() { this.showStatusForm = !this.showStatusForm; }
    handleNewStatusChange(evt) { this.newStatus = evt.detail.value; }

    async handleUpdateStatus() {
        if (!this.newStatus) { this.showError('', 'Selecciona un estado.'); return; }
        try {
            await updateApplicationStatus({ applicationId: this.selectedAppId, newStatus: this.newStatus });
            this.showStatusForm = false;
            this.newStatus = '';
            refreshApex(this._wiredApps);
            await this.loadDetail(this.selectedAppId);
            this.showSuccess('Estado actualizado.');
        } catch (e) { this.showError('Error', e); }
    }

    // ─── Review Handlers ──────────────────────────────────────────────────────

    handleToggleReviewForm() { this.showReviewForm = !this.showReviewForm; }
    handleReviewerPick(evt)  { this.reviewForm = { ...this.reviewForm, reviewerId: evt.detail.value }; }
    handleReviewTypeChange(evt) { this.reviewForm = { ...this.reviewForm, reviewType: evt.detail.value }; }
    handleReviewDueDateChange(evt) { this.reviewForm = { ...this.reviewForm, dueDate: evt.detail.value }; }

    async handleAssignReviewer() {
        if (!this.reviewForm.reviewerId) { this.showError('', 'Selecciona un revisor.'); return; }
        try {
            await assignReviewer({
                input: {
                    applicationId: this.selectedAppId,
                    reviewerId   : this.reviewForm.reviewerId,
                    reviewType   : this.reviewForm.reviewType,
                    dueDate      : this.reviewForm.dueDate || null
                }
            });
            this.showReviewForm = false;
            this.reviewForm = { reviewerId: '', reviewType: 'Academic', dueDate: '' };
            refreshApex(this._wiredApps);
            await this.loadDetail(this.selectedAppId);
            this.showSuccess('Revisor asignado.');
        } catch (e) { this.showError('Error', e); }
    }

    handleToggleSubmitReview(evt) {
        const reviewId = evt.currentTarget.dataset.id;
        this.submitFormReviewId = this.submitFormReviewId === reviewId ? null : reviewId;
        this.submitForm = { recommendation: '', score: null, comments: '' };
        this._rawDetail = { ...this._rawDetail }; // trigger re-render
    }

    handleRecommendationChange(evt)  { this.submitForm = { ...this.submitForm, recommendation: evt.detail.value }; }
    handleScoreChange(evt)           { this.submitForm = { ...this.submitForm, score: evt.detail.value }; }
    handleSubmitCommentsChange(evt)  { this.submitForm = { ...this.submitForm, comments: evt.detail.value }; }

    async handleSubmitReview(evt) {
        const reviewId = evt.currentTarget.dataset.id;
        try {
            await submitReview({
                sub: {
                    reviewId      : reviewId,
                    recommendation: this.submitForm.recommendation,
                    score         : this.submitForm.score,
                    comments      : this.submitForm.comments
                }
            });
            this.submitFormReviewId = null;
            this.submitForm = { recommendation: '', score: null, comments: '' };
            await this.loadDetail(this.selectedAppId);
            this.showSuccess('Revisión completada.');
        } catch (e) { this.showError('Error', e); }
    }

    // ─── Decision Handlers ────────────────────────────────────────────────────

    handleToggleDecisionForm() { this.showDecisionForm = !this.showDecisionForm; }
    handleDecisionChange(evt)        { this.decisionForm = { ...this.decisionForm, decision: evt.detail.value }; }
    handleDecisionDateChange(evt)    { this.decisionForm = { ...this.decisionForm, decisionDate: evt.detail.value }; }
    handleResponseDeadlineChange(evt){ this.decisionForm = { ...this.decisionForm, responseDeadline: evt.detail.value }; }
    handleScholarshipChange(evt)     { this.decisionForm = { ...this.decisionForm, scholarshipAmount: evt.detail.value }; }
    handleConditionsChange(evt)      { this.decisionForm = { ...this.decisionForm, conditions: evt.detail.value }; }
    handleDecisionNotesChange(evt)   { this.decisionForm = { ...this.decisionForm, notes: evt.detail.value }; }

    async handleMakeDecision() {
        if (!this.decisionForm.decision) { this.showError('', 'Selecciona una decisión.'); return; }
        try {
            await makeDecision({
                input: {
                    applicationId    : this.selectedAppId,
                    decision         : this.decisionForm.decision,
                    decisionDate     : this.decisionForm.decisionDate || null,
                    responseDeadline : this.decisionForm.responseDeadline || null,
                    scholarshipAmount : this.decisionForm.scholarshipAmount || null,
                    conditions       : this.decisionForm.conditions,
                    notes            : this.decisionForm.notes
                }
            });
            this.showDecisionForm = false;
            this.decisionForm = { decision: '', decisionDate: '', responseDeadline: '', scholarshipAmount: null, conditions: '', notes: '' };
            refreshApex(this._wiredApps);
            await this.loadDetail(this.selectedAppId);
            this.showSuccess('Decisión registrada.');
        } catch (e) { this.showError('Error', e); }
    }

    // ─── Document Handlers ────────────────────────────────────────────────────

    handleToggleDocumentForm() { this.showDocumentForm = !this.showDocumentForm; }
    handleDocNameChange(evt)     { this.documentForm = { ...this.documentForm, documentName: evt.detail.value }; }
    handleDocTypeChange(evt)     { this.documentForm = { ...this.documentForm, documentType: evt.detail.value }; }
    handleDocUrlChange(evt)      { this.documentForm = { ...this.documentForm, documentUrl: evt.detail.value }; }
    handleRepoChange(evt)        { this.documentForm = { ...this.documentForm, repository: evt.detail.value }; }
    handleDocRequiredChange(evt) { this.documentForm = { ...this.documentForm, isRequired: evt.detail.checked }; }
    handleDocNotesChange(evt)    { this.documentForm = { ...this.documentForm, notes: evt.detail.value }; }

    async handleAddDocument() {
        if (!this.documentForm.documentType) { this.showError('', 'Selecciona el tipo de documento.'); return; }
        try {
            await addDocument({
                input: {
                    applicationId: this.selectedAppId,
                    documentName : this.documentForm.documentName,
                    documentType : this.documentForm.documentType,
                    documentUrl  : this.documentForm.documentUrl,
                    repository   : this.documentForm.repository,
                    isRequired   : this.documentForm.isRequired,
                    notes        : this.documentForm.notes
                }
            });
            this.showDocumentForm = false;
            this.documentForm = { documentName: '', documentType: '', documentUrl: '', repository: 'Repositorio 1', isRequired: true, notes: '' };
            await this.loadDetail(this.selectedAppId);
            this.showSuccess('Documento agregado.');
        } catch (e) { this.showError('Error', e); }
    }

    async handleDocStatusSelect(evt) {
        const documentId = evt.currentTarget.dataset.id;
        const status     = evt.detail.value;
        try {
            await updateDocumentStatus({ documentId, status });
            await this.loadDetail(this.selectedAppId);
            this.showSuccess('Estado actualizado.');
        } catch (e) { this.showError('Error', e); }
    }

    // ─── Toast Helpers ────────────────────────────────────────────────────────

    showSuccess(message) {
        this.dispatchEvent(new ShowToastEvent({ title: 'Éxito', message, variant: 'success' }));
    }

    showError(title, error) {
        const message = error?.body?.message || error?.message || (typeof error === 'string' ? error : 'Error desconocido.');
        this.dispatchEvent(new ShowToastEvent({ title: title || 'Error', message, variant: 'error', mode: 'sticky' }));
    }
}
