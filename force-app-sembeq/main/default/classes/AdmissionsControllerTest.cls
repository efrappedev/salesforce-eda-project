@isTest
private class AdmissionsControllerTest {

    // ─── TEST DATA SETUP ──────────────────────────────────────────────────────

    @TestSetup
    static void makeData() {
        // EDA: Contact auto-creates an Account via EDA trigger
        // We create a plain Account + Contact to avoid EDA complexity in tests
        Account acct = new Account(Name = 'Test Institution');
        insert acct;

        Contact applicant = new Contact(
            FirstName = 'Juan',
            LastName  = 'Pérez',
            AccountId = acct.Id
        );
        insert applicant;

        Contact reviewer = new Contact(
            FirstName = 'Maria',
            LastName  = 'González',
            AccountId = acct.Id
        );
        insert reviewer;

        hed__Application__c app = new hed__Application__c(
            hed__Applicant__c           = applicant.Id,
            hed__Application_Status__c  = 'Received',
            hed__Application_Type__c    = 'Transfer',
            hed__Application_Date__c    = Date.today()
        );
        insert app;
    }

    private static hed__Application__c getApp() {
        return [SELECT Id, hed__Application_Status__c, hed__Applicant__c FROM hed__Application__c LIMIT 1];
    }

    private static Contact getReviewer() {
        return [SELECT Id FROM Contact WHERE LastName = 'González' LIMIT 1];
    }

    // ─── getApplications ──────────────────────────────────────────────────────

    @isTest
    static void testGetApplications_noFilter() {
        Test.startTest();
        List<AdmissionsWrapper.ApplicationSummary> result = AdmissionsController.getApplications(null, null);
        Test.stopTest();

        System.assert(result.size() > 0, 'Should return at least one application');
        System.assertEquals('Received', result[0].status);
        System.assertEquals(0, result[0].reviewCount);
        System.assertEquals(false, result[0].hasDecision);
    }

    @isTest
    static void testGetApplications_statusFilter() {
        Test.startTest();
        List<AdmissionsWrapper.ApplicationSummary> match    = AdmissionsController.getApplications('Received', null);
        List<AdmissionsWrapper.ApplicationSummary> noMatch  = AdmissionsController.getApplications('Accepted', null);
        Test.stopTest();

        System.assertEquals(1, match.size());
        System.assertEquals(0, noMatch.size());
    }

    @isTest
    static void testGetApplications_allFilter() {
        Test.startTest();
        List<AdmissionsWrapper.ApplicationSummary> result = AdmissionsController.getApplications('All', null);
        Test.stopTest();
        System.assert(result.size() > 0);
    }

    @isTest
    static void testGetApplications_searchTerm() {
        Test.startTest();
        List<AdmissionsWrapper.ApplicationSummary> found    = AdmissionsController.getApplications(null, 'Pérez');
        List<AdmissionsWrapper.ApplicationSummary> notFound = AdmissionsController.getApplications(null, 'XYZ_NOPE');
        Test.stopTest();

        System.assertEquals(1, found.size());
        System.assertEquals(0, notFound.size());
    }

    // ─── getApplicationDetail ─────────────────────────────────────────────────

    @isTest
    static void testGetApplicationDetail_empty() {
        hed__Application__c app = getApp();
        Test.startTest();
        AdmissionsWrapper.ApplicationDetail detail = AdmissionsController.getApplicationDetail(app.Id);
        Test.stopTest();

        System.assertEquals(app.Id, detail.id);
        System.assertEquals('Received', detail.status);
        System.assertEquals(0, detail.reviews.size());
        System.assertEquals(null, detail.decision);
        System.assertEquals(0, detail.documents.size());
    }

    @isTest
    static void testGetApplicationDetail_withRelated() {
        hed__Application__c app = getApp();
        Contact reviewer = getReviewer();

        Admissions_Review__c rev = new Admissions_Review__c(
            Application__c = app.Id,
            Reviewer__c    = reviewer.Id,
            Review_Type__c = 'Academic',
            Status__c      = 'In Progress',
            Due_Date__c    = Date.today().addDays(7)
        );
        insert rev;

        Admissions_Decision__c dec = new Admissions_Decision__c(
            Application__c   = app.Id,
            Decision__c      = 'Admitted',
            Decision_Date__c = Date.today()
        );
        insert dec;

        Admissions_Document__c doc = new Admissions_Document__c(
            Name             = 'Transcript',
            Application__c   = app.Id,
            Document_Type__c = 'Transcript',
            Status__c        = 'Received'
        );
        insert doc;

        Test.startTest();
        AdmissionsWrapper.ApplicationDetail detail = AdmissionsController.getApplicationDetail(app.Id);
        Test.stopTest();

        System.assertEquals(1, detail.reviews.size());
        System.assertEquals('In Progress', detail.reviews[0].status);
        System.assertEquals(false, detail.reviews[0].isOverdue);
        System.assertNotEquals(null, detail.decision);
        System.assertEquals('Admitted', detail.decision.decision);
        System.assertEquals(1, detail.documents.size());
        System.assertEquals('Received', detail.documents[0].status);
    }

