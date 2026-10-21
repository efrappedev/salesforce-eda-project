@isTest
private class BulkCleanFieldServiceTest {

    // Real Unicode characters embedded directly in the source (UTF-8), same
    // technique already proven by RegenerateIdService.ACCENT_MAP — not \u
    // escapes, which Apex string literals don't support.
    private static final String NARROW_NBSP = ' '; // U+202F — the confirmed French-locale culprit
    private static final String NBSP = ' '; // U+00A0
    private static final String IDEOGRAPHIC_SPACE = '　'; // U+3000
    private static final String ZERO_WIDTH_SPACE = '​'; // U+200B

    @TestSetup
    static void setup() {
        List<Account> accounts = new List<Account>();
        accounts.add(new Account(Name = 'Clean Field 0', AccountNumber = '1' + NARROW_NBSP + '799'));
        accounts.add(new Account(Name = 'Clean Field 1', AccountNumber = '1' + NBSP + '234'));
        accounts.add(new Account(Name = 'Clean Field 2', AccountNumber = 'AB' + ZERO_WIDTH_SPACE + 'CD'));
        accounts.add(new Account(Name = 'Clean Field 3', AccountNumber = 'ALREADY-CLEAN'));
        accounts.add(new Account(Name = 'Clean Field 4', AccountNumber = null));
        insert accounts;
    }

    @isTest
    static void testCleanValue_nullInput_returnsNull() {
        System.assertEquals(null, BulkCleanFieldService.cleanValue(null, true, true, true, '!@#'));
    }

    @isTest
    static void testCleanValue_noRulesSelected_isNoOp() {
        String raw = '1' + NARROW_NBSP + '799  spaced  ';
        System.assertEquals(raw, BulkCleanFieldService.cleanValue(raw, false, false, false, null));
    }

    @isTest
    static void testCleanValue_normalizeSpaces_narrowNoBreakSpace() {
        String raw = '1' + NARROW_NBSP + '799';
        System.assertEquals('1 799', BulkCleanFieldService.cleanValue(raw, true, false, false, null));
    }

    @isTest
    static void testCleanValue_normalizeSpaces_nbspAndIdeographicSpace() {
        System.assertEquals('1 234', BulkCleanFieldService.cleanValue('1' + NBSP + '234', true, false, false, null));
        System.assertEquals('A B', BulkCleanFieldService.cleanValue('A' + IDEOGRAPHIC_SPACE + 'B', true, false, false, null));
    }

    @isTest
    static void testCleanValue_normalizeSpaces_tab() {
        System.assertEquals('A B', BulkCleanFieldService.cleanValue('A\tB', true, false, false, null));
    }

    @isTest
    static void testCleanValue_normalizeSpaces_zeroWidthCharsStrippedNotReplaced() {
        // Zero-width characters have no visible width — "replace with a
        // space" would be wrong, they must disappear entirely.
        System.assertEquals('ABCD', BulkCleanFieldService.cleanValue('AB' + ZERO_WIDTH_SPACE + 'CD', true, false, false, null));
    }

    @isTest
    static void testCleanValue_customCharsToStrip_commaSeparatedSingleChars() {
        // Each comma-separated item is removed as a literal substring —
        // single characters listed one per item behave like the old
        // character-set stripping did.
        System.assertEquals('ABCD', BulkCleanFieldService.cleanValue('A!B@C#D', false, false, false, '!,@,#'));
    }

    @isTest
    static void testCleanValue_customCharsToStrip_duplicateItemsInList_noOp() {
        // Duplicate items in the user-typed list must not cause any
        // different behavior than a deduped list — replace() is idempotent
        // once the first occurrence is already gone.
        System.assertEquals('ABCD', BulkCleanFieldService.cleanValue('A!B@C#D', false, false, false, '!,@,#,!,@,#'));
    }

    @isTest
    static void testCleanValue_customCharsToStrip_wholeWordOrPhrase() {
        // An item longer than one character is removed as a whole literal
        // phrase, not character-by-character — e.g. an address annotation
        // like "(older)" the user wants gone entirely, wherever it appears.
        System.assertEquals(
            '123 Main St',
            BulkCleanFieldService.cleanValue('123 Main St (older)', false, true, true, '(older)')
        );
    }

    @isTest
    static void testCleanValue_customCharsToStrip_mixedCharsAndPhrases() {
        // A single comma-separated list can mix lone characters and whole
        // phrases in the same run.
        System.assertEquals(
            '123 Main St',
            BulkCleanFieldService.cleanValue('123 Main St (old)!', false, true, true, '!,(old)')
        );
    }

    @isTest
    static void testCleanValue_customCharsToStrip_whitespaceOnly_notTreatedAsBlank() {
        // String.isBlank()/isNotBlank() treat a whitespace-only string as
        // blank — cleanValue() must NOT use that check here, since a plain
        // space is a legitimate, deliberate strip target (e.g. removing
        // regular spaces after normalizeSpaces already converted exotic
        // ones to regular spaces).
        System.assertEquals('13000', BulkCleanFieldService.cleanValue('13 000', false, false, false, ' '));
    }

