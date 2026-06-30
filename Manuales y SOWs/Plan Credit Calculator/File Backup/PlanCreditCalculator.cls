public class PlanCreditCalculator {

    // INPUT: Cambiamos Id por String para evitar el error "Invalid Id" si llega vacío
    public class Request {
        @InvocableVariable(label='PE ID Actual (Destino)' required=false)
        public String peId; // Antes Id, ahora String
        
        @InvocableVariable(label='PE ID Anterior (Origen)' required=false)
        public String oldPeId; // Antes Id, ahora String

        @InvocableVariable(label='Plan ID (Opcional)' required=false)
        public String planId; 
    }

    // OUTPUT: No devolvemos nada, el Apex hace el Update internamente
    @InvocableMethod(label='Calculate Credits (Update DB)' description='Calculates and Updates PE records handling moves and deletes.')
    public static void calculateCredits(List<Request> requests) {
        
        // 1. RECOLECTAR TODOS LOS IDS UNICOS (Validando que sean reales)
        Set<Id> allPeIdsToProcess = new Set<Id>();
        
        for (Request req : requests) {
            // Usamos String.isNotBlank para filtrar nulos Y textos vacíos ('')
            if (String.isNotBlank(req.peId))    allPeIdsToProcess.add(Id.valueOf(req.peId));
            if (String.isNotBlank(req.oldPeId)) allPeIdsToProcess.add(Id.valueOf(req.oldPeId));
        }
        
        if (allPeIdsToProcess.isEmpty()) return;

        // 2. CONSULTA 1: TRAER INFORMACIÓN DE LOS PEs
        Map<Id, hed__Program_Enrollment__c> peMap = new Map<Id, hed__Program_Enrollment__c>([
            SELECT Id, hed__Program_Plan__c, hed__Credits_Earned__c 
            FROM hed__Program_Enrollment__c 
            WHERE Id IN :allPeIdsToProcess
        ]);

        // Recolectar IDs de Planes
        Set<Id> planIds = new Set<Id>();
        for(hed__Program_Enrollment__c pe : peMap.values()) {
            if(pe.hed__Program_Plan__c != null) planIds.add(pe.hed__Program_Plan__c);
        }

        // 3. CONSULTA 2: TRAER REQUISITOS
        List<hed__Plan_Requirement__c> allReqs = [
            SELECT Id, Name, hed__Credits__c, hed__Course__c, 
                   hed__Plan_Requirement__c, hed__Plan_Requirement__r.Name,
                   hed__Program_Plan__c, hed__Plan_Requirement__r.hed__Program_Plan__c
            FROM hed__Plan_Requirement__c 
            WHERE hed__Program_Plan__c IN :planIds 
               OR hed__Plan_Requirement__r.hed__Program_Plan__c IN :planIds
        ];

        // 4. CONSULTA 3: TRAER ENROLLMENTS
        List<hed__Course_Enrollment__c> allEnrollments = [
            SELECT Id, Name, hed__Credits_Earned__c, hed__Course_Offering__r.hed__Course__c, hed__Program_Enrollment__c
            FROM hed__Course_Enrollment__c 
            WHERE hed__Program_Enrollment__c IN :allPeIdsToProcess 
            AND Notations__c IN ('R', 'EQV', 'TRANSF')
        ];

        // 5. ORGANIZAR DATOS EN MAPAS
        Map<Id, List<hed__Plan_Requirement__c>> planToReqsMap = new Map<Id, List<hed__Plan_Requirement__c>>();
        for (hed__Plan_Requirement__c req : allReqs) {
            Id pId = (req.hed__Program_Plan__c != null) ? req.hed__Program_Plan__c : req.hed__Plan_Requirement__r.hed__Program_Plan__c;
            if (pId != null) {
                if (!planToReqsMap.containsKey(pId)) planToReqsMap.put(pId, new List<hed__Plan_Requirement__c>());
                planToReqsMap.get(pId).add(req);
            }
        }

        Map<Id, List<hed__Course_Enrollment__c>> peToEnrMap = new Map<Id, List<hed__Course_Enrollment__c>>();
        for (hed__Course_Enrollment__c enr : allEnrollments) {
            if (!peToEnrMap.containsKey(enr.hed__Program_Enrollment__c)) peToEnrMap.put(enr.hed__Program_Enrollment__c, new List<hed__Course_Enrollment__c>());
            peToEnrMap.get(enr.hed__Program_Enrollment__c).add(enr);
        }

        // 6. CALCULAR Y PREPARAR UPDATE
        List<hed__Program_Enrollment__c> pesToUpdate = new List<hed__Program_Enrollment__c>();
        
        for (hed__Program_Enrollment__c pe : peMap.values()) {
            List<hed__Plan_Requirement__c> specificReqs = planToReqsMap.get(pe.hed__Program_Plan__c);
            if(specificReqs == null) specificReqs = new List<hed__Plan_Requirement__c>();

            List<hed__Course_Enrollment__c> specificEnrs = peToEnrMap.get(pe.Id);
            if(specificEnrs == null) specificEnrs = new List<hed__Course_Enrollment__c>(); 
            
            Decimal totalCalculated = calculateLogic(specificReqs, specificEnrs);
            
            if (pe.hed__Credits_Earned__c != totalCalculated) {
                pe.hed__Credits_Earned__c = totalCalculated;
                pesToUpdate.add(pe);
            }
        }
        
        // 7. DML FINAL
        if (!pesToUpdate.isEmpty()) {
            update pesToUpdate;
        }
    }
    
    // --- LÓGICA MATEMÁTICA PURA (SIN CAMBIOS) ---
    private static Decimal calculateLogic(List<hed__Plan_Requirement__c> reqs, List<hed__Course_Enrollment__c> enrs) {
        // Mapear Cursos Aprobados del Alumno
        Map<String, hed__Course_Enrollment__c> mapCourseToEnr = new Map<String, hed__Course_Enrollment__c>();
        for (hed__Course_Enrollment__c enr : enrs) {
            if (enr.hed__Course_Offering__r.hed__Course__c != null) {
                mapCourseToEnr.put(enr.hed__Course_Offering__r.hed__Course__c, enr);
            }
        }
        
        Set<String> usedCourseIds = new Set<String>();
        Decimal grandTotal = 0.0;
        
        // Organizar Padres e Hijos
        List<hed__Plan_Requirement__c> parents = new List<hed__Plan_Requirement__c>();
        Map<String, List<hed__Plan_Requirement__c>> mapParentToChildren = new Map<String, List<hed__Plan_Requirement__c>>();
        
        for (hed__Plan_Requirement__c r : reqs) {
            if (r.hed__Plan_Requirement__c == null) {
                parents.add(r); 
            } else {
                if (!mapParentToChildren.containsKey(r.hed__Plan_Requirement__c)) {
                    mapParentToChildren.put(r.hed__Plan_Requirement__c, new List<hed__Plan_Requirement__c>());
                }
                mapParentToChildren.get(r.hed__Plan_Requirement__c).add(r);
            }
        }
        
        // Procesar Requisitos
        for (hed__Plan_Requirement__c parent : parents) {
            if (parent.Name != null && parent.Name.contains('12 unités')) { continue; }
            
            // A) Directo
            if (parent.hed__Course__c != null) {
                if (mapCourseToEnr.containsKey(parent.hed__Course__c) && !usedCourseIds.contains(parent.hed__Course__c)) {
                    hed__Course_Enrollment__c match = mapCourseToEnr.get(parent.hed__Course__c);
                    grandTotal += (match.hed__Credits_Earned__c != null ? match.hed__Credits_Earned__c : 0);
                    usedCourseIds.add(parent.hed__Course__c);
                }
            } 
            // B) Grupo
            else if (mapParentToChildren.containsKey(parent.Id)) {
                Decimal groupSum = 0.0;
                List<hed__Plan_Requirement__c> children = mapParentToChildren.get(parent.Id);
                for (hed__Plan_Requirement__c child : children) {
                    if (child.hed__Course__c != null && mapCourseToEnr.containsKey(child.hed__Course__c) && !usedCourseIds.contains(child.hed__Course__c)) {
                        hed__Course_Enrollment__c match = mapCourseToEnr.get(child.hed__Course__c);
                        groupSum += (match.hed__Credits_Earned__c != null ? match.hed__Credits_Earned__c : 0);
                        usedCourseIds.add(child.hed__Course__c);
                    }
                }
                Decimal cap = (parent.hed__Credits__c != null) ? parent.hed__Credits__c : 999;
                grandTotal += Math.min(groupSum, cap);
            }
        }
        
        // Procesar Bucket
        Decimal bucketSum = 0.0;
        Decimal bucketCap = 12.0; 
        for (hed__Course_Enrollment__c enr : enrs) {
            String cId = enr.hed__Course_Offering__r.hed__Course__c;
            if (cId != null && !usedCourseIds.contains(cId)) {
                Decimal earned = (enr.hed__Credits_Earned__c != null ? enr.hed__Credits_Earned__c : 0);
                if (bucketSum < bucketCap) {
                    bucketSum += earned;
                }
            }
        }
        grandTotal += Math.min(bucketSum, bucketCap);
        
        return grandTotal;
    }
}