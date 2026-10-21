#!/usr/bin/env python3
"""Backup of Zeffy Connect history from an org (read-only).

Exports every Zeffy_Review_Ticket__c (all fields, incl. the original webhook JSON), plus
Zeffy_Identity__c, Zeffy_Connect_Audit_Log__c, Zeffy_Fund__c and Zeffy_Webhook_Log__c, to
  Zeffy Connect/backups/<YYYY-MM-DD_HHMM>_<org>/
as JSON (exact, used by zeffy_tickets_migrate.py) and CSV (UTF-8 with BOM, for Excel).

The backups folder holds donor personal data: it is git-ignored and must never go to GitHub.

Usage:  python3 "Zeffy Connect/scripts/zeffy_tickets_backup.py" <org-alias-or-username>
"""
import csv
import json
import os
import subprocess
import sys
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
BACKUP_ROOT = os.path.join(os.path.dirname(HERE), 'backups')

# object → extra relationship fields to export (besides every field of the object)
OBJECTS = {
    'Zeffy_Review_Ticket__c':     ['CreatedBy.Name', 'Owner.Name', 'Resolved_Account__r.Name', 'Fund__r.Name'],
    'Zeffy_Identity__c':          ['Account__r.Name'],
    'Zeffy_Connect_Audit_Log__c': ['Ticket__r.Name', 'Account__r.Name', 'Performed_By__r.Name'],
    'Zeffy_Fund__c':              [],
    'Zeffy_Webhook_Log__c':       [],
}


def sf_json(args):
    out = subprocess.run(['sf'] + args + ['--json'], capture_output=True, text=True).stdout
    data = json.loads(out[out.index('{'):])
    if data.get('status') != 0:
        sys.exit('sf ' + ' '.join(args[:3]) + ' failed: ' + data.get('message', out[:300]))
    return data['result']


def query(org, soql):
    return sf_json(['data', 'query', '-o', org, '-q', soql])['records']


def flatten(rec, prefix=''):
    row = {}
    for k, v in rec.items():
        if k == 'attributes':
            continue
        if isinstance(v, dict):
            row.update(flatten(v, prefix + k + '.'))
        else:
            row[prefix + k] = v
    return row


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    org = sys.argv[1]
    o = query(org, 'SELECT Id, Name, IsSandbox FROM Organization')[0]
    print(f"Org: {o['Name']} ({o['Id']})  sandbox={o['IsSandbox']}  — read-only backup")

    stamp = datetime.now().strftime('%Y-%m-%d_%H%M')
    safe_org = ''.join(c if c.isalnum() or c in '.-_' else '_' for c in org)
    out_dir = os.path.join(BACKUP_ROOT, f'{stamp}_{safe_org}')
    os.makedirs(out_dir, exist_ok=True)

    manifest = {'org': org, 'orgName': o['Name'], 'orgId': o['Id'], 'isSandbox': o['IsSandbox'],
                'takenAt': datetime.now().isoformat(timespec='seconds'), 'counts': {}}
    for obj, extra in OBJECTS.items():
        fields = [f['name'] for f in sf_json(['sobject', 'describe', '-o', org, '-s', obj])['fields']]
        soql = f"SELECT {', '.join(fields + extra)} FROM {obj} ORDER BY CreatedDate"
        recs = query(org, soql)
        with open(os.path.join(out_dir, obj + '.json'), 'w', encoding='utf-8') as f:
            json.dump(recs, f, ensure_ascii=False, indent=1)
        rows = [flatten(r) for r in recs]
        cols = list(dict.fromkeys(c for r in rows for c in r)) or fields
        with open(os.path.join(out_dir, obj + '.csv'), 'w', encoding='utf-8-sig', newline='') as f:
            w = csv.DictWriter(f, fieldnames=cols)
            w.writeheader()
            w.writerows(rows)
        manifest['counts'][obj] = len(recs)
        print(f'  {obj:30s} {len(recs):5d}')

    tickets = json.load(open(os.path.join(out_dir, 'Zeffy_Review_Ticket__c.json'), encoding='utf-8'))
    by_status = {}
    for t in tickets:
        by_status[t.get('Status__c')] = by_status.get(t.get('Status__c'), 0) + 1
    manifest['ticketsByStatus'] = by_status
    with open(os.path.join(out_dir, 'manifest.json'), 'w', encoding='utf-8') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    print('Tickets by status:', by_status)
    print('Backup folder:', out_dir)


if __name__ == '__main__':
    main()
