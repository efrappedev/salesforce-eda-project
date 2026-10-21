/**
 * MergeUtilityTest.cls
 * Covers: MergeDataNormalizationUtil, MergeSnapshotService, MergeWrappers (DTOs),
 *         MergeRelatedRecordsService
 * Target coverage: 100 %
 */
@IsTest
private class MergeUtilityTest {

    // ─── MergeDataNormalizationUtil ────────────────────────────────────────────────

    @IsTest
    static void normEmail_lowercasesAndTrims() {
        System.assertEquals('john@example.com',
            MergeDataNormalizationUtil.normalizeEmail('  John@Example.COM  '));
    }

    @IsTest
    static void normEmail_blankAndNull_returnsNull() {
        System.assertEquals(null, MergeDataNormalizationUtil.normalizeEmail(''));
        System.assertEquals(null, MergeDataNormalizationUtil.normalizeEmail(null));
        System.assertEquals(null, MergeDataNormalizationUtil.normalizeEmail('   '));
    }

    @IsTest
    static void normPhone_stripsFormatting() {
        System.assertEquals('5141234567',
            MergeDataNormalizationUtil.normalizePhone('(514) 123-4567'));
    }

    @IsTest
    static void normPhone_stripsNACountryCode() {
        System.assertEquals('5141234567',
            MergeDataNormalizationUtil.normalizePhone('15141234567'));
        System.assertEquals('5141234567',
            MergeDataNormalizationUtil.normalizePhone('+1 514 123 4567'));
    }

    @IsTest
    static void normPhone_tooShortOrBlank_returnsNull() {
        System.assertEquals(null, MergeDataNormalizationUtil.normalizePhone('123456'));
        System.assertEquals(null, MergeDataNormalizationUtil.normalizePhone(null));
        System.assertEquals(null, MergeDataNormalizationUtil.normalizePhone(''));
    }

    @IsTest
    static void normName_removesAccentsAndNormalizes() {
        System.assertEquals('ELEVE ANDRE',
            MergeDataNormalizationUtil.normalizeName('élève André'));
    }

    @IsTest
    static void normName_collapsesExtraSpaces() {
        System.assertEquals('JEAN PAUL',
            MergeDataNormalizationUtil.normalizeName('Jean  Paul'));
    }

    @IsTest
    static void normName_blankAndNull_returnsNull() {
        System.assertEquals(null, MergeDataNormalizationUtil.normalizeName(''));
        System.assertEquals(null, MergeDataNormalizationUtil.normalizeName(null));
        System.assertEquals(null, MergeDataNormalizationUtil.normalizeName('   '));
    }

    @IsTest
    static void buildMatchKey_email() {
        System.assertEquals('Contact|Email|test@test.com',
            MergeDataNormalizationUtil.buildMatchKey('Contact', 'Email', 'Test@Test.com'));
    }

    @IsTest
    static void buildMatchKey_phone() {
        System.assertEquals('Contact|Phone|5141234567',
            MergeDataNormalizationUtil.buildMatchKey('Contact', 'Phone', '(514) 123-4567'));
    }

    @IsTest
    static void buildMatchKey_name() {
        System.assertEquals('Contact|Name|SMITH JOHN',
            MergeDataNormalizationUtil.buildMatchKey('Contact', 'Name', 'Smith John'));
    }

    @IsTest
    static void buildMatchKey_blankNormalized_returnsNull() {
        System.assertEquals(null,
            MergeDataNormalizationUtil.buildMatchKey('Contact', 'Email', ''));
        System.assertEquals(null,
            MergeDataNormalizationUtil.buildMatchKey('Contact', 'Phone', 'abc'));
    }

    @IsTest
    static void buildMatchKey_unknownType_usesRawTrim() {
        String key = MergeDataNormalizationUtil.buildMatchKey('Contact', 'Other', ' val ');
        System.assertEquals('Contact|Other|val', key);
    }

    @IsTest
    static void inferConfidence_allBranches() {
        System.assertEquals('High',   MergeDataNormalizationUtil.inferConfidence('Email', 1));
        System.assertEquals('High',   MergeDataNormalizationUtil.inferConfidence('Phone', 2));
        System.assertEquals('Medium', MergeDataNormalizationUtil.inferConfidence('Phone', 1));
        System.assertEquals('Low',    MergeDataNormalizationUtil.inferConfidence('Name',  1));
    }

