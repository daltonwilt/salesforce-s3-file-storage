# AWS Setup Milestones

*A staged guide to building the AWS side of Salesforce External File Storage by hand*

**Status:** In progress. Milestones 0 and 1 are complete.

## How to use this guide

The Salesforce side of this project is already built: the `s3FileManager` LWC, `S3FileController` and the `S3_File__c` object. This guide builds the AWS backend it calls, one milestone at a time. Each milestone adds a little to the same SAM stack, gets deployed, and gets tested before you move on.

- **Write it yourself.** Each milestone lists what to learn, what to build and how to test it. It gives requirements, not finished code.
- **Reference implementation:** a complete generated version lives outside the repo at `~/Downloads/salesforce-s3-file-storage/aws/`. Treat it as an answer key and compare against it *after* you've attempted a milestone. Don't copy its `salesforce/` folder; it's an older copy of this project.
- **Reviews:** when a milestone is done, ask Claude to "review milestone N". It checks your files and the deployed stack against the API contract, the reference implementation and the fixes listed below.

The architecture and design decisions are in [Salesforce_S3_File_Storage_Design.md](Salesforce_S3_File_Storage_Design.md).

### Progress

- [x] 0. Tooling and account safety
- [x] 1. Secure bucket
- [ ] 2. Presign Lambda: single-part upload and download
- [ ] 3. HTTP API with IAM auth
- [ ] 4. Multipart upload, complete, delete, and error mapping
- [ ] 5. Connect Salesforce (uploads)
- [ ] 6. Events: S3 → SQS + DLQ
- [ ] 7. Sync Lambda: SQS → Salesforce
- [ ] 8. Production readiness

### Project settings

| Setting | Value |
|---|---|
| AWS region | `us-east-1` (US East, N. Virginia) for everything |
| CLI profile | `sf-files` (IAM Identity Center, `AdministratorAccess`), exported as `AWS_PROFILE` in `~/.zshrc` |
| Stack name | `sf-files-dev` (one stack per environment) |
| Lambda runtime | `java25`. Build with Amazon Corretto 25 (`JAVA_HOME` in `~/.zshrc`). |
| Code location | `aws/` at the repo root |

The reference implementation uses Java 21. In your own files use `Runtime: java25` and `<maven.compiler.release>25</maven.compiler.release>`.

## The API contract

Salesforce already calls this API through `S3FileApi.cls`, using the `S3_Files_API` Named Credential. Your presign Lambda must match it exactly.

| Route | Request body | Success response |
|---|---|---|
| `POST /upload-url` | `fileKey`, `contentType`, `size` | `{"mode":"single","url","headers","expiresAt"}` or `{"mode":"multipart","uploadId","partSize","parts":[{"partNumber","url"}],"expiresAt"}` |
| `POST /multipart/complete` | `fileKey`, `uploadId`, `parts:[{partNumber, etag}]` | `{"etag"}` |
| `POST /download-url` | `fileKey`, `fileName`, `inline` | `{"url","expiresAt"}`. **404** if the object doesn't exist. |
| `POST /delete` | `fileKey` | **204** with an empty body |
| Any error | | Status ≥ 300 with `{"error":"message"}`. Apex shows the message to the user. |

- **File keys** are built by `S3FileKeys.cls` as `{18-char parent record Id}/{uuid}/{sanitized file name}`. The name allows letters, digits, spaces and `._()-`.
- **Maximum file size** is 5 GB (5368709120 bytes), enforced in Apex and again in the Lambda.
- **The sync Lambda** upserts `S3_File__c` by the external ID `File_Key__c`, setting `Status__c = 'Available'`, `Size_Bytes__c`, `ETag__c` and `Parent_Record_Id__c`.

## Fixes the reference implementation is missing

Build these into your version as you go.

| Issue | Where it's fixed |
|---|---|
| A full key can be 18 + 1 + 36 + 1 + 200 = **256** characters, but `File_Key__c` holds 255. Inserting the record then fails after the upload URL has already been issued. | Milestone 2: limit names to **199** characters in your key regex. The matching Apex change (`MAX_NAME_LENGTH = 199` in `S3FileKeys.cls`) is made on the Salesforce side. |
| Multipart part URLs can't sign a total size, so a user could upload more than they declared, or more than 5 GB. | Milestone 4: check the total with `ListParts` in `/multipart/complete`, and abort if it's too large. |
| Size parameters have no limits. | Milestone 4: part size `MinValue: 5242880`; threshold and maximum capped at 5 GB. |
| Old dependency versions (AWS SDK 2.25, Jackson 2.17). | Milestone 2: start with current versions. |
| ExternalId is optional and blank by default. | Milestone 5: set one. |
| No Retain policies, alarms, log retention or tests. | Milestones 2 and 8. |

