package com.daltonwilt.sffiles;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;

import static org.junit.jupiter.api.Assertions.*;

class FileKeysTest {

    private static final String ID = "001000000000001AAA";
    private static final String UUID = "123e4567-e89b-12d3-a456-426614174000";

    @Test
    void acceptsValidKey() {
        assertTrue(FileKeys.isValid(ID + "/" + UUID + "/Budget 2026.xlsx"));
    }

    @Test
    void acceptsMaxLengthName() {
        String key = ID + "/" + UUID + "/" + "a".repeat(195) + ".txt";

        assertEquals(255, key.length());
        assertTrue(FileKeys.isValid(key));
    }

    @Test
    void rejectsNameOver199Characters() {
        assertFalse(FileKeys.isValid(ID + "/" + UUID + "/" + "a".repeat(196) + ".txt"));
    }

    @ParameterizedTest
    @ValueSource(strings = {
            "001000000000001/" + UUID + "/a.txt",                        // 15-character ID
            ID + "/123e4567-e89b-12d3-a456-42661417400/a.txt",           // UUID too short
            ID + "/123e4567-e89b-12d3-a456-42661417400g/a.txt",          // non-hex character
            ID + "/123e4567e89b12d3a456426614174000/a.txt",              // UUID without dashes
            ID + "/" + UUID + "/a/b.txt",                                // extra segment
            ID + "/" + UUID + "/a?.txt",                                 // unsupported character
            ID + "/" + UUID + "/日本.pdf",                                // unicode name
            ID + "/" + UUID + "/",                                       // empty name
            ID + "/a.txt"                                                // missing UUID
    })
    void rejectsInvalidKeys(String key) {
        assertFalse(FileKeys.isValid(key));
    }

    @ParameterizedTest
    @NullAndEmptySource
    void rejectsNullAndEmpty(String key) {
        assertFalse(FileKeys.isValid(key));
    }

    @Test
    void extractsParentIdAndFileName() {
        String key = ID + "/" + UUID + "/Budget 2026.xlsx";

        assertEquals(ID, FileKeys.parentId(key));
        assertEquals("Budget 2026.xlsx", FileKeys.fileName(key));
    }

}
