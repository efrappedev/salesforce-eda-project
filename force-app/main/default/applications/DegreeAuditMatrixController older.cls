public with sharing class DegreeAuditMatrixController {

    // ===== Exclusiones de Program Plan =====
    private static final Set<String> EXCLUDED_PLAN_NAMES = new Set<String>{
        'HORS PROGRAMME', 'HORS PROGRAM'
    };

    // Notations que cuentan como OK (además de Status=Completed)
    private static final Set<String> OK_NOTATIONS = new Set<String>{ 'R', 'EQV', 'TRANSF' };
    
    // ==== Filtros UI ====
    // Valores conocidos para estados de Program Plan (ajusta si tu picklist tiene otros)
    private static final Set<String> KNOWN_PLAN_STATUSES = new Set<String>{ 'Current', 'Archived' };

    // Valores conocidos para Program Enrollment (Status__c)
    private static final Set<String> KNOWN_PE_STATUSES =
        new Set<String>{ 'Current', 'Completed', 'Transferred', 'Abandoned', 'On Hold' };

    // Selecciones que vienen de la VF
    public String planStatusFilter { get; set; }  // 'ALL' | 'Current' | 'Archived'
    public String peStatusFilter   { get; set; }  // 'ALL' | 'ACTIVE3' | valor único (Current, Completed, ...)

    // Picklist para Program Plan
    public List<SelectOption> getPlanStatusOptions(){
        List<SelectOption> opts = new List<SelectOption>();
        opts.add(new SelectOption('ALL','Tous'));
        for (String v : new List<String>{'Current','Archived'}){
            if (KNOWN_PLAN_STATUSES.contains(v)) opts.add(new SelectOption(v, v));
        }
        return opts;
    }

    // Picklist para Program Enrollment
    public List<SelectOption> getPeStatusOptions(){
        List<SelectOption> opts = new List<SelectOption>();
        opts.add(new SelectOption('ALL','Tous'));
        // Combinada: Current + Completed + Transferred (por defecto)
        opts.add(new SelectOption('ACTIVE3','Current + Completed + Transferred'));
        for (String v : new List<String>{'Current','Completed','Transferred','On Hold','Abandoned'}){
            if (KNOWN_PE_STATUSES.contains(v)) opts.add(new SelectOption(v, v));
        }
        return opts;
    }

    // (Se quedan aunque no se usan directamente; no rompen nada)
    private static final Set<String> ACTIVE_PLAN_STATUSES = new Set<String>{ 'Current' };
    private static final Set<String> ACTIVE_PE_STATUSES   = new Set<String>{ 'Current' };

    // Helper: ¿hay alguna notación OK? (normaliza acentos y separa por no-alfabéticos)
    private static Boolean hasOkNotation(String notes){
        if (String.isBlank(notes)) return false;
        String norm = notes.replace('é','e').replace('É','E').toUpperCase();
        for (String t : norm.split('[^A-Z]+')) {
            if (OK_NOTATIONS.contains(t)) return true;
        }
        return false;
    }

    // ====== Plan selection (aliases conservados) ======
    private String planIdInternal;
    public String getSelectedProgramPlanId() { return planIdInternal; }
    public void   setSelectedProgramPlanId(String v) { planIdInternal = v; }
    public String getSelectedPlanId() { return planIdInternal; }
    public void   setSelectedPlanId(String v) { planIdInternal = v; }
    public String selectedRequirementId { get; set; }   // filtro de curso (opcional)
    
    // agrega estas sobrecargas (para cuando te pasan un Id) checkpoint
    public void setSelectedProgramPlanId(Id v) { planIdInternal = (v == null ? null : (String)v); }
    public void setSelectedPlanId(Id v)        { planIdInternal = (v == null ? null : (String)v); }

    // ====== UI lists / data ======
    public List<SelectOption> programPlanOptions { get; private set; }
    public List<hed__Plan_Requirement__c> requirements { get; private set; }
    public List<RowVM> rows { get; private set; }
    public Integer studentsCount { get; private set; }
    public Integer requirementsCount { get; private set; }
    public Map<Id, Integer> reqOkCounts { get; private set; }
    
    // Devuelve un Map con 0 por defecto para todos los requirements visibles
    public Map<Id, Integer> getReqOkCountsSafe(){
        Map<Id, Integer> m = new Map<Id, Integer>();
        if (reqOkCounts != null) m.putAll(reqOkCounts);
        // 'requirements' es la misma lista que iteras en la VF
        for (SObject r : requirements){
            Id rid = (Id) r.get('Id');
            if (rid != null && !m.containsKey(rid)){
                m.put(rid, 0);
            }
        }
        return m;
    }
    
    public transient String csvContent { get; private set; }

    // ====== Modal (student detail) ======
    public Id selectedContactId { get; private set; }
    public Boolean showDetail { get; private set; }
    public StudentDetailVM studentDetail { get; private set; }
    
    public Map<Id, String>  detailOptTipByPrId  { get; private set; }
    public Map<Id, Decimal> detailOptEarnByPrId { get; private set; }
    
    public transient String detailCsvContent { get; private set; }

    // ====== Context (switch auto) ======
    private Id currentUserContactId; // portal user → not null

    // ====== Extra para Contact Action ======
    public List<SelectOption> studentPlanOptions { get; private set; }
    public Id actionContactId { get; private set; } // cuando viene de acción sobre Contact
    public String selectedStudentPlanId { get; set; }

    public Boolean getIsPortalView(){
        return (currentUserContactId != null);
    }

    // === Picklist para el filtro de curso (VF: {!requirementPicklist})
    public List<SelectOption> getRequirementPicklist(){
        List<SelectOption> opts = new List<SelectOption>();
        // Opción "todos"
        opts.add(new SelectOption('', '— Tous les cours —'));
        if (requirements != null){
            for (hed__Plan_Requirement__c r : requirements){
                // Usa el nombre del curso si existe; si no, el nombre del requirement
                String label = (r.hed__Course__r != null && String.isNotBlank(r.hed__Course__r.Name))
                    ? r.hed__Course__r.Name
                    : r.Name;
                opts.add(new SelectOption(r.Id, label));
            }
        }
        return opts;
    }

    // === Estado de datos para la vista (VF: {!hasData})
    public Boolean getHasData(){
        return (rows != null && !rows.isEmpty());
    }

    public DegreeAuditMatrixController(){
        // Defaults UI: planes = ALL; PE = Current+Completed+Transferred
        if (planStatusFilter == null) planStatusFilter = 'ALL';
        if (peStatusFilter   == null) peStatusFilter   = 'ACTIVE3';

        // Portal: detectar si el usuario actual es portal (tiene ContactId)
        try{
            currentUserContactId = [SELECT ContactId FROM User WHERE Id = :UserInfo.getUserId()].ContactId;
        }catch(Exception e){
            currentUserContactId = null;
        }

        // === Cargar Program Plans con filtro seleccionable (sin usar variables boolean en SOQL) ===
        programPlanOptions = new List<SelectOption>();
        List<hed__Program_Plan__c> planList;
        if (planStatusFilter == null || planStatusFilter == 'ALL') {
            planList = [
                SELECT Id, Name, hed__Status__c
                FROM hed__Program_Plan__c
                WHERE Name NOT IN :EXCLUDED_PLAN_NAMES
                ORDER BY Name
                LIMIT 1000
            ];
        } else {
            planList = [
                SELECT Id, Name, hed__Status__c
                FROM hed__Program_Plan__c
                WHERE Name NOT IN :EXCLUDED_PLAN_NAMES
                  AND hed__Status__c = :planStatusFilter
                ORDER BY Name
                LIMIT 1000
            ];
        }
        for (hed__Program_Plan__c p : planList) {
            programPlanOptions.add(new SelectOption(p.Id, p.Name));
        }

        rows = new List<RowVM>();
        reqOkCounts = new Map<Id, Integer>();
        csvContent = '';
        showDetail = false;
        requirementsCount = 0;
        studentsCount = 0;
        
        // inits para mapas de optativos del detalle en Contacto
        detailOptTipByPrId  = new Map<Id, String>();
        detailOptEarnByPrId = new Map<Id, Decimal>();

    }

    // ==== VMs ====
    public class RowVM {
        public Id ContactId { get; set; }
        public String FirstName { get; set; }
        public String LastName  { get; set; }
        public String DisplayName { get; set; }
        public String Email { get; set; }
        public String ContactExternalId { get; set; } // ID_Contact__c
        public Id programEnrollmentId { get; set; }    // PE del alumno en este plan
        public Map<Id, Decimal> mapOptEarnByPrId { get; set; } // Earned por bloque
        public Map<Id, String>  mapOptTipByPrId  { get; set; } // Tooltip por bloque
        public Map<Id, Boolean> mapReqToOk { get; set; }
        public Map<Id, String>  mapReqToTip { get; set; } 
        public Integer MissingCount { get; set; }
        public Decimal ProgressPercent { get; set; }  // 0..100
        public Date LastCourseDate { get; set; }
        public Boolean OlderThan7Years { get; set; }
        public RowVM(){
            mapReqToOk = new Map<Id, Boolean>();
            mapReqToTip = new Map<Id, String>();
            mapOptEarnByPrId = new Map<Id, Decimal>();
            mapOptTipByPrId  = new Map<Id, String>();
        }
        public String getProgressPercentText(){
            return (ProgressPercent == null) ? '' : String.valueOf((Integer)ProgressPercent.intValue()) + '%';
        }
        public String getLastCourseDateText(){
            return (LastCourseDate == null) ? '' : LastCourseDate.format();
        }
    }
    public class CourseStatusVM {
        public String CourseName { get; set; }
        public Boolean IsOk { get; set; }
        public String Tooltip { get; set; }
        public CourseStatusVM(String name, Boolean ok, String tip){
            CourseName = name; IsOk = ok; Tooltip = tip;
        }
    }
    public class StudentDetailVM {
        public Id ContactId { get; set; }
        public String FirstName { get; set; }    // <- nuevo
        public String LastName  { get; set; }    // <- nuevo
        public String DisplayName { get; set; }
        public String Email { get; set; }
        public String ContactExternalId { get; set; }  // ID_Contact__c
        public String PlanName { get; set; }
        public Integer MissingCount { get; set; }
        public Decimal ProgressPercent { get; set; }
        public Date LastCourseDate { get; set; }
        public Boolean OlderThan7Years { get; set; }
        public List<CourseStatusVM> Courses { get; set; }
        public String getProgressPercentText(){
            return (ProgressPercent == null) ? '' : String.valueOf((Integer)ProgressPercent.intValue()) + '%';
        }
        public String getLastCourseDateText(){
            return (LastCourseDate == null) ? '' : LastCourseDate.format();
        }
    }

        /* ===== Quick Action (Lightning) — constructor de extensión ===== */
        public DegreeAuditMatrixController(ApexPages.StandardController std){
            if (planStatusFilter == null) planStatusFilter = 'ALL';
            if (peStatusFilter   == null) peStatusFilter   = 'ACTIVE3';
        
            programPlanOptions   = new List<SelectOption>();
            rows                 = new List<RowVM>();
            reqOkCounts          = new Map<Id, Integer>();
            csvContent           = '';
            showDetail           = false;
            requirementsCount    = 0;
            studentsCount        = 0;
            detailOptTipByPrId   = new Map<Id, String>();
            detailOptEarnByPrId  = new Map<Id, Decimal>();
        
            // ✅ Obtener SIEMPRE el Id del Contact
            Id rid = null;
            try { rid = (Id) std.getId(); } catch (Exception e) {}
            if (rid == null) {
                SObject rec = std.getRecord();
                if (rec != null) rid = (Id) rec.get('Id');
            }
            if (rid == null) {
                String ridParam = ApexPages.currentPage().getParameters().get('recordId');
                if (!String.isBlank(ridParam)) rid = (Id) ridParam;
            }
            if (rid == null) {
                String idParam = ApexPages.currentPage().getParameters().get('id');
                if (!String.isBlank(idParam)) rid = (Id) idParam;
            }
            actionContactId = rid;
        
            if (actionContactId == null) {
                ApexPages.addMessage(new ApexPages.Message(
                    ApexPages.Severity.ERROR, 'Contact Id manquant.'
                ));
                return;
            }
        
            // PE del contacto (solo Current, sin “Hors programme”)
            List<hed__Program_Enrollment__c> pes = [
                SELECT Id, hed__Program_Plan__c, hed__Program_Plan__r.Name, Status__c
                FROM hed__Program_Enrollment__c
                WHERE hed__Contact__c = :actionContactId
                  AND Status__c = 'Current'
                  AND hed__Program_Plan__c != NULL
                  AND hed__Program_Plan__r.Name NOT IN :EXCLUDED_PLAN_NAMES
                ORDER BY hed__Program_Plan__r.Name
                LIMIT 1000
            ];
        
            selectedStudentPlanId = null;
            planIdInternal        = null;
            showDetail            = false;
        
            if (pes.isEmpty()){
                studentPlanOptions = null;
                return;
            }
        
            studentPlanOptions = new List<SelectOption>();
            Set<Id> seen = new Set<Id>();
            for (hed__Program_Enrollment__c pe : pes) {
                if (pe.hed__Program_Plan__c != null && seen.add(pe.hed__Program_Plan__c)) {
                    studentPlanOptions.add(new SelectOption(pe.hed__Program_Plan__c, pe.hed__Program_Plan__r.Name));
                }
            }
        }
    // ====== Action: Build matrix ======
    public PageReference runAudit() {
        // 🔄 Al cambiar de plan, resetea el filtro de curso
        selectedRequirementId = null;

        requirements = new List<hed__Plan_Requirement__c>();
        if (String.isBlank(planIdInternal)) { clearResults(); return null; }

        // 1) Requirements del plan (solo con Course)
        requirements = [
            SELECT Id, Name, hed__Course__c, hed__Course__r.Name
            FROM hed__Plan_Requirement__c
            WHERE hed__Program_Plan__c = :planIdInternal
              AND hed__Course__c != NULL
            ORDER BY Name
            LIMIT 2000
        ];

        requirementsCount = requirements.size();
        if (requirements.isEmpty()) { clearResults(); return null; }

        // Mapa Course -> Requirements para lookups O(1)
        Map<Id, List<Id>> courseToReq = buildCourseToReqMap();

        // 2) Contacts con Program Enrollment en el plan (con filtro seleccionable)
        Map<Id, Contact> contactsById = new Map<Id, Contact>();

        Set<String> peStatuses = new Set<String>();
        Boolean peFilterAll = (peStatusFilter == 'ALL' || peStatusFilter == null);
        if (!peFilterAll){
            if (peStatusFilter == 'ACTIVE3'){
                peStatuses.addAll(new List<String>{ 'Current','Completed','Transferred' });
            } else if (KNOWN_PE_STATUSES.contains(peStatusFilter)){
                peStatuses.add(peStatusFilter);
            }
        }
        Boolean peHasFilter = !peStatuses.isEmpty();

        List<hed__Program_Enrollment__c> peList;
        if (peHasFilter) {
            peList = [
                SELECT Id, hed__Contact__c, hed__Program_Plan__c,
                       hed__Contact__r.FirstName, hed__Contact__r.LastName,
                       hed__Contact__r.Email, hed__Contact__r.ID_Contact__c,
                       Status__c
                FROM hed__Program_Enrollment__c
                WHERE hed__Program_Plan__c = :planIdInternal
                  AND hed__Contact__c != NULL
                  AND Status__c IN :peStatuses
                ORDER BY hed__Contact__r.LastName, hed__Contact__r.FirstName
                LIMIT 10000
            ];
        } else {
            peList = [
                SELECT Id, hed__Contact__c, hed__Program_Plan__c,
                       hed__Contact__r.FirstName, hed__Contact__r.LastName,
                       hed__Contact__r.Email, hed__Contact__r.ID_Contact__c,
                       Status__c
                FROM hed__Program_Enrollment__c
                WHERE hed__Program_Plan__c = :planIdInternal
                  AND hed__Contact__c != NULL
                ORDER BY hed__Contact__r.LastName, hed__Contact__r.FirstName
                LIMIT 10000
            ];
        }

        for (hed__Program_Enrollment__c pe : peList) {
            if (!contactsById.containsKey(pe.hed__Contact__c)) {
                Contact c = new Contact(
                    Id = pe.hed__Contact__c,
                    FirstName = pe.hed__Contact__r.FirstName,
                    LastName  = pe.hed__Contact__r.LastName,
                    Email     = pe.hed__Contact__r.Email,
                    ID_Contact__c = pe.hed__Contact__r.ID_Contact__c
                );
                contactsById.put(c.Id, c);
            }
        }

        if (contactsById.isEmpty()) {
            clearResults(); 
            return null;
        }
        
        // Contact -> PE (del mismo plan) y Set con todos los PE
        Map<Id, Id> contactToPeId = new Map<Id, Id>();
        Set<Id> peIds = new Set<Id>();
        for (hed__Program_Enrollment__c pe : peList) {
            contactToPeId.put(pe.hed__Contact__c, pe.Id);
            peIds.add(pe.Id);
        }

        // 3) Course Enrollments: primero por PE (del plan), con fallback por Contact si hay CE sin PE
        List<hed__Course_Enrollment__c> cesAll = [
            SELECT Id,
                   hed__Contact__c,
                   hed__Program_Enrollment__c,
                   hed__Course_Offering__r.hed__Course__c,
                   hed__Course_Offering__r.hed__Course__r.Name,
                   hed__Course_Offering__r.hed__Term__r.Name,
                   hed__Course_Offering__r.hed__Term__r.hed__End_Date__c,
                   hed__Status__c,
                   Notations__c
            FROM hed__Course_Enrollment__c
            WHERE (hed__Program_Enrollment__c IN :peIds)
               OR (hed__Program_Enrollment__c = NULL AND hed__Contact__c IN :contactsById.keySet())
            ORDER BY hed__Contact__c
            LIMIT 20000
        ];
        
        // Indexación doble: por PE y (fallback) por Contact con PE nulo
        Map<Id, List<hed__Course_Enrollment__c>> cesByPe = new Map<Id, List<hed__Course_Enrollment__c>>();
        Map<Id, List<hed__Course_Enrollment__c>> cesByContactFallback = new Map<Id, List<hed__Course_Enrollment__c>>();
        
        for (hed__Course_Enrollment__c ce : cesAll) {
            if (ce.hed__Program_Enrollment__c != null) {
                if (!cesByPe.containsKey(ce.hed__Program_Enrollment__c)) {
                    cesByPe.put(ce.hed__Program_Enrollment__c, new List<hed__Course_Enrollment__c>());
                }
                cesByPe.get(ce.hed__Program_Enrollment__c).add(ce);
            } else {
                if (!cesByContactFallback.containsKey(ce.hed__Contact__c)) {
                    cesByContactFallback.put(ce.hed__Contact__c, new List<hed__Course_Enrollment__c>());
                }
                cesByContactFallback.get(ce.hed__Contact__c).add(ce);
            }
        }


        // 4) Build rows
        rows = new List<RowVM>();
        for (Contact c : contactsById.values()) {
            RowVM r = new RowVM();
            r.ContactId = c.Id;
            r.DisplayName =
                (c.FirstName != null ? c.FirstName + ' ' : '') +
                (c.LastName != null ? c.LastName : '');
            r.FirstName = c.FirstName;       // <-- set para CSV
            r.LastName  = c.LastName;        // <-- set para CSV
            r.Email = c.Email;
            r.ContactExternalId = (c.ID_Contact__c == null ? '' : c.ID_Contact__c);
            r.programEnrollmentId = contactToPeId.get(c.Id);

            for (hed__Plan_Requirement__c pr : requirements) {
                r.mapReqToOk.put(pr.Id, false);
                r.mapReqToTip.put(pr.Id, 'Aucune inscription trouvée');
            }

            Date latest = null;
            Integer completed = 0;

            // Trae los CE del PE de esta fila; si no hay (CE antiguos sin PE), fallback por Contact
            List<hed__Course_Enrollment__c> ceListForRow =
                (r.programEnrollmentId != null) ? cesByPe.get(r.programEnrollmentId) : null;
            if (ceListForRow == null) ceListForRow = cesByContactFallback.get(c.Id);
            
            if (ceListForRow != null && !ceListForRow.isEmpty()) {
                for (hed__Course_Enrollment__c ce : ceListForRow) {
                    Date d = (ce.hed__Course_Offering__r != null &&
                              ce.hed__Course_Offering__r.hed__Term__r != null)
                        ? ce.hed__Course_Offering__r.hed__Term__r.hed__End_Date__c
                        : null;
                    if (d != null && (latest == null || d > latest)) latest = d;
            
                    if (ce.hed__Course_Offering__r != null) {
                        Id courseId = ce.hed__Course_Offering__r.hed__Course__c;
                        String termName = (ce.hed__Course_Offering__r.hed__Term__r != null) ? ce.hed__Course_Offering__r.hed__Term__r.Name : '';
                        String termEnd  = (ce.hed__Course_Offering__r.hed__Term__r != null && ce.hed__Course_Offering__r.hed__Term__r.hed__End_Date__c != null)
                                          ? ce.hed__Course_Offering__r.hed__Term__r.hed__End_Date__c.format() : '';
                        String tip = 'Status: ' + (ce.hed__Status__c == null ? '' : ce.hed__Status__c)
                                   + '\nNotation: ' + (ce.Notations__c == null ? '' : ce.Notations__c)
                                   + '\nTerm: ' + (String.isBlank(termName) ? '' : termName) + (String.isBlank(termEnd) ? '' : ' (' + termEnd + ')');
            
                        List<Id> reqIdsForCourse = courseToReq.get(courseId);
                        if (reqIdsForCourse != null) {
                            for (Id prId : reqIdsForCourse) {
                                r.mapReqToTip.put(prId, tip);
                            }
                        }
                    }
            
                    Boolean isOk = (ce.hed__Status__c == 'Completed') || hasOkNotation(ce.Notations__c);
            
                    if (isOk && ce.hed__Course_Offering__r != null) {
                        Id courseId2 = ce.hed__Course_Offering__r.hed__Course__c;
                        List<Id> reqIds2 = courseToReq.get(courseId2);
                        if (reqIds2 != null) {
                            for (Id prId : reqIds2) {
                                if (!r.mapReqToOk.get(prId)) { r.mapReqToOk.put(prId, true); completed++; }
                            }
                        }
                    }
                }
            }


            r.LastCourseDate = latest;
            Integer totalReqs = requirements.size();
            r.MissingCount = totalReqs - completed;
            r.ProgressPercent = totalReqs > 0 ? (Decimal.valueOf(completed) / totalReqs) * 100 : 0;
            r.OlderThan7Years = (latest != null) ? (latest.daysBetween(Date.today()) >= 2557) : false;

            rows.add(r);
        }

        rows.sort(new RowSorter());
        studentsCount = rows.size();

        // ===== Contadores por requirement (para encabezado 10/100) =====
        reqOkCounts = new Map<Id, Integer>();
        for (hed__Plan_Requirement__c pr : requirements) {
            Integer acc = 0;
            for (RowVM r : rows) {
                if (r.mapReqToOk.get(pr.Id) == true) acc++;
            }
            reqOkCounts.put(pr.Id, acc);
        }

        // ===== CSV =====
        // Map<Contacto -> RowVM> para la API de optativos
        Map<Id, RowVM> rowsByContact = new Map<Id, RowVM>();
        for (RowVM r : rows) rowsByContact.put(r.ContactId, r);

        // ¡Calcular optativos!
        computeOptionalBlocks(planIdInternal, peIds, rowsByContact);
                buildCsv();
                return null;
         }

    private void clearResults(){
        rows = new List<RowVM>();
        studentsCount = 0;
        requirementsCount = (requirements == null) ? 0 : requirements.size();
        reqOkCounts = new Map<Id, Integer>();
        csvContent = '';
    }

    // ===== CSV matriz (ahora con Prénom y Nom)
    private void buildCsv(){
        List<String> headers = new List<String>();
        headers.add('Prénom');   // antes: Étudiant
        headers.add('Nom');
        headers.add('Email');
        headers.add('ID Contact');
        for (hed__Plan_Requirement__c pr : requirements) {
            headers.add( (pr.hed__Course__r != null ? pr.hed__Course__r.Name : pr.Name) );
        }
        headers.add('Manquants');
        headers.add('% Avancement');
        headers.add('Dernier cours');
        headers.add('7+ ans');

        List<String> lines = new List<String>();
        lines.add(toCsv(headers));

        for (RowVM r : rows) {
            List<String> cells = new List<String>();
            cells.add(r.FirstName);
            cells.add(r.LastName);
            cells.add(r.Email);
            cells.add(r.ContactExternalId);
            for (hed__Plan_Requirement__c pr : requirements) {
                cells.add( r.mapReqToOk.get(pr.Id) ? '✔' : '✖' );
            }
            cells.add(String.valueOf(r.MissingCount));
            cells.add(String.valueOf((Integer)r.ProgressPercent.intValue()) + '%');
            cells.add( r.LastCourseDate == null ? '' : r.LastCourseDate.format() );
            cells.add( r.OlderThan7Years ? '⛔' : '✅' );
            lines.add(toCsv(cells));
        }
        csvContent = String.join(lines, '\n');
    }

    private static String toCsv(List<String> cells){
        List<String> out = new List<String>();
        for (String s : cells) {
            String v = (s == null) ? '' : s;
            v = '"' + v.replace('"', '""') + '"';
            out.add(v);
        }
        return String.join(out, ',');
    }

    // Mapea Course Id -> lista de Requirement Ids
    private Map<Id, List<Id>> buildCourseToReqMap(){
        Map<Id, List<Id>> m = new Map<Id, List<Id>>();
        if (requirements == null) return m;
        for (hed__Plan_Requirement__c pr : requirements) {
            if (pr.hed__Course__c == null) continue;
            if (!m.containsKey(pr.hed__Course__c)) {
                m.put(pr.hed__Course__c, new List<Id>());
            }
            m.get(pr.hed__Course__c).add(pr.Id);
        }
        return m;
    }

    private class RowSorter implements Comparator<RowVM> {
        public Integer compare(RowVM a, RowVM b) {
            String la = a.LastName == null ? '' : a.LastName.toLowerCase();
            String lb = b.LastName == null ? '' : b.LastName.toLowerCase();
            if (la != lb) return la.compareTo(lb);
            String fa = a.FirstName == null ? '' : a.FirstName.toLowerCase();
            String fb = b.FirstName == null ? '' : b.FirstName.toLowerCase();
            return fa.compareTo(fb);
        }
    }

    // ===== Modal =====
    public PageReference openStudentDetailAction(){
        String cid = ApexPages.currentPage().getParameters().get('contactId');
        if (String.isBlank(cid)) return null;
        openStudentDetail(Id.valueOf(cid));
        return null;
    }
    public PageReference closeStudentDetail(){
        showDetail = false;
        selectedContactId = null;
        studentDetail = null;
        detailCsvContent = '';
        return null;
    }

    private void openStudentDetail(Id contactId){
        selectedContactId = contactId;
        if (requirements == null || requirements.isEmpty()) {
            runAudit();
        }
        Contact c = [
            SELECT Id, FirstName, LastName, Email, ID_Contact__c
            FROM Contact
            WHERE Id = :selectedContactId
            LIMIT 1
        ];

        // Build lookup for Course -> Requirements
        Map<Id, List<Id>> courseToReq = buildCourseToReqMap();

        // PE del contacto para el plan actual (si existe)
        hed__Program_Enrollment__c peForPlan = null;
        List<hed__Program_Enrollment__c> tmpPe = [
            SELECT Id
            FROM hed__Program_Enrollment__c
            WHERE hed__Contact__c = :selectedContactId
              AND hed__Program_Plan__c = :planIdInternal
            LIMIT 1
        ];
        if (!tmpPe.isEmpty()) peForPlan = tmpPe[0];
        
        // Course Enrollments filtrados por ese PE; si no hay, fallback por Contact
        List<hed__Course_Enrollment__c> ces = (peForPlan != null) ? [
            SELECT Id,
                   hed__Course_Offering__r.hed__Course__c,
                   hed__Course_Offering__r.hed__Course__r.Name,
                   hed__Course_Offering__r.hed__Term__r.Name,
                   hed__Course_Offering__r.hed__Term__r.hed__End_Date__c,
                   hed__Status__c,
                   Notations__c
            FROM hed__Course_Enrollment__c
            WHERE hed__Program_Enrollment__c = :peForPlan.Id
            ORDER BY hed__Course_Offering__r.hed__Term__r.hed__End_Date__c DESC
            LIMIT 5000
        ] : [
            SELECT Id,
                   hed__Course_Offering__r.hed__Course__c,
                   hed__Course_Offering__r.hed__Course__r.Name,
                   hed__Course_Offering__r.hed__Term__r.Name,
                   hed__Course_Offering__r.hed__Term__r.hed__End_Date__c,
                   hed__Status__c,
                   Notations__c
            FROM hed__Course_Enrollment__c
            WHERE hed__Contact__c = :selectedContactId
            ORDER BY hed__Course_Offering__r.hed__Term__r.hed__End_Date__c DESC
            LIMIT 5000
        ];


        Map<Id, Boolean> mapReqToOk = new Map<Id, Boolean>();
        Map<Id, String>  mapReqToTip = new Map<Id, String>();
        for (hed__Plan_Requirement__c pr : requirements) {
            mapReqToOk.put(pr.Id, false);
            mapReqToTip.put(pr.Id, 'No enrollment found');
        }

        Date latest = null;
        Integer completed = 0;

        for (hed__Course_Enrollment__c ce : ces) {
            Date d = (ce.hed__Course_Offering__r != null &&
                      ce.hed__Course_Offering__r.hed__Term__r != null)
                ? ce.hed__Course_Offering__r.hed__Term__r.hed__End_Date__c
                : null;
            if (d != null && (latest == null || d > latest)) latest = d;

            if (ce.hed__Course_Offering__r != null) {
                Id courseId = ce.hed__Course_Offering__r.hed__Course__c;
                String termName = (ce.hed__Course_Offering__r.hed__Term__r != null) ? ce.hed__Course_Offering__r.hed__Term__r.Name : '';
                String termEnd  = (ce.hed__Course_Offering__r.hed__Term__r != null && ce.hed__Course_Offering__r.hed__Term__r.hed__End_Date__c != null)
                                  ? ce.hed__Course_Offering__r.hed__Term__r.hed__End_Date__c.format() : '';
                String tip = 'Status: ' + (ce.hed__Status__c == null ? '' : ce.hed__Status__c)
                           + '\nNotation: ' + (ce.Notations__c == null ? '' : ce.Notations__c)
                           + '\nTerm: ' + (String.isBlank(termName) ? '' : termName) + (String.isBlank(termEnd) ? '' : ' (' + termEnd + ')');

                List<Id> reqIdsForCourse = courseToReq.get(courseId);
                if (reqIdsForCourse != null) {
                    for (Id prId : reqIdsForCourse) {
                        mapReqToTip.put(prId, tip);
                    }
                }
            }

            Boolean isOk = (ce.hed__Status__c == 'Completed') || hasOkNotation(ce.Notations__c);

            if (isOk && ce.hed__Course_Offering__r != null) {
                Id courseId2 = ce.hed__Course_Offering__r.hed__Course__c;
                List<Id> reqIds2 = courseToReq.get(courseId2);
                if (reqIds2 != null) {
                    for (Id prId : reqIds2) {
                        if (!mapReqToOk.get(prId)) { mapReqToOk.put(prId, true); completed++; }
                    }
                }
            }
        }

        List<CourseStatusVM> items = new List<CourseStatusVM>();
        for (hed__Plan_Requirement__c pr : requirements) {
            String courseName = (pr.hed__Course__r != null ? pr.hed__Course__r.Name : pr.Name);
            items.add(new CourseStatusVM(courseName, mapReqToOk.get(pr.Id), mapReqToTip.get(pr.Id)));
        }

        StudentDetailVM sd = new StudentDetailVM();
        sd.ContactId = c.Id;
        sd.FirstName = c.FirstName;
        sd.LastName  = c.LastName;
        sd.DisplayName =
            (c.FirstName != null ? c.FirstName + ' ' : '') +
            (c.LastName != null ? c.LastName : '');
        sd.Email = c.Email;
        sd.ContactExternalId = (c.ID_Contact__c == null ? '' : c.ID_Contact__c);
        sd.PlanName = getPlanName(planIdInternal);
        sd.MissingCount = requirements.size() - completed;
        sd.ProgressPercent = requirements.isEmpty() ? 0 : (Decimal.valueOf(completed) / requirements.size()) * 100;
        sd.LastCourseDate = latest;
        sd.OlderThan7Years = (latest != null) ? (latest.daysBetween(Date.today()) >= 2557) : false;
        sd.Courses = items;

        studentDetail = sd;
        buildDetailCsv(studentDetail);
        showDetail = true;
        
        // === Copiar mapas de optativos desde la fila del alumno hacia las props detail* ===
            if (detailOptTipByPrId == null)  detailOptTipByPrId  = new Map<Id, String>();
            if (detailOptEarnByPrId == null) detailOptEarnByPrId = new Map<Id, Decimal>();
            detailOptTipByPrId.clear();
            detailOptEarnByPrId.clear();
            
            if (rows != null && !rows.isEmpty()) {
                for (RowVM r : rows) {
                    if (r != null && r.ContactId == contactId) {
                        if (r.mapOptTipByPrId  != null) detailOptTipByPrId.putAll(r.mapOptTipByPrId);
                        if (r.mapOptEarnByPrId != null) detailOptEarnByPrId.putAll(r.mapOptEarnByPrId);
                        break;
                    }
                }
            }
            
        // === Defaults post-copia: garantiza claves para todos los bloques ===
                if (optBlocks != null) {
                    for (OptBlockDTO b : optBlocks) {
                        if (!detailOptTipByPrId.containsKey(b.prId))  detailOptTipByPrId.put(b.prId, '');
                        if (!detailOptEarnByPrId.containsKey(b.prId)) detailOptEarnByPrId.put(b.prId, 0);
                    }
                }
    }

    private String getPlanName(Id planId){
        if (String.isBlank(planId)) return '';
        hed__Program_Plan__c p = [
            SELECT Name FROM hed__Program_Plan__c WHERE Id = :planId LIMIT 1
        ];
        return p != null ? p.Name : '';
    }

    private void buildDetailCsv(StudentDetailVM sd){
        List<String> lines = new List<String>();
        // Encabezado con Prénom / Nom
        lines.add(toCsv(new List<String>{
            'Prénom','Nom','Email','ID Contact','Plan','% Avancement','Dernier cours','7+ ans','Manquants'
        }));
        // Fila de resumen
        lines.add(toCsv(new List<String>{
            (sd.FirstName == null ? '' : sd.FirstName),
            (sd.LastName  == null ? '' : sd.LastName),
            (sd.Email == null ? '' : sd.Email),
            (sd.ContactExternalId == null ? '' : sd.ContactExternalId),
            (sd.PlanName == null ? '' : sd.PlanName),
            String.valueOf((Integer)sd.ProgressPercent.intValue()) + '%',
            (sd.LastCourseDate == null ? '' : sd.LastCourseDate.format()),
            (sd.OlderThan7Years ? '⛔' : '✅'),
            String.valueOf(sd.MissingCount)
        }));
        // Separador visual
        lines.add('');
        // Detalle de cursos
        lines.add(toCsv(new List<String>{'Statut','Nom du cours'}));
        for (CourseStatusVM it : sd.Courses) {
            lines.add(toCsv(new List<String>{ it.IsOk ? '✔' : '✖', it.CourseName }));
        }
        detailCsvContent = String.join(lines, '\n');
    }

    // === Refrescar combo de Program Plan cuando cambie el filtro de estado ===
    public PageReference updatePlanOptions(){
        programPlanOptions = new List<SelectOption>();
        List<hed__Program_Plan__c> listP;
        if (planStatusFilter == null || planStatusFilter == 'ALL') {
            listP = [
                SELECT Id, Name, hed__Status__c
                FROM hed__Program_Plan__c
                WHERE Name NOT IN :EXCLUDED_PLAN_NAMES
                ORDER BY Name
                LIMIT 1000
            ];
        } else {
            listP = [
                SELECT Id, Name, hed__Status__c
                FROM hed__Program_Plan__c
                WHERE Name NOT IN :EXCLUDED_PLAN_NAMES
                  AND hed__Status__c = :planStatusFilter
                ORDER BY Name
                LIMIT 1000
            ];
        }
        for (hed__Program_Plan__c p : listP) {
            programPlanOptions.add(new SelectOption(p.Id, p.Name));
        }
        return null;
    }

            public PageReference choosePlanForAction(){
                // Validación básica
                if (String.isBlank(selectedStudentPlanId) || actionContactId == null){
                    ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Veuillez sélectionner un programme.'));
                    showDetail = false;
                    return null; // PPR
                }
            
                // Fija el plan y construye resultados
                planIdInternal = selectedStudentPlanId;
                runAudit();
                openStudentDetail(actionContactId);
            
                // Inicializa mapas si vinieran nulos
                if (detailOptTipByPrId == null)  detailOptTipByPrId  = new Map<Id, String>();
                if (detailOptEarnByPrId == null) detailOptEarnByPrId = new Map<Id, Decimal>();
            
                // Copia mapas de optativos
                detailOptTipByPrId.clear();
                detailOptEarnByPrId.clear();
                for (RowVM r : rows) {
                    if (r != null && r.ContactId == actionContactId) {
                        if (r.mapOptTipByPrId  != null) detailOptTipByPrId.putAll(r.mapOptTipByPrId);
                        if (r.mapOptEarnByPrId != null) detailOptEarnByPrId.putAll(r.mapOptEarnByPrId);
                        break;
                    }
                }
            
                // Defaults de optBlocks si faltara alguna clave
                if (optBlocks != null) {
                    for (OptBlockDTO b : optBlocks) {
                        if (!detailOptTipByPrId.containsKey(b.prId))  detailOptTipByPrId.put(b.prId, '');
                        if (!detailOptEarnByPrId.containsKey(b.prId)) detailOptEarnByPrId.put(b.prId, 0);
                    }
                }
            
                // Mostrar el panel de detalle en el rerender
                showDetail = true;
            
                // Importante: no redirigir, deja que el PPR pinte el detalle
                return null;
            }


    // ==========================================
// BLOQUES OPTATIVOS (nuevo)
// ==========================================

public class OptBlockDTO {
    public Id prId { get; set; }
    public String name { get; set; }
    public Decimal requiredCredits { get; set; }
    public Integer sequence { get; set; }

    public OptBlockDTO(Id prId, String name, Decimal requiredCredits, Integer sequence) {
        this.prId = prId;
        this.name = name;
        this.requiredCredits = (requiredCredits == null ? 0 : requiredCredits);
        this.sequence = (sequence == null ? 0 : sequence);
    }
}

public List<OptBlockDTO> optBlocks { get; set; }
public Boolean hasOptBlocks { get { return (optBlocks != null && !optBlocks.isEmpty()); } }

private void computeOptionalBlocks(Id programPlanId, Set<Id> peIds, Map<Id, RowVM> rows) {

    // 1) Padres
    List<hed__Plan_Requirement__c> parents = [
        SELECT Id, Name, hed__Credits__c, hed__Sequence__c, hed__Category__c
        FROM hed__Plan_Requirement__c
        WHERE hed__Program_Plan__c = :programPlanId
          AND hed__Course__c = NULL
        ORDER BY hed__Sequence__c NULLS LAST, Name
    ];

    // Si no hay, deja estructuras listas y sal
    if (parents.isEmpty()){
        optBlocks = new List<OptBlockDTO>();
        for (RowVM row : rows.values()){
            if (row.mapOptEarnByPrId == null) row.mapOptEarnByPrId = new Map<Id, Decimal>();
            if (row.mapOptTipByPrId  == null) row.mapOptTipByPrId  = new Map<Id, String>();
        }
        return;
    }

    // 2) Hijos por padre
    Map<Id, Set<Id>> mapParentCourses = new Map<Id, Set<Id>>();
    Map<Id, hed__Plan_Requirement__c> parentMap = new Map<Id, hed__Plan_Requirement__c>(parents);
    for (hed__Plan_Requirement__c c : [
        SELECT Id, hed__Course__c, hed__Plan_Requirement__c
        FROM hed__Plan_Requirement__c
        WHERE hed__Plan_Requirement__c IN :parentMap.keySet()
          AND hed__Course__c != NULL
    ]) {
        if (!mapParentCourses.containsKey(c.hed__Plan_Requirement__c))
            mapParentCourses.put(c.hed__Plan_Requirement__c, new Set<Id>());
        mapParentCourses.get(c.hed__Plan_Requirement__c).add(c.hed__Course__c);
    }

    // 2.1) Padres efectivos (optativos o “bucket sin hijos pero con créditos”)
    List<hed__Plan_Requirement__c> effectiveParents = new List<hed__Plan_Requirement__c>();
    for (hed__Plan_Requirement__c p : parents) {
        Boolean isOptional = (p.hed__Category__c == 'Optional' || p.hed__Category__c == 'Optionnel');
        Boolean hasChildren = mapParentCourses.containsKey(p.Id) && !mapParentCourses.get(p.Id).isEmpty();
        Boolean hasCredits  = (p.hed__Credits__c != null && p.hed__Credits__c > 0);
        if (isOptional || (!hasChildren && hasCredits)) effectiveParents.add(p);
    }

    // 3) DTOs visibles en la VF
    optBlocks = new List<OptBlockDTO>();
    for (hed__Plan_Requirement__c p : effectiveParents) {
        optBlocks.add(new OptBlockDTO(p.Id, p.Name, p.hed__Credits__c, (Integer)p.hed__Sequence__c));
    }

    // 4) Defaults en cada fila
    for (RowVM row : rows.values()) {
        if (row.mapOptEarnByPrId == null) row.mapOptEarnByPrId = new Map<Id, Decimal>();
        if (row.mapOptTipByPrId  == null) row.mapOptTipByPrId  = new Map<Id, String>();
        for (OptBlockDTO b : optBlocks) {
            if (!row.mapOptEarnByPrId.containsKey(b.prId)) row.mapOptEarnByPrId.put(b.prId, 0);
            if (!row.mapOptTipByPrId.containsKey(b.prId))  row.mapOptTipByPrId.put(b.prId, '');
        }
    }

    // 5) CE del mismo PE con créditos > 0
    List<hed__Course_Enrollment__c> ceList = [
        SELECT Id, hed__Program_Enrollment__c, hed__Credits_Earned__c,
               hed__Course_Offering__r.hed__Course__c,
               Course_Name__c, Terms__c, Notations__c
        FROM hed__Course_Enrollment__c
        WHERE hed__Program_Enrollment__c IN :peIds
          AND hed__Credits_Earned__c > 0
    ];
    Map<Id, List<hed__Course_Enrollment__c>> ceByPe = new Map<Id, List<hed__Course_Enrollment__c>>();
    for (hed__Course_Enrollment__c ce : ceList) {
        Id peId = ce.hed__Program_Enrollment__c;
        if (!ceByPe.containsKey(peId)) ceByPe.put(peId, new List<hed__Course_Enrollment__c>());
        ceByPe.get(peId).add(ce);
    }

    // 6) Asignación: “consume once”, SIN TOPE en el numerador
    for (RowVM row : rows.values()) {
    if (row.programEnrollmentId == null) continue;
    List<hed__Course_Enrollment__c> ceForStudent = ceByPe.get(row.programEnrollmentId);
    if (ceForStudent == null) continue;

    Set<Id> used = new Set<Id>(); // CE usados en cualquier bloque

    for (OptBlockDTO block : optBlocks) {
        Decimal earned = 0;
        String tip = '';
        Set<Id> validCourses = mapParentCourses.get(block.prId);

        if (validCourses != null && !validCourses.isEmpty()) {
            // Solo cursos del hijo; respeta “consume once”
            for (hed__Course_Enrollment__c ce : ceForStudent) {
                if (used.contains(ce.Id)) continue;
                Id courseId = (ce.hed__Course_Offering__r != null ? ce.hed__Course_Offering__r.hed__Course__c : null);
                if (courseId != null && validCourses.contains(courseId)) {
                    earned += ce.hed__Credits_Earned__c;

                    // ⬇️ Fallback de nombre para el tooltip
                    String nm = String.isBlank(ce.Course_Name__c)
                        ? (ce.hed__Course_Offering__r != null && ce.hed__Course_Offering__r.hed__Course__r != null
                            ? ce.hed__Course_Offering__r.hed__Course__r.Name
                            : '')
                        : ce.Course_Name__c;

                    tip += nm + ' · ' + ce.hed__Credits_Earned__c + 'u · ' +
                           (ce.Terms__c != null ? ce.Terms__c + ' ' : '') +
                           (ce.Notations__c != null ? '(' + ce.Notations__c + ')' : '') + '\n';
                    used.add(ce.Id);
                }
            }
        } else {
            // Bucket “libre”: toma lo que quede; SIN break ni tope
            for (hed__Course_Enrollment__c ce : ceForStudent) {
                if (used.contains(ce.Id)) continue;
                earned += ce.hed__Credits_Earned__c;

                // ⬇️ Fallback de nombre para el tooltip
                String nm = String.isBlank(ce.Course_Name__c)
                    ? (ce.hed__Course_Offering__r != null && ce.hed__Course_Offering__r.hed__Course__r != null
                        ? ce.hed__Course_Offering__r.hed__Course__r.Name
                        : '')
                    : ce.Course_Name__c;

                tip += nm + ' · ' + ce.hed__Credits_Earned__c + 'u · ' +
                       (ce.Terms__c != null ? ce.Terms__c + ' ' : '') +
                       (ce.Notations__c != null ? '(' + ce.Notations__c + ')' : '') + '\n';
                used.add(ce.Id);
            }
        }

        // ⭐ Publicar: 1 decimal y título (la VF agrega “ — earned / required”)
        row.mapOptEarnByPrId.put(block.prId, (earned == null ? 0 : earned.setScale(1)));
        row.mapOptTipByPrId.put(block.prId, tip.trim());
        }
    }
}


// Helper para mostrar X / Y
    public String getOptDisplay(Decimal earned, Decimal required) {
    if (required == null || required == 0) return earned.format() + ' / —';
    Decimal capped = (earned > required ? required : earned);
    return capped.format() + ' / ' + required.format();
}

// ===============================================
// == TEST SEED HELPERS (solo para @IsTest) ======
// ===============================================
@TestVisible
private class SeedIds {
    public Id planId;
    public Id contactId;
    public Id peId;
    public Id accountId;
    public Id optParentReqId;
}

/**
 * Estrategia:
 * 1) INTENTAR REUSAR DATOS REALES:
 *    - Cualquier PE con hed__Account__c != null y Plan con al menos 1 Requirement con Course.
 * 2) Si no hay, INTENTAR sembrar un dataset mínimo.
 * 3) Si el seed falla por validaciones del org, NO lanza: devolvemos nulos y los tests
 *    caen a los buscadores dinámicos (findUsablePlanId / findAnyContactForPlan).
 */
@TestVisible
private static SeedIds ensureTestSeed() {
    if (!Test.isRunningTest()) return null;

    SeedIds s = new SeedIds();

    // ========= 1) Reusar datos reales del org =========
    try {
        // Planes con al menos 1 requirement con Course
        Set<Id> planIdsWithReq = new Set<Id>();
        for (AggregateResult ar : [
            SELECT hed__Program_Plan__c pid, COUNT(Id) c
            FROM hed__Plan_Requirement__c
            WHERE hed__Course__c != NULL
            GROUP BY hed__Program_Plan__c
        ]) {
            planIdsWithReq.add((Id) ar.get('pid'));
        }

        if (!planIdsWithReq.isEmpty()) {
            // Un PE que tenga cuenta y plan válido
            hed__Program_Enrollment__c peAny = [
                SELECT Id, hed__Contact__c, hed__Program_Plan__c, hed__Account__c
                FROM hed__Program_Enrollment__c
                WHERE hed__Program_Plan__c IN :planIdsWithReq
                  AND hed__Contact__c != NULL
                  AND hed__Account__c != NULL
                ORDER BY LastModifiedDate DESC
                LIMIT 1
            ];

            if (peAny != null) {
                s.planId    = peAny.hed__Program_Plan__c;
                s.contactId = peAny.hed__Contact__c;
                s.peId      = peAny.Id;
                s.accountId = peAny.hed__Account__c;

                // Opcional: localizar un padre optativo si existe
                List<hed__Plan_Requirement__c> qOpt = [
                    SELECT Id
                    FROM hed__Plan_Requirement__c
                    WHERE hed__Program_Plan__c = :s.planId
                      AND (hed__Category__c = 'Optional' OR hed__Category__c = 'Optionnel')
                      AND hed__Course__c = NULL
                    ORDER BY hed__Sequence__c NULLS LAST, Name
                    LIMIT 1
                ];
                if (!qOpt.isEmpty()) s.optParentReqId = qOpt[0].Id;

                return s; // ✅ listo, sin crear nada
            }
        }
    } catch (Exception e) {
        // Ignora y pasa a intentar seed; no queremos romper @testSetup
    }

    // ========= 2) Intentar crear dataset mínimo =========
    try {
        // 2.1 Household
        Account hh = new Account(Name = 'SEED HH ' + Datetime.now().getTime());
        List<RecordType> rtHH = [
            SELECT Id
            FROM RecordType
            WHERE SObjectType = 'Account'
              AND (DeveloperName = 'HH_Account' OR DeveloperName = 'Household')
            LIMIT 1
        ];
        if (!rtHH.isEmpty()) hh.RecordTypeId = rtHH[0].Id;
        insert hh;

        // 2.2 Institucional (si tu org lo requiere para PE/CE, lo tendremos disponible)
        Account inst = new Account(Name = 'SEED INSTITUTION ' + Datetime.now().getTime());
        List<RecordType> rtInst = [
            SELECT Id
            FROM RecordType
            WHERE SObjectType = 'Account'
              AND (DeveloperName IN ('Educational_Institution','Institution','Academic_Program','Academic_Department'))
            LIMIT 1
        ];
        if (!rtInst.isEmpty()) inst.RecordTypeId = rtInst[0].Id;
        insert inst;

        // 2.3 Contact
        Contact con = new Contact(
            FirstName = 'Test',
            LastName  = 'Seed',
            Email     = 'seed@example.edu',
            AccountId = hh.Id
        );
        insert con;
        s.contactId = con.Id;

        // 2.4 Term/Courses/Offerings
        hed__Term__c term = new hed__Term__c(Name='SEED_TERM', hed__End_Date__c=Date.today());
        insert term;

        hed__Course__c cLeaf = new hed__Course__c(Name='SEED_C_LEAF');
        hed__Course__c cX    = new hed__Course__c(Name='SEED_C_X');
        hed__Course__c cY    = new hed__Course__c(Name='SEED_C_Y');
        insert new List<hed__Course__c>{ cLeaf, cX, cY };

        hed__Course_Offering__c offLeaf = new hed__Course_Offering__c(hed__Course__c=cLeaf.Id, hed__Term__c=term.Id);
        hed__Course_Offering__c offX    = new hed__Course_Offering__c(hed__Course__c=cX.Id,    hed__Term__c=term.Id);
        hed__Course_Offering__c offY    = new hed__Course_Offering__c(hed__Course__c=cY.Id,    hed__Term__c=term.Id);
        insert new List<hed__Course_Offering__c>{ offLeaf, offX, offY };

        // 2.5 Plan + Requirements
        hed__Program_Plan__c plan = new hed__Program_Plan__c(Name='SEED_PLAN', hed__Status__c='Current');
        insert plan;
        s.planId = plan.Id;

        hed__Plan_Requirement__c rLeaf = new hed__Plan_Requirement__c(
            Name='SEED_REQ_LEAF', hed__Program_Plan__c=plan.Id, hed__Course__c=cLeaf.Id, hed__Sequence__c=1
        );
        hed__Plan_Requirement__c rOptParent = new hed__Plan_Requirement__c(
            Name='SEED_REQ_OPT_PARENT', hed__Program_Plan__c=plan.Id,
            hed__Credits__c=4, hed__Category__c='Optional', hed__Sequence__c=10
        );
        insert new List<hed__Plan_Requirement__c>{ rLeaf, rOptParent };
        s.optParentReqId = rOptParent.Id;

        hed__Plan_Requirement__c rChildX = new hed__Plan_Requirement__c(
            Name='SEED_CHILD_X', hed__Program_Plan__c=plan.Id, hed__Course__c=cX.Id, hed__Plan_Requirement__c=rOptParent.Id
        );
        hed__Plan_Requirement__c rChildY = new hed__Plan_Requirement__c(
            Name='SEED_CHILD_Y', hed__Program_Plan__c=plan.Id, hed__Course__c=cY.Id, hed__Plan_Requirement__c=rOptParent.Id
        );
        insert new List<hed__Plan_Requirement__c>{ rChildX, rChildY };

        // 2.6 Elegir Account para PE/CE (institucional si existe; si no, HH)
        Id accId = (inst != null && inst.Id != null) ? inst.Id : con.AccountId;
        s.accountId = accId;

        // 2.7 Program Enrollment (PE) — OBLIGATORIO hed__Account__c
        hed__Program_Enrollment__c pe = new hed__Program_Enrollment__c(
            hed__Contact__c      = con.Id,
            hed__Program_Plan__c = plan.Id,
            hed__Account__c      = accId
        );
        insert pe;
        s.peId = pe.Id;

        // 2.8) Course Enrollments (CE) — también con hed__Account__c
        // Nota: ajusta <NOMBRE_CAMPO_NOTAS__c> al API real que usa tu controller para "notaciones".
        // En varias orgs SEMBEQ es Notations__c. Si tu controller llama hasOkNotation()
        // busca qué campo le pasa y usa ese.
        
        // ✅ OK directo por notación
        hed__Course_Enrollment__c ce1 = new hed__Course_Enrollment__c(
            hed__Contact__c            = con.Id,
            hed__Course_Offering__c    = offLeaf.Id,
            hed__Program_Enrollment__c = pe.Id,
            hed__Credits_Earned__c     = 1,
            hed__Account__c            = accId,
            hed__Status__c             = null,
            Notations__c               = 'R'          // <- sin cambios
        );
        
        // ✅ OK por equivalencia (sin acento)
        hed__Course_Enrollment__c ce2 = new hed__Course_Enrollment__c(
            hed__Contact__c            = con.Id,
            hed__Course_Offering__c    = offX.Id,
            hed__Program_Enrollment__c = pe.Id,
            hed__Credits_Earned__c     = 2,
            hed__Account__c            = accId,
            hed__Status__c             = null,
            Notations__c               = 'EQV'        // <- antes 'ÉQV' (corrige al valor del picklist)
        );
        
        // ❌ No-OK pero válido en el picklist (para cubrir la rama "false")
        hed__Course_Enrollment__c ce3 = new hed__Course_Enrollment__c(
            hed__Contact__c            = con.Id,
            hed__Course_Offering__c    = offY.Id,
            hed__Program_Enrollment__c = pe.Id,
            hed__Credits_Earned__c     = 2,
            hed__Account__c            = accId,
            hed__Status__c             = null,
            Notations__c               = 'INC'        // <- antes 'XYZ' (usa un valor existente que NO es OK)
        );
    
    insert new List<hed__Course_Enrollment__c>{ ce1, ce2, ce3 };

        return s; // ✅ seed creado
    } catch (DmlException dmle) {
        // ========= 3) Seed falló por validaciones del org: NO reventar =========
        // Devolvemos lo que haya (probablemente todo null). Los tests caen al uso de datos reales.
        return s;
    } catch (Exception e2) {
        return s;
    }
}

// Getters visibles a tests
@TestVisible public static Id testGetPlanId()      { SeedIds s = ensureTestSeed(); return s==null?null:s.planId; }
@TestVisible public static Id testGetContactId()   { SeedIds s = ensureTestSeed(); return s==null?null:s.contactId; }
@TestVisible public static Id testGetPeId()        { SeedIds s = ensureTestSeed(); return s==null?null:s.peId; }
@TestVisible public static Id testGetAccountId()   { SeedIds s = ensureTestSeed(); return s==null?null:s.accountId; }
@TestVisible public static Id testGetOptParentId() { SeedIds s = ensureTestSeed(); return s==null?null:s.optParentReqId; }

// ==== placeholders para futuras extensiones ====
@TestVisible private class TestDataIds {
    public Id planId; public Id contactId; public Id peId; public Id accountId; public Id optParentReqId;
}
@TestVisible private static TestDataIds prepareTestData() {
    if (!Test.isRunningTest()) return null;
    return new TestDataIds();
}


}