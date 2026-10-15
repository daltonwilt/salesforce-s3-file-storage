@IsTest
private class S3FileKeysTest {

    @IsTest
    static void sanitizeReplacesUnsupportedCharacters() {
        Assert.areEqual('Q3 report_final_.pdf', S3FileKeys.sanitize('  Q3 report/final?.pdf '));
        Assert.areEqual('Budget (v2)-final.xlsx', S3FileKeys.sanitize('Budget (v2)-final.xlsx'));
    }

    @IsTest
    static void sanitizeKeepsExtensionWhenTruncating() {
        String result = S3FileKeys.sanitize('a'.repeat(300) + '.xlsx');
        Assert.areEqual(200, result.length());
        Assert.isTrue(result.endsWith('.xlsx'));
    }

    @IsTest
    static void sanitizeFallsBackForUnreadableNames() {
        Assert.areEqual('file.pdf', S3FileKeys.sanitize('日本語.pdf'));
        Assert.areEqual('file', S3FileKeys.sanitize('   '));
        Assert.areEqual('file', S3FileKeys.sanitize(null));
    }

    @IsTest
    static void newKeyHasExpectedLayout() {
        Id parentId = Id.valueOf('001000000000001');
        List<String> parts = S3FileKeys.newKey(parentId, 'Budget 2026.xlsx').split('/');

        Assert.areEqual(3, parts.size());
        Assert.areEqual(String.valueOf(parentId), parts[0]);
        Assert.areEqual(18, parts[0].length());
        Assert.areEqual(36, parts[1].length());
        Assert.areEqual('Budget 2026.xlsx', parts[2]);
    }
}