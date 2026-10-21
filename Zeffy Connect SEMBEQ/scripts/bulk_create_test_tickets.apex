// ─── Tickets de prueba — asignación, rollback y flujo completo ───────────────
// Ejecutar: sf apex run --file bulk_create_test_tickets.apex --target-org e.frappe@sembeq.qc.ca.partialdev
// Limpiar:  DELETE [SELECT Id FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c LIKE 'TEST_%'];
//           DELETE [SELECT Id FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c LIKE 'test-%'];

String me       = UserInfo.getUserId();
String meName   = UserInfo.getName();
String today    = String.valueOf(Date.today());

String[] firstNames = new String[]{
    'Marie','Jean','Sophie','Pierre','Isabelle','François',
    'Catherine','Michel','Anne','Robert','Laura','David',
    'Lucie','Martin','Sylvie','Patrick','Nathalie','Philippe',
    'Julie','Alain','Éric','Geneviève','Marc','Stéphanie','Luc'
};
String[] lastNames = new String[]{
    'Tremblay','Gagnon','Roy','Côté','Bouchard','Fortin',
    'Gauthier','Morin','Lavoie','Ouellet','Martin','Lévesque',
    'Bernier','Pelletier','Dupuis','Lacroix','Bélanger','Richer',
    'Champagne','Thibodeau','Archambault','Leblanc','Poirier','Denis','Hardy'
};
String[] campaigns = new String[]{
    'Campagne annuelle 2026','Fonds d\'urgence','Bourse étudiante',
    'Don libre','Campagne Noël','Fonds communautaire'
};
String[] cities    = new String[]{
    'Montréal','Québec','Laval','Sherbrooke','Longueuil',
    'Gatineau','Trois-Rivières','Lévis'
};
String[] payMethods = new String[]{'visa','mastercard','amex','cash','check'};

// ── Escenarios de prueba ──────────────────────────────────────────────────────
// Grupo A: 15 Pending Review sin asignar  → para probar "asignar a alguien"
// Grupo B: 10 Pending Review asignados    → para probar filtro Assigned + reasignar
// Grupo C:  6 Resolved - Linked           → para probar rollback
// Grupo D:  4 Resolved - New Contact      → para probar rollback
// Grupo E:  3 Holding                     → para ver cómo suben a Pending Review
// Grupo F:  2 Error                       → para ver tarjeta Error en dashboard

List<Zeffy_Review_Ticket__c> toInsert = new List<Zeffy_Review_Ticket__c>();
Integer idx = 0;

// Helper para construir un ticket base
//   i        — índice para variar nombres/montos
//   status   — Status__c
//   daysBack — antigüedad
//   assigned — true = Manual_Assignee_Id__c = yo
//   resolved — true = llenar Resolved_At__c / Resolved_By__c
Zeffy_Review_Ticket__c makeTicket(Integer i, String status, Integer daysBack,
                                   Boolean assigned, Boolean resolved) {
    Integer fi   = Math.mod(i, firstNames.size());
    Integer li   = Math.mod(i + 3, lastNames.size());
    Integer ci   = Math.mod(i + 1, campaigns.size());
    Integer citi = Math.mod(i + 2, cities.size());
    Integer pmi  = Math.mod(i, payMethods.size());

    String fn  = firstNames[fi];
    String ln  = lastNames[li];
    Decimal amt = (Decimal)(((Math.mod(i, 20) + 1) * 25));  // $25–$500

    DateTime giftDt = DateTime.now().addDays(-daysBack);

    Zeffy_Review_Ticket__c t = new Zeffy_Review_Ticket__c(
        Zeffy_Transaction_Id__c   = 'TEST_' + String.valueOf(i).leftPad(5, '0'),
        Zeffy_Contact_Id__c       = 'test-contact-' + String.valueOf(i).leftPad(4, '0'),
        First_Name__c             = fn,
        Last_Name__c              = ln,
        Email__c                  = fn.toLowerCase() + '.' + ln.toLowerCase() + i + '@test-zeffy.com',
        Amount__c                 = amt,
        Currency__c               = 'CAD',
        Gift_Date__c              = giftDt.date(),
        Form_Name__c              = campaigns[ci],
        Payment_Method__c         = payMethods[pmi],
        Status__c                 = status,
        City__c                   = cities[citi],
        Province__c               = 'QC',
        Country__c                = 'CA',
        Postal_Code__c            = 'H' + Math.mod(i, 10) + 'A ' + Math.mod(i+1, 10) + 'B' + Math.mod(i+2, 10),
        Language__c               = Math.mod(i, 3) == 0 ? 'fr' : 'en',
        Is_Recurring__c           = Math.mod(i, 4) == 0,
        Subscription_Frequency__c = Math.mod(i, 4) == 0 ? 'monthly' : null,
        Note__c                   = Math.mod(i, 6) == 0 ? 'Nota de prueba #' + i : null
    );

    if (assigned) {
        t.Manual_Assignee_Id__c   = me;
        t.Manual_Assignee_Name__c = meName;
    }
    if (resolved) {
        t.Resolved_At__c = giftDt.addDays(1);
        t.Resolved_By__c = me;
    }
    return t;
}

// Grupo A — 15 Pending Review sin asignar (3–30 días atrás)
for (Integer i = 0; i < 15; i++) {
    toInsert.add(makeTicket(idx++, 'Pending Review', 3 + i * 2, false, false));
}

// Grupo B — 10 Pending Review asignados a mí (1–10 días atrás)
for (Integer i = 0; i < 10; i++) {
    toInsert.add(makeTicket(idx++, 'Pending Review', 1 + i, true, false));
}

// Grupo C — 6 Resolved - Linked (para rollback)
for (Integer i = 0; i < 6; i++) {
    toInsert.add(makeTicket(idx++, 'Resolved - Linked', 5 + i, false, true));
}

// Grupo D — 4 Resolved - New Contact (para rollback)
for (Integer i = 0; i < 4; i++) {
    toInsert.add(makeTicket(idx++, 'Resolved - New Contact', 4 + i, false, true));
}

// Grupo E — 3 Holding (recibidos como payment.created)
for (Integer i = 0; i < 3; i++) {
    toInsert.add(makeTicket(idx++, 'Holding', 1 + i, false, false));
}

// Grupo F — 2 Error
for (Integer i = 0; i < 2; i++) {
    toInsert.add(makeTicket(idx++, 'Error', 2 + i, false, false));
}

insert toInsert;

System.debug('✓ Creados ' + toInsert.size() + ' tickets de prueba.');
System.debug('  Grupo A — Pending sin asignar : 15');
System.debug('  Grupo B — Pending asignados   : 10');
System.debug('  Grupo C — Resolved Linked      :  6  ← rollback');
System.debug('  Grupo D — Resolved New Contact :  4  ← rollback');
System.debug('  Grupo E — Holding              :  3');
System.debug('  Grupo F — Error                :  2');
System.debug('Limpiar: DELETE [SELECT Id FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c LIKE \'TEST_%\'];');
