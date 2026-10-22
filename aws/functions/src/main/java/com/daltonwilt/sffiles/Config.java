package com.daltonwilt.sffiles;

record Config(String bucket, long maxFileBytes, long multipartThresholdBytes, long partSizeBytes) {

    static Config fromEnv() {
        return new Config(
                required("BUCKET_NAME"),
                requiredLong("MAX_FILE_BYTES"),
                requiredLong("MULTIPART_THRESHOLD_BYTES"),
                requiredLong("PART_SIZE_BYTES")
        );
    }

    private static String required(String name) {
        String value = System.getenv(name);
        if(value == null || value.isBlank()) {
            throw new IllegalStateException("Missing environment variable " + name);
        }

        return value;
    }

    private static long requiredLong(String name) {
        String value = required(name);
        try {
             return Long.parseLong(value);
        } catch (NumberFormatException e) {
            throw new IllegalStateException(name + " must be a whole number of bytes, got: " + value, e);
        }
    }

}
