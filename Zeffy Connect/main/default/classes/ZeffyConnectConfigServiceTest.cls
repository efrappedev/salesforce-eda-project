@isTest
private class ZeffyConnectConfigServiceTest {

    // ─── loadConfig — no config in the org ───────────────────────────────────

    @isTest
    static void testLoadConfigNoConfig() {
        // No Zeffy_Config__c exists — loadConfig should return safe defaults
        Test.startTest();
        Map<String, Object> cfg = ZeffyConnectConfigService.loadConfig();
        Test.stopTest();

        System.assertNotEquals(null, cfg, 'loadConfig should never return null');
        System.assertEquals('false', cfg.get('isConfigured'), 'isConfigured should be false when no config');
        System.assertEquals('en', cfg.get('language'), 'language default is en');
    }

    // ─── loadConfig — org-level config present ───────────────────────────────

    @isTest
    static void testLoadConfigWithConfig() {
        insert new Zeffy_Config__c(
            SetupOwnerId      = UserInfo.getOrganizationId(),
            Webhook_Secret__c = 'secret_abc_123456',
            API_Key__c        = 'apikey_abc_1234567890',
            Is_Active__c      = true,
            Language__c       = 'fr',
            Auto_Task_Enabled__c    = true,
            Task_Due_Days__c        = 3,
            Task_Owner_Id__c        = UserInfo.getUserId(),
            Task_Owner_Name__c      = 'Test Owner',
            Lapsed_Alert_Enabled__c = false,
            Lapsed_Days__c          = 180
        );

        Test.startTest();
        Map<String, Object> cfg = ZeffyConnectConfigService.loadConfig();
        Test.stopTest();

        System.assertEquals('true', cfg.get('isConfigured'), 'isConfigured should be true when secret set');
        System.assertEquals('true', cfg.get('isActive'));
        System.assertNotEquals('', cfg.get('webhookSecret'), 'Secret should be masked, not empty');
        System.assertNotEquals('', cfg.get('apiKey'), 'API key should be masked, not empty');
        // Language falls back to org-level since no user-level config
        System.assertNotEquals(null, cfg.get('language'));
    }

    // ─── saveConfig — creates new org-level config ────────────────────────────

    @isTest
    static void testSaveConfigNew() {
        grantSettingsAccess();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            ZeffyConnectConfigService.saveConfig('my_api_key_1234', 'my_secret_5678', true, null);
            Test.stopTest();
        }