    @isTest
    static void testGetApplicationDetail_overdueReview() {
        hed__Application__c app = getApp();
        Contact reviewer = getReviewer();

        Admissions_Review__c rev = new Admissions_Review__c(
            Application__c = app.Id,
            Reviewer__c    = reviewer.Id,
            Status__c      = 'Not Started',
            Due_Date__c    = Date.today().addDays(-3)  // past due
        );
        insert rev;

        Test.startTest();
        AdmissionsWrapper.ApplicationDetail detail = AdmissionsController.getApplicationDetail(app.Id);
        Test.stopTest();

        System.assertEquals(true, detail.reviews[0].isOverdue);
    }

    // ─── assignReviewer ───────────────────────────────────────────────────────

    @isTest
    static void testAssignReviewer_advancesStatus() {
        hed__Application__c app = getApp();
        Contact reviewer = getReviewer();

        AdmissionsWrapper.ReviewInput input = new AdmissionsWrapper.ReviewInput();
        input.applicationId = app.Id;
        input.reviewerId    = reviewer.Id;
        input.reviewType    = 'Academic';
        input.dueDate       = Date.today().addDays(14);

        Test.startTest();
        AdmissionsController.assignReviewer(input);
        Test.stopTest();

        List<Admissions_Review__c> reviews = [SELECT Id, Status__c FROM Admissions_Review__c WHERE Application__c = :app.Id];
        System.assertEquals(1, reviews.size());
        System.assertEquals('Not Started', reviews[0].Status__c);

        hed__Application__c updatedApp = [SELECT hed__Application_Status__c FROM hed__Application__c WHERE Id = :app.Id];
        System.assertEquals('In Review', updatedApp.hed__Application_Status__c);
    }

    @isTest
    static void testAssignReviewer_noStatusChange_ifNotReceived() {
        hed__Application__c app = getApp();
        update new hed__Application__c(Id = app.Id, hed__Application_Status__c = 'In Review');
        Contact reviewer = getReviewer();

        AdmissionsWrapper.ReviewInput input = new AdmissionsWrapper.ReviewInput();
        input.applicationId = app.Id;
        input.reviewerId    = reviewer.Id;
        input.reviewType    = 'Interview';

        Test.startTest();
        AdmissionsController.assignReviewer(input);
        Test.stopTest();

        // Already In Review — no double-update
        hed__Application__c updatedApp = [SELECT hed__Application_Status__c FROM hed__Application__c WHERE Id = :app.Id];
        System.assertEquals('In Review', updatedApp.hed__Application_Status__c);
    }

    // ─── submitReview ─────────────────────────────────────────────────────────

    @isTest
    static void testSubmitReview() {
        hed__Application__c app = getApp();
        Contact reviewer = getReviewer();

        Admissions_Review__c rev = new Admissions_Review__c(
            Application__c = app.Id,
            Reviewer__c    = reviewer.Id,
            Status__c      = 'In Progress'
        );
        insert rev;

        AdmissionsWrapper.ReviewSubmission sub = new AdmissionsWrapper.ReviewSubmission();
        sub.reviewId      = rev.Id;
        sub.recommendation = 'Strongly Recommend';
        sub.score         = 95;
        sub.comments      = 'Excellent candidate.';

        Test.startTest();
        AdmissionsController.submitReview(sub);
        Test.stopTest();

        Admissions_Review__c updated = [SELECT Status__c, Recommendation__c, Score__c, Completed_Date__c FROM Admissions_Review__c WHERE Id = :rev.Id];
        System.assertEquals('Completed', updated.Status__c);
        System.assertEquals('Strongly Recommend', updated.Recommendation__c);
        System.assertEquals(95, updated.Score__c.intValue());
        System.assertEquals(Date.today(), updated.Completed_Date__c);
    }

