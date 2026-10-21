public with sharing class ZeffyConfigService {

    @AuraEnabled(cacheable=true)
    public static Map<String, String> loadConfig() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getInstance();
        Boolean configured = cfg != null && String.isNotBlank(cfg.Webhook_Secret__c);
        return new Map<String, String>{
            'apiKey'         => cfg != null && String.isNotBlank(cfg.API_Key__c)
                                    ? maskKey(cfg.API_Key__c) : '',
            'webhookSecret'  => configured ? maskKey(cfg.Webhook_Secret__c) : '',
            'isActive'       => String.valueOf(cfg != null ? cfg.Is_Active__c : true),
            'isConfigured'   => String.valueOf(configured)
        };
    }

    @AuraEnabled
    public static void saveConfig(String apiKey, String webhookSecret, Boolean isActive) {
        Zeffy_Config__c cfg = Zeffy_Config__c.getInstance();
        if (cfg == null) {
            cfg = new Zeffy_Config__c(SetupOwnerId = UserInfo.getOrganizationId());
        }
        // Only update if user typed a real value (not the masked placeholder)
        if (String.isNotBlank(apiKey) && !apiKey.contains('****')) {
            cfg.API_Key__c = apiKey;
        }
        if (String.isNotBlank(webhookSecret) && !webhookSecret.contains('****')) {
            cfg.Webhook_Secret__c = webhookSecret;
        }
        cfg.Is_Active__c = isActive != null ? isActive : true;
        upsert cfg;
    }

    // Internal — returns full unmasked config for use in Apex (not exposed to LWC)
    public static Zeffy_Config__c getConfig() {
        return Zeffy_Config__c.getInstance();
    }

    private static String maskKey(String key) {
        if (String.isBlank(key) || key.length() <= 8) return '****';
        return key.substring(0, 4) + '****' + key.substring(key.length() - 4);
    }
}
