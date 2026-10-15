import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import getFiles from '@salesforce/apex/S3FileController.getFiles';
import startUpload from '@salesforce/apex/S3FileController.startUpload';
import completeMultipart from '@salesforce/apex/S3FileController.completeMultipart';
import getDownloadUrl from '@salesforce/apex/S3FileController.getDownloadUrl';
import deleteFile from '@salesforce/apex/S3FileController.deleteFile';

const PART_CONCURRENCY = 4;
const PART_ATTEMPTS = 3;
const POLL_INTERVAL_MS = 3000;
const POLL_MAX_ATTEMPTS = 10;

function getRowActions(row, doneCallback) {
    const actions = [];
    if (row.status === 'Available') {
        actions.push({ label: 'Download', name: 'download' }, { label: 'Preview', name: 'preview' });
    }
    actions.push({ label: 'Delete', name: 'delete' });
    doneCallback(actions);
}

const COLUMNS = [
    { label: 'File name', fieldName: 'fileName', wrapText: true },
    { label: 'Size', fieldName: 'sizeLabel', initialWidth: 100 },
    { label: 'Status', fieldName: 'status', initialWidth: 110 },
    {
        label: 'Uploaded',
        fieldName: 'createdDate',
        type: 'date',
        initialWidth: 180,
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }
    },
    { label: 'Uploaded by', fieldName: 'createdBy' },
    { type: 'action', typeAttributes: { rowActions: getRowActions } }
];

export default class S3FileManager extends LightningElement {
    @api recordId;
    @api cardTitle = 'Files (S3)';

    columns = COLUMNS;
    files = [];
    isLoading = false;
    hasLoaded = false;
    isUploading = false;
    uploadLabel = '';
    uploadProgress = 0;
    pollTimer;
    pollCount = 0;

    /** Home, app, utility bar, and some Experience pages have no record unless one is configured. */
    get hasRecord() {
        return Boolean(this.recordId);
    }

    get refreshDisabled() {
        return this.isUploading || !this.hasRecord;
    }

    get hasFiles() {
        return this.files.length > 0;
    }

    get showEmptyState() {
        return this.hasLoaded && !this.isLoading;
    }

    connectedCallback() {
        this.loadFiles();
    }

    disconnectedCallback() {
        clearTimeout(this.pollTimer);
    }

    // ---------- Loading ----------

    async loadFiles() {
        if (!this.hasRecord) {
            return;
        }
        this.isLoading = true;
        try {
            const result = await getFiles({ parentId: this.recordId });
            this.files = result.map((f) => ({ ...f, sizeLabel: formatSize(f.sizeBytes) }));
        } catch (error) {
            this.toast('Could not load files', reduceError(error), 'error');
        } finally {
            this.isLoading = false;
            this.hasLoaded = true;
        }
        this.schedulePollIfPending();
    }

    /** New uploads stay Pending until the S3 event is synced, usually a few seconds. */
    schedulePollIfPending() {
        clearTimeout(this.pollTimer);
        const hasPending = this.files.some((f) => f.status === 'Pending');
        if (hasPending && this.pollCount < POLL_MAX_ATTEMPTS) {
            this.pollCount += 1;
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.pollTimer = setTimeout(() => this.loadFiles(), POLL_INTERVAL_MS);
        }
    }

    handleRefresh() {
        this.pollCount = 0;
        this.loadFiles();
    }

    // ---------- Upload ----------

    async handleFilesSelected(event) {
        const selected = Array.from(event.target.files || []);
        if (!selected.length) {
            return;
        }
        this.isUploading = true;
        let succeeded = 0;

        for (const file of selected) {
            this.uploadLabel = file.name;
            this.uploadProgress = 0;
            try {
                // eslint-disable-next-line no-await-in-loop
                await this.uploadFile(file);
                succeeded += 1;
            } catch (error) {
                this.toast(`Upload failed: ${file.name}`, reduceError(error), 'error');
            }
        }

        this.isUploading = false;
        this.uploadLabel = '';
        if (succeeded) {
            this.toast('Upload complete', `${succeeded} file(s) uploaded. They will show as Available shortly.`, 'success');
        }
        this.pollCount = 0;
        this.loadFiles();
    }