---

## Milestone 0: Tooling and account safety ✅

**Learn:** why the root user is for emergencies only; IAM Identity Center vs. IAM users; regions; billing alerts.

**Done:**
- MFA on the root user, and no root access keys.
- An IAM Identity Center user with the `AdministratorAccess` permission set (8-hour sessions). Sign in to the console through the access portal, never as root.
- The CLI configured with `aws configure sso` as profile `sf-files`, SSO region `us-east-1`.
- A `monthly-5` cost budget with email alerts at 85% and 100% of actual spend and 100% of forecast spend.
- Tools: AWS CLI v2, SAM CLI, Maven, Corretto 25 and Docker (needed for `sam local invoke`).

**Check:**
```
aws sts get-caller-identity     # Arn contains AWSReservedSSO_AdministratorAccess
mvn -v                          # Java version: 25.x
sam --version
```

**When your session expires** (after 8 hours), run `aws sso login`.

---

## Milestone 1: Secure bucket ✅

**Goal:** your first CloudFormation stack, containing an encrypted, private, versioned bucket. It's only `template.yaml`, with no code.

### Learn
1. **CloudFormation:** you describe resources in a template, and AWS creates them as a **stack**. When you change the template and deploy again, AWS applies only the difference. Deleting the stack deletes its resources.
2. **SAM:** the `Transform: AWS::Serverless-2016-10-31` line adds shortcuts for Lambdas and APIs on top of CloudFormation. Include it now so you can add functions later.
3. **Template sections:** `AWSTemplateFormatVersion`, `Transform`, `Description`, `Parameters`, `Resources`, `Outputs`.
4. **Logical ID vs. physical name:** `FilesBucket` is the name inside your template; the bucket's real name is the physical name.
5. **Intrinsic functions:**
   - `!Ref` gives a parameter's value or a resource's main ID.
   - `!GetAtt Resource.Attribute` gives other attributes, for example `FilesBucket.Arn`.
   - `!Sub '${AWS::AccountId}-…'` builds strings.
6. **ARNs:** the unique ID of every AWS resource, for example `arn:aws:s3:::bucket-name`. Policies refer to resources by ARN.
7. **KMS:** a managed encryption key. Reading an object needs permission on the key as well as on the bucket.

**Docs to search for:** "CloudFormation template anatomy" and "AWS SAM template anatomy", plus the resource reference pages for `AWS::KMS::Key`, `AWS::KMS::Alias`, `AWS::S3::Bucket` and `AWS::S3::BucketPolicy`.

### Build
**`aws/.gitignore`:** `.aws-sam/`, `samconfig.toml`, `target/`, `*.key`, `*.pem`

**`aws/template.yaml`:**

| Piece | Requirements |
|---|---|
| Parameter `Environment` | String, default `dev`, allowed values `dev`, `uat`, `prod` |
| KMS key | Key rotation enabled. The key policy must give your account (`arn:aws:iam::${AWS::AccountId}:root`) full control of the key. **A key without a usable policy can lock you out.** |
| KMS alias | `alias/sf-files-${Environment}` |
| Bucket | **Name:** `sf-files-${AWS::AccountId}-${AWS::Region}-${Environment}`. Bucket names are global across all AWS customers, so the account ID keeps it unique.<br>**Ownership:** `BucketOwnerEnforced`.<br>**Public access:** all four Block Public Access settings on.<br>**Encryption:** SSE-KMS with your key, Bucket Key enabled.<br>**Versioning:** on.<br>**Lifecycle rules:** abort incomplete multipart uploads after 7 days; expire noncurrent versions after 30 days; remove expired delete markers (`ExpiredObjectDeleteMarker: true`), which are otherwise left behind once their old versions expire. |
| Bucket policy | Deny all S3 actions on the bucket and its objects when `aws:SecureTransport` is `false` |
| Outputs | `BucketName` and `KeyArn` |

Check your work as you go:
```
cd aws && sam validate --lint
```

### Deploy
```
sam deploy --guided
```
| Prompt | Answer |
|---|---|
| Stack name | `sf-files-dev` |
| AWS Region | `us-east-1` |
| Parameter Environment | `dev` |
| Confirm changes before deploy | `Y` |
| Allow SAM CLI IAM role creation | `Y` |
| Save arguments to configuration file | `Y` |

The first deploy also creates SAM's own helper stack, `aws-sam-cli-managed-default`, which stores build artifacts. Follow the deploy in the console under **CloudFormation → sf-files-dev → Events**.