    // ─── MergeWrappers — DTO constructors + computeDerived ───────────────────

    @IsTest
    static void relatedCounts_computeDerived_withActiveRecords() {
        MergeWrappers.RelatedCountsWrapper w = new MergeWrappers.RelatedCountsWrapper();
        MergeWrappers.RelatedCount rc1 = new MergeWrappers.RelatedCount('Cours');
        rc1.total = 3; rc1.active = 1;
        MergeWrappers.RelatedCount rc2 = new MergeWrappers.RelatedCount('Programmes');
        rc2.total = 2; rc2.active = 0;
        MergeWrappers.RelatedCount rc3 = new MergeWrappers.RelatedCount('Affiliations');
        rc3.total = 1;
        w.counts.add(rc1); w.counts.add(rc2); w.counts.add(rc3);
        w.computeDerived();
        System.assertEquals(6, w.totalRelated);
        System.assertEquals(true,  w.hasActiveRecords);
        System.assertEquals(true,  rc1.hasActive);
        System.assertEquals(false, rc2.hasActive);
    }

    @IsTest
    static void relatedCounts_computeDerived_noActive() {
        MergeWrappers.RelatedCountsWrapper w = new MergeWrappers.RelatedCountsWrapper();
        MergeWrappers.RelatedCount rc1 = new MergeWrappers.RelatedCount('Cours');
        rc1.total = 1;
        MergeWrappers.RelatedCount rc2 = new MergeWrappers.RelatedCount('Programmes');
        rc2.total = 1;
        w.counts.add(rc1); w.counts.add(rc2);
        w.computeDerived();
        System.assertEquals(2, w.totalRelated);
        System.assertEquals(false, w.hasActiveRecords);
    }

    @IsTest
    static void relatedCounts_getByLabel_returnsEmptyOnMiss() {
        MergeWrappers.RelatedCountsWrapper w = new MergeWrappers.RelatedCountsWrapper();
        MergeWrappers.RelatedCount found = w.getByLabel('Nonexistent');
        System.assertEquals('Nonexistent', found.label);
        System.assertEquals(0, found.total);
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
        System.assertNotEquals(null, rci.relatedCounts);
    }

    // ─── MergeSnapshotService ─────────────────────────────────────────────────────

    @IsTest
    static void captureSnapshot_nullRecord_returnsEmpty() {
        Map<String,Object> snap = MergeSnapshotService.captureSnapshot(null);
        System.assertEquals(0, snap.size());
    }

    @IsTest
    static void captureSnapshot_basicRecord_includesFieldsAndMeta() {
        Account acc = new Account(Name = 'Snapshot Test');
        insert acc;
        Account q = [SELECT Id, Name FROM Account WHERE Id = :acc.Id];
        Map<String,Object> snap = MergeSnapshotService.captureSnapshot(q);
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
        String json = MergeSnapshotService.captureAndSerialize(q);
        System.assert(json.contains('Ser Test'), 'JSON should contain account name');
    }

    @IsTest
    static void captureSnapshotsBulk_returnsMapPerRecord() {
        Account a1 = new Account(Name = 'Bulk A');
        Account a2 = new Account(Name = 'Bulk B');
        insert new List<Account>{ a1, a2 };
        List<Account> queried = [SELECT Id, Name FROM Account
                                  WHERE Id IN :new Set<Id>{ a1.Id, a2.Id }];
        Integer bulkSize = MergeSnapshotService.captureSnapshotsBulk(queried).size();
        System.assertEquals(2, bulkSize);
    }

    @IsTest
    static void captureSnapshotsBulk_containsExpectedId() {
        Account a = new Account(Name = 'BulkId Test');
        insert a;
        Account q = [SELECT Id, Name FROM Account WHERE Id = :a.Id];
        String idStr = String.valueOf(a.Id);
        System.assertEquals(true,
            MergeSnapshotService.captureSnapshotsBulk(new List<SObject>{ q }).containsKey(idStr));
    }

