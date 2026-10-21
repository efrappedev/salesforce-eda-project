/**
 * DataUpdateMultiTicketReviewController.cls
 * Grouped review: staff with the Data_Update_Multi_Ticket_Review custom permission (PS "Data Update Center
 * – Multi-Ticket Review") review every open ticket of one record together — only tickets of forms with
 * "Multiple submissions" on (Allow_Duplicate_Open_Requests__c, e.g. Église Update). The review screen
 * (dataUpdateMultiTicketReview) loads each ticket with DataUpdateReviewController.getComparisonData,
 * lets staff decide line by line, then applies ticket by ticket here — one transaction per
 * ticket, so each ticket keeps its own APPLY_COMPLETED log and rollback, and a big group never
 * hits one transaction's limits.
 */
public with sharing class DataUpdateMultiTicketReviewController {

    @TestVisible private static Boolean bypassPermissionForTest = false;

    public class MultiTicketReviewException extends Exception {}

    private static void requireMultiTicketReview() {
        if (!bypassPermissionForTest
                && !FeatureManagement.checkPermission(DataUpdateReviewController.MULTI_TICKET_REVIEW_PERMISSION)) {
            throw new AuraHandledException('NO_PERMISSION');
        }
    }

    /** Open tickets of the record from "multiple submissions" forms (newest first), its name and its email/phone fields. */
    @AuraEnabled
    public static DataUpdateWrapper.GroupContext getGroupContext(String targetRecordId) {
        requireMultiTicketReview();
        DataUpdateWrapper.GroupContext ctx = new DataUpdateWrapper.GroupContext();
        try {
            Id recId = Id.valueOf(targetRecordId);
            ctx.targetRecordId = recId;
            Set<String> ids = new Set<String>{ String.valueOf(recId), String.valueOf(recId).left(15) };
            Set<String> multiForms = DataUpdateReviewController.getMultiSubmissionForms();
            for (Data_Update_Request__c t : [
                SELECT Id, Name, Status__c, Update_Form_DeveloperName__c, Update_Form_Label__c, CreatedDate
                FROM Data_Update_Request__c
                WHERE Target_Record_Id__c IN :ids AND Status__c NOT IN ('Applied', 'Ignored', 'Closed')
                  AND Update_Form_DeveloperName__c IN :multiForms
                ORDER BY CreatedDate DESC, Name DESC
            ]) {
                DataUpdateWrapper.GroupTicket gt = new DataUpdateWrapper.GroupTicket();
                gt.id                = t.Id;
                gt.requestNumber     = t.Name;
                gt.status            = t.Status__c;
                gt.formDeveloperName = t.Update_Form_DeveloperName__c;
                gt.formLabel         = t.Update_Form_Label__c;
                gt.createdDate       = t.CreatedDate;
                ctx.tickets.add(gt);
            }

            Schema.DescribeSObjectResult d = recId.getSObjectType().getDescribe();
            Map<String, Schema.SObjectField> fieldMap = d.fields.getMap();
            // EDA contact: Email / Phone are saved in the preferred field, never offered as a place themselves.
            ctx.emailSavedIn = DataUpdateReviewController.emailSavedIn(d.getName(), recId, fieldMap);
            ctx.phoneSavedIn = DataUpdateReviewController.phoneSavedIn(d.getName(), recId, fieldMap);
            ctx.slotGroups.addAll(DataUpdateReviewController.buildSaveOptions(recId, fieldMap, ctx.emailSavedIn));
            ctx.recordName = String.valueOf(recId);
            if (fieldMap.containsKey('name')) {
                ctx.recordName = (String) Database.query('SELECT Name FROM ' + d.getName() + ' WHERE Id = :recId LIMIT 1')[0].get('Name');
            }
            ctx.success = true;
        } catch (Exception e) {
            ctx.success      = false;
            ctx.errorMessage = 'GENERIC_ERROR';
        }
        return ctx;
    }

    /**
     * Applies one ticket of a group. planJson:
     * {"fields":[form field...], "overrides":{"FormField":"OtherField"}, "tables":{"X#table":[idx]},
     *  "notApplied":[{labelFr,labelEn,value,reason,ticket}], "groupOthers":N, "recordName":"..."}
     * An empty plan closes the ticket as Applied with nothing changed (still logged, with reasons).
     */
    @AuraEnabled
    public static DataUpdateWrapper.ApplyResult applyGroupTicket(Id requestId, String planJson) {
        requireMultiTicketReview();
        Map<String, Object> plan;
        try {
            plan = String.isBlank(planJson) ? new Map<String, Object>()
                : (Map<String, Object>) JSON.deserializeUntyped(planJson);
        } catch (Exception e) {
            DataUpdateWrapper.ApplyResult bad = new DataUpdateWrapper.ApplyResult();
            bad.success      = false;
            bad.errorMessage = 'GENERIC_ERROR';
            return bad;
        }

        List<String> fields = new List<String>();
        if (plan.get('fields') instanceof List<Object>) {
            for (Object o : (List<Object>) plan.get('fields')) {
                if (o != null) fields.add(String.valueOf(o));
            }
        }
        Map<String, String> overrides = DataUpdateReviewController.stringMap(plan.get('overrides'));
        String tablesJson = plan.get('tables') instanceof Map<String, Object>
            ? JSON.serialize(plan.get('tables')) : null;

        Map<String, Object> notes = new Map<String, Object>();
        Integer others = plan.get('groupOthers') instanceof Integer ? (Integer) plan.get('groupOthers') : 0;
        if (others > 0) {
            notes.put('__group', new Map<String, Object>{
                'count'      => others,
                'recordName' => plan.get('recordName') == null ? '' : String.valueOf(plan.get('recordName'))
            });
        }
        if (plan.get('notApplied') instanceof List<Object> && !((List<Object>) plan.get('notApplied')).isEmpty()) {
            notes.put('__notApplied', plan.get('notApplied'));
        }
        return DataUpdateReviewController.applyCore(requestId, fields, tablesJson, overrides, notes);
    }
}
