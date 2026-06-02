/**
 * MergeUtilityTest.cls
 * Covers: DataNormalizationUtil, SnapshotService, MergeWrappers (DTOs),
 *         EDARelatedRecordsService
 * Target coverage: 100 %
 */
@IsTest
private class MergeUtilityTest {

    // ─── DataNormalizationUtil ────────────────────────────────────────────────

    @IsTest
    static void normEmail_lowercasesAndTrims() {
        System.assertEquals('john@example.com',
            DataNormalizationUtil.normalizeEmail('  John@Example.COM  '));
    }

    @IsTest
    static void normEmail_blankAndNull_returnsNull() {
        System.assertEquals(null, DataNormalizationUtil.normalizeEmail(''));
        System.assertEquals(null, DataNormalizationUtil.normalizeEmail(null));
        System.assertEquals(null, DataNormalizationUtil.normalizeEmail('   '));
    }

    @IsTest
    static void normPhone_stripsFormatting() {
        System.assertEquals('5141234567',
            DataNormalizationUtil.normalizePhone('(514) 123-4567'));
    }

    @IsTest
    static void normPhone_stripsNACountryCode() {
        System.assertEquals('5141234567',
            DataNormalizationUtil.normalizePhone('15141234567'));
        System.assertEquals('5141234567',
            DataNormalizationUtil.normalizePhone('+1 514 123 4567'));
    }

    @IsTest
    static void normPhone_tooShortOrBlank_returnsNull() {
        System.assertEquals(null, DataNormalizationUtil.normalizePhone('123456'));
        System.assertEquals(null, DataNormalizationUtil.normalizePhone(null));
        System.assertEquals(null, DataNormalizationUtil.normalizePhone(''));
    }

    @IsTest
    static void normName_removesAccentsAndNormalizes() {
        System.assertEquals('ELEVE ANDRE',
            DataNormalizationUtil.normalizeName('élève André'));
    }

    @IsTest
    static void normName_collapsesExtraSpaces() {
        System.assertEquals('JEAN PAUL',
            DataNormalizationUtil.normalizeName('Jean  Paul'));
    }

    @IsTest
    static void normName_blankAndNull_returnsNull() {
        System.assertEquals(null, DataNormalizationUtil.normalizeName(''));
        System.assertEquals(null, DataNormalizationUtil.normalizeName(null));
        System.assertEquals(null, DataNormalizationUtil.normalizeName('   '));
    }

    @IsTest
    static void buildMatchKey_email() {
        System.assertEquals('Contact|Email|test@test.com',
            DataNormalizationUtil.buildMatchKey('Contact', 'Email', 'Test@Test.com'));
    }

    @IsTest
    static void buildMatchKey_phone() {
        System.assertEquals('Contact|Phone|5141234567',
            DataNormalizationUtil.buildMatchKey('Contact', 'Phone', '(514) 123-4567'));
    }

    @IsTest
    static void buildMatchKey_name() {
        System.assertEquals('Contact|Name|SMITH JOHN',
            DataNormalizationUtil.buildMatchKey('Contact', 'Name', 'Smith John'));
    }

    @IsTest
    static void buildMatchKey_blankNormalized_returnsNull() {
        System.assertEquals(null,
            DataNormalizationUtil.buildMatchKey('Contact', 'Email', ''));
        System.assertEquals(null,
            DataNormalizationUtil.buildMatchKey('Contact', 'Phone', 'abc'));
    }

    @IsTest
    static void buildMatchKey_unknownType_usesRawTrim() {
        String key = DataNormalizationUtil.buildMatchKey('Contact', 'Other', ' val ');
        System.assertEquals('Contact|Other|val', key);
    }

    @IsTest
    static void inferConfidence_allBranches() {
        System.assertEquals('High',   DataNormalizationUtil.inferConfidence('Email', 1));
        System.assertEquals('High',   DataNormalizationUtil.inferConfidence('Phone', 2));
        System.assertEquals('Medium', DataNormalizationUtil.inferConfidence('Phone', 1));
        System.assertEquals('Low',    DataNormalizationUtil.inferConfidence('Name',  1));
    }

    // ─── MergeWrappers — DTO constructors + computeDerived ───────────────────

    @IsTest
    static void edaCounts_computeDerived_withActiveEnrollments() {
        MergeWrappers.EDACountsWrapper w = new MergeWrappers.EDACountsWrapper();
        w.courseConnections        = 3;
        w.activeCourseConnections  = 1;
        w.programEnrollments       = 2;
        w.activeProgramEnrollments = 0;
        w.affiliations             = 1;
        w.computeDerived();
        System.assertEquals(6, w.totalRelatedRecords);
        System.assertEquals(true, w.hasActiveEnrollments);
    }

