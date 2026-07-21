List<Account> accts = [
    SELECT Id FROM Account
    WHERE CreatedById = '005ON00000DkY7GYAV'
    AND CreatedDate = TODAY
];
System.debug('Accounts a borrar: ' + accts.size());

Set<Id> acctIds = new Map<Id, Account>(accts).keySet();

List<hed__Address__c> addrs = [
    SELECT Id FROM hed__Address__c
    WHERE hed__Parent_Account__c IN :acctIds
];
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
