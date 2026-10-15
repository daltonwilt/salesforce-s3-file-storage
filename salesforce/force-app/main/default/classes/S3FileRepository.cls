/**
 * Data access for S3_File__c in system mode.
 *
 * S3_File__c is Private and does not inherit sharing from its parent, so S3FileController
 * checks the user's access to the PARENT record before calling anything here. Do not call
 * these methods from anywhere that has not performed that check.
 */
public without sharing class S3FileRepository {

    public static List<S3_File__c> forParent(Id parentId) {
        String parent = String.valueOf(parentId);
        return [
            SELECT Id, File_Key__c, File_Name__c, Content_Type__c, Size_Bytes__c, Status__c,
                   CreatedDate, CreatedBy.Name
            FROM S3_File__c
            WHERE Parent_Record_Id__c = :parent
              AND Status__c IN ('Pending', 'Available')
            ORDER BY CreatedDate DESC
            LIMIT 1000
        ];
    }

    public static S3_File__c getFile(Id fileId) {
        List<S3_File__c> files = [
            SELECT Id, File_Key__c, File_Name__c, Parent_Record_Id__c, Status__c
            FROM S3_File__c
            WHERE Id = :fileId
            LIMIT 1
        ];
        return files.isEmpty() ? null : files[0];
    }

    public static void insertFile(S3_File__c file) {
        insert file;
    }

    public static void deleteFile(S3_File__c file) {
        delete file;
    }
}
