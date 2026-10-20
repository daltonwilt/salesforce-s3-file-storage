package com.daltonwilt.sffiles;

import java.util.regex.Pattern;

/**
 * File keys have the form {parentRecordId}/{uuid}/{sanitizedFileName}.
 * Apex generates them; both Lambdas validate them so nothing outside this layout is ever signed or synced.
 */
final class FileKeys {

    private static final Pattern KEY = Pattern.compile(
            "^([A-Za-z0-9]{15}|[A-Za-z0-9]{18})"
                    + "/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
                    + "/[A-Za-z0-9._()\\- ]{1,200}$");

    private FileKeys() {}

    static boolean isValid(String key) {
        return key != null && KEY.matcher(key).matches();
    }

    static String parentId(String key) {
        return key.substring(0, key.indexOf('/'));
    }

    static String fileName(String key) {
        return key.substring(key.lastIndexOf('/') + 1);
    }
}
