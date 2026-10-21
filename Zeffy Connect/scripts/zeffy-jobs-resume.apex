// Re-schedules Zeffy Connect jobs exactly as the Settings toggles say.
Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
if (cfg != null && cfg.Holding_Auto_Expire_Enabled__c == true) ZeffyHoldingExpireBatch.schedule();
if (cfg != null && cfg.Lapsed_Alert_Enabled__c == true)        ZeffyConnectLapsedDonorBatch.schedule(cfg);
System.debug('ZEFFY_JOBS_RESUMED holding=' + (cfg != null && cfg.Holding_Auto_Expire_Enabled__c == true)
             + ' lapsed=' + (cfg != null && cfg.Lapsed_Alert_Enabled__c == true));