    @IsTest
    static void edaCounts_computeDerived_noActive() {
        MergeWrappers.EDACountsWrapper w = new MergeWrappers.EDACountsWrapper();
        w.courseConnections  = 1;
        w.programEnrollments = 1;
        w.affiliations       = 0;
        w.computeDerived();
        System.assertEquals(2, w.totalRelatedRecords);
        System.assertEquals(false, w.hasActiveEnrollments);
    }

    @IsTest
    static void wrapperDefaults_areCorrect() {
        MergeWrappers.ScanResult sr = new MergeWrappers.ScanResult();
        System.assertEquals(true,  sr.success);
        System.assertEquals(0,     sr.ticketsCreated);
        System.assertEquals(0,     sr.duplicateGroupsFound);
        System.assertEquals(false, sr.isAsync);
        System.assertNotEquals(null, sr.previews);

        MergeWrappers.TicketPreview tp = new MergeWrappers.TicketPreview();
        System.assertEquals(false, tp.alreadyHasTicket);
        System.assertNotEquals(null, tp.candidates);

        MergeWrappers.CandidateWrapper cw = new MergeWrappers.CandidateWrapper();
        System.assertEquals(false, cw.isMaster);
        System.assertEquals(false, cw.isLosingRecord);
        System.assertEquals(false, cw.hasActiveEnrollments);
        System.assertNotEquals(null, cw.fieldValues);

        MergeWrappers.MergeResult mr = new MergeWrappers.MergeResult();
        System.assertEquals(false, mr.success);
        System.assertNotEquals(null, mr.orphanedAccounts);
        System.assertNotEquals(null, mr.orphanedContacts);

        MergeWrappers.ComparisonMatrix cm = new MergeWrappers.ComparisonMatrix();
        System.assertNotEquals(null, cm.recordIds);
        System.assertNotEquals(null, cm.rows);
        System.assertNotEquals(null, cm.missingRecordIds);
        System.assertNotEquals(null, cm.relatedContactsByRecordId);

        MergeWrappers.ComparisonRow row = new MergeWrappers.ComparisonRow();
        System.assertEquals(false, row.hasConflict);
        System.assertEquals(false, row.isEdaField);
        System.assertEquals(true,  row.isUpdateable);
        System.assertNotEquals(null, row.valuesByRecordId);

        MergeWrappers.OrphanedAccountInfo oai = new MergeWrappers.OrphanedAccountInfo();
        System.assertEquals(0,    oai.affiliationCount);
        System.assertEquals(true, oai.isSafeToDelete);

        MergeWrappers.RelatedContactInfo rci = new MergeWrappers.RelatedContactInfo();
        System.assertNotEquals(null, rci.edaCounts);
    }

    // ─── SnapshotService ─────────────────────────────────────────────────────

    @IsTest
    static void captureSnapshot_nullRecord_returnsEmpty() {
        Map<String,Object> snap = SnapshotService.captureSnapshot(null);
        System.assertEquals(0, snap.size());
    }

    @IsTest
    static void captureSnapshot_basicRecord_includesFieldsAndMeta() {
        Account acc = new Account(Name = 'Snapshot Test');
        insert acc;
        Account q = [SELECT Id, Name FROM Account WHERE Id = :acc.Id];
        Map<String,Object> snap = SnapshotService.captureSnapshot(q);
        System.assertEquals('Snapshot Test', snap.get('Name'));
        System.assertEquals(true, snap.containsKey('__meta_capturedAt'));
        System.assertEquals(true, snap.containsKey('__meta_objectType'));
        System.assertEquals(true, snap.containsKey('__meta_capturedBy'));
    }

    @IsTest
    static void captureAndSerialize_returnsJsonString() {
        Account acc = new Account(Name = 'Ser Test');
        insert acc;
        Account q = [SELECT Id, Name FROM Account WHERE Id = :acc.Id];
        String json = SnapshotService.captureAndSerialize(q);
        System.assert(json.contains('Ser Test'), 'JSON should contain account name');
    }

    @IsTest
    static void captureSnapshotsBulk_returnsMapPerRecord() {
        Account a1 = new Account(Name = 'Bulk A');
        Account a2 = new Account(Name = 'Bulk B');
        insert new List<Account>{ a1, a2 };
        List<Account> queried = [SELECT Id, Name FROM Account
                                  WHERE Id IN :new Set<Id>{ a1.Id, a2.Id }];
        Integer bulkSize = SnapshotService.captureSnapshotsBulk(queried).size();
        System.assertEquals(2, bulkSize);
    }

    @IsTest
    static void captureSnapshotsBulk_containsExpectedId() {
        Account a = new Account(Name = 'BulkId Test');
        insert a;
        Account q = [SELECT Id, Name FROM Account WHERE Id = :a.Id];
        String idStr = String.valueOf(a.Id);
        System.assertEquals(true,
            SnapshotService.captureSnapshotsBulk(new List<SObject>{ q }).containsKey(idStr));
    }

