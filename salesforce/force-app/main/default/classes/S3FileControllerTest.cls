@IsTest
private class S3FileControllerTest {

    @TestSetup
    static void setup() {
        insert new Account(Name = 'S3 File Test Account');
    }

    private static Id parentId() {
        return [SELECT Id FROM Account LIMIT 1].Id;
    }

    private static S3_File__c insertFile(Id parent, String status) {
        S3_File__c f = new S3_File__c(
            File_Key__c = S3FileKeys.newKey(parent, 'report.pdf'),
            Parent_Record_Id__c = String.valueOf(parent),
            File_Name__c = 'report.pdf',
            Content_Type__c = 'application/pdf',
            Size_Bytes__c = 1024,
            Status__c = status
        );
        insert f;
        return f;
    }

    // ---------- startUpload ----------

    @IsTest
    static void startUploadReturnsSingleUrlAndCreatesPendingRecord() {
        Id parent = parentId();
        Test.setMock(HttpCalloutMock.class, new S3FileApiMock());

        Test.startTest();
        Map<String, Object> result = S3FileController.startUpload(parent, 'Q3 report?.pdf', 'application/pdf', 1024L);
        Test.stopTest();

        Assert.areEqual('single', result.get('mode'));
        Assert.isNotNull(result.get('url'));
        Id fileId = (Id) result.get('fileId');
        S3_File__c file = [SELECT File_Key__c, File_Name__c, Status__c, Size_Bytes__c, Content_Type__c FROM S3_File__c WHERE Id = :fileId];
        Assert.areEqual('Pending', file.Status__c);
        Assert.areEqual('Q3 report?.pdf', file.File_Name__c);
        Assert.areEqual(1024, file.Size_Bytes__c);
        Assert.areEqual('application/pdf', file.Content_Type__c);
        Assert.isTrue(file.File_Key__c.startsWith(String.valueOf(parent) + '/'));
        Assert.isTrue(file.File_Key__c.endsWith('/Q3 report_.pdf'));
    }

    @IsTest
    static void startUploadReturnsMultipartInstructions() {
        S3FileApiMock mock = new S3FileApiMock();
        mock.mode = 'multipart';
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Map<String, Object> result = S3FileController.startUpload(parentId(), 'video.mp4', 'video/mp4', 200000000L);
        Test.stopTest();

        Assert.areEqual('multipart', result.get('mode'));
        Assert.areEqual('u1', result.get('uploadId'));
        Assert.areEqual(2, ((List<Object>) result.get('parts')).size());
    }

    @IsTest
    static void startUploadDefaultsInvalidContentType() {
        Test.setMock(HttpCalloutMock.class, new S3FileApiMock());

        Test.startTest();
        Map<String, Object> result = S3FileController.startUpload(parentId(), 'data.bin', 'not a mime type', 10L);
        Test.stopTest();

        Id fileId = (Id) result.get('fileId');
        Assert.areEqual('application/octet-stream', [SELECT Content_Type__c FROM S3_File__c WHERE Id = :fileId].Content_Type__c);
    }