    // ─── makeDecision + trigger ───────────────────────────────────────────────

    @isTest
    static void testMakeDecision_Admitted_syncsStatusAndEnrolls() {
        hed__Application__c app = getApp();

        AdmissionsWrapper.DecisionInput input = new AdmissionsWrapper.DecisionInput();
        input.applicationId    = app.Id;
        input.decision         = 'Admitted';
        input.decisionDate     = Date.today();
        input.conditions       = null;
        input.scholarshipAmount = 0;
        input.responseDeadline = Date.today().addDays(30);
        input.notes            = 'Congratulations!';

        Test.startTest();
        AdmissionsController.makeDecision(input);
        Test.stopTest();

        Admissions_Decision__c dec = [SELECT Decision__c FROM Admissions_Decision__c WHERE Application__c = :app.Id LIMIT 1];
        System.assertEquals('Admitted', dec.Decision__c);

        hed__Application__c updatedApp = [SELECT hed__Application_Status__c FROM hed__Application__c WHERE Id = :app.Id];
        System.assertEquals('Accepted', updatedApp.hed__Application_Status__c);

        List<hed__Program_Enrollment__c> enrollments = [SELECT Id FROM hed__Program_Enrollment__c WHERE hed__Contact__c = :app.hed__Applicant__c];
        System.assertEquals(1, enrollments.size());
    }

    @isTest
    static void testMakeDecision_Rejected() {
        hed__Application__c app = getApp();

        AdmissionsWrapper.DecisionInput input = new AdmissionsWrapper.DecisionInput();
        input.applicationId = app.Id;
        input.decision      = 'Rejected';
        input.decisionDate  = Date.today();

        Test.startTest();
        AdmissionsController.makeDecision(input);
        Test.stopTest();

        hed__Application__c updatedApp = [SELECT hed__Application_Status__c FROM hed__Application__c WHERE Id = :app.Id];
        System.assertEquals('Rejected', updatedApp.hed__Application_Status__c);

        List<hed__Program_Enrollment__c> enrollments = [SELECT Id FROM hed__Program_Enrollment__c WHERE hed__Contact__c = :app.hed__Applicant__c];
        System.assertEquals(0, enrollments.size());
    }

    @isTest
    static void testMakeDecision_AdmittedWithConditions() {
        hed__Application__c app = getApp();

        AdmissionsWrapper.DecisionInput input = new AdmissionsWrapper.DecisionInput();
        input.applicationId = app.Id;
        input.decision      = 'Admitted with Conditions';
        input.decisionDate  = null;  // test auto-date
        input.conditions    = 'Must pass language test.';

        Test.startTest();
        AdmissionsController.makeDecision(input);
        Test.stopTest();

        hed__Application__c updatedApp = [SELECT hed__Application_Status__c FROM hed__Application__c WHERE Id = :app.Id];
        System.assertEquals('Accepted', updatedApp.hed__Application_Status__c);
    }

    @isTest
    static void testMakeDecision_Waitlisted() {
        hed__Application__c app = getApp();
        AdmissionsWrapper.DecisionInput input = new AdmissionsWrapper.DecisionInput();
        input.applicationId = app.Id;
        input.decision      = 'Waitlisted';
        input.decisionDate  = Date.today();
        Test.startTest();
        AdmissionsController.makeDecision(input);
        Test.stopTest();
        hed__Application__c updatedApp = [SELECT hed__Application_Status__c FROM hed__Application__c WHERE Id = :app.Id];
        System.assertEquals('Waitlisted', updatedApp.hed__Application_Status__c);
    }

    @isTest
    static void testMakeDecision_Deferred() {
        hed__Application__c app = getApp();
        AdmissionsWrapper.DecisionInput input = new AdmissionsWrapper.DecisionInput();
        input.applicationId = app.Id;
        input.decision      = 'Deferred';
        input.decisionDate  = Date.today();
        Test.startTest();
        AdmissionsController.makeDecision(input);
        Test.stopTest();
        hed__Application__c updatedApp = [SELECT hed__Application_Status__c FROM hed__Application__c WHERE Id = :app.Id];
        System.assertEquals('Deferred', updatedApp.hed__Application_Status__c);
    }

    // ─── addDocument ──────────────────────────────────────────────────────────

