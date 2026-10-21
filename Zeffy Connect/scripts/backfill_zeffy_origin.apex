// Fills Zeffy_Origin__c on existing tickets (from their Zeffy payload) and on their linked gifts.
// Safe to re-run: only touches records whose origin is still empty.
List<Zeffy_Review_Ticket__c> tix = new List<Zeffy_Review_Ticket__c>();
List<GiftTransaction> gifts = new List<GiftTransaction>();
for (Zeffy_Review_Ticket__c t : [SELECT Id, Raw_Payload__c, Resolved_Gift__c, Resolved_Gift__r.Zeffy_Origin__c
                                 FROM Zeffy_Review_Ticket__c WHERE Zeffy_Origin__c = null LIMIT 5000]) {
    if (String.isBlank(t.Raw_Payload__c)) continue;
    String origin;
    try {
        Map<String,Object> root = (Map<String,Object>) JSON.deserializeUntyped(t.Raw_Payload__c);
        Map<String,Object> data = root.containsKey('data') ? (Map<String,Object>) root.get('data') : root;
        String raw = (String) data.get('type');
        if (raw == 'online') origin = 'Online';
        else if (raw == 'manual') origin = 'Manual';
        else if (raw == 'imported') origin = 'Imported';
    } catch (Exception e) { continue; }
    if (origin == null) continue;
    tix.add(new Zeffy_Review_Ticket__c(Id = t.Id, Zeffy_Origin__c = origin));
    if (t.Resolved_Gift__c != null && t.Resolved_Gift__r.Zeffy_Origin__c == null)
        gifts.add(new GiftTransaction(Id = t.Resolved_Gift__c, Zeffy_Origin__c = origin));
}
update tix;
update gifts;
System.debug('BACKFILL tickets=' + tix.size() + ' gifts=' + gifts.size());
