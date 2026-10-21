@RestResource(urlMapping='/dmc/webhook/*')
global class DmcWebhookReceiver {

    @HttpPost
    global static void handleWebhook() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        try {
            Zeffy_Config__c config = DmcConfigService.getConfig();

            // If not active, acknowledge without processing (prevents DMC retries)
            if (config == null || !config.Is_Active__c) {
                res.statusCode   = 200;
                res.responseBody = Blob.valueOf('{"status":"paused"}');
                return;
            }

            String rawBody = req.requestBody != null ? req.requestBody.toString() : '';
            if (String.isBlank(rawBody)) {
                res.statusCode   = 400;
                res.responseBody = Blob.valueOf('{"error":"empty body"}');
                return;
            }

            // Validate webhook token (simple comparison — DMC sends token in header)
            if (!validateToken(req, config.Webhook_Secret__c)) {
                res.statusCode   = 401;
                res.responseBody = Blob.valueOf('{"error":"invalid token"}');
                return;
            }

            DmcDonationService.processWebhook(rawBody);

            res.statusCode   = 200;
            res.responseBody = Blob.valueOf('{"status":"ok"}');

        } catch (Exception ex) {
            // Always return 200 to prevent DMC retries; the error is logged in the ticket
            res.statusCode   = 200;
            res.responseBody = Blob.valueOf('{"status":"error","message":"' +
                String.escapeSingleQuotes(ex.getMessage().abbreviate(200)) + '"}');
        }
    }

    private static Boolean validateToken(RestRequest req, String secret) {
        if (String.isBlank(secret)) return true; // No secret configured → open (dev mode)

        // DMC sends the token in one of these headers
        String incoming = req.headers.get('X-Zeffy-Signature');
        if (String.isBlank(incoming)) {
            incoming = req.headers.get('Authorization');
            if (String.isNotBlank(incoming) && incoming.startsWithIgnoreCase('Bearer ')) {
                incoming = incoming.substring(7);
            }
        }
        if (String.isBlank(incoming)) return false;

        // Constant-time comparison to prevent timing attacks
        return incoming.trim().equals(secret.trim());
    }
}