### Test
```
BUCKET=$(aws cloudformation describe-stacks --stack-name sf-files-dev \
  --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text)
echo hello > /tmp/test.txt
aws s3 cp /tmp/test.txt s3://$BUCKET/test.txt
aws s3api head-object --bucket $BUCKET --key test.txt   # ServerSideEncryption: aws:kms
curl -s https://$BUCKET.s3.amazonaws.com/test.txt        # AccessDenied (anonymous)
aws s3api get-public-access-block --bucket $BUCKET       # all four true
aws s3api get-bucket-lifecycle-configuration --bucket $BUCKET   # all three lifecycle actions
```

**Reference:** `FilesKey`, `FilesKeyAlias`, `FilesBucket` and `FilesBucketPolicy` in the reference `template.yaml`. That version also has CORS and notifications, which you add in milestones 5 and 6. Its bucket name uses a different pattern; this stack uses `sf-files-${AWS::AccountId}-${AWS::Region}-${Environment}`.

**Notes from the milestone 1 review:**
- **SSE-C is blocked.** `get-bucket-encryption` shows `BlockedEncryptionTypes: SSE-C` even though the template doesn't set it. AWS blocks customer-provided keys on new buckets by default. It doesn't affect SSE-KMS.
- **ETags aren't MD5s.** With SSE-KMS, an object's ETag isn't the MD5 of its content. Treat ETags as opaque version fingerprints. The sync Lambda stores them that way in milestone 7.
- **The CLI adds checksums.** Uploads showed `ChecksumAlgorithm: CRC64NVME` because the AWS CLI adds an integrity checksum by default. The Java SDK does the same, which matters for presigned URLs in milestone 2.

---

## Milestone 2: Presign Lambda for single-part upload and download

**Goal:** a Java Lambda that issues presigned upload and download URLs. In this milestone you test it by invoking it directly; the API comes in milestone 3.

### Learn
- **Lambda basics:** the handler method, the execution role (the permissions the function runs with), environment variables, memory and timeout.
- **Presigned URLs:** the Lambda signs a request with its own credentials, and whoever holds the URL can make *exactly that* request until it expires. Signing `Content-Length` into an upload URL means the browser can't upload more bytes than Apex declared.
- **Least privilege:** grant only the S3 and KMS actions the function needs, scoped to your bucket and key.
- **SnapStart:** Lambda takes a snapshot of your initialized function to make cold starts faster. Create SDK clients during init; never load secrets during init, or they get baked into the snapshot.
- **`sam build`, `sam local invoke`, `sam logs`.**

### Build
**`aws/functions/pom.xml`:**
- `maven.compiler.release` 25.
- Current AWS SDK v2 BOM with `s3` and `url-connection-client`. Exclude the Apache and Netty HTTP clients to keep the package small.
- `aws-lambda-java-core`, `aws-lambda-java-events` and `jackson-databind`.
- `junit-jupiter` for tests.

**`FileKeys.java`:**
- The key regex: an ID of 15 or 18 characters, then `/`, a UUID, `/`, and a name of 1–**199** characters from `[A-Za-z0-9._()\- ]`.
- Helpers: `isValid(key)`, `parentId(key)` and `fileName(key)`.

**`PresignHandler.java`:** input `APIGatewayV2HTTPEvent`, output `APIGatewayV2HTTPResponse`. Route on `event.getRouteKey()`, for example `"POST /upload-url"`.
- **`/upload-url`, single-part only for now:**
  - Validate the key, the content type (same regex as `S3FileController`) and `0 < size <= MAX_FILE_BYTES`.
  - Presign a `PutObject` with content type and **content length**, valid for 15 minutes.
  - Return `headers`: the signed headers the browser must send, minus `host` and `content-length`.
- **`/download-url`:**
  - Call `HeadObject` first; a missing object returns **404**.
  - Presign a `GetObject` valid for 5 minutes, with `responseContentDisposition` set to `inline` or `attachment` plus the file name.
- **Errors:** always `{"error": "..."}` with a 4xx or 5xx status.
- **Clients:** create `S3Client` and `S3Presigner` once, in static fields.

**`template.yaml` additions:**
- **`Globals.Function`:** `Runtime: java25`, `MemorySize: 1024`, `Timeout`, `CodeUri: functions/`, plus `AutoPublishAlias: live` and `SnapStart: ApplyOn: PublishedVersions`.
- **`PresignFunction`:**
  - Handler set to your class.
  - Environment variables: `BUCKET_NAME`, `MAX_FILE_BYTES`, `MULTIPART_THRESHOLD_BYTES`, `PART_SIZE_BYTES`.
  - Inline policy:
    - `s3:GetObject` and `s3:PutObject` on `bucket/*`
    - `s3:ListBucket` on the bucket itself, so `HeadObject` returns 404 instead of 403 for missing objects
    - `kms:GenerateDataKey` and `kms:Decrypt` on the key

