/**
 * DataUpdateMetadataDeleteServiceTest.cls
 * SOAP deleteMetadata() callout against canned responses: success, per-record failure,
 * SOAP fault, HTTP error, and a malformed envelope with no Body.
 */
@IsTest
private class DataUpdateMetadataDeleteServiceTest {

    private static final String MDT = 'Data_Update_Form__mdt';
    private static final List<String> NAMES = new List<String>{ 'Data_Update_Form__mdt.Some_Form' };

    private class SoapMock implements HttpCalloutMock {
        Integer statusCode;
        String body;
        HttpRequest lastRequest;
        SoapMock(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }
        public HttpResponse respond(HttpRequest req) {
            lastRequest = req;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(body);
            return res;
        }
    }

    private static String envelope(String bodyXml) {
        return '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">'
            + '<soapenv:Body>' + bodyXml + '</soapenv:Body></soapenv:Envelope>';
    }

    private static Exception deleteCatching(String sessionId) {
        try {
            DataUpdateFormAdminMetadataDeleteService.deleteCustomMetadata(MDT, NAMES, sessionId);
        } catch (Exception e) {
            return e;
        }
        return null;
    }

    private static void assertDeleteError(Exception e, String fragment) {
        System.assertNotEquals(null, e, 'Expected: ' + fragment);
        System.assert(e instanceof DataUpdateFormAdminMetadataDeleteService.MetadataDeleteException, e.getTypeName());
        System.assert(e.getMessage().contains(fragment), e.getMessage());
    }

    @IsTest
    static void nothingToDelete_NoCallout() {
        // No mock set: any callout here would fail the test.
        DataUpdateFormAdminMetadataDeleteService.deleteCustomMetadata('', NAMES, 'SESSION');
        DataUpdateFormAdminMetadataDeleteService.deleteCustomMetadata(MDT, null, 'SESSION');
        DataUpdateFormAdminMetadataDeleteService.deleteCustomMetadata(MDT, new List<String>(), 'SESSION');
        System.assertEquals(0, Limits.getCallouts());
    }

    @IsTest
    static void missingSession_Throws() {
        assertDeleteError(deleteCatching(' '), 'Missing session ID');
    }

    @IsTest
    static void success_SendsEscapedEnvelope() {
        SoapMock mock = new SoapMock(200, envelope(
            '<deleteMetadataResponse><result><fullName>Data_Update_Form__mdt.Some_Form</fullName>'
            + '<success>true</success></result></deleteMetadataResponse>'));
        Test.setMock(HttpCalloutMock.class, mock);

        DataUpdateFormAdminMetadataDeleteService.deleteCustomMetadata(MDT, NAMES, 'SESS<&>');

        String sent = mock.lastRequest.getBody();
        System.assert(sent.contains('<met:type>CustomMetadata</met:type>'), sent);
        System.assert(sent.contains('<met:fullNames>Data_Update_Form__mdt.Some_Form</met:fullNames>'), sent);
        System.assert(sent.contains('SESS&lt;&amp;&gt;'), sent);
        System.assertEquals('POST', mock.lastRequest.getMethod());
    }

    @IsTest
    static void recordFailures_AreCollected() {
        Test.setMock(HttpCalloutMock.class, new SoapMock(200, envelope(
            '<deleteMetadataResponse>'
            + '<result><fullName>A</fullName><success>false</success><errors><message>in use</message></errors></result>'
            + '<result><success>false</success></result>'
            + '</deleteMetadataResponse>')));
        Exception e = deleteCatching('SESSION');
        assertDeleteError(e, 'A: in use');
        System.assert(e.getMessage().contains('?: unknown error'), e.getMessage());
    }

    @IsTest
    static void soapFault_WithAndWithoutFaultString() {
        Test.setMock(HttpCalloutMock.class, new SoapMock(200, envelope(
            '<soapenv:Fault><faultcode>sf:INVALID_SESSION_ID</faultcode><faultstring>Invalid Session ID</faultstring></soapenv:Fault>')));
        assertDeleteError(deleteCatching('SESSION'), 'Invalid Session ID');

        Test.setMock(HttpCalloutMock.class, new SoapMock(200, envelope('<soapenv:Fault/>')));
        assertDeleteError(deleteCatching('SESSION'), 'unknown fault');
    }

    @IsTest
    static void httpError_Throws() {
        Test.setMock(HttpCalloutMock.class, new SoapMock(500, 'Server Error'));
        assertDeleteError(deleteCatching('SESSION'), 'HTTP 500');
    }

    @IsTest
    static void envelopeWithoutBody_IsTreatedAsNoFailures() {
        Test.setMock(HttpCalloutMock.class, new SoapMock(200, '<Envelope/>'));
        System.assertEquals(null, deleteCatching('SESSION'));
    }
}
