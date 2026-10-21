/**
 * DataUpdateReCaptchaService.cls
 * Google reCAPTCHA v2 (checkbox) verification for the public Data Update
 * Center lookup form — the only real brake on a scripted brute-force attack
 * against DataUpdatePortalController.lookupRecord() (guessing Account ID +
 * last name pairs).
 *
 * Config lives in DataUpdateReCaptcha_Setting__c (Hierarchy Custom Setting,
 * org defaults) instead of Custom Metadata specifically because Custom
 * Metadata *values* deploy from source (git) — Secret_Key__c/Signing_Secret__c
 * would otherwise end up committed to the repo. Custom Setting field
 * *definitions* are source-tracked, but the actual data values are entered
 * once in Setup and never leave the org.
 *
 * isEnabled() == false (Is_Active__c unchecked, or no Secret_Key__c yet) makes
 * every check in this class a no-op pass-through, so deploying this class
 * does not change lookupRecord()/submitUpdate() behavior until Setup is
 * completed and the flag is turned on.
 */
public without sharing class DataUpdateReCaptchaService {

    private static final String SITEVERIFY_ENDPOINT = 'https://www.google.com/recaptcha/api/siteverify';
    // Window during which submitUpdate() will accept the lookup pass issued
    // by a captcha-gated lookupRecord() call for the same identity, without
    // requiring the visitor to solve a second captcha on the form step.
    private static final Long LOOKUP_PASS_TTL_MILLIS = 10 * 60 * 1000L;

    @TestVisible private static Boolean TEST_FORCE_VERIFY_RESULT = null;
    @TestVisible private static Long TEST_OVERRIDE_TTL_MILLIS = null;

    public static DataUpdateReCaptcha_Setting__c getSettings() {
        return DataUpdateReCaptcha_Setting__c.getOrgDefaults();
    }

    public static Boolean isEnabled() {
        DataUpdateReCaptcha_Setting__c s = getSettings();
        return s != null && s.Is_Active__c == true && String.isNotBlank(s.Secret_Key__c);
    }

    public static String getSiteKey() {
        if (!isEnabled()) return null;
        return getSettings().Site_Key__c;
    }

    public static Boolean verifyToken(String captchaToken) {
        if (!isEnabled()) return true;
        if (TEST_FORCE_VERIFY_RESULT != null) return TEST_FORCE_VERIFY_RESULT;
        if (String.isBlank(captchaToken)) return false;

        DataUpdateReCaptcha_Setting__c s = getSettings();
        HttpRequest req = new HttpRequest();
        req.setEndpoint(SITEVERIFY_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setBody(
            'secret=' + EncodingUtil.urlEncode(s.Secret_Key__c, 'UTF-8') +
            '&response=' + EncodingUtil.urlEncode(captchaToken, 'UTF-8')
        );
        req.setTimeout(10000);

        try {
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) return false;
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            return body.get('success') == true;
        } catch (Exception e) {
            return false;
        }
    }

    // Signed proof that this exact (formName, identity1, identity2) triple already
    // cleared a captcha-gated lookupRecord() call. Bound to the identities rather
    // than the resolved recordId so submitUpdate() can reject a missing/expired/
    // mismatched pass BEFORE running findMatchingRecord() — otherwise
    // submitUpdate() would itself become a captcha-free identity-guessing
    // oracle via its NOT_FOUND vs. match behavior. identity2 is part of the
    // binding too: a pass earned for one ID can't be replayed to guess names.
    public static String generateLookupPass(String formName, String identity1, String identity2) {
        DataUpdateReCaptcha_Setting__c s = getSettings();
        if (!isEnabled() || String.isBlank(s.Signing_Secret__c)) return null;

        Long ttl = TEST_OVERRIDE_TTL_MILLIS != null ? TEST_OVERRIDE_TTL_MILLIS : LOOKUP_PASS_TTL_MILLIS;
        Long expiresAt = Datetime.now().getTime() + ttl;
        String payload = formName + '|' + identityHash(identity1) + '|' + identityHash(identity2) + '|' + expiresAt;
        return EncodingUtil.base64Encode(Blob.valueOf(payload)) + '.' + generateMac(payload, s.Signing_Secret__c);
    }

    public static Boolean validateLookupPass(String lookupPass, String formName, String identity1, String identity2) {
        if (!isEnabled()) return true;
        if (String.isBlank(lookupPass)) return false;

        DataUpdateReCaptcha_Setting__c s = getSettings();
        if (String.isBlank(s.Signing_Secret__c)) return false;

        try {
            List<String> parts = lookupPass.split('\\.', 2);
            if (parts.size() != 2) return false;

            String payload = EncodingUtil.base64Decode(parts[0]).toString();
            if (!generateMac(payload, s.Signing_Secret__c).equals(parts[1])) return false;

            List<String> segments = payload.split('\\|');
            if (segments.size() != 4) return false;
            if (!segments[0].equals(formName)) return false;
            if (!segments[1].equals(identityHash(identity1))) return false;
            if (!segments[2].equals(identityHash(identity2))) return false;

            return Datetime.now().getTime() <= Long.valueOf(segments[3]);
        } catch (Exception e) {
            return false;
        }
    }

    // Hashed so the payload stays splittable on '|' whatever the person typed, and
    // trimmed/lower-cased so the same answer always gives the same hash.
    private static String identityHash(String value) {
        String normalized = value == null ? '' : value.trim().toLowerCase();
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(normalized)));
    }

        private static String generateMac(String payload, String secret) {
        Blob mac = Crypto.generateMac('HmacSHA256', Blob.valueOf(payload), Blob.valueOf(secret));
        return EncodingUtil.base64Encode(mac);
    }
}
