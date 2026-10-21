@IsTest(SeeAllData=false)
private class DataUpdateReCaptchaServiceTest {

    private class SiteVerifyMock implements HttpCalloutMock {
        private final Integer statusCode;
        private final String body;
        SiteVerifyMock(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }
        public HttpResponse respond(HttpRequest req) {
            System.assertEquals('https://www.google.com/recaptcha/api/siteverify', req.getEndpoint());
            System.assertEquals('POST', req.getMethod());
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(body);
            return res;
        }
    }

    private static void enable(String siteKey, String secretKey, String signingSecret) {
        DataUpdateReCaptcha_Setting__c s = DataUpdateReCaptcha_Setting__c.getOrgDefaults();
        if (s.Id == null) {
            s.SetupOwnerId = UserInfo.getOrganizationId();
        }
        s.Is_Active__c = true;
        s.Site_Key__c = siteKey;
        s.Secret_Key__c = secretKey;
        s.Signing_Secret__c = signingSecret;
        upsert s;
    }

    @IsTest
    static void disabledByDefault_EverythingPassesThrough() {
        System.assertEquals(false, DataUpdateReCaptchaService.isEnabled());
        System.assertEquals(null, DataUpdateReCaptchaService.getSiteKey());
        System.assertEquals(true, DataUpdateReCaptchaService.verifyToken(null));
        System.assertEquals(true, DataUpdateReCaptchaService.validateLookupPass(null, 'SomeForm', 'ID-1', 'Tremblay'));
    }

    @IsTest
    static void enabled_GetSiteKey_ReturnsConfiguredValue() {
        enable('site-key-123', 'secret-key-456', 'signing-secret-789');
        System.assertEquals(true, DataUpdateReCaptchaService.isEnabled());
        System.assertEquals('site-key-123', DataUpdateReCaptchaService.getSiteKey());
    }

    @IsTest
    static void enabled_BlankToken_FailsWithoutCallout() {
        enable('site-key', 'secret-key', 'signing-secret');
        System.assertEquals(false, DataUpdateReCaptchaService.verifyToken(null));
        System.assertEquals(false, DataUpdateReCaptchaService.verifyToken(''));
    }

    @IsTest
    static void enabled_GoogleSuccess_VerifyReturnsTrue() {
        enable('site-key', 'secret-key', 'signing-secret');
        Test.setMock(HttpCalloutMock.class, new SiteVerifyMock(200, '{"success":true}'));

        Test.startTest();
        Boolean result = DataUpdateReCaptchaService.verifyToken('valid-token');
        Test.stopTest();

        System.assertEquals(true, result);
    }

    @IsTest
    static void enabled_GoogleFailure_VerifyReturnsFalse() {
        enable('site-key', 'secret-key', 'signing-secret');
        Test.setMock(HttpCalloutMock.class, new SiteVerifyMock(200, '{"success":false,"error-codes":["invalid-input-response"]}'));

        Test.startTest();
        Boolean result = DataUpdateReCaptchaService.verifyToken('bad-token');
        Test.stopTest();

        System.assertEquals(false, result);
    }

    @IsTest
    static void enabled_GoogleNon200_VerifyReturnsFalse() {
        enable('site-key', 'secret-key', 'signing-secret');
        Test.setMock(HttpCalloutMock.class, new SiteVerifyMock(500, 'Internal Server Error'));

        Test.startTest();
        Boolean result = DataUpdateReCaptchaService.verifyToken('any-token');
        Test.stopTest();

        System.assertEquals(false, result);
    }

    @IsTest
    static void enabled_GoogleMalformedBody_VerifyReturnsFalse() {
        enable('site-key', 'secret-key', 'signing-secret');
        Test.setMock(HttpCalloutMock.class, new SiteVerifyMock(200, 'not json'));

        Test.startTest();
        Boolean result = DataUpdateReCaptchaService.verifyToken('any-token');
        Test.stopTest();

        System.assertEquals(false, result);
    }

    @IsTest
    static void testForceVerifyResult_OverridesCallout() {
        enable('site-key', 'secret-key', 'signing-secret');
        DataUpdateReCaptchaService.TEST_FORCE_VERIFY_RESULT = true;
        System.assertEquals(true, DataUpdateReCaptchaService.verifyToken('irrelevant'));
        DataUpdateReCaptchaService.TEST_FORCE_VERIFY_RESULT = false;
        System.assertEquals(false, DataUpdateReCaptchaService.verifyToken('irrelevant'));
        DataUpdateReCaptchaService.TEST_FORCE_VERIFY_RESULT = null;
    }

