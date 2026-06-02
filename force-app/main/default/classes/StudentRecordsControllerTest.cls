@isTest
private class StudentRecordsControllerTest {

    // ---------- Helpers ----------
    private static Contact makeContact(String lastName, String oldId, Date birth, Boolean withAddress) {
        Contact c = new Contact(
            LastName = lastName,
            Old_id__c = oldId,
            Birthdate = birth
        );
        if (withAddress) {
            c.MailingStreet = '123 Rue Test';
            c.MailingCity = 'Montreal';
            c.MailingState = 'QC';
            c.MailingPostalCode = 'H1A 1A1';
        }
        insert c;
        return c;
    }

    private static Account makeProgram(String name) {
        Account a = new Account(Name = name);
        insert a;
        return a;
    }

    private static hed__Program_Enrollment__c makeProgramEnrollment(Id contactId, Id accountId,
                                                                    Date startDt, Date endDt,
                                                                    String status, String classStanding) {
        hed__Program_Enrollment__c pe = new hed__Program_Enrollment__c(
            hed__Contact__c = contactId,
            hed__Account__c = accountId,
            hed__Admission_Date__c = Date.today(),
            hed__Class_Standing__c = classStanding,
            Status__c = status,
            hed__Start_Date__c = startDt,
            hed__End_Date__c = endDt
        );
        insert pe;
        return pe;
    }

    private static hed__Course_Enrollment__c makeCourseEnrollment(Id contactId,
                                                                      Id programEnrollmentId,
                                                                      Decimal credits,
                                                                      Decimal grade,
                                                                      String notations,
                                                                      String terms,          // se mantiene en la firma (no se usa)
                                                                      Boolean primaryFlag,   // se mantiene en la firma (no se usa)
                                                                      String courseId,       // se mantiene en la firma (no se usa)
                                                                      String courseName) {   // se mantiene en la firma (no se usa)
            hed__Course_Enrollment__c ce = new hed__Course_Enrollment__c(
                hed__Contact__c = contactId,
                hed__Program_Enrollment__c = programEnrollmentId,
                hed__Credits_Earned__c = credits,
                hed__Grade__c = grade,
                Notations__c = notations
            );
            insert ce;
            return ce;
        }

    // ---------- Tests ----------

    @isTest static void test_BasePath_ProgramCreditsAndFields() {
        Contact c = makeContact('User One','A-001', Date.newInstance(1995,5,15), true);
        Account a = makeProgram('Program A');

        // Completed con Start & End => cubre StartYear/EndYear/Status
        hed__Program_Enrollment__c pe = makeProgramEnrollment(
            c.Id, a.Id,
            Date.newInstance(2020,1,1),
            Date.newInstance(2022,12,31),
            'Completed', 'Senior'
        );

        // Curso que suma créditos (R) y grade con valor (cubre Math.round)
        makeCourseEnrollment(c.Id, pe.Id, 3, 85, 'R', 'H2020', null, 'BI100', 'Course R');

        Test.startTest();
        StudentRecordsController.StudentPdfData data =
            StudentRecordsController.getStudentPdfData(c.Id);
        Test.stopTest();

        System.assertNotEquals(null, data, 'Debe retornar DTO');
        System.assertEquals('User One', data.Name);
        System.assertEquals(1, data.Programs.size(), 'Un programa');
        System.assertEquals('Completed', data.Programs[0].Status);
        System.assertEquals('2020', data.Programs[0].StartYear);
        System.assertEquals('2022', data.Programs[0].EndYear);
        System.assertEquals(1, data.Programs[0].Courses.size(), 'Un curso incluido');
        System.assertEquals(3, data.Programs[0].TotalCredits, 'Suma créditos por Notations=R');
    }

    @isTest static void test_ProgramCredits_WhenPrimaryNotAssignable() {
        Contact c = makeContact('User Two','A-002', Date.newInstance(1990,1,1), true);
        Account a = makeProgram('Program B');
        hed__Program_Enrollment__c pe = makeProgramEnrollment(
            c.Id, a.Id, Date.newInstance(2021,1,1), Date.newInstance(2023,1,1), 'Completed', 'Junior'
        );

        // Este NO debe aparecer (Primary=true)
        makeCourseEnrollment(c.Id, pe.Id, 4, 90, 'R', 'A2021', true, 'BI200', 'Primary True Course');

        // Este sí aparece (Primary null/false)
        makeCourseEnrollment(c.Id, pe.Id, 2, 88, 'EQV', 'A2021', null, 'BI201', 'EQV Course');

        Test.startTest();
        StudentRecordsController.StudentPdfData data =
            StudentRecordsController.getStudentPdfData(c.Id);
        Test.stopTest();

        System.assertEquals(2, data.Programs[0].Courses.size(),
            'Al no poder setear Primary, entran ambos cursos');
        System.assertEquals(6, data.Programs[0].TotalCredits,
            'Suma 4 (R) + 2 (EQV) = 6');
    }

