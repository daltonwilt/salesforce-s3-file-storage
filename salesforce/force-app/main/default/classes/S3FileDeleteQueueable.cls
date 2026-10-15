/**
 * Deletes S3 objects for deleted S3_File__c records.
 * Processes up to CALLOUTS_PER_JOB keys per run and chains itself for the rest.
 * Failed keys are retried up to MAX_ATTEMPTS times. S3 deletes are idempotent, so retries are safe.
 */
public with sharing class S3FileDeleteQueueable implements Queueable, Database.AllowsCallouts {

    @TestVisible
    private static final Integer CALLOUTS_PER_JOB = 90; // limit is 100 per transaction
    @TestVisible
    private static final Integer MAX_ATTEMPTS = 3;

    private final List<String> keys;
    private final Integer attempt;

    public S3FileDeleteQueueable(List<String> keys) {
        this(keys, 1);
    }

    public S3FileDeleteQueueable(List<String> keys, Integer attempt) {
        this.keys = keys;
        this.attempt = attempt;
    }

    public void execute(QueueableContext context) {
        List<String> remaining = new List<String>();
        List<String> failed = new List<String>();

        for (Integer i = 0; i < keys.size(); i++) {
            if (i >= CALLOUTS_PER_JOB) {
                remaining.add(keys[i]);
                continue;
            }
            try {
                S3FileApi.deleteFile(keys[i]);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'S3 delete failed (attempt ' + attempt + ') for ' + keys[i] + ': ' + e.getMessage());
                failed.add(keys[i]);
            }
        }

        if (Test.isRunningTest()) {
            return; // chained jobs cannot run in tests
        }
        if (!remaining.isEmpty()) {
            remaining.addAll(failed);
            System.enqueueJob(new S3FileDeleteQueueable(remaining, attempt));
        } else if (!failed.isEmpty()) {
            if (attempt < MAX_ATTEMPTS) {
                System.enqueueJob(new S3FileDeleteQueueable(failed, attempt + 1));
            } else {
                System.debug(LoggingLevel.ERROR, 'Giving up on S3 delete for ' + failed.size() + ' key(s): ' + String.join(failed, ', '));
            }
        }
    }
}