**`aws/events/*.json`:** sample events. Generate a starting shape with `sam local generate-event apigateway http-api-proxy`, then set `routeKey` and a JSON string `body`.

**Tests:** JUnit tests for `FileKeys` (valid keys, 200-character names rejected, bad UUIDs) and for request validation.

### Test
```
cd aws && sam build
sam local invoke PresignFunction -e events/upload-url.json      # returns a presigned URL
curl -X PUT -H "Content-Type: text/plain" --upload-file /tmp/test.txt "<url>"   # 200
```
- **Prove `Content-Length` is signed:** upload a file with a *different* byte count to the same URL. S3 must reject it (`SignatureDoesNotMatch`).
- **Download:** `events/download-url.json` returns a URL that downloads the file. A missing key returns 404.
- **Deployed function:** `sam deploy`, then `aws lambda invoke --function-name <name> --cli-binary-format raw-in-base64-out --payload file://events/upload-url.json out.json`.
- **Unit tests:** `mvn -f functions/pom.xml test`

**Salesforce follow-up:** change `MAX_NAME_LENGTH` to 199 in `salesforce/force-app/main/default/classes/S3FileKeys.cls`, and run `S3FileKeysTest`.

**Reference:** `FileKeys.java`, and in `PresignHandler.java` the methods `uploadUrl`, `downloadUrl`, `clientHeaders` and `contentDisposition`. Also `Globals` and `PresignFunction` in the template.

---

## Milestone 3: HTTP API with IAM auth

**Goal:** put the Lambda behind an API that only signed (IAM-authorized) callers can reach.

### Learn
- **API Gateway HTTP API vs. REST API:** HTTP APIs are cheaper and simpler, and they're enough here.
- **The `AWS_IAM` authorizer:** callers must sign each request with AWS Signature Version 4 (SigV4), and their identity needs `execute-api:Invoke`. Salesforce Named Credentials can produce SigV4 signatures.
- **Throttling:** rate and burst limits protect the backend.

### Build
- **`FilesApi`** (`AWS::Serverless::HttpApi`): `Auth: EnableIamAuthorizer: true` and `DefaultAuthorizer: AWS_IAM`, plus default route throttling (for example 25 requests per second, burst 50).
- **On `PresignFunction`:** four `HttpApi` events, all `POST`: `/upload-url`, `/multipart/complete`, `/download-url` and `/delete`, each with `ApiId: !Ref FilesApi`.
- **Output `ApiEndpoint`:** `https://${FilesApi}.execute-api.${AWS::Region}.amazonaws.com`

### Test
```
API=$(aws cloudformation describe-stacks --stack-name sf-files-dev \
  --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" --output text)
curl -s -X POST $API/upload-url -d '{}'          # {"message":"Forbidden"}: unsigned requests are rejected

pipx install awscurl                              # or: pip install awscurl
awscurl --service execute-api --region us-east-1 -X POST \
  -H 'Content-Type: application/json' \
  -d '{"fileKey":"001000000000001AAA/<uuid>/test.txt","contentType":"text/plain","size":6}' \
  $API/upload-url                                 # 200 with a presigned URL
```
If `awscurl` can't read your SSO profile, run `eval "$(aws configure export-credentials --format env)"` first.

Also check that invalid input returns your `{"error": ...}` shape with a 400.

---

## Milestone 4: Multipart upload, complete, delete, and error mapping

**Goal:** the remaining routes, and large files.

### Learn
- **S3 multipart upload:**
  1. `CreateMultipartUpload` returns an `uploadId`.
  2. Each part is a separate PUT that returns an **ETag**.
  3. `CompleteMultipartUpload` with all part numbers and ETags assembles the object.
  - Parts must be at least 5 MB (except the last), with at most 10,000 parts.
  - Unfinished uploads are invisible but still cost storage, which is why the lifecycle rule aborts them after 7 days.
- **Delete markers:** in a versioned bucket, `DeleteObject` adds a delete marker and the old version is kept. Your noncurrent-version lifecycle rule removes it after 30 days.

### Build
- **Parameters:**
  - `MultipartThresholdBytes`: default 100 MB, maximum 5 GB.
  - `PartSizeBytes`: default 64 MB, **`MinValue: 5242880`**.
  - `MaxFileBytes`: default and maximum 5368709120.
- **`/upload-url`, multipart branch:**
  - When `size` is above the threshold, compute the part size as `max(PART_SIZE, ceil(size / 10000))`.
  - Call `CreateMultipartUpload`, then presign an `UploadPart` URL for each part, valid for 60 minutes.
- **`/multipart/complete`:**
  - Validate the parts.
  - **Call `ListParts`, sum the sizes, and abort the upload if the total is larger than `MAX_FILE_BYTES`.** For a stricter check, store the declared size as object metadata at create time and compare against that.
  - Complete the upload and return `{"etag"}`.