    @isTest static void test_HorsProgram_TotalCreditsAndGradeNull() {
        Contact c = makeContact('User Three','A-003', Date.newInstance(1999,9,9), false);

        // Curso fuera de programa: hed__Program_Enrollment__c = null
        // Suma por EQV; grade null => Note debe ser '-'
        makeCourseEnrollment(c.Id, null, 1.5, null, 'EQV', 'P2020', null, 'TS101', 'EQV HP');

        // Otro fuera de programa, Notations que NO suma
        makeCourseEnrollment(c.Id, null, 3, 75, 'AUD', 'P2020', null, 'TS102', 'AUD HP');

        Test.startTest();
        StudentRecordsController.StudentPdfData data =
            StudentRecordsController.getStudentPdfData(c.Id);
        Test.stopTest();

        System.assertEquals(2, data.HorsProgram.size(), 'Ambos fuera de programa listados');
        System.assertEquals(1.5, data.TotalCreditsHorsProgram, 'Solo suma el EQV');
        // Validar que el curso con grade null (1.5 créditos, EQV) tenga Note '-'
        Boolean foundDash = false;
        for (StudentRecordsController.Course x : data.HorsProgram) {
            if (x.Credits == 1.5) {
                System.assertEquals('-', x.Note, 'Grade null debe mapear a "-"');
                foundDash = true;
                break;
            }
        }
        System.assert(foundDash, 'Debe haberse validado el curso con 1.5 créditos (EQV)');
    }

    @isTest static void test_StatusCurrent_EndYearBlankAndTermsOrder() {
        Contact c = makeContact('User Four','A-004', Date.newInstance(2000,2,2), true);
        Account a = makeProgram('Program C');

        // Current => EndYear vacío
        hed__Program_Enrollment__c pe = makeProgramEnrollment(
            c.Id, a.Id, Date.newInstance(2024,1,1), null, 'Current', 'Sophomore'
        );

        // Dos cursos con Notations que NO suman (para cubrir el branch negativo)
        makeCourseEnrollment(c.Id, pe.Id, 3, null, null, 'H2024', null, 'NT101', 'No Notations');
        makeCourseEnrollment(c.Id, pe.Id, 2, 77, 'AUD', 'A2024', null, 'NT102', 'Audit');

        Test.startTest();
        StudentRecordsController.StudentPdfData data =
            StudentRecordsController.getStudentPdfData(c.Id);
        Test.stopTest();

        System.assertEquals('Current', data.Programs[0].Status);
        System.assertEquals('2024', data.Programs[0].StartYear);
        System.assertEquals('', data.Programs[0].EndYear, 'Sin EndDate => EndYear vacío');
        System.assertEquals(0, data.Programs[0].TotalCredits, 'No debe sumar créditos');
        System.assertEquals(2, data.Programs[0].Courses.size(), 'Ambos cursos listados');
    }

    @isTest static void test_RemoteAction_fetchStudentPdfData() {
        Contact c = makeContact('User Five','A-005', Date.newInstance(1998,8,8), true);
        Account a = makeProgram('Program D');
        hed__Program_Enrollment__c pe = makeProgramEnrollment(
            c.Id, a.Id, Date.newInstance(2018,1,1), Date.newInstance(2019,1,1), 'Completed', 'Senior'
        );
        makeCourseEnrollment(c.Id, pe.Id, 1, 60, 'TRANSF', 'A2018', null, 'EP101', 'Transf');

        Test.startTest();
        // Llama al wrapper remoto
        StudentRecordsController.StudentPdfData data =
            StudentRecordsController.fetchStudentPdfData(c.Id);
        Test.stopTest();

        System.assertNotEquals(null, data);
        System.assertEquals(1, data.Programs.size());
        System.assertEquals(1, data.Programs[0].Courses.size());
        System.assertEquals(1, data.Programs[0].TotalCredits);
    }
}