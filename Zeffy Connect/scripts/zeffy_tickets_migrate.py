#!/usr/bin/env python3
"""Migrate Zeffy Connect review tickets from a backup (zeffy_tickets_backup.py) into another org.

Why: Zeffy's historical export has no Zeffy contact ID, so the tickets received by the sandbox
since go-live are the only source of that ID. Migrating them as OPEN tickets lets staff resolve
them in production, which registers each Zeffy ID and gives the robot its matching power.

What it does
  * Tickets: copies every field that exists in the target, except the sandbox resolution
    (Resolved_* lookups, resolver, assignee, amount-not-applied) — those IDs mean nothing in the
    target. Status: Holding / Delayed / Payment Failed / Pending Review are kept; everything
    else (Resolved - *, Closed, Skipped, Error) becomes Pending Review so staff inserts it manually.
  * Fund__c is re-linked by Zeffy_Fund__c Name when the fund exists in the target.
  * Blank Transaction_Status__c (Payment Status) is filled from the backup's webhook logs:
    a successful payment.completed → 'succeeded'; otherwise a payment.created → 'pending'.
    Why: before the 2026-10-06 robot fix, real payment.completed/updated webhooks (which carry
    no data.status) wiped the status to blank. Webhook logs are not migrated, so this is the
    only chance to repair it — no separate backfill is needed in the target.
  * One Audit Log row per migrated ticket ('Migrated from Sandbox') with the original ticket
    number, status, date and its sandbox audit history.
  * Only tickets created by the webhook (CreatedBy = Site Guest User) are migrated: tickets
    created by people or by UI tests in the sandbox are left out (--include-manual to add them).
  * Zeffy_Identity__c rows (opt-in, --with-identities) are copied only if the target has the SAME Account (same Id and Name)
    — sandbox copies keep production record IDs — and the Zeffy ID is not linked there yet.
  * Idempotent: transactions already present in the target (ticket or GiftTransaction with the
    same Zeffy_Transaction_Id__c) are skipped, so it can be re-run with a newer backup at cut-over.

Safety
  * DRY-RUN by default: reads the target and prints the plan; nothing is written.
  * --execute writes. If the target is PRODUCTION you must type the org name to confirm.

Usage
  python3 "Zeffy Connect/scripts/zeffy_tickets_migrate.py" --backup "Zeffy Connect/backups/<folder>" --target <org>
  python3 "Zeffy Connect/scripts/zeffy_tickets_migrate.py" --backup ... --target <org> --execute [--with-identities]
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime

KEEP_STATUS = {'Holding', 'Delayed', 'Payment Failed', 'Pending Review'}
OPEN_STATUS = 'Pending Review'
NOT_COPIED = {
    'Status__c', 'Fund__c',
    'Resolved_Account__c', 'Resolved_Gift__c', 'Resolved_Commitment__c', 'Resolved_Commitment_Id__c',
    'Resolved_At__c', 'Resolved_By__c', 'Resolution_Notes__c',
    'Manual_Assignee_Id__c', 'Manual_Assignee_Name__c', 'Zeffy_Amount_Not_Applied__c',
    'Zeffy_Amount_Reviewed__c',
}
AUDIT_ACTION = 'Migrated from Sandbox'
WEBHOOK_CREATOR = 'Site Guest User'   # "Zeffy Connect Site Guest User" = real Zeffy webhook


def sf_json(args):
    out = subprocess.run(['sf'] + args + ['--json'], capture_output=True, text=True).stdout
    data = json.loads(out[out.index('{'):])
    if data.get('status') != 0:
        raise RuntimeError('sf ' + ' '.join(args[:3]) + ' failed: ' + data.get('message', out[:300]))
    return data['result']


def query(org, soql):
    return sf_json(['data', 'query', '-o', org, '-q', soql])['records']


def chunks(items, n):
    for i in range(0, len(items), n):
        yield items[i:i + n]


def existing_values(org, obj, field, values):
    found = set()
    for part in chunks(sorted(values), 150):
        ids = ','.join("'" + v.replace("'", "\\'") + "'" for v in part)
        found |= {r[field] for r in query(org, f'SELECT {field} FROM {obj} WHERE {field} IN ({ids})')}
    return found


class Rest:
    def __init__(self, org):
        info = sf_json(['org', 'display', '-o', org])
        self.base = info['instanceUrl'] + '/services/data/v' + info.get('apiVersion', '62.0')
        self.token = info['accessToken']          # kept in memory only, never printed

    def create(self, sobject, records):
        """sObject Collections create, 200 per call, allOrNone=false. Returns [(ok, id_or_error)]."""
        results = []
        for part in chunks(records, 200):
            body = {'allOrNone': False,
                    'records': [dict(r, attributes={'type': sobject}) for r in part]}
            req = urllib.request.Request(self.base + '/composite/sobjects', method='POST',
                                         data=json.dumps(body).encode('utf-8'),
                                         headers={'Authorization': 'Bearer ' + self.token,
                                                  'Content-Type': 'application/json'})
            try:
                with urllib.request.urlopen(req) as resp:
                    for r in json.load(resp):
                        results.append((r['success'], r.get('id') or
                                        '; '.join(e.get('message', '') for e in r.get('errors', []))))
            except urllib.error.HTTPError as e:
                msg = e.read().decode('utf-8', 'replace')[:500]
                results.extend((False, f'HTTP {e.code}: {msg}') for _ in part)
        return results


REJECTED_LOG_STATUS = {'AUTH_FAILED', 'INVALID_JSON', 'EMPTY_PAYLOAD'}


def payload_type(raw):
    """Zeffy event type ("payment.completed", ...) from a raw webhook body, or None."""
    try:
        return (json.loads(raw) or {}).get('type') if raw else None
    except (ValueError, AttributeError):
        return None



def payment_origin(raw):
    """Zeffy payment origin (data.type: online/manual/imported) as the Zeffy_Origin__c value, or None."""
    try:
        data = (json.loads(raw) or {}).get('data') or {} if raw else {}
        t = (data.get('type') or '').strip().lower()
    except (ValueError, AttributeError):
        return None
    return {'online': 'Online', 'manual': 'Manual', 'imported': 'Imported'}.get(t)

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--backup', required=True, help='backup folder created by zeffy_tickets_backup.py')
    ap.add_argument('--target', required=True, help='target org alias or username')
    ap.add_argument('--execute', action='store_true', help='write to the target (default: dry-run)')
    ap.add_argument('--with-identities', action='store_true',
                    help='also copy Zeffy_Identity__c rows (off by default: sandbox links may come from tests)')
    ap.add_argument('--include-manual', action='store_true',
                    help='also migrate tickets NOT created by the webhook (tests / manual)')
    a = ap.parse_args()

    load = lambda n: json.load(open(os.path.join(a.backup, n + '.json'), encoding='utf-8'))
    manifest = load('manifest')
    all_tickets = load('Zeffy_Review_Ticket__c')
    is_webhook = lambda t: WEBHOOK_CREATOR in ((t.get('CreatedBy') or {}).get('Name') or '')
    tickets = all_tickets if a.include_manual else [t for t in all_tickets if is_webhook(t)]
    left_out = [t['Name'] for t in all_tickets if t not in tickets]
    identities = load('Zeffy_Identity__c') if a.with_identities else []
    audits = load('Zeffy_Connect_Audit_Log__c')
    webhook_logs = load('Zeffy_Webhook_Log__c')
    # Any processed event proves what Zeffy sent (a duplicate/failed insert of payment.completed still
    # means paid); only rejected requests are ignored. Old logs have no Event_Type__c → read the payload.
    tx_events = {}
    for l in webhook_logs:
        if l.get('Transaction_Id__c') and l.get('Status__c') not in REJECTED_LOG_STATUS:
            ev = l.get('Event_Type__c') or payload_type(l.get('Raw_Payload__c'))
            if ev:
                tx_events.setdefault(l['Transaction_Id__c'], set()).add(ev)

    # ── Target org + safety gate ─────────────────────────────────────────────
    o = query(a.target, 'SELECT Id, Name, IsSandbox FROM Organization')[0]
    print(f"Source : {manifest['orgName']} ({manifest['orgId']}) sandbox={manifest['isSandbox']} · backup {manifest['takenAt']}")
    print(f"Target : {o['Name']} ({o['Id']}) sandbox={o['IsSandbox']}  [{a.target}]")
    print('Mode   :', 'EXECUTE (writes)' if a.execute else 'DRY-RUN (no writes)')
    print(f"Tickets: {len(all_tickets)} in backup · {len(tickets)} from the Zeffy webhook"
          + (f" · {len(left_out)} left out (not webhook): {', '.join(left_out[:20])}" if left_out else ''))
    if o['Id'] == manifest['orgId']:
        sys.exit('Target is the same org as the backup source — nothing to migrate.')

    # ── Target schema ────────────────────────────────────────────────────────
    try:
        tdesc = sf_json(['sobject', 'describe', '-o', a.target, '-s', 'Zeffy_Review_Ticket__c'])
    except RuntimeError:
        sys.exit('Zeffy Connect is not deployed in the target (Zeffy_Review_Ticket__c missing). Deploy it first.')
    createable = {f['name'] for f in tdesc['fields'] if f['createable'] and f['custom']}
    src_fields = {k for t in tickets for k in t if k.endswith('__c')}
    copy_fields = sorted((src_fields & createable) - NOT_COPIED)
    missing = sorted(src_fields - createable - NOT_COPIED)

    # ── Skip what the target already has ─────────────────────────────────────
    tx_ids = {t['Zeffy_Transaction_Id__c'] for t in tickets if t.get('Zeffy_Transaction_Id__c')}
    in_target = existing_values(a.target, 'Zeffy_Review_Ticket__c', 'Zeffy_Transaction_Id__c', tx_ids)
    in_target |= existing_values(a.target, 'GiftTransaction', 'Zeffy_Transaction_Id__c', tx_ids)
    funds = {r['Name']: r['Id'] for r in query(a.target, 'SELECT Id, Name FROM Zeffy_Fund__c')}

    audit_by_ticket = {}
    for x in audits:
        if x.get('Ticket__c'):
            audit_by_ticket.setdefault(x['Ticket__c'], []).append(x)

    plan, skipped, status_changes, tx_filled = [], [], {}, {}
    refund_none_cleared = 0
    for t in tickets:
        tx = t.get('Zeffy_Transaction_Id__c')
        if tx and tx in in_target:
            skipped.append(t['Name'])
            continue
        rec = {f: t[f] for f in copy_fields if t.get(f) is not None}
        # Zeffy sends refund_status 'none' for unrefunded payments; the robot stores it as blank
        # (realRefundStatus) — old sandbox tickets kept the literal, so normalize it here.
        if str(rec.get('Refund_Status__c', '')).strip().lower() == 'none':
            rec.pop('Refund_Status__c')
            refund_none_cleared += 1
        orig = t.get('Status__c')
        rec['Status__c'] = orig if orig in KEEP_STATUS else OPEN_STATUS
        if rec['Status__c'] != orig:
            key = f'{orig} → {OPEN_STATUS}'
            status_changes[key] = status_changes.get(key, 0) + 1
        cur = rec.get('Transaction_Status__c')
        ev = tx_events.get(tx, set()) | {payload_type(t.get('Raw_Payload__c'))}
        paid = 'payment.completed' in ev and orig not in ('Holding', 'Delayed')
        if 'Transaction_Status__c' in createable and (not cur or (cur == 'pending' and paid)):
            fill = 'succeeded' if paid or 'payment.completed' in ev else 'pending' if 'payment.created' in ev else None
            if fill and fill != cur:
                rec['Transaction_Status__c'] = fill
                tx_filled[fill] = tx_filled.get(fill, 0) + 1
        if 'Zeffy_Origin__c' in createable and not rec.get('Zeffy_Origin__c'):
            origin = payment_origin(t.get('Raw_Payload__c'))
            if origin:
                rec['Zeffy_Origin__c'] = origin
        fund_name = (t.get('Fund__r') or {}).get('Name')
        if fund_name and fund_name in funds:
            rec['Fund__c'] = funds[fund_name]
        hist = audit_by_ticket.get(t['Id'], [])
        note = (f"Migrated from sandbox {manifest['orgName']} ({manifest['orgId']}). Original ticket {t['Name']}, "
                f"status '{orig}', received {t.get('CreatedDate')}.")
        if orig not in KEEP_STATUS and (t.get('Resolved_Account__r') or {}).get('Name'):
            note += f" In sandbox it was resolved to account '{t['Resolved_Account__r']['Name']}' — verify and resolve again."
        if t.get('Resolution_Notes__c'):
            note += f" Sandbox resolution notes: {t['Resolution_Notes__c']}"
        if hist:
            note += ' Sandbox history: ' + ' | '.join(
                f"{h.get('Performed_At__c', '')[:16]} {h.get('Action__c')}" for h in hist)
        plan.append((t, rec, note[:32000]))

    # Identities: only when the very same Account exists in the target
    id_plan = []
    if identities:
        acc_ids = {i['Account__c'] for i in identities if i.get('Account__c')}
        target_acc = {}
        for part in chunks(sorted(acc_ids), 150):
            ids = ','.join(f"'{x}'" for x in part)
            target_acc.update({r['Id']: r['Name'] for r in query(a.target, f'SELECT Id, Name FROM Account WHERE Id IN ({ids})')})
        linked = existing_values(a.target, 'Zeffy_Identity__c', 'Zeffy_Contact_Id__c',
                                 {i['Zeffy_Contact_Id__c'] for i in identities})
        for i in identities:
            src_name = (i.get('Account__r') or {}).get('Name')
            if i['Zeffy_Contact_Id__c'] in linked:
                print(f"  identity {i['Name']}: Zeffy ID already linked in target — skipped")
            elif target_acc.get(i['Account__c']) != src_name:
                print(f"  identity {i['Name']}: account {i['Account__c']} ('{src_name}') not in target — skipped")
            else:
                id_plan.append({k: i[k] for k in ('Zeffy_Contact_Id__c', 'Account__c', 'Email__c',
                                                   'First_Seen__c', 'Is_Primary__c', 'Source__c') if i.get(k) is not None})

    # ── Plan ─────────────────────────────────────────────────────────────────
    print(f'\nTickets in backup     : {len(tickets)}')
    print(f'Already in target     : {len(skipped)}' + (f"  ({', '.join(skipped[:10])}{'…' if len(skipped) > 10 else ''})" if skipped else ''))
    print(f'To insert             : {len(plan)}')
    final = {}
    for _, r, _ in plan:
        final[r['Status__c']] = final.get(r['Status__c'], 0) + 1
    print(f'Status in target      : {final}')
    for k, v in status_changes.items():
        print(f'  reopened            : {k}: {v}')
    print(f'Payment Status filled : {tx_filled or 0}  (blank status repaired from webhook logs)')
    print(f"Refund Status 'none'  : {refund_none_cleared}  (left blank, as the robot stores it)")
    print(f'Fields copied         : {len(copy_fields)}')
    if missing:
        print(f'⚠ Not in target (lost): {missing}')
    print(f'Identities to copy    : {len(id_plan)}')
    if not a.execute:
        print('\nDRY-RUN — nothing written. Re-run with --execute to insert.')
        return

    if not o['IsSandbox']:
        print('\n' + '!' * 70)
        print(f"  PRODUCTION: {len(plan)} tickets + {len(plan)} audit rows + {len(id_plan)} identities will be INSERTED")
        print('!' * 70)
        if input(f"Type the org name exactly ('{o['Name']}') to continue: ").strip() != o['Name']:
            sys.exit('Cancelled.')

    rest = Rest(a.target)
    res = rest.create('Zeffy_Review_Ticket__c', [r for _, r, _ in plan])
    mapping, errors, audit_rows = [], [], []
    now = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.000+0000')
    for (t, _, note), (ok, val) in zip(plan, res):
        if ok:
            mapping.append({'sourceName': t['Name'], 'sourceId': t['Id'], 'targetId': val,
                            'tx': t.get('Zeffy_Transaction_Id__c')})
            audit_rows.append({'Ticket__c': val, 'Action__c': AUDIT_ACTION, 'Performed_At__c': now, 'Notes__c': note})
        else:
            errors.append({'sourceName': t['Name'], 'error': val})
    audit_res = rest.create('Zeffy_Connect_Audit_Log__c', audit_rows) if audit_rows else []
    id_res = rest.create('Zeffy_Identity__c', id_plan) if id_plan else []

    out = os.path.join(a.backup, f"migration_result_{o['Id']}_{datetime.now().strftime('%Y-%m-%d_%H%M')}.json")
    with open(out, 'w', encoding='utf-8') as f:
        json.dump({'target': a.target, 'targetOrg': o, 'inserted': mapping, 'errors': errors,
                   'auditErrors': [v for ok, v in audit_res if not ok],
                   'identityResults': id_res}, f, ensure_ascii=False, indent=1)
    print(f'\nInserted tickets : {len(mapping)}   errors: {len(errors)}')
    print(f"Audit rows       : {sum(1 for ok, _ in audit_res if ok)}/{len(audit_rows)}")
    print(f"Identities       : {sum(1 for ok, _ in id_res if ok)}/{len(id_plan)}")
    for e in errors[:20]:
        print(f"  ✗ {e['sourceName']}: {e['error']}")
    print('Result file:', out)


if __name__ == '__main__':
    main()