- **`/delete`:** `DeleteObject`, returning 204 with no body.
- **IAM:** add `s3:DeleteObject`, `s3:AbortMultipartUpload` and `s3:ListMultipartUploadParts` on `bucket/*`.
- **Error mapping:**
  - Your validation errors return 400.
  - S3 404 (`NoSuchKey`, `NoSuchUpload`) returns 404.
  - Other S3 400 errors return 400.
  - Other S3 failures return 502.
  - Anything unexpected returns 500 with a generic message. Log the details; don't return them.

### Test
Deploy with a low threshold so test files stay small: `sam deploy --parameter-overrides MultipartThresholdBytes=10485760 PartSizeBytes=5242880`.

1. Run `mkfile 12m /tmp/big.bin`, then `split -b 5m /tmp/big.bin /tmp/part-`.
2. Request `/upload-url` with `size` 12582912. You get 3 part URLs.
3. PUT each part and capture its ETag: `curl -s -D - -o /dev/null -X PUT --upload-file /tmp/part-aa "<url1>" | grep -i etag`.
4. Call `/multipart/complete` with the 3 part numbers and ETags. `aws s3 ls s3://$BUCKET --recursive` shows one 12 MB object.
5. **Oversized upload:** declare a smaller size than you actually upload, or upload extra data, and confirm that complete rejects it and the upload is aborted (`aws s3api list-multipart-uploads --bucket $BUCKET` comes back empty).
6. **Delete:** call `/delete`, then `aws s3api list-object-versions --bucket $BUCKET --prefix <key>` shows a `DeleteMarkers` entry.

---

## Milestone 5: Connect Salesforce (uploads)

**Goal:** the `s3FileManager` component uploads real files to your bucket.

### Learn
- **IAM users vs. roles:** Salesforce needs credentials. A dedicated IAM user is allowed only to *assume* a role, and only the role can call the API. The role's temporary credentials limit the damage if the user's key leaks.
- **ExternalId:** an extra value the caller must present when assuming the role. It protects against the "confused deputy" problem.
- **Salesforce External Credential (AWS Signature V4) + Named Credential:** Salesforce assumes the role through STS and signs each callout.
- **CORS:** the browser enforces it. The bucket must explicitly allow PUT and GET from your Salesforce origin and expose the `ETag` header, or JavaScript can't read it.
- **CSP Trusted Sites:** Salesforce's own browser rule listing which external hosts Lightning pages may contact.

### Build in AWS
- **Parameters:** `SalesforceOrigins` (a CommaDelimitedList, for example `https://<mydomain>.lightning.force.com`, plus your Experience site domain if you use one) and `SalesforceExternalId` (`NoEcho`).
- **`SalesforceCalloutUser`** (IAM user): an inline policy allowing only `sts:AssumeRole` and `sts:TagSession` on the invoke role.
- **`SalesforceInvokeRole`:**
  - Trust policy: the callout user, with the condition `sts:ExternalId` equal to your parameter.
  - Permission policy: `execute-api:Invoke` on `arn:aws:execute-api:${Region}:${AccountId}:${FilesApi}/*/POST/*`.
- **Bucket CORS rule:** `AllowedOrigins: !Ref SalesforceOrigins`, methods `GET`, `PUT`, `HEAD`, headers `*`, **`ExposedHeaders: [ETag]`**, `MaxAge`.
- **Outputs:** `InvokeRoleArn`, `CalloutUserName`, and `BucketEndpoint` (`https://${FilesBucket}.s3.${AWS::Region}.amazonaws.com`).
- **Deploying:** a named IAM role needs `--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM`. `aws/samconfig.toml` currently has only `capabilities = "CAPABILITY_IAM"`, so add `CAPABILITY_NAMED_IAM` there (space-separated) or every `sam deploy` will need the flag.
- **Access key:** create one for the callout user with `aws iam create-access-key --user-name <CalloutUserName>`. Paste it only into Salesforce, and never commit it.

### Build in Salesforce Setup
These aren't in the repo yet; they can be added as metadata later.
1. **External Credential:**
   - Authentication Protocol: **AWS Signature Version 4**. Service `execute-api`, region `us-east-1`, your AWS account ID.
   - **Obtain temporary IAM credentials via STS:** on, with the role ARN and ExternalId.
   - Add a **named principal** holding the callout user's access key ID and secret.
2. **Named Credential `S3_Files_API`:** URL = the `ApiEndpoint` output, using the External Credential above, with **Generate Authorization Header** enabled.
3. **Principal access:** give the External Credential principal to the users of the component. Adding it to the `S3_File_User` permission set covers them.
4. **CSP Trusted Site:** the `BucketEndpoint` output, with `connect-src` allowed.

