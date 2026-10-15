/**
 * Apex entry point for the S3FileManager LWC.
 *
 * Every method checks the running user's access to the parent record (Read for list and
 * download, Edit for upload and delete) before touching S3_File__c or calling AWS.
 * File content never passes through Apex: AWS returns presigned URLs and the browser
 * transfers directly to and from S3.
 */
public with sharing class S3FileController {

    @TestVisible
    private static final Long MAX_FILE_BYTES = 5368709120L;
    private static final Pattern CONTENT_TYPE = Pattern.compile('^[A-Za-z0-9!#$&^_.+-]{1,50}/[A-Za-z0-9!#$&^_.+-]{1,49}$');
    private static final String DEFAULT_CONTENT_TYPE = 'application/octet-stream';
 
    @TestVisible
    private static Boolean denyAccessForTest = false;
 
    public class FileInfo {
        @AuraEnabled public Id id;
        @AuraEnabled public String fileName;
        @AuraEnabled public String contentType;
        @AuraEnabled public Decimal sizeBytes;
        @AuraEnabled public String status;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public String createdBy;
 
        public FileInfo(S3_File__c f) {
            id = f.Id;
            fileName = String.isNotBlank(f.File_Name__c) ? f.File_Name__c : f.File_Key__c.substringAfterLast('/');
            contentType = f.Content_Type__c;
            sizeBytes = f.Size_Bytes__c;
            status = f.Status__c;
            createdDate = f.CreatedDate;
            createdBy = f.CreatedBy?.Name;
        }
    }
 
    @AuraEnabled
    public static List<FileInfo> getFiles(Id parentId) {
        requireAccess(parentId, false);
        List<FileInfo> result = new List<FileInfo>();
        for (S3_File__c f : S3FileRepository.forParent(parentId)) {
            result.add(new FileInfo(f));
        }
        return result;
    }
 
    /**
     * Returns the AWS response (mode, url/headers or uploadId/partSize/parts) plus fileId.
     * The callout happens BEFORE the insert: Apex does not allow a callout after DML in the same transaction.
     */
    @AuraEnabled
    public static Map<String, Object> startUpload(Id parentId, String fileName, String contentType, Long size) {
        requireAccess(parentId, true);
        if (String.isBlank(fileName)) {
            throw fail('A file name is required.');
        }
        if (size == null || size <= 0) {
            throw fail('The file is empty.');
        }
        if (size > MAX_FILE_BYTES) {
            throw fail('The file exceeds the maximum size of ' + formatGb(MAX_FILE_BYTES) + '.');
        }
        String type = (String.isNotBlank(contentType) && CONTENT_TYPE.matcher(contentType).matches())
            ? contentType
            : DEFAULT_CONTENT_TYPE;
        String key = S3FileKeys.newKey(parentId, fileName);
 
        Map<String, Object> upload;
        try {
            upload = S3FileApi.uploadUrl(key, type, size);
        } catch (S3FileApi.ApiException e) {
            throw fail(e.getMessage());
        } catch (CalloutException e) {
            throw fail('Could not reach the file service. Please try again.');
        }
 
        S3_File__c file = new S3_File__c(
            File_Key__c = key,
            Parent_Record_Id__c = String.valueOf(parentId),
            File_Name__c = fileName.trim().left(255),
            Content_Type__c = type,
            Size_Bytes__c = size,
            Status__c = 'Pending'
        );
        S3FileRepository.insertFile(file);
 
        upload.put('fileId', file.Id);
        return upload;
    }
 
    /** partsJson: [{"partNumber":1,"etag":"\"...\""}, ...] */
    @AuraEnabled
    public static void completeMultipart(Id fileId, String uploadId, String partsJson) {
        S3_File__c file = loadFile(fileId);
        requireAccess(file.Parent_Record_Id__c, true);
        if (String.isBlank(uploadId) || String.isBlank(partsJson)) {
            throw fail('uploadId and parts are required.');
        }
        List<Object> parts;
        try {
            parts = (List<Object>) JSON.deserializeUntyped(partsJson);
        } catch (Exception e) {
            throw fail('parts must be a JSON array.');
        }
        try {
            S3FileApi.completeMultipart(file.File_Key__c, uploadId, parts);
        } catch (S3FileApi.ApiException e) {
            throw fail(e.getMessage());
        } catch (CalloutException e) {
            throw fail('Could not reach the file service. Please try again.');
        }
    }
 
    @AuraEnabled
    public static String getDownloadUrl(Id fileId, Boolean inline) {
        S3_File__c file = loadFile(fileId);
        requireAccess(file.Parent_Record_Id__c, false);
        if (file.Status__c != 'Available') {
            throw fail('This file is not available yet.');
        }
        try {
            Map<String, Object> result = S3FileApi.downloadUrl(file.File_Key__c, file.File_Name__c, inline);
            return (String) result.get('url');
        } catch (S3FileApi.ApiException e) {
            throw fail(e.statusCode == 404 ? 'The file could not be found in storage.' : e.getMessage());
        } catch (CalloutException e) {
            throw fail('Could not reach the file service. Please try again.');
        }
    }
 
    /** Deletes the reference record; S3FileTrigger queues the S3 deletion. */
    @AuraEnabled
    public static void deleteFile(Id fileId) {
        S3_File__c file = loadFile(fileId);
        requireAccess(file.Parent_Record_Id__c, true);
        S3FileRepository.deleteFile(file);
    }
 
    // ---------- Helpers ----------
 
    private static S3_File__c loadFile(Id fileId) {
        S3_File__c file = fileId == null ? null : S3FileRepository.getFile(fileId);
        if (file == null) {
            throw fail('File not found.');
        }
        return file;
    }
 
    private static void requireAccess(String recordId, Boolean needEdit) {
        Id parentId;
        try {
            parentId = Id.valueOf(recordId);
        } catch (Exception e) {
            throw fail('A valid record is required.');
        }
        List<UserRecordAccess> access = [
            SELECT RecordId, HasReadAccess, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :parentId
        ];
        Boolean allowed = !access.isEmpty()
            && (needEdit ? access[0].HasEditAccess : access[0].HasReadAccess)
            && !denyAccessForTest;
        if (!allowed) {
            throw fail(needEdit
                ? 'You do not have permission to change files on this record.'
                : 'You do not have access to files on this record.');
        }
    }
 
    private static AuraHandledException fail(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
 
    private static String formatGb(Long bytes) {
        return String.valueOf((Decimal.valueOf(bytes) / 1073741824).setScale(1)) + ' GB';
    }
}