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
        @AuraEnabled public RelatedCountsWrapper relatedCounts;
        @AuraEnabled public Boolean            hasActiveEnrollments;
        @AuraEnabled public Boolean            isMaster;
        @AuraEnabled public Boolean            isLosingRecord;

        public CandidateWrapper() {
            fieldValues          = new Map<String,Object>();
            relatedCounts        = new RelatedCountsWrapper();
            hasActiveEnrollments = false;
            isMaster             = false;
            isLosingRecord       = false;
        }
    }

    // ─── RELATED COUNTS (generic — auto-detected per installed packages) ─────────

    public class RelatedCount {
        @AuraEnabled public String  label;
        @AuraEnabled public Integer total;
        @AuraEnabled public Integer active;
        @AuraEnabled public Boolean hasActive;

        public RelatedCount(String label) {
            this.label    = label;
            this.total    = 0;
            this.active   = 0;
            this.hasActive = false;
        }
    }

    public class RelatedCountsWrapper {
        @AuraEnabled public List<RelatedCount> counts;
        @AuraEnabled public Integer            totalRelated;
        @AuraEnabled public Boolean            hasActiveRecords;

        public RelatedCountsWrapper() {
            counts          = new List<RelatedCount>();
            totalRelated    = 0;
            hasActiveRecords = false;
        }

        public void computeDerived() {
            totalRelated     = 0;
            hasActiveRecords = false;
            for (RelatedCount rc : counts) {
                rc.hasActive     = rc.active > 0;
                totalRelated    += rc.total;
                if (rc.active > 0) hasActiveRecords = true;
            }
        }

        public RelatedCount getByLabel(String label) {
            for (RelatedCount rc : counts) {
                if (rc.label == label) return rc;
            }
            return new RelatedCount(label);
        }
    }

    // ─── RELATED RECORDS COMPARISON (Step 2 wizard) ───────────────────────────

    public class RelatedObjectComparison {
        @AuraEnabled public String                  apiName;
        @AuraEnabled public String                  label;
        @AuraEnabled public String                  lookupField;
        @AuraEnabled public List<RelatedRecordInfo> masterRecords;
        @AuraEnabled public List<RelatedRecordInfo> loserRecords;

        public RelatedObjectComparison() {
            masterRecords = new List<RelatedRecordInfo>();
            loserRecords  = new List<RelatedRecordInfo>();
        }
    }

    public class RelatedRecordInfo {
        @AuraEnabled public String  recordId;
        @AuraEnabled public String  recordName;
        @AuraEnabled public String  ownerCandidateId;
        @AuraEnabled public Boolean hasConflict;

        public RelatedRecordInfo() { hasConflict = false; }
    }

    // ─── MERGE REQUEST / RESULT ───────────────────────────────────────────────

    public class MergeRequest {
        @AuraEnabled public String            ticketId;
        @AuraEnabled public String            masterId;
        @AuraEnabled public List<String>      losingIds;
        @AuraEnabled public Map<String,String> fieldDecisions; // fieldApiName -> sourceRecordId
        @AuraEnabled public String            notes;
        @AuraEnabled public String            relatedDeletesJson; // JSON: {objectApiName: [recordIds]}
    }

    public class MergeResult {
        @AuraEnabled public Boolean                  success;
        @AuraEnabled public String                   errorMessage;
        @AuraEnabled public String                   logId;
        @AuraEnabled public String                   mergedRecordId;
        @AuraEnabled public List<OrphanedAccountInfo> orphanedAccounts;
        @AuraEnabled public List<OrphanedContactInfo> orphanedContacts;
        @AuraEnabled public Integer                  cleanedUpTicketCount;

        public MergeResult() {
            success              = false;
            orphanedAccounts     = new List<OrphanedAccountInfo>();
            orphanedContacts     = new List<OrphanedContactInfo>();
            cleanedUpTicketCount = 0;
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
        @AuraEnabled public String               contactId;
        @AuraEnabled public String               contactName;
        @AuraEnabled public RelatedCountsWrapper relatedCounts;

        public RelatedContactInfo() {
            relatedCounts = new RelatedCountsWrapper();
        }
    }

    // ─── RELATED ACCOUNT (for Contact comparison) ─────────────────────────────

    public class RelatedAccountInfo {
        @AuraEnabled public String               accountId;
        @AuraEnabled public String               accountName;
        @AuraEnabled public RelatedCountsWrapper relatedCounts;

        public RelatedAccountInfo() {
            relatedCounts = new RelatedCountsWrapper();
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

    // ─── SNAPSHOT VIEW (merged loser records — eye icon on "Fusionné" cards) ──

    public class SnapshotViewWrapper {
        @AuraEnabled public String             recordId;
        @AuraEnabled public String             recordName;
        @AuraEnabled public String             capturedAt;
        @AuraEnabled public String             objectType;
        @AuraEnabled public List<SnapshotField> fields;

        public SnapshotViewWrapper() {
            fields = new List<SnapshotField>();
        }
    }

    public class SnapshotField {
        @AuraEnabled public String label;
        @AuraEnabled public String apiName;
        @AuraEnabled public String value;
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
        @AuraEnabled public Map<String,RelatedCountsWrapper>        relatedCountsByRecordId;
        @AuraEnabled public String                                 objectType;
        @AuraEnabled public Map<String,List<RelatedContactInfo>>   relatedContactsByRecordId;
        @AuraEnabled public Map<String,RelatedAccountInfo>         relatedAccountByRecordId;
        @AuraEnabled public String                                 savedMasterId;    // Selected_Master_Id__c (Merged tickets)
        @AuraEnabled public List<String>                           missingRecordIds; // records deleted by the merge
        @AuraEnabled public String                                 ticketStatus;
        @AuraEnabled public String                                 ticketClosedReason;
        @AuraEnabled public String                                 ticketNotes;
        @AuraEnabled public String                                 mergePerformedBy;
        @AuraEnabled public String                                 mergePerformedDate;
        @AuraEnabled public String                                 mergeMasterName;
        @AuraEnabled public String                                 mergeLoserNames;
        @AuraEnabled public String                                 ticketErrorMessage;

        public ComparisonMatrix() {
            recordIds                 = new List<String>();
            recordNames               = new List<String>();
            rows                      = new List<ComparisonRow>();
            relatedCountsByRecordId    = new Map<String,RelatedCountsWrapper>();
            relatedContactsByRecordId = new Map<String,List<RelatedContactInfo>>();
            relatedAccountByRecordId  = new Map<String,RelatedAccountInfo>();
            missingRecordIds          = new List<String>();
        }
    }
}