    @isTest
    static void testCleanValue_collapseSpaces() {
        System.assertEquals('A B', BulkCleanFieldService.cleanValue('A    B', false, true, false, null));
    }

    @isTest
    static void testCleanValue_trimEdges() {
        System.assertEquals('A B', BulkCleanFieldService.cleanValue('  A B  ', false, false, true, null));
    }

    @isTest
    static void testCleanValue_orderOfOperations_stripThenCollapseThenTrim() {
        // Stripping "-" out of " A - B " first creates a run of doubled
        // spaces around where the dash was, which collapse must still
        // catch, and the result must still be trimmed at the edges.
        String raw = ' A - B ';
        System.assertEquals('A B', BulkCleanFieldService.cleanValue(raw, false, true, true, '-'));
    }

    @isTest
    static void testCleanValue_allRulesCombined() {
        String raw = '  1' + NARROW_NBSP + '799' + ZERO_WIDTH_SPACE + '!!  ';
        System.assertEquals('1 799', BulkCleanFieldService.cleanValue(raw, true, true, true, '!'));
    }

    @isTest
    static void testGetCleanableFields_onlyStringLikeTypes() {
        Test.startTest();
        List<BulkEditWrappers.FieldOption> fields = BulkCleanFieldService.getCleanableFields('Account');
        Test.stopTest();

        Set<String> apiNames = new Set<String>();
        for (BulkEditWrappers.FieldOption f : fields) {
            apiNames.add(f.apiName);
            System.assert(
                new Set<String>{ 'STRING', 'PHONE', 'EMAIL', 'URL' }.contains(f.dataType),
                'Unexpected non-string-like field type offered: ' + f.dataType
            );
        }
        System.assert(apiNames.contains('AccountNumber'), 'AccountNumber (STRING) should be offered');
        System.assert(apiNames.contains('Phone'), 'Phone should be offered');
        System.assert(apiNames.contains('Website'), 'Website (URL) should be offered');
        System.assert(!apiNames.contains('Industry'), 'Picklist fields must not be offered');
        System.assert(!apiNames.contains('AnnualRevenue'), 'Currency fields must not be offered');
    }

    @isTest
    static void testPreviewCleanup_sampleAndTotals() {
        Test.startTest();
        BulkEditWrappers.CleanPreviewResult result = BulkCleanFieldService.previewCleanup(
            'Account', 'AccountNumber', null, null, null,
            true, true, true, null
        );
        Test.stopTest();

        // 4 of the 5 seeded Accounts have a non-blank AccountNumber.
        System.assertEquals(4, result.totalMatching);
        System.assertEquals(4, result.sampleSize);
        // 3 are dirty (narrow NBSP, NBSP, zero-width space); 1 is already clean.
        System.assertEquals(3, result.sampleWouldChange);

        Boolean foundCleanRow = false;
        for (BulkEditWrappers.CleanPreviewRow row : result.rows) {
            if (row.beforeValue == 'ALREADY-CLEAN') {
                foundCleanRow = true;
                System.assertEquals(false, row.willChange);
                System.assertEquals('ALREADY-CLEAN', row.afterValue);
                System.assertEquals('Clean Field 3', row.recordDisplay, 'Expected the row display to resolve to the Account Name, not the raw Id');
            }
        }
        System.assert(foundCleanRow, 'Expected the already-clean row to be present with willChange = false');
    }

    // BulkPasteUpdateService.resolveDisplayFieldName() was changed from
    // private to public so previewCleanup() above could reuse it — this
    // confirms the visibility-only change didn't alter its behavior.
    @isTest
    static void testResolveDisplayFieldName_stillResolvesNameField() {
        Schema.SObjectType sType = BulkEditService.resolveObjectType('Account');
        System.assertEquals('Name', BulkPasteUpdateService.resolveDisplayFieldName(sType));
    }

    @isTest
    static void testPreviewCleanup_withFilter() {
        Test.startTest();
        BulkEditWrappers.CleanPreviewResult result = BulkCleanFieldService.previewCleanup(
            'Account', 'AccountNumber', 'Name', 'Clean Field 0', false,
            true, false, false, null
        );
        Test.stopTest();

        System.assertEquals(1, result.totalMatching);
        System.assertEquals(1, result.sampleSize);
        System.assertEquals(1, result.sampleWouldChange);
    }

    @isTest
    static void testPreviewCleanup_invalidObject_throws() {
        Boolean threw = false;
        try {
            BulkCleanFieldService.previewCleanup(
                'Not_A_Real_Object__c', 'AccountNumber', null, null, null,
                true, true, true, null
            );
        } catch (BulkEditException ex) {
            threw = true;
        }
        System.assert(threw);
    }
}
