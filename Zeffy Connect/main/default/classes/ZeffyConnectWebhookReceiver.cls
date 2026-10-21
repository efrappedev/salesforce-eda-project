// without sharing: runs as the Site Guest User, and records it creates are reassigned to the
// default owner (external OWD = Private), so with sharing it can't see its own Holding tickets,
// Zeffy_Identity__c or GiftTransactions. Requests are HMAC-validated before any processing.
@RestResource(urlMapping='/zeffy-connect/webhook/*')
global without sharing class ZeffyConnectWebhookReceiver {

    @TestVisible private static Boolean throwForTest  = false;
    @TestVisible private static Boolean failWriteLog  = false;

    @HttpPost
    global static void handleWebhook() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        Zeffy_Config__c config;
        String rawBody = '';

        try {
            config  = ZeffyConnectConfigService.getConfig();
            rawBody = req.requestBody != null ? req.requestBody.toString() : '';
            if (throwForTest) throw new System.SObjectException('Forced test exception');

            if (config == null || String.isBlank(config.Webhook_Secret__c)) {
                writeLog('NO_CONFIG', null, null, null,
                    'No Zeffy configuration found in Custom Settings.',
                    'Webhook_Secret__c is blank. Configure the webhook secret in Zeffy Connect Settings.', null);
                res.statusCode   = 200;
                res.responseBody = Blob.valueOf('{"status":"no_config"}');
                return;
            }

            if (String.isBlank(rawBody)) {
                writeLog('EMPTY_PAYLOAD', null, null, null,
                    'Zeffy sent a webhook with an empty body.',
                    'Request body was null or blank. Possible network issue on Zeffy side.', null);
                res.statusCode   = 200;
                res.responseBody = Blob.valueOf('{"status":"empty_payload"}');
                return;
            }

            String authDetail = validateToken(req, config.Webhook_Secret__c, rawBody);
            if (authDetail != null) {
                writeLog('AUTH_FAILED', null, null, null,
                    'Webhook secret does not match. Request rejected.',
                    authDetail, null);
                res.statusCode   = 200;
                res.responseBody = Blob.valueOf('{"status":"auth_failed"}');
                return;
            }

            // Always log SERVICE_INACTIVE — even when paused we want to know Zeffy is calling.
            // Checked after the signature so only authentic events are kept: the payload is stored
            // and can be reprocessed from Robot Health once the connection is turned back on.
            if (!config.Is_Active__c) {
                writeLog('SERVICE_INACTIVE', null, null, null,
                    'Webhook received but connection is inactive (paused in Settings) — payload kept, reprocess it after resuming.',
                    'Set Is_Active__c = true in Credentials to resume processing.', null, rawBody);
                res.statusCode   = 200;
                res.responseBody = Blob.valueOf('{"status":"paused"}');
                return;
            }

            // Delegate to service — returns a structured result for logging
            ZeffyConnectDonationService.WebhookResult result =
                ZeffyConnectDonationService.processWebhookWithResult(rawBody);

            // Keep the raw payload for anything that did not land cleanly so staff can
            // reprocess it from the webhook log once the cause is fixed.
            Boolean keepPayload = result.retryable == true
                || !NON_REPROCESSABLE.contains(result.status);
            writeLog(result.status, result.transactionId, result.donorName, result.amount,
                     result.message, result.detail, result.eventType,
                     keepPayload ? rawBody : null);

            // 500 on transient failures so Zeffy retries the delivery; everything else is
            // final (duplicates, ignored events, bad payloads) and must not be retried.
            res.statusCode   = result.retryable == true ? 500 : 200;
            res.responseBody = Blob.valueOf('{"status":"' + result.status.toLowerCase() + '"}');

        } catch (Exception ex) {
            String detail = 'Type: '    + ex.getTypeName()
                          + ' | Line: ' + ex.getLineNumber()
                          + ' | Stack: ' + ex.getStackTraceString().abbreviate(3000);
            writeLog('UNHANDLED_EXCEPTION', null, null, null,
                'Unexpected error: ' + ex.getMessage().abbreviate(500),
                detail, null, rawBody);
            res.statusCode   = 500;
            res.responseBody = Blob.valueOf('{"status":"error"}');
        }
    }

    // ── Logging (runs in its own Future to avoid callout/DML order issues) ──────
    // Statuses that are final by nature — re-running the same payload would change nothing
    private static final Set<String> NON_REPROCESSABLE = new Set<String>{
        'SUCCESS', 'DUPLICATE_SKIPPED', 'MISSING_TX_ID'
    };

    @TestVisible
    private static void writeLog(String status, String txId, String donorName,
                                 Decimal amount, String message, String detail,
                                 String eventType) {
        writeLog(status, txId, donorName, amount, message, detail, eventType, null);
    }

    @TestVisible
    private static void writeLog(String status, String txId, String donorName,
                                 Decimal amount, String message, String detail,
                                 String eventType, String rawBody) {
        try {
            if (failWriteLog) throw new System.SObjectException('Forced writeLog failure');
            // A cut payload is broken JSON and could never be reprocessed: keep none and say why
            if (String.isNotBlank(rawBody) && rawBody.length() > 131072) {
                detail = 'Payload too large to keep (' + rawBody.length() + ' chars) — cannot be reprocessed from here. '
                    + (detail != null ? detail : '');
                rawBody = null;
            }
            Zeffy_Webhook_Log__c log = new Zeffy_Webhook_Log__c(
                Status__c         = status,
                Occurred_At__c    = DateTime.now(),
                Transaction_Id__c = txId,
                Donor_Name__c     = donorName,
                Amount__c         = amount,
                Event_Type__c     = eventType,
                Message__c        = message   != null ? message.abbreviate(2000)  : null,
                Detail__c         = detail    != null ? detail.abbreviate(5000)   : null,
                Raw_Payload__c    = String.isNotBlank(rawBody) ? rawBody : null,
                Has_Raw_Payload__c = String.isNotBlank(rawBody)
            );
            insert log;
        } catch (Exception ex) {
            // Logging must never break the webhook response
            System.debug('ZeffyWebhookLog insert failed: ' + ex.getMessage());
        }
    }

    // Returns null on success, or a diagnostic String on failure (logged as AUTH_FAILED detail)
    // Zeffy sends:  Zeffy-Signature: t=<unix_seconds>,v1=<hex_HMAC-SHA256("{t}.{rawBody}", secret)>
    private static String validateToken(RestRequest req, String secret, String rawBody) {

        String sigHeader = req.headers.get('Zeffy-Signature');
        if (String.isBlank(sigHeader)) {
            return 'Missing Zeffy-Signature header. Headers recibidos: ' + req.headers.keySet();
        }

        // Parse  t=<ts>,v1=<hex>
        String t  = null;
        String v1 = null;
        for (String part : sigHeader.split(',')) {
            List<String> kv = part.split('=', 2);
            if (kv.size() == 2) {
                if (kv[0].trim() == 't')  t  = kv[1].trim();
                if (kv[0].trim() == 'v1') v1 = kv[1].trim();
            }
        }

        if (String.isBlank(t) || String.isBlank(v1)) {
            return 'Zeffy-Signature mal formateado (esperado t=...,v1=...): [' + sigHeader.abbreviate(300) + ']';
        }

        // Replay attack check: reject if timestamp is older than 5 minutes
        try {
            Long tsSeconds  = Long.valueOf(t);
            Long nowSeconds = DateTime.now().getTime() / 1000;
            if (Math.abs(nowSeconds - tsSeconds) > 300) {
                return 'Replay attack rejected: timestamp t=' + t + ' is more than 5 minutes old.';
            }
        } catch (Exception e) {
            return 'Timestamp t=[' + t + '] no es un número válido.';
        }

        // HMAC-SHA256( secret, "{t}.{rawBody}" )
        String signedPayload = t + '.' + rawBody;
        Blob   mac           = Crypto.generateMac('hmacSHA256',
                                   Blob.valueOf(signedPayload),
                                   Blob.valueOf(secret));
        String expected = EncodingUtil.convertToHex(mac);

        if (v1.equalsIgnoreCase(expected)) return null;

        // Never log the expected signature or anything derived from the secret
        return 'Firma v1 no coincide (t: ' + t + ').';
    }
}