    async uploadFile(file) {
        const upload = await startUpload({
            parentId: this.recordId,
            fileName: file.name,
            contentType: file.type || 'application/octet-stream',
            size: file.size
        });

        if (upload.mode === 'single') {
            await putBlob(upload.url, file, upload.headers, (loaded) => this.setProgress(loaded, file.size));
            return;
        }

        const parts = await this.uploadParts(file, upload);
        await completeMultipart({
            fileId: upload.fileId,
            uploadId: upload.uploadId,
            partsJson: JSON.stringify(parts)
        });
    }

    async uploadParts(file, upload) {
        const { partSize, parts } = upload;
        const loadedByPart = new Map();
        const completed = [];
        let next = 0;

        const reportProgress = () => {
            let total = 0;
            loadedByPart.forEach((bytes) => {
                total += bytes;
            });
            this.setProgress(total, file.size);
        };

        const worker = async () => {
            while (next < parts.length) {
                const part = parts[next];
                next += 1;
                const start = (part.partNumber - 1) * partSize;
                const blob = file.slice(start, Math.min(start + partSize, file.size));

                let etag;
                for (let attempt = 1; attempt <= PART_ATTEMPTS; attempt += 1) {
                    try {
                        // eslint-disable-next-line no-await-in-loop
                        etag = await putBlob(part.url, blob, null, (loaded) => {
                            loadedByPart.set(part.partNumber, loaded);
                            reportProgress();
                        });
                        break;
                    } catch (error) {
                        loadedByPart.set(part.partNumber, 0);
                        if (attempt === PART_ATTEMPTS) {
                            throw error;
                        }
                    }
                }
                if (!etag) {
                    throw new Error('S3 did not return an ETag. Check that the bucket CORS configuration exposes the ETag header.');
                }
                completed.push({ partNumber: part.partNumber, etag });
            }
        };

        const workers = [];
        for (let i = 0; i < Math.min(PART_CONCURRENCY, parts.length); i += 1) {
            workers.push(worker());
        }
        await Promise.all(workers);
        return completed.sort((a, b) => a.partNumber - b.partNumber);
    }

    setProgress(loaded, total) {
        this.uploadProgress = total ? Math.min(100, Math.round((loaded / total) * 100)) : 0;
    }

    // ---------- Row actions ----------

    async handleRowAction(event) {
        const action = event.detail.action.name;
        const row = event.detail.row;
        try {
            if (action === 'download' || action === 'preview') {
                const url = await getDownloadUrl({ fileId: row.id, inline: action === 'preview' });
                const opened = window.open(url, '_blank');
                if (!opened) {
                    this.toast('Pop-up blocked', 'Allow pop-ups for this site to download files.', 'warning');
                }
            } else if (action === 'delete') {
                const confirmed = await LightningConfirm.open({
                    message: `Delete "${row.fileName}"? This cannot be undone from Salesforce.`,
                    label: 'Delete file',
                    theme: 'warning'
                });
                if (confirmed) {
                    await deleteFile({ fileId: row.id });
                    this.toast('File deleted', row.fileName, 'success');
                    this.loadFiles();
                }
            }
        } catch (error) {
            this.toast('Action failed', reduceError(error), 'error');
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}

/** PUTs a blob to a presigned S3 URL with progress reporting. Resolves with the ETag response header. */
function putBlob(url, blob, headers, onProgress) {
    return new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        xhr.open('PUT', url);
        Object.entries(headers || {}).forEach(([name, value]) => xhr.setRequestHeader(name, value));
        xhr.upload.onprogress = (event) => {
            if (event.lengthComputable) {
                onProgress(event.loaded);
            }
        };
        xhr.onload = () => {
            if (xhr.status >= 200 && xhr.status < 300) {
                resolve(xhr.getResponseHeader('ETag'));
            } else {
                reject(new Error(`Upload to storage failed (HTTP ${xhr.status}).`));
            }
        };
        xhr.onerror = () =>
            reject(new Error('Network error during upload. Check the CSP Trusted Site and bucket CORS settings.'));
        xhr.send(blob);
    });
}

function formatSize(bytes) {
    if (bytes === null || bytes === undefined) {
        return '';
    }
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let value = Number(bytes);
    let unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
        value /= 1024;
        unit += 1;
    }
    return `${value.toFixed(unit === 0 ? 0 : 1)} ${units[unit]}`;
}

function reduceError(error) {
    if (!error) {
        return 'Unknown error';
    }
    if (error.body) {
        if (Array.isArray(error.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        if (error.body.message) {
            return error.body.message;
        }
    }
    return error.message || 'Unknown error';
}