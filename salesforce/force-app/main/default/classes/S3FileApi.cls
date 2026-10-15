/**
 * Callouts to the AWS file API through the S3_Files_API Named Credential.
 * Salesforce signs each request with AWS Signature Version 4; payloads are small JSON only.
 */
public with sharing class S3FileApi {

    @TestVisible
    private static final String NAMED_CREDENTIAL = 'callout:S3_Files_API';
    private static final Integer TIMEOUT_MS = 20000;

    public class ApiException extends Exception {
        public Integer statusCode;
    }

    public static Map<String, Object> uploadUrl(String fileKey, String contentType, Long size) {
        return post('/upload-url', new Map<String, Object>{
            'fileKey' => fileKey,
            'contentType' => contentType,
            'size' => size
        });
    }

    public static Map<String, Object> completeMultipart(String fileKey, String uploadId, List<Object> parts) {
        return post('/multipart/complete', new Map<String, Object>{
            'fileKey' => fileKey,
            'uploadId' => uploadId,
            'parts' => parts
        });
    }

    public static Map<String, Object> downloadUrl(String fileKey, String fileName, Boolean inline) {
        return post('/download-url', new Map<String, Object>{
            'fileKey' => fileKey,
            'fileName' => fileName,
            'inline' => inline == true
        });
    }

    public static void deleteFile(String fileKey) {
        post('/delete', new Map<String, Object>{ 'fileKey' => fileKey });
    }

    private static Map<String, Object> post(String path, Map<String, Object> body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + path);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(TIMEOUT_MS);
        req.setBody(JSON.serialize(body));

        HttpResponse res = new Http().send(req);
        Integer status = res.getStatusCode();

        if (status == 204) {
            return new Map<String, Object>();
        }
        if (status >= 200 && status < 300) {
            return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        }

        String message = 'File service error (HTTP ' + status + ')';
        try {
            Map<String, Object> err = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            if (err.get('error') != null) {
                message = String.valueOf(err.get('error'));
            }
        } catch (Exception ignored) {
            // Non-JSON error body (for example, an API Gateway 403); keep the generic message
        }
        ApiException ex = new ApiException(message);
        ex.statusCode = status;
        throw ex;
    }
}
