trigger S3FileTrigger on S3_File__c (after delete) {
    S3FileTriggerHandler.afterDelete(Trigger.old);
}