package com.daltonwilt.sffiles;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;

import static org.junit.jupiter.api.Assertions.*;

class DownloadRequestTest {

    private static final String KEY = "001000000000001AAA/123e4567-e89b-12d3-a456-426614174000/Budget 2026.xlsx";

    @Test
    void acceptsValidKey() {
        assertDoesNotThrow(() -> new DownloadRequest(KEY, "Budget 2026.xlsx", false).validate());
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = {"001000000000001/123e4567-e89b-12d3-a456-426614174000/a.txt", "../etc/passwd"})
    void rejectsInvalidKey(String key) {
        ApiException e = assertThrows(ApiException.class, () -> new DownloadRequest(key, "a.txt", false).validate());

        assertEquals(400, e.getStatus());
        assertTrue(e.getMessage().contains("fileKey"));
    }

    @Test
    void inlineOnlyWhenExplicitlyTrue() {
        assertTrue(new DownloadRequest(KEY, null, true).isInline());
        assertFalse(new DownloadRequest(KEY, null, false).isInline());
        assertFalse(new DownloadRequest(KEY, null, null).isInline());
    }

    @Test
    void displayNameUsesProvidedName() {
        assertEquals("Résumé “final”.pdf", new DownloadRequest(KEY, "Résumé “final”.pdf", false).displayName());
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = {"   "})
    void displayNameFallsBackToKeyFileName(String fileName) {
        assertEquals("Budget 2026.xlsx", new DownloadRequest(KEY, fileName, false).displayName());
    }
}
