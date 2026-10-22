package com.daltonwilt.sffiles;

public class ApiException extends RuntimeException {

    private final int status;

    ApiException(int status, String message) {
        super(message);
        this.status = status;
    }

    int getStatus() {
        return status;
    }
}
