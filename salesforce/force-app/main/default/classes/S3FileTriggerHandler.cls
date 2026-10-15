public with sharing class S3FileTriggerHandler {

    /** Queues deletion of the S3 objects behind deleted reference records (triggers cannot make callouts). */
    public static void afterDelete(List<S3_File__c> deleted) {
        List<String> keys = new List<String>();
        for (S3_File__c f : deleted) {
            if (String.isNotBlank(f.File_Key__c)) {
                keys.add(f.File_Key__c);
            }
        }
        if (!keys.isEmpty()) {
            System.enqueueJob(new S3FileDeleteQueueable(keys));
        }
    }
}