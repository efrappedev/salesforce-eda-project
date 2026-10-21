public with sharing class ZeffyConnectFundService {

    // ─── Wrappers ─────────────────────────────────────────────────────────────

    public class FundRow {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  description;
        @AuraEnabled public Boolean isActive;
        @AuraEnabled public List<CampaignRow> campaigns;
        public FundRow() { this.campaigns = new List<CampaignRow>(); }
    }

    public class CampaignRow {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String formId;
        @AuraEnabled public String fundId;
        @AuraEnabled public String fundName;
    }

    // ─── Read ─────────────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static List<FundRow> getFundsWithCampaigns() {
        List<Zeffy_Fund__c> funds = [
            SELECT Id, Name, Description__c, Is_Active__c
            FROM Zeffy_Fund__c
            WHERE Is_Active__c = true
            ORDER BY Name
        ];
        List<Campaign> campaigns = [
            SELECT Id, Name, Zeffy_Form_Id__c, Zeffy_Fund__c, Zeffy_Fund__r.Name
            FROM Campaign
            WHERE Is_Zeffy_Managed__c = true
            ORDER BY Name
        ];

        Map<Id, FundRow> fundMap = new Map<Id, FundRow>();
        List<FundRow> result = new List<FundRow>();

        FundRow unassigned = new FundRow();
        unassigned.id = null;
        unassigned.name = null;
        result.add(unassigned);

        for (Zeffy_Fund__c f : funds) {
            FundRow fr = new FundRow();
            fr.id = f.Id;
            fr.name = f.Name;
            fr.description = f.Description__c;
            fr.isActive = f.Is_Active__c;
            fundMap.put(f.Id, fr);
            result.add(fr);
        }

        for (Campaign c : campaigns) {
            CampaignRow cr = new CampaignRow();
            cr.id     = c.Id;
            cr.name   = c.Name;
            cr.formId = c.Zeffy_Form_Id__c;
            cr.fundId   = c.Zeffy_Fund__c;
            cr.fundName = c.Zeffy_Fund__r != null ? c.Zeffy_Fund__r.Name : null;
            if (c.Zeffy_Fund__c != null && fundMap.containsKey(c.Zeffy_Fund__c)) {
                fundMap.get(c.Zeffy_Fund__c).campaigns.add(cr);
            } else {
                unassigned.campaigns.add(cr);
            }
        }

        return result;
    }

    @AuraEnabled(cacheable=false)
    public static List<Map<String, String>> getActiveFunds() {
        List<Map<String, String>> opts = new List<Map<String, String>>();
        for (Zeffy_Fund__c f : [SELECT Id, Name FROM Zeffy_Fund__c WHERE Is_Active__c = true ORDER BY Name]) {
            opts.add(new Map<String, String>{ 'value' => f.Id, 'label' => f.Name });
        }
        return opts;
    }

    // ─── Write ────────────────────────────────────────────────────────────────

    @AuraEnabled
    public static String createFund(String name, String description) {
        Zeffy_Fund__c f = new Zeffy_Fund__c(
            Name           = name,
            Description__c = description,
            Is_Active__c   = true
        );
        insert f;
        return f.Id;
    }

    @AuraEnabled
    public static void assignCampaignToFund(Id campaignId, Id fundId) {
        update new Campaign(Id = campaignId, Zeffy_Fund__c = fundId);
        ZeffyConnectDonationService.logAction(null, 'Campaign Fund Changed', null,
            'Campaign ' + campaignId + ' → fund ' + (fundId == null ? '(none)' : String.valueOf(fundId)));
    }

    // Changes the ticket's fund and, when the ticket is already resolved, keeps the
    // linked GiftTransaction's fund in sync so reports never disagree with the ticket.
    @AuraEnabled
    public static void updateTicketFund(Id ticketId, Id fundId) {
        List<Zeffy_Review_Ticket__c> rows = [
            SELECT Id, Fund__c, Resolved_Gift__c, Resolved_Account__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1
        ];
        Id prevFund = rows.isEmpty() ? null : rows[0].Fund__c;
        update new Zeffy_Review_Ticket__c(Id = ticketId, Fund__c = fundId);
        String notes = 'Fund ' + (prevFund == null ? '(none)' : String.valueOf(prevFund))
                     + ' → ' + (fundId == null ? '(none)' : String.valueOf(fundId));
        if (!rows.isEmpty() && rows[0].Resolved_Gift__c != null) {
            update new GiftTransaction(Id = rows[0].Resolved_Gift__c, Zeffy_Fund__c = fundId);
            notes += ' (also applied to the linked gift)';
        }
        ZeffyConnectDonationService.logAction(ticketId, 'Fund Changed',
            rows.isEmpty() ? null : rows[0].Resolved_Account__c, notes);
    }

    // ─── Called internally by DonationService ────────────────────────────────

    public static Id resolveFundFromCampaign(Id campaignId) {
        if (campaignId == null) return null;
        List<Campaign> camps = [SELECT Zeffy_Fund__c FROM Campaign WHERE Id = :campaignId LIMIT 1];
        return camps.isEmpty() ? null : camps[0].Zeffy_Fund__c;
    }
}
