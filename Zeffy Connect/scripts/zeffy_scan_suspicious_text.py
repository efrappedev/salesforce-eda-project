#!/usr/bin/env python3
"""Scan Zeffy Connect free-text data for prompt-injection / code-injection attempts.

Read-only (SOQL only). Looks at every text field that comes from donors via Zeffy
(names, notes, buyer questions, tribute, company, address…) plus the raw webhook payload.

Usage:  python3 "Zeffy Connect/scripts/zeffy_scan_suspicious_text.py" <org-alias-or-username>
"""
import json
import re
import subprocess
import sys

TEXT_FIELDS = [
    'First_Name__c', 'Last_Name__c', 'Company_Name__c', 'Email__c', 'Phone__c', 'Address__c', 'City__c',
    'Province__c', 'Postal_Code__c', 'Country__c', 'Note__c', 'Annotation__c', 'Buyer_Questions__c',
    'Tribute_Honouree__c', 'Rate_Title__c', 'Form_Name__c', 'Discount_Code__c', 'Fund_Name__c',
    'Resolution_Notes__c', 'Raw_Payload__c',
]

# Phrases aimed at an AI assistant (EN / FR / ES)
INJECTION = re.compile(r'(?i)('
    r'ignore (all |any |the )?(previous|prior|above|your) (instructions|prompts?|rules)|'
    r'disregard (the |your )?(previous|above|instructions)|system prompt|you are (now )?an? (ai|assistant|agent)|'
    r'\b(assistant|claude|chatgpt|gpt|llm|ai agent)\s*[:,]|new instructions|developer mode|jailbreak|'
    r'ignore[zr]? (les |toutes les )?instructions|instructions pr[ée]c[ée]dentes|'
    r'ignora (las |todas las )?instrucciones|instrucciones anteriores|'
    r'(approve|resolve|delete|export|send) (all|every) (tickets?|records?|donations?)'
r')')
CODE = re.compile(r'(?i)(<\s*script|javascript:|on(error|load|click)\s*=|<\s*iframe|<\s*img[^>]+src|'
                  r'\{\{.*\}\}|\$\{.*\}|\bSELECT\b.+\bFROM\b|\bUNION\b\s+\bSELECT\b|--\s*$|;\s*DROP\b)')
URL = re.compile(r'(?i)\b(?:https?://|www\.)[^\s"\'<>]+')
INVISIBLE = re.compile('[​‌‍⁠﻿‪-‮⁦-⁩]')
# URLs that legitimately appear in Zeffy payloads
TRUSTED_URL = re.compile(r'(?i)^(https?://)?([a-z0-9-]+\.)*(zeffy\.com|stripe\.com|amazonaws\.com)(/|$)')


def sf_query(org, soql):
    out = subprocess.run(['sf', 'data', 'query', '-o', org, '--json', '-q', soql],
                         capture_output=True, text=True).stdout
    data = json.loads(out[out.index('{'):])
    if data.get('status') != 0:
        sys.exit('Query failed: ' + data.get('message', out[:300]))
    return data['result']['records']


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    org = sys.argv[1]
    o = sf_query(org, 'SELECT Name, IsSandbox FROM Organization')[0]
    print(f"Org: {o['Name']}  (sandbox={o['IsSandbox']})  — read-only scan")

    recs = sf_query(org, 'SELECT Id, Name, Status__c, ' + ', '.join(TEXT_FIELDS) +
                    ' FROM Zeffy_Review_Ticket__c ORDER BY CreatedDate')
    hits = []
    for r in recs:
        for f in TEXT_FIELDS:
            v = r.get(f)
            if not isinstance(v, str) or not v:
                continue
            reasons = []
            m = INJECTION.search(v)
            if m: reasons.append(f'AI-instruction phrase: "{m.group(0)}"')
            m = CODE.search(v)
            if m and f != 'Raw_Payload__c': reasons.append(f'code/markup pattern: "{m.group(0)[:60]}"')
            if f == 'Raw_Payload__c' and re.search(r'(?i)<\s*script|javascript:', v):
                reasons.append('script in raw payload')
            urls = [u for u in URL.findall(v) if not TRUSTED_URL.match(u)]
            if urls: reasons.append('URL: ' + ', '.join(u[:80] for u in urls[:3]))
            if INVISIBLE.search(v): reasons.append('invisible/bidi unicode characters')
            if reasons:
                hits.append((r['Name'], r['Status__c'], f, reasons, v))

    print(f'Tickets scanned: {len(recs)} · fields per ticket: {len(TEXT_FIELDS)}')
    if not hits:
        print('Suspicious content: NONE')
        return
    print(f'Suspicious content: {len(hits)} finding(s)\n')
    for name, status, f, reasons, v in hits:
        snippet = v if len(v) <= 200 else v[:200] + '…'
        print(f'- {name} [{status}] {f}: ' + '; '.join(reasons))
        if f != 'Raw_Payload__c':
            print(f'    text: {snippet!r}')


if __name__ == '__main__':
    main()
