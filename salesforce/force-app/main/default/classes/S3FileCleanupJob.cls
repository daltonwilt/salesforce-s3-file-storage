/**
 * Marks uploads that never completed as Failed.
 * Schedule nightly:  System.schedule('S3 File Cleanup', '0 0 2 * * ?', new S3FileCleanupJob());
 *
 * Runs without sharing because it must see Pending records owned by every user.
 * If a late S3 event arrives afterwards, the AWS sync sets the record back to Available.
 */
public without sharing class S3FileCleanupJob implements Database.Batchable<SObject>, Schedulable {

    @TestVisible
    private static final Integer PENDING_HOURS = 24;

    public void execute(SchedulableContext context) {
        Database.executeBatch(new S3FileCleanupJob(), 200);
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        Datetime cutoff = Datetime.now().addHours(-PENDING_HOURS);
        return Database.getQueryLocator([
            SELECT Id FROM S3_File__c WHERE Status__c = 'Pending' AND CreatedDate < :cutoff
        ]);
    }

    public void execute(Database.BatchableContext context, List<S3_File__c> scope) {
        for (S3_File__c f : scope) {
            f.Status__c = 'Failed';
        }
        update scope;
    }

    public void finish(Database.BatchableContext context) {
    }
}