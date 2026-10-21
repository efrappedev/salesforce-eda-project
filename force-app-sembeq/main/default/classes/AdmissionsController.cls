public with sharing class AdmissionsController {

    // ─── READ ─────────────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<AdmissionsWrapper.ApplicationSummary> getApplications(
        String statusFilter, String searchTerm
    ) {
        String soql =
            'SELECT Id, Name, hed__Applicant__c, hed__Applicant__r.Name, ' +
            '       hed__Application_Status__c, hed__Application_Type__c, ' +
            '       Program__c, Program__r.Name, hed__Application_Date__c, ' +
            '  (SELECT Id, Status__c FROM Admissions_Reviews__r), ' +
            '  (SELECT Id FROM Admissions_Decisions__r LIMIT 1), ' +
            '  (SELECT Id, Status__c FROM Admissions_Documents__r) ' +
            'FROM hed__Application__c ';

        List<String> conditions = new List<String>();
        if (String.isNotBlank(statusFilter) && statusFilter != 'All') {
            conditions.add('hed__Application_Status__c = \'' + String.escapeSingleQuotes(statusFilter) + '\'');
        }
        if (String.isNotBlank(searchTerm)) {
            String s = '%' + String.escapeSingleQuotes(searchTerm) + '%';
            conditions.add('(hed__Applicant__r.Name LIKE \'' + s + '\' OR Name LIKE \'' + s + '\')');
        }
        if (!conditions.isEmpty()) soql += 'WHERE ' + String.join(conditions, ' AND ') + ' ';
        soql += 'ORDER BY hed__Application_Date__c DESC NULLS LAST LIMIT 100';

        List<AdmissionsWrapper.ApplicationSummary> result = new List<AdmissionsWrapper.ApplicationSummary>();
        for (hed__Application__c app : Database.query(soql)) {
            AdmissionsWrapper.ApplicationSummary s = new AdmissionsWrapper.ApplicationSummary();
            s.id               = app.Id;
            s.name             = app.Name;
            s.applicantId      = app.hed__Applicant__c;
            s.applicantName    = app.hed__Applicant__r?.Name;
            s.status           = app.hed__Application_Status__c;
            s.applicationType  = app.hed__Application_Type__c;
            s.programName      = app.Program__r?.Name;
            s.applicationDate  = app.hed__Application_Date__c != null ? app.hed__Application_Date__c.date() : null;
            List<Admissions_Review__c>   reviews   = app.Admissions_Reviews__r;
            List<Admissions_Decision__c> decisions = app.Admissions_Decisions__r;
            List<Admissions_Document__c> docs      = app.Admissions_Documents__r;
            s.reviewCount           = reviews.size();
            s.completedReviewCount  = 0;
            for (Admissions_Review__c r : reviews) {
                if (r.Status__c == 'Completed') s.completedReviewCount++;
            }
            s.hasDecision    = !decisions.isEmpty();
            s.documentCount  = docs.size();
            s.verifiedDocCount = 0;
            for (Admissions_Document__c d : docs) {
                if (d.Status__c == 'Verified') s.verifiedDocCount++;
            }
            result.add(s);
        }
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static AdmissionsWrapper.ApplicationDetail getApplicationDetail(Id applicationId) {
        hed__Application__c app = [
            SELECT Id, Name,
                   hed__Applicant__c, hed__Applicant__r.Name,
                   hed__Application_Status__c, hed__Application_Type__c,
                   Program__c, Program__r.Name,
                   hed__Term__c, hed__Term__r.Name,
                   hed__Application_Date__c, hed__Due_Date__c,
                   Interview_Required__c, Financial_Aid_Requested__c,
                   Previous_Institution__c, Previous_GPA__c,
                   Comments__c,
              (SELECT Id, Name, Reviewer__c, Reviewer__r.Name, Status__c, Review_Type__c,
                      Recommendation__c, Score__c, Due_Date__c, Completed_Date__c, Comments__c
               FROM Admissions_Reviews__r ORDER BY CreatedDate ASC),
              (SELECT Id, Name, Decision__c, Decision_Date__c,
                      Decision_Made_By__c, Decision_Made_By__r.Name,
                      Conditions__c, Scholarship_Amount__c, Response_Deadline__c, Notes__c
               FROM Admissions_Decisions__r ORDER BY CreatedDate DESC LIMIT 1),
              (SELECT Id, Name, Document_Type__c, Status__c, Received_Date__c,
                      Verified_By__c, Verified_By__r.Name, Is_Required__c,
                      Document_URL__c, Repository__c, Notes__c
               FROM Admissions_Documents__r ORDER BY Document_Type__c ASC)
            FROM hed__Application__c
            WHERE Id = :applicationId
            WITH SECURITY_ENFORCED
        ];

        AdmissionsWrapper.ApplicationDetail detail = new AdmissionsWrapper.ApplicationDetail();
        detail.id                  = app.Id;
        detail.name                = app.Name;
        detail.applicantId         = app.hed__Applicant__c;
        detail.applicantName       = app.hed__Applicant__r?.Name;
        detail.status              = app.hed__Application_Status__c;
        detail.applicationType     = app.hed__Application_Type__c;
        detail.programId           = app.Program__c;
        detail.programName         = app.Program__r?.Name;
        detail.termId              = app.hed__Term__c;
        detail.termName            = app.hed__Term__r?.Name;
        detail.applicationDate     = app.hed__Application_Date__c != null ? app.hed__Application_Date__c.date() : null;
        detail.dueDate             = app.hed__Due_Date__c;
        detail.interviewRequired   = app.Interview_Required__c;
        detail.financialAidRequested = app.Financial_Aid_Requested__c;
        detail.previousInstitution = app.Previous_Institution__c;
        detail.previousGpa         = app.Previous_GPA__c;
        detail.comments            = app.Comments__c;

        detail.reviews = new List<AdmissionsWrapper.ReviewDetail>();
        for (Admissions_Review__c r : app.Admissions_Reviews__r) {
            AdmissionsWrapper.ReviewDetail rd = new AdmissionsWrapper.ReviewDetail();
            rd.id             = r.Id;
            rd.name           = r.Name;
            rd.reviewerId     = r.Reviewer__c;
            rd.reviewerName   = r.Reviewer__r?.Name;
            rd.status         = r.Status__c;
            rd.reviewType     = r.Review_Type__c;
            rd.recommendation = r.Recommendation__c;
            rd.score          = r.Score__c;
            rd.dueDate        = r.Due_Date__c;
            rd.completedDate  = r.Completed_Date__c;
            rd.comments       = r.Comments__c;
            rd.isOverdue      = (r.Due_Date__c != null && r.Due_Date__c < Date.today() && r.Status__c != 'Completed');
            detail.reviews.add(rd);
        }

        detail.decision = null;
        if (!app.Admissions_Decisions__r.isEmpty()) {
            Admissions_Decision__c dec = app.Admissions_Decisions__r[0];
            AdmissionsWrapper.DecisionDetail dd = new AdmissionsWrapper.DecisionDetail();
            dd.id                  = dec.Id;
            dd.name                = dec.Name;
            dd.decision            = dec.Decision__c;
            dd.decisionDate        = dec.Decision_Date__c;
            dd.decisionMadeById    = dec.Decision_Made_By__c;
            dd.decisionMadeByName  = dec.Decision_Made_By__r?.Name;
            dd.conditions          = dec.Conditions__c;
            dd.scholarshipAmount   = dec.Scholarship_Amount__c;
            dd.responseDeadline    = dec.Response_Deadline__c;
            dd.notes               = dec.Notes__c;
            detail.decision = dd;
        }

        detail.documents = new List<AdmissionsWrapper.DocumentDetail>();
        for (Admissions_Document__c doc : app.Admissions_Documents__r) {
            AdmissionsWrapper.DocumentDetail docDetail = new AdmissionsWrapper.DocumentDetail();
            docDetail.id             = doc.Id;
            docDetail.name           = doc.Name;
            docDetail.documentType   = doc.Document_Type__c;
            docDetail.status         = doc.Status__c;
            docDetail.receivedDate   = doc.Received_Date__c;
            docDetail.verifiedById   = doc.Verified_By__c;
            docDetail.verifiedByName = doc.Verified_By__r?.Name;
            docDetail.isRequired     = doc.Is_Required__c;
            docDetail.documentUrl    = doc.Document_URL__c;
            docDetail.repository     = doc.Repository__c;
            docDetail.notes          = doc.Notes__c;
            detail.documents.add(docDetail);
        }

        return detail;
    }

    // ─── REVIEW ───────────────────────────────────────────────────────────────

    @AuraEnabled
    public static void assignReviewer(AdmissionsWrapper.ReviewInput input) {
        insert new Admissions_Review__c(
            Application__c = input.applicationId,
            Reviewer__c    = input.reviewerId,
            Review_Type__c = input.reviewType,
            Due_Date__c    = input.dueDate,
            Status__c      = 'Not Started'
        );
        // Advance application to In Review if still at Received
        updateApplicationStatusIfMatch(input.applicationId, 'Received', 'In Review');
    }

    @AuraEnabled
    public static void submitReview(AdmissionsWrapper.ReviewSubmission sub) {
        Admissions_Review__c r = new Admissions_Review__c(
            Id             = sub.reviewId,
            Recommendation__c = sub.recommendation,
            Score__c       = sub.score,
            Comments__c    = sub.comments,
            Status__c      = 'Completed',
            Completed_Date__c = Date.today()
        );
        update r;
    }

    // ─── DECISION ─────────────────────────────────────────────────────────────

    @AuraEnabled
    public static void makeDecision(AdmissionsWrapper.DecisionInput input) {
        insert new Admissions_Decision__c(
            Application__c      = input.applicationId,
            Decision__c         = input.decision,
            Decision_Date__c    = input.decisionDate != null ? input.decisionDate : Date.today(),
            Conditions__c       = input.conditions,
            Scholarship_Amount__c = input.scholarshipAmount,
            Response_Deadline__c  = input.responseDeadline,
            Notes__c            = input.notes
        );
        // Status sync is handled by AdmissionsDecision_SyncStatus trigger
    }

    // ─── DOCUMENTS ────────────────────────────────────────────────────────────

    @AuraEnabled
    public static void addDocument(AdmissionsWrapper.DocumentInput input) {
        insert new Admissions_Document__c(
            Name           = String.isNotBlank(input.documentName) ? input.documentName : input.documentType,
            Application__c = input.applicationId,
            Document_Type__c = input.documentType,
            Status__c      = 'Required',
            Document_URL__c  = input.documentUrl,
            Repository__c  = input.repository,
            Is_Required__c = input.isRequired != null ? input.isRequired : true,
            Notes__c       = input.notes
        );
    }

    @AuraEnabled
    public static void updateDocumentStatus(Id documentId, String status) {
        Admissions_Document__c doc = new Admissions_Document__c(Id = documentId, Status__c = status);
        if (status == 'Received') doc.Received_Date__c = Date.today();
        update doc;
    }

    @AuraEnabled
    public static void updateApplicationStatus(Id applicationId, String newStatus) {
        update new hed__Application__c(Id = applicationId, hed__Application_Status__c = newStatus);
    }

    // ─── HELPERS ──────────────────────────────────────────────────────────────

    private static void updateApplicationStatusIfMatch(Id appId, String fromStatus, String toStatus) {
        List<hed__Application__c> apps = [SELECT Id, hed__Application_Status__c FROM hed__Application__c WHERE Id = :appId LIMIT 1];
        if (!apps.isEmpty() && apps[0].hed__Application_Status__c == fromStatus) {
            apps[0].hed__Application_Status__c = toStatus;
            update apps;
        }
    }
}
