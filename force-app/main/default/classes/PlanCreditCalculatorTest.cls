@isTest
private class PlanCreditCalculatorTest {

    @testSetup
    static void setupData() {
        // 1. Crear Cuenta (Requerida por EDA)
        Account school = new Account(Name = 'Universidad Test Dummy');
        insert school;

        // 2. Crear Plan
        hed__Program_Plan__c plan = new hed__Program_Plan__c(Name = 'Plan Test Completo');
        insert plan;
        
        // 3. Crear Cursos (3 tipos para cubrir todo el código)
        // A) Curso Obligatorio Directo
        hed__Course__c courseObli = new hed__Course__c(Name = 'Teología I', hed__Course_ID__c = 'TEO101', hed__Account__c = school.Id);
        // B) Curso de Grupo (Hijo)
        hed__Course__c courseGroup = new hed__Course__c(Name = 'Griego I', hed__Course_ID__c = 'GR101', hed__Account__c = school.Id);
        // C) Curso Electivo (Sin requisito)
        hed__Course__c courseFree = new hed__Course__c(Name = 'Piano', hed__Course_ID__c = 'MUS101', hed__Account__c = school.Id);
        
        insert new List<hed__Course__c>{courseObli, courseGroup, courseFree};
        
        // 4. Crear Requisitos (Requirements)
        // A) Requisito Directo
        hed__Plan_Requirement__c reqDirect = new hed__Plan_Requirement__c(
            Name = 'Req Teo I',
            hed__Program_Plan__c = plan.Id,
            hed__Course__c = courseObli.Id,
            hed__Credits__c = 3.0
        );
        
        // B) Requisito de Grupo (Padre) - Cubre lógica de mapas hijos
        hed__Plan_Requirement__c reqGroupParent = new hed__Plan_Requirement__c(
            Name = 'Grupo Idiomas',
            hed__Program_Plan__c = plan.Id,
            hed__Credits__c = 10.0 // Límite del grupo
        );
        insert new List<hed__Plan_Requirement__c>{reqDirect, reqGroupParent};
        
        // C) Requisito Hijo (Apunta al Padre)
        hed__Plan_Requirement__c reqGroupChild = new hed__Plan_Requirement__c(
            Name = 'Opcion Griego',
            hed__Plan_Requirement__c = reqGroupParent.Id, 
            hed__Course__c = courseGroup.Id,
            hed__Credits__c = 3.0
        );
        insert reqGroupChild;
        
        // 5. Crear Term
        hed__Term__c term = new hed__Term__c(
            Name = '2024-1', 
            hed__Account__c = school.Id 
        ); 
        insert term;

        // 6. Crear Offerings
        hed__Course_Offering__c off1 = new hed__Course_Offering__c(hed__Course__c = courseObli.Id, hed__Term__c = term.Id);
        hed__Course_Offering__c off2 = new hed__Course_Offering__c(hed__Course__c = courseGroup.Id, hed__Term__c = term.Id);
        hed__Course_Offering__c off3 = new hed__Course_Offering__c(hed__Course__c = courseFree.Id, hed__Term__c = term.Id);
        insert new List<hed__Course_Offering__c>{off1, off2, off3};
    }

    @isTest
    static void testFullWaterfallCoverage() {
        // Recuperar datos
        hed__Program_Plan__c plan = [SELECT Id FROM hed__Program_Plan__c LIMIT 1];
        hed__Program_Enrollment__c pe = new hed__Program_Enrollment__c(hed__Program_Plan__c = plan.Id);
        insert pe;
        
        List<hed__Course_Offering__c> offerings = [SELECT Id, hed__Course__r.hed__Course_ID__c FROM hed__Course_Offering__c];
        
        Test.startTest();
        
        // Inscribir al alumno en LAS TRES materias
        List<hed__Course_Enrollment__c> enrollments = new List<hed__Course_Enrollment__c>();
        for(hed__Course_Offering__c off : offerings) {
            enrollments.add(new hed__Course_Enrollment__c(
                hed__Program_Enrollment__c = pe.Id,
                hed__Course_Offering__c = off.Id,
                hed__Credits_Earned__c = 3.0,
                Notations__c = 'R'
            ));
        }
        insert enrollments;
        
        // EJECUCIÓN (Versión Void/Ejecutor)
        // Ya no esperamos un resultado "return", solo llamamos al método.
        PlanCreditCalculator.Request req = new PlanCreditCalculator.Request();
        req.peId = String.valueOf(pe.Id); 
        req.planId = null; 
        
        PlanCreditCalculator.calculateCredits(new List<PlanCreditCalculator.Request>{req});
        
        Test.stopTest();
        
        // VALIDACIÓN: Consultamos la base de datos para ver si se actualizó
        hed__Program_Enrollment__c peCheck = [SELECT hed__Credits_Earned__c FROM hed__Program_Enrollment__c WHERE Id = :pe.Id];
        
        // 3 (Directo) + 3 (Grupo) + 3 (Electiva) = 9 Total
        System.assertEquals(9.0, peCheck.hed__Credits_Earned__c, 'El cálculo debe sumar Directas, Grupos y Electivas directamente en el registro');
    }
    
    @isTest
    static void testDeleteOrphan() {
        hed__Program_Plan__c plan = [SELECT Id FROM hed__Program_Plan__c LIMIT 1];
        hed__Course_Offering__c offering = [SELECT Id FROM hed__Course_Offering__c LIMIT 1];
        
        hed__Program_Enrollment__c pe = new hed__Program_Enrollment__c(hed__Program_Plan__c = plan.Id);
        insert pe;
        
        hed__Course_Enrollment__c cc = new hed__Course_Enrollment__c(
            hed__Program_Enrollment__c = pe.Id,
            hed__Course_Offering__c = offering.Id,
            hed__Credits_Earned__c = 3.0,
            Notations__c = 'R'
        );
        insert cc;
        
        Test.startTest();
        // Simular borrado lógico (huérfano)
        cc.hed__Program_Enrollment__c = null;
        update cc;
        
        PlanCreditCalculator.Request reqDelete = new PlanCreditCalculator.Request();
        reqDelete.peId = null;     
        reqDelete.oldPeId = String.valueOf(pe.Id);
        
        PlanCreditCalculator.calculateCredits(new List<PlanCreditCalculator.Request>{reqDelete});
        Test.stopTest();
        
        hed__Program_Enrollment__c peCheck = [SELECT hed__Credits_Earned__c FROM hed__Program_Enrollment__c WHERE Id = :pe.Id];
        System.assertEquals(0.0, peCheck.hed__Credits_Earned__c, 'Debe bajar a 0 tras quedar huérfano');
    }
}