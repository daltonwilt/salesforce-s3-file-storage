/**
 * Builds S3 object keys in the form {parentRecordId}/{uuid}/{sanitizedFileName}.
 * The AWS functions reject any key that does not match this layout.
 */
public with sharing class S3FileKeys {

    private static final Integer MAX_NAME_LENGTH = 199;
    private static final Integer MAX_EXTENSION_LENGTH = 20;

    public static String newKey(Id parentId, String fileName) {
        return String.valueOf(parentId) + '/' + UUID.randomUUID().toString() + '/' + sanitize(fileName);
    }

    /** Keeps letters, digits, spaces and ._()- ; everything else becomes an underscore. Preserves the extension when truncating. */
    public static String sanitize(String fileName) {
        String name = fileName == null ? '' : fileName.trim();
        name = name.replaceAll('[^A-Za-z0-9._()\\- ]', '_');

        if (name.length() > MAX_NAME_LENGTH) {
            Integer dot = name.lastIndexOf('.');
            String extension = (dot > 0 && name.length() - dot <= MAX_EXTENSION_LENGTH) ? name.substring(dot) : '';
            name = name.left(MAX_NAME_LENGTH - extension.length()) + extension;
        }
        Integer lastDot = name.lastIndexOf('.');
        String base = lastDot > 0 ? name.left(lastDot) : name;
        String ext = lastDot > 0 ? name.substring(lastDot) : '';
        if (String.isBlank(base.replace('.', '').replace('_', ''))) {
            name = 'file' + ext; // e.g. a name made only of non-Latin characters
        }
        return name;
    }
}