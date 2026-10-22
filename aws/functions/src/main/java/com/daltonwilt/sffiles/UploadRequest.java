package com.daltonwilt.sffiles;

import java.util.regex.Pattern;

record UploadRequest(String fileKey, String contentType, long size) {

    private static final Pattern CONTENT_TYPE =
            Pattern.compile("^[A-Za-z0-9!#$&^_.+-]{1,50}/[A-Za-z0-9!#$&^_.+-]{1,49}$");

    void validate(Config config) {
        if(!FileKeys.isValid(fileKey)) {
            throw new ApiException(400, "fileKey is not in the expected format");
        }
        if(contentType == null || !CONTENT_TYPE.matcher(contentType).matches()) {
            throw new ApiException(400, "contentType is not a valid MIME type");
        }
        if(size <= 0) {
            throw new ApiException(400, "size must be a positive number of bytes");
        }
        if(size > config.maxFileBytes()) {
            throw new ApiException(400, "File exceeds the maximum size of " + config.maxFileBytes() + " bytes");
        }
        if(size > config.multipartThresholdBytes()) {
            throw new ApiException(400, "Multipart upload isn't supported yet");
        }
    }
}
