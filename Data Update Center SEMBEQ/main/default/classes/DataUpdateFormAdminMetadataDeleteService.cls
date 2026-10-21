/**
 * DataUpdateFormAdminMetadataDeleteService.cls
 * True (hard) delete of Custom Metadata (__mdt) records via the Metadata API SOAP
 * deleteMetadata() call. Metadata.Operations (used everywhere else in this app for CMDT writes)
 * only supports insert/update, never delete — deleteMetadata() has no native Apex wrapper, so
 * this issues the SOAP callout directly. Unlike Metadata.Operations.enqueueDeployment(),
 * deleteMetadata() is synchronous: no polling/callback job needed.
 *
 * Authenticates via an explicit session ID supplied by the caller, sent directly to the org's
 * own domain (URL.getOrgDomainUrl() — already whitelisted for both sandbox and production by
 * DataUpdate_MetadataApi_Sandbox/Production Remote Site Settings). NOT the DataUpdate_MetadataApi_NC
 * Named Credential's OAuth 2.0 Client Credentials Flow, which was tried first but confirmed
 * empirically to fail (INVALID_SESSION_ID: Client Credentials Flow tokens don't create a
 * session Salesforce's legacy SOAP session-validation layer recognizes — see memory-bank
 * rondas 103/104). That Named Credential/External Credential/Connected App infra is no longer
 * used by this class. The sessionId must come from UserInfo.getSessionId() called inside a
 * Visualforce page request (see DataUpdateFormDeleteVfController) — LWC/Aura invocations don't
 * carry a session ID usable for SOAP API calls.
 */
public with sharing class DataUpdateFormAdminMetadataDeleteService {

    public class MetadataDeleteException extends Exception {}

    private static final String API_VERSION = '64.0';
    private static final String MD_NS = 'http://soap.sforce.com/2006/04/metadata';

    // The Metadata API's deleteMetadata() <type> element takes the metadata COMPONENT type —
    // for every custom metadata record, regardless of which __mdt object it belongs to, that
    // is always the literal string "CustomMetadata". The specific __mdt object API name is
    // only ever part of each record's fullName ("<MdtApiName>.<DeveloperName>"), never the type.
    private static final String CUSTOM_METADATA_TYPE = 'CustomMetadata';

    // Deletes one or more Custom Metadata records. fullNames must already include the
    // "<MdtApiName>.<DeveloperName>" prefix expected by the Metadata API. sessionId must be a
    // real, API-usable session ID — see class header comment for why UserInfo.getSessionId()
    // only works when called from a Visualforce page context.
    public static void deleteCustomMetadata(String metadataType, List<String> fullNames, String sessionId) {
        if (String.isBlank(metadataType) || fullNames == null || fullNames.isEmpty()) {
            return;
        }
        if (String.isBlank(sessionId)) {
            throw new MetadataDeleteException('Missing session ID for deleteMetadata callout.');
        }

        HttpRequest req = new HttpRequest();
        req.setEndpoint(URL.getOrgDomainUrl().toExternalForm() + '/services/Soap/m/' + API_VERSION
            + '/' + UserInfo.getOrganizationId());
        req.setMethod('POST');
        req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
        req.setHeader('SOAPAction', '""');
        req.setTimeout(60000);
        req.setBody(buildDeleteMetadataEnvelope(metadataType, fullNames, sessionId));

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new MetadataDeleteException(
                'deleteMetadata callout failed (HTTP ' + res.getStatusCode() + '): ' + res.getBody());
        }

        parseDeleteMetadataResponse(res.getBody(), fullNames);
    }

    private static String buildDeleteMetadataEnvelope(String metadataType, List<String> fullNames, String sessionId) {
        String fullNamesXml = '';
        for (String fn : fullNames) {
            fullNamesXml += '<met:fullNames>' + fn.escapeXml() + '</met:fullNames>';
        }
        return '<?xml version="1.0" encoding="UTF-8"?>'
            + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:met="' + MD_NS + '">'
            + '<soapenv:Header>'
            + '<met:SessionHeader><met:sessionId>' + sessionId.escapeXml() + '</met:sessionId></met:SessionHeader>'
            + '</soapenv:Header>'
            + '<soapenv:Body>'
            + '<met:deleteMetadata>'
            + '<met:type>' + CUSTOM_METADATA_TYPE + '</met:type>'
            + fullNamesXml
            + '</met:deleteMetadata>'
            + '</soapenv:Body>'
            + '</soapenv:Envelope>';
    }

    private static void parseDeleteMetadataResponse(String responseBody, List<String> fullNames) {
        Dom.Document doc = new Dom.Document();
        doc.load(responseBody);
        Dom.XmlNode body = getChild(doc.getRootElement(), 'Body');

        Dom.XmlNode fault = getChild(body, 'Fault');
        if (fault != null) {
            Dom.XmlNode faultString = getChild(fault, 'faultstring');
            throw new MetadataDeleteException('Metadata API fault deleting ' + String.join(fullNames, ', ')
                + ': ' + (faultString != null ? faultString.getText() : 'unknown fault'));
        }

        Dom.XmlNode response = getChild(body, 'deleteMetadataResponse');
        List<String> failures = new List<String>();
        for (Dom.XmlNode result : getChildren(response, 'result')) {
            Dom.XmlNode successNode = getChild(result, 'success');
            Boolean success = successNode != null && successNode.getText() == 'true';
            if (!success) {
                Dom.XmlNode fullNameNode = getChild(result, 'fullName');
                Dom.XmlNode errors = getChild(result, 'errors');
                Dom.XmlNode msgNode = getChild(errors, 'message');
                failures.add((fullNameNode != null ? fullNameNode.getText() : '?') + ': '
                    + (msgNode != null ? msgNode.getText() : 'unknown error'));
            }
        }
        if (!failures.isEmpty()) {
            throw new MetadataDeleteException('deleteMetadata failed — ' + String.join(failures, '; '));
        }
    }

    private static Dom.XmlNode getChild(Dom.XmlNode parent, String name) {
        if (parent == null) return null;
        for (Dom.XmlNode child : parent.getChildElements()) {
            if (child.getName() == name) return child;
        }
        return null;
    }

    private static List<Dom.XmlNode> getChildren(Dom.XmlNode parent, String name) {
        List<Dom.XmlNode> result = new List<Dom.XmlNode>();
        if (parent == null) return result;
        for (Dom.XmlNode child : parent.getChildElements()) {
            if (child.getName() == name) result.add(child);
        }
        return result;
    }
}
