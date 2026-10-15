@IsTest
private class S3FileAsyncTest {

    private static S3_File__c newFile(String status) {
        Id parent = Id.valueOf('001000000000001');
        return new S3_File__c(
            File_Key__c = S3FileKeys.newKey(parent, 'report.pdf'),
            Parent_Record_Id__c = String.valueOf(parent),
            File_Name__c = 'report.pdf',
            Status__c = status
        );
    }

    @IsTest
    static void deleteQueueableToleratesServiceFailures() {
        S3FileApiMock mock = new S3FileApiMock();
        mock.statusCode = 500;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new S3FileDeleteQueueable(new List<String>{ 'k1', 'k2' }));
        Test.stopTest();

        AsyncApexJob job = [SELECT Status, NumberOfErrors FROM AsyncApexJob WHERE ApexClass.Name = 'S3FileDeleteQueueable' LIMIT 1];
        Assert.areEqual('Completed', job.Status);
        Assert.areEqual(0, job.NumberOfErrors);
    }

    @IsTest
    static void deleteQueueableHandlesMoreKeysThanOneJobAllows() {
        Test.setMock(HttpCalloutMock.class, new S3FileApiMock());
        List<String> keys = new List<String>();
        for (Integer i = 0; i < S3FileDeleteQueueable.CALLOUTS_PER_JOB + 5; i++) {
            keys.add('key-' + i);
        }

        Test.startTest();
        System.enqueueJob(new S3FileDeleteQueueable(keys));
        Test.stopTest();

        AsyncApexJob job = [SELECT Status, NumberOfErrors FROM AsyncApexJob WHERE ApexClass.Name = 'S3FileDeleteQueueable' LIMIT 1];
        Assert.areEqual('Completed', job.Status);
        Assert.areEqual(0, job.NumberOfErrors);
    }

    @IsTest
    static void cleanupMarksStalePendingUploadsAsFailed() {
        S3_File__c stale = newFile('Pending');
        S3_File__c recent = newFile('Pending');
        S3_File__c done = newFile('Available');
        insert new List<S3_File__c>{ stale, recent, done };
        Test.setCreatedDate(stale.Id, Datetime.now().addHours(-(S3FileCleanupJob.PENDING_HOURS + 2)));
        Test.setCreatedDate(done.Id, Datetime.now().addDays(-5));

        Test.startTest();
        Database.executeBatch(new S3FileCleanupJob());
        Test.stopTest();

        Map<Id, S3_File__c> after = new Map<Id, S3_File__c>([SELECT Status__c FROM S3_File__c]);
        Assert.areEqual('Failed', after.get(stale.Id).Status__c);
        Assert.areEqual('Pending', after.get(recent.Id).Status__c);
        Assert.areEqual('Available', after.get(done.Id).Status__c);
    }

    @IsTest
    static void cleanupCanBeScheduled() {
        Test.startTest();
        String jobId = System.schedule('S3 File Cleanup Test', '0 0 2 * * ?', new S3FileCleanupJob());
        Test.stopTest();

        CronTrigger cron = [SELECT CronExpression FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual('0 0 2 * * ?', cron.CronExpression);
    }
}