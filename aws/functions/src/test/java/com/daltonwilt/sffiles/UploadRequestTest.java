package com.daltonwilt.sffiles;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.Executable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;

import static org.junit.jupiter.api.Assertions.*;

class UploadRequestTest {

    private static final String KEY = "001000000000001AAA/123e4567-e89b-12d3-a456-426614174000/Budget 2026.xlsx";
    private static final long MAX = 5_368_709_120L;       // 5 GB
    private static final long THRESHOLD = 104_857_600L;   // 100 MB
    private static final Config CONFIG = new Config("bucket", MAX, THRESHOLD, 67_108_864L);

    @Test
    void acceptsValidRequest() {
        assertDoesNotThrow(() -> new UploadRequest(KEY, "text/plain", 1).validate(CONFIG));
    }

    @Test
    void acceptsSizeAtThreshold() {
        assertDoesNotThrow(() -> new UploadRequest(KEY, "text/plain", THRESHOLD).validate(CONFIG));
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = {"001000000000001/123e4567-e89b-12d3-a456-426614174000/a.txt", "not-a-key"})
    void rejectsInvalidKey(String key) {
        ApiException e = assertApiError(400, () -> new UploadRequest(key, "text/plain", 1).validate(CONFIG));

        assertTrue(e.getMessage().contains("fileKey"));
    }

    @ParameterizedTest
    @ValueSource(strings = {"image/png", "application/pdf", "application/vnd.ms-excel", "image/svg+xml"})
    void acceptsValidContentTypes(String contentType) {
        assertDoesNotThrow(() -> new UploadRequest(KEY, contentType, 1).validate(CONFIG));
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = {
            "text",                         // no subtype
            "text/",                        // empty subtype
            "/plain",                       // empty type
            "text/plain; charset=utf-8",    // parameters not allowed
            "text /plain",                  // whitespace
            "text/plain/extra"              // extra segment
    })
    void rejectsInvalidContentType(String contentType) {
        ApiException e = assertApiError(400, () -> new UploadRequest(KEY, contentType, 1).validate(CONFIG));

        assertTrue(e.getMessage().contains("contentType"));
    }

    @Test
    void rejectsContentTypeOverLengthLimits() {
        assertApiError(400, () -> new UploadRequest(KEY, "a".repeat(51) + "/plain", 1).validate(CONFIG));
        assertApiError(400, () -> new UploadRequest(KEY, "text/" + "a".repeat(50), 1).validate(CONFIG));
    }

    @ParameterizedTest
    @ValueSource(longs = {0, -1, Long.MIN_VALUE})
    void rejectsNonPositiveSize(long size) {
        ApiException e = assertApiError(400, () -> new UploadRequest(KEY, "text/plain", size).validate(CONFIG));

        assertTrue(e.getMessage().contains("size"));
    }

    @Test
    void rejectsSizeOverMaximum() {
        ApiException e = assertApiError(400, () -> new UploadRequest(KEY, "text/plain", MAX + 1).validate(CONFIG));

        assertTrue(e.getMessage().contains("maximum"));
    }

    @Test
    void acceptsSizeAtMaximumWhenBelowThreshold() {
        Config config = new Config("bucket", 1_000, 1_000, 500);

        assertDoesNotThrow(() -> new UploadRequest(KEY, "text/plain", 1_000).validate(config));
    }

    @Test
    void rejectsSizeAboveThresholdUntilMultipartExists() {
        ApiException e = assertApiError(400, () -> new UploadRequest(KEY, "text/plain", THRESHOLD + 1).validate(CONFIG));

        assertTrue(e.getMessage().contains("Multipart"));
    }

    private static ApiException assertApiError(int status, Executable call) {
        ApiException e = assertThrows(ApiException.class, call);
        assertEquals(status, e.getStatus());
        return e;
    }
}
