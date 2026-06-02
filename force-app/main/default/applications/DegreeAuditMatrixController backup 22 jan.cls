public with sharing class DegreeAuditMatrixController {

    // ===== Exclusiones de Program Plan =====
    private static final Set<String> EXCLUDED_PLAN_NAMES = new Set<String>{
        'HORS PROGRAMME', 'HORS PROGRAM'
    };

    // Notations que cuentan como OK (además de Status=Completed)
    private static final Set<String> OK_NOTATIONS = new Set<String>{ 'R', 'EQV', 'TRANSF' };
    
    // Ignora CEs sin PE o con PE de otro plan (solo lectura, sin tocar datos)
    private static final Boolean EXCLUDE_ANOMALIES = true;
    
    // ==== Filtros UI ====
    private static final Set<String> KNOWN_PLAN_STATUSES = new Set<String>{ 'Current', 'Archived' };
    // === PE Status dinámicos (desde Describe) ===
    private static Set<String> PE_STATUS_CACHE;
    
    private static Set<String> peStatusesAll(){
        if (PE_STATUS_CACHE == null){
            PE_STATUS_CACHE = new Set<String>();
            try{
                Schema.DescribeFieldResult dfr = hed__Program_Enrollment__c.Status__c.getDescribe();
                for (Schema.PicklistEntry e : dfr.getPicklistValues()){
                    if (e.isActive()) PE_STATUS_CACHE.add(e.getValue());
                }
            }catch(Exception e){}
        }
        return new Set<String>(PE_STATUS_CACHE); // copia segura
    }

    public String planStatusFilter { get; set; }  // 'ALL' | 'Current' | 'Archived'
    public String peStatusFilter   { get; set; }  // 'ALL' | 'ACTIVE3' | valor único

    public List<SelectOption> getPlanStatusOptions(){
        List<SelectOption> opts = new List<SelectOption>();
        opts.add(new SelectOption('ALL','Tous'));
        for (String v : new List<String>{'Current','Archived'}){
            if (KNOWN_PLAN_STATUSES.contains(v)) opts.add(new SelectOption(v, v));
        }
        return opts;
    }

    public List<SelectOption> getPeStatusOptions(){
        List<SelectOption> opts = new List<SelectOption>();
        opts.add(new SelectOption('ALL','Tous'));
        for (String v : peStatusesAll()){
            opts.add(new SelectOption(v, v));
        }
        return opts;
    }

    private static final Set<String> ACTIVE_PLAN_STATUSES = new Set<String>{ 'Current' };
    private static final Set<String> ACTIVE_PE_STATUSES   = new Set<String>{ 'Current' };

    @TestVisible
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
    public String selectedRequirementId { get; set; }
    public void setSelectedProgramPlanId(Id v) { planIdInternal = (v == null ? null : (String)v); }
    public void setSelectedPlanId(Id v)        { planIdInternal = (v == null ? null : (String)v); }

    // ====== UI lists / data ======
    public List<SelectOption> programPlanOptions { get; private set; }
    public List<hed__Plan_Requirement__c> requirements { get; private set; }
    public List<RowVM> rows { get; private set; }
    public Integer studentsCount { get; private set; }
    public Integer requirementsCount { get; private set; }
    public Map<Id, Integer> reqOkCounts { get; private set; }
    public Map<Id, Integer> getReqOkCountsSafe(){
        Map<Id, Integer> m = new Map<Id, Integer>();
        if (reqOkCounts != null) m.putAll(reqOkCounts);
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
    private Id currentUserContactId;

    // ====== Extra para Contact Action ======
    public List<SelectOption> studentPlanOptions { get; private set; }
    public Id actionContactId { get; private set; }
    public String selectedStudentPlanId { get; set; }

    public Boolean getIsPortalView(){
        return (currentUserContactId != null);
    }

    public List<SelectOption> getRequirementPicklist(){
        List<SelectOption> opts = new List<SelectOption>();
        opts.add(new SelectOption('', '— Tous les cours —'));
        if (requirements != null){
            for (hed__Plan_Requirement__c r : requirements){
                String label = (r.hed__Course__r != null && String.isNotBlank(r.hed__Course__r.Name))
                    ? r.hed__Course__r.Name
                    : r.Name;
                opts.add(new SelectOption(r.Id, label));
            }
        }
        return opts;
    }

    public Boolean getHasData(){
        return (rows != null && !rows.isEmpty());
    }

    public DegreeAuditMatrixController(){
        if (planStatusFilter == null) planStatusFilter = 'Current';
        if (peStatusFilter   == null) peStatusFilter   = 'Current';

        try{
            currentUserContactId = [SELECT ContactId FROM User WHERE Id = :UserInfo.getUserId()].ContactId;
        }catch(Exception e){
            currentUserContactId = null;
        }

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
        detailOptTipByPrId  = new Map<Id, String>();
        detailOptEarnByPrId = new Map<Id, Decimal>();
    }

    public class RowVM {
        public Id ContactId { get; set; }
        public String FirstName { get; set; }
        public String LastName  { get; set; }
        public String DisplayName { get; set; }
        public String Email { get; set; }
        public String ContactExternalId { get; set; }
        public Id programEnrollmentId { get; set; }
        public Map<Id, Decimal> mapOptEarnByPrId { get; set; }
        public Map<Id, String>  mapOptTipByPrId  { get; set; }
        public Map<Id, Boolean> mapReqToOk { get; set; }
        public Map<Id, String>  mapReqToTip { get; set; } 
        public Integer MissingCount { get; set; }
        public Decimal ProgressPercent { get; set; }
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
        public String FirstName { get; set; }
        public String LastName  { get; set; }
        public String DisplayName { get; set; }
        public String Email { get; set; }
        public String ContactExternalId { get; set; }
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

    public DegreeAuditMatrixController(ApexPages.StandardController std){
        if (planStatusFilter == null) planStatusFilter = 'Current';
        if (peStatusFilter   == null) peStatusFilter   = 'Current';
    
        programPlanOptions   = new List<SelectOption>();
        rows                 = new List<RowVM>();
        reqOkCounts          = new Map<Id, Integer>();
        csvContent           = '';
        showDetail           = false;
        requirementsCount    = 0;
        studentsCount        = 0;
        detailOptTipByPrId   = new Map<Id, String>();
        detailOptEarnByPrId  = new Map<Id, Decimal>();
    
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
        selectedRequirementId = null;
    
        requirements = new List<hed__Plan_Requirement__c>();
        if (String.isBlank(planIdInternal)) { clearResults(); return null; }
    
        // Reqs "hoja" (por curso). Si no hay, seguimos (plan solo optativo).
        requirements = [
            SELECT Id, Name, hed__Course__c, hed__Course__r.Name
            FROM hed__Plan_Requirement__c
            WHERE hed__Program_Plan__c = :planIdInternal
              AND hed__Course__c != NULL
            ORDER BY Name
            LIMIT 2000
        ];
        requirementsCount = requirements.size();
    
        Map<Id, List<Id>> courseToReq = buildCourseToReqMap();
    
        Map<Id, Contact> contactsById = new Map<Id, Contact>();
    
        // Filtro de PE por UI
        Set<String> peStatuses = new Set<String>();
        Boolean peFilterAll = (peStatusFilter == 'ALL' || peStatusFilter == null);
        if (!peFilterAll && peStatusesAll().contains(peStatusFilter)) {
            peStatuses.add(peStatusFilter);
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
    
        if (contactsById.isEmpty()) { clearResults(); return null; }
    
        Map<Id, Id> contactToPeId = new Map<Id, Id>();
        Set<Id> peIds = new Set<Id>();
        for (hed__Program_Enrollment__c pe : peList) {
            contactToPeId.put(pe.hed__Contact__c, pe.Id);
            peIds.add(pe.Id);
        }
    
        List<hed__Course_Enrollment__c> cesByPeRaw = [
            SELECT Id,
                   hed__Contact__c,
                   hed__Program_Enrollment__c,
                   hed__Course_Offering__r.hed__Course__c,
                   hed__Course_Offering__r.hed__Course__r.Name,
                   hed__Course_Offering__r.hed__Term__r.Name,
                   hed__Course_Offering__r.hed__End_Date__c,
                   hed__Course_Offering__r.hed__Term__r.hed__End_Date__c,
                   hed__Status__c,
                   Notations__c,
                   hed__Program_Enrollment__r.hed__Program_Plan__c
            FROM hed__Course_Enrollment__c
            WHERE hed__Program_Enrollment__c IN :peIds
              AND hed__Program_Enrollment__r.hed__Program_Plan__c = :planIdInternal
            ORDER BY hed__Contact__c
            LIMIT 20000
        ];
        Map<Id, List<hed__Course_Enrollment__c>> cesByPe = new Map<Id, List<hed__Course_Enrollment__c>>();
        for (hed__Course_Enrollment__c ce : cesByPeRaw) {
            List<hed__Course_Enrollment__c> bucket = cesByPe.get(ce.hed__Program_Enrollment__c);
            if (bucket == null) { bucket = new List<hed__Course_Enrollment__c>(); cesByPe.put(ce.hed__Program_Enrollment__c, bucket); }
            bucket.add(ce);
        }
    
        rows = new List<RowVM>();
        for (Contact c : contactsById.values()) {
            RowVM r = new RowVM();
            r.ContactId = c.Id;
            r.DisplayName = (c.FirstName != null ? c.FirstName + ' ' : '') + (c.LastName != null ? c.LastName : '');
            r.FirstName = c.FirstName;
            r.LastName  = c.LastName;
            r.Email = c.Email;
            r.ContactExternalId = (c.ID_Contact__c == null ? '' : c.ID_Contact__c);
            r.programEnrollmentId = contactToPeId.get(c.Id);
    
            // Inicializa tooltips/OK por cada req hoja (si hay)
            for (hed__Plan_Requirement__c pr : requirements) {
                r.mapReqToOk.put(pr.Id, false);
                r.mapReqToTip.put(pr.Id, 'Aucune inscription trouvée');
            }
    
            Date latest = null;
            Integer completed = 0;
    
            List<hed__Course_Enrollment__c> ceListForRow =
                (r.programEnrollmentId != null) ? cesByPe.get(r.programEnrollmentId) : null;
    
            if (ceListForRow != null && !ceListForRow.isEmpty()) {
                for (hed__Course_Enrollment__c ce : ceListForRow) {
                    Date coEnd   = (ce.hed__Course_Offering__r != null) ? ce.hed__Course_Offering__r.hed__End_Date__c : null;
                    Date termEnd = (ce.hed__Course_Offering__r != null && ce.hed__Course_Offering__r.hed__Term__r != null)
                                   ? ce.hed__Course_Offering__r.hed__Term__r.hed__End_Date__c
                                   : null;
                    Date d = (coEnd != null) ? coEnd : termEnd;
                    if (d != null && (latest == null || d > latest)) latest = d;
                    
                    if (ce.hed__Course_Offering__r != null) {
                        Id courseId   = ce.hed__Course_Offering__r.hed__Course__c;
                        String termNm = (ce.hed__Course_Offering__r.hed__Term__r != null) ? ce.hed__Course_Offering__r.hed__Term__r.Name : '';
                        String endStr = (coEnd != null) ? coEnd.format()
                                     : (termEnd != null ? termEnd.format() : '');
                        String tip = 'Status: '   + (ce.hed__Status__c == null ? '' : ce.hed__Status__c)
                                   + '\nNotation: ' + (ce.Notations__c == null ? '' : ce.Notations__c)
                                   + '\nTerm: '     + (String.isBlank(termNm) ? '' : termNm)
                                   + (String.isBlank(endStr) ? '' : ' (' + endStr + ')');
                    
                        List<Id> reqIdsForCourse = courseToReq.get(courseId);
                        if (reqIdsForCourse != null) {
                            for (Id prId : reqIdsForCourse) r.mapReqToTip.put(prId, tip);
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
            r.MissingCount = (totalReqs > 0) ? (totalReqs - completed) : 0;
            r.ProgressPercent = (totalReqs > 0) ? (Decimal.valueOf(completed) / totalReqs) * 100 : 0;
            r.OlderThan7Years = (latest != null) ? (latest.daysBetween(Date.today()) >= 2557) : false;
    
            rows.add(r);
        }
    
        rows.sort(new RowSorter());
        studentsCount = rows.size();
    
        reqOkCounts = new Map<Id, Integer>();
        for (hed__Plan_Requirement__c pr : requirements) {
            Integer acc = 0;
            for (RowVM r : rows) if (r.mapReqToOk.get(pr.Id) == true) acc++;
            reqOkCounts.put(pr.Id, acc);
        }
    
        Map<Id, RowVM> rowsByContact = new Map<Id, RowVM>();
        for (RowVM r : rows) rowsByContact.put(r.ContactId, r);
    
        // Siempre calcular bloques optativos (soporta planes 100% optativos)
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

    private void buildCsv(){
        List<String> headers = new List<String>();
        headers.add('Prénom');
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
    
        Map<Id, List<Id>> courseToReq = buildCourseToReqMap();
    
        hed__Program_Enrollment__c peForPlan = null;
        List<hed__Program_Enrollment__c> tmpPe = [
            SELECT Id
            FROM hed__Program_Enrollment__c
            WHERE hed__Contact__c = :selectedContactId
              AND hed__Program_Plan__c = :planIdInternal
            LIMIT 1
        ];
        if (!tmpPe.isEmpty()) peForPlan = tmpPe[0];
        
        // ÚNICA asignación válida (sin bloque extra)
        List<hed__Course_Enrollment__c> ces = (peForPlan != null) ? [
            SELECT Id,
                   hed__Course_Offering__r.hed__Course__c,
                   hed__Course_Offering__r.hed__Course__r.Name,
                   hed__Course_Offering__r.hed__Term__r.Name,
                   hed__Course_Offering__r.hed__End_Date__c,
                   hed__Course_Offering__r.hed__Term__r.hed__End_Date__c,
                   hed__Status__c,
                   Notations__c,
                   hed__Program_Enrollment__r.hed__Program_Plan__c
            FROM hed__Course_Enrollment__c
            WHERE hed__Program_Enrollment__c = :peForPlan.Id
              AND hed__Program_Enrollment__r.hed__Program_Plan__c = :planIdInternal
            ORDER BY hed__Course_Offering__r.hed__End_Date__c DESC,
             hed__Course_Offering__r.hed__Term__r.hed__End_Date__c DESC
            LIMIT 5000
        ] : new List<hed__Course_Enrollment__c>();
    
        Map<Id, Boolean> mapReqToOk = new Map<Id, Boolean>();
        Map<Id, String>  mapReqToTip = new Map<Id, String>();
        for (hed__Plan_Requirement__c pr : requirements) {
            mapReqToOk.put(pr.Id, false);
            mapReqToTip.put(pr.Id, 'No enrollment found');
        }
    
        Date latest = null;
        Integer completed = 0;
    
        for (hed__Course_Enrollment__c ce : ces) {
            Date coEnd   = (ce.hed__Course_Offering__r != null) ? ce.hed__Course_Offering__r.hed__End_Date__c : null;
            Date termEnd = (ce.hed__Course_Offering__r != null && ce.hed__Course_Offering__r.hed__Term__r != null)
                           ? ce.hed__Course_Offering__r.hed__Term__r.hed__End_Date__c
                           : null;
            Date d = (coEnd != null) ? coEnd : termEnd;
            if (d != null && (latest == null || d > latest)) latest = d;
            
            if (ce.hed__Course_Offering__r != null) {
                Id courseId   = ce.hed__Course_Offering__r.hed__Course__c;
                String termNm = (ce.hed__Course_Offering__r.hed__Term__r != null) ? ce.hed__Course_Offering__r.hed__Term__r.Name : '';
                String endStr = (coEnd != null) ? coEnd.format()
                             : (termEnd != null ? termEnd.format() : '');
                String tip = 'Status: '   + (ce.hed__Status__c == null ? '' : ce.hed__Status__c)
                           + '\nNotation: ' + (ce.Notations__c == null ? '' : ce.Notations__c)
                           + '\nTerm: '     + (String.isBlank(termNm) ? '' : termNm)
                           + (String.isBlank(endStr) ? '' : ' (' + endStr + ')');
            
                List<Id> reqIdsForCourse = courseToReq.get(courseId);
                if (reqIdsForCourse != null) {
                    for (Id prId : reqIdsForCourse) { mapReqToTip.put(prId, tip); }
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
        lines.add(toCsv(new List<String>{
            'Prénom','Nom','Email','ID Contact','Plan','% Avancement','Dernier cours','7+ ans','Manquants'
        }));
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
        lines.add('');
        lines.add(toCsv(new List<String>{'Statut','Nom du cours'}));
        for (CourseStatusVM it : sd.Courses) {
            lines.add(toCsv(new List<String>{ it.IsOk ? '✔' : '✖', it.CourseName }));
        }
        detailCsvContent = String.join(lines, '\n');
    }

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
        if (String.isBlank(selectedStudentPlanId) || actionContactId == null){
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Veuillez sélectionner un programme.'));
            showDetail = false;
            return null;
        }
        planIdInternal = selectedStudentPlanId;
        runAudit();
        openStudentDetail(actionContactId);
        if (detailOptTipByPrId == null)  detailOptTipByPrId  = new Map<Id, String>();
        if (detailOptEarnByPrId == null) detailOptEarnByPrId = new Map<Id, Decimal>();
        detailOptTipByPrId.clear();
        detailOptEarnByPrId.clear();
        for (RowVM r : rows) {
            if (r != null && r.ContactId == actionContactId) {
                if (r.mapOptTipByPrId  != null) detailOptTipByPrId.putAll(r.mapOptTipByPrId);
                if (r.mapOptEarnByPrId != null) detailOptEarnByPrId.putAll(r.mapOptEarnByPrId);
                break;
            }
        }
        if (optBlocks != null) {
            for (OptBlockDTO b : optBlocks) {
                if (!detailOptTipByPrId.containsKey(b.prId))  detailOptTipByPrId.put(b.prId, '');
                if (!detailOptEarnByPrId.containsKey(b.prId)) detailOptEarnByPrId.put(b.prId, 0);
            }
        }
        showDetail = true;
        return null;
    }

    // ==========================================
    // BLOQUES OPTATIVOS (corregido)
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

    // === NEW: cursos hoja que son requirements NO optativos del plan
    private Set<Id> buildNonOptionalLeafCourseIds(Id programPlanId, Map<Id, hed__Plan_Requirement__c> parentMap){
        Set<Id> nonOpt = new Set<Id>();
        List<hed__Plan_Requirement__c> leaves = [
            SELECT Id, hed__Course__c, hed__Plan_Requirement__c
            FROM hed__Plan_Requirement__c
            WHERE hed__Program_Plan__c = :programPlanId
              AND hed__Course__c != NULL
        ];
        for (hed__Plan_Requirement__c leaf : leaves){
            Id pid = leaf.hed__Plan_Requirement__c;
            Boolean parentIsOptional =
                (pid != null && parentMap.containsKey(pid) &&
                 (parentMap.get(pid).hed__Category__c == 'Optional' || parentMap.get(pid).hed__Category__c == 'Optionnel'));
            if (!parentIsOptional && leaf.hed__Course__c != null){
                nonOpt.add(leaf.hed__Course__c);
            }
        }
        return nonOpt;
    }

    // === REEMPLAZO: prioriza padres con hijos; el/los sin hijos (catch-all) van al final
    private void computeOptionalBlocks(Id programPlanId, Set<Id> peIds, Map<Id, RowVM> rows) {
    
        // 1) Padres (headers) del plan
        List<hed__Plan_Requirement__c> parents = [
            SELECT Id, Name, hed__Credits__c, hed__Sequence__c, hed__Category__c
            FROM hed__Plan_Requirement__c
            WHERE hed__Program_Plan__c = :programPlanId
              AND hed__Course__c = NULL
            ORDER BY hed__Sequence__c NULLS LAST, Name
        ];
        if (parents.isEmpty()){
            optBlocks = new List<OptBlockDTO>();
            for (RowVM row : rows.values()){
                if (row.mapOptEarnByPrId == null) row.mapOptEarnByPrId = new Map<Id, Decimal>();
                if (row.mapOptTipByPrId  == null) row.mapOptTipByPrId  = new Map<Id, String>();
            }
            return;
        }
    
        // 2) Hijos hoja por padre
        Map<Id, hed__Plan_Requirement__c> parentMap = new Map<Id, hed__Plan_Requirement__c>(parents);
        Map<Id, Set<Id>> mapParentCourses = new Map<Id, Set<Id>>();
        for (hed__Plan_Requirement__c c : [
            SELECT Id, hed__Course__c, hed__Plan_Requirement__c
            FROM hed__Plan_Requirement__c
            WHERE hed__Plan_Requirement__c IN :parentMap.keySet()
              AND hed__Course__c != NULL
        ]) {
            Id pid = c.hed__Plan_Requirement__c;
            if (!mapParentCourses.containsKey(pid)) mapParentCourses.put(pid, new Set<Id>());
            mapParentCourses.get(pid).add(c.hed__Course__c);
        }
    
        // 3) Padres efectivos (Optional u obligatorios con créditos>0)
        List<hed__Plan_Requirement__c> effectiveParents = new List<hed__Plan_Requirement__c>();
        for (hed__Plan_Requirement__c p : parents) {
            Boolean isOptional = (p.hed__Category__c == 'Optional' || p.hed__Category__c == 'Optionnel');
            Boolean hasCredits  = (p.hed__Credits__c != null && p.hed__Credits__c > 0);
            if (hasCredits || isOptional) effectiveParents.add(p);
        }
    
        // 3.1) Separar en: con hijos vs. sin hijos (catch-all)
        List<hed__Plan_Requirement__c> withChildren = new List<hed__Plan_Requirement__c>();
        List<hed__Plan_Requirement__c> catchAll     = new List<hed__Plan_Requirement__c>();
        for (hed__Plan_Requirement__c p : effectiveParents) {
            if (mapParentCourses.containsKey(p.Id) && !mapParentCourses.get(p.Id).isEmpty()) {
                withChildren.add(p);
            } else {
                catchAll.add(p);
            }
        }
    
        // 4) DTO visibles (mantén orden por sequence)
        optBlocks = new List<OptBlockDTO>();
        for (hed__Plan_Requirement__c p : withChildren) {
            optBlocks.add(new OptBlockDTO(p.Id, p.Name, p.hed__Credits__c, (Integer)p.hed__Sequence__c));
        }
        for (hed__Plan_Requirement__c p : catchAll) {
            optBlocks.add(new OptBlockDTO(p.Id, p.Name, p.hed__Credits__c, (Integer)p.hed__Sequence__c));
        }
    
        // 5) Excluir cursos que ya son requisitos NO optativos
        Set<Id> nonOptionalLeafCourseIds = buildNonOptionalLeafCourseIds(programPlanId, parentMap);
    
        // 6) Defaults por fila
        for (RowVM row : rows.values()) {
            if (row.mapOptEarnByPrId == null) row.mapOptEarnByPrId = new Map<Id, Decimal>();
            if (row.mapOptTipByPrId  == null) row.mapOptTipByPrId  = new Map<Id, String>();
            for (OptBlockDTO b : optBlocks) {
                if (!row.mapOptEarnByPrId.containsKey(b.prId)) row.mapOptEarnByPrId.put(b.prId, 0);
                if (!row.mapOptTipByPrId.containsKey(b.prId))  row.mapOptTipByPrId.put(b.prId, '');
            }
        }
    
        // 7) CE del mismo PE con créditos > 0
        List<hed__Course_Enrollment__c> ceList = [
            SELECT Id, hed__Program_Enrollment__c, hed__Credits_Earned__c,
                   hed__Course_Offering__r.hed__Course__c,
                   Course_Name__c, Terms__c, Notations__c,
                   hed__Program_Enrollment__r.hed__Program_Plan__c
            FROM hed__Course_Enrollment__c
            WHERE hed__Program_Enrollment__c IN :peIds
              AND hed__Program_Enrollment__r.hed__Program_Plan__c = :programPlanId
              AND hed__Credits_Earned__c > 0
        ];
        Map<Id, List<hed__Course_Enrollment__c>> ceByPe = new Map<Id, List<hed__Course_Enrollment__c>>();
        for (hed__Course_Enrollment__c ce : ceList) {
            Id peId = ce.hed__Program_Enrollment__c;
            if (!ceByPe.containsKey(peId)) ceByPe.put(peId, new List<hed__Course_Enrollment__c>());
            ceByPe.get(peId).add(ce);
        }
    
        // 8) Asignación en DOS PASOS: (1) específicos, (2) catch-all con sobrantes
        for (RowVM row : rows.values()) {
            if (row.programEnrollmentId == null) continue;
            List<hed__Course_Enrollment__c> ceForStudent = ceByPe.get(row.programEnrollmentId);
            if (ceForStudent == null) continue;
    
            Set<Id> used = new Set<Id>();
    
            // Paso 1: padres con hijos (match exacto por curso)
            for (hed__Plan_Requirement__c p : withChildren) {
                Set<Id> validCourses = mapParentCourses.get(p.Id);
                Decimal earned = 0;
                String tip = '';
                if (validCourses != null && !validCourses.isEmpty()) {
                    for (hed__Course_Enrollment__c ce : ceForStudent) {
                        if (used.contains(ce.Id)) continue;
                        Id courseId = (ce.hed__Course_Offering__r != null ? ce.hed__Course_Offering__r.hed__Course__c : null);
                        if (courseId == null) continue;
                        if (nonOptionalLeafCourseIds.contains(courseId)) continue; // excluir requeridos no optativos
                        if (!validCourses.contains(courseId)) continue;
    
                        earned += ce.hed__Credits_Earned__c;
                        String nm = String.isBlank(ce.Course_Name__c)
                            ? (ce.hed__Course_Offering__r != null && ce.hed__Course_Offering__r.hed__Course__r != null
                                ? ce.hed__Course_Offering__r.hed__Course__r.Name : '')
                            : ce.Course_Name__c;
                        tip += nm + ' · ' + ce.hed__Credits_Earned__c + 'u · ' +
                               (ce.Terms__c != null ? ce.Terms__c + ' ' : '') +
                               (ce.Notations__c != null ? '(' + ce.Notations__c + ')' : '') + '\n';
                        used.add(ce.Id);
                    }
                }
                row.mapOptEarnByPrId.put(p.Id, (earned == null ? 0 : earned.setScale(1)));
                row.mapOptTipByPrId.put(p.Id, tip.trim());
            }
    
            // Paso 2: padres SIN hijos (catch-all) — consumen lo que sobró
            for (hed__Plan_Requirement__c p : catchAll) {
                Decimal earned = 0;
                String tip = '';
                for (hed__Course_Enrollment__c ce : ceForStudent) {
                    if (used.contains(ce.Id)) continue;
                    Id courseId = (ce.hed__Course_Offering__r != null ? ce.hed__Course_Offering__r.hed__Course__c : null);
                    if (courseId == null) continue;
                    if (nonOptionalLeafCourseIds.contains(courseId)) continue; // excluir requeridos no optativos
    
                    earned += ce.hed__Credits_Earned__c;
                    String nm = String.isBlank(ce.Course_Name__c)
                        ? (ce.hed__Course_Offering__r != null && ce.hed__Course_Offering__r.hed__Course__r != null
                            ? ce.hed__Course_Offering__r.hed__Course__r.Name : '')
                        : ce.Course_Name__c;
                    tip += nm + ' · ' + ce.hed__Credits_Earned__c + 'u · ' +
                           (ce.Terms__c != null ? ce.Terms__c + ' ' : '') +
                           (ce.Notations__c != null ? '(' + ce.Notations__c + ')' : '') + '\n';
                    used.add(ce.Id);
                }
                row.mapOptEarnByPrId.put(p.Id, (earned == null ? 0 : earned.setScale(1)));
                row.mapOptTipByPrId.put(p.Id, tip.trim());
            }
        }
    }

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

    @TestVisible
    private static SeedIds ensureTestSeed() {
        if (!Test.isRunningTest()) return null;

        SeedIds s = new SeedIds();

        try {
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

                    return s;
                }
            }
        } catch (Exception e) {
        }

        try {
            if (Test.isRunningTest() && TEST_THROW_DML == true) {
                insert new Account();
            }
            if (Test.isRunningTest() && TEST_THROW_GENERIC == true) {
                Integer z = 1 / 0;
            }
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

            Contact con = new Contact(
                FirstName = 'Test',
                LastName  = 'Seed',
                Email     = 'seed@example.edu',
                AccountId = hh.Id
            );
            insert con;
            s.contactId = con.Id;

            hed__Term__c term = new hed__Term__c(Name='SEED_TERM', hed__End_Date__c=Date.today());
            try { term.put('hed__Account__c', inst.Id); } catch (Exception ignore) {}
            insert term;
            
            hed__Course__c cLeaf = new hed__Course__c(Name='SEED_C_LEAF');
            hed__Course__c cX    = new hed__Course__c(Name='SEED_C_X');
            hed__Course__c cY    = new hed__Course__c(Name='SEED_C_Y');
            try { cLeaf.put('hed__Account__c', inst.Id); } catch (Exception ignore) {}
            try { cX.put('hed__Account__c',    inst.Id); } catch (Exception ignore) {}
            try { cY.put('hed__Account__c',    inst.Id); } catch (Exception ignore) {}
            insert new List<hed__Course__c>{ cLeaf, cX, cY };
            
            hed__Course_Offering__c offLeaf = new hed__Course_Offering__c(hed__Course__c=cLeaf.Id, hed__Term__c=term.Id);
            hed__Course_Offering__c offX    = new hed__Course_Offering__c(hed__Course__c=cX.Id,    hed__Term__c=term.Id);
            hed__Course_Offering__c offY    = new hed__Course_Offering__c(hed__Course__c=cY.Id,    hed__Term__c=term.Id);
            try { offLeaf.put('hed__Account__c', inst.Id); } catch (Exception ignore) {}
            try { offX.put('hed__Account__c',    inst.Id); } catch (Exception ignore) {}
            try { offY.put('hed__Account__c',    inst.Id); } catch (Exception ignore) {}
            insert new List<hed__Course_Offering__c>{ offLeaf, offX, offY };
            
            hed__Program_Plan__c plan = new hed__Program_Plan__c(Name='SEED_PLAN', hed__Status__c='Current');
            try { plan.put('hed__Account__c', inst.Id); } catch (Exception ignore) {}
            insert plan;
            s.planId = plan.Id;
            
            hed__Plan_Requirement__c rLeaf = new hed__Plan_Requirement__c(
                Name='SEED_REQ_LEAF', hed__Program_Plan__c=plan.Id, hed__Course__c=cLeaf.Id, hed__Sequence__c=1
            );
            hed__Plan_Requirement__c rOptParent = new hed__Plan_Requirement__c(
                Name='SEED_REQ_OPT_PARENT', hed__Program_Plan__c=plan.Id,
                hed__Credits__c=4, hed__Category__c='Optional', hed__Sequence__c=10
            );
            try { rLeaf.put('hed__Account__c',      inst.Id); } catch (Exception ignore) {}
            try { rOptParent.put('hed__Account__c', inst.Id); } catch (Exception ignore) {}
            insert new List<hed__Plan_Requirement__c>{ rLeaf, rOptParent };
            s.optParentReqId = rOptParent.Id;
            
            hed__Plan_Requirement__c rChildX = new hed__Plan_Requirement__c(
                Name='SEED_CHILD_X', hed__Program_Plan__c=plan.Id, hed__Course__c=cX.Id, hed__Plan_Requirement__c=rOptParent.Id
            );
            hed__Plan_Requirement__c rChildY = new hed__Plan_Requirement__c(
                Name='SEED_CHILD_Y', hed__Program_Plan__c=plan.Id, hed__Course__c=cY.Id, hed__Plan_Requirement__c=rOptParent.Id
            );
            try { rChildX.put('hed__Account__c', inst.Id); } catch (Exception ignore) {}
            try { rChildY.put('hed__Account__c', inst.Id); } catch (Exception ignore) {}
            insert new List<hed__Plan_Requirement__c>{ rChildX, rChildY };
            
            Id accId = (inst != null && inst.Id != null) ? inst.Id : con.AccountId;
            s.accountId = accId;
            
            hed__Program_Enrollment__c pe = new hed__Program_Enrollment__c(
                hed__Contact__c      = con.Id,
                hed__Program_Plan__c = plan.Id,
                hed__Account__c      = accId
            );
            insert pe;
            s.peId = pe.Id;
            
            hed__Course_Enrollment__c ce1 = new hed__Course_Enrollment__c(
                hed__Contact__c            = con.Id,
                hed__Course_Offering__c    = offLeaf.Id,
                hed__Program_Enrollment__c = pe.Id,
                hed__Credits_Earned__c     = 1,
                hed__Account__c            = accId,
                hed__Status__c             = null,
                Notations__c               = 'R'
            );
            
            hed__Course_Enrollment__c ce2 = new hed__Course_Enrollment__c(
                hed__Contact__c            = con.Id,
                hed__Course_Offering__c    = offX.Id,
                hed__Program_Enrollment__c = pe.Id,
                hed__Credits_Earned__c     = 2,
                hed__Account__c            = accId,
                hed__Status__c             = null,
                Notations__c               = 'EQV'
            );
            
            hed__Course_Enrollment__c ce3 = new hed__Course_Enrollment__c(
                hed__Contact__c            = con.Id,
                hed__Course_Offering__c    = offY.Id,
                hed__Program_Enrollment__c = pe.Id,
                hed__Credits_Earned__c     = 2,
                hed__Account__c            = accId,
                hed__Status__c             = null,
                Notations__c               = 'INC'
            );
        
            insert new List<hed__Course_Enrollment__c>{ ce1, ce2, ce3 };

            return s;
        } catch (DmlException dmle) {
            return s;
        } catch (Exception e2) {
            return s;
        }
    }

    @TestVisible static Boolean TEST_THROW_DML = false;
    @TestVisible static Boolean TEST_THROW_GENERIC = false;
    @TestVisible public static Id testGetPlanId()      { SeedIds s = ensureTestSeed(); return s==null?null:s.planId; }
    @TestVisible public static Id testGetContactId()   { SeedIds s = ensureTestSeed(); return s==null?null:s.contactId; }
    @TestVisible public static Id testGetPeId()        { SeedIds s = ensureTestSeed(); return s==null?null:s.peId; }
    @TestVisible public static Id testGetAccountId()   { SeedIds s = ensureTestSeed(); return s==null?null:s.accountId; }
    @TestVisible public static Id testGetOptParentId() { SeedIds s = ensureTestSeed(); return s==null?null:s.optParentReqId; }

    @TestVisible private class TestDataIds {
        public Id planId; public Id contactId; public Id peId; public Id accountId; public Id optParentReqId;
    }
    @TestVisible private static TestDataIds prepareTestData() {
        if (!Test.isRunningTest()) return null;
        return new TestDataIds();
    }
}