### Test
- **Upload:** use the `s3FileManager` card on a record page. The object appears in S3 under `{recordId}/{uuid}/{name}`, and the record **stays Pending**. That's expected: nothing marks it Available until milestone 7.
- **Multipart from the browser:** with the low threshold from milestone 4, a 25 MB file uploads in parts.
- **Download, preview and delete before milestone 7:** set one record's `Status__c` to `Available` by hand, then use the row actions.
- **Browser errors and what they mean:**
  - "Network error during upload" points to the CSP Trusted Site or CORS origins.
  - "S3 did not return an ETag" means `ExposedHeaders` is missing.
  - "File service error (HTTP 403)" points to the Named Credential, the role or the ExternalId.

---

## Milestone 6: Events, S3 → SQS + DLQ

**Goal:** every completed upload produces a queued event.

### Learn
- **S3 event notifications:** S3 can send `ObjectCreated` events to SQS, SNS or Lambda. They're delivered **at least once**, so expect duplicates occasionally.
- **SQS:**
  - **Visibility timeout:** a received message is hidden while it's being processed, and reappears if it isn't deleted.
  - **`maxReceiveCount` and dead-letter queues:** messages that keep failing move to the DLQ instead of retrying forever.
- **Queue policies:** S3 needs permission to send to your queue. Scope it with `aws:SourceArn` (your bucket) and `aws:SourceAccount`.
- **Circular dependencies:** the bucket's notification refers to the queue, and the queue policy refers to the bucket. To break the loop, build the bucket ARN with `!Sub` from its known name instead of `!GetAtt`, and add `DependsOn` from the bucket to the queue policy. The name must match `BucketName` in the template exactly: `arn:aws:s3:::sf-files-${AWS::AccountId}-${AWS::Region}-${Environment}`. S3 checks it can send when the notification is created.

### Build
- **`FileEventsDLQ`:** SQS-managed encryption, 14-day retention.
- **`FileEventsQueue`:** SQS-managed encryption, `VisibilityTimeout` at least **6× the sync Lambda's timeout** (for example 180 seconds for a 30-second Lambda), and a `RedrivePolicy` to the DLQ with `maxReceiveCount: 5`.
- **`FileEventsQueuePolicy`:** allow `s3.amazonaws.com` to `sqs:SendMessage`, with conditions on source ARN and account.
- **Bucket `NotificationConfiguration`:** `QueueConfigurations` with event `s3:ObjectCreated:*` and the queue ARN.
- **Output:** `DeadLetterQueueUrl`.

### Test
```
QUEUE=$(aws sqs get-queue-url --queue-name <queue name> --query QueueUrl --output text)
aws s3 cp /tmp/test.txt s3://$BUCKET/001000000000001AAA/<uuid>/test.txt
aws sqs receive-message --queue-url $QUEUE --wait-time-seconds 10
```
The first message may be an `s3:TestEvent` sent when the notification was created. Read a real event's JSON carefully: `Records[].s3.object.key` (URL-encoded), `size` and `eTag` are what your sync Lambda parses.

---

## Milestone 7: Sync Lambda, SQS → Salesforce

**Goal:** uploaded files turn **Available** in Salesforce within seconds.

### Learn
- **SQS event source mapping:** Lambda polls the queue and invokes your function with batches. With **`ReportBatchItemFailures`**, you return only the failed message IDs, and the rest are deleted.
- **Secrets Manager:** stores the Salesforce private key and connection details outside your code and template.
- **OAuth 2.0 JWT bearer flow:**
  1. The Lambda signs a short-lived JWT with a private key.
  2. Salesforce checks it against the certificate uploaded to the External Client App.
  3. Salesforce returns an access token for the integration user. No password is involved.
- **sObject Collections upsert:** `PATCH /services/data/vXX.X/composite/sobjects/S3_File__c/File_Key__c` upserts up to 200 records in one call. Because it matches on the external ID, duplicate S3 events are harmless.

### Build in Salesforce
1. **An integration user:** for example the *Salesforce Integration* license with the *Minimum Access - API Only Integrations* profile. Assign it the `S3_File_Integration` permission set from the repo.
2. **A key pair:**
   ```
   openssl req -x509 -newkey rsa:2048 -nodes -keyout sf-sync.key -out sf-sync.crt -days 365 -subj "/CN=sf-file-sync"
   ```
   Keep `sf-sync.key` out of the repo; `*.key` and `*.pem` are gitignored.
3. **An External Client App:** enable OAuth, the **JWT bearer flow** and the `api` scope, and upload `sf-sync.crt`. Set it to admin-approved users only, and pre-authorize the integration user, for example through a permission set. Copy the consumer key.

