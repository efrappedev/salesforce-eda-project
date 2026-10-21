public class AdmissionsWrapper {

    public class ApplicationSummary {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  applicantId;
        @AuraEnabled public String  applicantName;
        @AuraEnabled public String  status;
        @AuraEnabled public String  applicationType;
        @AuraEnabled public String  programName;
        @AuraEnabled public Date    applicationDate;
        @AuraEnabled public Integer reviewCount;
        @AuraEnabled public Integer completedReviewCount;
        @AuraEnabled public Boolean hasDecision;
        @AuraEnabled public Integer documentCount;
        @AuraEnabled public Integer verifiedDocCount;
    }

    public class ApplicationDetail {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  applicantId;
        @AuraEnabled public String  applicantName;
        @AuraEnabled public String  status;
        @AuraEnabled public String  applicationType;
        @AuraEnabled public String  programId;
        @AuraEnabled public String  programName;
        @AuraEnabled public String  termId;
        @AuraEnabled public String  termName;
        @AuraEnabled public Date    applicationDate;
        @AuraEnabled public Date    dueDate;
        @AuraEnabled public Boolean interviewRequired;
        @AuraEnabled public Boolean financialAidRequested;
        @AuraEnabled public String  previousInstitution;
        @AuraEnabled public Decimal previousGpa;
        @AuraEnabled public String  comments;
        @AuraEnabled public List<ReviewDetail>   reviews;
        @AuraEnabled public DecisionDetail       decision;
        @AuraEnabled public List<DocumentDetail> documents;
    }

    public class ReviewDetail {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  reviewerId;
        @AuraEnabled public String  reviewerName;
        @AuraEnabled public String  status;
        @AuraEnabled public String  reviewType;
        @AuraEnabled public String  recommendation;
        @AuraEnabled public Decimal score;
        @AuraEnabled public Date    dueDate;
        @AuraEnabled public Date    completedDate;
        @AuraEnabled public String  comments;
        @AuraEnabled public Boolean isOverdue;
    }

    public class DecisionDetail {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  decision;
        @AuraEnabled public Date    decisionDate;
        @AuraEnabled public String  decisionMadeById;
        @AuraEnabled public String  decisionMadeByName;
        @AuraEnabled public String  conditions;
        @AuraEnabled public Decimal scholarshipAmount;
        @AuraEnabled public Date    responseDeadline;
        @AuraEnabled public String  notes;
    }

    public class DocumentDetail {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  documentType;
        @AuraEnabled public String  status;
        @AuraEnabled public Date    receivedDate;
        @AuraEnabled public String  verifiedById;
        @AuraEnabled public String  verifiedByName;
        @AuraEnabled public Boolean isRequired;
        @AuraEnabled public String  documentUrl;
        @AuraEnabled public String  repository;
        @AuraEnabled public String  notes;
    }

    public class ReviewInput {
        @AuraEnabled public String applicationId;
        @AuraEnabled public String reviewerId;
        @AuraEnabled public String reviewType;
        @AuraEnabled public Date   dueDate;
    }

    public class ReviewSubmission {
        @AuraEnabled public String  reviewId;
        @AuraEnabled public String  recommendation;
        @AuraEnabled public Decimal score;
        @AuraEnabled public String  comments;
    }

    public class DecisionInput {
        @AuraEnabled public String  applicationId;
        @AuraEnabled public String  decision;
        @AuraEnabled public Date    decisionDate;
        @AuraEnabled public String  conditions;
        @AuraEnabled public Decimal scholarshipAmount;
        @AuraEnabled public Date    responseDeadline;
        @AuraEnabled public String  notes;
    }

    public class DocumentInput {
        @AuraEnabled public String  applicationId;
        @AuraEnabled public String  documentName;
        @AuraEnabled public String  documentType;
        @AuraEnabled public String  documentUrl;
        @AuraEnabled public String  repository;
        @AuraEnabled public Boolean isRequired;
        @AuraEnabled public String  notes;
    }
}