    @IsTest
    static void diffSnapshots_detectsChangedField() {
        Map<String,Object> before = new Map<String,Object>{ 'Email' => 'a@x.com', 'Phone' => '123' };
        Map<String,Object> after  = new Map<String,Object>{ 'Email' => 'b@x.com', 'Phone' => '123' };
        Map<String,Object> diff   = MergeSnapshotService.diffSnapshots(before, after);
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
        Map<String,Object> diff = MergeSnapshotService.diffSnapshots(before, after);
        System.assertEquals(0, diff.size());
    }

    @IsTest
    static void diffSnapshots_newFieldInAfter_appearsInDiff() {
        Map<String,Object> before = new Map<String,Object>{ 'Email' => null };
        Map<String,Object> after  = new Map<String,Object>{ 'Email' => 'x@x.com' };
        Map<String,Object> diff   = MergeSnapshotService.diffSnapshots(before, after);
        System.assertEquals(true, diff.containsKey('Email'));
    }

    @IsTest
    static void deserialize_blankString_returnsEmpty() {
        System.assertEquals(0, MergeSnapshotService.deserialize('').size());
        System.assertEquals(0, MergeSnapshotService.deserialize(null).size());
    }

    @IsTest
    static void serializeBulkSnapshots_returnsValidJson() {
        Account a = new Account(Name = 'BulkSer');
        insert a;
        Account q = [SELECT Id, Name FROM Account WHERE Id = :a.Id];
        String json = MergeSnapshotService.serializeBulkSnapshots(new List<SObject>{ q });
        System.assert(json.startsWith('{'), 'Expected JSON object');
    }

    // ─── MergeRelatedRecordsService ────────────────────────────────────────────────

    @IsTest
    static void isEDAAvailable_doesNotThrow() {
        Boolean result = MergeRelatedRecordsService.isEDAAvailable();
        System.assertNotEquals(null, result);
    }

    @IsTest
    static void getBulkCounts_emptySet_returnsEmptyMap() {
        Integer sz = MergeRelatedRecordsService.getBulkCountsForContacts(new Set<Id>()).size();
        System.assertEquals(0, sz);
    }

    @IsTest
    static void getCountsForContact_noEDAData_returnsZeroCounts() {
        Contact c = new Contact(LastName = 'RelSvcTestZero');
        insert c;
        MergeWrappers.RelatedCountsWrapper w =
            MergeRelatedRecordsService.getCountsForContact(c.Id);
        System.assertNotEquals(null, w);
        System.assertNotEquals(null, w.counts);
        System.assertEquals(0, w.totalRelated);
    }

    @IsTest
    static void getBulkCounts_multipleContacts_returnsEntryPerContact() {
        Contact c1 = new Contact(LastName = 'BulkRelSvc1');
        Contact c2 = new Contact(LastName = 'BulkRelSvc2');
        insert new List<Contact>{ c1, c2 };
        Integer sz = MergeRelatedRecordsService.getBulkCountsForContacts(
            new Set<Id>{ c1.Id, c2.Id }).size();
        System.assertEquals(2, sz);
    }

    @IsTest
    static void relatedRecordsService_unknownObjectType_returnsEmptyWrapper() {
        Contact c = new Contact(LastName = 'RelSvcUnknown');
        insert c;
        Map<Id,MergeWrappers.RelatedCountsWrapper> result =
            MergeRelatedRecordsService.getBulkCounts(new Set<Id>{ c.Id }, 'Lead');
        System.assertEquals(1, result.size());
        System.assertEquals(0, result.get(c.Id).counts.size(),
            'Unknown object type should yield empty counts list');
    }

    // ─── MergeSnapshotService: null sType branch (line 128) ───────────────────────

    @IsTest
    static void snapshotService_getDescribeMap_unknownType_returnsEmptyMap() {
        // Covers MergeSnapshotService line 128: sType == null → returns new Map<>()
        Map<String,Schema.SObjectField> result =
            MergeSnapshotService.getDescribeMap('Totally_Nonexistent_Object__xyz');
        System.assertNotEquals(null, result, 'Must return an empty map, not null');
        System.assertEquals(0, result.size(), 'Unknown objectType must produce empty field map');
    }
}
