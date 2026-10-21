public with sharing class ZeffyConnectConfigService {

    // ── Load config for the current user ──────────────────────────────────────
    // Credentials: org-level only (masked). Language: user-level via hierarchy.
    // App-level settings (task automation, lapsed): org-level.
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> loadConfig() {
        Zeffy_Config__c userCfg = Zeffy_Config__c.getInstance();   // user > profile > org
        Zeffy_Config__c orgCfg  = Zeffy_Config__c.getOrgDefaults();

        Boolean configured = orgCfg != null && String.isNotBlank(orgCfg.Webhook_Secret__c);

        return new Map<String, Object>{
            // Credentials (admin only)
            'apiKey'          => orgCfg != null && String.isNotBlank(orgCfg.API_Key__c)
                                      ? maskKey(orgCfg.API_Key__c) : '',
            'webhookSecret'   => configured ? maskKey(orgCfg.Webhook_Secret__c) : '',
            'isActive'        => String.valueOf(orgCfg != null ? orgCfg.Is_Active__c : true),
            'isConfigured'    => String.valueOf(configured),
            // Language (per user, falls back to org default)
            'language'        => userCfg != null && String.isNotBlank(userCfg.Language__c)
                                      ? userCfg.Language__c : 'en',
            // Task automation (org-level)
            'autoTaskEnabled' => String.valueOf(orgCfg != null ? orgCfg.Auto_Task_Enabled__c : false),
            'taskDueDays'     => String.valueOf(orgCfg != null && orgCfg.Task_Due_Days__c != null
                                      ? (Integer) orgCfg.Task_Due_Days__c : 2),
            'taskOwnerId'     => orgCfg != null ? (orgCfg.Task_Owner_Id__c   ?? '') : '',
            'taskOwnerName'   => orgCfg != null ? (orgCfg.Task_Owner_Name__c ?? '') : '',
            // Lapsed donor alerts (org-level)
            'lapsedEnabled'      => String.valueOf(orgCfg != null ? orgCfg.Lapsed_Alert_Enabled__c : false),
            'lapsedDays'         => String.valueOf(orgCfg != null && orgCfg.Lapsed_Days__c != null
                                      ? (Integer) orgCfg.Lapsed_Days__c : 365),
            'lapsedOwnerId'      => orgCfg != null ? (orgCfg.Lapsed_Owner_Id__c    ?? '') : '',
            'lapsedOwnerName'    => orgCfg != null ? (orgCfg.Lapsed_Owner_Name__c  ?? '') : '',
            'lapsedScheduleDay'      => orgCfg != null && String.isNotBlank(orgCfg.Lapsed_Schedule_Day__c)
                                          ? orgCfg.Lapsed_Schedule_Day__c : 'MON',
            'lapsedScheduleFrequency'=> orgCfg != null && String.isNotBlank(orgCfg.Lapsed_Schedule_Frequency__c)
                                          ? orgCfg.Lapsed_Schedule_Frequency__c : 'WEEKLY',
            // Event processing toggles
            'processPaymentCreated'  => String.valueOf(orgCfg != null ? orgCfg.Process_Payment_Created__c : false),
            'processPaymentUpdated'  => String.valueOf(orgCfg != null ? orgCfg.Process_Payment_Updated__c : true),
            'processPaymentDeleted'  => String.valueOf(orgCfg != null ? orgCfg.Process_Payment_Deleted__c : true),
            'processContactEvents'   => String.valueOf(orgCfg != null ? orgCfg.Process_Contact_Events__c  : false),
            // Holding ticket auto-expiry
            'holdingExpireEnabled'   => String.valueOf(orgCfg != null ? orgCfg.Holding_Auto_Expire_Enabled__c : false),
            'holdingExpireDays'      => String.valueOf(orgCfg != null && orgCfg.Holding_Expire_Days__c != null
                                            ? (Integer) orgCfg.Holding_Expire_Days__c : 10),
            'holdingExpireDisabledAt'=> orgCfg != null && orgCfg.Holding_Expire_Disabled_At__c != null
                                            ? orgCfg.Holding_Expire_Disabled_At__c.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') : '',
            // Ticket actions (admin-controlled, read by every user)
            'showFollowup'          => String.valueOf(orgCfg != null ? orgCfg.Show_Followup_Button__c : false),
            // Webhook test
            'webhookEndpointUrl'    => orgCfg != null ? (orgCfg.Webhook_Endpoint_Url__c ?? '') : ''
        };
    }

    // ── Save ticket action visibility (admin only) ────────────────────────────
    @AuraEnabled
    public static void saveTicketActions(Boolean showFollowup) {
        requireSettingsAccess('Only Zeffy Connect administrators can change this setting.');
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        if (cfg == null || cfg.Id == null) {
            cfg = new Zeffy_Config__c(SetupOwnerId = UserInfo.getOrganizationId());
        }
        cfg.Show_Followup_Button__c = showFollowup == true;
        upsert cfg;
    }

    // ── Save credentials (admin only) ─────────────────────────────────────────
    @AuraEnabled
    public static void saveConfig(String apiKey, String webhookSecret, Boolean isActive, String webhookEndpointUrl) {
        // Credentials are admin-only — the LWC hides the section, this enforces it server-side
        requireSettingsAccess('Only Zeffy Connect administrators can change the Zeffy connection.');
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        if (cfg == null || cfg.Id == null) {
            cfg = new Zeffy_Config__c(SetupOwnerId = UserInfo.getOrganizationId());
        }
        if (String.isNotBlank(apiKey) && !apiKey.contains('****')) {
            cfg.API_Key__c = apiKey;
        }
        if (String.isNotBlank(webhookSecret) && !webhookSecret.contains('****')) {
            cfg.Webhook_Secret__c = webhookSecret;
        }
        cfg.Is_Active__c = isActive != null ? isActive : true;
        if (webhookEndpointUrl != null) {
            cfg.Webhook_Endpoint_Url__c = String.isNotBlank(webhookEndpointUrl) ? webhookEndpointUrl.trim() : null;
        }
        upsert cfg;
    }

    // ── Save language preference for the current user ─────────────────────────
    @AuraEnabled
    public static void saveLanguage(String language) {
        if (String.isBlank(language)) return;
        Zeffy_Config__c cfg = Zeffy_Config__c.getInstance(UserInfo.getUserId());
        if (cfg == null || cfg.Id == null) {
            cfg = new Zeffy_Config__c(SetupOwnerId = UserInfo.getUserId());
        }
        cfg.Language__c = language;
        upsert cfg;
    }

    // ── Save event processing toggles ────────────────────────────────────────
    @AuraEnabled
    public static void saveEventToggles(
        Boolean processPaymentCreated, Boolean processPaymentUpdated,
        Boolean processPaymentDeleted, Boolean processContactEvents,
        Boolean holdingExpireEnabled, Integer holdingExpireDays
    ) {
        requireSettingsAccess('Only Zeffy Connect administrators can change event processing.');
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        if (cfg == null || cfg.Id == null) {
            cfg = new Zeffy_Config__c(SetupOwnerId = UserInfo.getOrganizationId());
        }
        // Remember when auto-expire was switched off so the UI can warn if it stays off
        Boolean wasExpireOn = cfg.Holding_Auto_Expire_Enabled__c == true;
        Boolean isExpireOn  = holdingExpireEnabled == true;
        if (isExpireOn) {
            cfg.Holding_Expire_Disabled_At__c = null;
        } else if (wasExpireOn) {
            cfg.Holding_Expire_Disabled_At__c = DateTime.now();
        }
        cfg.Process_Payment_Created__c       = processPaymentCreated != null ? processPaymentCreated : false;
        cfg.Process_Payment_Updated__c       = processPaymentUpdated != null ? processPaymentUpdated : true;
        cfg.Process_Payment_Deleted__c       = processPaymentDeleted != null ? processPaymentDeleted : true;
        cfg.Process_Contact_Events__c        = processContactEvents  != null ? processContactEvents  : false;
        cfg.Holding_Auto_Expire_Enabled__c   = holdingExpireEnabled  != null ? holdingExpireEnabled  : false;
        cfg.Holding_Expire_Days__c           = holdingExpireDays     != null ? holdingExpireDays     : 10;
        upsert cfg;

        // Schedule or cancel the holding expiry batch based on toggle
        if (cfg.Holding_Auto_Expire_Enabled__c) {
            ZeffyHoldingExpireBatch.schedule();
        } else {
            ZeffyHoldingExpireBatch.unschedule();
        }
    }

    // ── Save app-level settings (task automation + lapsed donor) ─────────────
    @AuraEnabled
    public static void saveAppSettings(
        Boolean autoTaskEnabled, Integer taskDueDays, String taskOwnerId, String taskOwnerName,
        Boolean lapsedEnabled, Integer lapsedDays, String lapsedOwnerId, String lapsedOwnerName,
        String lapsedScheduleDay, String lapsedScheduleFrequency
    ) {
        requireSettingsAccess('Only Zeffy Connect administrators can change automation settings.');
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        if (cfg == null || cfg.Id == null) {
            cfg = new Zeffy_Config__c(SetupOwnerId = UserInfo.getOrganizationId());
        }
        cfg.Auto_Task_Enabled__c    = autoTaskEnabled  != null ? autoTaskEnabled : false;
        cfg.Task_Due_Days__c        = taskDueDays      != null ? taskDueDays     : 2;
        cfg.Task_Owner_Id__c        = taskOwnerId;
        cfg.Task_Owner_Name__c      = taskOwnerName;
        cfg.Lapsed_Alert_Enabled__c = lapsedEnabled    != null ? lapsedEnabled   : false;
        cfg.Lapsed_Days__c          = lapsedDays       != null ? lapsedDays      : 365;
        cfg.Lapsed_Owner_Id__c      = lapsedOwnerId;
        cfg.Lapsed_Owner_Name__c    = lapsedOwnerName;
        cfg.Lapsed_Schedule_Day__c       = String.isNotBlank(lapsedScheduleDay) ? lapsedScheduleDay : 'MON';
        cfg.Lapsed_Schedule_Frequency__c = String.isNotBlank(lapsedScheduleFrequency) ? lapsedScheduleFrequency : 'WEEKLY';

        // Re-schedule the lapsed donor batch based on new settings
        if (lapsedEnabled == true) {
            ZeffyConnectLapsedDonorBatch.schedule(cfg);
        } else {
            ZeffyConnectLapsedDonorBatch.unschedule();
        }

        upsert cfg;
    }

    // ── Search Accounts by name OR email (for wizard account picker) ────────
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> searchAccounts(String searchTerm) {
        List<Map<String, String>> results = new List<Map<String, String>>();
        if (String.isBlank(searchTerm) || searchTerm.trim().length() < 2) return results;
        String q = '%' + searchTerm.trim() + '%';
        // Donors can be people, churches or organizations (Household accounts are not donors)
        Set<String> orgTypes = new Set<String>{ 'Eglise', 'Org_Business_Account', 'Business_Account' };
        List<Account> accounts = [
            SELECT Id, Name, PersonEmail, BillingCity, IsPersonAccount, RecordType.Name
            FROM Account
            WHERE (Name LIKE :q OR PersonEmail LIKE :q)
            AND (IsPersonAccount = true OR RecordType.DeveloperName IN :orgTypes)
            ORDER BY Name
            LIMIT 15
        ];
        for (Account a : accounts) {
            String detail = String.isNotBlank(a.PersonEmail) ? a.PersonEmail
                          : (!a.IsPersonAccount && a.RecordType != null ? a.RecordType.Name : '');
            if (String.isNotBlank(a.BillingCity)) detail += (String.isNotBlank(detail) ? ' · ' : '') + a.BillingCity;
            results.add(new Map<String, String>{
                'id'     => a.Id,
                'name'   => a.Name,
                'detail' => detail
            });
        }
        return results;
    }

    // ── Search users and queues by name (for assignee picker) ────────────────
    // Empty/short search returns the first 10 active users + up to 5 queues.
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> searchOwners(String searchTerm) {
        List<Map<String, String>> results = new List<Map<String, String>>();
        Boolean hasFilter = String.isNotBlank(searchTerm) && searchTerm.trim().length() >= 2;
        String q = hasFilter ? '%' + searchTerm.trim() + '%' : null;

        List<User> users = hasFilter
            ? [SELECT Id, Name FROM User WHERE IsActive = true AND Name LIKE :q ORDER BY Name LIMIT 10]
            : [SELECT Id, Name FROM User WHERE IsActive = true ORDER BY Name LIMIT 10];

        List<Group> queues = hasFilter
            ? [SELECT Id, Name FROM Group WHERE Type = 'Queue' AND Name LIKE :q ORDER BY Name LIMIT 5]
            : [SELECT Id, Name FROM Group WHERE Type = 'Queue' ORDER BY Name LIMIT 5];

        for (User u : users) {
            results.add(new Map<String, String>{ 'id' => u.Id, 'name' => u.Name, 'type' => 'user' });
        }
        for (Group g : queues) {
            results.add(new Map<String, String>{ 'id' => g.Id, 'name' => g.Name, 'type' => 'queue' });
        }
        return results;
    }

    // ── Internal — full unmasked config for Apex use ──────────────────────────
    public static Zeffy_Config__c getConfig() {
        return Zeffy_Config__c.getOrgDefaults();
    }

        private static String maskKey(String key) {
        if (String.isBlank(key) || key.length() <= 8) return '****';
        return key.substring(0, 4) + '****' + key.substring(key.length() - 4);
    }

    // ── Send a signed test webhook to the Site endpoint ───────────────────────
    @AuraEnabled
    public static Map<String, Object> sendTestWebhook(String eventType) {
        // Creates real TEST tickets through the live endpoint: admins only
        requireSettingsAccess('Only Zeffy Connect administrators can send test webhooks.');
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        if (cfg == null || String.isBlank(cfg.Webhook_Secret__c)) {
            return new Map<String, Object>{ 'success' => false, 'message' => 'Webhook Secret not configured in Settings → Credentials.' };
        }
        if (String.isBlank(cfg.Webhook_Endpoint_Url__c)) {
            return new Map<String, Object>{ 'success' => false, 'message' => 'Webhook Endpoint URL not configured in Settings → Credentials.' };
        }

        String safeEvent = String.isNotBlank(eventType) ? eventType : 'payment.completed';
        Long   ts        = DateTime.now().getTime() / 1000;
        String txId      = 'TEST-' + String.valueOf(DateTime.now().getTime());

        String status = safeEvent == 'payment.deleted' ? 'deleted'
                      : safeEvent == 'payment.created'  ? 'pending' : 'succeeded';

        Long amountCents = 2500;
        String data =
            '{"id":"' + txId + '"'
          + ',"status":"' + status + '"'
          + ',"amount":' + amountCents
          + ',"eligible_amount":' + amountCents
          + ',"currency":"CAD"'
          + ',"created":' + ts
          + ',"campaign_id":null,"contact":null'
          + ',"receipt_url":"https://zeffy.com/receipt/' + txId + '"'
          + ',"refund_status":null,"dispute":null,"refunds":[]'
          + ',"payment_method":{"type":"card","brand":"visa","last4":"4242"}'
          + ',"recurring":{"is_recurring":false,"status":null,"interval":null,"subscription_id":null,"current_period_start":null,"current_period_end":null}'
          + ',"buyer":{"email":"john.doe@test-zeffy.com","first_name":"John","last_name":"Doe"'
          + ',"is_corporate":false,"company_name":null'
          + ',"address":{"line1":"123 rue des Tests","city":"Montréal","state":"QC","postal_code":"H2X 1Y3","country":"CA"}}'
          + ',"items":[{"id":"item-' + txId + '","type":"donation","amount":' + amountCents + ',"rate_title":"Test donation","contact_id":null,"questions":[],"tribute":null}]'
          + ',"buyer_questions":[],"fund":null,"discount":null,"occurrence_id":null}';

        String body = '{"type":"' + safeEvent + '","id":"evt-' + txId + '","version":1'
                    + ',"dispatchedAt":"' + DateTime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss') + 'Z"'
                    + ',"data":' + data + '}';

        // HMAC-SHA256: sign "timestamp.body"
        Blob   sigBlob    = Crypto.generateMac('HmacSHA256', Blob.valueOf(ts + '.' + body), Blob.valueOf(cfg.Webhook_Secret__c));
        String sigHex     = EncodingUtil.convertToHex(sigBlob);
        String sigHeader  = 't=' + ts + ',v1=' + sigHex;

        HttpRequest req = new HttpRequest();
        req.setEndpoint(cfg.Webhook_Endpoint_Url__c);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Zeffy-Signature', sigHeader);
        req.setBody(body);
        req.setTimeout(10000);

        try {
            HttpResponse resp = new Http().send(req);
            return new Map<String, Object>{
                'success' => resp.getStatusCode() == 200,
                'status'  => resp.getStatusCode(),
                'body'    => resp.getBody(),
                'txId'    => txId,
                'event'   => safeEvent
            };
        } catch (Exception e) {
            return new Map<String, Object>{ 'success' => false, 'message' => e.getMessage() };
        }
    }

    public static void requireSettingsAccess() {
        requireSettingsAccess('Only Zeffy Connect administrators can do this.');
    }

    private static void requireSettingsAccess(String message) {
        if (!FeatureManagement.checkPermission('Zeffy_Connect_Settings_Access')) {
            throw new AuraHandledException(message);
        }
    }
}