    @IsTest
    static void lookupPass_RoundTrip_ValidatesSuccessfully() {
        enable('site-key', 'secret-key', 'signing-secret');

        Test.startTest();
        String pass = DataUpdateReCaptchaService.generateLookupPass('SEMBEQ_Contact_Update', 'I-000123', 'Tremblay');
        Boolean valid = DataUpdateReCaptchaService.validateLookupPass(pass, 'SEMBEQ_Contact_Update', 'I-000123', 'Tremblay');
        Test.stopTest();

        System.assert(String.isNotBlank(pass));
        System.assertEquals(true, valid);
    }

    @IsTest
    static void lookupPass_MismatchedIdentity_Fails() {
        enable('site-key', 'secret-key', 'signing-secret');

        String pass = DataUpdateReCaptchaService.generateLookupPass('SEMBEQ_Contact_Update', 'I-000123', 'Tremblay');

        System.assertEquals(false, DataUpdateReCaptchaService.validateLookupPass(pass, 'SEMBEQ_Contact_Update', 'I-999999', 'Tremblay'));
        System.assertEquals(false, DataUpdateReCaptchaService.validateLookupPass(pass, 'OtherForm', 'I-000123', 'Tremblay'));
        // A pass earned for one ID can't be replayed to guess the second answer.
        System.assertEquals(false, DataUpdateReCaptchaService.validateLookupPass(pass, 'SEMBEQ_Contact_Update', 'I-000123', 'Gagnon'));
        System.assertEquals(false, DataUpdateReCaptchaService.validateLookupPass(pass, 'SEMBEQ_Contact_Update', 'I-000123', null));
        // Same answer typed with other spacing/case still matches.
        System.assertEquals(true, DataUpdateReCaptchaService.validateLookupPass(pass, 'SEMBEQ_Contact_Update', 'I-000123', ' TREMBLAY '));
    }

    @IsTest
    static void lookupPass_Tampered_Fails() {
        enable('site-key', 'secret-key', 'signing-secret');

        String pass = DataUpdateReCaptchaService.generateLookupPass('SEMBEQ_Contact_Update', 'I-000123', 'Tremblay');
        String tampered = pass.substring(0, pass.length() - 1) + (pass.endsWith('A') ? 'B' : 'A');

        System.assertEquals(false, DataUpdateReCaptchaService.validateLookupPass(tampered, 'SEMBEQ_Contact_Update', 'I-000123', 'Tremblay'));
    }

    @IsTest
    static void lookupPass_MalformedString_FailsGracefully() {
        enable('site-key', 'secret-key', 'signing-secret');

        System.assertEquals(false, DataUpdateReCaptchaService.validateLookupPass('not-a-real-pass', 'SEMBEQ_Contact_Update', 'I-000123', 'Tremblay'));
        System.assertEquals(false, DataUpdateReCaptchaService.validateLookupPass('###.###', 'SEMBEQ_Contact_Update', 'I-000123', 'Tremblay'));
    }

    @IsTest
    static void lookupPass_Expired_Fails() {
        enable('site-key', 'secret-key', 'signing-secret');
        DataUpdateReCaptchaService.TEST_OVERRIDE_TTL_MILLIS = -1000L;

        String pass = DataUpdateReCaptchaService.generateLookupPass('SEMBEQ_Contact_Update', 'I-000123', 'Tremblay');
        DataUpdateReCaptchaService.TEST_OVERRIDE_TTL_MILLIS = null;

        System.assertEquals(false, DataUpdateReCaptchaService.validateLookupPass(pass, 'SEMBEQ_Contact_Update', 'I-000123', 'Tremblay'));
    }

    @IsTest
    static void generateLookupPass_MissingSigningSecret_ReturnsNull() {
        enable('site-key', 'secret-key', null);
        System.assertEquals(null, DataUpdateReCaptchaService.generateLookupPass('SEMBEQ_Contact_Update', 'I-000123', 'Tremblay'));
    }

    @IsTest
    static void validateLookupPass_MissingSigningSecret_ReturnsFalse() {
        enable('site-key', 'secret-key', 'signing-secret');
        String pass = DataUpdateReCaptchaService.generateLookupPass('SEMBEQ_Contact_Update', 'I-000123', 'Tremblay');

        DataUpdateReCaptcha_Setting__c s = DataUpdateReCaptcha_Setting__c.getOrgDefaults();
        s.Signing_Secret__c = null;
        update s;

        System.assertEquals(false, DataUpdateReCaptchaService.validateLookupPass(pass, 'SEMBEQ_Contact_Update', 'I-000123', 'Tremblay'));
    }
}