        Zeffy_Config__c saved = Zeffy_Config__c.getOrgDefaults();
        System.assertNotEquals(null, saved, 'Config should have been created');
        System.assertEquals('my_api_key_1234', saved.API_Key__c);
        System.assertEquals('my_secret_5678',  saved.Webhook_Secret__c);
        System.assertEquals(true, saved.Is_Active__c);
    }

    // ─── saveConfig — updates existing, masked values are skipped ─────────────

    @isTest
    static void testSaveConfigMaskedValuesNotOverwritten() {
        grantSettingsAccess();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new Zeffy_Config__c(
                SetupOwnerId      = UserInfo.getOrganizationId(),
                API_Key__c        = 'original_api_key',
                Webhook_Secret__c = 'original_secret',
                Is_Active__c      = true
            );

            Test.startTest();
            // Passing masked values — should NOT overwrite
            ZeffyConnectConfigService.saveConfig('orig****_key', 'orig****_sec', false, null);
            Test.stopTest();
        }

        Zeffy_Config__c saved = Zeffy_Config__c.getOrgDefaults();
        System.assertEquals('original_api_key', saved.API_Key__c, 'Masked API key should not be saved');
        System.assertEquals('original_secret',  saved.Webhook_Secret__c, 'Masked secret should not be saved');
        System.assertEquals(false, saved.Is_Active__c, 'Is_Active should be updated');
    }

    // ─── saveConfig — isActive null defaults to true ─────────────────────────

    @isTest
    static void testSaveConfigActiveNullDefaultsTrue() {
        grantSettingsAccess();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            ZeffyConnectConfigService.saveConfig(null, null, null, null);
            Test.stopTest();
        }

        Zeffy_Config__c saved = Zeffy_Config__c.getOrgDefaults();
        System.assertEquals(true, saved.Is_Active__c, 'null isActive should default to true');
    }

    // ─── saveLanguage — creates new user-level record ─────────────────────────

    @isTest
    static void testSaveLanguageNew() {
        Test.startTest();
        ZeffyConnectConfigService.saveLanguage('fr');
        Test.stopTest();

        Zeffy_Config__c userCfg = Zeffy_Config__c.getInstance(UserInfo.getUserId());
        System.assertNotEquals(null, userCfg, 'User config should exist');
        System.assertEquals('fr', userCfg.Language__c);
    }

    // ─── saveLanguage — updates existing user-level record ───────────────────

    @isTest
    static void testSaveLanguageUpdate() {
        insert new Zeffy_Config__c(
            SetupOwnerId = UserInfo.getUserId(),
            Language__c  = 'en'
        );

        Test.startTest();
        ZeffyConnectConfigService.saveLanguage('fr');
        Test.stopTest();

        Zeffy_Config__c userCfg = Zeffy_Config__c.getInstance(UserInfo.getUserId());
        System.assertEquals('fr', userCfg.Language__c);
    }

    // ─── saveLanguage — blank input is ignored ────────────────────────────────

    @isTest
    static void testSaveLanguageBlankIgnored() {
        Test.startTest();
        ZeffyConnectConfigService.saveLanguage('');   // should return early
        ZeffyConnectConfigService.saveLanguage(null); // should return early
        Test.stopTest();
        // No exception = pass
    }

    // ─── saveAppSettings — lapsed disabled ───────────────────────────────────

    @isTest
    static void testSaveAppSettingsLapsedDisabled() {
        grantSettingsAccess();
        // runAs refreshes the permission cache so the custom permission is visible
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            ZeffyConnectConfigService.saveAppSettings(
                false, 2, null, null,
                false, 365, null, null, 'MON', 'WEEKLY'
            );
            Test.stopTest();

            Zeffy_Config__c saved = Zeffy_Config__c.getOrgDefaults();
            System.assertEquals(false, saved.Lapsed_Alert_Enabled__c);
            System.assertEquals(false, saved.Auto_Task_Enabled__c);
        }
    }

    // ─── saveAppSettings — lapsed enabled (schedules batch) ──────────────────

    @isTest
    static void testSaveAppSettingsLapsedEnabled() {
        grantSettingsAccess();
        // runAs refreshes the permission cache so the custom permission is visible
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new Zeffy_Config__c(
                SetupOwnerId = UserInfo.getOrganizationId(),
                Is_Active__c = true
            );

            Test.startTest();
            ZeffyConnectConfigService.saveAppSettings(
                true, 3, UserInfo.getUserId(), 'Test User',
                true, 180, UserInfo.getUserId(), 'Test User',
                'TUE', 'WEEKLY'
            );
            Test.stopTest();

            Zeffy_Config__c saved = Zeffy_Config__c.getOrgDefaults();
            System.assertEquals(true, saved.Lapsed_Alert_Enabled__c);
            System.assertEquals(true, saved.Auto_Task_Enabled__c);
            System.assertEquals(180, (Integer) saved.Lapsed_Days__c);
            System.assertEquals('TUE', saved.Lapsed_Schedule_Day__c);
        }
    }

    // ─── saveAppSettings — monthly frequency ─────────────────────────────────

    @isTest
    static void testSaveAppSettingsMonthly() {
        grantSettingsAccess();
        // runAs refreshes the permission cache so the custom permission is visible
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new Zeffy_Config__c(
                SetupOwnerId = UserInfo.getOrganizationId(),
                Is_Active__c = true
            );

            Test.startTest();
            ZeffyConnectConfigService.saveAppSettings(
                false, 2, null, null,
                true, 365, null, null, 'MON', 'MONTHLY'
            );
            Test.stopTest();

            Zeffy_Config__c saved = Zeffy_Config__c.getOrgDefaults();
            System.assertEquals('MONTHLY', saved.Lapsed_Schedule_Frequency__c);
        }
    }

    // ─── searchAccounts — term too short → empty result ──────────────────────

    @isTest
    static void testSearchAccountsTooShort() {
        Test.startTest();
        List<Map<String, String>> r1 = ZeffyConnectConfigService.searchAccounts('A');
        List<Map<String, String>> r2 = ZeffyConnectConfigService.searchAccounts(null);
        List<Map<String, String>> r3 = ZeffyConnectConfigService.searchAccounts('');
        Test.stopTest();

        System.assertEquals(0, r1.size());
        System.assertEquals(0, r2.size());
        System.assertEquals(0, r3.size());
    }

    // ─── searchAccounts — returns matching PersonAccount ─────────────────────

    @isTest
    static void testSearchAccountsFound() {
        Id personRtId = [SELECT Id FROM RecordType WHERE SObjectType = 'Account'
                         AND DeveloperName = 'PersonAccount' LIMIT 1]?.Id;
        insert new Account(RecordTypeId = personRtId,
                           FirstName = 'Tester', LastName = 'Tremblay',
                           PersonEmail = 'tester@search.ca');

        Test.startTest();
        List<Map<String, String>> results = ZeffyConnectConfigService.searchAccounts('Tremblay');
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals('Tester Tremblay', results[0].get('name'));
        System.assertEquals('tester@search.ca', results[0].get('detail'));
    }

    // ─── searchOwners — no filter returns users + queues ─────────────────────

    @isTest
    static void testSearchOwnersNoFilter() {
        Test.startTest();
        List<Map<String, String>> results = ZeffyConnectConfigService.searchOwners(null);
        Test.stopTest();

        System.assertNotEquals(0, results.size(), 'Should return at least current user');
        Boolean foundUser = false;
        for (Map<String, String> r : results) {
            if (r.get('type') == 'user') { foundUser = true; break; }
        }
        System.assertEquals(true, foundUser);
    }

    // ─── searchOwners — with filter ──────────────────────────────────────────

    @isTest
    static void testSearchOwnersWithFilter() {
        Test.startTest();
        // Filter by current user's name (always present)
        String userName = UserInfo.getName();
        List<Map<String, String>> results = ZeffyConnectConfigService.searchOwners(userName.substring(0, 3));
        Test.stopTest();

        System.assertNotEquals(null, results);
    }

    // ─── saveConfig — saves webhookEndpointUrl ───────────────────────────────

    @isTest
    static void testSaveConfigWebhookUrl() {
        grantSettingsAccess();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            ZeffyConnectConfigService.saveConfig(null, null, true, 'https://example.my.salesforce-sites.com/webhook');
            Test.stopTest();
        }

        Zeffy_Config__c saved = Zeffy_Config__c.getOrgDefaults();
        System.assertEquals('https://example.my.salesforce-sites.com/webhook', saved.Webhook_Endpoint_Url__c);
    }

    // ─── loadConfig — returns webhookEndpointUrl ─────────────────────────────

    @isTest
    static void testLoadConfigWebhookUrl() {
        insert new Zeffy_Config__c(
            SetupOwnerId          = UserInfo.getOrganizationId(),
            Webhook_Secret__c     = 'sec_abc_1234567',
            Webhook_Endpoint_Url__c = 'https://test.salesforce-sites.com/hook'
        );

        Test.startTest();
        Map<String, Object> cfg = ZeffyConnectConfigService.loadConfig();
        Test.stopTest();

        System.assertEquals('https://test.salesforce-sites.com/hook', cfg.get('webhookEndpointUrl'));
    }

    // ─── sendTestWebhook — no secret configured ──────────────────────────────

    @isTest
    static void testSendTestWebhookNoSecret() {
        grantSettingsAccess();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            Map<String, Object> result = ZeffyConnectConfigService.sendTestWebhook('payment.completed');
            Test.stopTest();

            System.assertEquals(false, result.get('success'));
            System.assert(String.valueOf(result.get('message')).contains('Webhook Secret'), 'Should mention secret');
        }
    }

    // ─── sendTestWebhook — secret configured but no URL ─────────────────────

    @isTest
    static void testSendTestWebhookNoUrl() {
        grantSettingsAccess();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new Zeffy_Config__c(
                SetupOwnerId      = UserInfo.getOrganizationId(),
                Webhook_Secret__c = 'secret_abc_12345678'
            );

            Test.startTest();
            Map<String, Object> result = ZeffyConnectConfigService.sendTestWebhook('payment.created');
            Test.stopTest();

            System.assertEquals(false, result.get('success'));
            System.assert(String.valueOf(result.get('message')).contains('Webhook Endpoint URL'), 'Should mention URL');
        }
    }

    // ─── sendTestWebhook — mock HTTP 200 response ────────────────────────────

    private class Mock200 implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setStatusCode(200);
            res.setBody('ok');
            return res;
        }
    }

    @isTest
    static void testSendTestWebhookCalloutSuccess() {
        grantSettingsAccess();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new Zeffy_Config__c(
                SetupOwnerId            = UserInfo.getOrganizationId(),
                Webhook_Secret__c       = 'secret_abc_12345678',
                Webhook_Endpoint_Url__c = 'https://example.salesforce-sites.com/hook'
            );

            Test.setMock(HttpCalloutMock.class, new Mock200());
            Test.startTest();
            Map<String, Object> result = ZeffyConnectConfigService.sendTestWebhook('payment.completed');
            Test.stopTest();

            System.assertEquals(true,  result.get('success'));
            System.assertEquals(200,   result.get('status'));
            System.assert(String.valueOf(result.get('txId')).startsWith('TEST-'), 'txId should start with TEST-');
        }
    }

    // ─── sendTestWebhook — mock HTTP 500 (endpoint error) ───────────────────

    private class Mock500 implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setStatusCode(500);
            res.setBody('Internal Server Error');
            return res;
        }
    }

    @isTest
    static void testSendTestWebhookCalloutFailure() {
        grantSettingsAccess();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new Zeffy_Config__c(
                SetupOwnerId            = UserInfo.getOrganizationId(),
                Webhook_Secret__c       = 'secret_abc_12345678',
                Webhook_Endpoint_Url__c = 'https://example.salesforce-sites.com/hook'
            );

            Test.setMock(HttpCalloutMock.class, new Mock500());
            Test.startTest();
            Map<String, Object> result = ZeffyConnectConfigService.sendTestWebhook('payment.deleted');
            Test.stopTest();

            System.assertEquals(false, result.get('success'));
            System.assertEquals(500,   result.get('status'));
        }
    }

    // ─── sendTestWebhook — non-admin is rejected ─────────────────────────────

    @isTest
    static void testSendTestWebhookRequiresAdmin() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Alias = 'zcnt', Email = 'zc.nonadmin.test@test.example', EmailEncodingKey = 'UTF-8',
            LastName = 'NonAdminTest', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_CA',
            ProfileId = p.Id, TimeZoneSidKey = 'America/Toronto',
            UserName = 'zc.nonadmin.test.' + System.currentTimeMillis() + '@test.example'
        );
        insert u;
        Boolean rejected = false;
        System.runAs(u) {
            Test.startTest();
            try {
                ZeffyConnectConfigService.sendTestWebhook('payment.completed');
            } catch (AuraHandledException e) {
                rejected = true;
            }
            Test.stopTest();
        }
        System.assert(rejected, 'Only admins can send test webhooks');
    }

    // ─── maskKey — short key (≤ 8 chars) is fully masked ────────────────────

    @isTest
    static void testMaskKeyShortValue() {
        // Insert config with a secret of exactly 6 chars (≤ 8 → should return '****')
        insert new Zeffy_Config__c(
            SetupOwnerId      = UserInfo.getOrganizationId(),
            Webhook_Secret__c = 'abc123',
            API_Key__c        = 'key456'
        );

        Test.startTest();
        Map<String, Object> cfg = ZeffyConnectConfigService.loadConfig();
        Test.stopTest();

        // Both values are short (≤ 8 chars) → should be masked as '****'
        System.assertEquals('****', cfg.get('webhookSecret'), 'Short secret should be fully masked');
        System.assertEquals('****', cfg.get('apiKey'), 'Short API key should be fully masked');
    }

    // ─── searchAccounts — returns BillingCity in detail when present ──────────

    @isTest
    static void testSearchAccountsWithBillingCity() {
        Id personRtId = [SELECT Id FROM RecordType WHERE SObjectType = 'Account'
                         AND DeveloperName = 'PersonAccount' LIMIT 1]?.Id;
        insert new Account(
            RecordTypeId = personRtId,
            FirstName    = 'Marie',
            LastName     = 'Bergeron',
            PersonEmail  = 'marie.bc@test.ca',
            BillingCity  = 'Québec'
        );

        Test.startTest();
        List<Map<String, String>> results = ZeffyConnectConfigService.searchAccounts('Bergeron');
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assert(results[0].get('detail').contains('Québec'), 'BillingCity should appear in detail');
    }

    // ─── saveEventToggles — saves all event toggle flags ─────────────────────

    @isTest
    static void testSaveEventToggles() {
        grantSettingsAccess();
        // runAs refreshes the permission cache so the custom permission is visible
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            ZeffyConnectConfigService.saveEventToggles(true, false, true, false, false, 10);
            Test.stopTest();

            Zeffy_Config__c saved = Zeffy_Config__c.getOrgDefaults();
            System.assertEquals(true,  saved.Process_Payment_Created__c);
            System.assertEquals(false, saved.Process_Payment_Updated__c);
            System.assertEquals(true,  saved.Process_Payment_Deleted__c);
            System.assertEquals(false, saved.Process_Contact_Events__c);
            System.assertEquals(false, saved.Holding_Auto_Expire_Enabled__c);
            System.assertEquals(10,    (Integer) saved.Holding_Expire_Days__c);
        }
    }

    @isTest
    static void testSaveEventTogglesHoldingEnabled() {
        grantSettingsAccess();
        // runAs refreshes the permission cache so the custom permission is visible
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            ZeffyConnectConfigService.saveEventToggles(true, true, true, false, true, 7);
            Test.stopTest();

            Zeffy_Config__c saved = Zeffy_Config__c.getOrgDefaults();
            System.assertEquals(true, saved.Holding_Auto_Expire_Enabled__c);
            System.assertEquals(7,    (Integer) saved.Holding_Expire_Days__c);
            // Job should be scheduled
            List<CronTrigger> jobs = [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'ZeffyHoldingExpireBatch'];
            System.assertEquals(1, jobs.size(), 'Batch should be scheduled when toggle is ON');
        }
    }

    @isTest
    static void testSaveEventTogglesHoldingDisabled() {
        grantSettingsAccess();
        // runAs refreshes the permission cache so the custom permission is visible
        System.runAs(new User(Id = UserInfo.getUserId())) {
            // Schedule it first, then disable to verify unschedule
            ZeffyHoldingExpireBatch.schedule();
            Test.startTest();
            ZeffyConnectConfigService.saveEventToggles(true, true, true, false, false, 10);
            Test.stopTest();

            List<CronTrigger> jobs = [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'ZeffyHoldingExpireBatch'];
            System.assertEquals(0, jobs.size(), 'Batch should be unscheduled when toggle is OFF');
        }
    }

    // ─── sendTestWebhook — Http().send() throws exception ───────────────────

    private class MockThrow implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            throw new CalloutException('Connection refused by server');
        }
    }

    @isTest
    static void testSendTestWebhookCalloutException() {
        grantSettingsAccess();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new Zeffy_Config__c(
                SetupOwnerId            = UserInfo.getOrganizationId(),
                Webhook_Secret__c       = 'secret_abc_12345678',
                Webhook_Endpoint_Url__c = 'https://example.salesforce-sites.com/hook'
            );

            Test.setMock(HttpCalloutMock.class, new MockThrow());
            Test.startTest();
            Map<String, Object> result = ZeffyConnectConfigService.sendTestWebhook('payment.completed');
            Test.stopTest();

            System.assertEquals(false, result.get('success'));
            System.assert(String.valueOf(result.get('message')).contains('Connection refused'),
                'Exception message should propagate to result');
        }
    }

    // ─── searchOwners — queue loop body covered when queues exist ────────────

    @isTest
    static void testSearchOwnersWithQueue() {
        Group q = new Group(Name = 'Test Zeffy Queue', Type = 'Queue');
        insert q;

        Test.startTest();
        List<Map<String, String>> results = ZeffyConnectConfigService.searchOwners('Test Zeffy');
        Test.stopTest();

        Boolean foundQueue = false;
        for (Map<String, String> r : results) {
            if (r.get('type') == 'queue') { foundQueue = true; break; }
        }
        System.assertEquals(true, foundQueue, 'Queue loop body should execute — queue should appear in results');
    }

    @isTest
    static void testSaveConfigNullBranch() {
        // Delete existing org config so getOrgDefaults() returns null → covers line 54
        grantSettingsAccess();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Zeffy_Config__c existing = Zeffy_Config__c.getOrgDefaults();
            if (existing != null && existing.Id != null) delete existing;
            Test.startTest();
            ZeffyConnectConfigService.saveConfig('apikey_nullbranch', 'secret_nullbranch', true, null);
            Test.stopTest();
        }
        System.assertNotEquals(null, Zeffy_Config__c.getOrgDefaults(), 'Config should be created from null branch');
    }

    @isTest
    static void testSaveLanguageNullBranch() {
        // Delete org config so getInstance returns null → covers line 75
        Zeffy_Config__c orgCfg = Zeffy_Config__c.getOrgDefaults();
        if (orgCfg != null && orgCfg.Id != null) delete orgCfg;
        Test.startTest();
        ZeffyConnectConfigService.saveLanguage('fr');
        Test.stopTest();
        System.assertNotEquals(null, Zeffy_Config__c.getInstance(UserInfo.getUserId()));
    }

    @isTest
    static void testSaveEventTogglesNullBranch() {
        grantSettingsAccess();
        // runAs refreshes the permission cache so the custom permission is visible
        System.runAs(new User(Id = UserInfo.getUserId())) {
            // Delete org config so getOrgDefaults() returns null → covers the null-create branch
            Zeffy_Config__c existing = Zeffy_Config__c.getOrgDefaults();
            if (existing != null && existing.Id != null) delete existing;
            Test.startTest();
            ZeffyConnectConfigService.saveEventToggles(true, false, true, false, false, 10);
            Test.stopTest();
            System.assertNotEquals(null, Zeffy_Config__c.getOrgDefaults(), 'Config created from null branch');
        }
    }

    @isTest
    static void testSaveAppSettingsNullBranch() {
        grantSettingsAccess();
        // runAs refreshes the permission cache so the custom permission is visible
        System.runAs(new User(Id = UserInfo.getUserId())) {
            // Delete org config so getOrgDefaults() returns null → covers line 107
            Zeffy_Config__c existing = Zeffy_Config__c.getOrgDefaults();
            if (existing != null && existing.Id != null) delete existing;
            Test.startTest();
            ZeffyConnectConfigService.saveAppSettings(
                true, 3, null, null,
                false, 365, null, null, null, null
            );
            Test.stopTest();
            System.assertNotEquals(null, Zeffy_Config__c.getOrgDefaults(), 'Config created from null branch');
        }
    }

    // ─── Holding auto-expire: disabled timestamp for the warning banner ─────

    @isTest
    static void testHoldingExpireDisabledAtTracking() {
        grantSettingsAccess();
        // runAs refreshes the permission cache so the custom permission is visible
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            ZeffyConnectConfigService.saveEventToggles(false, true, true, false, true, 10);   // ON
            System.assertEquals('', ZeffyConnectConfigService.loadConfig().get('holdingExpireDisabledAt'), 'No timestamp while on');

            ZeffyConnectConfigService.saveEventToggles(false, true, true, false, false, 10);  // ON → OFF
            String offAt = (String) ZeffyConnectConfigService.loadConfig().get('holdingExpireDisabledAt');
            System.assert(String.isNotBlank(offAt), 'Timestamp recorded when switched off');

            ZeffyConnectConfigService.saveEventToggles(true, true, true, false, false, 10);   // OFF → OFF (other toggle)
            System.assertEquals(offAt, ZeffyConnectConfigService.loadConfig().get('holdingExpireDisabledAt'), 'Original timestamp kept');

            ZeffyConnectConfigService.saveEventToggles(false, true, true, false, true, 10);   // OFF → ON
            Test.stopTest();
            System.assertEquals('', ZeffyConnectConfigService.loadConfig().get('holdingExpireDisabledAt'), 'Cleared when back on');
        }
    }

    // ─── saveTicketActions — admin-only follow-up toggle ─────────────────────

    @isTest
    static void testSaveTicketActionsAdmin() {
        grantSettingsAccess();
        System.assertEquals('false', ZeffyConnectConfigService.loadConfig().get('showFollowup'), 'Hidden by default');

        // runAs refreshes the permission cache so the custom permission is visible
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            ZeffyConnectConfigService.saveTicketActions(true);
            Test.stopTest();
        }
        System.assertEquals('true', ZeffyConnectConfigService.loadConfig().get('showFollowup'), 'Admin can show the button');
    }

    @isTest
    static void testSaveTicketActionsNonAdminRejected() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Alias = 'zcna', Email = 'zc.nonadmin@test.example', EmailEncodingKey = 'UTF-8',
            LastName = 'NonAdmin', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_CA',
            ProfileId = p.Id, TimeZoneSidKey = 'America/Toronto',
            UserName = 'zc.nonadmin.' + System.currentTimeMillis() + '@test.example'
        );
        insert u;
        Boolean rejected = false;
        System.runAs(u) {
            Test.startTest();
            try {
                ZeffyConnectConfigService.saveTicketActions(true);
            } catch (AuraHandledException e) {
                rejected = true;
            }
            Test.stopTest();
        }
        System.assert(rejected, 'Users without the custom permission cannot change the toggle');
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        System.assert(cfg == null || cfg.Show_Followup_Button__c != true, 'Toggle stays off');
    }

    @isTest
    static void testSaveConfigNonAdminRejected() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Alias = 'zcnc', Email = 'zc.nonadmin.cfg@test.example', EmailEncodingKey = 'UTF-8',
            LastName = 'NonAdminCfg', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_CA',
            ProfileId = p.Id, TimeZoneSidKey = 'America/Toronto',
            UserName = 'zc.nonadmin.cfg.' + System.currentTimeMillis() + '@test.example'
        );
        insert u;
        Boolean rejected = false;
        System.runAs(u) {
            Test.startTest();
            try {
                ZeffyConnectConfigService.saveConfig('stolen_key', 'stolen_secret', true, null);
            } catch (AuraHandledException e) {
                rejected = true;
            }
            Test.stopTest();
        }
        System.assert(rejected, 'Non-admin must not be able to change the Zeffy credentials');
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        System.assertNotEquals('stolen_key', cfg == null ? null : cfg.API_Key__c, 'API key must be unchanged');
    }

    // Zeffy_Connect_Admin_Access grants the Zeffy_Connect_Settings_Access custom permission.
    // Callers must re-enter via System.runAs so the permission cache picks it up.
    private static void grantSettingsAccess() {
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Zeffy_Connect_Admin_Access' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = ps.Id);
    }

    // Person account without email: the detail falls back to blank
    @isTest
    static void testSearchAccountsWithoutEmail() {
        Id personRtId = [SELECT Id FROM RecordType WHERE SObjectType = 'Account'
                         AND DeveloperName = 'PersonAccount' LIMIT 1]?.Id;
        insert new Account(RecordTypeId = personRtId, FirstName = 'Sans', LastName = 'Courriel');

        Test.startTest();
        List<Map<String, String>> results = ZeffyConnectConfigService.searchAccounts('Courriel');
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals('', results[0].get('detail'));
    }
}