    @IsTest
    static void startUploadRejectsInvalidSizes() {
        Id parent = parentId();
        Test.setMock(HttpCalloutMock.class, new S3FileApiMock());

        for (Long size : new List<Long>{ 0L, S3FileController.MAX_FILE_BYTES + 1 }) {
            try {
                S3FileController.startUpload(parent, 'a.txt', 'text/plain', size);
                Assert.fail('Expected size ' + size + ' to be rejected');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('empty') || e.getMessage().contains('maximum size'), e.getMessage());
            }
        }
        Assert.areEqual(0, [SELECT COUNT() FROM S3_File__c]);
    }

    @IsTest
    static void startUploadSurfacesServiceErrorAndCreatesNoRecord() {
        S3FileApiMock mock = new S3FileApiMock();
        mock.statusCode = 400;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        try {
            S3FileController.startUpload(parentId(), 'a.txt', 'text/plain', 10L);
            Assert.fail('Expected an error from the file service');
        } catch (AuraHandledException e) {
            Assert.areEqual('Simulated failure', e.getMessage());
        }
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM S3_File__c]);
    }

    // ---------- getFiles ----------

    @IsTest
    static void getFilesReturnsPendingAndAvailableOnly() {
        Id parent = parentId();
        insertFile(parent, 'Pending');
        insertFile(parent, 'Available');
        insertFile(parent, 'Failed');

        Test.startTest();
        List<S3FileController.FileInfo> files = S3FileController.getFiles(parent);
        Test.stopTest();

        Assert.areEqual(2, files.size());
        Assert.areEqual('report.pdf', files[0].fileName);
    }

    // ---------- download ----------

    @IsTest
    static void getDownloadUrlReturnsPresignedUrl() {
        S3_File__c f = insertFile(parentId(), 'Available');
        Test.setMock(HttpCalloutMock.class, new S3FileApiMock());

        Test.startTest();
        String url = S3FileController.getDownloadUrl(f.Id, false);
        Test.stopTest();

        Assert.areEqual('https://example.com/get', url);
    }

    @IsTest
    static void getDownloadUrlRejectsPendingFiles() {
        S3_File__c f = insertFile(parentId(), 'Pending');
        try {
            S3FileController.getDownloadUrl(f.Id, false);
            Assert.fail('Expected pending file to be rejected');
        } catch (AuraHandledException e) {
            Assert.areEqual('This file is not available yet.', e.getMessage());
        }
    }

    @IsTest
    static void getDownloadUrlReportsMissingObject() {
        S3_File__c f = insertFile(parentId(), 'Available');
        S3FileApiMock mock = new S3FileApiMock();
        mock.statusCode = 404;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        try {
            S3FileController.getDownloadUrl(f.Id, false);
            Assert.fail('Expected a not-found error');
        } catch (AuraHandledException e) {
            Assert.areEqual('The file could not be found in storage.', e.getMessage());
        }
        Test.stopTest();
    }

    // ---------- multipart completion ----------

    @IsTest
    static void completeMultipartCallsService() {
        S3_File__c f = insertFile(parentId(), 'Pending');
        S3FileApiMock mock = new S3FileApiMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        S3FileController.completeMultipart(f.Id, 'u1', '[{"partNumber":1,"etag":"\\"a\\""},{"partNumber":2,"etag":"\\"b\\""}]');
        Test.stopTest();

        Assert.isTrue(mock.calledPaths.contains('/multipart/complete'));
    }

    @IsTest
    static void completeMultipartRejectsMalformedParts() {
        S3_File__c f = insertFile(parentId(), 'Pending');
        try {
            S3FileController.completeMultipart(f.Id, 'u1', 'not json');
            Assert.fail('Expected malformed parts to be rejected');
        } catch (AuraHandledException e) {
            Assert.areEqual('parts must be a JSON array.', e.getMessage());
        }
    }

    // ---------- delete ----------

    @IsTest
    static void deleteFileRemovesRecordAndQueuesS3Delete() {
        S3_File__c f = insertFile(parentId(), 'Available');
        Test.setMock(HttpCalloutMock.class, new S3FileApiMock());

        Test.startTest();
        S3FileController.deleteFile(f.Id);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM S3_File__c WHERE Id = :f.Id]);
        AsyncApexJob job = [SELECT Status, NumberOfErrors FROM AsyncApexJob WHERE ApexClass.Name = 'S3FileDeleteQueueable' LIMIT 1];
        Assert.areEqual('Completed', job.Status);
        Assert.areEqual(0, job.NumberOfErrors);
    }

    @IsTest
    static void unknownFileIsRejected() {
        Id missing = Id.valueOf(S3_File__c.SObjectType.getDescribe().getKeyPrefix() + '000000000000');
        try {
            S3FileController.deleteFile(missing);
            Assert.fail('Expected a missing file to be rejected');
        } catch (AuraHandledException e) {
            Assert.areEqual('File not found.', e.getMessage());
        }
    }

    // ---------- access control ----------

    @IsTest
    static void deniedAccessBlocksEveryOperation() {
        Id parent = parentId();
        S3_File__c f = insertFile(parent, 'Available');
        S3FileController.denyAccessForTest = true;

        try {
            S3FileController.getFiles(parent);
            Assert.fail('Expected read access to be denied');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('do not have access'), e.getMessage());
        }
        try {
            S3FileController.startUpload(parent, 'a.txt', 'text/plain', 10L);
            Assert.fail('Expected edit access to be denied');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('do not have permission'), e.getMessage());
        }
        try {
            S3FileController.deleteFile(f.Id);
            Assert.fail('Expected delete to be denied');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('do not have permission'), e.getMessage());
        }
        Assert.areEqual(1, [SELECT COUNT() FROM S3_File__c]);
    }
}