    @isTest
    static void testAddDocument() {
        hed__Application__c app = getApp();

        AdmissionsWrapper.DocumentInput input = new AdmissionsWrapper.DocumentInput();
        input.applicationId = app.Id;
        input.documentName  = 'Official Transcript';
        input.documentType  = 'Transcript';
        input.documentUrl   = 'https://drive.google.com/file/xyz';
        input.repository    = 'Repositorio 1';
        input.isRequired    = true;
        input.notes         = 'Sealed envelope required.';

        Test.startTest();
        AdmissionsController.addDocument(input);
        Test.stopTest();

        List<Admissions_Document__c> docs = [SELECT Name, Document_Type__c, Status__c, Document_URL__c, Is_Required__c FROM Admissions_Document__c WHERE Application__c = :app.Id];
        System.assertEquals(1, docs.size());
        System.assertEquals('Official Transcript', docs[0].Name);
        System.assertEquals('Required', docs[0].Status__c);
        System.assertEquals('https://drive.google.com/file/xyz', docs[0].Document_URL__c);
        System.assertEquals(true, docs[0].Is_Required__c);
    }

    @isTest
    static void testAddDocument_defaultsNameToType() {
        hed__Application__c app = getApp();
        AdmissionsWrapper.DocumentInput input = new AdmissionsWrapper.DocumentInput();
        input.applicationId = app.Id;
        input.documentType  = 'CV-Resume';  // no documentName
        Test.startTest();
        AdmissionsController.addDocument(input);
        Test.stopTest();
        Admissions_Document__c doc = [SELECT Name FROM Admissions_Document__c WHERE Application__c = :app.Id LIMIT 1];
        System.assertEquals('CV-Resume', doc.Name);
    }

    // ─── updateDocumentStatus ─────────────────────────────────────────────────

    @isTest
    static void testUpdateDocumentStatus_Received() {
        hed__Application__c app = getApp();
        Admissions_Document__c doc = new Admissions_Document__c(
            Name = 'Transcript', Application__c = app.Id,
            Document_Type__c = 'Transcript', Status__c = 'Required'
        );
        insert doc;

        Test.startTest();
        AdmissionsController.updateDocumentStatus(doc.Id, 'Received');
        Test.stopTest();

        Admissions_Document__c updated = [SELECT Status__c, Received_Date__c FROM Admissions_Document__c WHERE Id = :doc.Id];
        System.assertEquals('Received', updated.Status__c);
        System.assertEquals(Date.today(), updated.Received_Date__c);
    }

    @isTest
    static void testUpdateDocumentStatus_Verified() {
        hed__Application__c app = getApp();
        Admissions_Document__c doc = new Admissions_Document__c(
            Name = 'Transcript', Application__c = app.Id,
            Document_Type__c = 'Transcript', Status__c = 'Received'
        );
        insert doc;

        Test.startTest();
        AdmissionsController.updateDocumentStatus(doc.Id, 'Verified');
        Test.stopTest();

        Admissions_Document__c updated = [SELECT Status__c FROM Admissions_Document__c WHERE Id = :doc.Id];
        System.assertEquals('Verified', updated.Status__c);
    }

    // ─── updateApplicationStatus ──────────────────────────────────────────────

    @isTest
    static void testUpdateApplicationStatus() {
        hed__Application__c app = getApp();
        Test.startTest();
        AdmissionsController.updateApplicationStatus(app.Id, 'In Review');
        Test.stopTest();
        hed__Application__c updated = [SELECT hed__Application_Status__c FROM hed__Application__c WHERE Id = :app.Id];
        System.assertEquals('In Review', updated.hed__Application_Status__c);
    }

    // ─── Trigger: update Decision ─────────────────────────────────────────────

    @isTest
    static void testTrigger_decisionUpdate_syncsStatus() {
        hed__Application__c app = getApp();

        Admissions_Decision__c dec = new Admissions_Decision__c(
            Application__c   = app.Id,
            Decision__c      = 'Waitlisted',
            Decision_Date__c = Date.today()
        );
        insert dec;

        hed__Application__c afterInsert = [SELECT hed__Application_Status__c FROM hed__Application__c WHERE Id = :app.Id];
        System.assertEquals('Waitlisted', afterInsert.hed__Application_Status__c);

        Test.startTest();
        dec.Decision__c = 'Rejected';
        update dec;
        Test.stopTest();

        hed__Application__c afterUpdate = [SELECT hed__Application_Status__c FROM hed__Application__c WHERE Id = :app.Id];
        System.assertEquals('Rejected', afterUpdate.hed__Application_Status__c);
    }
}
