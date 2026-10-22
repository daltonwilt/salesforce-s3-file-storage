package com.daltonwilt.sffiles;

record DownloadRequest(String fileKey, String fileName, Boolean inline) {

    void validate() {
        if (!FileKeys.isValid(fileKey)) {
            throw new ApiException(400, "fileKey is not in the expected format");
        }
    }

    boolean isInline() {
        return Boolean.TRUE.equals(inline);
    }

    String displayName() {
        return fileName == null || fileName.isBlank() ? FileKeys.fileName(fileKey) : fileName;
    }
}
