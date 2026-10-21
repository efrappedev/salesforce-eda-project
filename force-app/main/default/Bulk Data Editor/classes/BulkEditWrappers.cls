public with sharing class BulkEditWrappers {

    public class ObjectOption {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;

        public ObjectOption(String apiName, String label) {
            this.apiName = apiName;
            this.label = label;
        }
    }

    public class FieldOption {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public String dataType;

        public FieldOption(String apiName, String label, String dataType) {
            this.apiName = apiName;
            this.label = label;
            this.dataType = dataType;
        }
    }

    public class ValueBucket {
        @AuraEnabled public String rawValue;
        @AuraEnabled public String displayValue;
        @AuraEnabled public Boolean isBlank;
        @AuraEnabled public Integer recordCount;

        public ValueBucket(String rawValue, String displayValue, Boolean isBlank, Integer recordCount) {
            this.rawValue = rawValue;
            this.displayValue = displayValue;
            this.isBlank = isBlank;
            this.recordCount = recordCount;
        }
    }

    public class ValueDistributionResult {
        @AuraEnabled public String fieldDataType;
        @AuraEnabled public Boolean isPicklist;
        @AuraEnabled public Integer totalRecords;
        @AuraEnabled public List<ValueBucket> buckets;
        @AuraEnabled public Boolean truncated;

        public ValueDistributionResult() {
            this.buckets = new List<ValueBucket>();
            this.totalRecords = 0;
            this.truncated = false;
        }
    }

    public class BulkEditJobResult {
        @AuraEnabled public Id logId;
        @AuraEnabled public Id batchJobId;

        public BulkEditJobResult(Id logId, Id batchJobId) {
            this.logId = logId;
            this.batchJobId = batchJobId;
        }
    }

    public class JobStatusResult {
        @AuraEnabled public Id logId;
        @AuraEnabled public String status;
        @AuraEnabled public Integer recordsAffected;
        @AuraEnabled public Integer totalRecords;
        @AuraEnabled public Integer processedRecords;
        @AuraEnabled public Integer numberOfErrors;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public Boolean canUndo;
        @AuraEnabled public Boolean isDone;
        @AuraEnabled public Id batchJobId;
    }

    public class RecordTypeOption {
        @AuraEnabled public Id recordTypeId;
        @AuraEnabled public String label;

        public RecordTypeOption(Id recordTypeId, String label) {
            this.recordTypeId = recordTypeId;
            this.label = label;
        }
    }

    public class RecordSearchResult {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Id recordTypeId;
        @AuraEnabled public String recordTypeLabel;

        public RecordSearchResult(Id id, String name, Id recordTypeId, String recordTypeLabel) {
            this.id = id;
            this.name = name;
            this.recordTypeId = recordTypeId;
            this.recordTypeLabel = recordTypeLabel;
        }
    }

    public class MatchResult {
        @AuraEnabled public String searchValue;
        @AuraEnabled public Id recordId;
        @AuraEnabled public String recordDisplay;
        @AuraEnabled public String status;
        @AuraEnabled public String currentValue;

        public MatchResult(String searchValue, Id recordId, String recordDisplay, String status, String currentValue) {
            this.searchValue = searchValue;
            this.recordId = recordId;
            this.recordDisplay = recordDisplay;
            this.status = status;
            this.currentValue = currentValue;
        }
    }

    public class EditHistoryEntry {
        @AuraEnabled public Id logId;
        @AuraEnabled public String name;
        @AuraEnabled public String objectLabel;
        @AuraEnabled public String fieldLabel;
        @AuraEnabled public String oldValueDisplay;
        @AuraEnabled public String newValue;
        @AuraEnabled public Integer recordsAffected;
        @AuraEnabled public String status;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public Boolean canUndo;
        @AuraEnabled public String filterFieldLabel;
        @AuraEnabled public String filterValueDisplay;
    }

    public class CleanPreviewRow {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String recordDisplay;
        @AuraEnabled public String beforeValue;
        @AuraEnabled public String afterValue;
        @AuraEnabled public Boolean willChange;

        public CleanPreviewRow(Id recordId, String recordDisplay, String beforeValue, String afterValue, Boolean willChange) {
            this.recordId = recordId;
            this.recordDisplay = recordDisplay;
            this.beforeValue = beforeValue;
            this.afterValue = afterValue;
            this.willChange = willChange;
        }
    }

    public class CleanPreviewResult {
        @AuraEnabled public Integer totalMatching;
        @AuraEnabled public Integer sampleSize;
        @AuraEnabled public Integer sampleWouldChange;
        @AuraEnabled public List<CleanPreviewRow> rows;

        public CleanPreviewResult() {
            this.totalMatching = 0;
            this.sampleSize = 0;
            this.sampleWouldChange = 0;
            this.rows = new List<CleanPreviewRow>();
        }
    }
}