    @IsTest
    static void diffSnapshots_detectsChangedField() {
        Map<String,Object> before = new Map<String,Object>{ 'Email' => 'a@x.com', 'Phone' => '123' };
        Map<String,Object> after  = new Map<String,Object>{ 'Email' => 'b@x.com', 'Phone' => '123' };
        Map<String,Object> diff   = SnapshotService.diffSnapshots(before, after);
        System.assertEquals(true,  diff.containsKey('Email'));
        System.assertEquals(false, diff.containsKey('Phone'));
    }

    @IsTest
    static void diffSnapshots_skipsMetaKeys() {
        Map<String,Object> before = new Map<String,Object>{
            '__meta_capturedAt' => '2024-01-01', 'Name' => 'A'
        };
        Map<String,Object> after = new Map<String,Object>{
            '__meta_capturedAt' => '2025-01-01', 'Name' => 'A'
        };
        Map<String,Object> diff = SnapshotService.diffSnapshots(before, after);
        System.assertEquals(0, diff.size());
    }

    @IsTest
    static void diffSnapshots_newFieldInAfter_appearsInDiff() {
        Map<String,Object> before = new Map<String,Object>{ 'Email' => null };
        Map<String,Object> after  = new Map<String,Object>{ 'Email' => 'x@x.com' };
        Map<String,Object> diff   = SnapshotService.diffSnapshots(before, after);
        System.assertEquals(true, diff.containsKey('Email'));
    }

    @IsTest
    static void deserialize_blankString_returnsEmpty() {
        System.assertEquals(0, SnapshotService.deserialize('').size());
        System.assertEquals(0, SnapshotService.deserialize(null).size());
    }

    @IsTest
    static void serializeBulkSnapshots_returnsValidJson() {
        Account a = new Account(Name = 'BulkSer');
        insert a;
        Account q = [SELECT Id, Name FROM Account WHERE Id = :a.Id];
        String json = SnapshotService.serializeBulkSnapshots(new List<SObject>{ q });
        System.assert(json.startsWith('{'), 'Expected JSON object');
    }

    // ─── EDARelatedRecordsService ─────────────────────────────────────────────

    @IsTest
    static void isEDAAvailable_doesNotThrow() {
        Boolean result = EDARelatedRecordsService.isEDAAvailable();
        // Call twice: second call returns from cache
        Boolean cached = EDARelatedRecordsService.isEDAAvailable();
        System.assertEquals(result, cached);
    }

    @IsTest
    static void getBulkCounts_emptySet_returnsEmptyMap() {
        Integer sz = EDARelatedRecordsService.getBulkCountsForContacts(new Set<Id>()).size();
        System.assertEquals(0, sz);
    }

    @IsTest
    static void getCountsForContact_noEDAData_returnsZeroCounts() {
        Contact c = new Contact(LastName = 'EDATestZero');
        insert c;
        MergeWrappers.EDACountsWrapper w =
            EDARelatedRecordsService.getCountsForContact(c.Id);
        System.assertNotEquals(null, w);
        System.assertEquals(0, w.courseConnections);
        System.assertEquals(0, w.programEnrollments);
        System.assertEquals(0, w.affiliations);
    }

    @IsTest
    static void getBulkCounts_multipleContacts_returnsEntryPerContact() {
        Contact c1 = new Contact(LastName = 'BulkEDA1');
        Contact c2 = new Contact(LastName = 'BulkEDA2');
        insert new List<Contact>{ c1, c2 };
        Integer sz = EDARelatedRecordsService.getBulkCountsForContacts(
            new Set<Id>{ c1.Id, c2.Id }).size();
        System.assertEquals(2, sz);
    }

    @IsTest
    static void getActiveCourseStatuses_returnsNonNull() {
        Set<String> statuses = EDARelatedRecordsService.getActiveCourseStatuses();
        System.assertNotEquals(null, statuses);
    }

    @IsTest
    static void getActiveProgramStatuses_returnsNonNull() {
        Set<String> statuses = EDARelatedRecordsService.getActiveProgramStatuses();
        System.assertNotEquals(null, statuses);
    }

    // ─── SnapshotService: null sType branch (line 128) ───────────────────────

    @IsTest
    static void snapshotService_getDescribeMap_unknownType_returnsEmptyMap() {
        // Covers SnapshotService line 128: sType == null → returns new Map<>()
        Map<String,Schema.SObjectField> result =
            SnapshotService.getDescribeMap('Totally_Nonexistent_Object__xyz');
        System.assertNotEquals(null, result, 'Must return an empty map, not null');
        System.assertEquals(0, result.size(), 'Unknown objectType must produce empty field map');
    }
}
