/**
 * MergeWrappers.cls
 * All Data Transfer Objects (DTOs) for the Safe Merge Management System.
 * Kept in a single file to simplify LWC @AuraEnabled serialization.
 */
public without sharing class MergeWrappers {

    // ─── SCAN ─────────────────────────────────────────────────────────────────

    public class ScanRequest {
        @AuraEnabled public String       objectType;          // 'Contact' | 'Account' (kept for test/Apex compat)
        @AuraEnabled public String       mergeObjectType;     // LWC primary — avoids Aura framework name conflict
        @AuraEnabled public List<String> matchFields;         // ['Email','Phone','Name']
        @AuraEnabled public Integer      recordLimit;
        @AuraEnabled public Boolean      dryRun;              // preview without writing tickets
        @AuraEnabled public String       emailObjectApiName;  // null = default (Email_Address__c if exists)
    }

    public class ScanResult {
        @AuraEnabled public Boolean            success;
        @AuraEnabled public Integer            ticketsCreated;
        @AuraEnabled public Integer            duplicateGroupsFound;
        @AuraEnabled public Integer            recordsAnalyzed;
        @AuraEnabled public Integer            skippedExistingTickets;
        @AuraEnabled public List<TicketPreview> previews;
        @AuraEnabled public String             errorMessage;
        @AuraEnabled public Boolean            isAsync;     // true when launched as Batch Apex
        @AuraEnabled public String             batchJobId;  // AsyncApexJob.Id when isAsync=true

        public ScanResult() {
            previews               = new List<TicketPreview>();
            ticketsCreated         = 0;
            duplicateGroupsFound   = 0;
            recordsAnalyzed        = 0;
            skippedExistingTickets = 0;
            success                = true;
            isAsync                = false;
        }
    }

    public class TicketPreview {
        @AuraEnabled public String             ticketId;
        @AuraEnabled public String             matchKey;
        @AuraEnabled public String             matchType;      // Email|Phone|Name|Mixed
        @AuraEnabled public String             confidence;     // High|Medium|Low
        @AuraEnabled public Integer            candidateCount;
        @AuraEnabled public List<CandidateWrapper> candidates;
        @AuraEnabled public Boolean            alreadyHasTicket;

        public TicketPreview() {
            candidates       = new List<CandidateWrapper>();
            alreadyHasTicket = false;
        }
    }

    // ─── CANDIDATE ────────────────────────────────────────────────────────────

    public class CandidateWrapper {
        @AuraEnabled public String             recordId;
        @AuraEnabled public String             recordName;
        @AuraEnabled public Map<String,Object> fieldValues;
        @AuraEnabled public EDACountsWrapper   edaCounts;
        @AuraEnabled public Boolean            hasActiveEnrollments;
        @AuraEnabled public Boolean            isMaster;
        @AuraEnabled public Boolean            isLosingRecord;

        public CandidateWrapper() {
            fieldValues          = new Map<String,Object>();
            edaCounts            = new EDACountsWrapper();
            hasActiveEnrollments = false;
            isMaster             = false;
            isLosingRecord       = false;
        }
    }

    // ─── EDA COUNTS ───────────────────────────────────────────────────────────

    public class EDACountsWrapper {
        @AuraEnabled public Integer courseConnections;
        @AuraEnabled public Integer activeCourseConnections;
        @AuraEnabled public Integer programEnrollments;
        @AuraEnabled public Integer activeProgramEnrollments;
        @AuraEnabled public Integer affiliations;
        @AuraEnabled public Integer totalRelatedRecords;
        @AuraEnabled public Boolean hasActiveEnrollments;

        public EDACountsWrapper() {
            courseConnections       = 0;
            activeCourseConnections = 0;
            programEnrollments      = 0;
            activeProgramEnrollments= 0;
            affiliations            = 0;
            totalRelatedRecords     = 0;
            hasActiveEnrollments    = false;
        }

        public void computeDerived() {
            totalRelatedRecords  = courseConnections + programEnrollments + affiliations;
            hasActiveEnrollments = (activeCourseConnections > 0 || activeProgramEnrollments > 0);
        }
    }

    // ─── MERGE REQUEST / RESULT ───────────────────────────────────────────────

    public class MergeRequest {
        @AuraEnabled public String            ticketId;
        @AuraEnabled public String            masterId;
        @AuraEnabled public List<String>      losingIds;
        @AuraEnabled public Map<String,String> fieldDecisions; // fieldApiName -> sourceRecordId
        @AuraEnabled public String            notes;
    }

    public class MergeResult {
        @AuraEnabled public Boolean                  success;
        @AuraEnabled public String                   errorMessage;
        @AuraEnabled public String                   logId;
        @AuraEnabled public String                   mergedRecordId;
        @AuraEnabled public List<OrphanedAccountInfo> orphanedAccounts;
        @AuraEnabled public List<OrphanedContactInfo> orphanedContacts;

        public MergeResult() {
            success          = false;
            orphanedAccounts = new List<OrphanedAccountInfo>();
            orphanedContacts = new List<OrphanedContactInfo>();
        }
    }

    // ─── ORPHANED ACCOUNT (post Contact-merge) ────────────────────────────────

    public class OrphanedAccountInfo {
        @AuraEnabled public String  accountId;
        @AuraEnabled public String  accountName;
        @AuraEnabled public Integer affiliationCount;
        @AuraEnabled public Boolean isSafeToDelete;

        public OrphanedAccountInfo() {
            affiliationCount = 0;
            isSafeToDelete   = true;
        }
    }

    // ─── ORPHANED CONTACT (post Account-merge) ────────────────────────────────

    public class OrphanedContactInfo {
        @AuraEnabled public String contactId;
        @AuraEnabled public String contactName;
        @AuraEnabled public String email;
        @AuraEnabled public String phone;
    }

    public class DeletedContactInfo {
        @AuraEnabled public String contactId;
        @AuraEnabled public String contactName;
        @AuraEnabled public String deletedAt;
    }

    // ─── RELATED CONTACT (for Account comparison) ─────────────────────────────

    public class RelatedContactInfo {
        @AuraEnabled public String           contactId;
        @AuraEnabled public String           contactName;
        @AuraEnabled public EDACountsWrapper edaCounts;

        public RelatedContactInfo() {
            edaCounts = new EDACountsWrapper();
        }
    }

    // ─── COMPARISON MATRIX (Wizard Step 2) ────────────────────────────────────

    public class ComparisonRow {
        @AuraEnabled public String             fieldApiName;
        @AuraEnabled public String             fieldLabel;
        @AuraEnabled public String             fieldType;
        @AuraEnabled public Boolean            isEdaField;
        @AuraEnabled public Boolean            hasConflict;
        @AuraEnabled public Boolean            isUpdateable;
        @AuraEnabled public Map<String,String> valuesByRecordId; // recordId -> displayValue
        @AuraEnabled public String             selectedRecordId; // default = master

        public ComparisonRow() {
            valuesByRecordId = new Map<String,String>();
            hasConflict      = false;
            isEdaField       = false;
            isUpdateable     = true;
        }
    }

    public class DeletedAccountInfo {
        @AuraEnabled public String accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String deletedAt;
    }

    // ─── EMAIL OBJECT CANDIDATE (scan modal combobox) ─────────────────────────

    public class EmailObjectInfo {
        @AuraEnabled public String label;
        @AuraEnabled public String value; // API name
    }

    public class ComparisonMatrix {
        @AuraEnabled public List<String>                           recordIds;
        @AuraEnabled public List<String>                           recordNames;
        @AuraEnabled public List<ComparisonRow>                    rows;
        @AuraEnabled public Map<String,EDACountsWrapper>           edaCountsByRecordId;
        @AuraEnabled public String                                 objectType;
        @AuraEnabled public Map<String,List<RelatedContactInfo>>   relatedContactsByRecordId;
        @AuraEnabled public String                                 savedMasterId;    // Selected_Master_Id__c (Merged tickets)
        @AuraEnabled public List<String>                           missingRecordIds; // records deleted by the merge

        public ComparisonMatrix() {
            recordIds                 = new List<String>();
            recordNames               = new List<String>();
            rows                      = new List<ComparisonRow>();
            edaCountsByRecordId       = new Map<String,EDACountsWrapper>();
            relatedContactsByRecordId = new Map<String,List<RelatedContactInfo>>();
            missingRecordIds          = new List<String>();
        }
    }
}
