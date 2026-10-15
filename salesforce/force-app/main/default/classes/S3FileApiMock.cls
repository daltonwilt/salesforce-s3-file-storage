@IsTest
public class S3FileApiMock implements HttpCalloutMock {

    public Integer statusCode = 200;
    public String mode = 'single';
    public List<String> calledPaths = new List<String>();

    public HttpResponse respond(HttpRequest req) {
        String path = req.getEndpoint().removeStart(S3FileApi.NAMED_CREDENTIAL);
        calledPaths.add(path);

        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');

        if (statusCode >= 300) {
            res.setStatusCode(statusCode);
            res.setBody('{"error":"Simulated failure"}');
            return res;
        }
        if (path == '/delete') {
            res.setStatusCode(204);
            return res;
        }

        res.setStatusCode(200);
        if (path == '/upload-url') {
            res.setBody(mode == 'multipart'
                ? '{"mode":"multipart","uploadId":"u1","partSize":67108864,"parts":[{"partNumber":1,"url":"https://example.com/p1"},{"partNumber":2,"url":"https://example.com/p2"}],"expiresAt":"2026-01-01T01:00:00Z"}'
                : '{"mode":"single","url":"https://example.com/put","headers":{"Content-Type":"application/pdf"},"expiresAt":"2026-01-01T00:15:00Z"}');
        } else if (path == '/download-url') {
            res.setBody('{"url":"https://example.com/get","expiresAt":"2026-01-01T00:05:00Z"}');
        } else if (path == '/multipart/complete') {
            res.setBody('{"etag":"abc-2"}');
        } else {
            res.setStatusCode(404);
            res.setBody('{"error":"Unknown route"}');
        }
        return res;
    }
}