### Build in AWS
- **`SalesforceSecret`:** a placeholder JSON with `loginUrl`, `audience`, `clientId`, `username` and `privateKey`. Use `https://test.salesforce.com` for sandboxes. Fill in the real values after deploying, not in the template:
  ```
  aws secretsmanager put-secret-value --secret-id <arn> --secret-string file://secret.json && rm secret.json
  ```
  The private key must be in PKCS#8 format (`BEGIN PRIVATE KEY`). Convert it with `openssl pkcs8 -topk8 -nocrypt` if needed.
- **`SalesforceClient.java`:**
  - Load the secret lazily on first use, never at init, because of SnapStart.
  - Sign an RS256 JWT with `iss=clientId`, `sub=username`, `aud=audience` and a 3-minute expiry.
  - Exchange it at `{loginUrl}/services/oauth2/token`.
  - Cache the token and instance URL; on a 401, log in again once.
- **`SyncHandler.java`:**
  - Skip `s3:TestEvent` and anything other than `ObjectCreated`.
  - **URL-decode** the key, where `+` means a space.
  - Skip keys that fail `FileKeys.isValid`.
  - Upsert `File_Key__c`, `Parent_Record_Id__c`, `Status__c = 'Available'`, `Size_Bytes__c` and `ETag__c` in chunks of 200 with `allOrNone: false`.
  - Return failed message IDs.
- **`SyncFunction` in the template:**
  - Environment variables: `SF_SECRET_ARN` and `SF_API_VERSION` (`67.0`).
  - Policy: `AWSSecretsManagerGetSecretValuePolicy` on the secret.
  - SQS event: `BatchSize: 10`, `MaximumBatchingWindowInSeconds: 5`, `FunctionResponseTypes: [ReportBatchItemFailures]`, `ScalingConfig: MaximumConcurrency: 5`.

### Test
- **End to end:** upload from the LWC. The row changes from Pending to **Available** within seconds. Download, preview and delete all work, and after a delete the S3 object gets a delete marker shortly afterwards, from `S3FileDeleteQueueable`.
- **Logs:** `sam logs -n SyncFunction --stack-name sf-files-dev --tail`
- **Dead-letter queue:** run `aws sqs send-message --queue-url $QUEUE --message-body 'not json'`. After 5 failed receives it appears in the DLQ.

**Reference:** `SyncHandler.java`, `SalesforceClient.java`, the `SyncFunction` and `SalesforceSecret` resources, and the post-deploy steps in the reference `aws/README.md`.

---

## Milestone 8: Production readiness

- **Retain on delete:** `DeletionPolicy: Retain` and `UpdateReplacePolicy: Retain` on the bucket, the KMS key and the secret, so deleting a stack can't destroy files.
- **DLQ alarm:** a CloudWatch alarm on `ApproximateNumberOfMessagesVisible > 0`, sending to an SNS email topic.
- **Log retention:** explicit `AWS::Logs::LogGroup` resources with a retention period, for example 30 days.
- **API access logs** on the HTTP API stage.
- **CloudTrail data events on the bucket** (optional), if you need an audit trail of file access.
- **Rotation:** document how to rotate the callout user's access key and the JWT certificate, and when.
- **Tests:** JUnit tests for both handlers, using the sample events.
- **Other environments:** deploy `uat` and `prod` as separate stacks with `--parameter-overrides Environment=prod` and their own Salesforce origins.

---

## Costs and cleanup

- **What it costs:** the KMS key is about $1 a month. S3, Lambda, API Gateway, SQS and Secrets Manager (about $0.40 per secret per month) cost cents at this scale.
- **Tear down a dev stack:**
  1. Empty the bucket first, *including old versions*. The console's **Empty** button handles versions; `aws s3 rm --recursive` does not.
  2. Run `sam delete --stack-name sf-files-dev`.
  3. The KMS key is scheduled for deletion after a 7–30 day waiting period.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `ExpiredToken` / `Token has expired` | Your SSO session ended. Run `aws sso login`. |
| `Rate exceeded` in the console | Temporary throttling. Wait a minute, then refresh before retrying. |
| Your stack isn't visible in the console | The console region isn't `us-east-1`. |
| CLI output opens in a pager (lines start with `:`) | Press `q` to exit. Turn the pager off with `export AWS_PAGER=""` in `~/.zshrc`, or `--no-cli-pager` per command. |
| `SignatureDoesNotMatch` on a presigned PUT | Headers or byte count differ from what was signed. Send exactly the returned `headers`. |
| `{"message":"Forbidden"}` from the API | The request wasn't signed, or the caller lacks `execute-api:Invoke`. |
| HeadObject returns 403 instead of 404 | The function's role is missing `s3:ListBucket` on the bucket. |
| `CREATE_FAILED` on the bucket notification | The queue policy doesn't allow S3 yet. Add `DependsOn` and check the `aws:SourceArn` condition. |
| Files stay Pending forever | Check the sync Lambda's logs and the DLQ. If they've been Pending for 24 hours, `S3FileCleanupJob` marks them Failed. |

