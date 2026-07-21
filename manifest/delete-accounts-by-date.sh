#!/bin/bash
# ============================================================
# Borra accounts creados por Edgar Frappe en una fecha dada
# junto con sus hed__Address__c relacionados (EDA)
#
# Uso:
#   ./manifest/delete-accounts-by-date.sh <org> <fecha>
#
# Ejemplos:
#   ./manifest/delete-accounts-by-date.sh e.frappe@sembeq.qc.ca.partialdev TODAY
#   ./manifest/delete-accounts-by-date.sh e.frappe@sembeq.qc.ca.partialdev 2026-07-14
#   ./manifest/delete-accounts-by-date.sh production 2026-07-15
# ============================================================

TARGET_ORG="${1:-e.frappe@sembeq.qc.ca.partialdev}"
FECHA="${2:-TODAY}"

echo "================================================"
echo "  Borrar accounts creados el: $FECHA"
echo "  Org: $TARGET_ORG"
echo "================================================"

if [ "$TARGET_ORG" = "production" ]; then
    echo "⚠️  Esto borrará registros en PRODUCCIÓN. Type CONFIRMAR para continuar:"
    read -r CONFIRM
    if [ "$CONFIRM" != "CONFIRMAR" ]; then
        echo "Cancelado."
        exit 0
    fi
fi

cat > /tmp/delete_accounts_run.apex << APEX
String fecha = '$FECHA';
List<Account> accts;
if (fecha == 'TODAY') {
    accts = [SELECT Id FROM Account WHERE CreatedById = '005ON00000DkY7GYAV' AND CreatedDate = TODAY];
} else {
    Date d = Date.valueOf(fecha);
    accts = [SELECT Id FROM Account WHERE CreatedById = '005ON00000DkY7GYAV' AND CreatedDate >= :d AND CreatedDate < :d.addDays(1)];
}
System.debug('Accounts a borrar: ' + accts.size());

Set<Id> acctIds = new Map<Id, Account>(accts).keySet();
List<hed__Address__c> addrs = [SELECT Id FROM hed__Address__c WHERE hed__Parent_Account__c IN :acctIds];
System.debug('Addresses a borrar: ' + addrs.size());

if (!addrs.isEmpty()) {
    Database.DeleteResult[] dr = Database.delete(addrs, false);
    Integer fail = 0;
    for (Database.DeleteResult r : dr) if (!r.isSuccess()) fail++;
    System.debug('Addresses: ' + (addrs.size()-fail) + ' borradas, ' + fail + ' fallidas');
}
if (!accts.isEmpty()) {
    Database.DeleteResult[] dr = Database.delete(accts, false);
    Integer fail = 0;
    for (Database.DeleteResult r : dr) if (!r.isSuccess()) fail++;
    System.debug('Accounts: ' + (accts.size()-fail) + ' borradas, ' + fail + ' fallidas');
}
APEX

sf apex run --file /tmp/delete_accounts_run.apex --target-org "$TARGET_ORG" 2>&1 | grep "USER_DEBUG"
