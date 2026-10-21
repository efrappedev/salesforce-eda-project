public with sharing class DmcConfigService {

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
                                          ? orgCfg.Lapsed_Schedule_Frequency__c : 'WEEKLY'
        };
    }

    // ── Save credentials (admin only) ─────────────────────────────────────────
    @AuraEnabled
    public static void saveConfig(String apiKey, String webhookSecret, Boolean isActive) {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        if (cfg == null) {
            cfg = new Zeffy_Config__c(SetupOwnerId = UserInfo.getOrganizationId());
        }
        if (String.isNotBlank(apiKey) && !apiKey.contains('****')) {
            cfg.API_Key__c = apiKey;
        }
        if (String.isNotBlank(webhookSecret) && !webhookSecret.contains('****')) {
            cfg.Webhook_Secret__c = webhookSecret;
        }
        cfg.Is_Active__c = isActive != null ? isActive : true;
        upsert cfg;
    }

    // ── Save language preference for the current user ─────────────────────────
    @AuraEnabled
    public static void saveLanguage(String language) {
        if (String.isBlank(language)) return;
        Zeffy_Config__c cfg = Zeffy_Config__c.getInstance(UserInfo.getUserId());
        if (cfg == null) {
            cfg = new Zeffy_Config__c(SetupOwnerId = UserInfo.getUserId());
        }
        cfg.Language__c = language;
        upsert cfg;
    }

    // ── Save app-level settings (task automation + lapsed donor) ─────────────
    @AuraEnabled
    public static void saveAppSettings(
        Boolean autoTaskEnabled, Integer taskDueDays, String taskOwnerId, String taskOwnerName,
        Boolean lapsedEnabled, Integer lapsedDays, String lapsedOwnerId, String lapsedOwnerName,
        String lapsedScheduleDay, String lapsedScheduleFrequency
    ) {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        if (cfg == null) {
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
            DmcLapsedDonorBatch.schedule(cfg);
        } else {
            DmcLapsedDonorBatch.unschedule();
        }

        upsert cfg;
    }

    // ── Search Accounts by name OR email (for wizard account picker) ────────
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> searchAccounts(String searchTerm) {
        List<Map<String, String>> results = new List<Map<String, String>>();
        if (String.isBlank(searchTerm) || searchTerm.trim().length() < 2) return results;
        String q = '%' + searchTerm.trim() + '%';
        List<Account> accounts = [
            SELECT Id, Name, PersonEmail, BillingCity
            FROM Account
            WHERE (Name LIKE :q OR PersonEmail LIKE :q)
            AND IsPersonAccount = true
            ORDER BY Name
            LIMIT 15
        ];
        for (Account a : accounts) {
            String detail = String.isNotBlank(a.PersonEmail) ? a.PersonEmail : '';
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
}