## Review notes

Open questions from a review of this guide on 2026-10-16. Talk through each one when you reach its milestone; nothing above has been changed yet.

### Milestone 2
- **`sam local invoke` uses the wrong bucket.** Locally, SAM resolves `!Ref FilesBucket` to the string `FilesBucket`, so presigned URLs point at a bucket that doesn't exist. Pass the real name with `--env-vars events/env.json`: `{"PresignFunction":{"BUCKET_NAME":"<bucket>"}}`.
- **Checksums in current SDK versions.** Newer AWS SDK v2 releases add default integrity checksums, which can put `x-amz-checksum-*` or `x-amz-sdk-checksum-algorithm` into presigned PUTs and break browser uploads. If your URLs contain them, set `requestChecksumCalculation(WHEN_REQUIRED)`. The reference's SDK 2.25 predates this, so comparing against it won't show the problem.
- **Jackson 2 or 3.** "Current Jackson" now means Jackson 3, which has a new groupId and package (`tools.jackson`). Choose deliberately; 2.x stays closer to the reference.
- **Accept 18-character IDs only in `FileKeys`.** Apex always writes 18, and `S3FileRepository.forParent` matches the 18-character string, so a file stored under a 15-character ID would never show on the record.
- **Encode `Content-Disposition`.** `fileName` is the original, unsanitized name (unicode, quotes), and it's null for records the sync Lambda created. Fall back to `FileKeys.fileName(key)`, then send `filename="<ascii fallback>"; filename*=UTF-8''<percent-encoded>`. The reference's `downloadUrl` shows how.
- **Create log groups now.** Lambda creates `/aws/lambda/<fn>` on the first run, so an `AWS::Logs::LogGroup` with the same name added in milestone 8 fails with "already exists". Define it alongside the function (or use `LoggingConfig`).
- **Credential lifetime.** A presigned URL stops working when the Lambda's temporary credentials expire, even if its own expiry is later. This matters most for the 60-minute part URLs in milestone 4.

### Milestone 4
- **Test step 5 can't pass as written.** The `ListParts` check only aborts above `MAX_FILE_BYTES` (5 GB), so uploading slightly more than the declared 12 MB succeeds. The metadata idea doesn't help either: metadata from `CreateMultipartUpload` only appears on the finished object and can't be read during the upload.
- **Better fix: sign `Content-Length` into each `UploadPart` URL.** Part sizes are fixed (`partSize`, with the remainder in the last part), and the LWC slices exactly those sizes. The total then equals the declared size, and an oversized part fails with `SignatureDoesNotMatch`. Keep `ListParts` as a backup check. The reference doesn't do this; add it to the fixes table.
- **Paginate `ListParts`.** It returns at most 1,000 parts per page, and a 5 GB file with 5 MB parts has 1,024.

### Milestone 5
- **CSP host must match the presigned URLs.** Milestone 1 tests `bucket.s3.amazonaws.com`, but `BucketEndpoint` is `bucket.s3.us-east-1.amazonaws.com`. Check which host the presigner actually emits and use that for the CSP Trusted Site.

### Milestone 6
- **Why SQS-managed encryption.** S3 can't send notifications to a queue encrypted with the AWS-managed `aws/sqs` key. Worth adding to the Learn section.

### Milestone 7
- **Ghost records.** The upsert inserts when no record matches, so a late or duplicate `ObjectCreated` event arriving after a user deleted the record re-creates it as Available, pointing at an object that now only has a delete marker. Consider calling `HeadObject` in `SyncHandler` and skipping keys that return 404 (the sync role then needs `s3:GetObject`).
- **DLQ test depends on how parse errors are handled.** `'not json'` reaches the DLQ only if the handler reports parse failures as batch item failures rather than skipping them.
- **Integration user license.** Assign the *Salesforce API Integration* permission set license before `S3_File_Integration`, or the assignment fails.
- **Placeholder secret.** Don't change the template's `SecretString` after running `put-secret-value`, or the next deploy overwrites the real values.

### Milestone 8 and cleanup
- **Delete the access key before tearing down.** CloudFormation can't delete the callout user while it still has the access key created by hand in milestone 5. Run `aws iam delete-access-key` before `sam delete`.
- **Retain changes teardown.** Once `Retain` is on, `sam delete` leaves the bucket, KMS key and secret behind. Update the cleanup steps to match.

### Guide housekeeping
- Milestones 3–6 have no `Reference:` line.
