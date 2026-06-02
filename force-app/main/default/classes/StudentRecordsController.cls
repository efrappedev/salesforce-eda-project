public with sharing class StudentRecordsController {

    public class Course {
        @AuraEnabled public String Name;
        @AuraEnabled public String Code;
        @AuraEnabled public Decimal Credits;
        @AuraEnabled public String Note;
        @AuraEnabled public String Terms;
        @AuraEnabled public String Remarque;
    }

    public class Program {
        @AuraEnabled public String Name;
        @AuraEnabled public String AdmissionDate;
        @AuraEnabled public String ClassStanding;
        @AuraEnabled public Decimal TotalCredits;
        @AuraEnabled public List<Course> Courses;

        @AuraEnabled public String StartYear;
        @AuraEnabled public String EndYear;
        @AuraEnabled public String Status;
    }

    public class StudentPdfData {
        @AuraEnabled public String Name;
        @AuraEnabled public String Birthdate;
        @AuraEnabled public String Address;
        @AuraEnabled public String EmissionDate;
        @AuraEnabled public String StudentCode;
        @AuraEnabled public String ID_Contact; // <--- PREPARED FOR FUTURE USE
        @AuraEnabled public List<Program> Programs;
        @AuraEnabled public List<Course> HorsProgram;
        @AuraEnabled public Decimal TotalCreditsHorsProgram;
    }

    public static StudentPdfData getStudentPdfData(Id contactId) {
        Contact student = [
            SELECT Name, Birthdate, MailingStreet, MailingCity, MailingState, MailingPostalCode, Old_id__c, ID_Contact__c
            FROM Contact
            WHERE Id = :contactId
            LIMIT 1
        ];

        List<hed__Program_Enrollment__c> enrollments = [
            SELECT Id, hed__Account__r.Name, hed__Admission_Date__c, hed__Class_Standing__c,
                   hed__Start_Date__c, hed__End_Date__c, Status__c
            FROM hed__Program_Enrollment__c
            WHERE hed__Contact__c = :contactId
        ];

        StudentPdfData result = new StudentPdfData();
        result.Name = student.Name;
        result.Birthdate = student.Birthdate != null ? String.valueOf(student.Birthdate) : '';
        result.Address = student.MailingStreet + ', ' + student.MailingCity + ', ' + student.MailingState + ', ' + student.MailingPostalCode;
        result.EmissionDate = String.valueOf(Date.today());
        result.StudentCode = student.Old_id__c;
        result.ID_Contact = student.ID_Contact__c; // <--- READY FOR FUTURE USE
        result.Programs = new List<Program>();
        result.HorsProgram = new List<Course>();
        result.TotalCreditsHorsProgram = 0;

        Map<Id, Program> programMap = new Map<Id, Program>();

        for (hed__Program_Enrollment__c pe : enrollments) {
            Program p = new Program();
            p.Name = pe.hed__Account__r.Name;
            p.AdmissionDate = pe.hed__Admission_Date__c != null ? String.valueOf(pe.hed__Admission_Date__c) : '';
            p.ClassStanding = pe.hed__Class_Standing__c;
            p.Courses = new List<Course>();
            p.TotalCredits = 0;

            p.Status = pe.Status__c;
            p.StartYear = pe.hed__Start_Date__c != null ? String.valueOf(pe.hed__Start_Date__c.year()) : '';
            p.EndYear = (pe.hed__End_Date__c != null) ? String.valueOf(pe.hed__End_Date__c.year()) : '';

            programMap.put(pe.Id, p);
        }

        List<hed__Course_Enrollment__c> allCourses = [
            SELECT Course_ID__c, Course_Name__c, hed__Credits_Earned__c, Notations__c,
                Terms__c, hed__Program_Enrollment__c, hed__Grade__c, RecordType.DeveloperName
            FROM hed__Course_Enrollment__c
            WHERE hed__Contact__c = :student.Id
            AND (hed__Primary__c = false OR hed__Primary__c = null)
            AND (RecordType.DeveloperName = 'Student' OR RecordTypeId = null)
            ORDER BY Terms__c
        ];

        for (hed__Course_Enrollment__c c : allCourses) {
            Course cm = new Course();
            cm.Name = c.Course_Name__c;
            cm.Code = c.Course_ID__c;
            cm.Credits = c.hed__Credits_Earned__c;
            cm.Terms = c.Terms__c;
            cm.Note = c.hed__Grade__c != null ? String.valueOf(Math.round(c.hed__Grade__c)) : '-';
            cm.Remarque = c.Notations__c;

            Boolean isValidCredit = c.Notations__c != null &&
        (
            c.Notations__c.contains('R') ||
            c.Notations__c.contains('EQV') ||
            c.Notations__c.contains('TRANSF')
        );

            if (programMap.containsKey(c.hed__Program_Enrollment__c)) {
                programMap.get(c.hed__Program_Enrollment__c).Courses.add(cm);
                if (isValidCredit && c.hed__Credits_Earned__c != null) {
                    programMap.get(c.hed__Program_Enrollment__c).TotalCredits += c.hed__Credits_Earned__c;
                }
            } else {
                result.HorsProgram.add(cm);
                if (isValidCredit && c.hed__Credits_Earned__c != null) {
                    result.TotalCreditsHorsProgram += c.hed__Credits_Earned__c;
                }
            }
        }

        result.Programs.addAll(programMap.values());
        return result;
    }

    @RemoteAction
    public static StudentPdfData fetchStudentPdfData(String contactId) {
        return getStudentPdfData(contactId);
    }
}